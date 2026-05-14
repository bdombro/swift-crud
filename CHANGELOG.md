# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Bumped `swift-tools-version` to 6.3 (requires Swift 6.3+ toolchain to build).
- Hardened HTTP server (request body cap, safer JSON/logging, idempotent routes), session and SMTP behavior, `.env` quoting, and production listen address (`Server.start()` on `0.0.0.0`).
- Split `Core` into smaller files (`HTTPRequest`, `HTTPResponse`, `HTTPLimits`, `Globals`, `AccessLogger`, `SMTPEmailSender`) and moved cookie crypto to `Security/AuthCookie.swift`.

### Added
- Swift Testing suite: unit tests for `AuthCookie`, `HTTPRequest` parsing, and `Environment`; model tests for `User` and `Post` Blackbird behavior; end-to-end integration tests covering all API endpoints via an in-process server.
- More integration and unit tests for send-code IP throttling, invalid email shapes, `stripDotEnvQuotes`, and `limit=0` on list posts.


[Unreleased]: https://github.com/bdombro/swift-crud/compare/v0.4.0...HEAD
