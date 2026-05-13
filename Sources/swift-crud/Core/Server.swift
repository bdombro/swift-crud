// Server.swift: wraps a SwiftNIO HTTP server (NIOTS/NIOTransportServices) with start/stop lifecycle and a NIOHTTPServerHandler that dispatches requests to the route table.

import Foundation
import NIO
import NIOHTTP1
import NIOTransportServices

final class Server: @unchecked Sendable {
    let port: UInt16
    private let group: EventLoopGroup
    private var channel: Channel?

    /// The port the HTTP server actually bound to (may differ from `port` when port 0 is used).
    private(set) var boundPort: UInt16?

    init(port: UInt16) {
        self.port = port
        self.group = NIOTSEventLoopGroup()
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    /// Blocking start — used by the app entrypoint. Binds to 0.0.0.0 and runs until stopped.
    func start() async throws {
        _ = try await bind(host: "0.0.0.0")
        guard let channel = self.channel else { return }
        try await channel.closeFuture.get()
    }

    /// Non-blocking start — binds to 127.0.0.1 and returns immediately. For tests.
    func startAndListen() async throws {
        let channel = try await bind(host: "127.0.0.1")
        if let address = channel.localAddress {
            boundPort = UInt16(address.port ?? Int(self.port))
        }
    }

    /// Internal bind helper — shared by both start modes.
    private func bind(host: String) async throws -> Channel {
        let bootstrap = NIOTSListenerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(NIOHTTPServerHandler())
                }
            }

        let channel = try await bootstrap.bind(host: host, port: Int(self.port)).get()
        self.channel = channel
        return channel
    }

    /// Stops the server.
    func stop() async {
        if let channel = channel {
            try? await channel.close()
            self.channel = nil
        }
        try? await group.shutdownGracefully()
    }
}

private final class NIOHTTPServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var head: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?

    private static func formatLogDate(_ date: Date) -> String {
        let comp = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d.%02d.%02d_%02d:%02d:%02d",
            comp.year ?? 0, comp.month ?? 0, comp.day ?? 0,
            comp.hour ?? 0, comp.minute ?? 0, comp.second ?? 0)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case .head(let head):
            self.head = head
            self.bodyBuffer = context.channel.allocator.buffer(capacity: 0)

        case .body(var byteBuffer):
            if self.bodyBuffer == nil {
                self.bodyBuffer = context.channel.allocator.buffer(
                    capacity: byteBuffer.readableBytes)
            }
            self.bodyBuffer?.writeBuffer(&byteBuffer)

        case .end:
            guard let head = self.head else { return }
            let body =
                self.bodyBuffer?.getData(at: 0, length: self.bodyBuffer?.readableBytes ?? 0)
                ?? Data()
            self.head = nil
            self.bodyBuffer = nil
            handleRequest(head: head, body: body, context: context)
        }
    }

    private func handleRequest(head: HTTPRequestHead, body: Data, context: ChannelHandlerContext) {
        let uri = head.uri
        let components = URLComponents(string: uri)
        let path = components?.path ?? uri
        let query = components?.query ?? ""
        let headers: HTTPHeaders = HTTPHeaders(
            uniqueKeysWithValues: head.headers.map { ($0.name, $0.value) })
        var request = HTTPRequest(
            method: head.method, path: path, query: query, headers: headers, body: body)
        let start = Date()
        let userId = request.authUserId.map(String.init) ?? "ANONYMOUS"

        guard let (handler, params) = routes.route(for: head.method, path: path) else {
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            let line =
                "\(Self.formatLogDate(start)) 404 \(head.method.rawValue) \(path) \(userId) \(durationMs)ms"
            if let queue = logFileWriteQueue, let filePath = logFilePath {
                queue.async {
                    try? "\(line)\n".write(toFile: filePath, atomically: true, encoding: .utf8)
                }
            } else {
                print(line)
            }
            writeResponse(
                HTTPResponse(
                    statusCode: .notFound, headers: [HTTPHeader("Content-Type"): "text/plain"],
                    body: Data("Not Found".utf8)), head: head, context: context)
            return
        }

        request.routeParameters = params

        let eventLoop = context.eventLoop
        let internalErrorResponse = HTTPResponse(
            statusCode: .internalServerError,
            headers: [HTTPHeader("Content-Type"): "application/json"],
            body: try! HTTPResponse.encoder.encode(["message": "internal server error"]))
        let promise = eventLoop.makePromise(of: HTTPResponse.self)

        promise.futureResult.whenComplete { result in
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            let response: HTTPResponse
            switch result {
            case .success(let value):
                response = value
                let statusCode = response.statusCode.code
                let line =
                    "\(Self.formatLogDate(start)) \(statusCode) \(head.method.rawValue) \(path) \(userId) \(durationMs)ms"
                if let queue = logFileWriteQueue, let filePath = logFilePath {
                    queue.async {
                        try? "\(line)\n".write(toFile: filePath, atomically: true, encoding: .utf8)
                    }
                } else {
                    print(line)
                }
            case .failure:
                response = internalErrorResponse
                let line =
                    "\(Self.formatLogDate(start)) 500 \(head.method.rawValue) \(path) \(userId) \(durationMs)ms"
                if let queue = logFileWriteQueue, let filePath = logFilePath {
                    queue.async {
                        try? "\(line)\n".write(toFile: filePath, atomically: true, encoding: .utf8)
                    }
                } else {
                    print(line)
                }
            }
            eventLoop.execute {
                self.writeResponse(response, head: head, context: context)
            }
        }

        Task {
            do {
                let response = try await handler(request)
                promise.succeed(response)
            } catch {
                promise.succeed(internalErrorResponse)
            }
        }
    }

    private func writeResponse(
        _ response: HTTPResponse, head: HTTPRequestHead, context: ChannelHandlerContext
    ) {
        var nioHeaders = NIOHTTP1.HTTPHeaders()
        for (name, value) in response.headers {
            nioHeaders.add(name: name, value: value)
        }
        nioHeaders.add(name: "Content-Length", value: "\(response.body.count)")

        let responseHead = HTTPResponseHead(
            version: head.version, status: response.statusCode, headers: nioHeaders)
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}
