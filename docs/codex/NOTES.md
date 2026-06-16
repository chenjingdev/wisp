# codex app-server 프로토콜 실측 기록 (Task 14)

- 측정일: 2026-06-12
- 대상: `codex-cli 0.128.0` (`/opt/homebrew/bin/codex`), macOS arm64, ChatGPT 플랜 로그인 상태
- 실측 원본 로그: `/tmp/codex-probe-1.jsonl` (방향·타임스탬프 포함 JSONL)
- 이 문서가 Task 15–16(Swift 클라이언트)의 단일 진실 소스. 메서드명 상수는 여기서 그대로 복사할 것.

## 1. 프레이밍 (framing)

**newline-delimited JSON (JSONL)**. Content-Length 헤더 없음.

- 요청: JSON 한 줄 + `\n` 을 stdin에 쓰고 flush.
- 응답/알림: stdout에서 한 줄 = JSON 메시지 하나.
- stderr: 정상 happy-path에서 **완전히 비어 있음** (0 byte). 단, 별도 파이프로 빼두는 게 안전.
- 서버는 stdin이 닫히면 종료. 프로세스 시작 직후 바로 요청을 받을 수 있음 (initialize 응답까지 0.08초).

## 2. 어휘 (vocabulary)

이 버전(0.128.0)은 **thread / turn / item** 어휘를 사용한다.
(구버전의 `newConversation` / `sendUserMessage` / `addConversationListener` 는 없음 — ClientRequest 스키마에 존재하지 않음.)

- conversation → **thread** (`thread/start`)
- message 전송 → **turn** (`turn/start`, params.input은 `UserInput[]`)
- 출력 단위 → **item** (`item/started`, `item/completed`, type: `agentMessage` | `reasoning` | `userMessage` | ...)
- **별도의 listener 등록/subscribe 호출 불필요.** `thread/start` 하면 해당 커넥션으로 알림이 자동으로 흘러온다.

## 3. 핸드셰이크

