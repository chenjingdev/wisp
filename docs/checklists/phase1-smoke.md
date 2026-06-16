# Phase 1 수동 스모크 체크리스트

빌드·실행: `./scripts/make-app.sh && open build/Wisp.app`

- [ ] 첫 실행: 마이크 권한 프롬프트 표시 → 허용
- [ ] 첫 실행: 손쉬운 사용 안내 표시 → 시스템 설정에서 Wisp 추가
- [ ] 메뉴바 아이콘 표시, 상태가 "대기 중 (⌥Space)"가 됨
- [ ] TextEdit 열고 ⌥Space 짧게 → HUD 표시 + 빨간 마이크
- [ ] 한국어 문장 말하고 ⌥Space 다시 → "전사 중…" → TextEdit에 텍스트 입력됨
- [ ] ⌥Space 길게 누른 채 말하고 뗌 (PTT) → 동일하게 동작
- [ ] 녹음 중 Esc → 취소되고 아무것도 붙여넣지 않음
- [ ] 클립보드에 "테스트123" 복사 → 받아쓰기 → 잠시 후 클립보드가 "테스트123"으로 복원
- [ ] 포커스 없는 상태(바탕화면 클릭)에서 받아쓰기 → HUD에 "클립보드에 복사됨" 표시
- [ ] 메뉴바 "마지막 결과 복사" → 클립보드에 직전 결과
- [ ] `sqlite3 ~/Library/Application\ Support/Wisp/history.sqlite 'select count(*) from dictation;'` ≥ 1
