#!/usr/bin/env bash
# ============================================================================
#  setup-akses.sh — akses SSH publik via Bore tunnel (bore.pub).
#   1) pasang bore resmi bila belum ada
#   2) jalankan tunnel: bore local 22 --to bore.pub
#   3) tangkap port publik dari log bore
#   4) catat port/host bore ke out/vps-status.json
#
#  Env: BORE_SERVER (default bore.pub), BORE_PORT (default 0603/auto),
#       BORE_SECRET (opsional).
# ============================================================================
set -uo pipefail
export XY_TAG='VpsFree:bore'
. "$(dirname "$0")/lib-common.sh"

install_bore() {
  if command -v bore >/dev/null 2>&1; then return 0; fi
  log 'memasang bore (binary resmi)...'
  local tmp; tmp="$(mktemp -d)"
  if curl -fsSL --connect-timeout 15 --max-time 60 \
    "https://github.com/ekzhang/bore/releases/download/v0.5.1/bore-v0.5.1-x86_64-unknown-linux-musl.tar.gz" | tar -xz -C "$tmp"; then
    sudo mv "$tmp/bore" /usr/local/bin/bore
    sudo chmod +x /usr/local/bin/bore
    rm -rf "$tmp"
    command -v bore >/dev/null 2>&1 && return 0
  fi
  rm -rf "$tmp"
  if command -v cargo >/dev/null 2>&1; then
    log 'mencoba install bore via cargo...'
    cargo install bore-cli >/dev/null 2>&1 && return 0
  fi
  return 1
}

if ! install_bore; then
  log 'ERROR: unduhan/instalasi bore gagal.'
  update_status "$(jq -n '{akses:{mode:"bore",bore:{status:"failed",note:"install bore gagal"}}}')" || true
  exit 1
fi

BORE_SERVER="${BORE_SERVER:-bore.pub}"
BORE_PORT="${BORE_PORT:-0603}"
sudo mkdir -p /var/log

start_bore() {
  local port_args=()
  if [ -n "$BORE_PORT" ] && [ "$BORE_PORT" != "0" ]; then
    port_args=("--port" "$BORE_PORT")
  fi

  log "menghubungkan tunnel bore ke $BORE_SERVER..."
  sudo pkill -f "bore local" 2>/dev/null || true
  nohup bore local 22 --to "$BORE_SERVER" "${port_args[@]}" ${BORE_SECRET:+--secret "$BORE_SECRET"} > /var/log/bore.log 2>&1 &
}

start_bore
sleep 2

# Verifikasi proses hidup, jika gagal port ditolak coba tanpa --port
if ! pgrep -f "bore local" >/dev/null 2>&1; then
  log "port '$BORE_PORT' ditolak oleh server $BORE_SERVER. Mencoba alokasi port dinamis..."
  nohup bore local 22 --to "$BORE_SERVER" ${BORE_SECRET:+--secret "$BORE_SECRET"} > /var/log/bore.log 2>&1 &
  sleep 2
fi

REMOTE_PORT=""
for _ in $(seq 1 15); do
  if [ -f /var/log/bore.log ]; then
    REMOTE_PORT="$(grep -oE 'remote_port=[0-9]+' /var/log/bore.log 2>/dev/null | tail -1 | cut -d= -f2 || true)"
    [ -z "$REMOTE_PORT" ] && REMOTE_PORT="$(grep -oE 'listening at [^:]+:[0-9]+' /var/log/bore.log 2>/dev/null | tail -1 | awk -F: '{print $NF}' || true)"
    [ -n "$REMOTE_PORT" ] && break
  fi
  sleep 1
done

if [ -z "$REMOTE_PORT" ] || ! pgrep -f "bore local" >/dev/null 2>&1; then
  log 'ERROR: Bore tunnel gagal terhubung. Log:'
  tail -n 25 /var/log/bore.log || true
  update_status "$(jq -n '{akses:{mode:"bore",bore:{status:"failed",note:"bore up gagal"}}}')" || true
  exit 1
fi

SSH_CMD="ssh -p $REMOTE_PORT root@$BORE_SERVER"

PUBLIC_IP="$(curl -fsS --connect-timeout 8 --max-time 15 https://api.ipify.org 2>/dev/null || echo '')"

update_status "$(jq -n \
  --arg bserver "$BORE_SERVER" --arg bport "$REMOTE_PORT" --arg ssh_cmd "$SSH_CMD" --arg pub "$PUBLIC_IP" \
  '{public_ip:$pub, bore_server:$bserver, bore_port:$bport, ssh_command:$ssh_cmd,
    akses:{mode:"bore", bore:{status:"ok", server:$bserver, port:$bport,
      command_root:$ssh_cmd,
      note:"Akses SSH via Bore tunnel: " + $ssh_cmd}}}')"

log "=========================================================="
log "BORE TUNNEL AKTIF!"
log "SSH Login (Root): $SSH_CMD"
log "Password        : (sesuai secret VPS_PASSWORD)"
log "=========================================================="
exit 0
