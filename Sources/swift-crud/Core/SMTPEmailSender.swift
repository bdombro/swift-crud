// SMTPEmailSender.swift: NIO + NIOSSL SMTP client for delivering login codes (STARTTLS, implicit TLS, response framing).

import Foundation
import NIO
@preconcurrency import NIOSSL

/// Shared `EventLoopGroup` for SMTP when the app configures SMTP (created in `main`, shut down after server stop).
nonisolated(unsafe) var smtpEventLoopGroup: MultiThreadedEventLoopGroup?

/// Default seconds to wait for TCP connect and each SMTP response.
let defaultSMTPTimeoutSeconds: Int = 30

/// Sendable wrapper for NIOSSL types that are explicitly unavailable for Sendable.
private final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Sends the code via SMTP using NIO with optional TLS (STARTTLS or implicit).
/// Requires `SMTP_HOST`, `SMTP_USERNAME`, `SMTP_PASSWORD`, and `SMTP_FROM` env vars.
struct SMTPEmailSender: EmailSender {
    let host: String
    let port: UInt16
    let username: String
    let password: String
    let from: String
    /// Optional display name for the `From` header (`SMTP_FROM_NAME`).
    let fromName: String?
    let tlsMode: SMTPTLSMode
    let tlsInsecure: Bool
    let timeoutSeconds: Int
    /// Hostname for TLS certificate verification / SNI (defaults to `host` when valid).
    let tlsServerName: String?

    private var tlsPeerName: String {
        if let tlsServerName, !tlsServerName.isEmpty { return tlsServerName }
        return host
    }

    func send(code: String, to email: String) async throws {
        if tlsMode != .none, !Self.isValidTLSServerName(tlsPeerName) {
            throw SMTPError.invalidTLSHostname(tlsPeerName)
        }
        let message = buildMessage(code: code, to: email)
        let group: MultiThreadedEventLoopGroup
        let ownsGroup: Bool
        if let shared = smtpEventLoopGroup {
            group = shared
            ownsGroup = false
        } else {
            group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            ownsGroup = true
        }
        defer {
            if ownsGroup {
                shutdownGroup(group)
            }
        }

        let handler = SMTPResponseHandler(timeout: TimeAmount.seconds(Int64(timeoutSeconds)))
        var maybeChannel: Channel?

        do {
            let channel = try await connect(group: group, handler: handler)
            maybeChannel = channel

            _ = try await readResponse(channel: channel, handler: handler)
            try requireSMTPCode(in: try await exchange("EHLO swift-crud\r\n", channel: channel, handler: handler),
                                allowed: [250])

            if tlsMode == .starttls {
                try requireSMTPCode(
                    in: try await exchange("STARTTLS\r\n", channel: channel, handler: handler),
                    allowed: [220])
                try await upgradeToTLS(channel: channel, handler: handler)
                try requireSMTPCode(
                    in: try await exchange("EHLO swift-crud\r\n", channel: channel, handler: handler),
                    allowed: [250])
            }

            if tlsMode == .none {
                throw SMTPError.authRequiresTLS
            }

            try requireSMTPCode(
                in: try await exchange("AUTH LOGIN\r\n", channel: channel, handler: handler),
                allowed: [334])
            try requireSMTPCode(
                in: try await exchange(Data(username.utf8).base64EncodedString() + "\r\n", channel: channel,
                                      handler: handler),
                allowed: [334])
            try requireSMTPCode(
                in: try await exchange(Data(password.utf8).base64EncodedString() + "\r\n", channel: channel,
                                      handler: handler),
                allowed: [235])

            try requireSMTPCode(
                in: try await exchange("MAIL FROM:<\(from)>\r\n", channel: channel, handler: handler),
                allowed: [250])
            try requireSMTPCode(
                in: try await exchange("RCPT TO:<\(email)>\r\n", channel: channel, handler: handler),
                allowed: [250, 251])
            try requireSMTPCode(
                in: try await exchange("DATA\r\n", channel: channel, handler: handler),
                allowed: [354])
            try requireSMTPCode(
                in: try await exchange(message + "\r\n.\r\n", channel: channel, handler: handler),
                allowed: [250])
            _ = try await exchange("QUIT\r\n", channel: channel, handler: handler)

            try? await channel.close().get()
        } catch {
            if let ch = maybeChannel {
                try? await ch.close().get()
            }
            throw error
        }
    }

