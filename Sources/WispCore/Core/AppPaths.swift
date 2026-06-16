import Foundation

enum AppPaths {
    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wisp")
    }
    static var models: URL { appSupport.appendingPathComponent("models") }
    static var modes: URL { appSupport.appendingPathComponent("modes") }
    /// 구버전이 남긴 녹음 폴더. 더는 생성/사용하지 않으며 시작 시 1회 정리한다.
    static var recordings: URL { appSupport.appendingPathComponent("recordings") }
    static var configURL: URL { appSupport.appendingPathComponent("config.json") }
    static var databaseURL: URL { appSupport.appendingPathComponent("history.sqlite") }
    /// 기본 모델 파일 경로. 활성 모델 경로는 `modelURL(fileName:)`으로 파생한다.
    static var modelURL: URL { modelURL(fileName: ModelCatalog.defaultModel.fileName) }

    /// 모델 파일명에서 디스크 경로를 파생한다(models 폴더 하위).
    static func modelURL(fileName: String) -> URL {
        models.appendingPathComponent(fileName)
    }

    /// 앱 번들에 포함된 Silero VAD 모델(무음 환각 방지용 whisper.cpp 내장 VAD). 번들에 없으면
    /// nil → VAD 미사용(에너지 게이트만으로 무음 처리).
    static var vadModelURL: URL? {
        Bundle.main.url(forResource: "ggml-silero-v6.2.0", withExtension: "bin")
    }

    static func ensureDirectories() throws {
        for dir in [appSupport, models, modes] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
