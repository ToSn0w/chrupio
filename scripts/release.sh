#!/usr/bin/env bash
# Builds a release of Chrupio: a Developer ID signed, notarized and stapled Chrupio-<version>.dmg, the Chrome
# extension as Chrupio-Extension-<version>.zip, the Sparkle appcast.xml and SHA256SUMS, all in dist/release/<version>/.
#
# Usage: scripts/release.sh [--dry-run] [<version>]
#   <version>   X.Y.Z. Without it, the default VERSION in scripts/build-app.sh is used.
#   --dry-run   No certificate needed: the app is ad-hoc signed, the DMG is unsigned and not notarized, the appcast
#               has a placeholder signature, and the output goes to dist/release/<version>-dry-run/. For testing
#               only; never publish it.
#
# Environment (real release):
#   SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)", installed in the keychain.
#   NOTARY_PROFILE  a keychain profile made with `xcrun notarytool store-credentials` (preferred), or
#   APPLE_ID + TEAM_ID + APP_PASSWORD   an Apple ID with an app-specific password.
#   The Sparkle EdDSA private key in the login keychain (made with generate_keys; see docs/release.md).
#   CHRUPIO_REPO    owner/name of the GitHub repo hosting releases (default ToSn0w/chrupio, as in build-app.sh).
# See docs/release.md.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
warn_unsigned() {
  cat >&2 <<'BANNER'

  ###########################################################################
  ##  DRY RUN: UNSIGNED, NOT NOTARIZED. DO NOT PUBLISH THESE FILES.        ##
  ##  Gatekeeper blocks this DMG on any other Mac.                         ##
  ###########################################################################

BANNER
}

DRY_RUN=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $arg (usage: scripts/release.sh [--dry-run] [<version>])" ;;
    *) [[ -z "$VERSION" ]] || die "more than one version given"; VERSION="$arg" ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  VERSION="$(sed -n 's/^VERSION="\${VERSION:-\([^}]*\)}"$/\1/p' scripts/build-app.sh | head -1)"
  [[ -n "$VERSION" ]] || die "no version given and none found in scripts/build-app.sh; pass one, e.g. scripts/release.sh 1.0.0"
  echo "Version from scripts/build-app.sh: $VERSION"
fi
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || die "version '$VERSION' is not X.Y.Z (digits only, e.g. 1.0.0); macOS reads CFBundleShortVersionString that way"

# Only Xcode command-line tools and what ships with macOS.
for tool in swift codesign hdiutil ditto shasum plutil spctl rsync file xmllint; do
  command -v "$tool" >/dev/null || die "$tool not found; install the Xcode command-line tools (xcode-select --install)"
done

if [[ $DRY_RUN -eq 1 ]]; then
  OUT="dist/release/$VERSION-dry-run"
  IDENTITY="-"
  warn_unsigned
