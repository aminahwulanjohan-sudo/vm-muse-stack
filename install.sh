#!/bin/bash
# Installer bertahap vm-muse-stack. Cek tiap langkah, berhenti kalau gagal.
# Jalankan: sudo -E ./install.sh   (-E agar env proxy tidak hilang)
set -u

ok()   { echo "✅ $1"; }
fail() { echo "❌ $1"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1 tidak ditemukan"; }

echo "=== [1/7] Cek prasyarat ==="
need socat; need node; need curl; need openssl
[ -n "${https_proxy:-}" ] || fail "https_proxy kosong — set dulu"
[ -f /run/hatch/egress-tls/ca-bundle.pem ] || fail "CA bundle proxy tidak ada"
ok "prasyarat lengkap"

echo "=== [2/7] Install cloudflared ==="
if [ ! -x /usr/local/bin/cloudflared ]; then
  VER="<CLOUDFLARED_VERSION>"   # mis. 2026.9.3
  curl -sL -o /tmp/cloudflared \
    "https://github.com/cloudflare/cloudflared/releases/download/${VER}/cloudflared-linux-amd64" \
    || fail "download cloudflared gagal"
  install -m 0755 /tmp/cloudflared /usr/local/bin/cloudflared
fi
/usr/local/bin/cloudflared --version || fail "cloudflared tidak jalan"
ok "cloudflared terinstall"

echo "=== [3/7] Setup tunnel ==="
mkdir -p /home/hatch/.cloudflared
[ -f /home/hatch/.cloudflared/token ] || fail "token belum ada — isi /home/hatch/.cloudflared/token (chmod 600)"
chmod 600 /home/hatch/.cloudflared/token
cp cloudflare-tunnel/hosts.cf.example /home/hatch/.cloudflared/hosts.cf
sed -e "s|<PROXY_URL>|${https_proxy}|g" \
    cloudflare-tunnel/run-cloudflared.sh.template \
    > /home/hatch/.cloudflared/run-cloudflared.sh
chmod +x /home/hatch/.cloudflared/run-cloudflared.sh
cp services/cloudflared.service.example /etc/systemd/system/cloudflared.service
systemctl daemon-reload
systemctl enable --now cloudflared
sleep 8
systemctl is-active --quiet cloudflared || fail "cloudflared tidak active"
journalctl -u cloudflared --no-pager -n 30 2>/dev/null | grep -q "Registered tunnel connection" \
  || fail "tunnel belum register — cek journalctl -u cloudflared"
ok "tunnel terdaftar di Cloudflare"

echo "=== [4/7] Install 9Router ==="
if ! command -v 9router >/dev/null 2>&1; then
  export NODE_EXTRA_CA_CERTS=/run/hatch/egress-tls/ca-bundle.pem
  /opt/hatch-image/bin/npm install -g 9router@0.5.91 || fail "npm install 9router gagal"
fi
9router --version >/dev/null 2>&1 || fail "9router tidak jalan"
ok "9router terinstall"

echo "=== [5/7] Setup service 9Router ==="
[ -f /home/hatch/.9router-dashboard-password ] || {
  openssl rand -base64 18 | tr -d '/+=' | head -c 24 > /home/hatch/.9router-dashboard-password
  chmod 600 /home/hatch/.9router-dashboard-password
}
[ -f /home/hatch/.9router-jwt-secret ] || {
  openssl rand -hex 32 > /home/hatch/.9router-jwt-secret
  chmod 600 /home/hatch/.9router-jwt-secret
}
cat > /etc/systemd/system/9router.service << EOF
[Unit]
Description=9Router LLM Gateway
After=network.target
[Service]
Type=simple
User=root
Environment=HOME=/home/hatch
Environment=DATA_DIR=/home/hatch/.9router
Environment=INITIAL_PASSWORD=$(cat /home/hatch/.9router-dashboard-password)
Environment=JWT_SECRET=$(cat /home/hatch/.9router-jwt-secret)
Environment=PORT=20128
Environment=https_proxy=$https_proxy
Environment=http_proxy=${http_proxy:-$https_proxy}
Environment=no_proxy=localhost,127.0.0.1,::1
Environment=CURL_CA_BUNDLE=/run/hatch/egress-tls/ca-bundle.pem
Environment=SSL_CERT_FILE=/run/hatch/egress-tls/ca-bundle.pem
Environment=NODE_EXTRA_CA_CERTS=/run/hatch/egress-tls/ca-bundle.pem
ExecStart=/usr/bin/9router -H 127.0.0.1 -p 20128 -n --skip-update
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now 9router
sleep 5
curl -s -m 5 http://127.0.0.1:20128/ >/dev/null || fail "9router tidak respons di :20128"
ok "9router jalan di 127.0.0.1:20128"

echo "=== [6/7] Setup ttyd + password gate ==="
[ -x /home/hatch/ttyd/ttyd ] || fail "binary ttyd tidak ada di /home/hatch/ttyd/ttyd"
cp services/ttyd.service.example /etc/systemd/system/ttyd.service
# auth-gate.js disalin manual dari VM asal (lihat docs)
[ -f /home/hatch/ttyd/auth-gate.js ] || fail "auth-gate.js belum ada — copy dari VM asal"
cp services/ttyd-auth.service.example /etc/systemd/system/ttyd-auth.service
systemctl daemon-reload
systemctl enable --now ttyd ttyd-auth
sleep 3
systemctl is-active --quiet ttyd-auth || fail "ttyd-auth tidak active"
ok "ttyd + password gate jalan"

echo "=== [7/7] Pasang recover.sh ==="
mkdir -p /home/hatch/workspace/vm-recovery
cp recover.sh /home/hatch/workspace/vm-recovery/recover.sh
chmod +x /home/hatch/workspace/vm-recovery/recover.sh
ok "recover.sh terpasang di ~/workspace/vm-recovery/"

echo ""
echo "SELESAI. Langkah manual tersisa:"
echo "- Daftarkan Public Hostname di dashboard tunnel (atau via API)"
echo "- Isi provider/API key di 9Router, CLIProxyAPI, Hermes (lihat docs masing-masing)"
echo "- Daftarkan recover.sh ke health hook / cron"
