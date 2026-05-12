# Contributing

Thanks for your interest in **swift-crud**.

## Development

This repo uses **[just](https://github.com/casey/just)** ([`justfile`](justfile)) for common tasks. Install `just` (for example `brew install just` on macOS), then from the repo root:

- **Build:** `just build` (optimized: `just build-release`)
- **Run examples:**  
  `just example-minimal-help`  
  `just example-nested-lookup-help`  
  For arbitrary arguments, use `just run-minimal …` or `just run-nested …`. If a flag would be parsed by `just` instead of the demo, put `--` before the program’s arguments (for example `just run-minimal -- --help`).
- **Tests:** `just test`  
  On macOS, **XCTest** requires the full Xcode toolchain (not only Command Line Tools). If tests fail with `no such module 'XCTest'`, install Xcode and run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, or run tests from Xcode.
- **Other recipes:** `just` with no arguments lists everything defined in the `justfile` (for example `just ci` for build + test, `just clean`, `just resolve`).

## Pull requests

- Keep behavior aligned with **swift-crud** unless explicitly documented otherwise.
- Add or update tests for parsing and validation changes.
- Run `just ci` (or `just build` and `just test`) before submitting.

## Code of conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
