#!/usr/bin/env bash
# ============================================================================
#  finalize-vps.sh — tutup akses sesi ini tanpa menyentuh state tersimpan.
#   * hentikan tunnel Bore (sesi ini)
#   * TIDAK menghapus data /home atau Release state.
#  Status 'inactive' ditulis oleh step publish-status --active false.
# ============================================================================
set -uo pipefail
export XY_TAG='VpsFree:finalize'
. "$(dirname "$0")/lib-common.sh"

sudo pkill -f "bore local" 2>/dev/null || true
if command -v cloudflared >/dev/null 2>&1; then
  sudo cloudflared service uninstall >/dev/null 2>&1 || true
  sudo pkill -f "cloudflared" 2>/dev/null || true
  log 'cloudflared tunnel dihentikan.'
fi
log 'Sesi VPS dihentikan. State tersimpan tetap ada dan akan dipulihkan pada sesi berikutnya.'
exit 0
