// Logger.swift: JSON-structured unified logging — lock-based, zero String allocation, ISO 8601 ms-precision timestamps.

import Foundation

enum Logger {
    enum Level: String {
        case error = "E"
        case warn  = "W"
        case info  = "I"
        case debug = "D"
    }

    // MARK: Serial queue for buffer synchronization
    private nonisolated(unsafe) static var logQueue: DispatchQueue? = nil
    private nonisolated(unsafe) static var flushTimer: DispatchSourceTimer? = nil

    // MARK: Buffers (accumulate lines, flush in batch)
    private nonisolated(unsafe) static var infoBuffer = Data()
    private nonisolated(unsafe) static var errorBuffer = Data()
    private nonisolated(unsafe) static var accessBuffer = Data()
    private static let maxBufferSize = 32768
    private static let flushIntervalMs: Int = 100

    // MARK: Timestamp cache (second-level prefix, ms appended per line)
    private nonisolated(unsafe) static var cachedTimestampPrefix: [UInt8] = []
    private nonisolated(unsafe) static var cachedTimestampSecond: Int64 = 0

    // MARK: Setup / shutdown

    static func setup() {
        Self.logQueue = DispatchQueue(label: "swift-crud.log", qos: .utility)
        Self.infoBuffer.reserveCapacity(Self.maxBufferSize)
        Self.errorBuffer.reserveCapacity(Self.maxBufferSize)
        Self.accessBuffer.reserveCapacity(Self.maxBufferSize)

        let timer = DispatchSource.makeTimerSource(queue: Self.logQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(Self.flushIntervalMs))
        timer.setEventHandler {
            Self.flushAll()
        }
        timer.resume()
        Self.flushTimer = timer
    }

    static func shutdown() {
        Self.flushTimer?.cancel()
        Self.flushTimer = nil
        Self.flushAll()
        Self.logQueue = nil
    }

    // MARK: Timestamp formatting (ISO 8601 with ms, cheap prefix cache)

    private static func cachedTimestampBytes() -> [UInt8] {
        let now = Date().timeIntervalSince1970
        let second = Int64(now)
        if second != Self.cachedTimestampSecond {
            Self.cachedTimestampPrefix = platformTimestampPrefix(unixSecond: second)
            Self.cachedTimestampSecond = second
        }
        let ms = Int((now - Double(second)) * 1000)
        var result = Self.cachedTimestampPrefix
        result.append(contentsOf: String(format: "%03dZ", ms).utf8)
        return result
    }

    // MARK: JSON escaping (O(n), reserveCapacity to avoid reallocation)

