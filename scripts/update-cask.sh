#!/bin/sh
# Fill the Homebrew cask with the version and sha256 of a published release,
# then push it to the ToSn0w/homebrew-chrupio tap.
# Usage: scripts/update-cask.sh 1.0.0
#        scripts/update-cask.sh --local <Chrupio-X.Y.Z.dmg> <cask copy.rb> 1.0.0
#   --local  test mode: hashes a local DMG and writes a copy of the cask to <cask copy.rb>.
#            No gh, no download, no tap clone, no push; the cask in the repo is left alone.
set -eu
src="$(dirname "$0")/../packaging/homebrew/Casks/chrupio.rb"
if [ "${1:-}" = "--local" ]; then
  [ $# -eq 4 ] || { echo "usage: $0 --local <dmg> <cask copy.rb> <version>" >&2; exit 2; }
  dmg="$2"; out="$3"; v="$4"
  sum="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
  sed -e "s/^  version \".*\"/  version \"$v\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sum\"/" "$src" > "$out"
  echo "Cask copy written to $out ($v, $sum); nothing published"
  exit 0
fi
v="$1"; cask="$src"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
gh release download "v$v" -R ToSn0w/chrupio -p "Chrupio-$v.dmg" -D "$tmp"
sum="$(shasum -a 256 "$tmp/Chrupio-$v.dmg" | cut -d' ' -f1)"
sed -i '' -e "s/^  version \".*\"/  version \"$v\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sum\"/" "$cask"
gh repo view ToSn0w/homebrew-chrupio >/dev/null 2>&1 || gh repo create ToSn0w/homebrew-chrupio --public -d "Homebrew tap for Chrupio"
git clone -q "https://github.com/ToSn0w/homebrew-chrupio.git" "$tmp/tap"
mkdir -p "$tmp/tap/Casks"; cp "$cask" "$tmp/tap/Casks/chrupio.rb"
git -C "$tmp/tap" add Casks/chrupio.rb
git -C "$tmp/tap" commit -qm "Chrupio $v" && git -C "$tmp/tap" push -q origin HEAD
echo "Cask updated to $v ($sum)"
