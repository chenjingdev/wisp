import Foundation

/// 녹음 동안 재생 중인 미디어를 일시정지/재개한다. macOS엔 공개 API가 없어
/// 비공개 MediaRemote를 dlopen/dlsym으로 쓴다(BetterTouchTool 등이 쓰는 방식).
///
/// 설계(리서치 + 실측 근거):
///  - **전송**(pause/play)은 `MRMediaRemoteSendCommand`로 now-playing 앱에 보낸다 — Music·
///    Spotify뿐 아니라 Media Session을 구현한 브라우저(YouTube/Netflix)까지 멈춘다. 이 경로는
///    비특권 프로세스에서도 동작한다(실측 확인).
///  - **재생 여부 읽기**는 macOS 15.4+/26에서 `com.apple.*` 번들에만 허용된다
///    (`com.apple.mediaremote.now-playing-read-access` 게이트). 우리 앱은 비특권이라 in-process
///    조회·알림이 전부 막힌다(false/빈값/0회). 그래서 읽기만 **`/usr/bin/perl`(com.apple.perl5)
///    경유 헬퍼(mr_probe)** 로 위임한다(ungive/mediaremote-adapter 원리).
///  - 동작: pause는 **즉시(낙관적)** 보내 녹음 시작을 지연시키지 않고, "재생 중이었는지"는
///    **비동기 probe**로 확인해 **재생 중이던 것만** 종료 시 재개한다. probe 실패(nil)·멈춤(false)
///    이면 재개하지 않아 **멈춰 있던 미디어를 깨우지 않는다.**
@MainActor
final class MediaController {
    /// 재생 여부 비동기 조회. 완료 콜백은 메인에서 호출된다(nil = 불명).
    typealias Probe = (@escaping @Sendable (Bool?) -> Void) -> Void

    private let send: (Int) -> Void
    private let probe: Probe
    private var pausedByUs = false
    /// 진행 중인 probe를 식별/무효화한다 — 종료(resume) 후 늦게 도착한 probe가 pausedByUs를
    /// 되살려 엉뚱하게 깨우는 것을 막는다.
    private var probeGeneration = 0

    private static let kCommandPlay = 0
    private static let kCommandPause = 1

    /// send/probe를 주입하면 테스트에서 실제 미디어·perl을 건드리지 않는다.
    init(send: ((Int) -> Void)? = nil, probe: Probe? = nil) {
        self.send = send ?? Self.makeRealSender()
        let injected = probe != nil
        self.probe = probe ?? Self.makePerlProbe()
        // 실제(perl) probe만 워밍 — perl/dyld 캐시를 데워 첫 받아쓰기의 정지 지연(콜드 스타트
        // ~150ms)을 줄인다(결과 버림). 주입된 테스트 probe는 건드리지 않는다.
        if !injected { self.probe { _ in } }
    }

    /// 받아쓰기 시작: **먼저 재생 여부를 읽고**(perl 위임 ~20ms), 그 결과로 정지/재개를 정한다.
    /// pause를 먼저 보내면 그 직후 read가 우리 pause를 반영해 false로 보여 "재생 중이던 것만
    /// 재개"가 깨지므로, 반드시 **read → 판정 → 명령** 순서다. 재생 중이면 멈추고 종료 시
    /// 재개, 멈춰 있으면(false) 손대지 않고, 불명(nil)이면 낙관적으로 멈추되 재개는 안 한다
    /// (브라우저 등 전역 정지는 살리되 깨우지는 않음). probe가 ~20ms라 정지 지연은 미미하다.
    func pauseMedia() {
        probeGeneration += 1
        let gen = probeGeneration
        MultitouchHotkey.diag("MEDIA: 재생여부 probe 시작(gen=\(gen))")
        probe { [weak self] playing in
            MainActor.assumeIsolated {
                // 늦게 도착한 probe(이미 종료돼 generation이 바뀐 경우)는 무시 — 명령도 안 보낸다.
                guard let self, self.probeGeneration == gen else { return }
                switch playing {
                case .some(true):
                    self.send(Self.kCommandPause)
                    self.pausedByUs = true
                    MultitouchHotkey.diag("MEDIA: 재생 중 → pause, 종료 시 재개")
                case .none:
                    self.send(Self.kCommandPause)   // 불명 → 낙관적 정지(재개는 안 함)
                    self.pausedByUs = false
                    MultitouchHotkey.diag("MEDIA: 재생여부 불명 → pause(무깨움)")
                case .some(false):
                    self.pausedByUs = false          // 이미 멈춤 → 건드리지 않음
                    MultitouchHotkey.diag("MEDIA: 멈춰 있음 → 그대로 둠")
                }
            }
        }
    }

