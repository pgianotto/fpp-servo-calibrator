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
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sed -i "s|PLUGIN_DIR_PLACEHOLDER|$PLUGIN_DIR|g" /tmp/fpp-servo-calibrator.service
sudo mv /tmp/fpp-servo-calibrator.service "$SERVICE"
sudo systemctl daemon-reload
sudo systemctl enable fpp-servo-calibrator.service

sudo systemctl restart fpp-servo-calibrator.service 2>/dev/null || true

# ── Apache proxy (always write so reinstalls and updates stay current) ────────
echo "Configuring Apache proxy..."
sudo a2enmod proxy proxy_http 2>/dev/null || true
PROXY_CONF="/etc/apache2/conf-available/fpp-servo-calibrator-proxy.conf"
printf '<IfModule mod_proxy.c>\n    ProxyPass        /fpp-servo-calibrator-api/ http://localhost:5003/\n    ProxyPassReverse /fpp-servo-calibrator-api/ http://localhost:5003/\n</IfModule>\n' \
    | sudo tee "$PROXY_CONF" > /dev/null
# Create the conf-enabled symlink directly rather than relying on a2enconf
sudo ln -sf "$PROXY_CONF" /etc/apache2/conf-enabled/fpp-servo-calibrator-proxy.conf
sudo systemctl reload apache2 2>/dev/null || true

echo "Done. Access via FPP menu: Plugins > Servo Calibrator"
