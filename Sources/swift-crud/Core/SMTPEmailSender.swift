// SMTPEmailSender.swift: durable NIO SMTP client — keeps one authenticated session open and reuses it across sends.

import Foundation
import NIO
@preconcurrency import NIOSSL

/// Shared `EventLoopGroup` for SMTP when the app configures SMTP (created in `main`, shut down after server stop).
nonisolated(unsafe) var smtpEventLoopGroup: MultiThreadedEventLoopGroup?

/// Default seconds to wait for TCP connect and each SMTP response.
let defaultSMTPTimeoutSeconds: Int = 30

/// Configuration for an SMTP session (host, TLS, credentials).
struct SMTPConnectionConfig: Sendable {
    let host: String
    let port: UInt16
    let username: String
    let password: String
    let tlsMode: SMTPTLSMode
    let tlsInsecure: Bool
    let timeoutSeconds: Int
    let tlsServerName: String?

    var tlsPeerName: String {
        if let tlsServerName, !tlsServerName.isEmpty { return tlsServerName }
        return host
    }

    var requiresAuth: Bool {
        !username.isEmpty && !password.isEmpty
    }
}

/// Sends login codes through one long-lived SMTP session.
struct SMTPEmailSender: EmailSender {
    private let connection: SMTPConnection
    private let from: String
    private let fromName: String?

    init(config: SMTPConnectionConfig, group: EventLoopGroup, ownsGroup: Bool, from: String, fromName: String?) {
        self.connection = SMTPConnection(config: config, group: group, ownsGroup: ownsGroup)
        self.from = from
        self.fromName = fromName
    }

    func send(code: String, to email: String) async throws {
        let message = Self.buildMessage(code: code, to: email, from: from, fromName: fromName)
        try await connection.sendMail(from: from, message: message, recipient: email)
    }

    /// Closes the SMTP session (`QUIT`) and optional owned event loop group.
    func shutdown() async {
        await connection.shutdown()
    }

    // MARK: - Message builder

    static func buildMessage(code: String, to recipient: String, from: String, fromName: String?) -> String {
        let fromHeader = formatSMTPFromHeader(displayName: fromName, email: from)
        return "From: \(fromHeader)\r\n" +
            "To: \(recipient)\r\n" +
            "Subject: Your login code\r\n" +
            "\r\n" +
            "Your 8-digit login code is: \(code)\r\n" +
            "\r\n" +
            "Enter all 8 digits. This code expires in 10 minutes."
    }
}

/// Reusable SMTP client connection: EHLO/TLS/AUTH once, then MAIL per message with RSET between sends.
final class SMTPConnection: @unchecked Sendable {
    private let config: SMTPConnectionConfig
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private let workQueue = DispatchQueue(label: "swift-crud.smtp.connection")

    private var channel: Channel?
    private var handler: SMTPResponseHandler?
    private var lastActivity = Date.distantPast

    /// Issue `NOOP` when idle longer than this (seconds).
    private let idleNOOPSeconds: TimeInterval = 60
    /// Force reconnect when idle longer than this (seconds).
    private let idleReconnectSeconds: TimeInterval = 300

    init(config: SMTPConnectionConfig, group: EventLoopGroup, ownsGroup: Bool) {
        self.config = config
        self.group = group
        self.ownsGroup = ownsGroup
    }

    /// Sends a complete RFC 822 message body (headers + blank line + text) to `recipient`.
    func sendMail(from mailFrom: String, message: String, recipient: String) async throws {
        try await performExclusive { [self] in
            if self.config.tlsMode != .none, !Self.isValidTLSServerName(self.config.tlsPeerName) {
                throw SMTPError.invalidTLSHostname(self.config.tlsPeerName)
            }
            try self.ensureReady()
            guard let channel = self.channel, let handler = self.handler else { throw SMTPError.timeout }

            do {
                try requireSMTPCode(
                    in: try self.exchange("MAIL FROM:<\(mailFrom)>\r\n", channel: channel, handler: handler),
                    allowed: [250])
                try requireSMTPCode(
                    in: try self.exchange("RCPT TO:<\(recipient)>\r\n", channel: channel, handler: handler),
                    allowed: [250, 251])
                try requireSMTPCode(
                    in: try self.exchange("DATA\r\n", channel: channel, handler: handler),
                    allowed: [354])
                try requireSMTPCode(
                    in: try self.exchange(message + "\r\n.\r\n", channel: channel, handler: handler),
                    allowed: [250])
                _ = try self.exchange("RSET\r\n", channel: channel, handler: handler)
                self.touchActivity()
            } catch {
                self.disconnect()
                throw error
            }
        }
    }

