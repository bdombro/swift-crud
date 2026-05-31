# List all recipes (default when you run `just` with no arguments).
_:
    @just --list


# Compile everything in release mode (optimized binaries under `.build/release/`).
build:
    swift build -c release --static-swift-stdlib

# Compile the library and example executables (debug).
build-debug:
    swift build

# Deploy the application to the production server
deploy:
  git push
  ssh contabo 'bash -lc "cd /www/wwwroot/toodyapp.com/backend && git pull && just systemd-upgrade"'

# Will set everything up for a clean repo
init:
    just keygen-cookie-secret

# Generate a random cookie secret key and update the env.sh file
keygen-cookie-secret:
    #!/bin/bash
    KEY="$(openssl rand -base64 32)"
    perl -i -pe "s|^AUTH_SECRET=.*|AUTH_SECRET=$KEY|" .env || echo "AUTH_SECRET=$KEY" >> .env


# Kill any existing server running on port 8222
kill:
    lsof -ti :8222 | xargs kill -9 || true

alias start := run
# Run the built binary application
run: build kill
    .build/release/swift-crud

# Run the build binary applicatin in debug mode
run-debug: build-debug kill
    .build/debug/swift-crud

alias dev := run-dev
# Run the application in dev mode
run-dev: kill
    swift run

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



########################################################
# Systemd
########################################################


# systemd unit name (override: `SERVICE_NAME=my-api just systemd-start`)
systemd_service := env_var_or_default("SERVICE_NAME", "swift-crud")

# Install or refresh the systemd unit (Linux; run from project root).
systemd-install:
    ./scripts/systemd-install.sh

# Reinstall the systemd unit (Linux; run from project root).
systemd-reinstall:
    ./scripts/systemd-install.sh --reinstall

# Uninstall the systemd unit (Linux; run from project root).
systemd-uninstall:
    ./scripts/systemd-install.sh --uninstall

# Pulls latest, rebuilds, and restarts the systemd service.
systemd-upgrade:
    just build
    just systemd-restart
    just systemd-status

# Start the installed systemd service.
systemd-start:
    sudo systemctl start {{ systemd_service }}.service

# Stop the installed systemd service.
systemd-stop:
    sudo systemctl stop {{ systemd_service }}.service

# Restart the installed systemd service.
systemd-restart:
    sudo systemctl restart {{ systemd_service }}.service

# Show systemd service status.
systemd-status:
    sudo systemctl status {{ systemd_service }}.service

# Enable the service to start on boot.
systemd-enable:
    sudo systemctl enable {{ systemd_service }}.service

# Disable the service from starting on boot.
systemd-disable:
    sudo systemctl disable {{ systemd_service }}.service

# Reload systemd unit files after editing a `.service` file.
systemd-daemon-reload:
    sudo systemctl daemon-reload

# Follow journal logs for the service.
systemd-logs:
    @# sudo journalctl -u swift-crud -n 100      # last 100 lines
    @# sudo journalctl -u swift-crud --since today
    sudo journalctl -u {{ systemd_service }} -f




########################################################
# Benchmarking
########################################################

benchmark-init:
    brew install hey

# performance benchmark the app with a simple cookie-authenticated GET request.

# 70-85k req/s in production mode on M4 Pro macbook
benchmark-healthz:
    hey -n 10000 -c 50 -m GET \
      http://127.0.0.1:8222/healthz

# 70-85k req/s in production mode on M4 Pro macbook
benchmark-cookie USER_ID_COOKIE="1.e3ZM4zjWAZGDR/Y2wLiJU+BuFNS3LNWgNT6tu9Nk46A=":
    hey -n 10000 -c 50 -m GET \
      -H "Cookie: user_id={{ USER_ID_COOKIE }}" \
      http://127.0.0.1:8222/api/session

# performance benchmark the app with a single DB read

# 48-57k req/s in production mode on M4 Pro macbook
benchmark-r USER_ID_COOKIE="1.e3ZM4zjWAZGDR/Y2wLiJU+BuFNS3LNWgNT6tu9Nk46A=":
    hey -n 100000 -c 50 -m GET \
      -H "Cookie: user_id={{ USER_ID_COOKIE }}" \
      http://127.0.0.1:8222/api/posts?limit=1

# performance benchmark the app with a single DB write

# 9-11.5k req/s in production mode on M4 Pro macbook
benchmark-w USER_ID_COOKIE="1.e3ZM4zjWAZGDR/Y2wLiJU+BuFNS3LNWgNT6tu9Nk46A=":
    hey -n 50000 -c 50 -m POST \
      -H "Cookie: user_id={{ USER_ID_COOKIE }}" \
      -H "Content-Type: application/json" \
      -d '{"content":"Benchmarking POST","variant":"note"}' \
      http://127.0.0.1:8222/api/posts

# performance benchmark the app with 1/10 writes per read
# ~3.16s, 31600r/s total, Write 3200r/s, Read 29200r/s in

# production mode on M4 Pro macbook
benchmark-rw USER_ID_COOKIE="1.e3ZM4zjWAZGDR/Y2wLiJU+BuFNS3LNWgNT6tu9Nk46A=":
    #!/bin/bash
    # Save the start time
    start_time=$(date +%s.%N)

    # Run GET and POST benchmarks simultaneously
    hey -n 90000 -c 50 -m GET \
      -H "Cookie: user_id={{ USER_ID_COOKIE }}" \
      http://127.0.0.1:8222/api/posts?limit=1 &
    hey -n 10000 -c 50 -m POST \
      -H "Cookie: user_id={{ USER_ID_COOKIE }}" \
      -H "Content-Type: application/json" \
      -d '{"content":"Benchmarking POST","variant":"note"}' \
      http://127.0.0.1:8222/api/posts &
    wait

    # Calculate and print the elapsed time
    end_time=$(date +%s.%N)
    elapsed_time=$(printf "%.2f" "$(bc -l <<< "${end_time} - ${start_time}")")
    req_per_sec=$(printf "%.2f" "$(bc -l <<< "100000 / ${elapsed_time}")")
    echo "Benchmark completed in ${elapsed_time} seconds"
    echo "req/s = ${req_per_sec}"
