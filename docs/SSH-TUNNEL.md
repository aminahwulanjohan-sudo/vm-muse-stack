# SSH via Cloudflare Tunnel

Akses SSH ke VM tanpa IP publik, lewat tunnel yang sama dengan layanan lain.

## Cara kerja

```
laptop (ssh vm-ourme)
  -> ProxyCommand: cloudflared access ssh --hostname ssh.domainkamu.my.id
  -> Cloudflare edge
  -> cloudflared di VM (tunnel "Muse.ai")
  -> ssh://127.0.0.1:22 (sshd di VM)
```

- Route tunnel: `ssh.domainkamu.my.id` -> `ssh://127.0.0.1:22`
  (tambah via dashboard: Access > Tunnels > tunnel > Public Hostname,
  atau via API dengan token berizin Cloudflare Tunnel Edit)
- Di VM: `openssh-server` + `PermitRootLogin yes` + `PasswordAuthentication yes`,
  password root disimpan 0600 di `~/.root_password` (JANGAN di-commit).
- Di laptop (`~/.ssh/config`):
  ```
  Host vm-ourme
    HostName ssh.domainkamu.my.id
    User root
    ProxyCommand cloudflared access ssh --hostname %h
  ```
- Tiap VM di-replace, host key ikut ganti. Di laptop:
  ```
  ssh-keygen -R ssh.domainkamu.my.id
  ssh-keygen -R vm-ourme
  ```

## Login tanpa password (public key)

1. Di laptop: `cat ~/.ssh/id_ed25519.pub` (atau buat baru: `ssh-keygen -t ed25519`)
2. Simpan public key secara PERSISTEN di VM:
   `~/.ssh/authorized_keys_laptop` (satu key per baris)
3. Pasang ke root sekarang:
   ```
   mkdir -p /root/.ssh && chmod 700 /root/.ssh
   cat ~/.ssh/authorized_keys_laptop >> /root/.ssh/authorized_keys
   chmod 600 /root/.ssh/authorized_keys
   ```
4. `recover.sh` punya block `SSH authorized_keys root` (append-only) yang
   memulihkan `/root/.ssh/authorized_keys` dari salinan persisten itu
   tiap VM di-replace — karena `/root/.ssh` ikut hilang.

Pastikan `PubkeyAuthentication yes` di `sshd_config` (default Ubuntu: yes).

## Insiden 2026-10-03: 502 / connection refused
**Gejala di laptop** saat `ssh vm-ourme`:
```
websocket: bad handshake
HTTP/1.1 502 Bad Gateway (Server: cloudflare)
kex_exchange_identification: Connection closed by remote host
```

**Di log cloudflared VM** (`journalctl -u cloudflared`):
```
ERR error="dial tcp 127.0.0.1:22: connect: connection refused"
    destAddr=ssh://127.0.0.1:22 ingressRule=4 originService=ssh://127.0.0.1:22
```

**Akar masalah:** VM habis di-replace dan `openssh-server` BUKAN bawaan
image VM — paketnya hilang total. Section `recover.sh` untuk SSH hanya
mengedit `/etc/ssh/sshd_config` dan me-restart service, TANPA memastikan
paketnya terinstall dulu. Karena file config & service tidak ada, section
itu gagal diam-diam (`2>/dev/null || true`), port 22 kosong, dan tunnel
melempar 502 ke client.

Catatan: 502 di sini BUKAN berarti tunnel putus — request sampai ke VM,
tapi tidak ada yang mendengarkan di ujungnya.

**Perbaikan:**
1. `apt-get install -y openssh-server`
2. Pastikan `PermitRootLogin yes` + `PasswordAuthentication yes` di
   `/etc/ssh/sshd_config`, set password root dari file 0600
3. `systemctl enable --now ssh`
4. Verifikasi: `ss -tlnp | grep :22` dan banner `SSH-2.0-OpenSSH...`
   via koneksi TCP ke 127.0.0.1:22

**Pencegahan (sudah di `recover.sh`):** block `SSH server ensure`
(append-only, di paling bawah) yang self-contained: cek `dpkg -s
openssh-server`, install bila belum ada, baru config + enable + start.
Idempotent, aman dijalanin tiap replace.

**Monitoring:** hook `vm-health-check` (poll tiap 60 detik) ikut memantau
port 22 — kalau sshd mati/hilang padahal service lain sehat, hook tetap
wake agent untuk menjalankan `recover.sh`. Setelah VM replace total,
`hermes-gateway` pasti down (unit di `/etc` ikut hilang) sehingga hook
pasti fire.

## Pelajaran umum

Setiap section `recover.sh` yang butuh paket apt WAJIB memastikan paketnya
terinstall dulu — jangan asumsi paket itu bawaan image. Pola:

```bash
if ! dpkg -s <paket> >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq <paket>
fi
```

Kegagalan diam-diam (`|| true` / `2>/dev/null`) itu berguna agar satu
section tidak menggagalkan semuanya, tapi section WAJIB tetap mencapai
tujuannya (service jalan) — bukan cuma "tidak error".
