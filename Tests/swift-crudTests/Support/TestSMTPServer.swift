// TestSMTPServer.swift: loopback SMTP server for connection reuse tests; counts TCP sessions and accepts plaintext mail.

import Foundation
import NIO
@testable import swift_crud

/// Shared counters across connections on one test server instance.
final class TestSMTPMetrics: @unchecked Sendable {
    var tcpConnectionCount = 0
    var ehloCount = 0
    var rsetCount = 0
    var messagesAccepted = 0
    var activeChannels: [Channel] = []
}

/// Loopback SMTP stub that counts TCP connects and accepts unauthenticated mail.
final class TestSMTPServer {
    private let group: EventLoopGroup
    private var channel: Channel
    private let metrics: TestSMTPMetrics
    private let bindPort: Int

    var port: Int { bindPort }

    var tcpConnectionCount: Int { metrics.tcpConnectionCount }
    var ehloCount: Int { metrics.ehloCount }
    var rsetCount: Int { metrics.rsetCount }
    var messagesAccepted: Int { metrics.messagesAccepted }

    private init(channel: Channel, group: EventLoopGroup, metrics: TestSMTPMetrics, bindPort: Int) {
        self.channel = channel
        self.group = group
        self.metrics = metrics
        self.bindPort = bindPort
    }

    static func start(group: EventLoopGroup) async throws -> TestSMTPServer {
        let metrics = TestSMTPMetrics()
        let channel = try await bindServer(group: group, metrics: metrics, port: 0)
        guard let bound = channel.localAddress?.port else { throw SMTPError.timeout }
        return TestSMTPServer(channel: channel, group: group, metrics: metrics, bindPort: Int(bound))
    }

    /// Closes the listener and active clients, then binds again on the same port.
    func restart() async throws {
        for child in metrics.activeChannels {
            try? await child.close()
        }
        metrics.activeChannels.removeAll()
        try await channel.close()
        try await Task.sleep(nanoseconds: 50_000_000)
        channel = try await Self.bindServer(group: group, metrics: metrics, port: bindPort)
    }

    func close() async throws {
        for child in metrics.activeChannels {
            try? await child.close()
        }
        metrics.activeChannels.removeAll()
        try await channel.close()
    }

    private static func bindServer(
        group: EventLoopGroup, metrics: TestSMTPMetrics, port: Int
    ) async throws -> Channel {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: true)
            .childChannelInitializer { channel -> EventLoopFuture<Void> in
                metrics.activeChannels.append(channel)
                return channel.pipeline.addHandler(TestSMTPChannelHandler(metrics: metrics))
            }
        return try await bootstrap.bind(host: "127.0.0.1", port: port).get()
    }
}

private final class TestSMTPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let metrics: TestSMTPMetrics
    private var buffer = ""
    private var inData = false

    init(metrics: TestSMTPMetrics) {
        self.metrics = metrics
    }

    func channelActive(context: ChannelHandlerContext) {
        metrics.tcpConnectionCount += 1
        send("220 test-smtp ready\r\n", context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        guard let chunk = buf.readString(length: buf.readableBytes) else { return }
        buffer += chunk
        processBuffer(context: context)
    }

    private func processBuffer(context: ChannelHandlerContext) {
        while true {
            if inData {
                guard let range = buffer.range(of: "\r\n.\r\n") else { return }
                buffer = String(buffer[range.upperBound...])
                inData = false
                metrics.messagesAccepted += 1
                send("250 ok\r\n", context: context)
                continue
            }

            guard let lineRange = buffer.range(of: "\r\n") else { return }
            let line = String(buffer[..<lineRange.lowerBound])
            buffer = String(buffer[lineRange.upperBound...])
            if line.isEmpty { continue }

            let upper = line.uppercased()
            if upper.hasPrefix("EHLO") || upper.hasPrefix("HELO") {
                metrics.ehloCount += 1
                send("250-test.local\r\n250 OK\r\n", context: context)
            } else if upper.hasPrefix("MAIL FROM") {
                send("250 ok\r\n", context: context)
            } else if upper.hasPrefix("RCPT TO") {
                send("250 ok\r\n", context: context)
            } else if upper == "DATA" {
                inData = true
                send("354 go ahead\r\n", context: context)
            } else if upper == "RSET" {
                metrics.rsetCount += 1
                send("250 ok\r\n", context: context)
            } else if upper == "NOOP" {
                send("250 ok\r\n", context: context)
            } else if upper == "QUIT" {
                send("221 bye\r\n", context: context)
                context.close(promise: nil)
                return
            } else {
                send("502 not implemented\r\n", context: context)
            }
        }
    }

    private func send(_ text: String, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        context.channel.writeAndFlush(buffer, promise: nil)
    }
}