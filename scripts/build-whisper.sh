#!/usr/bin/env bash
# Builds whisper-cli and whisper-server from a pinned whisper.cpp release: static (no libwhisper or ggml dylibs),
# Metal with the shader library embedded (no default.metallib next to the binary), Apple Silicon only, macOS 15+.
# The result is cached in .build/whisper.cpp/; scripts/build-app.sh copies it into Chrupio.app/Contents/Helpers.
# Prints the directory holding both binaries on the last line of stdout. Needs git and cmake (brew install cmake).
set -euo pipefail
cd "$(dirname "$0")/.."

# Matches Homebrew's whisper.cpp 1.9.5. Bump both together, then check the commit with: git ls-remote --tags
# https://github.com/ggml-org/whisper.cpp.git 'v<tag>^{}'.
TAG="v1.9.5"
COMMIT="d1be6fde11ac6e0407606b4e42fe72d34add8037"
REPO="https://github.com/ggml-org/whisper.cpp.git"
# The oldest Apple Silicon CPU. ggml would otherwise tune for the build Mac (-mcpu=native) and could use
# instructions an M1 doesn't have.
CPU="apple-m1"
DEPLOYMENT_TARGET="15.0"

ROOT=".build/whisper.cpp"
SRC="$ROOT/src-$TAG"
BUILD="$ROOT/build-$TAG-arm64"
OUT="$ROOT/bin-$TAG-arm64"

log() { echo "$*" >&2; }

if [[ -x "$OUT/whisper-cli" && -x "$OUT/whisper-server" && "$(cat "$OUT/.commit" 2>/dev/null)" == "$COMMIT" ]]; then
  log "whisper.cpp $TAG already built ($OUT)"
  echo "$OUT"
  exit 0
fi

command -v cmake >/dev/null || { log "error: cmake not found; install it with: brew install cmake"; exit 1; }

if [[ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$COMMIT" ]]; then
  log "Fetching whisper.cpp $TAG"
  rm -rf "$SRC"
  mkdir -p "$ROOT"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" "$REPO" "$SRC" >&2
  actual="$(git -C "$SRC" rev-parse HEAD)"
  [[ "$actual" == "$COMMIT" ]] || { log "error: whisper.cpp $TAG is commit $actual, expected $COMMIT"; rm -rf "$SRC"; exit 1; }
fi

log "Building whisper.cpp $TAG (static, Metal embedded, arm64, macOS $DEPLOYMENT_TARGET+)"
rm -rf "$BUILD"
# OpenMP off: Apple clang has none, and CMake would otherwise pick up Homebrew's libomp.dylib.
cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_C_FLAGS="-mcpu=$CPU" -DCMAKE_CXX_FLAGS="-mcpu=$CPU" \
  -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_OPENMP=OFF -DGGML_BLAS=ON -DGGML_CCACHE=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=ON \
  -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF -DWHISPER_COREML=OFF >&2
cmake --build "$BUILD" --config Release -j "$(sysctl -n hw.ncpu)" --target whisper-cli whisper-server >&2

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$BUILD/bin/whisper-cli" "$BUILD/bin/whisper-server" "$OUT/"
strip -x "$OUT/whisper-cli" "$OUT/whisper-server"

# Only system libraries and frameworks: anything from Homebrew or the build tree would break on other Macs.
for binary in "$OUT/whisper-cli" "$OUT/whisper-server"; do
  bad="$(otool -L "$binary" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' || true)"
  [[ -z "$bad" ]] || { log "error: $binary links non-system libraries:"; log "$bad"; rm -rf "$OUT"; exit 1; }
done
echo "$COMMIT" > "$OUT/.commit"
log "Built whisper-cli and whisper-server in $OUT"
echo "$OUT"
