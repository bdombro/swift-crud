#!/usr/bin/env bash
# Install, uninstall, or reinstall a systemd unit for swift-crud.
#
# Run from the project root (or any directory that holds .build/release/swift-crud
# and your .env / db.sqlite). WorkingDirectory is set to $PWD at install time.
#
# Usage:
#   ./scripts/systemd-install.sh
#   ./scripts/systemd-install.sh --reinstall
#   ./scripts/systemd-install.sh --uninstall
#
# Environment:
#   SERVICE_NAME   unit name (default: swift-crud)

set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-swift-crud}"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "Options:"
  echo "  --uninstall   stop, disable, remove the unit file, daemon-reload"
  echo "  --reinstall   --uninstall then install"
  echo "  -h, --help    show this message"
}

install_service() {
  local app_root bin
  app_root="$(pwd -P)"
  bin="${app_root}/.build/release/swift-crud"

  if [[ ! -x "${bin}" ]]; then
    echo "error: missing executable: ${bin}" >&2
    echo "hint: run 'just build' from ${app_root}" >&2
    exit 1
  fi

  sudo tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=swift-crud HTTP API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=www
Group=www
WorkingDirectory=${app_root}
ExecStart=${bin}
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=300
StartLimitBurst=5
TimeoutStopSec=30
KillSignal=SIGTERM
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${app_root}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

  sudo chmod 644 "$UNIT_PATH"
  sudo systemctl daemon-reload
  sudo systemctl enable "${SERVICE_NAME}.service"
  sudo systemctl restart "${SERVICE_NAME}.service"

  if [[ -t 1 ]]; then
    sudo systemctl --no-pager status "${SERVICE_NAME}.service"
  fi

  print_systemctl_hints
}

uninstall_service() {
  if systemctl list-unit-files "${SERVICE_NAME}.service" --no-legend 2>/dev/null | grep -q .; then
    sudo systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    sudo systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
  fi

  if [[ -f "$UNIT_PATH" ]]; then
    sudo rm -f "$UNIT_PATH"
  fi

  sudo systemctl daemon-reload
  sudo systemctl reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true

  echo "Removed ${SERVICE_NAME}.service (if it was installed)."
}

print_systemctl_hints() {
  echo
  echo "Start: sudo systemctl start ${SERVICE_NAME}.service"
  echo "Stop: sudo systemctl stop ${SERVICE_NAME}.service"
  echo "Restart: sudo systemctl restart ${SERVICE_NAME}.service"
  echo "Status: sudo systemctl status ${SERVICE_NAME}.service"
  echo "Enable: sudo systemctl enable ${SERVICE_NAME}.service"
  echo "Disable: sudo systemctl disable ${SERVICE_NAME}.service"
  echo "Daemon-reload: sudo systemctl daemon-reload"
  echo "Logs: sudo journalctl -u ${SERVICE_NAME} -f"
}

case "${1:-}" in
  -h | --help)
    usage
    ;;
  --uninstall)
    uninstall_service
    ;;
  --reinstall)
    uninstall_service
    install_service
    ;;
  "")
    install_service
    ;;
  *)
    echo "error: unknown option: ${1}" >&2
    usage >&2
    exit 1
    ;;
esac
