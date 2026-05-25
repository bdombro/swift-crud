#!/usr/bin/env bash
# Install (or refresh) a systemd unit for swift-crud.
#
# Run from the project root (or any directory that holds .build/release/swift-crud
# and your .env / db.sqlite). WorkingDirectory is set to $PWD at install time.
#
# Usage:
#   ./scripts/systemd-install.sh
#
# Environment:
#   SERVICE_NAME   unit name (default: swift-crud)

set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-swift-crud}"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

# Prints the file comment if the user runs the script with -h or --help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

APP_ROOT="$(pwd -P)"
BIN="${APP_ROOT}/.build/release/swift-crud"

sudo tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=swift-crud HTTP API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=www
Group=www
WorkingDirectory=${APP_ROOT}
ExecStart=${BIN}
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

# App reads .env and DB_PATH relative to WorkingDirectory.
ReadWritePaths=${APP_ROOT}

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$UNIT_PATH"
sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}.service"
sudo systemctl restart "${SERVICE_NAME}.service"
sudo systemctl --no-pager status "${SERVICE_NAME}.service"

echo
echo "Start: sudo systemctl start ${SERVICE_NAME}.service"
echo "Stop: sudo systemctl stop ${SERVICE_NAME}.service"
echo "Restart: sudo systemctl restart ${SERVICE_NAME}.service"
echo "Status: sudo systemctl status ${SERVICE_NAME}.service"
echo "Enable: sudo systemctl enable ${SERVICE_NAME}.service"
echo "Disable: sudo systemctl disable ${SERVICE_NAME}.service"
echo "Daemon-reload: sudo systemctl daemon-reload"
echo "Logs: sudo journalctl -u ${SERVICE_NAME} -f"
