// SMTPConnectionTests.swift: verifies the SMTP client keeps one session alive, reuses it, and reconnects after server drop.

import Foundation
import NIO
import Testing
@testable import swift_crud

@Suite("SMTP persistent connection")
struct SMTPConnectionTests {
    private func plainConfig(host: String, port: UInt16) -> SMTPConnectionConfig {
        SMTPConnectionConfig(
            host: host,
            port: port,
            username: "",
            password: "",
            tlsMode: .none,
            tlsInsecure: false,
            timeoutSeconds: 10,
            tlsServerName: nil)
    }

    @Test("connectForTesting completes EHLO on plaintext test server")
    func handshakes() async throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await TestSMTPServer.start(group: serverGroup)

        let config = plainConfig(host: "127.0.0.1", port: UInt16(server.port))
        let connection = SMTPConnection(config: config, group: clientGroup, ownsGroup: false)
        try await connection.connectForTesting()
        #expect(server.ehloCount == 1)
        await connection.shutdown()

        try await server.close()
        try await clientGroup.shutdownGracefully()
        try await serverGroup.shutdownGracefully()
    }

    @Test("two sendMail calls reuse one TCP connection")
    func reusesConnection() async throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await TestSMTPServer.start(group: serverGroup)

        let config = plainConfig(host: "127.0.0.1", port: UInt16(server.port))
        let sender = SMTPEmailSender.smtp(
            config: config, group: clientGroup, ownsGroup: false, from: "from@test.local", fromName: nil)

        try await sender.send(code: "12345678", to: "a@example.com")
        try await sender.send(code: "87654321", to: "b@example.com")
        await sender.shutdown()

        #expect(server.tcpConnectionCount == 1)
        #expect(server.messagesAccepted == 2)
        #expect(server.rsetCount >= 1)

        try await server.close()
        try await clientGroup.shutdownGracefully()
        try await serverGroup.shutdownGracefully()
    }

    @Test("sendMail opens a new TCP connection after the server drops the session")
    func reconnectsAfterDrop() async throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await TestSMTPServer.start(group: serverGroup)

        let config = plainConfig(host: "127.0.0.1", port: UInt16(server.port))
        let connection = SMTPConnection(config: config, group: clientGroup, ownsGroup: false)
        let body = SMTPEmailSender.buildMessage(
            code: "11111111", to: "u@example.com", from: "from@test.local", fromName: nil)

        try await connection.sendMail(from: "from@test.local", message: body, recipient: "u@example.com")
        #expect(server.tcpConnectionCount == 1)

        try await server.restart()

        let body2 = SMTPEmailSender.buildMessage(
            code: "22222222", to: "v@example.com", from: "from@test.local", fromName: nil)
        try await connection.sendMail(from: "from@test.local", message: body2, recipient: "v@example.com")

        #expect(server.tcpConnectionCount == 2)
        #expect(server.messagesAccepted == 2)
        await connection.shutdown()

        try await server.close()
        try await clientGroup.shutdownGracefully()
        try await serverGroup.shutdownGracefully()
    }
}