    private static func jsonEscaped(_ s: String) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(s.count + 4)
        for byte in s.utf8 {
            switch byte {
            case 0x5C: result.append(contentsOf: [0x5C, 0x5C])
            case 0x22: result.append(contentsOf: [0x5C, 0x22])
            case 0x0A: result.append(contentsOf: [0x5C, 0x6E])
            case 0x0D: result.append(contentsOf: [0x5C, 0x72])
            case 0x09: result.append(contentsOf: [0x5C, 0x74])
            case 0x00...0x07, 0x0B, 0x0C, 0x0E...0x1F:
                result.append(contentsOf: String(format: "\\u%04x", byte).utf8)
            default: result.append(byte)
            }
        }
        return result
    }

    // MARK: JSON building (no String allocation)

    private static func appendJSONLog(_ data: inout Data, message: String, level: Level, requestId: String? = nil) {
        let ts = Self.cachedTimestampBytes()
        data.append(contentsOf: [0x7B, 0x22, 0x74, 0x73, 0x22, 0x3A, 0x22])
        data.append(contentsOf: ts)
        data.append(contentsOf: [0x22, 0x2C, 0x22, 0x6C, 0x76, 0x6C, 0x22, 0x3A, 0x22])
        data.append(contentsOf: level.rawValue.utf8)
        data.append(contentsOf: [0x22, 0x2C, 0x22, 0x6D, 0x73, 0x67, 0x22, 0x3A, 0x22])
        data.append(contentsOf: Self.jsonEscaped(message))
        if let rid = requestId {
            data.append(contentsOf: [0x22, 0x2C, 0x22, 0x72, 0x65, 0x71, 0x22, 0x3A, 0x22])
            data.append(contentsOf: rid.utf8)
        }
        data.append(contentsOf: [0x22, 0x7D, 0x0A])
    }

    private static func appendJSONAccess(_ data: inout Data, method: String, path: String, userId: String, statusCode: Int, durationMs: Int, requestId: String? = nil) {
        let ts = Self.cachedTimestampBytes()
        data.append(contentsOf: [0x7B, 0x22, 0x74, 0x73, 0x22, 0x3A, 0x22])
        data.append(contentsOf: ts)
        data.append(contentsOf: [0x22, 0x2C, 0x22, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x22, 0x3A])
        data.append(contentsOf: String(statusCode).utf8)
        data.append(contentsOf: [0x2C, 0x22, 0x6D, 0x65, 0x74, 0x68, 0x6F, 0x64, 0x22, 0x3A, 0x22])
        data.append(contentsOf: method.utf8)
        data.append(contentsOf: [0x22, 0x2C, 0x22, 0x70, 0x61, 0x74, 0x68, 0x22, 0x3A, 0x22])
        data.append(contentsOf: Self.jsonEscaped(path))
        data.append(contentsOf: [0x22, 0x2C, 0x22, 0x75, 0x73, 0x65, 0x72, 0x22, 0x3A, 0x22])
        data.append(contentsOf: userId.utf8)
        if let rid = requestId {
            data.append(contentsOf: [0x22, 0x2C, 0x22, 0x72, 0x65, 0x71, 0x22, 0x3A, 0x22])
            data.append(contentsOf: rid.utf8)
        }
        data.append(contentsOf: [0x22, 0x2C, 0x22, 0x64, 0x75, 0x72, 0x22, 0x3A])
        data.append(contentsOf: String(durationMs).utf8)
        data.append(contentsOf: [0x7D, 0x0A])
    }

    // MARK: Convenience methods

    static func info(_ message: String) {
        Self.log(message, level: .info)
    }

    static func error(_ message: String) {
        Self.log(message, level: .error)
    }

    /// Writes a human-readable line to stderr and exits with status 1.
    /// Use for startup failures before the async log flush loop is running.
    static func fatal(_ message: String) -> Never {
        var data = Data("swift-crud: ".utf8)
        data.append(contentsOf: message.utf8)
        data.append(0x0A)
        data.withUnsafeBytes { ptr in
            _ = platformWrite(platformStderr, ptr.baseAddress!, ptr.count)
        }
        platformExit(1)
    }

    // MARK: General log (outputs NDJSON via queue+append)

    static func log(_ message: String, level: Level = .info) {
        let queue = Self.logQueue ?? DispatchQueue.global(qos: .utility)
        queue.async {
            var buf = Data()
            appendJSONLog(&buf, message: message, level: level)
            if level == .error {
                Self.errorBuffer.append(buf)
                if Self.errorBuffer.count >= Self.maxBufferSize {
                    Self.flushBuffer(&Self.errorBuffer, to: platformStderr)
                }
            } else {
                Self.infoBuffer.append(buf)
                if Self.infoBuffer.count >= Self.maxBufferSize {
                    Self.flushBuffer(&Self.infoBuffer, to: platformStdout)
                }
            }
        }
    }

    // MARK: Access log

    static func access(start: Date, method: String, path: String, userId: String, statusCode: Int, requestId: String? = nil) {
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        let queue = Self.logQueue ?? DispatchQueue.global(qos: .utility)
        queue.async {
            var buf = Data()
            appendJSONAccess(&buf, method: method, path: path, userId: userId, statusCode: statusCode, durationMs: durationMs, requestId: requestId)
            Self.accessBuffer.append(buf)
            if Self.accessBuffer.count >= Self.maxBufferSize {
                Self.flushBuffer(&Self.accessBuffer, to: platformStdout)
            }
        }
    }

    // MARK: Buffer flushing

    private static func flushBuffer(_ buffer: inout Data, to fd: Int32) {
        guard !buffer.isEmpty else { return }
        buffer.withUnsafeBytes { ptr in
            _ = platformWrite(fd, ptr.baseAddress!, ptr.count)
        }
        buffer.removeAll(keepingCapacity: true)
    }

    private static func flushAll() {
        Self.flushBuffer(&Self.infoBuffer, to: platformStdout)
        Self.flushBuffer(&Self.errorBuffer, to: platformStderr)
        Self.flushBuffer(&Self.accessBuffer, to: platformStdout)
    }
}
