#!/usr/bin/env bash
# Signs Chrupio.app inside-out with the hardened runtime. Used by scripts/build-app.sh and scripts/release.sh.
#
# Usage: scripts/sign-app.sh <Chrupio.app> <identity> [extra codesign options, e.g. --timestamp]
#   <identity>  a codesigning identity name, or "-" for ad hoc.
#
# Order, deepest first:
#   1. Sparkle.framework, exactly as Sparkle's docs say (sparkle-project.org/documentation/sandboxing): Installer.xpc,
#      Downloader.xpc (keeping its own entitlements), Autoupdate, Updater.app, then the framework. No --deep, and
#      never the app's entitlements.
#   2. Everything else nested: helper binaries (chrupio-mcp, whisper-cli, whisper-server), dylibs, other bundles.
#      They need no entitlements: Metal compiles whisper's shaders in Apple's compiler service, not in-process JIT.
#   3. The app, with scripts/Chrupio.entitlements.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# -ge 2 ]] || { echo "usage: $0 <Chrupio.app> <identity> [codesign options]" >&2; exit 2; }
APP="${1%/}"; IDENTITY="$2"; shift 2
OPTS=(--force --options runtime --sign "$IDENTITY" "$@")

sign() {
  local target="$1"; shift
  echo "  signing ${target#"$APP"/}"
  codesign "${OPTS[@]}" "$@" "$target"
}

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  V="$SPARKLE/Versions/$(readlink "$SPARKLE/Versions/Current")"
  [[ -e "$V/XPCServices/Installer.xpc" ]] && sign "$V/XPCServices/Installer.xpc"
  [[ -e "$V/XPCServices/Downloader.xpc" ]] && sign "$V/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
  sign "$V/Autoupdate"
  sign "$V/Updater.app"
  sign "$SPARKLE"
fi

MAIN_EXE="$APP/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")"
targets=()
while IFS= read -r -d '' f; do
  [[ "$f" == "$MAIN_EXE" ]] && continue
  file -b "$f" | grep -q 'Mach-O' && targets+=("$f")
done < <(find "$APP/Contents" -path "$SPARKLE" -prune -o -type f -print0)
while IFS= read -r -d '' d; do
  targets+=("$d")
done < <(find "$APP/Contents" -path "$SPARKLE" -prune -o -type d \( -name '*.framework' -o -name '*.bundle' \
  -o -name '*.app' -o -name '*.xpc' -o -name '*.appex' -o -name '*.plugin' \) -print0)
if [[ ${#targets[@]} -gt 0 ]]; then
  while IFS= read -r t; do
    sign "$t"
  done < <(for t in "${targets[@]}"; do printf '%d\t%s\n' "$(tr -cd / <<<"$t" | wc -c)" "$t"; done | sort -rn | cut -f2-)
fi

ENTITLEMENTS="scripts/Chrupio.entitlements"
case "$IDENTITY" in
  "Developer ID Application:"*|"Apple Development:"*|"Apple Distribution:"*) ;;
  *)
    # Ad hoc and self-signed ("Chrupio Dev") signatures have no Team ID, so the hardened runtime's library validation
    # refuses to load Sparkle.framework into the app. Local builds only; a Developer ID release never gets this.
    tmp_entitlements="$(mktemp -t chrupio-entitlements)"
    trap 'rm -f "$tmp_entitlements"' EXIT
    cp "$ENTITLEMENTS" "$tmp_entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$tmp_entitlements" >/dev/null
    ENTITLEMENTS="$tmp_entitlements"
    echo "  note: \"$IDENTITY\" has no Team ID, so library validation is off for this local build"
    ;;
esac
echo "  signing $(basename "$APP") (with scripts/Chrupio.entitlements)"
codesign "${OPTS[@]}" --entitlements "$ENTITLEMENTS" "$APP"
