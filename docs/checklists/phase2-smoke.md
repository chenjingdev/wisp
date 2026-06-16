# Phase 2 수동 스모크 체크리스트

빌드·실행: `./scripts/make-app.sh && open build/Wisp.app`

- [ ] 메뉴바에서 "메시지" 모드 선택
- [ ] TextEdit에서 ⌥Space → "어 그 내일 음 3시에 보자고 어 전해줘" 발화 → 종료
- [ ] HUD가 "전사 중…" → "다듬는 중…" 순서로 표시
- [ ] 군말 제거된 자연스러운 문장이 붙여넣어짐
- [ ] "받아쓰기" 모드 → 동일 발화 → STT 원문이 거의 그대로 ("다듬는 중…" 단계 없음)
- [ ] 히스토리 확인:
      `sqlite3 ~/Library/Application\ Support/Wisp/history.sqlite 'select modeId, llmSucceeded, substr(coalesce(llmOutput,transcript),1,30) from dictation order by createdAt desc limit 3;'`
- [ ] 폴백: Wisp가 띄운 app-server만 종료(`pgrep -f "codex app-server" 확인 후 해당 PID만 kill`) 직후 받아쓰기 → 재시작/exec로 결과 나옴
- [ ] 네트워크 차단 상태에서 받아쓰기 → STT 원문이 붙여넣어짐 (무손실)
- [ ] 후처리 체감 지연 기록 (목표: 3초 이내)
