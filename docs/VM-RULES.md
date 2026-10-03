# Aturan VM (wajib dibaca sebelum utak-atik infrastruktur)

Dokumen ini merangkum SEMUA aturan operasional VM yang dipelajari dari
insiden nyata 2026-10-01 s/d 2026-10-03. Langgar aturan ini = VM tidak
pulih otomatis saat di-replace.

---

## 1. VM bisa di-replace sewaktu-waktu (tanpa pemberitahuan)

- Garis hidup-mati: **`/home/hatch/` (`~`)**.
- **HILANG TOTAL** saat replace: `/etc/`, `/usr/`, `/root/`, `/var/`,
  `/opt/` — termasuk file service systemd, binary terinstall,
  `sshd_config`, host key SSH, dan paket apt.
- **SELAMAT**: semua di dalam `~` — config, secret, database,
  script, template service, backup key.

> Prinsip: kalau file penting ada di luar `~`, anggap sudah hilang.
> Buatkan salinannya di dalam `~` + mekanisme restore otomatis.

---

## 2. `recover.sh` — jantung pemulihan otomatis

Lokasi: `~/workspace/vm-recovery/recover.sh` (versi sanitized di repo ini).

### Aturan keras
- **APPEND-ONLY**: hanya tambah section baru di akhir. Jangan pernah
  menimpa/menghapus section yang sudah ada.
- **Idempoten**: aman dijalankan berkali-kali. Tiap section harus cek
  dulu ("apakah sudah benar?") sebelum bertindak.
- **Self-contained**: tiap section yang butuh paket apt HARUS install
  paketnya dulu — jangan asumsi paket bawaan image (pelajaran:
  `openssh-server` ternyata bukan bawaan image).
- **Tanpa secret**: script tidak menyimpan secret apapun. Secret dibaca
  dari file di `~` saat dibutuhkan, atau di-generate bila belum ada.

### Pola tiap section
```bash
# ---- Nama komponen (YYYY-MM-DD) ----
if [ ! -f /etc/systemd/system/nama.service ] && [ -f /home/hatch/path/template.service ]; then
  cp /home/hatch/path/template.service /etc/systemd/system/nama.service
  systemctl daemon-reload
  log "recreated nama.service"
fi
if ! systemctl is-active --quiet nama 2>/dev/null; then
  systemctl start nama 2>/dev/null && log "started nama" || log "FAILED to start nama"
fi
```

---

## 3. Manajemen secret

- Semua secret di `~` dengan permission **0600**: API token, password,
  private key, OAuth file.
- **JANGAN PERNAH** commit secret ke repo ini. Gunakan placeholder
  (`<TOKEN>`, `<PASSWORD>`, `domainkamu.my.id`).
- `recover.sh` "meminjam pakai": baca dari file → pasang sebagai
  environment variable service → tidak menyimpan di dalam script.

---

## 4. Systemd service

- File unit WAJIB di `/etc/systemd/system/` (aturan sistem), tapi file
  ini hilang saat replace.
- Template unit WAJIB disimpan di `~` (contoh:
  `/home/hatch/server-control/server-control.service`), dan `recover.sh`
  menyalinnya kembali + `daemon-reload` + start.
- **hermes-gateway**: restart HANYA via `systemctl restart hermes-gateway`.
  Jangan pakai `hermes gateway restart --system` via CLI — itu
  me-regenerate unit yang salah (path `/root/.hermes` instead of
  `/home/hatch/.hermes`).

---

## 5. Egress proxy (WAJIB)

- VM **tidak punya akses internet langsung**. Semua koneksi keluar
  WAJIB lewat proxy: `http://hatch-egress-proxy:3128` (dengan auth).
- Service yang butuh internet (hermes, cliproxyapi, server-control)
  HARUS punya env var di unit-nya:
  ```ini
  Environment="http_proxy=http://USER:PASS@hatch-egress-proxy:3128"
  Environment="https_proxy=http://USER:PASS@hatch-egress-proxy:3128"
  Environment="HTTP_PROXY=..."
  Environment="HTTPS_PROXY=..."
  Environment="no_proxy=localhost,127.0.0.1,::1"
  ```
- Tanpa ini: TLS error `WRONG_VERSION_NUMBER` atau koneksi timeout.
- Kredensial proxy bisa rotate — kalau service tiba-tiba tidak bisa
  akses internet, cek kredensial proxy di unit-nya.

---

## 6. SSH

- `openssh-server` **bukan** bawaan image → install via apt di `recover.sh`.
- Config: `PermitRootLogin yes`, `PasswordAuthentication yes`,
  `PubkeyAuthentication yes`.
- **Host key persist**: backup di `~/.ssh/ssh_host_keys/` (0600),
  `recover.sh` me-restore ke `/etc/ssh/` bila berubah. Tanpa ini, laptop
  harus `ssh-keygen -R` tiap VM di-replace.
- **authorized_keys persist**: public key laptop di
  `~/.ssh/authorized_keys_laptop`, di-restore ke `/root/.ssh/`.
- Password root di `~/.root_password` (0600), jangan di-commit.

---

## 7. Hermes (Telegram bots)

- **Fully self-contained** di `~/.hermes/`: kode agent (815MB),
  python, node, npm, ffmpeg, chromium di `~/.hermes/tools/`.
