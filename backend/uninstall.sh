#!/bin/bash
# Removes hatch-actions + hatch-notify. Add --purge to also delete the token, config and state.
set -uo pipefail
PORT=$(python3 -c 'import json; print(json.load(open("/etc/hatch-actions/config.json")).get("port", 8771))' 2>/dev/null || echo 8771)
systemctl disable --now hatch-actions.service hatch-notify.path hatch-notify.timer 2>/dev/null
rm -f /etc/systemd/system/hatch-actions.service /etc/systemd/system/hatch-notify.{service,path,timer}
systemctl daemon-reload
rm -f /usr/local/sbin/hatch-actions.py /usr/local/sbin/hatch-notify.py
tailscale serve --https="$PORT" off 2>/dev/null
if [ "${1:-}" = "--purge" ]; then rm -rf /etc/hatch-actions /var/lib/hatch-notify /var/log/hatch-actions.log; fi
echo "removed hatch-actions and hatch-notify"
