import Foundation

// mock 프로세스가 먼저 종료된 뒤 stdin write 시 SIGPIPE로 러너 전체가 죽는 것을 방지
signal(SIGPIPE, SIG_IGN)

// 테스트 진입점. 새 테스트 그룹은 여기 등록한다.
let runner = await TestRunner(filter: CommandLine.arguments.dropFirst().first)

await scaffoldTests(runner)
await cWhisperLinkTests(runner)
await configStoreTests(runner)
await modeStoreTests(runner)
await audioTests(runner)
await transcriptionTests(runner)
await modelCatalogTests(runner)
await modelManagerTests(runner)
await modelSetupServiceTests(runner)
await hotkeyStateMachineTests(runner)
await hotkeyCaptureTests(runner)
await presetHotkeysTests(runner)
await fingerCountGateTests(runner)
await tapHoldGateTests(runner)
await multitouchWatchdogTests(runner)
await mediaControllerTests(runner)
await textReplacerTests(runner)
await pasteServiceTests(runner)
await historyStoreTests(runner)
await recordingControllerTests(runner)
await codexClientTests(runner)
await restartPolicyTests(runner)
await postProcessServiceTests(runner)
await codexLocatorTests(runner)
await codexRealTests(runner)

await runner.finish()
