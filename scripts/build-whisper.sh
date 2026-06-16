#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

command -v cmake >/dev/null || brew install cmake

if [ ! -f vendor/whisper.cpp/CMakeLists.txt ]; then
    git submodule add -f https://github.com/ggml-org/whisper.cpp vendor/whisper.cpp || true
    git submodule update --init vendor/whisper.cpp
fi

cd vendor/whisper.cpp
git fetch --tags --quiet
TAG=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
git checkout --quiet "$TAG"

cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF
cmake --build build -j"$(sysctl -n hw.ncpu)"
cd ../..

mkdir -p vendor/whisper-lib Sources/CWhisper/include
find vendor/whisper.cpp/build -name '*.a' -exec cp {} vendor/whisper-lib/ \;
cp vendor/whisper.cpp/include/whisper.h Sources/CWhisper/include/
cp vendor/whisper.cpp/ggml/include/*.h Sources/CWhisper/include/
echo "=== built libs ==="
ls vendor/whisper-lib
echo "whisper $TAG built"
