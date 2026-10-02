# Aturan Deploy ke VM (anti-hilang saat VM replace)

## 1. VM bisa di-replace sewaktu-waktu
Provider ganti VM tanpa pemberitahuan. SEMUA file di luar `/home/<USER>/`
HILANG TOTAL. Yang persist hanya `/home/<USER>/`.

## 2. Lokasi project
- SELALU: `/home/<USER>/www/<nama-project>/`
- JANGAN: `/var/www/`, `/opt/`, `/srv/`, `/root/`, path lain di luar home.

## 3. Systemd service
File service HARUS di `/etc/systemd/system/<nama>.service` (aturan sistem),
tapi WAJIB juga ditambahkan ke `recover.sh` agar pulih otomatis.

Template:
```ini
[Unit]
Description=<Deskripsi>
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/home/<USER>/www/<nama-project>
ExecStart=/usr/bin/node /home/<USER>/www/<nama-project>/server.js
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
```

## 4. Tambah ke recover.sh — HANYA APPEND, JANGAN TIMPA
Selalu tambah block baru di PALING BAWAH file:

```bash
cat >> ~/workspace/vm-recovery/recover.sh << 'EOF'

# ---- <nama-project> (<deskripsi>, YYYY-MM-DD) ----
if [ ! -f /etc/systemd/system/<nama>.service ] && [ -d /home/<USER>/www/<nama-project> ]; then
  cat > /etc/systemd/system/<nama>.service << 'UNIT'
[Unit]
Description=<Deskripsi>
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/home/<USER>/www/<nama-project>
ExecStart=/usr/bin/node /home/<USER>/www/<nama-project>/server.js
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now <nama>.service
fi
EOF
```

DILARANG: tulis ulang file, hapus block lain, edit block milik service lain.

## 5. Domain publik
Minta ke AI operator VM: subdomain + port lokal.
Contoh: "tambahkan app.&lt;domain&gt; ke port 3000". Jangan setting Cloudflare sendiri.

## Checklist
- [ ] Project di `/home/<USER>/www/<nama>/`
- [ ] Service aktif: `systemctl is-active <nama>`
- [ ] Block recover.sh ditambahkan (append)
- [ ] (Opsional) Route Cloudflare diminta

## Port terpakai (jangan tabrakan)
- 22 SSH · 53 mini-dns · 7681 ttyd · 7682 ttyd-auth
- 8317 CLIProxyAPI · 20128 9Router · 20129 muse-bridge · 20309 panel
- 3000+ bebas (cek: `ss -tln | grep :<port>`)

## Jangan diutak-atik
cloudflared, mini-dns, connect-bridge, hermes-gateway, muse-bridge,
9router, cliproxyapi, server-control, sibluudz-bot, ttyd, ttyd-auth, ssh.

## Catatan
- Resource terbatas. Jangan mining/render berat.
- `apt install` hilang pas replace — catat di recover.sh kalau penting.
- Database: pakai SQLite (file di home). Hindari MySQL/Postgres.