### 요청 1: `initialize` (필수, 첫 요청)

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"wisp","title":"Wisp","version":"0.1.0"}}}
```

- `clientInfo.name`, `clientInfo.version` 필수, `title` 선택.
- `params.capabilities.optOutNotificationMethods: [string]` 로 시끄러운 알림(예: `"mcpServer/startupStatus/updated"`)을 끌 수 있음 (스키마 확인, 미실측).
- v2 메서드(thread/turn)는 `experimentalApi` 플래그 **없이도 동작함** (실측).

실측 응답 (0.08초):

```json
{"id":1,"result":{"userAgent":"wisp-probe/0.128.0 (Mac OS 26.5.1; arm64) ghostty/1.3.2-HEAD-_f78189a (wisp-probe; 0.1.0)","codexHome":"/Users/chenjing/.codex","platformFamily":"unix","platformOs":"macos"}}
```

### 알림 2: `initialized` (클라이언트 → 서버, params 없음)

```json
{"jsonrpc":"2.0","method":"initialized"}
```

## 4. happy path 전체 시퀀스 (실측)

메서드 순서: `initialize` → `initialized`(notif) → `thread/start` → `turn/start` → (알림 수신) → `turn/completed` 에서 종료.

### 4.1 `thread/start`

```json
{"jsonrpc":"2.0","id":2,"method":"thread/start","params":{"model":"gpt-5.3-codex-spark","approvalPolicy":"never","sandbox":"read-only","cwd":"/Users/chenjing/dev/whisper","ephemeral":true}}
```

- 모든 파라미터 optional. `sandbox` 는 문자열 enum: `"read-only" | "workspace-write" | "danger-full-access"`.
- `approvalPolicy`: `"untrusted" | "on-failure" | "on-request" | "never"`.
- `ephemeral:true` → 스레드가 디스크 히스토리에 안 남음 (응답의 `path:null`). Wisp 딕테이션 용도에 권장.
- `developerInstructions`(string), `baseInstructions`(string) 파라미터 존재 → 리라이팅 시스템 프롬프트를 여기에 실을 수 있음 (Task 16 참고).

실측 응답 (요청 후 약 0.7초):

```json
{"id":2,"result":{"thread":{"id":"019eb91f-550e-7611-91a4-8b6be90138fd","forkedFromId":null,"preview":"","ephemeral":true,"modelProvider":"openai","createdAt":1781222298,"updatedAt":1781222298,"status":{"type":"idle"},"path":null,"cwd":"/Users/chenjing/dev/whisper","cliVersion":"0.128.0","source":"vscode","name":null,"turns":[]},"model":"gpt-5.3-codex-spark","modelProvider":"openai","serviceTier":"fast","cwd":"/Users/chenjing/dev/whisper","instructionSources":["/Users/chenjing/.codex/AGENTS.md"], ...}}
```

→ **`result.thread.id`** 를 보관 (이후 turn/start에 필요).
→ 요청한 model/sandbox가 config.toml 기본값(gpt-5.5 / danger-full-access)을 **스레드 단위로 정상 오버라이드**함이 응답에서 확인됨.

### 4.2 `turn/start`

```json
{"jsonrpc":"2.0","id":3,"method":"turn/start","params":{"threadId":"019eb91f-550e-7611-91a4-8b6be90138fd","input":[{"type":"text","text":"1+1은? 숫자만."}]}}
```

- required: `threadId`, `input` (UserInput 배열, 텍스트는 `{"type":"text","text":"..."}`).
- turn 단위 오버라이드 가능: `model`, `effort`(`"none"|"minimal"|"low"|"medium"|"high"|"xhigh"`), `approvalPolicy`, `sandboxPolicy`(객체형: `{"type":"readOnly"}` 등 — thread/start의 문자열형과 다름 주의), `outputSchema`.

응답은 **즉시** 반환 (완료 아님):

```json
{"id":3,"result":{"turn":{"id":"019eb91f-5551-7ae0-9505-cd816ac78225","items":[],"status":"inProgress","error":null,"startedAt":null,"completedAt":null,"durationMs":null}}}
```

### 4.3 수신 알림 스트림 (실측, 시간순)

```
remoteControl/status/changed
thread/started                      (thread/start 직후 자동 — subscribe 불필요)
warning                             (config의 미완성 feature 경고 — 무시 가능)
mcpServer/startupStatus/updated ×N  (유저 config의 MCP 서버 기동 — 노이즈)
thread/status/changed               (idle → active)
turn/started
skills/changed
item/started   { item.type: "userMessage" }
item/completed { item.type: "userMessage" }
item/started   { item.type: "reasoning" }      ← 무시
item/completed { item.type: "reasoning" }      ← 무시
item/started   { item.type: "agentMessage", text: "" }
item/agentMessage/delta             (스트리밍 델타: params.delta)
item/completed { item.type: "agentMessage" }   ★ 최종 텍스트
thread/tokenUsage/updated
hook/started / hook/completed       (유저의 Stop hook — 노이즈)
thread/status/changed               (active → idle)
turn/completed                      ★ 턴 종료 신호
```

### 4.4 최종 텍스트를 담는 알림 ★

`item/completed` 중 `params.item.type == "agentMessage"` 인 것. 텍스트는 `params.item.text`:

```json
{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_07ba...","text":"2","phase":"final_answer","memoryCitation":null},"threadId":"019eb91f-...","turnId":"019eb91f-..."}}
```

스트리밍이 필요하면 `item/agentMessage/delta` (params: `delta`, `itemId`, `threadId`, `turnId`).

### 4.5 턴 완료 알림 ★

```json
{"method":"turn/completed","params":{"threadId":"019eb91f-...","turn":{"id":"019eb91f-...","items":[],"status":"completed","error":null,"startedAt":1781222298,"completedAt":1781222306,"durationMs":7796}}}
```

- `turn.status`: `"completed" | "interrupted" | "failed" | "inProgress"`.
- **주의: `turn.items` 는 빈 배열로 옴.** 최종 텍스트는 turn/completed가 아니라 4.4의 `item/completed`에서 수집해야 한다.
- 실패는 `turn.status == "failed"` + `turn.error`, 그리고 별도 `error` 알림(method: `"error"`)도 존재.

## 5. spark 모델 id 확정

**`gpt-5.3-codex-spark`** — 양쪽 경로 모두 실측 동작 확인.

- app-server `model/list` (params `{}`) 응답에 포함됨. 전체 목록(0.128.0 실측):
  `gpt-5.3-codex`(default), `gpt-5.5`, `gpt-5.2`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex-spark` (모두 hidden:false)
- spark로 thread/start 하면 응답 `serviceTier` 가 자동으로 `"fast"` 가 됨.
- reasoning effort 미지정 시에도 reasoning item이 생성되지만 빠름. 더 줄이려면 turn/start에 `"effort":"low"` 시도 가능 (모델별 지원 effort는 model/list의 `supportedReasoningEfforts` 참조; spark 항목 확인 필요).

## 6. 실측 타이밍 (trivial turn, "1+1은? 숫자만." → "2")

| 구간 | 시간 |
|---|---|
| 프로세스 spawn → initialize 응답 | 0.08 s |
| thread/start → 응답 | 0.70 s |
| turn/start → turn/completed | **7.80 s** (서버 자체 durationMs 7796) |
| └ 그중 MCP 서버 기동 대기 (turn/start → userMessage item/started) | ~4.3 s |
| └ 실제 모델 응답 (userMessage → agentMessage 완료) | ~3.3 s |
| `codex exec` 폴백 (동일 질문) | 18.7 s (1회차) / 9.7 s (2회차) |

→ 첫 턴 지연의 절반 이상이 유저 config의 MCP 서버(honcho, chrome-devtools 등) 기동 대기. Wisp에서는 **app-server 프로세스 + 스레드를 미리 만들어 두는(warm) 전략**이 유효. 토큰: trivial turn에 input 15,264 (AGENTS.md 등 포함, cached 3,456) / output 86.

## 7. exec 폴백 (실측 검증 완료)

```bash
codex exec --skip-git-repo-check -m gpt-5.3-codex-spark -s read-only \
  -o /tmp/codex-last-msg.txt "프롬프트..."
```

- `-o, --output-last-message <FILE>`: **최종 agent 메시지만** 파일에 기록됨 (실측: 파일 내용 `7`, exit 0, 9.7초).
- `--json` 플래그도 존재 (JSONL 이벤트를 stdout으로) — 폴백에서는 `-o` 파일 읽기가 가장 단순.
- `--skip-git-repo-check` 필수 (작업 디렉토리가 git repo가 아닐 수 있음), `-s read-only` 로 sandbox 고정.
- stdout에는 hook 로그·토큰 사용량 등 노이즈가 섞이므로 stdout 파싱하지 말고 `-o` 파일만 읽을 것.

## 8. 인증

**headless 동작 확인.** 기존 ChatGPT 로그인(`~/.codex/` 의 auth)을 그대로 사용. 추가 env var, 토큰, 인터랙션 전혀 불필요. `initialize` 응답의 `codexHome` 으로 어느 홈을 쓰는지 확인 가능.

## 9. gotchas

1. **스키마 덤프 명령**: `codex app-server generate-json-schema --out <DIR>` (stdout 출력 아님, `--out` 필수). 결과물은 본 디렉토리(`docs/codex/`)에 커밋됨. `ClientRequest.json`(요청 메서드 전체), `ServerNotification.json`(알림 전체), `v2/`(thread/turn 파라미터별 파일), `v1/`(initialize).
2. **config.toml 상호작용**: 유저 config는 `model="gpt-5.5"`, `sandbox_mode="danger-full-access"`, `approval_policy="never"`, `model_reasoning_effort="xhigh"`. thread/start 파라미터가 model/sandbox/approval을 스레드 단위로 오버라이드함(실측). 단 **reasoning effort는 thread/start에 파라미터가 없으므로** config의 xhigh가 적용될 수 있음 → 필요시 turn/start의 `effort` 로 오버라이드.
3. **instructionSources**: `~/.codex/AGENTS.md` 가 자동 로드되어 입력 토큰에 포함됨 (15k input). 응답 속도엔 큰 영향 없었음.
4. **유저 hook/notify**: turn 종료 시 유저 config의 `notify` 명령(SkyComputerUseClient)이 실행되고 `hook/started`/`hook/completed` 알림이 옴. Wisp의 모든 딕테이션 턴마다 이 프로그램이 실행된다는 점 인지. 무시 가능한 노이즈.
5. **`warning` 알림**: under-development features(child_agents_md, goals) 경고가 thread 시작마다 옴. 무시.
6. **`mcpServer/startupStatus/updated` 노이즈 + 지연**: 유저 MCP 서버들이 thread별로 기동됨. initialize의 `optOutNotificationMethods` 로 알림은 끌 수 있지만 기동 지연 자체는 남음.
7. **turn/start 응답 ≠ 완료**: 응답은 즉시 `status:"inProgress"`. 완료는 반드시 `turn/completed` 알림으로 판단.
8. **`turn/completed` 의 `items` 는 비어 있음** — 최종 텍스트는 `item/completed`(type=agentMessage)에서 수집.
9. **서버 → 클라이언트 요청** (ServerRequest: 승인 요청 등)이 올 수 있는 구조이나, `approvalPolicy:"never"` + `read-only` 에서는 미발생(실측). 견고한 클라이언트라면 미지의 `id` 있는 요청에 에러 응답이라도 돌려줄 것.
10. **macOS에 `timeout` 명령 없음** — 셸 테스트 시 주의 (프로브는 자체 타임아웃으로 해결).
11. **프로세스 정리**: stdin 닫으면 app-server 종료. Wisp는 종료 시 child를 terminate할 것. (`pkill -f codex` 금지 — IDE/Codex.app의 app-server까지 죽는다.)

## 10. Swift 클라이언트용 상수 요약 (Task 15에서 그대로 복사)

```
요청:  initialize, thread/start, turn/start, turn/interrupt, model/list
알림(송신): initialized
알림(수신, 필수 처리): item/completed, turn/completed, error
알림(수신, 선택): item/agentMessage/delta, turn/started, thread/started, item/started
판별: item/completed → params.item.type == "agentMessage" → params.item.text
종료: turn/completed → params.turn.status ("completed"|"failed"|"interrupted")
모델: gpt-5.3-codex-spark
```
