#!/bin/zsh
# Tuno.app paketini oluşturur: ./scripts/build-app.sh [debug|release]
#
# Ortam değişkenleri (yayın betiği bunları ayarlar; günlük geliştirmede gerekmez):
#   TUNO_SIGN_IDENTITY  İmza kimliği (varsayılan: Keychain'deki "Apple Development")
#   TUNO_HARDENED=1     Güçlendirilmiş çalışma ortamı + zaman damgası (notarizasyon için)
#   TUNO_VERSION        Sürüm (CFBundleShortVersionString), ör. 1.0.0
#   TUNO_BUILD          Derleme numarası (CFBundleVersion), sürekli artmalı
#   TUNO_FEED_URL       Sparkle güncelleme listesi adresi (appcast.xml)
#   TUNO_PUBLIC_KEY     Sparkle güncelleme imzası açık anahtarı
set -euo pipefail

CONFIG="${1:-release}"
ROOT="${0:A:h:h}"
BUILD="$ROOT/build"
APP="$BUILD/Tuno.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Tuno" "$APP/Contents/MacOS/Tuno"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

if [[ ! -f "$BUILD/AppIcon.icns" ]]; then
  swift "$ROOT/scripts/make-icon.swift" "$BUILD"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Yayın bilgilerini paketin Info.plist'ine yaz.
PLIST="$APP/Contents/Info.plist"
plist_set() { /usr/libexec/PlistBuddy -c "Delete :$1" "$PLIST" 2>/dev/null || true
              /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST"; }
[[ -n "${TUNO_VERSION:-}" ]] && plist_set CFBundleShortVersionString string "$TUNO_VERSION"
[[ -n "${TUNO_BUILD:-}" ]] && plist_set CFBundleVersion string "$TUNO_BUILD"
if [[ -n "${TUNO_FEED_URL:-}" && -n "${TUNO_PUBLIC_KEY:-}" ]]; then
  plist_set SUFeedURL string "$TUNO_FEED_URL"
  plist_set SUPublicEDKey string "$TUNO_PUBLIC_KEY"
  plist_set SUEnableAutomaticChecks bool true
  # Güncellemenin EdDSA imzası açmadan önce doğrulanır (Sparkle 2.10+; tüm sürümler ve farklar imzalı).
  plist_set SUVerifyUpdateBeforeExtraction bool true
fi

# İmza. Kalıcı bir kimlik, macOS izinlerinin her derlemede sıfırlanmasını önler.
IDENTITY="${TUNO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
if [[ "${TUNO_HARDENED:-0}" == 1 ]]; then
  SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
else
  SIGN=(codesign --force --sign "$IDENTITY" --timestamp=none)
fi

# İçeriden dışarıya: önce Sparkle'ın parçaları, sonra çerçeve, en son uygulama.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" --entitlements "$ROOT/Resources/Tuno.entitlements" "$APP"

echo "İmza: $IDENTITY"
echo "✓ $APP"
