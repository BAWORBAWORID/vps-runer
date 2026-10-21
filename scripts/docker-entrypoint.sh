#!/usr/bin/env bash
# ============================================================================
#  docker-entrypoint.sh — Entrypoint untuk VpsFree dalam container Docker.
#   1) Set password root & user sudo dari env VPS_PASSWORD
#   2) Deteksi TUN device atau otomatis beralih ke mode userspace-networking
#   3) Jalankan tailscaled daemon & sambungkan ke Tailscale dengan Tailscale SSH
#   4) Jalankan sshd & HTTP healthcheck server untuk cloud container (Koyeb/dll)
#   5) Loop supervisor untuk menjaga container tetap hidup
# ============================================================================
set -e

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

# 3. Deteksi TUN Device atau beralih ke Userspace Networking
TUN_MODE="tun"
if [ ! -d /dev/net ]; then
  mkdir -p /dev/net 2>/dev/null || true
fi
if [ ! -c /dev/net/tun ]; then
  mknod /dev/net/tun c 10 200 2>/dev/null || true
fi

# Tes apakah TUN device bisa dibuka
if [ ! -c /dev/net/tun ] || ! (exec 3<>/dev/net/tun) 2>/dev/null; then
  log "TUN device tidak dapat diakses (lingkungan cloud container). Menggunakan mode userspace-networking..."
  TUN_MODE="userspace"
fi

# 4. Jalankan tailscaled daemon
mkdir -p /var/run/tailscale /var/lib/tailscale /var/log
TAILSCALED_ARGS=(
  "--state=/var/lib/tailscale/tailscaled.state"
  "--socket=/var/run/tailscale/tailscaled.sock"
)

if [ "$TUN_MODE" = "userspace" ]; then
  TAILSCALED_ARGS+=("--tun=userspace-networking")
fi

log "Menjalankan tailscaled (mode: $TUN_MODE)..."
tailscaled "${TAILSCALED_ARGS[@]}" > /var/log/tailscaled.log 2>&1 &
TAILSCALED_PID=$!

# Verifikasi apakah tailscaled hidup, jika crash langsung beralih ke userspace
sleep 2
if ! kill -0 "$TAILSCALED_PID" 2>/dev/null; then
  log "tailscaled gagal dengan TUN, beralih ke mode userspace-networking..."
  tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock --tun=userspace-networking > /var/log/tailscaled.log 2>&1 &
  TAILSCALED_PID=$!
fi

# Tunggu socket tailscaled siap (max 15 detik)
for _ in $(seq 1 15); do
  if [ -S /var/run/tailscale/tailscaled.sock ]; then
    break
  fi
  sleep 1
done

# 5. Hubungkan ke Tailnet jika TAILSCALE_AUTH_KEY diberikan
if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
  HOST_NAME="${HOSTNAME:-vpsfree-docker}"
  log "Menghubungkan ke Tailscale tailnet sebagai '$HOST_NAME'..."

  UP_ARGS=(
    --authkey="${TAILSCALE_AUTH_KEY}"
    --hostname="${HOST_NAME}"
    --accept-dns=false
    --ssh
  )

  # shellcheck disable=SC2086
  if tailscale up "${UP_ARGS[@]}" ${TAILSCALE_EXTRA_ARGS:-}; then
    TS_IP="$(tailscale ip -4 2>/dev/null || true)"
    log "Tailscale berhasil terhubung! IP: ${TS_IP:-ok} (Tailscale SSH aktif)"
  else
    log "WARNING: 'tailscale up' gagal. Menampilkan log tailscaled:"
    tail -n 25 /var/log/tailscaled.log || true
  fi
else
  log "PEMBERITAHUAN: TAILSCALE_AUTH_KEY tidak diisi. Hubungkan manual dengan 'tailscale up'."
fi

# 6. Jalankan SSH Daemon (OpenSSH)
log "Menjalankan sshd..."
mkdir -p /var/run/sshd
/usr/sbin/sshd

# 7. Jalankan HTTP Healthcheck endpoint untuk Cloud PaaS (Koyeb/Render/Railway)
HTTP_PORT="${PORT:-8000}"
mkdir -p /tmp/healthcheck
echo "OK - VpsFree is running" > /tmp/healthcheck/index.html
python3 -m http.server "$HTTP_PORT" --directory /tmp/healthcheck >/dev/null 2>&1 &
log "Healthcheck HTTP server aktif di port $HTTP_PORT"

log "VPS Container siap melayani koneksi SSH."

# 8. Handler shutdown bersih
cleanup() {
  log "Menghentikan layanan..."
  kill -TERM "$TAILSCALED_PID" 2>/dev/null || true
  pkill -TERM sshd 2>/dev/null || true
  pkill -f "http.server" 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT

# 9. Supervisor Loop agar container tetap hidup
while true; do
  if ! kill -0 "$TAILSCALED_PID" 2>/dev/null; then
    log "WARNING: tailscaled terhenti, merestart..."
    tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock --tun=userspace-networking >> /var/log/tailscaled.log 2>&1 &
    TAILSCALED_PID=$!
  fi
  if ! pgrep -x sshd >/dev/null 2>&1; then
    log "WARNING: sshd terhenti, merestart..."
    /usr/sbin/sshd
  fi
  sleep 10
done
