#!/bin/bash
# VM recovery — SANITIZED template. Idempotent: aman dijalanin berkali-kali.
# Ganti semua <PLACEHOLDER> sebelum dipakai.
# Prinsip tiap section: "kalau file service belum ada -> bikin; kalau service mati -> start".

HOME_DIR="/home/<USER>"
LOG="$HOME_DIR/workspace/vm-recovery/recovery.log"
mkdir -p "$HOME_DIR/workspace/vm-recovery"
log() { echo "[$(date '+%F %T')] $1" >> "$LOG"; }

# Proxy (wajib — VM tidak bisa akses internet langsung)
export https_proxy="${https_proxy:-<PROXY_URL>}"
export http_proxy="${http_proxy:-$https_proxy}"
export no_proxy="${no_proxy:-localhost,127.0.0.1,::1,[::1]}"
[ -z "$https_proxy" ] && log "WARNING: https_proxy kosong"

# CA bundle untuk TLS intercept proxy
CA_BUNDLE="<CA_BUNDLE_PATH>"   # mis. /run/hatch/egress-tls/ca-bundle.pem
CA_ENV=""
if [ -f "$CA_BUNDLE" ]; then
  CA_ENV="Environment=CURL_CA_BUNDLE=$CA_BUNDLE
Environment=SSL_CERT_FILE=$CA_BUNDLE
Environment=NODE_EXTRA_CA_CERTS=$CA_BUNDLE"
  export NODE_EXTRA_CA_CERTS="$CA_BUNDLE"   # npm butuh ini (sudo men-strip env)
else
  log "WARNING: CA bundle $CA_BUNDLE tidak ada"
fi

NEED_RELOAD=0
mk_service() { # $1=nama $2=isi unit
  if [ ! -f "/etc/systemd/system/$1.service" ]; then
    printf '%s' "$2" > "/etc/systemd/system/$1.service"
    NEED_RELOAD=1
    log "recreated $1.service"
  fi
  if ! systemctl is-active --quiet "$1" 2>/dev/null; then
    [ "$NEED_RELOAD" = 1 ] && systemctl daemon-reload && NEED_RELOAD=0
    systemctl enable --quiet "$1" 2>/dev/null
    systemctl start "$1" 2>/dev/null && log "started $1" || log "FAILED start $1"
  fi
}

# ---- cloudflared (Cloudflare Named Tunnel) ----
mk_service cloudflared "[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
Type=simple
User=root
ExecStart=$HOME_DIR/.cloudflared/run-cloudflared.sh
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
"

# ---- mini-dns (TCP DNS lokal utk cloudflared SRV discovery) ----
[ -f "$HOME_DIR/workspace/cloudflared/mini-dns-tcp.js" ] && mk_service mini-dns "[Unit]
Description=Mini DNS TCP
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/node $HOME_DIR/workspace/cloudflared/mini-dns-tcp.js
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
"

# ---- 9Router (LLM gateway :20128) ----
if ! command -v 9router >/dev/null 2>&1; then
  <NPM_BIN> install -g 9router@<VERSION> >/dev/null 2>&1 \
    && log "npm install 9router" || log "FAILED npm install 9router"
fi
[ -f "$HOME_DIR/.9router-dashboard-password" ] || {
  openssl rand -base64 18 | tr -d '/+=' | head -c 24 > "$HOME_DIR/.9router-dashboard-password"
  chmod 600 "$HOME_DIR/.9router-dashboard-password"
  log "generated 9router dashboard password"
}
[ -f "$HOME_DIR/.9router-jwt-secret" ] || {
  openssl rand -hex 32 > "$HOME_DIR/.9router-jwt-secret"
  chmod 600 "$HOME_DIR/.9router-jwt-secret"
}
mk_service 9router "[Unit]
Description=9Router LLM Gateway
After=network.target
[Service]
Type=simple
User=root
Environment=HOME=$HOME_DIR
Environment=DATA_DIR=$HOME_DIR/.9router
Environment=INITIAL_PASSWORD=$(cat $HOME_DIR/.9router-dashboard-password)
Environment=JWT_SECRET=$(cat $HOME_DIR/.9router-jwt-secret)
Environment=PORT=20128
Environment=https_proxy=$https_proxy
Environment=http_proxy=$http_proxy
Environment=no_proxy=$no_proxy
$CA_ENV
ExecStart=/usr/bin/9router -H 127.0.0.1 -p 20128 -n --skip-update
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
"

# ---- muse-bridge (mailbox :20129) ----
[ -f "$HOME_DIR/muse-bridge/bridge.js" ] && mk_service muse-bridge "[Unit]
Description=Muse mailbox bridge
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=$HOME_DIR/muse-bridge
Environment=HOME=$HOME_DIR
$CA_ENV
ExecStart=/usr/bin/node $HOME_DIR/muse-bridge/bridge.js
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
"

