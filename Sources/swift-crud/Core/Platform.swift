// Platform.swift: POSIX libc imports and helpers shared by macOS and Linux.

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Terminates the process with the given exit status.
func platformExit(_ code: Int32) -> Never {
    exit(code)
}
