#!/bin/bash
# 테스트 실행: ./scripts/test.sh [이름 필터]
# CLT 환경엔 XCTest가 없어 swift test 대신 자체 러너(WispTests)를 사용한다.
# -enable-testing으로 빌드해 @testable import WispCore가 동작한다.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift run -Xswiftc -enable-testing WispTests "$@"
