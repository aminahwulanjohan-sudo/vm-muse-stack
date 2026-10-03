# vm-muse-stack

Replikasi full stack VM Muse: AI gateway + Telegram bots + Cloudflare Tunnel,
di VM yang semua traffic-nya **wajib lewat egress HTTP CONNECT proxy**.

## Arsitektur

```
Internet
   │
   ▼
Cloudflare Edge ◄── tunnel (HTTP/2 :7844 via proxy) ──┐
   │                                                   │
   ├── panel.domainkamu.my.id ──► 127.0.0.1:20309  server-control (panel)
   ├── 9router.domainkamu.my.id ─► 127.0.0.1:20128  9Router (LLM gateway)
   ├── term.domainkamu.my.id ────► 127.0.0.1:7682   ttyd-auth (password gate)
   │                                     └─► 127.0.0.1:7681  ttyd
   ├── ssh.domainkamu.my.id ─────► 127.0.0.1:22     SSH (via cloudflared ProxyCommand)
   └── cliproxy.domainkamu.my.id ─► 127.0.0.1:8317  CLIProxyAPI
                                                      │
Telegram ──► hermes-gateway ──► 9Router ──► muse-bridge (:20129)
   │                              │              │
   │                              │              └── mailbox → Muse worker
   │                              │
   │                              ├── muse/* ──────► Muse Bridge
   │                              └── cliproxy/* ──► CLIProxyAPI (Antigravity)
   │
   └── bot3 ──► CLIProxyAPI langsung (gemini-3.8-flash-high)

Discord ──► sibluudz-bot ──► connect-bridge ──► proxy ──► gateway.discord.gg
```

## Komponen + port

| Komponen | Port | Fungsi |
|---|---|---|
| 9Router | 20128 | LLM gateway, combo + provider |
| muse-bridge | 20129 | Mailbox bridge Hermes → Muse worker |
| server-control | 20309 | Panel web (login page) |
| ttyd | 7681 | Terminal web (hanya 127.0.0.1) |
| ttyd-auth | 7682 | Password gate untuk ttyd |
| CLIProxyAPI | 8317 | Proxy Antigravity (round-robin) |
| SSH | 22 | SSH server |
| cloudflared | — | Named Tunnel ke Cloudflare |
| mini-dns | 53/tcp | DNS lokal utk cloudflared SRV discovery |
| connect-bridge | — | Forwarder TCP → HTTP CONNECT proxy |
| hermes-gateway | — | Gateway bot Telegram |
| sibluudz-bot | — | Bot Discord |

## Quick start

```bash
# 1. Isi secret (JANGAN commit file aslinya — lihat .gitignore)
cp cloudflare-tunnel/hosts.cf.example ~/.cloudflared/hosts.cf
# simpan token tunnel di ~/.cloudflared/token (chmod 600)

# 2. Jalankan installer bertahap
sudo -E ./install.sh

# 3. Pasang auto-recovery (jalan tiap VM replace)
# copy recover.sh ke ~/workspace/vm-recovery/ lalu daftarkan ke hook/cron
```

## Cara kerja tunnel

VM tidak bisa konek langsung ke internet (wajib via egress proxy).
`cloudflared` normal gagal (coba QUIC/UDP + koneksi langsung).

Solusi: paksa `--protocol http2`, arahkan edge hostname ke relay `socat`
lokal via hosts override (`unshare --mount`), relay teruskan via
HTTP CONNECT ke proxy. Detail: [cloudflare-tunnel/README.md](cloudflare-tunnel/README.md).

## Cara kerja recover.sh

VM diganti provider sewaktu-waktu → semua di luar `/home/hatch/` hilang
(`/etc/systemd/system/`, `/usr/bin/`, dsb).

`recover.sh` idempotent: tiap section cek "sudah ada?" → kalau belum,
bikin ulang service + start. Aman dijalanin berkali-kali. Dipanggil oleh
health hook tiap 1 menit (silent kalau sehat).

Aturan deploy agar survive replace: [docs/DEPLOY-RULES.md](docs/DEPLOY-RULES.md).
Dok lain: [SSH via tunnel + insiden 2026-10-03](docs/SSH-TUNNEL.md) ·
[9Router](docs/9ROUTER.md) · [Hermes](docs/HERMES.md).