    /// `QUIT` and close; safe to call multiple times.
    func shutdown() async {
        try? await performExclusive { [self] in
            self.disconnect(quiesce: true)
            if self.ownsGroup {
                shutdownEventLoopGroup(self.group)
            }
        }
    }

    /// Runs EHLO (and TLS/AUTH when configured). Exposed for unit tests.
    func connectForTesting() async throws {
        try await performExclusive { [self] in
            try self.connectAndAuthenticate()
        }
    }

    private func performExclusive<T>(_ operation: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func isValidTLSServerName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("_") && !name.contains(" ")
    }

    private func ensureReady() throws {
        let idle = Date().timeIntervalSince(lastActivity)

        if let channel, channel.isActive {
            if idle >= idleReconnectSeconds {
                disconnect()
            } else if idle >= idleNOOPSeconds {
                do {
                    guard let handler else { throw SMTPError.timeout }
                    try requireSMTPCode(
                        in: try exchange("NOOP\r\n", channel: channel, handler: handler),
                        allowed: [250])
                    touchActivity()
                    return
                } catch {
                    disconnect()
                }
            } else {
                return
            }
        }

        try connectAndAuthenticate()
    }

    private func connectAndAuthenticate() throws {
        if channel != nil {
            disconnect()
        }

        let timeout = TimeAmount.seconds(Int64(config.timeoutSeconds))
        let responseHandler = SMTPResponseHandler(timeout: timeout)
        let channel = try connect(group: group, handler: responseHandler)

        self.channel = channel
        self.handler = responseHandler

        try requireSMTPCode(in: try readResponse(channel: channel, handler: responseHandler), allowed: [220])
        try requireSMTPCode(
            in: try exchange("EHLO swift-crud\r\n", channel: channel, handler: responseHandler),
            allowed: [250])

        if config.tlsMode == .starttls {
            try requireSMTPCode(
                in: try exchange("STARTTLS\r\n", channel: channel, handler: responseHandler),
                allowed: [220])
            try upgradeToTLS(channel: channel, handler: responseHandler)
            try requireSMTPCode(
                in: try exchange("EHLO swift-crud\r\n", channel: channel, handler: responseHandler),
                allowed: [250])
        }

        if config.tlsMode == .none {
            if config.requiresAuth {
                throw SMTPError.authRequiresTLS
            }
        } else if config.requiresAuth {
            try requireSMTPCode(
                in: try exchange("AUTH LOGIN\r\n", channel: channel, handler: responseHandler),
                allowed: [334])
            try requireSMTPCode(
                in: try exchange(Data(config.username.utf8).base64EncodedString() + "\r\n",
                                 channel: channel, handler: responseHandler),
                allowed: [334])
            try requireSMTPCode(
                in: try exchange(Data(config.password.utf8).base64EncodedString() + "\r\n",
                                 channel: channel, handler: responseHandler),
                allowed: [235])
        }

        touchActivity()
    }

    private func disconnect(quiesce: Bool = false) {
        let channel = self.channel
        let handler = self.handler

        self.channel = nil
        self.handler = nil

        if quiesce, let channel, channel.isActive, let handler {
            _ = try? exchange("QUIT\r\n", channel: channel, handler: handler)
        }
        if let channel {
            try? channel.close().wait()
        }
    }

    private func touchActivity() {
        lastActivity = Date()
    }

    private func connect(group: EventLoopGroup, handler: SMTPResponseHandler) throws -> Channel {
        let sslBox: SendableBox<NIOSSLClientHandler>?
        if config.tlsMode == .tls {
            let tlsConfig = makeTLSConfig()
            let context = try NIOSSLContext(configuration: tlsConfig)
            sslBox = SendableBox(try NIOSSLClientHandler(context: context, serverHostname: config.tlsPeerName))
        } else {
            sslBox = nil
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: TimeAmount.seconds(Int64(config.timeoutSeconds)))
            .channelOption(ChannelOptions.autoRead, value: true)
            .channelInitializer { channel in
                if let sslBox {
                    return channel.pipeline.addHandler(sslBox.value).flatMap {
                        channel.pipeline.addHandler(handler)
                    }
                }
                return channel.pipeline.addHandler(handler)
            }
        return try bootstrap.connect(host: config.host, port: Int(config.port)).wait()
    }

    private func upgradeToTLS(channel: Channel, handler: SMTPResponseHandler) throws {
        let tlsConfig = makeTLSConfig()
        let context = try NIOSSLContext(configuration: tlsConfig)
        let box = SendableBox(try NIOSSLClientHandler(context: context, serverHostname: config.tlsPeerName))
        nonisolated(unsafe) let sslHandler = box.value

        _ = try channel.eventLoop.submit {
            channel.pipeline.addHandler(sslHandler, position: .first)
        }.wait()
    }

