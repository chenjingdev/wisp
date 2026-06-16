import AppKit

@MainActor
final class RecordingController: ObservableObject {
    @Published private(set) var state: PipelineState = .idle
    @Published private(set) var inputLevel: AudioLevel = .zero
    @Published private(set) var notice: String?

    private(set) var processingTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?

    private let audio: AudioServicing
    private var transcription: any Transcribing
    private var postProcess: PostProcessing
    private let paste: Pasting
    private let history: HistoryStoring
    private let modeProvider: () -> Mode
    private let frontmostBundleId: () -> String?
    private let effects: RecordingEffects
    /// whisper 인식 힌트(initial_prompt). 종료 시점에 평가돼 최신 설정을 읽는다.
    private let vocabulary: () -> String
    /// 출력 직전 결정적 단어 교체. 기본은 무변환.
    private let replace: (String) -> String
    /// 녹음 시작 시점에 주변 컨텍스트(선택 텍스트/클립보드)를 캡처한다.
    private let captureContext: () -> DictationContext
    /// 무음 게이트 peak 문턱. 종료 시점에 평가돼 최신 설정(무음 감지 감도)을 읽는다.
    private let speechThreshold: () -> Float
    /// startRecording에서 캡처해 stopAndProcess가 후처리에 넘긴다.
    private var capturedContext = DictationContext()
    /// 마지막 자동 붙여넣기(.pasted)된 텍스트와 시각. 트랙패드 더블탭 취소가
    /// "방금 받아쓴 글자 수만큼 Backspace"로 되돌리는 데 쓴다 — ⌘Z(앱 네이티브 undo)는
    /// 터미널·검색창 등 undo 스택이 없는 입력에서 안 먹어 z만 남기 때문이다.
    private(set) var lastPasteAt: Date?
    private(set) var lastPastedText: String?

    init(audio: AudioServicing,
         transcription: any Transcribing,
         postProcess: PostProcessing,
         paste: Pasting,
         history: HistoryStoring,
         modeProvider: @escaping () -> Mode,
         frontmostBundleId: @escaping () -> String? = {
             NSWorkspace.shared.frontmostApplication?.bundleIdentifier
         },
         effects: RecordingEffects = NoopRecordingEffects(),
         vocabulary: @escaping () -> String = { "" },
         replace: @escaping (String) -> String = { $0 },
         captureContext: @escaping () -> DictationContext = { DictationContext() },
         speechThreshold: @escaping () -> Float = { AudioMath.speechPeakThreshold }) {
        self.audio = audio
        self.transcription = transcription
        self.postProcess = postProcess
        self.paste = paste
        self.history = history
        self.modeProvider = modeProvider
        self.frontmostBundleId = frontmostBundleId
        self.effects = effects
        self.vocabulary = vocabulary
        self.replace = replace
        self.captureContext = captureContext
        self.speechThreshold = speechThreshold
    }

    func toggleOrStart() {
        switch state {
        case .recording: stopAndProcess()
        case .idle: startRecording()
        default: break
        }
    }

    func startRecording() {
        guard state == .idle else { return }
        // 새 받아쓰기는 이전 받아쓰기의 취소(undo) 대상을 무효화한다 — 묵은 lastPastedText
        // 글자 수만큼 엉뚱하게 Backspace하지 않도록. 처리 중이면 startRecording이 막히므로
        // (state != .idle) pendingIdleActions는 보통 비어 있지만 방어적으로 함께 비운다.
        lastPasteAt = nil
        lastPastedText = nil
        pendingIdleActions = []
        resetTask?.cancel()
        notice = nil
        do {
            try audio.startRecording { [weak self] level in
                Task { @MainActor in self?.inputLevel = level }
            }
            // 선택 텍스트/클립보드는 핫키를 누른 지금(포커스가 활성 앱에 있을 때) 캡처해야
            // 한다 — 처리 시점엔 포커스가 이동했을 수 있다. 사용 여부는 종료 모드가 결정.
            capturedContext = captureContext()
            state = .recording
            effects.onRecordingStart(mode: modeProvider())
        } catch {
            fail("녹음 시작 실패: \(error.localizedDescription)")
        }
    }

