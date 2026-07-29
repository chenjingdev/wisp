#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v cmake >/dev/null || brew install cmake

if [ ! -f vendor/whisper.cpp/CMakeLists.txt ]; then
    git submodule update --init vendor/whisper.cpp
fi

WHISPER_COMMIT="$(git ls-files -s -- vendor/whisper.cpp | awk '$1 == "160000" { print $2 }')"
if [ -z "$WHISPER_COMMIT" ]; then
    echo "vendor/whisper.cpp gitlink를 찾지 못했습니다" >&2
    exit 1
fi
if ! git -C vendor/whisper.cpp cat-file -e "${WHISPER_COMMIT}^{commit}" 2>/dev/null; then
    git submodule update --init vendor/whisper.cpp
fi
WHISPER_GIT_DIR="$(git -C vendor/whisper.cpp rev-parse --absolute-git-dir)"

BUILD_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/wisp-whisper.XXXXXX")"
trap 'rm -rf "$BUILD_SOURCE"' EXIT

# 패치를 submodule 자체에 적용하면 부모 저장소가 재현 불가능한 dirty submodule을
# 가리키게 된다. 추적 중인 고정 commit을 임시 소스 트리로 복사한 뒤 Wisp 전용
# residency API 패치를 적용해 정적 라이브러리만 산출한다.
git -C vendor/whisper.cpp archive "$WHISPER_COMMIT" | tar -x -C "$BUILD_SOURCE"
git -C "$BUILD_SOURCE" apply "$ROOT/patches/whisper-event-residency.patch"

GIT_DIR="$WHISPER_GIT_DIR" GIT_WORK_TREE="$BUILD_SOURCE" \
cmake -S "$BUILD_SOURCE" -B "$BUILD_SOURCE/build" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF
cmake --build "$BUILD_SOURCE/build" -j"$(sysctl -n hw.ncpu)"

mkdir -p vendor/whisper-lib Sources/CWhisper/include
find "$BUILD_SOURCE/build" -name '*.a' -exec cp {} vendor/whisper-lib/ \;
cp "$BUILD_SOURCE/include/whisper.h" Sources/CWhisper/include/
cp "$BUILD_SOURCE/ggml/include/"*.h Sources/CWhisper/include/
echo "=== built libs ==="
ls vendor/whisper-lib
echo "whisper $(git -C vendor/whisper.cpp describe --always --tags "$WHISPER_COMMIT") + Wisp residency patch built"