    private func makeTLSConfig() -> TLSConfiguration {
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        if config.tlsInsecure {
            tlsConfig.certificateVerification = .none
        }
        return tlsConfig
    }

    private func exchange(_ command: String, channel: Channel, handler: SMTPResponseHandler) throws -> String {
        try sendCommand(command, channel: channel, handler: handler)
        return try readResponse(channel: channel, handler: handler)
    }

    private func sendCommand(_ command: String, channel: Channel, handler: SMTPResponseHandler) throws {
        handler.cancelTimeout()
        let buffer = channel.allocator.buffer(string: command)
        try channel.writeAndFlush(buffer).wait()
    }

    private func readResponse(channel: Channel, handler: SMTPResponseHandler) throws -> String {
        try smtpReadResponse(channel: channel, handler: handler)
    }
}

// MARK: - SMTP framing (testable)

/// Returns true when `response` ends with a final SMTP status line (`ddd `), not a continuation (`ddd-`).
func isSMTPResponseComplete(_ response: String) -> Bool {
    guard let last = smtpResponseLines(response).last else { return false }
    guard last.count >= 4 else { return false }
    let idx3 = last.index(last.startIndex, offsetBy: 3)
    return last.prefix(3).allSatisfy(\.isNumber) && last[idx3] == " "
}

/// Final status code from the last non-empty line of a multiline SMTP reply.
func smtpFinalStatusCode(_ response: String) -> Int? {
    guard let last = smtpResponseLines(response).last, last.count >= 3 else { return nil }
    return Int(last.prefix(3))
}

/// Throws when the final SMTP status is not one of `allowed`.
func requireSMTPCode(in response: String, allowed: [Int]) throws {
    guard let code = smtpFinalStatusCode(response), allowed.contains(code) else {
        throw SMTPError.serverRejected(response.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private func smtpResponseLines(_ response: String) -> [String] {
    response.split(separator: "\r\n", omittingEmptySubsequences: true).map(String.init)
}

/// Reads one complete SMTP reply (test helper and shared read path).
func smtpReadResponse(channel: Channel, handler: SMTPResponseHandler) throws -> String {
    let promise = channel.eventLoop.makePromise(of: String.self)
    try channel.eventLoop.submit {
        handler.cancelTimeout()
        if let buffered = handler.drainIfComplete() {
            promise.succeed(buffered)
            return
        }
        handler.beginWaiting(promise: promise, on: channel.eventLoop)
    }.wait()
    return try promise.futureResult.wait()
}

/// Sendable wrapper for NIOSSL types that are explicitly unavailable for Sendable.
private final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Accumulates SMTP response bytes and bridges to an EventLoopPromise.
final class SMTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let timeout: TimeAmount
    private var responsePromise: EventLoopPromise<String>?
    private var timeoutTask: Scheduled<Void>?
    fileprivate var accumulated: ByteBuffer?

    init(timeout: TimeAmount) {
        self.timeout = timeout
    }

    func drainIfComplete() -> String? {
        guard let acc = accumulated, acc.readableBytes > 0 else { return nil }
        let response = String(decoding: acc.readableBytesView, as: UTF8.self)
        guard isSMTPResponseComplete(response) else { return nil }
        accumulated?.clear()
        return response
    }

    func beginWaiting(promise: EventLoopPromise<String>, on loop: EventLoop) {
        responsePromise = promise
        scheduleTimeout(on: loop)
    }

    func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    func channelActive(context: ChannelHandlerContext) {
        if accumulated == nil {
            accumulated = context.channel.allocator.buffer(capacity: 0)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var data = unwrapInboundIn(data)
        if accumulated == nil {
            accumulated = context.channel.allocator.buffer(capacity: 0)
        }
        accumulated?.writeBuffer(&data)
        guard let promise = responsePromise else { return }
        guard let acc = accumulated else { return }
        let response = String(decoding: acc.readableBytesView, as: UTF8.self)
        guard isSMTPResponseComplete(response) else { return }
        responsePromise = nil
        cancelTimeout()
        accumulated?.clear()
        promise.succeed(response)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failPendingPromise(error)
        context.close(promise: nil)
    }

    private func failPendingPromise(_ error: Error) {
        cancelTimeout()
        if let promise = responsePromise {
            responsePromise = nil
            promise.fail(error)
        }
    }

    private func scheduleTimeout(on loop: EventLoop) {
        cancelTimeout()
        timeoutTask = loop.scheduleTask(in: timeout) { [weak self] in
            self?.failPendingPromise(SMTPError.timeout)
        }
    }
}

private func shutdownEventLoopGroup(_ group: EventLoopGroup) {
    let semaphore = DispatchSemaphore(value: 0)
    group.shutdownGracefully(queue: .global()) { _ in
        semaphore.signal()
    }
    semaphore.wait()
}
