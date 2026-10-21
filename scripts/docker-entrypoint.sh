#!/usr/bin/env bash
# ============================================================================
#  docker-entrypoint.sh — Entrypoint untuk VpsFree dalam container Docker.
#   1) Set password root & user sudo dari env VPS_PASSWORD
#   2) Pastikan TUN device siap
#   3) Jalankan tailscaled daemon & sambungkan ke Tailscale jika ada auth key
#   4) Jalankan sshd & jaga container tetap hidup
# ============================================================================
set -eo pipefail

log() {
  printf '[%s] [VpsFree:Docker] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

# 1. Validasi Password
VPS_PASSWORD="${VPS_PASSWORD:-}"
if [ -z "$VPS_PASSWORD" ] || [ "${#VPS_PASSWORD}" -lt 8 ]; then
  log "ERROR: Environment variable VPS_PASSWORD belum diset atau kurang dari 8 karakter."
  exit 1
fi

# Set password root
echo "root:${VPS_PASSWORD}" | chpasswd
log "Password root berhasil diset."

# 2. Setup User Tambahan (default: vps)
VPS_USER="${VPS_USER:-vps}"
if [ "$VPS_USER" != "root" ]; then
  if ! id -u "$VPS_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$VPS_USER"
    log "User '$VPS_USER' dibuat."
  fi
  echo "$VPS_USER:${VPS_PASSWORD}" | chpasswd
  usermod -aG sudo "$VPS_USER" 2>/dev/null || true
  echo "$VPS_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-vpsfree
  chmod 440 /etc/sudoers.d/90-vpsfree
  log "User sudo '$VPS_USER' siap."
fi

# 3. Pastikan TUN device ada
if [ ! -d /dev/net ]; then
  mkdir -p /dev/net
fi
if [ ! -c /dev/net/tun ]; then
  mknod /dev/net/tun c 10 200 2>/dev/null || true
fi

# 4. Jalankan tailscaled daemon
log "Menjalankan tailscaled..."
tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock > /var/log/tailscaled.log 2>&1 &
TAILSCALED_PID=$!

# Tunggu socket tailscaled siap
for _ in $(seq 1 10); do
  if [ -S /var/run/tailscale/tailscaled.sock ]; then
    break
  fi
  sleep 1
done

# 5. Hubungkan ke Tailnet jika TAILSCALE_AUTH_KEY diberikan
if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
  HOST_NAME="${HOSTNAME:-vpsfree-docker}"
  log "Menghubungkan ke Tailscale tailnet sebagai '$HOST_NAME'..."
  # shellcheck disable=SC2086
  tailscale up \
    --authkey="${TAILSCALE_AUTH_KEY}" \
    --hostname="${HOST_NAME}" \
    --accept-dns=false \
    ${TAILSCALE_EXTRA_ARGS:-} || {
      log "WARNING: 'tailscale up' gagal. Periksa auth key atau permission jaringan."
    }

  TS_IP="$(tailscale ip -4 2>/dev/null || true)"
  if [ -n "$TS_IP" ]; then
    log "Tailscale terhubung! IP: $TS_IP"
  fi
else
  log "PEMBERITAHUAN: TAILSCALE_AUTH_KEY tidak diisi. Hubungkan manual dengan 'tailscale up'."
fi

# 6. Jalankan SSH Daemon
log "Menjalankan sshd..."
mkdir -p /var/run/sshd
/usr/sbin/sshd

log "VPS Container siap melayani koneksi SSH."

# Trap sinyal terminasi untuk shutdown bersih
cleanup() {
  log "Menghentikan layanan..."
  kill -TERM "$TAILSCALED_PID" 2>/dev/null || true
  pkill -TERM sshd 2>/dev/null || true
  wait "$TAILSCALED_PID" 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT

# Jaga container tetap berjalan
wait "$TAILSCALED_PID"
