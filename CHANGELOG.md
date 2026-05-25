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
- `scripts/systemd-install.sh` installs a systemd unit with `WorkingDirectory` set to the install-time `$PWD`, `ExecStart` pointing at `.build/release/swift-crud`, and the service running as `www`.
- `just systemd-*` recipes wrap the install script and common `systemctl` / `journalctl` commands (`SERVICE_NAME` overrides the unit name).
- Optional `SMTP_FROM_NAME` for a display name on outgoing login-code emails (`From: "Name" <addr>`).
- Linux support (same POSIX NIO stack as macOS).

### Fixed
- SMTP client no longer hangs on replies ending in CRLF; connect/read timeouts, `SMTP_TLS_SERVERNAME` for MX hosts, and handler error logging added.
- Startup failures (missing `AUTH_SECRET`, bind errors, etc.) print a line to stderr and exit with status 1 instead of exiting silently.
- Linux build: use `swift-crypto` (`import Crypto`) for HMAC cookies and login code hashing on all platforms.
- Linux build: generate login codes via `secureRandomUInt32()` (`/dev/urandom`) on all platforms.

### Changed
- POSIX libc usage is centralized in `Platform.swift`; app code no longer branches on `CryptoKit` vs `Crypto` or macOS-only Security APIs.

[Unreleased]: https://github.com/bdombro/swift-crud/compare/v0.4.0...HEAD
