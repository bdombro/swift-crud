// main.swift: application entry point — wires up environment, database, email sender, routes, and starts the HTTP server.

import Blackbird
import Foundation
import NIO

/// Serial queue used to bridge C signal handlers into the async world.
private let signalQueue = DispatchQueue(label: "swift-crud.signal")

/// Set by C signal handlers when SIGTERM / SIGINT is received.
/// Read-only by async code via the polling loop on signalQueue.
private nonisolated(unsafe) var shutdownRequested = false

// Installed at module init time (before main()). Can only set the global flag.
platformSignal(SIGTERM) { _ in
    shutdownRequested = true
    signalQueue.async {}
}

platformSignal(SIGINT) { _ in
    shutdownRequested = true
    signalQueue.async {}
}

/// Block until a signal is received, then return.
func waitForShutdownSignal() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        signalQueue.async {
            while !shutdownRequested {
                Thread.sleep(forTimeInterval: 0.05)
            }
            continuation.resume()
        }
    }
}

/// Application bootstrap: load environment and validate secrets, open SQLite and ensure schemas,
/// configure globals (email, DB, auth, session cookie, CORS), register routes, start the HTTP server,
/// then block until SIGTERM/SIGINT and shut down the server and optional SMTP resources gracefully.
func main() async throws {
    let env = Environment()

    guard env.authSecret != "change-me" else {
        Logger.fatal(
            "AUTH_SECRET must be set (e.g. in .env). Run `just keygen-cookie-secret` to generate one."
        )
    }

    var dbOptions: Blackbird.Database.Options = []
    if env.dbDebug { dbOptions.insert(.debugPrintEveryQuery) }

    let dbUrl = URL(fileURLWithPath: env.dbPath)
    let database = try Blackbird.Database(path: dbUrl.path, options: dbOptions)

    // Ensure Blackbird creates tables before any requests arrive
    try await User.resolveSchema(in: database)
    try await Post.resolveSchema(in: database)

    if env.smtpHost != nil, env.smtpUsername != nil, env.smtpPassword != nil, env.smtpFrom != nil {
        smtpEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }
    let sender = makeEmailSender(from: env)
    activeAuthSecret = env.authSecret
    cookieDomain = env.cookieDomain
    cookieSecure = env.cookieSecure
    corsAllowedOrigins = env.corsAllowedOrigins
    emailSender = sender
    db = database

    Logger.setup()

    registerRoutes()

    let server = Server(port: env.port)

    Task {
        do {
            try await server.start()
        } catch {
            Logger.fatal("HTTP server stopped with error — \(error)")
        }
    }

    var bindWait = 0
    while server.boundPort == nil && bindWait < 500 {
        try await Task.sleep(nanoseconds: 1_000_000)
        bindWait += 1
    }
    guard server.boundPort != nil else {
        Logger.fatal("Server did not bind to port \(env.port)")
    }

    Logger.info("Server running on port \(env.port)")

    // Wait for SIGTERM / SIGINT — then initiate graceful shutdown
    await waitForShutdownSignal()
    Logger.info("Shutting down gracefully...")

    await server.stop()
    Logger.shutdown()
    if let smtp = emailSender as? SMTPEmailSender {
        await smtp.shutdown()
    }
    if let smtpGroup = smtpEventLoopGroup {
        try? await smtpGroup.shutdownGracefully()
        smtpEventLoopGroup = nil
    }
    Logger.info("Server stopped.")
}

do {
    try await main()
} catch {
    Logger.fatal("Startup failed — \(error)")
}
