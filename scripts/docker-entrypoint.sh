#!/usr/bin/env bash
# ============================================================================
#  docker-entrypoint.sh — Entrypoint untuk VpsFree dalam container Docker (Bore)
#   1) Set password root SSH dari env VPS_PASSWORD
#   2) Jalankan OpenSSH Server di port 22 (PermitRootLogin & PasswordAuthentication)
#   3) Hubungkan TCP tunnel ke Bore (bore local 22 --to bore.pub --port $BORE_PORT)
#   4) Jalankan HTTP healthcheck server untuk cloud container (Koyeb/Render)
#   5) Loop supervisor menjaga container, sshd, dan bore tetap hidup
# ============================================================================
set -e

log() {
  printf '[%s] [VpsFree:Bore] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

# 1. Setup Password Root
VPS_PASSWORD="${VPS_PASSWORD:-}"
if [ -n "$VPS_PASSWORD" ]; then
  echo "root:${VPS_PASSWORD}" | chpasswd
  log "Password root berhasil diset."
else
  VPS_PASSWORD="rootpassword123"
  echo "root:${VPS_PASSWORD}" | chpasswd
  log "PERINGATAN: VPS_PASSWORD tidak diset. Password default: rootpassword123"
fi

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

# 3. Jalankan Bore TCP Tunnel
BORE_SERVER="${BORE_SERVER:-bore.pub}"
BORE_PORT="${BORE_PORT:-0603}"
BORE_LOG="/tmp/bore.log"

start_bore() {
  local port_args=()
  if [ -n "$BORE_PORT" ] && [ "$BORE_PORT" != "0" ]; then
    port_args=("--port" "$BORE_PORT")
  fi

  log "Menghubungkan tunnel bore ke $BORE_SERVER..."
  bore local 22 --to "$BORE_SERVER" "${port_args[@]}" ${BORE_SECRET:+--secret "$BORE_SECRET"} > "$BORE_LOG" 2>&1 &
  BORE_PID=$!
}

start_bore
sleep 3

# Jika gagal karena port ditolak server, coba tanpa flag --port (alokasi port dinamis)
if ! kill -0 "$BORE_PID" 2>/dev/null; then
  log "Port '$BORE_PORT' ditolak oleh server $BORE_SERVER. Mencoba alokasi port dinamis..."
  bore local 22 --to "$BORE_SERVER" ${BORE_SECRET:+--secret "$BORE_SECRET"} > "$BORE_LOG" 2>&1 &
  BORE_PID=$!
  sleep 3
fi

# Dapatkan port publik dari log bore
REMOTE_PORT=""
for _ in $(seq 1 15); do
  if [ -f "$BORE_LOG" ]; then
    REMOTE_PORT="$(grep -oE 'remote_port=[0-9]+' "$BORE_LOG" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
    [ -z "$REMOTE_PORT" ] && REMOTE_PORT="$(grep -oE 'listening at [^:]+:[0-9]+' "$BORE_LOG" 2>/dev/null | tail -1 | awk -F: '{print $NF}' || true)"
    [ -n "$REMOTE_PORT" ] && break
  fi
  sleep 1
done

if [ -n "$REMOTE_PORT" ]; then
  log "=========================================================="
  log "BORE TUNNEL AKTIF!"
  log "SSH Login (Root): ssh -p $REMOTE_PORT root@$BORE_SERVER"
  log "Password        : (sesuai env VPS_PASSWORD)"
  log "=========================================================="
else
  log "PERINGATAN: Menunggu koneksi bore. Periksa log: cat $BORE_LOG"
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
