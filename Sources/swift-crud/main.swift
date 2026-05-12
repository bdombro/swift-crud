// main.swift: application entry point — wires up environment, database, email sender, routes, and starts the HTTP server.

import Blackbird
import Foundation

func main() async throws {
    let env = Environment()

    guard env.authSecret != "change-me" else {
        fatalError("AUTH_SECRET environment variable must be set. Run `just keygen-cookie-secret` to generate one.")
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

    registerPostRoutes()
    registerSessionRoutes()

    let server = Server(port: env.port)
    try await server.start()
}

try await main()