# ---- CLIProxyAPI (:8317) ----
[ -x "$HOME_DIR/cliproxyapi/cli-proxy-api" ] && mk_service cliproxyapi "[Unit]
Description=CLIProxyAPI Antigravity Proxy
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=$HOME_DIR/cliproxyapi
Environment=HOME=$HOME_DIR
Environment=https_proxy=$https_proxy
Environment=http_proxy=$http_proxy
Environment=no_proxy=$no_proxy
$CA_ENV
ExecStart=$HOME_DIR/cliproxyapi/cli-proxy-api
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
"

# ---- server-control (panel :20309) ----
[ -f "$HOME_DIR/server-control/server-control.service" ] && {
  [ ! -f /etc/systemd/system/server-control.service ] && \
    cp "$HOME_DIR/server-control/server-control.service" /etc/systemd/system/ && NEED_RELOAD=1
  mk_service server-control "$(cat /etc/systemd/system/server-control.service)"
}

# ---- hermes-gateway (bot Telegram) — JANGAN via hermes CLI, pakai systemctl ----
[ -f "$HOME_DIR/.hermes/hermes-gateway.service" ] && {
  [ ! -f /etc/systemd/system/hermes-gateway.service ] && \
    cp "$HOME_DIR/.hermes/hermes-gateway.service" /etc/systemd/system/ && NEED_RELOAD=1
  if ! systemctl is-active --quiet hermes-gateway 2>/dev/null; then
    [ "$NEED_RELOAD" = 1 ] && systemctl daemon-reload && NEED_RELOAD=0
    systemctl start hermes-gateway 2>/dev/null && log "started hermes-gateway" || log "FAILED start hermes-gateway"
  fi
}

# ---- connect-bridge (forwarder TCP -> HTTP CONNECT proxy) ----
[ -f "$HOME_DIR/workspace/ngrok/connect-bridge.js" ] && \
[ -f "$HOME_DIR/server-control/connect-bridge.service" ] && {
  [ ! -f /etc/systemd/system/connect-bridge.service ] && \
    cp "$HOME_DIR/server-control/connect-bridge.service" /etc/systemd/system/ && NEED_RELOAD=1
  if ! systemctl is-active --quiet connect-bridge 2>/dev/null; then
    [ "$NEED_RELOAD" = 1 ] && systemctl daemon-reload && NEED_RELOAD=0
    systemctl enable --quiet connect-bridge 2>/dev/null
    systemctl start connect-bridge 2>/dev/null && log "started connect-bridge" || log "FAILED start connect-bridge"
  fi
}

# ---- sibluudz discord bot ----
[ -f "$HOME_DIR/server-control/sibluudz-bot.service" ] && {
  [ ! -f /etc/systemd/system/sibluudz-bot.service ] && \
    cp "$HOME_DIR/server-control/sibluudz-bot.service" /etc/systemd/system/ && NEED_RELOAD=1
  if ! systemctl is-active --quiet sibluudz-bot 2>/dev/null; then
    [ "$NEED_RELOAD" = 1 ] && systemctl daemon-reload && NEED_RELOAD=0
    systemctl start sibluudz-bot 2>/dev/null && log "started sibluudz-bot" || log "FAILED start sibluudz-bot"
  fi
}

# ---- ttyd (:7681, hanya 127.0.0.1) ----
[ -x "$HOME_DIR/ttyd/ttyd" ] && mk_service ttyd "[Unit]
Description=ttyd - Terminal over Web
After=network.target
[Service]
Type=simple
User=root
ExecStart=$HOME_DIR/ttyd/ttyd -p 7681 -i 127.0.0.1 --writable bash
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
"

# ---- ttyd-auth (password gate :7682 -> proxy ke ttyd) ----
[ -f "$HOME_DIR/ttyd/auth-gate.js" ] && mk_service ttyd-auth "[Unit]
Description=ttyd password gate
After=ttyd.service
[Service]
Type=simple
User=root
ExecStart=/usr/bin/node $HOME_DIR/ttyd/auth-gate.js
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
"

# ---- SSH: root login pakai password (untuk akses via tunnel) ----
if grep -q "^#*PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null; then
  sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
else
  echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
fi
if grep -q "^#*PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null; then
  sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
else
  echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
fi
if [ -f "$HOME_DIR/.root_password" ]; then
  echo "root:$(cat $HOME_DIR/.root_password)" | chpasswd 2>/dev/null
  chmod 600 "$HOME_DIR/.root_password" 2>/dev/null
fi
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

[ "$NEED_RELOAD" = 1 ] && systemctl daemon-reload
log "recover selesai"