    /// 우리가 멈춘(=재생 중이라고 확인된) 경우에만 재생 재개. 멱등. generation을 올려
    /// 진행 중인 probe를 무효화한다 — 종료 후 늦게 온 probe가 pause/재개를 일으키지 않도록.
    func resumeIfPaused() {
        probeGeneration += 1
        guard pausedByUs else { return }
        send(Self.kCommandPlay)
        pausedByUs = false
    }

    // MARK: - 재생 여부 조회 (perl 위임)

    /// 번들 리소스의 mr_probe.pl + mr_probe.dylib을 /usr/bin/perl로 실행해 "1/0/?"을 받는다.
    /// 리소스가 없으면(개발 중 `swift build` 실행 등) 항상 nil → 재개 비활성(무깨움).
    private static func makePerlProbe() -> Probe {
        let res = Bundle.main.resourceURL
        let fm = FileManager.default
        guard let pl = res?.appendingPathComponent("mr_probe.pl").path,
              let dylib = res?.appendingPathComponent("mr_probe.dylib").path,
              fm.fileExists(atPath: pl), fm.fileExists(atPath: dylib) else {
            MultitouchHotkey.diag("MEDIA: mr_probe 리소스 없음 — 재개 비활성(무깨움)")
            return { completion in DispatchQueue.main.async { completion(nil) } }
        }
        return { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.runPerlProbe(perl: pl, dylib: dylib)
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// 백그라운드에서 perl을 1회 spawn해 재생 여부를 동기로 읽는다. 데드라인 내 미종료면 nil.
    private static func runPerlProbe(perl: String, dylib: String) -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")  // 절대경로 필수(com.apple.perl5)
        p.arguments = [perl, dylib]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            MultitouchHotkey.diag("MEDIA: perl 실행 실패 — \(error)")
            return nil
        }
        let deadline = Date().addingTimeInterval(1.0)   // perl 부팅 ~80–150ms
        while p.isRunning && Date() < deadline { usleep(5_000) }
        if p.isRunning { p.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if s.hasPrefix("1") { return true }
        if s.hasPrefix("0") { return false }
        return nil
    }

    // MARK: - 명령 전송

    private static func makeRealSender() -> (Int) -> Void {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY),
              let sym = dlsym(handle, "MRMediaRemoteSendCommand")
        else { MultitouchHotkey.diag("MEDIA: MRMediaRemoteSendCommand 심볼 로드 실패"); return { _ in } }
        // 프레임워크는 프로세스 수명 동안 상주 — handle을 닫지 않는다.
        typealias SendCommandFn = @convention(c) (Int, CFDictionary?) -> Bool
        let fn = unsafeBitCast(sym, to: SendCommandFn.self)
        // 보조 방어: now-playing 세션이 없을 때 명령이 기본 음악 앱을 깨우는 암묵적
        // 실행을 끈다. 비공개 옵션 키라 무시될 수 있으나 무해.
        let options = ["kMRMediaRemoteOptionDisableImplicitAppLaunchBehaviors": true] as CFDictionary
        return { cmd in let ok = fn(cmd, options); MultitouchHotkey.diag("MEDIA: send cmd=\(cmd) ok=\(ok)") }
    }
}
