# VpsFree

VPS **Ubuntu Server** yang dijalankan oleh **GitHub Actions** atau **Docker**, diakses lewat **SSH publik melalui Bore tunnel** (`bore.pub`) dan/atau **Cloudflare Tunnel**.

Kredit asli: **KallAncrit**. Template: `xykal/XyRDP`.

---

## 1. Cara kerja singkat

Setiap kali workflow dijalankan, GitHub menyiapkan satu mesin Ubuntu Server sementara (ephemeral):

1. `setup-vps.sh` — setel password root dari secret `VPS_PASSWORD`, aktifkan SSH (root login, password + pubkey auth), install **cloudflared** jika `CLOUDFLARED_TOKEN` diset, tambahkan SSH public key dari `VPS_SSH_KEY` ke authorized_keys.
2. `restore-state.sh` — pulihkan data sesi sebelumnya (home, konfigurasi SSH).
3. `setup-akses.sh` — pasang dan jalankan **Bore tunnel** (`bore local 22 --to bore.pub`). Jika `CLOUDFLARED_TOKEN` diset, jalankan juga **cloudflared tunnel** sebagai systemd service.
4. `publish-status.sh` — tulis status sesi dan port SSH publik ke branch `status` (`vps-status.json`).
5. `keepalive.sh` — jaga mesin tetap hidup, simpan state tiap 15 menit, jadwalkan sesi berikutnya sebelum waktu habis, hentikan diri sendiri 3 menit sebelum batas waktu.
6. `finalize-vps.sh` — hentikan tunnel Bore **dan** cloudflared saat sesi selesai.

---

## 2. Prasyarat

- Repository dibuat dari template (`Use this template` di GitHub).
- Actions diizinkan pada repository.
- **Repository HARUS private** — state sesi (home, SSH keys) disimpan di Release/artifact.

---

## 3. Secrets

Buka **Settings → Secrets and variables → Actions → New repository secret**.

### Wajib

| Secret | Deskripsi |
|---|---|
| `VPS_PASSWORD` | Password root. **Minimal 8 karakter.** Semua login root & sudo pakai password ini. |

### Opsional — SSH & Akses

| Secret | Default | Deskripsi |
|---|---|---|
| `VPS_SSH_KEY` | (kosong) | Public key SSH (format: `ssh-ed25519 AAAA... comment`) untuk login tanpa password. Ditambahkan ke `/root/.ssh/authorized_keys`. |
| `BORE_PORT` | (random) | Port Bore tunnel tetap — supaya port tidak berubah saat renewal. |
| `BORE_SERVER` | `bore.pub` | Server Bore tunnel. Bisa diganti dengan server Bore custom. |
| `BORE_SECRET` | (kosong) | Secret untuk Bore tunnel authentication (opsional). |

### Opsional — Cloudflare Tunnel

| Secret | Deskripsi |
|---|---|
| `CLOUDFLARED_TOKEN` | Token Cloudflare Tunnel Argo (format: `eyJh...`). Jika diset, auto install + jalankan cloudflared tunnel sebagai systemd service saat VPS menyala. |

### Opsional — Lainnya

| Secret | Default | Deskripsi |
|---|---|---|
| `CLEANUP_TOKEN` | `GITHUB_TOKEN` | Personal Access Token (PAT) untuk cleanup actions. Jika kosong, pakai `GITHUB_TOKEN` bawaan. |

---

## 4. Menjalankan sesi

### Lewat GitHub Actions

1. Buka tab **Actions** → **VpsFree — VPS 6 Jam** (`vps-6h.yml`) → **Run workflow**.
2. (Opsional) Isi input sesuai kebutuhan:
   - `durasi_menit` — durasi sesi (default: 340 menit)
   - `hostname` — prefix hostname (default: vpsfree)
   - `perpanjang_otomatis` — `ya` (default) / `tidak`
3. Tunggu step **Setup akses Bore (SSH Publik)** selesai. Di log akan muncul port tunnel Bore, contoh:
   ```
   SSH Login (Root): ssh -p 34333 root@bore.pub
   Password: (sesuai VPS_PASSWORD)
   ```
4. Konek via SSH:

```bash
# Password auth
ssh -p <port> root@bore.pub

# SSH key auth (jika VPS_SSH_KEY diset)
ssh -i /path/to/private_key -p <port> root@bore.pub
```

### Lewat Docker

```bash
docker build -t vpsfree .

docker run -d \
  --name vpsfree \
  --restart unless-stopped \
  -e VPS_PASSWORD="PasswordKuat123" \
  -e VPS_SSH_KEY="ssh-ed25519 AAAA..." \
  -e BORE_PORT="34333" \
  -e CLOUDFLARED_TOKEN="eyJh..." \
  vpsfree

# Cek port SSH dari log
docker logs vpsfree | grep "SSH Command"
```

---

## 5. Login SSH Tanpa Password

Jika `VPS_SSH_KEY` diset dengan **public key** kamu, VPS runner akan menambahkan key tersebut ke `/root/.ssh/authorized_keys`.

**Contoh setup di komputer kamu:**

```bash
# 1. Generate key pair (jika belum punya)
ssh-keygen -t ed25519 -C "server-aku"

# 2. Lihat public key
cat ~/.ssh/id_ed25519.pub
# Output: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5... comment

# 3. Copy output itu ke GitHub Secret VPS_SSH_KEY

# 4. Login tanpa password
ssh -i ~/.ssh/id_ed25519 -p <port> root@bore.pub
```

---

## 6. Cloudflare Tunnel

Jika `CLOUDFLARED_TOKEN` diset, cloudflared akan:

1. Terinstall otomatis saat `setup-vps.sh` jalan.
2. Dijalankan sebagai **systemd service** saat `setup-akses.sh` selesai.
3. Dihentikan otomatis saat sesi selesai (`finalize-vps.sh`).

Log cloudflared:
```bash
ssh -p <port> root@bore.pub
journalctl -u cloudflared -f
```

---

## 7. Berhenti & Perpanjangan (Renewal)

- **Batas Waktu GitHub Actions:** Runner memiliki batas **6 jam (360 menit)** per job.
- **Renewal Otomatis:** `keepalive.sh` auto men-dispatch sesi baru sebelum waktu habis (jika `perpanjang_otomatis=ya`).
- **Konsistensi Port:** Port Bore disimpan ke `/etc/vpsfree/bore_port` dan dipulihkan saat renewal — port tetap sama.
- **Menghentikan Total:** cancel run yang sedang berjalan **dan** run antrean di tab Actions.

---

## 8. Struktur Repository

```
.github/workflows/
  vps-6h.yml        # sesi VPS (schema 6)
  validate-vps.yml  # bash -n + ShellCheck
scripts/
  lib-common.sh     # helper: logger, baca/tulis out/vps-status.json
  setup-vps.sh      # root/sudo, SSH, firewall, cloudflared install, SSH key
  setup-akses.sh    # tunnel Bore + cloudflared tunnel
  restore-state.sh  # pulihkan state sesi sebelumnya
  persist-state.sh  # simpan state (--checkpoint untuk berkala)
  publish-status.sh # publikasi status ke branch status
  keepalive.sh      # heartbeat, checkpoint, handover, auto-stop
  finalize-vps.sh   # hentikan tunnel Bore + cloudflared
  cleanup-actions.sh# hapus run lama GitHub Actions
```

---

## 9. Validasi

```bash
for f in scripts/*.sh; do bash -n "$f"; done
shellcheck --severity=error scripts/*.sh
```

CI menjalankan keduanya lewat `.github/workflows/validate-vps.yml` (dipicu saat `scripts/**` berubah).

---

## 10. Keamanan & Batasan

- SSH hanya lewat **Bore tunnel** (`bore.pub`) — port 22 runner GitHub tidak langsung exposed.
- **Gunakan repository private.** State (home + SSH keys) disimpan di Release/artifact.
- **Jangan taruh private key di secrets/state.** VPS_SSH_KEY hanya menerima **public key**.
- Runner GitHub-hosted **ephemeral** (VM baru per job), job dibatasi **6 jam**.
- Batas artifact: Free 500 MB / Pro 1 GB / Team 2 GB.
- Gunakan auth key yang bisa dicabut bila perangkat hilang.
