#!/usr/bin/env bash
# ============================================================================
#  setup-vps.sh — MODE DASAR VpsFree (Ubuntu Server).
#   1) set password superuser/root dari secret VPS_PASSWORD
#   2) buat user sudo (default: vps) dengan password yang sama
#   3) aktifkan SSH password + root login (akses lewat Bore tunnel)
#   4) tulis identitas sesi ke out/vps-status.json (tanpa password)
#
#  Port 22 di VM GitHub-hosted tidak punya inbound publik; hanya ditembus
#  lewat Bore tunnel (bore.pub). Script dijalankan sebagai user runner, pakai sudo.
# ============================================================================
set -uo pipefail
export XY_TAG='VpsFree:base'
. "$(dirname "$0")/lib-common.sh"

if [ -z "${VPS_PASSWORD:-}" ] || [ "${#VPS_PASSWORD}" -lt 8 ]; then
  log 'ERROR: secret VPS_PASSWORD belum di-set / terlalu pendek (min 8 karakter).'; exit 1
fi
case "$VPS_PASSWORD" in
  *$'\n'*|*$'\r'*) log 'ERROR: VPS_PASSWORD tidak boleh mengandung baris baru.'; exit 1;;
esac

# ---------- durasi (menit) ----------
DUR="${DUR:-360}"; DUR="${DUR//[^0-9]/}"; [ -z "$DUR" ] && DUR=342
[ "$DUR" -lt 10 ] && DUR=342
[ "$DUR" -gt 342 ] && DUR=342   # margin aman di bawah timeout workflow 360

# ---------- user ----------
VPS_USER="${VPS_USER:-vps}"
if ! printf '%s' "$VPS_USER" | grep -Eq '^[a-z_][a-z0-9_-]{1,31}$'; then
  log "ERROR: VPS_USER tidak valid (huruf kecil/angka, _ atau -, 2-32 karakter)."; exit 1
fi
case "$VPS_USER" in
  daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|_apt|nobody|systemd-network|sshd) 
    log "ERROR: VPS_USER '$VPS_USER' adalah nama sistem; pilih nama lain."; exit 1;;
esac

HOST_NAME="$(vps_hostname)"
. /etc/os-release 2>/dev/null || true
OS_NAME="${PRETTY_NAME:-Ubuntu}"
KERNEL="$(uname -r)"
CPU="$(nproc 2>/dev/null || echo 0)"
RAM_GB="$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null)"; [ -z "$RAM_GB" ] && RAM_GB=0
DISK_FREE_GB="$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"; [ -z "$DISK_FREE_GB" ] && DISK_FREE_GB=0

log "mode dasar | hostname $HOST_NAME | durasi $DUR menit | user $VPS_USER | OS $OS_NAME ($KERNEL)"

# ---------- paket dasar (curl, wget, jq, git, rsync) ----------
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq curl wget git rsync
elif ! command -v git >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git rsync
fi
sudo systemctl enable --now ssh >/dev/null 2>&1 || sudo systemctl enable --now sshd >/dev/null 2>&1 || true

# ---------- password superuser / root ----------
printf 'root:%s\n' "$VPS_PASSWORD" | sudo chpasswd
log 'password root diset dari VPS_PASSWORD.'

# ---------- user sudo opsional (default tetap layani root) ----------
VPS_USER="${VPS_USER:-root}"
if [ "$VPS_USER" != "root" ]; then
  if ! id -u "$VPS_USER" >/dev/null 2>&1; then
    sudo useradd -m -s /bin/bash "$VPS_USER"
  fi
  printf '%s:%s\n' "$VPS_USER" "$VPS_PASSWORD" | sudo chpasswd
  sudo usermod -aG sudo "$VPS_USER" 2>/dev/null || true
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$VPS_USER" | sudo tee /etc/sudoers.d/90-vpsfree >/dev/null
  sudo chmod 440 /etc/sudoers.d/90-vpsfree
fi

# ---------- sshd: Port 22 + PermitRootLogin + PasswordAuthentication ----------
sudo mkdir -p /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/99-vpsfree.conf > /dev/null <<'EOF'
Port 22
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
EOF

if ! sudo sshd -t 2>/dev/null; then
  log 'ERROR: konfigurasi sshd tidak valid setelah drop-in.'
  sudo rm -f /etc/ssh/sshd_config.d/99-vpsfree.conf
