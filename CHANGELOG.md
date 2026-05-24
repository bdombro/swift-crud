# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Default HTTP port is `8222` (was `8000`).
- Login codes are 8-digit decimal numbers (zero-padded); docs and email copy updated accordingly.
- HTTP server uses POSIX NIO (`ServerBootstrap` / `MultiThreadedEventLoopGroup`) on all platforms; dropped NIO Transport Services.

### Added
- Linux support (same POSIX NIO stack as macOS).

### Fixed
- Linux build: use `swift-crypto` (`import Crypto`) for HMAC cookies and login code hashing on all platforms.
- Linux build: generate login codes via `secureRandomUInt32()` (`/dev/urandom`) on all platforms.

### Changed
- POSIX libc usage is centralized in `Platform.swift`; app code no longer branches on `CryptoKit` vs `Crypto` or macOS-only Security APIs.

[Unreleased]: https://github.com/bdombro/swift-crud/compare/v0.4.0...HEAD
