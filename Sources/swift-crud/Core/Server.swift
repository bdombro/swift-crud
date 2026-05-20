// Server.swift: wraps a SwiftNIO HTTP server (NIOTS/NIOTransportServices) with start/stop lifecycle and async connection handler based on NIOAsyncChannel.

import Foundation
import NIO
import NIOCore
import NIOHTTP1
import NIOTransportServices

private typealias HTTPConnection = NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>

/// Tracks in-flight HTTP connections for graceful shutdown draining.
private actor ConnectionCounter {
    private var count = 0

    /// Records a new active connection.
    func increment() { count += 1 }

    /// Records that a connection finished handling.
    func decrement() { count -= 1 }

    /// Number of connections still processing a request.
    var current: Int { count }
}

final class Server: @unchecked Sendable {
    let port: UInt16
    private let group: EventLoopGroup
    private var channel: Channel?
    private var listenTask: Task<Void, Never>?
    private var groupIsShutdown = false
    private let connectionCounter = ConnectionCounter()

    /// The port the HTTP server actually bound to (may differ from `port` when port 0 is used).
    private(set) var boundPort: UInt16?

    /// Creates a server that will listen on `port` once `start()` or `startAndListen()` is called.
    init(port: UInt16) {
        self.port = port
        self.group = NIOTSEventLoopGroup()
    }

    /// Shuts down the event loop group if the server was not stopped explicitly.
    deinit {
        if !groupIsShutdown {
            try? group.syncShutdownGracefully()
        }
    }

    /// Blocking start — used by the app entrypoint. Binds to 0.0.0.0 and runs until stopped.
    func start() async throws {
        let serverChannel = try await bind(host: "0.0.0.0")
        try await withThrowingTaskGroup(of: Void.self) { group in
            try await serverChannel.executeThenClose { inbound in
                for try await connection in inbound {
                    group.addTask {
                        await self.handleConnection(connection)
                    }
                }
            }
        }
    }

