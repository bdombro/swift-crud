// main.swift: application entry point — wires up environment, database, email sender, routes, and starts the HTTP server.

import Blackbird
import Darwin
import Foundation

/// Serial queue used to bridge C signal handlers into the async world.
private let signalQueue = DispatchQueue(label: "swift-crud.signal")

/// Set by C signal handlers when SIGTERM / SIGINT is received.
/// Read-only by async code via the polling loop on signalQueue.
private var shutdownRequested = false

// Installed at module init time (before main()). Can only set the global flag.
signal(SIGTERM) { _ in
    shutdownRequested = true
    signalQueue.async {}
}

signal(SIGINT) { _ in
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

func main() async throws {
    let env = Environment()

    guard env.authSecret != "change-me" else {
        fatalError(
            "AUTH_SECRET environment variable must be set. Run `just keygen-cookie-secret` to generate one."
        )
    }

    var dbOptions: Blackbird.Database.Options = []
    if env.dbDebug { dbOptions.insert(.debugPrintEveryQuery) }

    let dbUrl = URL(fileURLWithPath: env.dbPath)
    let database = try Blackbird.Database(path: dbUrl.path, options: dbOptions)

    // Ensure Blackbird creates tables before any requests arrive
    try await User.resolveSchema(in: database)
    try await Post.resolveSchema(in: database)

    let sender = makeEmailSender(from: env)
    activeAuthSecret = env.authSecret
    emailSender = sender
    db = database

    if let logFile = env.logFile {
        logFileWriteQueue = DispatchQueue(label: "swift-crud.access-log", qos: .utility)
        logFilePath = logFile
    }

    registerPostRoutes()
    registerSessionRoutes()
    registerHealthRoutes()

    let server = Server(port: env.port)

    // Non-blocking start — server is listening but we don't block here
    try await server.startAndListen()
    print("Server running on port \(env.port)")
    if logFileWriteQueue != nil, let path = logFilePath {
        print("Request logs: \(path)")
    }

    // Wait for SIGTERM / SIGINT — then initiate graceful shutdown
    await waitForShutdownSignal()
    print("Shutting down gracefully...")

    await server.stop()
    print("Server stopped.")
}

try await main()