fi
sudo systemctl restart ssh >/dev/null 2>&1 || sudo systemctl restart sshd >/dev/null 2>&1 || true

# Verifikasi nilai EFEKTIF
EFF_ROOT="$(sudo sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')"
EFF_PW="$(sudo sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')"
if [ "$EFF_ROOT" != 'yes' ] || [ "$EFF_PW" != 'yes' ]; then
  log "menimpa langsung di sshd_config (root='$EFF_ROOT', password='$EFF_PW')..."
  printf '\nPort 22\nPermitRootLogin yes\nPasswordAuthentication yes\n' | sudo tee -a /etc/ssh/sshd_config >/dev/null
  sudo systemctl restart ssh >/dev/null 2>&1 || sudo systemctl restart sshd >/dev/null 2>&1 || true
fi

if ss -ltn 2>/dev/null | grep -q ':22 '; then
  SSH_LISTEN='ok'
else
  SSH_LISTEN='belum terdeteksi'
fi
log "sshd port 22: $SSH_LISTEN | PermitRootLogin=$EFF_ROOT PasswordAuthentication=$EFF_PW"
if [ "$EFF_ROOT" != 'yes' ] || [ "$EFF_PW" != 'yes' ]; then
  log 'PERINGATAN: login root/password belum aktif sesuai konfigurasi efektif.'
fi

# ---------- SSH public key dari secret VPS_SSH_KEY ----------
if [ -n "${VPS_SSH_KEY:-}" ]; then
  sudo mkdir -p /root/.ssh
  sudo chmod 700 /root/.ssh
  printf '%s\n' "$VPS_SSH_KEY" | sudo tee -a /root/.ssh/authorized_keys > /dev/null
  sudo chmod 600 /root/.ssh/authorized_keys
  log "SSH public key ditambahkan ke authorized_keys (VPS_SSH_KEY)."
fi

# ---------- firewall: allow port 22 & outgoing ----------
if command -v ufw >/dev/null 2>&1; then
  sudo ufw --force reset >/dev/null 2>&1 || true
  sudo ufw default deny incoming >/dev/null 2>&1 || true
  sudo ufw default allow outgoing >/dev/null 2>&1 || true
  sudo ufw allow 22/tcp >/dev/null 2>&1 || true
  sudo ufw --force enable >/dev/null 2>&1 || true
  log 'ufw aktif: allow 22/tcp & all outgoing.'
fi

# ---------- Node.js v22 ----------
NODE_CURRENT="$(node -v 2>/dev/null | tr -dc '0-9' || echo '0')"
if [ "$NODE_CURRENT" -lt 22 ]; then
  log 'menginstal Node.js v22...'
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash - 2>/dev/null || true
  sudo apt-get install -y -qq nodejs 2>/dev/null || true
fi
NODE_VER="$(node -v 2>/dev/null || echo 'none')"
log "Node.js: $NODE_VER"

# ---------- pnpm + yarn + n (Node version manager) ----------
if ! command -v pnpm >/dev/null 2>&1; then
  log 'menginstal pnpm...'
  npm install -g pnpm 2>/dev/null || curl -fsSL https://get.pnpm.io/install.sh | sudo bash - 2>/dev/null || true
fi
PNPM_VER="$(pnpm -v 2>/dev/null || echo 'none')"
log "pnpm: $PNPM_VER"

if ! command -v yarn >/dev/null 2>&1; then
  log 'menginstal yarn...'
  npm install -g yarn 2>/dev/null || true
fi
YARN_VER="$(yarn -v 2>/dev/null || echo 'none')"
log "yarn: $YARN_VER"

if ! command -v n >/dev/null 2>&1; then
  log 'menginstal n (Node version manager)...'
  npm install -g n 2>/dev/null || true
fi

# ---------- PM2 global ----------
if ! command -v pm2 >/dev/null 2>&1; then
  log 'menginstal pm2...'
  npm install -g pm2 2>/dev/null || true
fi
PM2_VER="$(pm2 -v 2>/dev/null | head -1 || echo 'none')"
log "pm2: $PM2_VER"

# ---------- git (PPA latest) ----------
if ! command -v git >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
  log 'menginstal git & rsync...'
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git rsync 2>/dev/null || true
fi
GIT_VER="$(git --version 2>/dev/null | awk '{print $3}' || echo 'none')"
log "git: $GIT_VER | rsync: $(command -v rsync >/dev/null 2>&1 && echo 'ok' || echo 'missing')"

