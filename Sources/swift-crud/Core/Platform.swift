// Platform.swift: POSIX libc imports and helpers shared across supported Unix targets.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Standard output file descriptor (`STDOUT_FILENO`).
let platformStdout: Int32 = STDOUT_FILENO

/// Standard error file descriptor (`STDERR_FILENO`).
let platformStderr: Int32 = STDERR_FILENO

/// Writes up to `count` bytes from `bytes` to `fd`; returns the number of bytes written.
func platformWrite(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    write(fd, bytes, count)
}

/// Registers a C signal handler (e.g. `SIGTERM`, `SIGINT`).
func platformSignal(_ signum: Int32, _ handler: @escaping @convention(c) (Int32) -> Void) {
    signal(signum, handler)
}

/// ISO 8601 UTC date/time prefix through seconds: `YYYY-MM-DDTHH:MM:SS.`
func platformTimestampPrefix(unixSecond: Int64) -> [UInt8] {
    var t = time_t(unixSecond)
    var tm = tm()
    gmtime_r(&t, &tm)
    let prefix = String(
        format: "%04d-%02d-%02dT%02d:%02d:%02d.",
        tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
        tm.tm_hour, tm.tm_min, tm.tm_sec
    )
    return Array(prefix.utf8)
}

/// Fills a `UInt32` with cryptographically secure random bytes from `/dev/urandom`.
func secureRandomUInt32() -> UInt32 {
    var value: UInt32 = 0
    withUnsafeMutableBytes(of: &value) { buffer in
        guard let base = buffer.baseAddress else { fatalError("secureRandomUInt32 buffer") }
        let fd = open("/dev/urandom", O_RDONLY)
        precondition(fd >= 0, "open /dev/urandom failed")
        defer { _ = close(fd) }
        var remaining = buffer.count
        var ptr = base
        while remaining > 0 {
            let readCount = read(fd, ptr, remaining)
            precondition(readCount > 0, "read /dev/urandom failed")
            remaining -= readCount
            ptr = ptr.advanced(by: readCount)
        }
    }
    return value
}

/// Terminates the process with the given exit status.
func platformExit(_ code: Int32) -> Never {
    exit(code)
}
