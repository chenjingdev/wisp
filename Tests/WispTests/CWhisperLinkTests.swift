import Foundation
import CWhisper

@MainActor
func cWhisperLinkTests(_ t: TestRunner) async {
    await t.test("CWhisper: whisper 심볼 링크") {
        let info = String(cString: whisper_print_system_info())
        try expect(!info.isEmpty)
    }
}
