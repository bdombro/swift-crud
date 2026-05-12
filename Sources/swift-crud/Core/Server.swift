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

    /// Blocking start — used by the app entrypoint.  Runs until the server is stopped.
    func start() async throws {
        let bootstrap = NIOTSListenerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(NIOHTTPServerHandler())
                }
            }

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(self.port)).get()
        self.channel = channel
        print("Server running on port \(port)")
        try await channel.closeFuture.get()
    }

    /// Non-blocking start — returns once the server is listening.  Suitable for tests.
    func startAndListen() async throws {
        let bootstrap = NIOTSListenerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(NIOHTTPServerHandler())
                }
            }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: Int(self.port)).get()
        self.channel = channel

        if let address = channel.localAddress {
            boundPort = UInt16(address.port ?? Int(self.port))
        }
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

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case .head(let head):
            self.head = head
            self.bodyBuffer = context.channel.allocator.buffer(capacity: 0)

        case .body(var byteBuffer):
            if self.bodyBuffer == nil {
                self.bodyBuffer = context.channel.allocator.buffer(capacity: byteBuffer.readableBytes)
            }
            self.bodyBuffer?.writeBuffer(&byteBuffer)

        case .end:
            guard let head = self.head else { return }
            let body = self.bodyBuffer?.getData(at: 0, length: self.bodyBuffer?.readableBytes ?? 0) ?? Data()
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
        let headers: HTTPHeaders = HTTPHeaders(uniqueKeysWithValues: head.headers.map { ($0.name, $0.value) })
        var request = HTTPRequest(method: head.method, path: path, query: query, headers: headers, body: body)

        guard let (handler, params) = routes.route(for: head.method, path: path) else {
            writeResponse(HTTPResponse(statusCode: .notFound, headers: [HTTPHeader("Content-Type"): "text/plain"], body: Data("Not Found".utf8)), head: head, context: context)
            return
        }

        request.routeParameters = params

        let eventLoop = context.eventLoop
        let internalErrorResponse = HTTPResponse(statusCode: .internalServerError, headers: [HTTPHeader("Content-Type"): "application/json"], body: try! HTTPResponse.encoder.encode(["message": "internal server error"]))
        let promise = eventLoop.makePromise(of: HTTPResponse.self)

        promise.futureResult.whenComplete { result in
            let response: HTTPResponse
            switch result {
            case .success(let value):
                response = value
            case .failure:
                response = internalErrorResponse
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

    private func writeResponse(_ response: HTTPResponse, head: HTTPRequestHead, context: ChannelHandlerContext) {
        var nioHeaders = NIOHTTP1.HTTPHeaders()
        for (name, value) in response.headers {
            nioHeaders.add(name: name, value: value)
        }
        nioHeaders.add(name: "Content-Length", value: "\(response.body.count)")

        let responseHead = HTTPResponseHead(version: head.version, status: response.statusCode, headers: nioHeaders)
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}