else
  OUT="dist/release/$VERSION"
  [[ -n "${SIGN_IDENTITY:-}" ]] || die "SIGN_IDENTITY is not set. Set it to your \"Developer ID Application: Name (TEAMID)\" identity, or pass --dry-run for an unsigned test build."
  [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]] \
    || die "SIGN_IDENTITY must be a \"Developer ID Application: ...\" identity; other certificates cannot be notarized for distribution"
  security find-identity -v -p codesigning | grep -qF "\"$SIGN_IDENTITY\"" \
    || die "SIGN_IDENTITY \"$SIGN_IDENTITY\" is not a valid code-signing identity in your keychain (check: security find-identity -v -p codesigning)"
  IDENTITY="$SIGN_IDENTITY"

  xcrun --find notarytool >/dev/null 2>&1 || die "xcrun notarytool not found; install Xcode 13 or later command-line tools"
  xcrun --find stapler >/dev/null 2>&1 || die "xcrun stapler not found; install the Xcode command-line tools"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    NOTARY_DESC="keychain profile \"$NOTARY_PROFILE\""
  elif [[ -n "${APPLE_ID:-}" || -n "${TEAM_ID:-}" || -n "${APP_PASSWORD:-}" ]]; then
    missing=()
    [[ -n "${APPLE_ID:-}" ]] || missing+=(APPLE_ID)
    [[ -n "${TEAM_ID:-}" ]] || missing+=(TEAM_ID)
    [[ -n "${APP_PASSWORD:-}" ]] || missing+=(APP_PASSWORD)
    [[ ${#missing[@]} -eq 0 ]] || die "notarization needs APPLE_ID, TEAM_ID and APP_PASSWORD together; missing: ${missing[*]}"
    NOTARY_AUTH=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
    NOTARY_DESC="Apple ID $APPLE_ID, team $TEAM_ID (password hidden)"
    team_in_identity="$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$SIGN_IDENTITY")"
    [[ -z "$team_in_identity" || "$team_in_identity" == "$TEAM_ID" ]] \
      || die "TEAM_ID $TEAM_ID does not match the team in SIGN_IDENTITY ($team_in_identity)"
  else
    die "no notarization credentials. Set NOTARY_PROFILE (made with: xcrun notarytool store-credentials), or APPLE_ID, TEAM_ID and APP_PASSWORD."
  fi

  if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    echo "warning: tracked files have uncommitted changes; this release will not match a commit." >&2
  fi
fi

# Where the release lives; the appcast points at its DMG. build-app.sh puts the feed URL for the same repo in Info.plist.
CHRUPIO_REPO="${CHRUPIO_REPO:-ToSn0w/chrupio}"
export CHRUPIO_REPO
APP="dist/Chrupio.app"
DMG="$OUT/Chrupio-$VERSION.dmg"
APPCAST="$OUT/appcast.xml"
ZIP="$OUT/Chrupio-Extension-$VERSION.zip"
WORK="$(mktemp -d)"
trap 'hdiutil detach -quiet "$WORK/mnt" 2>/dev/null || true; rm -rf "$WORK"' EXIT

rm -rf "$OUT"
mkdir -p "$OUT"

step "Building Chrupio $VERSION (release)"
VERSION="$VERSION" scripts/build-app.sh --no-sign

step "Signing inside-out (hardened runtime) with: $([[ $DRY_RUN -eq 1 ]] && echo 'ad-hoc identity (dry run)' || echo "$IDENTITY")"
SIGN_EXTRA=()
[[ $DRY_RUN -eq 1 ]] || SIGN_EXTRA+=(--timestamp)

# Sparkle's command-line tools come with the Swift package (swift build above fetched them).
SPARKLE_BIN="$(dirname "$(find .build/artifacts -path '*/Sparkle/bin/sign_update' -type f 2>/dev/null | head -1)")"
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "Sparkle's sign_update not found under .build/artifacts; run swift package resolve"
plist_key="$(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist")"
if [[ $DRY_RUN -eq 0 ]]; then
  # Updates signed with any other key are refused by every installed copy, so check before notarizing.
  keychain_key="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" \
    || die "no Sparkle signing key in the login keychain; restore it with generate_keys -f (docs/release.md)"
  [[ "$keychain_key" == "$plist_key" ]] \
    || die "SUPublicEDKey in Info.plist ($plist_key) is not the keychain's Sparkle key ($keychain_key)"
fi

# Sparkle's parts, helper binaries (chrupio-mcp, whisper-cli, whisper-server), then the app; see scripts/sign-app.sh.
scripts/sign-app.sh "$APP" "$IDENTITY" ${SIGN_EXTRA[@]+"${SIGN_EXTRA[@]}"}

step "Verifying the app signature"
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "  spctl skipped: an ad-hoc signed app is always rejected by Gatekeeper."
else
  codesign -d --verbose=2 "$APP" 2>&1 | grep -E '^(Authority|TeamIdentifier|Timestamp|Runtime)' | sed 's/^/  /' || true
  # Only local builds turn library validation off (scripts/sign-app.sh); a release must keep it.
  ! codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q disable-library-validation \
    || die "the app is signed with disable-library-validation; a release must not be"
  # Before notarization Gatekeeper says "Unnotarized Developer ID"; the binding check runs on the DMG below.
  spctl -a -vv -t exec "$APP" 2>&1 | sed 's/^/  /' || echo "  (expected before notarization; checked again after stapling)"
fi

step "Building $DMG"
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Chrupio.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -quiet -volname "Chrupio $VERSION" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO -ov "$DMG"

if [[ $DRY_RUN -eq 0 ]]; then
  step "Signing the DMG"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  codesign --verify --strict --verbose=2 "$DMG"

  step "Notarizing (${NOTARY_DESC}); this usually takes a few minutes"
  # JSON output so the submission id and status can be read without echoing credentials.
  if ! xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait --output-format json > "$WORK/notary.json"; then
    cat "$WORK/notary.json" >&2 || true
    die "notarytool submit failed"
  fi
  sub_id="$(plutil -extract id raw "$WORK/notary.json" 2>/dev/null || true)"
  status="$(plutil -extract status raw "$WORK/notary.json" 2>/dev/null || true)"
  echo "  submission $sub_id: $status"
  if [[ "$status" != "Accepted" ]]; then
    [[ -n "$sub_id" ]] && xcrun notarytool log "$sub_id" "${NOTARY_AUTH[@]}" >&2 || true
    die "notarization was not accepted (status: ${status:-unknown}); the log is above"
  fi
  xcrun notarytool log "$sub_id" "${NOTARY_AUTH[@]}" "$OUT/notarization-log.json" >/dev/null 2>&1 || true

  step "Stapling and validating"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -vv -t open --context context:primary-signature "$DMG"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$WORK/mnt" "$DMG"
  spctl -a -vv -t exec "$WORK/mnt/Chrupio.app"
  hdiutil detach -quiet "$WORK/mnt"
fi

step "Zipping the Chrome extension"
# The same files build-app.sh bundles into the app (no tests, no README), in one top-level folder.
EXT_DIR="$WORK/ext/Chrupio-Extension-$VERSION"
mkdir -p "$EXT_DIR"
rsync -a --exclude .DS_Store "$APP/Contents/Resources/ChromeExtension/" "$EXT_DIR/"
[[ -f "$EXT_DIR/manifest.json" ]] || die "extension manifest.json missing from the app bundle"
ditto -c -k --norsrc --noextattr --keepParent "$EXT_DIR" "$ZIP"
ext_version="$(plutil -extract version raw extension/manifest.json 2>/dev/null || echo '?')"
echo "  $ZIP (manifest version $ext_version)"

step "Writing the Sparkle appcast"
# One item: the stapled DMG of this release. Installed copies read it from releases/latest/download/appcast.xml.
DMG_URL="https://github.com/$CHRUPIO_REPO/releases/download/v$VERSION/Chrupio-$VERSION.dmg"
if [[ $DRY_RUN -eq 1 ]]; then
  ed_attributes="sparkle:edSignature=\"DRY-RUN-NOT-SIGNED\" length=\"$(stat -f %z "$DMG")\""
  echo "  dry run: placeholder signature, not signed with the Sparkle key"
else
  # sign_update reads the private key from the login keychain and prints: sparkle:edSignature="..." length="..."
  ed_attributes="$("$SPARKLE_BIN/sign_update" "$DMG")" || die "sign_update failed"
  [[ "$ed_attributes" == *'sparkle:edSignature="'* && "$ed_attributes" == *'length="'* ]] \
    || die "unexpected sign_update output: $ed_attributes"
fi
build_number="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
min_system="$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Chrupio</title>
    <link>https://github.com/$CHRUPIO_REPO</link>
    <item>
      <title>Chrupio $VERSION</title>
      <link>https://github.com/$CHRUPIO_REPO/releases/tag/v$VERSION</link>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min_system</sparkle:minimumSystemVersion>
      <enclosure url="$DMG_URL" type="application/octet-stream" $ed_attributes />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$APPCAST" || die "appcast.xml is not well-formed"
echo "  $APPCAST (build $build_number, $DMG_URL)"

step "Writing SHA256SUMS"
(cd "$OUT" && shasum -a 256 "Chrupio-$VERSION.dmg" "Chrupio-Extension-$VERSION.zip" appcast.xml > SHA256SUMS && cat SHA256SUMS)

step "Done"
for f in "$DMG" "$ZIP" "$APPCAST" "$OUT/SHA256SUMS"; do
  printf '  %-60s %s\n' "$f" "$(du -h "$f" | cut -f1 | tr -d ' ')"
done
if [[ $DRY_RUN -eq 1 ]]; then
  warn_unsigned
else
  echo "Next: create the GitHub release v$VERSION with these files (appcast.xml must be on the latest release, so"
  echo "installed copies see the update), then run scripts/update-cask.sh $VERSION:"
  echo
  printf '  gh release create v%s -R %s --title "Chrupio %s" --notes "" \\\n    %q %q %q %q\n' \
    "$VERSION" "$CHRUPIO_REPO" "$VERSION" "$DMG" "$ZIP" "$APPCAST" "$OUT/SHA256SUMS"
fi
