#!/usr/bin/env bash
# Builds dist/Chrupio.app (release, or debug with --debug). By default it signs ad hoc (codesign --sign -) and leaves
# your keychain alone; macOS then asks for the microphone and screen-recording permissions again after each rebuild.
# CHRUPIO_DEV_IDENTITY=1 signs with a trusted identity instead, so macOS keeps those permissions across rebuilds: the
# first Apple Development or Developer ID identity, else a self-signed "Chrupio Dev" one that it creates once in your
# login keychain and trusts for code signing. IDENTITY=<name> signs with that identity and skips both.
# --no-sign leaves the bundle unsigned for scripts/release.sh, which signs it inside-out itself.
# The bundle holds whisper-cli and whisper-server in Contents/Helpers (scripts/build-whisper.sh, needs cmake) and
# Sparkle.framework in Contents/Frameworks. CHRUPIO_REPO picks the GitHub repo of the update feed.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
SIGN=1
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --no-sign) SIGN=0 ;;
    *) echo "usage: $0 [--debug] [--no-sign]" >&2; exit 2 ;;
  esac
done

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="dist/Chrupio.app"
# GitHub repo whose releases host the Sparkle appcast; scripts/release.sh reads the same variable for the DMG URL.
CHRUPIO_REPO="${CHRUPIO_REPO:-ToSn0w/chrupio}"
SPARKLE_FEED_URL="https://github.com/$CHRUPIO_REPO/releases/latest/download/appcast.xml"
# EdDSA public key of the Sparkle signing key in the release Mac's login keychain (docs/release.md).
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-1nJKjng6yoXGUr9Gk8vUgCXCGJe+H5Ha0QMUPxNS29U=}"

# Static whisper-cli and whisper-server, built once and cached in .build/whisper.cpp/.
WHISPER_BIN="$(scripts/build-whisper.sh | tail -1)"

# One build for both products; --product would build them one at a time.
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Chrupio" "$APP/Contents/MacOS/Chrupio"
# SwiftPM adds rpaths into the build tree, which would load Sparkle from there on this Mac; the app finds it through
# @executable_path/../Frameworks (Package.swift).
otool -l "$APP/Contents/MacOS/Chrupio" | awk '/LC_RPATH/ {getline; getline; print $2}' | while read -r rpath; do
  case "$rpath" in "$PWD"/*) install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/Chrupio" 2>/dev/null ;; esac
done
# ditto keeps the framework's Versions symlinks.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$WHISPER_BIN/whisper-cli" "$WHISPER_BIN/whisper-server" "$APP/Contents/Helpers/"
# Read-only MCP server for Claude Code; runs on its own, without the app.
cp "$BIN_DIR/chrupio-mcp" "$APP/Contents/MacOS/chrupio-mcp"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp -R Sources/Chrupio/Fonts "$APP/Contents/Resources/Fonts"
rsync -a --exclude tests --exclude '*.test.mjs' --exclude README.md extension/ "$APP/Contents/Resources/ChromeExtension/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.chrupio.app</string>
  <key>CFBundleName</key><string>Chrupio</string>
  <key>CFBundleDisplayName</key><string>Chrupio</string>
  <key>CFBundleExecutable</key><string>Chrupio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppSleepDisabled</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Chrupio records your voice in meetings to transcribe them on this Mac.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Chrupio records the other meeting participants to transcribe them on this Mac.</string>
  <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

if [[ $SIGN -eq 0 ]]; then
  echo "Built $APP ($CONFIG, unsigned)"
  exit 0
fi

DEV_IDENTITY="Chrupio Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# A self-signed code-signing certificate, made once. Its identity stays the same across rebuilds, so macOS
# keeps the permissions it granted. The private key is allowed for codesign only.
make_dev_identity() {
  echo "CHRUPIO_DEV_IDENTITY=1: adding a self-signed code-signing certificate \"$DEV_IDENTITY\" to your login keychain and trusting it for code signing." >&2
  echo "Creating the self-signed code-signing identity \"$DEV_IDENTITY\" in your login keychain (one time)." >&2
  echo "macOS may ask for your login password to trust it for code signing." >&2
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $DEV_IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout pass:chrupio 2>/dev/null \
    || openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout pass:chrupio
  security import "$tmp/id.p12" -k "$KEYCHAIN" -P chrupio -T /usr/bin/codesign >/dev/null
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem"
}

if [[ -n "${IDENTITY:-}" ]]; then
  :
elif [[ "${CHRUPIO_DEV_IDENTITY:-}" == 1 ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
  if [[ -z "$IDENTITY" ]]; then
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$DEV_IDENTITY\""; then
      make_dev_identity
    fi
    IDENTITY="$DEV_IDENTITY"
  fi
else
  IDENTITY="-"
fi
if [[ "$IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  echo "error: signing identity \"$IDENTITY\" not found or not valid for code signing (security find-identity -v -p codesigning)." >&2
  exit 1
fi

scripts/sign-app.sh "$APP" "$IDENTITY" >/dev/null
codesign --verify --deep --strict "$APP"
echo "Built $APP ($CONFIG, signed with: $([[ $IDENTITY == - ]] && echo "ad hoc" || echo "$IDENTITY"))"