- Saat recovery: **nol download**, cuma tulis ulang file service.
- Tiap profile punya config sendiri:
  `~/.hermes/config.yaml` (default),
  `~/.hermes/profiles/bot2/config.yaml`,
  `~/.hermes/profiles/bot3/config.yaml`.
- **GOTCHA**: cache provider di
  `~/.hermes/provider_models_cache.json` HARUS dihapus tiap ganti
  `base_url`/`model` di config, lalu restart gateway.
- **GOTCHA**: override `/model` tersimpan di `state.db` per sesi Telegram
  dan menang atas `config.yaml`. Kalau ganti provider tapi error lama
  muncul terus, cek kolom `model`/`model_config` di tabel `sessions`.
  Clear DB harus saat service **berhenti total** (kalau masih hidup,
  state in-memory ditulis balik ke DB saat restart).
- **GOTCHA**: `api_key` di config ada di dalam blok `model:` (indent) —
  regex `^api_key:` tidak cocok, pakai `^(\s*)api_key:`.

---

## 8. 9Router

- Binary via `npm install -g 9router@0.5.91` (versi di-pin).
- **Optimasi recovery**: tarball di-cache di
  `~/workspace/vm-recovery/npm-cache/9router-0.5.91.tgz` +
  `npm config set prefer-offline true` + cache di-warm.
  Hasil: install ulang ~6 detik offline vs 1-2 menit download.
- Data (`DATA_DIR=/home/hatch/.9router`) persist: API key, provider,
  combo, usage history.
- Service bind `127.0.0.1:20128` via flag `-H 127.0.0.1`.
- **GOTCHA**: combo models HARUS array of string
  (`["muse/muse-spark-1.3"]`), bukan object.
- **GOTCHA**: jangan pakai prefix `gemini` untuk node openai-compatible
  (di-resolve ke provider bawaan) — pakai `cliproxy`.

---

## 9. CLIProxyAPI (Antigravity)

- Binary + config di `/home/hatch/cliproxyapi/`, service `cliproxyapi`.
- **GOTCHA**: service HARUS set `Environment=HOME=/home/hatch`
  (OAuth di `/home/hatch/.cli-proxy-api`) + proxy env vars.
- Akun: 2 akun Antigravity (round-robin), file di
  `~/.cli-proxy-api/antigravity-<email>.json`.
- Kuota real bisa diambil via Google Cloud Code API:
  `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`
  dengan `Authorization: Bearer <access_token>` +
  `User-Agent: antigravity/cli/1.0.9 linux/amd64`.
  Dua step: `loadCodeAssist` dulu untuk dapat `project` id, baru
  `retrieveUserQuotaSummary`. Mengembalikan buckets `gemini-5h`,
  `gemini-weekly`, `3p-5h`, `3p-weekly` (remainingFraction + resetTime).

---

## 10. Health monitoring

- Hook `vm-health-check` (bukan cron): cek tiap 60 detik, **silent**
  kalau semua sehat (nol token), wake agent hanya kalau ada yang mati.
- Yang dimonitor: port 22 (SSH), hermes-gateway, port 8317
  (CLIProxyAPI), port 20128 (9Router), port 20309 (panel).
- Hindari wake berulang untuk masalah yang sama
  (state di `~/hooks/state/vm-health.json`).
- Estimasi pulih total: 2–5 menit (deteksi 60 dtk + recovery).

---

## 11. Cloudflare

- Token minimal di `~/.cloudflare-api-token` (0600), token full di
  `~/.cloudflare-api-token-full` (0600). Jangan tampilkan isinya.
- Prinsip izin bertahap: kasih minimal dulu (Zone DNS Edit +
  Account Cloudflare Tunnel Edit). Kalau butuh izin lain, kabari user
  dulu — jangan asumsi.
- Tunnel `Muse.ai` — hostname via dashboard atau API dengan token
  berizin Tunnel Edit.

---

## 12. Server Control panel

- Node.js stdlib saja (tanpa dependency), port `127.0.0.1:20309`.
- Butuh proxy env vars di unit (lihat aturan 5) untuk akses API eksternal.
- Tab "Cliproxy" (kategori AI): monitor service, akun, routing bot,
  usage harian, dan kuota real Google (lihat aturan 9).
- Endpoint `/api/cliproxy` — cache kuota 60 detik di backend agar
  tidak spam API Google.

---

## Ringkasan satu baris per aturan

| # | Aturan |
|---|--------|
| 1 | Di luar `~` = hilang saat replace |
| 2 | `recover.sh` append-only + idempoten + tanpa secret |
| 3 | Secret di `~` 0600, jangan commit |
| 4 | Template service di `~`, hermes restart via systemctl saja |
| 5 | Egress wajib via proxy |
| 6 | SSH host key + authorized_keys di-backup ke `~` |
| 7 | Hermes self-contained; hapus cache provider tiap ganti config |
| 8 | 9Router: tarball di-cache, versi di-pin |
| 9 | CLIProxyAPI: HOME=/home/hatch + proxy env |
| 10 | Hook health check 60 dtk, silent kalau sehat |
| 11 | Cloudflare: izin minimal bertahap |
| 12 | Panel butuh proxy env untuk API eksternal |