    func stopAndProcess() {
        guard state == .recording else { return }
        let mode = modeProvider()
        let targetBundleId = frontmostBundleId()
        // 전환(replaceTranscription)이 전사 도중 일어나도 이 받아쓰기는 stop 시점에 활성이던
        // 엔진으로 끝까지 처리한다 — Task 본문에서 self.transcription을 늦게 읽으면 진행 중
        // 받아쓰기가 새 엔진으로 바뀌는 창이 생긴다. 여기서 동기 캡처해 그 창을 닫는다.
        let transcription = transcription
        state = .transcribing

        processingTask = Task {
            var transcript: String?
            var sttSeconds: Double = 0
            var recordSeconds: Double = 0
            do {
                let recording = try audio.stopRecording()
                // 마이크가 멈춘 시점 — 전사를 기다리지 말고 즉시 미디어 재개/볼륨 복원
                effects.onRecordingEnd()
                recordSeconds = recording.duration
                // 무음 게이트 — 아무 말 없이 버튼만 떼면 whisper가 "Thank you"/"감사합니다"
                // 등으로 환각한다. 명백한 무음이면 전사하지 않고 조용히 종료한다(붙여넣기·기록
                // 없음, 보류된 톡(Enter)도 폐기). 실측 레벨로 문턱을 맞추려 peak/rms를 남긴다.
                let pk = AudioMath.peak(recording.samples)
                let rms = AudioMath.rms(recording.samples)
                let hasSpeech = AudioMath.hasSpeech(recording.samples, peakThreshold: speechThreshold())
                MultitouchHotkey.diag("AUDIO: peak=\(pk) rms=\(rms) dur=\(recordSeconds) speech=\(hasSpeech) n=\(recording.samples.count)")
                guard hasSpeech else {
                    pendingIdleActions = []
                    notice = nil
                    state = .idle
                    return
                }
                let sttStart = Date()
                let text = try await transcription.transcribe(
                    samples: recording.samples, language: mode.language,
                    prompt: vocabulary(), translate: mode.translateToEnglish
                )
                sttSeconds = Date().timeIntervalSince(sttStart)
                guard !text.isEmpty else { throw WispError.emptyTranscript }
                transcript = text

                state = .postProcessing
                let outcome = await postProcess.process(transcript: text, mode: mode, context: capturedContext)

                // 출력 직전 결정적 치환(고유명사·약어 교정). 히스토리 저장은 원문을
                // 유지해 무엇이 바뀌었는지 추적 가능하게 둔다.
                let outputText = replace(outcome.finalText)
                let pasteResult = paste.paste(outputText)
                if pasteResult == .pasted { lastPasteAt = Date(); lastPastedText = outputText }
                save(DictationRecord(
                    id: UUID().uuidString, createdAt: Date(),
                    transcript: text, llmOutput: outcome.llmOutput, modeId: mode.id,
                    targetBundleId: targetBundleId, llmSucceeded: outcome.llmSucceeded,
                    recordSeconds: recordSeconds, sttSeconds: sttSeconds,
                    llmSeconds: outcome.llmSeconds
                ))
                state = .finished
                effects.onComplete()
                // 결과를 HUD에 직접 보여준다 — 붙여넣기가 보이지 않는 곳에
                // 떨어져도 사용자가 전사 결과를 확인하고 ⌘V로 복구할 수 있다
                let snippet = outputText.count > 42
                    ? String(outputText.prefix(42)) + "…"
                    : outputText
                switch pasteResult {
                case .pasted:
                    notice = "“\(snippet)”"
                case .clipboardOnly:
                    notice = "“\(snippet)” — 클립보드에 복사됨, ⌘V로 붙여넣기"
                case .needsAccessibility:
                    notice = "“\(snippet)” — 자동 붙여넣기엔 손쉬운 사용 권한 필요 (클립보드엔 복사됨)"
                }
                resetSoon()
                flushPendingIdleActions()   // 처리 중 보류된 톡(Enter)을 텍스트 붙은 직후 실행
            } catch {
                // stopRecording 자체가 던졌으면 위 onRecordingEnd가 실행되지 않았을 수
                // 있다 — 멱등이므로 한 번 더 호출해 미디어/볼륨을 확실히 복원한다.
                effects.onRecordingEnd()
                save(DictationRecord(
                    id: UUID().uuidString, createdAt: Date(),
                    transcript: transcript, llmOutput: nil, modeId: mode.id,
                    targetBundleId: targetBundleId, llmSucceeded: false,
                    recordSeconds: recordSeconds, sttSeconds: sttSeconds, llmSeconds: 0
                ))
                pendingIdleActions = []   // 처리 실패 — 텍스트가 없으니 보류한 톡 폐기
                fail(error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard state == .recording else { return }
        audio.cancelRecording()
        effects.onRecordingEnd()
        state = .idle
    }

    /// 전사·후처리 진행 중인지.
    var isBusy: Bool {
        switch state {
        case .transcribing, .postProcessing: return true
        default: return false
        }
    }

    /// 처리가 진행 중이면 완료(텍스트가 붙은 뒤) 후, 아니면 즉시 실행한다.
    /// "받아쓰고 손 떼자마자 톡(Enter)"이 처리 딜레이에 씹히지 않도록, 그 Enter를
    /// 처리 완료 시점으로 미뤄 자동 전송되게 한다.
    private var pendingIdleActions: [() -> Void] = []
    func runWhenIdle(_ action: @escaping () -> Void) {
        if isBusy {
            pendingIdleActions.append(action)
        } else {
            action()
        }
    }

    private func flushPendingIdleActions() {
        let actions = pendingIdleActions
        pendingIdleActions = []
        for a in actions { a() }
    }

    /// 방금 자동 붙여넣은 텍스트가 대상 앱에 안착할 때까지 남은 시간(트랙패드 톡=Enter용).
    /// "paste 안착 감지 후 auto-send"를 시간 기반으로 근사한다 —
    /// 터미널은 ⌘V를 PTY로 비동기 처리해 native 필드보다 느리므로, 갓 붙여넣은 직후 Return이
    /// paste보다 먼저 도착해 씹히는 것을 막는다. 붙여넣은 지 window를 넘겼으면(또는 자동
    /// 붙여넣기가 없었으면) 0 — 사용자가 텍스트를 보고 한참 뒤 톡 친 경우엔 지연을 안 준다.
    func pasteSettleRemaining(window: TimeInterval = 0.15, now: Date = Date()) -> TimeInterval {
        guard let t = lastPasteAt else { return 0 }
        return max(0, window - now.timeIntervalSince(t))
    }

    /// 트랙패드 더블탭 취소용 — 방금 받아쓰기를 ⌘Z로 되돌릴 수 있는 상태인가.
    /// window(기본 8초) 이내의 자동 붙여넣기가 있을 때만 true.
    func recentDictationUndoable(now: Date = Date(), window: TimeInterval = 8) -> Bool {
        guard let t = lastPasteAt else { return false }
        return now.timeIntervalSince(t) <= window
    }

    /// 취소를 한 번 쓰고 무효화한다 — 더블탭 2회에 Backspace가 2번 가 이전 내용까지
    /// 지워지는 것을 막는다.
    func markDictationUndone() {
        lastPasteAt = nil
        lastPastedText = nil
    }

    /// codex 설정 변경 시 후처리기 교체. 진행 중인 받아쓰기는 이미 캡처된
    /// 기존 인스턴스로 끝까지 처리된다.
    func replacePostProcessor(_ newValue: PostProcessing) {
        postProcess = newValue
    }

    /// 모델 전환 시 전사 엔진 교체(이미 warmUp된 인스턴스를 받는다). 진행 중인 받아쓰기는
    /// stopAndProcess가 시작 시 캡처한 기존 엔진으로 끝까지 처리되고, 교체는 다음 받아쓰기부터
    /// 적용된다 — 전환은 보통 유휴 상태에서 일어난다.
    func replaceTranscription(_ newValue: any Transcribing) {
        transcription = newValue
    }

    private func save(_ record: DictationRecord) {
        do { try history.save(record) } catch {
            NSLog("Wisp: 히스토리 저장 실패 — \(error)")
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        resetSoon()
    }

    private func resetSoon() {
        resetTask?.cancel()
        resetTask = Task {
            // 결과 텍스트를 읽을 시간을 준다
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            if state != .recording { state = .idle }
        }
    }
}
