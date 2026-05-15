#!/bin/bash
# fpp-servo-calibrator installer
PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Installing Animatronic Servo Calibrator plugin..."

python3 -c "import smbus2" 2>/dev/null || \
    pip3 install --quiet smbus2 2>/dev/null || \
    pip3 install --quiet --break-system-packages smbus2 2>/dev/null || \
    echo "WARNING: could not install smbus2 — install manually with: pip3 install --break-system-packages smbus2"
chmod +x "$PLUGIN_DIR/servo_ctl.py"
chmod +x "$PLUGIN_DIR/servo_daemon.py"

# ── systemd service (always write so updates stay current) ────────────────────
SERVICE="/etc/systemd/system/fpp-servo-calibrator.service"
echo "Installing systemd service..."
cat > /tmp/fpp-servo-calibrator.service << 'EOF'
[Unit]
Description=FPP Servo Calibrator Daemon
After=network.target fppd.service

[Service]
Type=simple
User=fpp
ExecStartPre=/bin/sleep 8
ExecStart=/usr/bin/python3 PLUGIN_DIR_PLACEHOLDER/servo_daemon.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
sed -i "s|PLUGIN_DIR_PLACEHOLDER|$PLUGIN_DIR|g" /tmp/fpp-servo-calibrator.service
sudo mv /tmp/fpp-servo-calibrator.service "$SERVICE"
sudo systemctl daemon-reload
sudo systemctl enable fpp-servo-calibrator.service

sudo systemctl restart fpp-servo-calibrator.service 2>/dev/null || true

# ── Stamp HEAD SHA into pluginInfo.json so FPP plugin manager shows current ───
HEAD_SHA=$(git -C "$PLUGIN_DIR" rev-parse HEAD 2>/dev/null || true)
if [ -n "$HEAD_SHA" ]; then
    python3 - << PYEOF
import json, sys
path = '$PLUGIN_DIR/pluginInfo.json'
try:
    info = json.loads(open(path).read())
    for v in info.get('versions', []):
        v['sha'] = '$HEAD_SHA'
    open(path, 'w').write(json.dumps(info, indent=4) + '\n')
    print('  pluginInfo.json sha updated to ${HEAD_SHA:0:8}')
except Exception as e:
    print(f'  WARNING: could not update pluginInfo.json sha: {e}')
PYEOF
fi

echo "Done. Access via FPP menu: Plugins > Servo Calibrator"
