// Server.swift: wraps a SwiftNIO HTTP server (NIOTS/NIOTransportServices) with start/stop lifecycle and async connection handler based on NIOAsyncChannel.

import Darwin
import Foundation
import NIO
import NIOHTTP1
import NIOTransportServices

private typealias HTTPConnection = NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>

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
        Task {
            try? await withThrowingTaskGroup(of: Void.self) { group in
                try await serverChannel.executeThenClose { inbound in
                    for try await connection in inbound {
                        group.addTask {
                            await self.handleConnection(connection)
                        }
                    }
                }
            }
        }
    }

    private func handleConnection(_ connection: HTTPConnection) async {
        do {
            try await handleHTTPConnection(connection)
        } catch { }
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

    /// Stops the server.
    func stop() async {
        if let channel = channel {
            try? await channel.close()
            self.channel = nil
        }
        try? await group.shutdownGracefully()
    }

    // MARK: - Connection handler

    private func handleHTTPConnection(_ connection: HTTPConnection) async throws {
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
                        case .end: break
                        }
                        if case .end = bodyPart { break }
                    }
                    await handleRequest(
                        head: head,
                        body: body.getData(at: 0, length: body.readableBytes) ?? Data(),
                        outbound: outbound
                    )
                case .body, .end:
                    break
                }
            }
        }
    }

    // MARK: - Request handling

    private func handleRequest(
        head: HTTPRequestHead,
        body: Data,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async {
        let uri = head.uri
        let qIdx = uri.firstIndex(of: "?") ?? uri.endIndex
        let path = String(uri[..<qIdx])
        let query = qIdx < uri.endIndex ? String(uri[uri.index(after: qIdx)...]) : ""
        let headers: RequestHeaders = head.headers
        var request = HTTPRequest(
            method: head.method, path: path, query: query, headers: headers, body: body)
        let start = Date()

        guard let (handler, params) = routes.route(for: head.method, path: path) else {
            logRequest(start: start, method: head.method.rawValue, path: path, userId: "ANONYMOUS", statusCode: 404)
            var notFoundHeaders = NIOHTTP1.HTTPHeaders()
            notFoundHeaders.add(name: "Content-Type", value: "text/plain")
            try? await outbound.write(contentsOf: [
                .head(.init(version: head.version, status: .notFound, headers: notFoundHeaders)),
                .body(.byteBuffer(ByteBuffer(string: "Not Found"))),
                .end(nil),
            ])
            return
        }

        request.routeParameters = params

        let response: HTTPResponse
        do {
            response = try await handler(request)
        } catch {
            response = Self.internalErrorResponse
        }

        let userIdStr = request.wasAuthChecked
            ? request.authUserId.map(String.init) ?? "ANONYMOUS"
            : "ANONYMOUS"
        logRequest(start: start, method: head.method.rawValue, path: path,
                    userId: userIdStr, statusCode: Int(response.statusCode.code))

        await writeResponse(response, head: head, outbound: outbound)
    }

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

    // MARK: - Logging

    private static func formatLogDate(_ date: Date) -> String {
        var t = time_t(date.timeIntervalSince1970)
        var tm = tm()
        gmtime_r(&t, &tm)
        return String(
            format: "%04d.%02d.%02d_%02d:%02d:%02d",
            tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
            tm.tm_hour, tm.tm_min, tm.tm_sec)
    }

    private static let internalErrorResponse = HTTPResponse(
        statusCode: .internalServerError,
        headers: [HTTPHeader("Content-Type"): "application/json"],
        body: try! HTTPResponse.encoder.encode(["message": "internal server error"]))

    private func logRequest(start: Date, method: String, path: String, userId: String, statusCode: Int) {
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        let logQueue = logFileWriteQueue ?? DispatchQueue.global(qos: .utility)
        let filePath = logFilePath
        logQueue.async {
            let line = "\(Self.formatLogDate(start)) \(statusCode) \(method) \(path) \(userId) \(durationMs)ms"
            if let path = filePath {
                try? "\(line)\n".write(toFile: path, atomically: true, encoding: .utf8)
            } else {
                print(line)
            }
        }
    }
}
