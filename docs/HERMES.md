# Hermes Telegram Gateway

Bot Telegram multi-profile yang jadi antarmuka chat ke AI backend.

## Arsitektur

```
Telegram → hermes-gateway → 9Router → muse-bridge → Muse worker
                              ↘ CLIProxyAPI (bot3, langsung)
```

- Profile `default` + `bot2`: lewat 9Router (combo `muse-spark`)
- Profile `bot3`: langsung ke CLIProxyAPI (model Gemini)

## Instalasi

Hermes diinstal via installer resmi. Service jalan sebagai systemd:

```ini
# /etc/systemd/system/hermes-gateway.service
[Unit]
Description=Hermes Agent Gateway
After=network.target
[Service]
Type=simple
User=root
Environment=HOME=/home/hatch
# proxy WAJIB (egress via proxy, kalau tidak: SSL WRONG_VERSION_NUMBER)
Environment=https_proxy=<PROXY_URL>
Environment=http_proxy=<PROXY_URL>
ExecStart=/home/hatch/.hermes/bin/hermes gateway run --system
Restart=always
[Install]
WantedBy=multi-user.target
```

## Konfigurasi

Config per profile:
- Default: `/home/hatch/.hermes/config.yaml`
- Bot2: `/home/hatch/.hermes/profiles/bot2/config.yaml`
- Bot3: `/home/hatch/.hermes/profiles/bot3/config.yaml`

Contoh blok model (9Router):
```yaml
model:
  base_url: http://127.0.0.1:20128/v1
  model: muse-spark
  api_key: <9ROUTER_API_KEY>
```

Contoh blok model (CLIProxyAPI langsung):
```yaml
model:
  base_url: http://127.0.0.1:8317/v1
  model: gemini-3.8-flash-high
  api_key: <CLIPROXY_API_KEY>
```

## GOTCHA

1. **Jangan pakai `hermes gateway restart --system`** — installer generate unit dengan path salah (`/root/.hermes`). Selalu pakai:
   ```
   systemctl restart hermes-gateway
   ```

2. **Hapus cache provider setelah ganti config:**
   ```
   rm /home/hatch/.hermes/provider_models_cache.json
   systemctl restart hermes-gateway
   ```
   Kalau tidak, config lama tetap dipakai.

3. **`api_key` ada di dalam blok `model:`** (indent 2 spasi). Regex `^api_key:` tidak cocok.

4. **Tiap profile punya config sendiri** — update semua profile, bukan cuma default.

5. **Proxy env wajib** di unit file (VM egress via proxy).

## Pairing Bot Telegram

- Bot dibuat via `@NousHostedHermesBot` (managed pairing) atau BotFather manual.
- `TELEGRAM_ALLOWED_USERS` = user ID owner (di `.env`).
- Orang asing cuma dapat pesan pairing, tidak bisa pakai bot.

## Kepribadian per Bot

Edit `SOUL.md` di folder masing-masing profile, lalu restart gateway:
- Default: `/home/hatch/.hermes/SOUL.md`
- Bot2: `/home/hatch/.hermes/profiles/bot2/SOUL.md`
- Bot3: `/home/hatch/.hermes/profiles/bot3/SOUL.md`
