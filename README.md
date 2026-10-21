# VpsFree

VPS **Ubuntu Server** yang dijalankan oleh **GitHub Actions** atau **Docker**, diakses lewat **SSH publik melalui Bore tunnel** (`bore.pub`).

Kredit asli: **KallAncrit**. Template: `xykal/XyRDP`.

---

## 1. Cara kerja singkat

Setiap kali workflow dijalankan, GitHub menyiapkan satu mesin Ubuntu Server sementara (ephemeral):

1. `setup-vps.sh` menyetel password **root** dan user sudo dari secret `VPS_PASSWORD`, serta mengaktifkan OpenSSH Server (Port 22, root login, password + pubkey).
2. `restore-state.sh` memulihkan data sesi sebelumnya (home, konfigurasi SSH).
3. `setup-akses.sh` memasang dan menjalankan **Bore tunnel** (`bore local 22 --to bore.pub`).
4. `publish-status.sh` menulis status sesi dan port SSH publik ke branch `status` (`vps-status.json`).
5. `keepalive.sh` menjaga mesin tetap hidup, menyimpan state tiap 15 menit, menjadwalkan sesi berikutnya sebelum waktu habis, lalu menghentikan diri sendiri 3 menit sebelum batas waktu.

---

## 2. Prasyarat

- Repository dibuat dari template (`Use this template` di GitHub).
- Actions diizinkan pada repository.

---

## 3. Secrets / Environment

Buka **Settings → Secrets and variables → Actions → New repository secret**, atau lewat env Docker:

| Variabel | Deskripsi |
|---|---|
| `VPS_PASSWORD` | Password untuk login SSH user **root**. Minimal 8 karakter. |
| `BORE_PORT` | (Opsional) Request port spesifik di `bore.pub` (default `0603` / otomatis dinamis). |

---

## 4. Menjalankan sesi

1. Tab **Actions** → **VpsFree — VPS 6 Jam** (`vps-6h.yml`) → **Run workflow**.
2. Tunggu step **Setup akses Bore (SSH Publik)** selesai. Di log akan muncul port tunnel Bore.
3. Konek langsung sebagai user **root** menggunakan password dari terminal (HP/PC/Termux):

```bash
ssh -p <port> root@bore.pub
```

IP dan status juga bisa dibaca dari branch `status` → `vps-status.json`.

---

## 5. Berhenti & perpanjangan (renewal)

- **Auto-stop:** sesi berhenti sendiri 2 menit sebelum `expires_at` (sebelum 6 jam pas) agar runner lama selesai bersih dan runner baru langsung jalan. Batas keras job 360 menit.
- **Auto-backup 20 menit sebelum waktu habis:** `keepalive.sh` otomatis menyimpan checkpoint data sebelum waktu habis.
- **Renewal otomatis 5 menit sebelum waktu habis** (`perpanjang_otomatis=ya`): `keepalive.sh` menyimpan state final lalu otomatis men-dispatch sesi baru ke GitHub Actions. Sesi lama tetap melayani sampai menit ke-348 lalu stop tertib, dan sesi baru langsung menyambung tanpa perlu bolak-balik ke GitHub. Renewal **tidak** menghapus state.
- **State** disimpan setiap 15 menit dan saat sesi berakhir ke GitHub Release tag `vpsfree-state-latest` (asset `vps-state.tar.gz`), plus artifact `vpsfree-state`.
- Yang ikut dipulihkan: isi home (`/home/<user>`), `/etc/ssh/sshd_config.d`, dan `/var/lib/tailscale` (agar node Tailscale memakai identitas/IP yang sama).

> Saat state dipulihkan, nama node Tailscale dipertahankan (tidak diganti tiap renewal); nama `<prefix>-<nomor-run>` hanya dipakai pada sesi pertama.

> **Menghentikan total:** cancel run yang sedang berjalan **dan** run antrean di tab Actions. Fallback estafet tidak akan men-dispatch ulang saat run di-cancel, tetapi sesi estafet yang sudah terjadwal tetap berjalan bila tidak di-cancel.

> Catatan: runner GitHub-hosted adalah mesin ephemeral, jadi perpindahan sesi tidak bisa benar-benar 100% tanpa jeda. Implementasi meminimalkan downtime dan mempertahankan data + identitas Tailscale. Untuk nol-downtime sejati, pakai runner Ubuntu **self-hosted**.

---

## 6. Struktur repository

```
.github/workflows/
  vps-6h.yml        # sesi VPS (schema 6)
  validate-vps.yml  # bash -n + ShellCheck
scripts/
  lib-common.sh     # helper: logger, baca/tulis out/vps-status.json
  setup-vps.sh      # root/user sudo, SSH, firewall, status awal
  setup-akses.sh    # Tailscale + pembatasan SSH ke tailnet
  restore-state.sh  # pulihkan state sesi sebelumnya
  persist-state.sh  # simpan state (--checkpoint untuk berkala)
  publish-status.sh # publikasi status ke branch status
  keepalive.sh      # heartbeat, checkpoint, handover, auto-stop
  finalize-vps.sh   # putuskan Tailscale sesi ini
  cleanup-actions.sh# hapus run lama
```

---

## 7. Validasi

```bash
for f in scripts/*.sh; do bash -n "$f"; done
shellcheck --severity=error scripts/*.sh
```

CI menjalankan keduanya lewat `.github/workflows/validate-vps.yml` (dipicu saat `scripts/**` berubah).

---

## 8. Keamanan, batasan, dan limit GitHub

- SSH hanya lewat tailnet; ufw menolak inbound selain `tailscale0` / `100.64.0.0/10` ke port 22.
- Port 22 runner GitHub tidak punya inbound publik.
- Jangan menaruh password/auth key di file, log, atau status. `.gitignore` sudah mengabaikan `*.env` dan `out/`.
- **Gunakan repository private.** State Tailscale (`/var/lib/tailscale`) berisi kunci node dan ikut disimpan agar IP tetap sama; Release/artifact bisa dibaca siapa pun bila repo publik. Password tidak pernah ikut disimpan.
- Runner GitHub-hosted bersifat **ephemeral** (VM baru per job) dan job dibatasi **6 jam**. Karena itu durasi dibatasi 342 menit + timeout job 360 menit.
- Batas penyimpanan artifact mengikuti plan GitHub (Free 500 MB / Pro 1 GB / Team 2 GB); asset Release maksimal 2 GB. Bila state terlalu besar, upload artifact bisa gagal (dilewati, job tetap lanjut) dan Release menjadi sumber utama.
- Renewal bisa tertunda bila ada run lain di antrean (concurrency group `vpsfree-active-session`).
- Tidak ada jaminan bebas suspend dari GitHub, kelangsungan IP di luar tailnet, atau cakupan provider Tailscale.
- Gunakan auth key yang bisa dicabut bila perangkat hilang.

---

## 9. Menjalankan via Docker (Opsional)

Selain dijalankan di GitHub Actions, VpsFree juga dapat di-build dan dijalankan sebagai container Docker mandiri:

```bash
# Build image
docker build -t vpsfree .

# Jalankan container (terhubung otomatis ke bore.pub)
docker run -d \
  --name vpsfree \
  --restart unless-stopped \
  -e VPS_PASSWORD="PasswordKuat123" \
  -e BORE_PORT="0603" \
  -e VPS_USER="vps" \
  vpsfree

# Cek port SSH publik yang didapat dari bore:
docker logs vpsfree | grep "SSH Command"
```

