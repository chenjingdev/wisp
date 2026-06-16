#!/bin/bash
# agent-bar의 build-app.sh와 동일한 방식: SwiftPM 빌드 → 수동 번들 조립 → ad-hoc 서명.
# (이 머신엔 Xcode가 없어 xcodebuild/개발자 인증서를 쓰지 않는다)
#
# 사용:
#   ./scripts/make-app.sh            # build/Wisp.app 생성
#   ./scripts/make-app.sh --install  # ~/Applications/Wisp.app 설치 (open -a Wisp / Spotlight 가능)
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_NAME="Wisp.app"
BUNDLE_PATH="build/$BUNDLE_NAME"
INSTALL_DIR="$HOME/Applications"
INSTALL_PATH="$INSTALL_DIR/$BUNDLE_NAME"
SHOULD_INSTALL=0

for arg in "$@"; do
    case "$arg" in
        --install) SHOULD_INSTALL=1 ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Usage: ./scripts/make-app.sh [--install]" >&2
            exit 1
            ;;
    esac
done

# WispTests는 @testable이라 릴리즈 불가 — 앱 프로덕트만 빌드
swift build -c release --product Wisp

rm -rf "$BUNDLE_PATH"
mkdir -p "$BUNDLE_PATH/Contents/MacOS" "$BUNDLE_PATH/Contents/Resources"

cat > "$BUNDLE_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>ko</string>
    <key>CFBundleDisplayName</key><string>Wisp</string>
    <key>CFBundleIdentifier</key><string>dev.chenjing.wisp</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Wisp</string>
    <key>CFBundleExecutable</key><string>Wisp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>음성 받아쓰기를 위해 마이크 접근이 필요합니다.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$BUNDLE_PATH/Contents/PkgInfo"
cp .build/release/Wisp "$BUNDLE_PATH/Contents/MacOS/Wisp"

# 미디어 "재생 여부" 조회 헬퍼(mr_probe). macOS 15.4+는 now-playing 읽기를 com.apple.*
# 프로세스에만 허용한다 — 우리(비특권)는 못 읽으므로, com.apple.perl5인 /usr/bin/perl이
# 로드할 작은 dylib을 빌드해 번들한다(MediaController가 perl 위임으로 호출). 컴파일 실패해도
# 앱은 동작한다 — probe가 없으면 "재개 안 함(무깨움)"으로 안전 강등된다.
if clang -dynamiclib -fobjc-arc -framework Foundation \
        -o "$BUNDLE_PATH/Contents/Resources/mr_probe.dylib" helpers/mr_probe.m 2>/dev/null; then
    cp helpers/mr_probe.pl "$BUNDLE_PATH/Contents/Resources/mr_probe.pl"
    echo "미디어 probe 헬퍼: mr_probe.dylib 빌드·번들"
else
    echo "경고: mr_probe.dylib 빌드 실패 — 미디어 자동 재개 비활성(무깨움 폴백)" >&2
fi

# Silero VAD 모델(무음 환각 방지 — whisper.cpp 내장 VAD). 없으면 VAD 미사용으로 강등된다.
VAD_MODEL="vendor/whisper-lib/ggml-silero-v6.2.0.bin"
if [[ -f "$VAD_MODEL" ]]; then
    cp "$VAD_MODEL" "$BUNDLE_PATH/Contents/Resources/"
    echo "VAD 모델: ggml-silero-v6.2.0.bin 번들 (~0.9MB)"
else
    echo "경고: VAD 모델 없음 — 무음은 에너지 게이트만으로 처리" >&2
fi

# 안정적 self-signed 인증서로 서명하면 재빌드해도 코드 서명 신원이 유지돼
# 손쉬운 사용(Accessibility) 권한이 재설치마다 무효화되지 않는다. ad-hoc(`-`)은
# 빌드마다 cdhash가 바뀌어 TCC 권한이 매번 풀린다. 인증서가 없으면 ad-hoc 폴백.
SIGN_IDENTITY="${WISP_SIGN_IDENTITY:-Screen Translate Local Code Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    SIGN_ARG="$SIGN_IDENTITY"; SIGN_DESC="$SIGN_IDENTITY (안정 신원 — 권한 유지)"
else
    SIGN_ARG="-"; SIGN_DESC="ad-hoc (재빌드 시 손쉬운 사용 권한 재설정 필요)"
fi
# 중첩 dylib(mr_probe)을 번들 봉인 전에 먼저 서명한다 — /usr/bin/perl(하드닝된 플랫폼
# 바이너리)이 dlopen할 때 라이브러리 검증에 걸리지 않도록.
if [[ -f "$BUNDLE_PATH/Contents/Resources/mr_probe.dylib" ]]; then
    codesign --force --sign "$SIGN_ARG" "$BUNDLE_PATH/Contents/Resources/mr_probe.dylib" >/dev/null
fi
codesign --force --sign "$SIGN_ARG" "$BUNDLE_PATH" >/dev/null
echo "서명: $SIGN_DESC"

if [[ "$SHOULD_INSTALL" -eq 1 ]]; then
    # 실행 중인 인스턴스만 정확히 종료 (이름 유사 프로세스 오살 방지)
    pkill -f "$BUNDLE_NAME/Contents/MacOS/Wisp" 2>/dev/null || true
    # 종료 완료까지 대기 — 종료 중에 번들을 교체/실행하면 LaunchServices가
    # -600(procNotFound)으로 open을 거부할 수 있다
    for _ in $(seq 1 50); do
        pgrep -f "$BUNDLE_NAME/Contents/MacOS/Wisp" >/dev/null 2>&1 || break
        sleep 0.1
    done
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_PATH"
    cp -R "$BUNDLE_PATH" "$INSTALL_PATH"
    # LaunchServices 등록 — 직후부터 `open -a Wisp` / Spotlight 검색 가능
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_PATH"
    echo "Installed: $INSTALL_PATH"
    echo "실행: open -a Wisp"
else
    echo "OK: $BUNDLE_PATH"
fi
