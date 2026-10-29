#!/usr/bin/env bash
# ============================================================================
#  docker-entrypoint.sh — Entrypoint untuk VpsFree dalam container Docker (Bore)
#   1) Set password root SSH dari env VPS_PASSWORD (default: Akunff+62)
#   2) Jalankan OpenSSH Server di port 22 (PermitRootLogin & PasswordAuthentication)
#   3) Jalankan Bore TCP Tunnel di latar belakang (port stabil dari /etc/vpsfree/bore_port)
#   4) Tampilkan bore.pub & port di console (stdout) untuk akses SSH
#   5) Jalankan HTTP healthcheck server untuk cloud container (Koyeb/Render)
#   6) Loop supervisor menjaga container, sshd, dan bore tetap hidup
# ============================================================================
set -e

log() {
  printf '[%s] [VpsFree:Bore] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

echo "=========================================================="
echo "  VpsFree — Ubuntu 22.04 Container"
echo "=========================================================="

# 1. Setup Password Root (default: Akunff+62)
VPS_PASSWORD="${VPS_PASSWORD:-Akunff+62}"
echo "root:${VPS_PASSWORD}" | chpasswd
log "Password root berhasil diset."

# 2. Konfigurasi OpenSSH Server (Port 22, root login, password auth)
mkdir -p /var/run/sshd /etc/ssh/sshd_config.d
cat <<'EOF' > /etc/ssh/sshd_config.d/99-vpsfree.conf
Port 22
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF

log "Menjalankan OpenSSH Server di port 22..."
/usr/sbin/sshd

# 3. Jalankan Bore TCP Tunnel di latar belakang
BORE_SERVER="${BORE_SERVER:-bore.pub}"
BORE_LOG="/tmp/bore.log"

SAVED_PORT=""
if [ -f /etc/vpsfree/bore_port ]; then
  SAVED_PORT="$(cat /etc/vpsfree/bore_port 2>/dev/null | tr -dc '0-9')"
fi
TARGET_PORT="${BORE_PORT:-$SAVED_PORT}"

start_bore() {
  local port_args=()
  if [ -n "$TARGET_PORT" ] && [ "$TARGET_PORT" != "0" ]; then
    port_args=("--port" "$TARGET_PORT")
    log "Menghubungkan bore ke $BORE_SERVER dengan port: $TARGET_PORT (mempertahankan port)..."
  else
    log "Menghubungkan bore ke $BORE_SERVER (alokasi port dinamis)..."
  fi

  bore local 22 --to "$BORE_SERVER" "${port_args[@]}" ${BORE_SECRET:+--secret "$BORE_SECRET"} > "$BORE_LOG" 2>&1 &
  BORE_PID=$!
}

start_bore
sleep 3

# Jika gagal karena port ditolak server, coba alokasi port dinamis
if ! kill -0 "$BORE_PID" 2>/dev/null; then
  log "Port '$TARGET_PORT' ditolak server $BORE_SERVER. Mencoba alokasi port dinamis..."
  bore local 22 --to "$BORE_SERVER" ${BORE_SECRET:+--secret "$BORE_SECRET"} > "$BORE_LOG" 2>&1 &
  BORE_PID=$!
  sleep 3
fi

# Dapatkan port publik dari log bore
REMOTE_PORT=""
for _ in $(seq 1 30); do
  if [ -f "$BORE_LOG" ]; then
    REMOTE_PORT="$(sed 's/\x1b\[[0-9;]*m//g' "$BORE_LOG" 2>/dev/null | grep -oE 'remote_port=[0-9]+' | tail -1 | cut -d= -f2 || true)"
    [ -z "$REMOTE_PORT" ] && REMOTE_PORT="$(sed 's/\x1b\[[0-9;]*m//g' "$BORE_LOG" 2>/dev/null | grep -oE 'listening at [^:]+:[0-9]+' | tail -1 | awk -F: '{print $NF}' || true)"
    [ -n "$REMOTE_PORT" ] && break
  fi
  sleep 1
done

if [ -n "$REMOTE_PORT" ]; then
  mkdir -p /etc/vpsfree
  printf '%s\n' "$REMOTE_PORT" > /etc/vpsfree/bore_port
  echo "=========================================================="
  echo "  BORE TUNNEL AKTIF!"
  echo "  SSH Login (Root): ssh root@bore.pub -p $REMOTE_PORT"
  echo "  Port Terdaftar  : $REMOTE_PORT (port stabil tersimpan)"
  echo "  Password        : $VPS_PASSWORD"
  echo "=========================================================="
else
  echo "=========================================================="
  echo "  PERINGATAN: bore belum terhubung. Cek log: cat $BORE_LOG"
  echo "=========================================================="
fi

# 4. Jalankan HTTP Healthcheck endpoint untuk Cloud PaaS (Koyeb/Render/Railway)
HTTP_PORT="${PORT:-8000}"
mkdir -p /tmp/healthcheck
echo "OK - VpsFree Bore is running" > /tmp/healthcheck/index.html
python3 -m http.server "$HTTP_PORT" --directory /tmp/healthcheck >/dev/null 2>&1 &
log "Healthcheck HTTP server aktif di port $HTTP_PORT"

# 5. Handler shutdown bersih
cleanup() {
  log "Menghentikan layanan..."
  kill -TERM "$BORE_PID" 2>/dev/null || true
  pkill -TERM sshd 2>/dev/null || true
  pkill -f "http.server" 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT

# 6. Supervisor Loop agar container tetap hidup
while true; do
  if ! kill -0 "$BORE_PID" 2>/dev/null; then
    log "WARNING: bore terhenti, merestart tunnel..."
    start_bore
  fi
  if ! pgrep -x sshd >/dev/null 2>&1; then
    log "WARNING: sshd terhenti, merestart..."
    /usr/sbin/sshd
  fi
  sleep 10
done
