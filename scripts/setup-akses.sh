#!/usr/bin/env bash
# ============================================================================
#  setup-akses.sh — akses SSH publik via Bore tunnel (bore.pub).
#   1) pasang bore resmi bila belum ada
#   2) cek port dari sesi sebelumnya (renewal) agar port tidak berubah
#   3) jalankan tunnel: bore local 22 --to bore.pub [--port <saved_port>]
#   4) tangkap port publik dari log bore (bersihkan escape code ANSI)
#   5) simpan port ke /etc/vpsfree/bore_port & out/vps-status.json
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
BORE_LOG="/tmp/bore.log"
touch "$BORE_LOG" 2>/dev/null || sudo touch "$BORE_LOG" 2>/dev/null || true
chmod 666 "$BORE_LOG" 2>/dev/null || sudo chmod 666 "$BORE_LOG" 2>/dev/null || true

# 1. Cek port dari sesi sebelumnya (agar port tetap sama saat renewal)
SAVED_PORT=""
if [ -f /etc/vpsfree/bore_port ]; then
  SAVED_PORT="$(cat /etc/vpsfree/bore_port 2>/dev/null | tr -dc '0-9')"
fi
if [ -z "$SAVED_PORT" ]; then
  SAVED_PORT="$(read_status | jq -r '.bore_port // empty' 2>/dev/null | tr -dc '0-9')"
fi

# Jika BORE_PORT eksplisit diset di env, gunakan itu; bila tidak, pakai port sesi sebelumnya
TARGET_PORT="${BORE_PORT:-$SAVED_PORT}"

start_bore() {
  local port_args=()
  if [ -n "$TARGET_PORT" ] && [ "$TARGET_PORT" != "0" ]; then
    port_args=("--port" "$TARGET_PORT")
    log "menghubungkan bore ke $BORE_SERVER dengan port: $TARGET_PORT (mempertahankan port)..."
  else
    log "menghubungkan bore ke $BORE_SERVER (alokasi port dinamis otomatis)..."
  fi

  sudo pkill -f "bore local" 2>/dev/null || true
  nohup bore local 22 --to "$BORE_SERVER" "${port_args[@]}" ${BORE_SECRET:+--secret "$BORE_SECRET"} > "$BORE_LOG" 2>&1 &
}

start_bore
sleep 3

# Jika target port ditolak server (misal port bentrok), coba alokasi port dinamis
if ! pgrep -f "bore local" >/dev/null 2>&1; then
  log "port '$TARGET_PORT' ditolak server $BORE_SERVER. Mencoba alokasi port dinamis otomatis..."
  nohup bore local 22 --to "$BORE_SERVER" ${BORE_SECRET:+--secret "$BORE_SECRET"} > "$BORE_LOG" 2>&1 &
  sleep 3
fi

REMOTE_PORT=""
for _ in $(seq 1 20); do
  if [ -f "$BORE_LOG" ]; then
    # Bersihkan ANSI escape codes sebelum parsing port
    REMOTE_PORT="$(sed 's/\x1b\[[0-9;]*m//g' "$BORE_LOG" 2>/dev/null | grep -oE 'remote_port=[0-9]+' | tail -1 | cut -d= -f2 || true)"
    [ -z "$REMOTE_PORT" ] && REMOTE_PORT="$(sed 's/\x1b\[[0-9;]*m//g' "$BORE_LOG" 2>/dev/null | grep -oE 'listening at [^:]+:[0-9]+' | tail -1 | awk -F: '{print $NF}' || true)"
    [ -n "$REMOTE_PORT" ] && break
  fi
  sleep 1
done

if [ -z "$REMOTE_PORT" ] || ! pgrep -f "bore local" >/dev/null 2>&1; then
  log 'ERROR: Bore tunnel gagal terhubung. Log:'
  cat "$BORE_LOG" 2>/dev/null || true
  update_status "$(jq -n '{akses:{mode:"bore",bore:{status:"failed",note:"bore up gagal"}}}' )" || true
  exit 1
fi

# ---------- cloudflared tunnel (opsional) ----------
if [ -n "${CLOUDFLARED_TOKEN:-}" ] && command -v cloudflared >/dev/null 2>&1; then
  log 'menjalankan cloudflared tunnel...'
  sudo cloudflared service uninstall >/dev/null 2>&1 || true
  sudo pkill -f cloudflared 2>/dev/null || true
  sleep 1

  # Write token to file then install as systemd service
  # Using direct systemd unit approach for reliability
  printf '%s\n' "$CLOUDFLARED_TOKEN" | sudo tee /etc/cloudflared/token > /dev/null
  sudo chmod 600 /etc/cloudflared/token

  sudo tee /etc/systemd/system/cloudflared.service > /dev/null << 'SEOF'
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --no-autoupdate tunnel run --token-file /etc/cloudflared/token
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SEOF

  sudo systemctl daemon-reload
  sudo systemctl enable cloudflared
  if sudo systemctl start cloudflared 2>&1; then
    log 'cloudflared tunnel aktif (systemd).'
  else
    log 'PERINGATAN: cloudflared service start gagal.'
  fi
fi

# Simpan port ke /etc/vpsfree/bore_port agar terbawa saat renewal
sudo mkdir -p /etc/vpsfree
printf '%s\n' "$REMOTE_PORT" | sudo tee /etc/vpsfree/bore_port >/dev/null
sudo chmod 644 /etc/vpsfree/bore_port

SSH_CMD="ssh -p $REMOTE_PORT root@$BORE_SERVER"
PUBLIC_IP="$(curl -fsS --connect-timeout 8 --max-time 15 https://api.ipify.org 2>/dev/null || echo '')"

update_status "$(jq -n \
  --arg bserver "$BORE_SERVER" --arg bport "$REMOTE_PORT" --arg ssh_cmd "$SSH_CMD" --arg pub "$PUBLIC_IP" \
  --arg note "Akses SSH via Bore tunnel: $SSH_CMD" \
  '{public_ip:$pub, bore_server:$bserver, bore_port:$bport, ssh_command:$ssh_cmd,
    akses:{mode:"bore", bore:{status:"ok", server:$bserver, port:$bport,
      command_root:$ssh_cmd, note:$note}}}' 2>&1)"

log "=========================================================="
log "BORE TUNNEL AKTIF!"
log "SSH Login (Root): $SSH_CMD"
log "Port Terdaftar  : $REMOTE_PORT (akan dipertahankan saat renewal)"
log "Password        : (sesuai secret VPS_PASSWORD)"
log "=========================================================="
exit 0