    // MARK: - Connection

    private static func isValidTLSServerName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("_") && !name.contains(" ")
    }

    private func connect(group: EventLoopGroup, handler: SMTPResponseHandler) async throws -> Channel {
        let sslBox: SendableBox<NIOSSLClientHandler>?
        if self.tlsMode == .tls {
            let config = self.makeTLSConfig()
            let ctx = try NIOSSLContext(configuration: config)
            sslBox = SendableBox(try NIOSSLClientHandler(context: ctx, serverHostname: self.tlsPeerName))
        } else {
            sslBox = nil
        }
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: TimeAmount.seconds(Int64(timeoutSeconds)))
            .channelOption(ChannelOptions.autoRead, value: true)
            .channelInitializer { channel in
                if let box = sslBox {
                    return channel.pipeline.addHandler(box.value).flatMap {
                        channel.pipeline.addHandler(handler)
                    }
                } else {
                    return channel.pipeline.addHandler(handler)
                }
            }
        return try await bootstrap.connect(host: host, port: Int(port)).get()
    }

    // MARK: - STARTTLS upgrade

    private func upgradeToTLS(channel: Channel, handler: SMTPResponseHandler) async throws {
        let config = makeTLSConfig()
        let ctx = try NIOSSLContext(configuration: config)
        let box = SendableBox(try NIOSSLClientHandler(context: ctx, serverHostname: tlsPeerName))
        nonisolated(unsafe) let sslHandler = box.value

        try await channel.eventLoop.submit {
            channel.pipeline.addHandler(sslHandler, position: .first)
        }.get()
    }

    // MARK: - TLS config

    private func makeTLSConfig() -> TLSConfiguration {
        var config = TLSConfiguration.makeClientConfiguration()
        if tlsInsecure {
            config.certificateVerification = .none
        }
        return config
    }

    // MARK: - Request / response

    private func exchange(_ command: String, channel: Channel, handler: SMTPResponseHandler) async throws -> String {
        try await sendCommand(command, channel: channel, handler: handler)
        return try await readResponse(channel: channel, handler: handler)
    }

    private func sendCommand(_ command: String, channel: Channel, handler: SMTPResponseHandler) async throws {
        try await channel.eventLoop.submit {
            handler.cancelTimeout()
            let buffer = channel.allocator.buffer(string: command)
            channel.writeAndFlush(buffer, promise: nil)
        }.get()
    }

    private func readResponse(channel: Channel, handler: SMTPResponseHandler) async throws -> String {
        let promise = channel.eventLoop.makePromise(of: String.self)
        try await channel.eventLoop.submit {
            handler.cancelTimeout()
            if let buffered = handler.drainIfComplete() {
                promise.succeed(buffered)
                return
            }
            handler.beginWaiting(promise: promise, on: channel.eventLoop)
        }.get()
        return try await promise.futureResult.get()
    }

    // MARK: - Message builder

    private func buildMessage(code: String, to recipient: String) -> String {
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

// MARK: - Helpers

/// Bridge to NIO's synchronous shutdown from Swift async.
private func shutdownGroup(_ group: EventLoopGroup) {
    group.shutdownGracefully(queue: .global()) { _ in }
}

// MARK: - NIO channel handler

/// Accumulates SMTP response bytes and bridges to an EventLoopPromise.
private final class SMTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let timeout: TimeAmount
    private var responsePromise: EventLoopPromise<String>?
    private var timeoutTask: Scheduled<Void>?
    fileprivate var accumulated: ByteBuffer?

    init(timeout: TimeAmount) {
        self.timeout = timeout
    }

    fileprivate func drainIfComplete() -> String? {
        guard let acc = accumulated, acc.readableBytes > 0 else { return nil }
        let response = String(decoding: acc.readableBytesView, as: UTF8.self)
        guard isSMTPResponseComplete(response) else { return nil }
        accumulated?.clear()
        return response
    }

    fileprivate func beginWaiting(promise: EventLoopPromise<String>, on loop: EventLoop) {
        responsePromise = promise
        scheduleTimeout(on: loop)
    }

    fileprivate func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    func channelActive(context: ChannelHandlerContext) {
        accumulated = context.channel.allocator.buffer(capacity: 0)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var data = unwrapInboundIn(data)
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
