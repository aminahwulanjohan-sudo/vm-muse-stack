# 9Router

AI gateway lokal — routing terpusat ke multiple AI provider dengan combo model.

## Instalasi

```bash
# Butuh NODE_EXTRA_CA_CERTS kalau egress via TLS-intercept proxy
export NODE_EXTRA_CA_CERTS=/run/hatch/egress-tls/ca-bundle.pem
npm install -g 9router@0.5.91
```

Service systemd (`/etc/systemd/system/9router.service`):
```ini
[Unit]
Description=9Router AI Gateway
After=network.target
[Service]
Type=simple
User=root
Environment=HOME=/home/hatch
Environment=DATA_DIR=/home/hatch/.9router
ExecStart=/usr/bin/9router -H 127.0.0.1 -p 20128
Restart=always
[Install]
WantedBy=multi-user.target
```

Dashboard: `http://127.0.0.1:20128` (password di file 0600, jangan hardcode).

## Provider

| Nama | Prefix | Type | Base URL |
|---|---|---|---|
| Muse Bridge | `muse` | openai-compatible | `http://127.0.0.1:20129/v1` |
| CLIProxyAPI | `cliproxy` | openai-compatible | `http://127.0.0.1:8317/v1` |

Model dipakai sebagai `<prefix>/<model>`, contoh: `muse/muse-spark-1.3`.

## Combo

Contoh combo `muse-spark`:
```json
{
  "name": "muse-spark",
  "models": ["muse/muse-spark-1.3"]
}
```

⚠️ **GOTCHA:** `models` HARUS array of string. Kalau object `{provider, model}`, request gagal (`a.includes is not a function`).

## API Key

Buat API key terpisah per konsumen (Hermes, device lain, dll) via dashboard atau API.

## GOTCHA Prefix

JANGAN pakai prefix `gemini` untuk node openai-compatible — 9Router me-resolve prefix itu ke provider bawaan sehingga credential tidak ketemu (`No active credentials for provider: gemini`). Pakai prefix custom seperti `cliproxy`.

## Verifikasi

```bash
curl http://127.0.0.1:20128/v1/models -H "Authorization: Bearer <KEY>"
```
