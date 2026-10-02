# Metode Cloudflare Named Tunnel di VM Egress-Proxy

## Prasyarat Cloudflare

Sebelum mulai, siapkan:

1. **Akun Cloudflare** — daftar/login di [dash.cloudflare.com](https://dash.cloudflare.com)
2. **Domain aktif** — beli domain (atau pakai yang sudah ada), tambahkan ke Cloudflare sebagai site, dan pastikan status **Active** (nameserver sudah diarahkan ke Cloudflare)
3. **Buat Tunnel** — di dashboard: Zero Trust → Networks → Tunnels → Create tunnel → pilih **Cloudflared** → kasih nama → copy **token instalasi** (format panjang, diawali huruf acak). Token ini yang dipakai di `~/.cloudflared/token`
4. **(Opsional) API Token** — kalau mau kelola DNS/route via API: My Profile → API Tokens → Create Custom Token dengan izin:
   - Zone → DNS → Edit (pilih zone domain kamu)
   - Account → Cloudflare Tunnel → Edit

Tanpa domain yang sudah Active di Cloudflare, tunnel tidak bisa diakses publik.

## Masalah

VM ini **wajib** lewat egress HTTP CONNECT proxy untuk semua traffic internet.
Koneksi langsung diblokir. `cloudflared` bawaan gagal karena:

1. Coba QUIC/UDP dulu → proxy tidak teruskan UDP → gagal.
2. Koneksi TCP langsung ke `regionX.v2.argotunnel.com:7844` → diblokir.

## Solusi

Paksa `cloudflared` bicara HTTP/2 ke **relay lokal**, relay teruskan via
HTTP CONNECT ke proxy.

### Rantai koneksi

```
cloudflared --protocol http2 --edge region1.v2.argotunnel.com:7844
   │
   │  (hostname tetap asli agar TLS SNI benar,
   │   tapi /etc/hosts di-override → 127.0.0.1)
   ▼
127.0.0.1:7844  (socat relay lokal)
   │
   │  PROXY: HTTP CONNECT proxy-host:proxy-port
   │  → CONNECT <edge-ip>:7844
   ▼
Cloudflare edge :7844
```

### Komponen

| Bagian | Peran |
|---|---|
| `--protocol http2` | Matikan QUIC/UDP, paksa TCP+TLS |
| `--edge region1.v2.argotunnel.com:7844` | Pakai hostname (bukan IP) agar SNI/TLS valid |
| `unshare --mount` + `mount --bind hosts.cf /etc/hosts` | Belokkan hostname edge → 127.0.0.1, hanya untuk proses cloudflared |
| `socat TCP-LISTEN:7844 … PROXY:…` | Relay: terima koneksi lokal, teruskan via HTTP CONNECT |
| `export -n http_proxy https_proxy …` | cloudflared JANGAN pakai proxy env (dia ngomong ke relay lokal) |
| `SSL_CERT_FILE` / `NODE_EXTRA_CA_CERTS` | Trust CA intersepsi proxy (kalau proxy melakukan TLS intercept) |

### Kenapa bukan --edge <IP>:7844 langsung?

Pernah dicoba: TLS EOF. Cloudflare validasi SNI — IP tanpa hostname yang
benar ditolak. Jadi hostname wajib asli, yang dibelokkan hanya resolusinya.

## File

- `run-cloudflared.sh.template` — wrapper (isi `<PROXY_URL>` dan token)
- `hosts.cf.example` — hosts override
- `../services/cloudflared.service.example` — unit systemd

## Setup public hostname

Via dashboard: tunnel → Public Hostnames → Add
(`sub.domain` → `http://127.0.0.1:<port>`). DNS CNAME otomatis dibuat.

Via API (butuh token: Zone DNS Edit + Account Cloudflare Tunnel Edit):

```bash
# 1. Buat DNS CNAME ke tunnel
curl -X POST "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records" \
  -H "Authorization: Bearer <API_TOKEN>" -H "Content-Type: application/json" \
  --data '{"type":"CNAME","name":"<sub>","content":"<TUNNEL_ID>.cfargotunnel.com","proxied":true}'

# 2. Tambah ingress rule
curl -X PUT "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/cfd_tunnel/<TUNNEL_ID>/configurations" \
  -H "Authorization: Bearer <API_TOKEN>" -H "Content-Type: application/json" \
  --data '{"config":{"ingress":[
    {"hostname":"<sub.domain>","service":"http://127.0.0.1:<port>"},
    {"service":"http_status:404"}]}}'
```

Untuk SSH: `"service":"ssh://127.0.0.1:22"`, di laptop pakai
`ProxyCommand cloudflared access ssh --hostname %h`.

## Verifikasi

```bash
systemctl is-active cloudflared            # active
journalctl -u cloudflared | grep "Registered tunnel connection"
curl -s -o /dev/null -w "%{http_code}\n" https://<sub.domain>/
```

## Troubleshooting

| Gejala | Penyebab | Fix |
|---|---|---|
| TLS EOF | `--edge` pakai IP | pakai hostname + hosts override |
| `connection refused 127.0.0.1:7844` | socat mati | cek PROXY_URL, restart service |
| Error 1033 di browser | cloudflared mati / tunnel tidak register | cek service + token |
| Tunnel `degraded` | cuma 1 koneksi (normal 4) | biasanya pulih sendiri |
| `404 Unknown host` | hostname diambil alih Worker / route belum ada | hapus Worker, tambah ulang Public Hostname |