# ---------- ufw ----------
if ! command -v ufw >/dev/null 2>&1; then
  log 'menginstal ufw...'
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw 2>/dev/null || true
fi

# ---------- auto-start router dari state yang direstore ----------
if [ -d "/root/Codex-Router" ] && [ -f "/root/Codex-Router/package.json" ]; then
  log 'router Codex-Router terdeteksi di /root — setup auto-start...'

  # Install dependencies
  if [ -f "/root/Codex-Router/pnpm-lock.yaml" ]; then
    cd /root/Codex-Router
    pnpm install --silent 2>/dev/null || true
    pnpm build 2>/dev/null || true
    log 'router build selesai.'
  fi

  # Create ecosystem config for PM2
  cat > /root/Codex-Router/ecosystem.config.cjs << 'EOF'
module.exports = {
  apps: [{
    name: 'router',
    script: 'apps/api/dist/index.js',
    cwd: '/root/Codex-Router',
    instances: 1,
    exec_mode: 'fork',
    env: {
      PORT: 4000,
      DATABASE_PATH: '/root/.srouter/srouter.db',
      NODE_ENV: 'production',
    },
  }],
};
EOF

  # Create run.sh for easy restart (router + cloudflared tunnel)
  cat > /root/run.sh << 'RUNEOF'
#!/bin/bash
# Auto-start Codex-Router + Cloudflared Tunnel via PM2
# Usage: bash /root/run.sh

CLOUDFLARED_TOKEN="${CLOUDFLARED_TOKEN:-}"
ROUTER_DIR="/root/Codex-Router"
SROUTER_DB="/root/.srouter/srouter.db"

echo "=== Auto-Start Codex-Router ==="

# --- Router ---
cd "$ROUTER_DIR"

# Install deps if needed
if [ -d node_modules ] && [ -f pnpm-lock.yaml ]; then
  echo "[1/4] Installing dependencies..."
  pnpm install --silent 2>/dev/null || pnpm install
fi

# Build if dist missing
if [ ! -f apps/api/dist/index.js ] && [ -f pnpm-lock.yaml ]; then
  echo "[2/4] Building router..."
  pnpm build
fi

# Kill existing router
pm2 delete router 2>/dev/null || true

# Start with PM2
echo "[3/4] Starting router via PM2..."
pm2 start ecosystem.config.cjs
pm2 save

echo ""
echo "=== Router Status ==="
pm2 status

# --- Cloudflared Tunnel ---
if [ -n "$CLOUDFLARED_TOKEN" ] && command -v cloudflared >/dev/null 2>&1; then
  echo ""
  echo "=== Auto-Start Cloudflared Tunnel ==="

  # Uninstall existing service first
  echo "[1/3] Uninstalling old cloudflared service..."
  cloudflared service uninstall 2>/dev/null || true
  sudo cloudflared service uninstall 2>/dev/null || true

  # Remove stale files
  sudo rm -f /etc/systemd/system/cloudflared.service 2>/dev/null || true
  sudo rm -f /etc/cloudflared/config.yml 2>/dev/null || true
  sudo rm -f /etc/cloudflared/token 2>/dev/null || true

  # Kill existing processes
  sudo pkill -f cloudflared 2>/dev/null || true
  pkill -f cloudflared 2>/dev/null || true
  sleep 1

  # Create /etc/cloudflared dir and write token
  # NOTE: Use printf WITHOUT \n to avoid corrupting the base64 token
  sudo mkdir -p /etc/cloudflared
  printf '%s' "$CLOUDFLARED_TOKEN" | sudo tee /etc/cloudflared/token > /dev/null
  sudo chmod 600 /etc/cloudflared/token

  # Create systemd service
  echo "[3/3] Installing cloudflared service..."
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
  sudo systemctl start cloudflared

  echo ""
  echo "=== Cloudflared Status ==="
  sudo systemctl status cloudflared --no-pager | head -8
  echo ""
  echo "=== Tunnel Info ==="
  cloudflared tunnel list 2>/dev/null || echo "Tunnel list unavailable"
else
  if [ -z "$CLOUDFLARED_TOKEN" ]; then
    echo ""
    echo "⚠️  CLOUDFLARED_TOKEN not set in env — skipping cloudflared setup."
  else
    echo ""
    echo "⚠️  cloudflared binary not found — skipping cloudflared setup."
  fi
