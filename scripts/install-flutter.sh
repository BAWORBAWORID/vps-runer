#!/usr/bin/env bash
# ============================================================================
#  install-flutter.sh — VpsFree: pasang Flutter SDK + Android SDK + Web/Desktop
#  tools di dalam runner VPS (GitHub Actions, Ubuntu 22.04/24.04).
#
#  Diadaptasi dari install.sh (root-only) agar aman dijalankan user `runner`
#  via sudo, dan TIDAK mengulang bagian yang sudah ada (Chrome dsb).
#
#  Pemakaian:  bash scripts/install-flutter.sh
#  Durasi    : ~8–15 menit (download ~2 GB, butuh ±8 GB disk bebas)
#  Hasil     : flutter & dart di /opt/flutter, Android SDK di /opt/android-sdk
#              helper: fl-info / fl-clean-all / fl-update
# ============================================================================
set -uo pipefail
. "$(dirname "$0")/lib-common.sh"

SUDO="sudo"
[ "$(id -u)" -eq 0 ] && SUDO=""

log 'INFO: install-flutter dimulai...'

# ---------- 0. cek disk bebas (butuh >= 8 GB) ----------
FREE_GB=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
log "INFO: disk bebas: ${FREE_GB}GB"
if [ "${FREE_GB:-0}" -lt 8 ]; then
  log "ERROR: disk bebas < 8GB (${FREE_GB}GB). Instalasi Flutter+Android butuh ~8GB. Batalkan."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ---------- 1. dependensi sistem ----------
log 'INFO: [1/6] install dependensi build (java17, gtk, clang, cmake)...'
$SUDO apt-get update -y
$SUDO apt-get install -y --no-install-recommends \
  curl wget git unzip zip xz-utils \
  openjdk-17-jdk-headless \
  libglu1-mesa libgtk-3-dev \
  clang cmake ninja-build \
  pkg-config build-essential \
  lib32z1 libbz2-1.0 lib32stdc++6 \
  ca-certificates gnupg || log 'WARN: sebagian paket gagal, lanjut'

# ---------- 2. Chrome/Chromium (untuk flutter web; biasanya sudah ada) ----------
log 'INFO: [2/6] cek browser untuk flutter web...'
CHROME_BIN=""
for c in google-chrome-stable google-chrome chromium chromium-browser /snap/bin/chromium; do
  if command -v "$c" >/dev/null 2>&1; then CHROME_BIN="$(command -v "$c")"; break; fi
done
if [ -z "$CHROME_BIN" ]; then
  log 'INFO: chrome tidak ada, install google-chrome-stable...'
  wget -q -O /tmp/gc.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb || true
  [ -f /tmp/gc.deb ] && $SUDO apt-get install -y /tmp/gc.deb && rm -f /tmp/gc.deb
  command -v google-chrome-stable >/dev/null 2>&1 && CHROME_BIN="$(command -v google-chrome-stable)"
fi
[ -n "$CHROME_BIN" ] && $SUDO ln -sf "$CHROME_BIN" /usr/local/bin/chromium && \
  log "INFO: chrome di $CHROME_BIN" || log 'WARN: chrome tidak terdeteksi (flutter web perlu)'

# ---------- 3. Flutter SDK ----------
log 'INFO: [3/6] flutter SDK...'
if [ -d /opt/flutter/.git ]; then
  $SUDO git -C /opt/flutter pull || true
else
  $SUDO rm -rf /opt/flutter
  $SUDO git clone https://github.com/flutter/flutter.git -b stable --depth 1 /opt/flutter
fi
$SUDO git config --global --add safe.directory /opt/flutter || true
$SUDO ln -sf /opt/flutter/bin/flutter /usr/local/bin/flutter
$SUDO ln -sf /opt/flutter/bin/dart /usr/local/bin/dart
/opt/flutter/bin/flutter config --no-analytics
/opt/flutter/bin/flutter precache

# ---------- 4. Android SDK ----------
log 'INFO: [4/6] android cmdline-tools...'
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=/opt/android-sdk
$SUDO mkdir -p "$ANDROID_HOME/cmdline-tools"
if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  CDL_URL="https://dl.google.com/android/repository/commandlinetools-linux-14742923_latest.zip"
  wget -q "$CDL_URL" -O /tmp/at.zip || { log 'ERROR: download cmdline-tools gagal'; exit 1; }
  rm -rf /tmp/ct; unzip -q /tmp/at.zip -d /tmp/ct
  $SUDO mkdir -p "$ANDROID_HOME/cmdline-tools/latest"
  $SUDO cp -r /tmp/ct/* "$ANDROID_HOME/cmdline-tools/latest/"
  rm -rf /tmp/ct /tmp/at.zip
fi

# ---------- 5. env global ----------
log 'INFO: [5/6] environment variables...'
JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
[ -d "$JAVA_HOME" ] || JAVA_HOME="$(ls -d /usr/lib/jvm/java-17-* 2>/dev/null | head -1 || true)"
$SUDO tee /etc/profile.d/flutter.sh > /dev/null <<EOF
export JAVA_HOME=${JAVA_HOME}
export FLUTTER_HOME=/opt/flutter
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=/opt/android-sdk
export CHROME_EXECUTABLE="${CHROME_BIN}"
export PATH=\$FLUTTER_HOME/bin:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/build-tools:\$PATH
EOF
$SUDO chmod +x /etc/profile.d/flutter.sh

# gradle memory (agar build tak OOM di runner kecil)
$SUDO mkdir -p /root/.gradle
$SUDO tee /root/.gradle/gradle.properties > /dev/null <<'EOF'
org.gradle.daemon=true
org.gradle.parallel=true
org.gradle.jvmargs=-Xmx2048m -XX:MaxMetaspaceSize=512m
org.gradle.caching=true
EOF

# ---------- 6. komponen android + lisensi ----------
log 'INFO: [6/6] android platform & build-tools (download besar, mohon tunggu)...'
SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
yes | $SUDO "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
$SUDO "$SDKMANAGER" \
  "platform-tools" \
  "cmdline-tools;latest" \
  "platforms;android-34" \
  "platforms;android-35" \
  "build-tools;34.0.0" \
  "build-tools;35.0.0" || log 'WARN: sebagian android platform gagal'
$SUDO "$SDKMANAGER" "platforms;android-36" "build-tools;36.0.0" >/dev/null 2>&1 || true

/opt/flutter/bin/flutter config --android-sdk "$ANDROID_HOME"
yes | /opt/flutter/bin/flutter doctor --android-licenses >/dev/null 2>&1 || true
/opt/flutter/bin/flutter config --enable-web
/opt/flutter/bin/flutter config --enable-linux-desktop

# helper CLI
$SUDO tee /usr/local/bin/fl-info > /dev/null <<'EOF'
#!/usr/bin/env bash
source /etc/profile.d/flutter.sh 2>/dev/null || true
echo "Flutter: $(flutter --version 2>/dev/null | head -n1)"
echo "Java:    $JAVA_HOME"
echo "Android: $ANDROID_HOME"
echo "Chrome:  ${CHROME_EXECUTABLE:-not detected}"
EOF
$SUDO chmod +x /usr/local/bin/fl-info

log 'SUCCESS: install-flutter selesai. flutter doctor:'
/opt/flutter/bin/flutter doctor 2>&1 | head -20 || true
