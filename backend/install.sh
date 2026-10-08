#!/bin/bash
# Installs hatch-actions + hatch-notify on the server. Run as root, from this folder:
#   bash install.sh
# Idempotent: re-running updates the code and units, keeps your token and config.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

install -d -m 750 /etc/hatch-actions /var/lib/hatch-notify
install -m 755 "$D/hatch-actions.py" /usr/local/sbin/hatch-actions.py
install -m 755 "$D/hatch-notify.py"  /usr/local/sbin/hatch-notify.py

if [ ! -s /etc/hatch-actions/token ]; then
  python3 -c 'import secrets; print(secrets.token_hex(24))' > /etc/hatch-actions/token
  chmod 600 /etc/hatch-actions/token
  echo "generated token"
fi
if [ ! -s /etc/hatch-actions/config.json ]; then
  install -m 640 "$D/config.example.json" /etc/hatch-actions/config.json
  echo "installed default config"
fi
# Drop allow-listed scripts whose unit doesn't exist on this box, so the app never shows a dead button.
python3 - <<'PY'
import json, subprocess
p = "/etc/hatch-actions/config.json"
cfg = json.load(open(p))
keep = []
for s in cfg.get("scripts", []):
    rc = subprocess.run(["systemctl", "cat", s["unit"]], capture_output=True).returncode
    (keep if rc == 0 else []).append(s)
    if rc != 0: print("skipping %s: unit %s not found" % (s["id"], s["unit"]))
cfg["scripts"] = keep
json.dump(cfg, open(p, "w"), indent=2)
print("%d scripts allow-listed" % len(keep))
PY

install -m 644 "$D/systemd/hatch-actions.service" /etc/systemd/system/
install -m 644 "$D/systemd/hatch-notify.service"  /etc/systemd/system/
install -m 644 "$D/systemd/hatch-notify.path"     /etc/systemd/system/
install -m 644 "$D/systemd/hatch-notify.timer"    /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now hatch-actions.service hatch-notify.path hatch-notify.timer
systemctl restart hatch-actions.service
systemctl start hatch-notify.service || true

# Publish over the tailnet with the node's TLS cert (tailnet-only; Funnel is NOT enabled).
PORT=$(python3 -c 'import json; print(json.load(open("/etc/hatch-actions/config.json")).get("port", 8771))')
tailscale serve --bg --https="$PORT" "http://127.0.0.1:$PORT" >/dev/null
sleep 1
HOST=$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
echo
echo "hatch-actions:  https://$HOST:$PORT   ($(systemctl is-active hatch-actions.service))"
echo "hatch-notify:   path unit $(systemctl is-active hatch-notify.path) · timer $(systemctl is-active hatch-notify.timer)"
echo "token:          /etc/hatch-actions/token  (copy to ~/Library/Application Support/HatchMap/actions-token on the Mac)"
curl -s -m 5 "http://127.0.0.1:$PORT/ping" && echo