    /// Non-blocking start — binds to 127.0.0.1 and returns immediately. For tests.
    func startAndListen() async throws {
        let serverChannel = try await bind(host: "127.0.0.1")
        listenTask = Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    try await serverChannel.executeThenClose { inbound in
                        for try await connection in inbound {
                            group.addTask {
                                await self.handleConnection(connection)
                            }
                        }
                    }
                }
            } catch {
                // Test server: accept loop ended or failed; errors are surfaced via channel close.
            }
        }
    }

    /// Accepts one TCP connection, runs the HTTP handler, and updates the connection counter for shutdown.
    private func handleConnection(_ connection: HTTPConnection) async {
        await connectionCounter.increment()
        defer { Task { await connectionCounter.decrement() } }
        do {
            try await handleHTTPConnection(connection)
        } catch let error as ChannelError where error == .inputClosed || error == .outputClosed {
            // Normal client half-close / full-close — not a server fault.
        } catch is CancellationError {
        } catch {
            Logger.access(
                start: Date(), method: "-", path: "-", userId: "ANONYMOUS", statusCode: 500)
        }
    }

    /// Internal bind helper — shared by both start modes.
    private func bind(host: String) async throws -> NIOAsyncChannel<HTTPConnection, Never> {
        let serverChannel = try await NIOTSListenerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: Int(port)) { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMapThrowing { _ in
                    try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(
                            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark(
                                lowWatermark: 8, highWatermark: 16
                            ),
                            isOutboundHalfClosureEnabled: true,
                            inboundType: HTTPServerRequestPart.self,
                            outboundType: HTTPServerResponsePart.self
                        )
                    )
                }
            }
        self.channel = serverChannel.channel
        if let address = serverChannel.channel.localAddress {
            boundPort = UInt16(address.port ?? Int(self.port))
        }
        return serverChannel
    }

    /// Graceful shutdown — stops accepting new connections, drains in-flight requests up to `timeout` seconds.
    func shutdownGracefully(timeout: TimeInterval = 15) async {
        if let channel = channel {
            try? await channel.close()
            self.channel = nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while await connectionCounter.current > 0 && Date() < deadline {
            await Task.yield()
        }

        listenTask?.cancel()
        listenTask = nil

        try? await group.shutdownGracefully()
        groupIsShutdown = true
    }

    /// Stops the server.
    func stop() async {
        listenTask?.cancel()
        listenTask = nil
        if let channel = channel {
            try? await channel.close()
            self.channel = nil
        }
        try? await group.shutdownGracefully()
        groupIsShutdown = true
    }

    // MARK: - Connection handler

    /// Reads request parts from a connection, enforces the body size limit, and dispatches each request.
    private func handleHTTPConnection(_ connection: HTTPConnection) async throws {
        let remoteDesc = connection.channel.remoteAddress.map { String(describing: $0) }
        try await connection.executeThenClose { inbound, outbound in
            var iterator = inbound.makeAsyncIterator()
            while let part = try await iterator.next() {
                switch part {
                case .head(let head):
                    var body = connection.channel.allocator.buffer(capacity: 0)
                    while let bodyPart = try await iterator.next() {
                        switch bodyPart {
                        case .head: break
                        case .body(var buf):
                            body.writeBuffer(&buf)
                            if body.readableBytes > HTTPLimits.maxRequestBodyBytes {
                                var plHeaders = NIOHTTP1.HTTPHeaders()
                                plHeaders.add(name: "Content-Type", value: "text/plain")
                                try? await outbound.write(contentsOf: [
                                    .head(
                                        .init(
                                            version: head.version, status: .payloadTooLarge,
                                            headers: plHeaders)),
                                    .body(.byteBuffer(ByteBuffer(string: "Request body too large"))),
                                    .end(nil),
                                ])
                                return
                            }
                        case .end: break
                        }
                        if case .end = bodyPart { break }
                    }
                    await handleRequest(
                        head: head,
                        body: body.getData(at: 0, length: body.readableBytes) ?? Data(),
                        remoteAddress: remoteDesc,
                        outbound: outbound
                    )
                case .body, .end:
                    break
                }
            }
        }
    }

    // MARK: - Request handling

    /// Routes one HTTP request: CORS preflight, 404, handler dispatch, CORS on the response, access log, write.
    private func handleRequest(
        head: HTTPRequestHead,
        body: Data,
        remoteAddress: String?,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async {
        let uri = head.uri
        let qIdx = uri.firstIndex(of: "?") ?? uri.endIndex
        let path = String(uri[..<qIdx])
        let query = qIdx < uri.endIndex ? String(uri[uri.index(after: qIdx)...]) : ""
        let headers: RequestHeaders = head.headers
        var request = HTTPRequest(
            method: head.method, path: path, query: query, headers: headers, body: body,
            remoteAddress: remoteAddress)
        request.requestId = Data((0..<8).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString().trimmingCharacters(in: ["="])
        let start = Date()

        if let preflight = CORS.preflightResponse(for: request) {
            Logger.access(
                start: start, method: head.method.rawValue, path: path, userId: "ANONYMOUS",
                statusCode: Int(preflight.statusCode.code), requestId: request.requestId)
            await writeResponse(preflight, head: head, outbound: outbound)
            return
        }

        guard let (handler, params) = routes.route(for: head.method, path: path) else {
            Logger.access(
                start: start, method: head.method.rawValue, path: path, userId: "ANONYMOUS",
                statusCode: 404, requestId: request.requestId)
            var notFound = HTTPResponse(
                statusCode: .notFound,
                headers: [HTTPHeader("Content-Type"): "text/plain"],
                body: Data("Not Found".utf8))
            CORS.apply(to: &notFound, request: request)
            await writeResponse(notFound, head: head, outbound: outbound)
            return
        }

        request.routeParameters = params

        var response: HTTPResponse
        do {
            response = try await handler(request)
        } catch {
            response = Self.internalErrorResponse
        }
        CORS.apply(to: &response, request: request)

        let userIdStr = request.wasAuthChecked
            ? request.authUserId.map(String.init) ?? "ANONYMOUS"
            : "ANONYMOUS"
        Logger.access(
            start: start, method: head.method.rawValue, path: path, userId: userIdStr,
            statusCode: Int(response.statusCode.code), requestId: request.requestId)

        await writeResponse(response, head: head, outbound: outbound)
    }

    /// Serializes an `HTTPResponse` (including handler and CORS headers) onto the NIO outbound channel.
    private func writeResponse(
        _ response: HTTPResponse,
        head: HTTPRequestHead,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async {
        var nioHeaders = NIOHTTP1.HTTPHeaders()
        for (name, value) in response.headers {
            nioHeaders.add(name: name, value: value)
        }
        nioHeaders.add(name: "Content-Length", value: "\(response.body.count)")
        let responseHead = HTTPResponseHead(
            version: head.version, status: response.statusCode, headers: nioHeaders)
        let bodyBuffer = ByteBuffer(bytes: response.body)
        try? await outbound.write(contentsOf: [
            .head(responseHead),
            .body(.byteBuffer(bodyBuffer)),
            .end(nil),
        ])
    }

    private static let internalErrorResponse: HTTPResponse = {
        let body =
            (try? HTTPResponse.encoder.encode(["message": "internal server error"]))
            ?? Data(#"{"message":"internal server error"}"#.utf8)
        return HTTPResponse(
            statusCode: .internalServerError,
            headers: [HTTPHeader("Content-Type"): "application/json"],
            body: body)
    }()
}
