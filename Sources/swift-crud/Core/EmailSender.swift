// EmailSender.swift: email abstraction for delivering one-time login codes — provides PrintEmailSender (stdout fallback) and SMTPEmailSender (NIO-based with NIOSSL STARTTLS), plus a factory function.

import Foundation
import NIO
import NIOSSL

// MARK: - Protocol

/// Abstraction for delivering one-time login codes to users.
protocol EmailSender: Sendable {
    /// Deliver the given code to the user's email address.
    func send(code: String, to email: String) async throws
}

// MARK: - Print fallback

/// Prints the code to stdout — the default when no SMTP is configured.
struct PrintEmailSender: EmailSender {
    func send(code: String, to email: String) async throws {
        print("Email send simulated: to=\(email), code=\(code)")
    }
}

// MARK: - SMTP sender (NIO + NIOSSL)

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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownGroup(group) }

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
            if let ch = maybeChannel { try? ch.close().wait() }
            throw error
        }
    }

    // MARK: - Connection

    private func connect(group: EventLoopGroup, handler: SMTPResponseHandler) async throws -> Channel {
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.autoRead, value: true)
            .channelInitializer { channel in
                if self.tlsMode == .tls {
                    do {
                        let config = self.makeTLSConfig()
                        let ctx = try NIOSSLContext(configuration: config)
                        let sslHandler = try NIOSSLClientHandler(context: ctx, serverHostname: self.host)
                        return channel.pipeline.addHandler(sslHandler).flatMap {
                            channel.pipeline.addHandler(handler)
                        }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
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
        let sslHandler = try NIOSSLClientHandler(context: ctx, serverHostname: host)

        try await channel.eventLoop.submit {
            channel.pipeline.addHandler(sslHandler, position: .first).whenComplete { _ in }
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
                channel.writeAndFlush(buffer)
            }
        }
        return try await promise.futureResult.get()
    }

    // MARK: - Message builder

    private func buildMessage(code: String, to recipient: String) -> String {
        return """
        From: \(from)
        To: \(recipient)
        Subject: Your login code

        Your login code is: \(code)

        This code expires in 10 minutes.
        """
    }
}

// MARK: - Factory

extension EmailSender where Self == PrintEmailSender {
    static var printFallback: PrintEmailSender { PrintEmailSender() }
}

extension EmailSender where Self == SMTPEmailSender {
    static func smtp(host: String, port: UInt16, username: String, password: String, from: String,
                     tlsMode: SMTPTLSMode = .starttls, tlsInsecure: Bool = false) -> SMTPEmailSender {
        SMTPEmailSender(host: host, port: port, username: username, password: password,
                        from: from, tlsMode: tlsMode, tlsInsecure: tlsInsecure)
    }
}

/// Picks the right sender based on environment config.
func makeEmailSender(from env: Environment) -> EmailSender {
    guard let host = env.smtpHost,
          let username = env.smtpUsername,
          let password = env.smtpPassword,
          let from = env.smtpFrom
    else {
        return .printFallback
    }
    return .smtp(host: host, port: env.smtpPort, username: username, password: password, from: from,
                 tlsMode: env.smtpTLSMode, tlsInsecure: env.smtpTlsInsecure)
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
        responsePromise = nil
        guard var acc = accumulated else { return }
        let result = acc.readString(length: acc.readableBytes) ?? ""
        acc.clear()
        accumulated = acc
        promise.succeed(result)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let promise = responsePromise {
            responsePromise = nil
            promise.fail(error)
        }
    }
}