fi

echo ""
echo "=== DONE ==="
RUNEOF
  chmod +x /root/run.sh
  log 'run.sh created at /root/run.sh.'

  # Start with PM2
  cd /root/Codex-Router
  pm2 start ecosystem.config.cjs 2>/dev/null || pm2 restart router 2>/dev/null || true
  pm2 save 2>/dev/null || true
  log 'router PM2 started.'
fi

# ---------- Antigravity CLI (agy) ----------
if [ -f "/root/.local/bin/agy" ] || command -v agy >/dev/null 2>&1; then
  log "agy: $(agy --version 2>/dev/null | head -1 || echo 'ok')"
elif [ -f "/root/.local/bin/agy" ] && [ ! -x "/root/.local/bin/agy" ]; then
  chmod +x /root/.local/bin/agy
  log "agy: installed (chmod +x)"
else
  log 'menginstal agy (Antigravity CLI)...'
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://antigravity.google/cli/install.sh | bash 2>/dev/null || true
    # Ensure agy is executable
    [ -f /root/.local/bin/agy ] && chmod +x /root/.local/bin/agy
    # Ensure PATH includes /root/.local/bin
    if ! grep -q '/root/.local/bin' /etc/environment 2>/dev/null; then
      echo 'PATH="/root/.local/bin:$PATH"' | sudo tee /etc/environment >/dev/null 2>&1 || true
    fi
    export PATH="/root/.local/bin:$PATH"
    AGY_VER="$(/root/.local/bin/agy --version 2>/dev/null | head -1 || echo 'installed')"
    log "agy: $AGY_VER"
  else
    log 'agy: curl not found — skipping'
  fi
fi

# ---------- cloudflared (opsional) ----------
if [ -n "${CLOUDFLARED_TOKEN:-}" ]; then
  log 'menginstal cloudflared...'
  sudo mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg 2>/dev/null | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null || true
  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null || true
  sudo apt-get update -qq 2>/dev/null || true
  if ! command -v cloudflared >/dev/null 2>&1; then
    sudo apt-get install -y -qq cloudflared 2>/dev/null || true
  fi
  log 'cloudflared siap. Akan dijalankan di setup-akses.sh.'
fi

# ---------- status awal (tanpa password) ----------
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EXPIRES="$(date -u -d "+${DUR} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+"${DUR}"M +%Y-%m-%dT%H:%M:%SZ)"
update_status "$(jq -n \
  --arg host "$HOST_NAME" --arg os "$OS_NAME" --arg kernel "$KERNEL" \
  --argjson cpu "$CPU" --argjson ram "$RAM_GB" --argjson disk "$DISK_FREE_GB" \
  --arg user "$VPS_USER" --arg listen "$SSH_LISTEN" \
  --arg started "$NOW" --arg expires "$EXPIRES" --argjson dur "$DUR" \
  --arg runid "${GITHUB_RUN_ID:-}" --arg attempt "${GITHUB_RUN_ATTEMPT:-}" \
  --arg number "${GITHUB_RUN_NUMBER:-}" \
  --arg url "https://github.com/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
  '{active:true, hostname:$host, os:$os, kernel:$kernel,
    cpu_threads:$cpu, ram_gb:$ram, disk_free_gb:$disk,
    ssh_port:22, ssh_user:$user, ssh_listen:$listen,
    public_ip:"", bore_server:"", bore_port:"",
    started_at:$started, expires_at:$expires, duration_menit:$dur,
    run_id:$runid, run_attempt:$attempt, run_number:$number, run_url:$url,
    mode:"vpsfree",
    akses:{mode:"bore", bore:{status:"pending"}}}')"

{
  printf '### VpsFree\n\n'
  printf '| field | nilai |\n|---|---|\n'
  printf '| hostname | %s |\n| OS | %s |\n| kernel | %s |\n| user | %s |\n| SSH | %s:22 |\n| mulai | %s |\n| berakhir | %s |\n' \
    "$HOST_NAME" "$OS_NAME" "$KERNEL" "$VPS_USER" "$HOST_NAME" "$NOW" "$EXPIRES"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true

log "SESI DASAR SIAP — user $VPS_USER, SSH port 22. Lanjut: setup Bore tunnel."
exit 0
