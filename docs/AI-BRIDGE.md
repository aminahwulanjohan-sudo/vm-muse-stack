# Jembatan AI Laptop <-> Muse (pengelola VM)

AI di laptop bisa ngobrol langsung dengan Muse tanpa copy-paste,
cukup lewat SSH yang sudah ada.

## AI laptop -> Muse (sudah jadi, teruji)

Script: `/home/hatch/ai-bridge/ask-muse.sh` — dijalankan DARI laptop:

```bash
ssh vm-ourme /home/hatch/ai-bridge/ask-muse.sh "tolong cek status nginx di VM"
```

- Tanpa config apa pun di sisi laptop: script membaca API key 9Router
  dari VM sendiri, memanggil `muse/muse-spark-1.3` via 9Router lokal.
- Rantai: SSH -> script -> 9Router (127.0.0.1:20128) -> muse-bridge
  -> mailbox -> worker Muse -> balasan dicetak ke stdout.
- Latensi ~15-60 detik per pesan (siklus wake worker). Bukan untuk
  chat rapid-fire; cocok untuk koordinasi deploy/operasi.
- Multi-turn: kirim history via stdin:
  ```bash
  echo '[{"role":"user","content":"hai"}]' \
    | ssh vm-ourme /home/hatch/ai-bridge/ask-muse.sh --stdin
  ```
- Worker yang menjawab punya akses MEMORY.md dan konteks yang sama
  dengan Muse di Telegram.

## Muse -> AI laptop (outbox)

Muse tidak bisa push ke laptop (NAT). Pola yang dipakai:
- Muse menulis pesan ke `/home/hatch/ai-bridge/outbox/<timestamp>-<topik>.txt`
- AI laptop mem-poll via SSH: `ssh vm-ourme "ls -t /home/hatch/ai-bridge/outbox/ | head"`
- Setelah dibaca, AI laptop hapus file-nya (atau Muse yang bersihkan).

## Catatan

- `ai-bridge/` ada di home -> persist saat VM replace.
- Tidak butuh service/hook baru: rantai 9Router+mailbox sudah ada.
- Jangan taruh API key di laptop — script mengambilnya dari VM.
