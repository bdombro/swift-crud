// APIRouter.swift: lightweight URL router supporting constant and :parameter segments, with convenience methods for GET/POST/PUT/DELETE registration and module-level shared routes instance.

import NIOHTTP1

private enum RouteSegment: Sendable {
    case constant(String)
    case parameter(String)
}

private struct Route: Sendable {
    let method: HTTPMethod
    let originalPath: String
    let segments: [RouteSegment]
    let handler: Handler

    init(method: HTTPMethod, path: String, handler: @escaping Handler) {
        self.method = method
        self.originalPath = path
        self.segments = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { segment in
                if segment.hasPrefix(":") {
                    return .parameter(String(segment.dropFirst()))
                } else {
                    return .constant(String(segment))
                }
            }
        self.handler = handler
    }

    func match(_ parts: [Substring]) -> [String: String]? {
        guard parts.count == segments.count else { return nil }

        var parameters: [String: String] = [:]
        for (segment, part) in zip(segments, parts) {
            switch segment {
            case .constant(let value):
                guard value == part else { return nil }
            case .parameter(let name):
                parameters[name] = String(part)
            }
        }
        return parameters
    }
}

struct Routes: Sendable {
    private var routes: [Route] = []

    mutating func get(_ path: String, handler: @escaping Handler) {
        routes.removeAll { $0.method == .GET && $0.originalPath == path }
        routes.append(Route(method: .GET, path: path, handler: handler))
    }

    mutating func post(_ path: String, handler: @escaping Handler) {
        routes.removeAll { $0.method == .POST && $0.originalPath == path }
        routes.append(Route(method: .POST, path: path, handler: handler))
    }

    mutating func put(_ path: String, handler: @escaping Handler) {
        routes.removeAll { $0.method == .PUT && $0.originalPath == path }
        routes.append(Route(method: .PUT, path: path, handler: handler))
    }

    mutating func del(_ path: String, handler: @escaping Handler) {
        routes.removeAll { $0.method == .DELETE && $0.originalPath == path }
        routes.append(Route(method: .DELETE, path: path, handler: handler))
    }

    func route(for method: HTTPMethod, path: String) -> (Handler, [String: String])? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        for route in routes {
            guard route.method == method else { continue }
            if let params = route.match(parts) {
                return (route.handler, params)
            }
        }
        return nil
    }
}

nonisolated(unsafe) var routes = Routes()
