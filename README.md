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
| `BORE_PORT` | (Opsional) Tidak perlu diset. Port otomatis dialokasikan dan disimpan agar tetap sama saat renewal. |

---

## 4. Menjalankan sesi

1. Tab **Actions** → **VpsFree — VPS 6 Jam** (`vps-6h.yml`) → **Run workflow**.
2. Tunggu step **Setup akses Bore (SSH Publik)** selesai. Di log akan muncul port tunnel Bore.
3. Konek langsung sebagai user **root** menggunakan password dari terminal (HP/PC/Termux):

```bash
ssh -p <port> root@bore.pub
```

Status dan port aktif juga otomatis tercatat di branch `status` → `vps-status.json`.

---

## 5. Berhenti & perpanjangan (renewal)

- **Batas Waktu GitHub Actions:** Runner GitHub Actions memiliki batas keras maksimum **6 jam (360 menit)** per job.
- **Renewal Otomatis Antar Sesi:** Agar VPS bisa berjalan terus tanpa batas 6 jam, `keepalive.sh` otomatis men-dispatch sesi 6 jam berikutnya sebelum waktu habis (`perpanjang_otomatis=ya`).
- **Konsistensi Port saat Renewal:** Port yang dialokasikan di sesi pertama disimpan ke `/etc/vpsfree/bore_port` dan dipulihkan saat renewal, sehingga Anda tetap menggunakan port yang sama (`ssh -p <port> root@bore.pub`) di setiap perpanjangan sesi tanpa perlu ganti port!

> Saat state dipulihkan, port Bore dipertahankan antar renewal.

> **Menghentikan total:** cancel run yang sedang berjalan **dan** run antrean di tab Actions. Fallback estafet tidak akan men-dispatch ulang saat run di-cancel, tetapi sesi estafet yang sudah terjadwal tetap berjalan bila tidak di-cancel.

> Catatan: runner GitHub-hosted adalah mesin ephemeral, jadi perpindahan sesi tidak bisa benar-benar 100% tanpa jeda. Implementasi meminimalkan downtime dan mempertahankan data + port Bore. Untuk nol-downtime sejati, pakai runner Ubuntu **self-hosted**.

---

## 6. Struktur repository

```
.github/workflows/
  vps-6h.yml        # sesi VPS (schema 6)
  validate-vps.yml  # bash -n + ShellCheck
scripts/
  lib-common.sh     # helper: logger, baca/tulis out/vps-status.json
  setup-vps.sh      # root/user sudo, SSH, firewall, status awal
  setup-akses.sh    # tunnel Bore (bore.pub) untuk SSH publik
  restore-state.sh  # pulihkan state sesi sebelumnya
  persist-state.sh  # simpan state (--checkpoint untuk berkala)
  publish-status.sh # publikasi status ke branch status
  keepalive.sh      # heartbeat, checkpoint, handover, auto-stop
  finalize-vps.sh   # hentikan tunnel Bore sesi ini
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

- SSH hanya lewat Bore tunnel (bore.pub); port 22 runner GitHub tidak punya inbound publik langsung.
- Port 22 runner GitHub tidak punya inbound publik.
- Jangan menaruh password/auth key di file, log, atau status. `.gitignore` sudah mengabaikan `*.env` dan `out/`.
- **Gunakan repository private.** State sesi (home & konfigurasi SSH) disimpan di Release/artifact yang bisa dibaca siapa pun bila repo publik. Password tidak pernah ikut disimpan.
- Runner GitHub-hosted bersifat **ephemeral** (VM baru per job) dan job dibatasi **6 jam**. Karena itu durasi dibatasi 340 menit + timeout job 360 menit.
- Batas penyimpanan artifact mengikuti plan GitHub (Free 500 MB / Pro 1 GB / Team 2 GB); asset Release maksimal 2 GB. Bila state terlalu besar, upload artifact bisa gagal (dilewati, job tetap lanjut) dan Release menjadi sumber utama.
- Renewal bisa tertunda bila ada run lain di antrean (concurrency group `vpsfree-active-session`).
- Tidak ada jaminan bebas suspend dari GitHub, kelangsungan port Bore publik.
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

