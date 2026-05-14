// SMTPEmailSender.swift: NIO + NIOSSL SMTP client for delivering login codes (STARTTLS, implicit TLS, response framing).

import Foundation
import NIO
@preconcurrency import NIOSSL

/// Shared `EventLoopGroup` for SMTP when the app configures SMTP (created in `main`, shut down after server stop).
nonisolated(unsafe) var smtpEventLoopGroup: MultiThreadedEventLoopGroup?

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
    let tlsMode: SMTPTLSMode
    let tlsInsecure: Bool

    func send(code: String, to email: String) async throws {
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

        let handler = SMTPResponseHandler()
        var maybeChannel: Channel?

        do {
            let channel = try await connect(group: group, handler: handler)
            maybeChannel = channel

            _ = try await send("EHLO swift-crud\r\n", channel: channel, handler: handler)

            if tlsMode == .starttls {
                try await upgradeToTLS(channel: channel, handler: handler)
                _ = try await send("EHLO swift-crud\r\n", channel: channel, handler: handler)
            }

            if tlsMode == .none {
                throw SMTPError.authRequiresTLS
            }

            _ = try await send("AUTH LOGIN\r\n", channel: channel, handler: handler)
            _ = try await send(Data(username.utf8).base64EncodedString() + "\r\n", channel: channel, handler: handler)
            _ = try await send(Data(password.utf8).base64EncodedString() + "\r\n", channel: channel, handler: handler)
            _ = try await send("MAIL FROM:<\(from)>\r\n", channel: channel, handler: handler)
            _ = try await send("RCPT TO:<\(email)>\r\n", channel: channel, handler: handler)
            _ = try await send("DATA\r\n", channel: channel, handler: handler)
            _ = try await send(message + "\r\n.\r\n", channel: channel, handler: handler)
            _ = try await send("QUIT\r\n", channel: channel, handler: handler)

            try? await channel.close().get()
        } catch {
            if let ch = maybeChannel {
                try? await ch.close().get()
            }
            throw error
        }
    }

    // MARK: - Connection

    private func connect(group: EventLoopGroup, handler: SMTPResponseHandler) async throws -> Channel {
        let sslBox: SendableBox<NIOSSLClientHandler>?
        if self.tlsMode == .tls {
            let config = self.makeTLSConfig()
            let ctx = try NIOSSLContext(configuration: config)
            sslBox = SendableBox(try NIOSSLClientHandler(context: ctx, serverHostname: self.host))
        } else {
            sslBox = nil
        }
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
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
        _ = try await send("STARTTLS\r\n", channel: channel, handler: handler)

        let config = makeTLSConfig()
        let ctx = try NIOSSLContext(configuration: config)
        let box = SendableBox(try NIOSSLClientHandler(context: ctx, serverHostname: host))
        nonisolated(unsafe) let h = box.value

        try await channel.eventLoop.submit {
            channel.pipeline.addHandler(h, position: .first).whenComplete { _ in }
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

    @discardableResult
    private func send(_ command: String, channel: Channel, handler: SMTPResponseHandler) async throws -> String {
        let promise = channel.eventLoop.makePromise(of: String.self)
        channel.eventLoop.execute {
            if var acc = handler.accumulated, acc.readableBytes > 0 {
                let result = acc.readString(length: acc.readableBytes) ?? ""
                acc.clear()
                handler.accumulated = acc
                promise.succeed(result)
            } else {
                handler.responsePromise = promise
                let buffer = channel.allocator.buffer(string: command)
                _ = channel.writeAndFlush(buffer)
            }
        }
        return try await promise.futureResult.get()
    }

    // MARK: - Message builder

    private func buildMessage(code: String, to recipient: String) -> String {
        return "From: \(from)\r\n" +
            "To: \(recipient)\r\n" +
            "Subject: Your login code\r\n" +
            "\r\n" +
            "Your login code is: \(code)\r\n" +
            "\r\n" +
            "This code expires in 10 minutes."
    }
}

// MARK: - Helpers

/// Bridge to NIO's synchronous shutdown from Swift async.
private func shutdownGroup(_ group: EventLoopGroup) {
    group.shutdownGracefully(queue: .global()) { _ in }
}

/// Returns true when `response` ends with a final SMTP status line (`ddd `), not a continuation (`ddd-`).
fileprivate func isSMTPResponseComplete(_ response: String) -> Bool {
    let lines = response.components(separatedBy: "\r\n")
    guard let last = lines.last, !last.isEmpty else { return false }
    guard last.count >= 4 else { return false }
    let idx3 = last.index(last.startIndex, offsetBy: 3)
    return last.prefix(3).allSatisfy(\.isNumber) && last[idx3] == " "
}

// MARK: - NIO channel handler

/// Accumulates SMTP response bytes and bridges to an EventLoopPromise.
private final class SMTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    fileprivate var responsePromise: EventLoopPromise<String>?
    fileprivate var accumulated: ByteBuffer?

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
        accumulated?.clear()
        promise.succeed(response)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let promise = responsePromise {
            responsePromise = nil
            promise.fail(error)
        }
    }
}
