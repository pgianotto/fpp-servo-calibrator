#!/bin/bash
set -euo pipefail
# fpp-servo-calibrator installer
PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Installing Animatronic Servo Calibrator plugin..."

# ── uv (fast Python package installer) — install via pip, not a curl|sh script ─
export PATH="/usr/local/bin:$HOME/.local/bin:/root/.local/bin:$PATH"
if ! command -v uv &>/dev/null; then
    echo "Installing uv..."
    # --break-system-packages is safe here: pip targets /usr/local/lib/python3.x/
    # dist-packages, which dpkg doesn't track, so it can't conflict with apt.
    python3 -m pip install --quiet --break-system-packages uv
fi

# ── smbus2 — system-wide via uv, same as FPP manages its own Python deps ──────
python3 -c "import smbus2" 2>/dev/null || {
    echo "Installing smbus2..."
    uv pip install --system --break-system-packages --quiet smbus2
}

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
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sed -i "s|PLUGIN_DIR_PLACEHOLDER|$PLUGIN_DIR|g" /tmp/fpp-servo-calibrator.service
mv /tmp/fpp-servo-calibrator.service "$SERVICE"
systemctl daemon-reload
systemctl enable fpp-servo-calibrator.service

systemctl restart fpp-servo-calibrator.service 2>/dev/null || true

# ── Apache proxy (always write so reinstalls and updates stay current) ────────
echo "Configuring Apache proxy..."
a2enmod proxy proxy_http 2>/dev/null || true
PROXY_CONF="/etc/apache2/conf-available/fpp-servo-calibrator-proxy.conf"
printf '<IfModule mod_proxy.c>\n    ProxyPass        /fpp-servo-calibrator-api/ http://localhost:5003/\n    ProxyPassReverse /fpp-servo-calibrator-api/ http://localhost:5003/\n</IfModule>\n' \
    > "$PROXY_CONF"
# Create the conf-enabled symlink directly rather than relying on a2enconf
ln -sf "$PROXY_CONF" /etc/apache2/conf-enabled/fpp-servo-calibrator-proxy.conf
systemctl reload apache2 2>/dev/null || true

# Allow root (used by FPP's plugin manager) to run git in this directory.
# Without this, git 2.35+ rejects pull/fetch from root in fpp-owned dirs.
git config --system --add safe.directory "$PLUGIN_DIR" 2>/dev/null || true

echo "Done. Access via FPP menu: Plugins > Servo Calibrator"
