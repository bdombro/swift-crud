set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# List all recipes (default when you run `just` with no arguments).
_:
    @just --list

# Run the application in debug mode
dev: kill
    swift run

# Compile everything in release mode (optimized binaries under `.build/release/`).
build:
    swift build -c release

# Compile the library and example executables (debug).
build-debug:
    swift build

# Will set everything up for a clean repo
init:
    just keygen-cookie-secret

# Generate a random cookie secret key and update the env.sh file
keygen-cookie-secret:
    #!/bin/bash
    KEY="$(openssl rand -base64 32)"
    sed -i '' "s|^AUTH_SECRET=.*|AUTH_SECRET=$KEY|" .env || echo "AUTH_SECRET=$KEY" >> .env

# Kill any existing server running on port 8000
kill:
    lsof -ti :8000 | xargs kill -9 || true

# Run the built binary application
run: build kill
    .build/release/swift-crud

# Run the build binary applicatin in debug mode
run-debug: build-debug kill
    .build/debug/swift-crud

# Run unit tests (`SwiftCrudTests`). On macOS, XCTest needs the full Xcode app selected (`xcode-select`), not Command Line Tools only.
test:
    swift test

# Build then run tests — quick pre-push check.
ci: build test

# Delete SwiftPM’s `.build` directory (forces a clean rebuild next time).
clean:
    rm -rf .build

# Resolve and fetch package dependencies (updates `Package.resolved` when versions change).
resolve:
    swift package resolve

# Describe the package graph (targets, products, dependencies).
describe:
    swift package describe

benchmark-init:
    brew install hey

# performance benchmark the app with a simple cookie-authenticated GET request.

# 70-85k req/s in production mode on M4 Pro macbook
benchmark-cookie:
    hey -n 10000 -c 50 -m GET \
      -H "Cookie: user_id=$USER_ID_COOKIE" \
      http://127.0.0.1:8000/api/session

# performance benchmark the app with a single DB read

# 48-57k req/s in production mode on M4 Pro macbook
benchmark-r:
    hey -n 100000 -c 50 -m GET \
      -H "Cookie: user_id=$USER_ID_COOKIE" \
      http://127.0.0.1:8000/api/posts?limit=1

# performance benchmark the app with a single DB write

# 9-11.5k req/s in production mode on M4 Pro macbook
benchmark-w:
    hey -n 50000 -c 50 -m POST \
      -H "Cookie: user_id=$USER_ID_COOKIE" \
      -H "Content-Type: application/json" \
      -d '{"content":"Benchmarking POST","variant":"note"}' \
      http://127.0.0.1:8000/api/posts

# performance benchmark the app with 1/10 writes per read
# ~3.16s, 31600r/s total, Write 3200r/s, Read 29200r/s in

# production mode on M4 Pro macbook
benchmark-rw:
    #!/bin/bash
    # Save the start time
    start_time=$(date +%s.%N)

    # Run GET and POST benchmarks simultaneously
    hey -n 90000 -c 50 -m GET \
      -H "Cookie: user_id=$USER_ID_COOKIE" \
      http://127.0.0.1:8000/api/posts?limit=1 &
    hey -n 10000 -c 50 -m POST \
      -H "Cookie: user_id=$USER_ID_COOKIE" \
      -H "Content-Type: application/json" \
      -d '{"content":"Benchmarking POST","variant":"note"}' \
      http://127.0.0.1:8000/api/posts &
    wait

    # Calculate and print the elapsed time
    end_time=$(date +%s.%N)
    elapsed_time=$(printf "%.2f" "$(bc -l <<< "${end_time} - ${start_time}")")
    req_per_sec=$(printf "%.2f" "$(bc -l <<< "100000 / ${elapsed_time}")")
    echo "Benchmark completed in ${elapsed_time} seconds"
    echo "req/s = ${req_per_sec}"
