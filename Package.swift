// swift-tools-version:6.0
import PackageDescription

// 주의: 이 머신은 Xcode 없이 Command Line Tools만 설치되어 있다.
// CLT에는 XCTest가 없고 swift-testing은 컴파일러와 ABI가 어긋나 테스트가 발견되지 않으므로,
// 테스트는 WispTests 실행 타깃(자체 TestKit 러너)으로 돌린다: ./scripts/test.sh [필터]
let package = Package(
    name: "Wisp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),
        .target(
            name: "WispCore",
            dependencies: [
                "CWhisper",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Lvendor/whisper-lib"]),
                .linkedLibrary("whisper"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
                .linkedLibrary("ggml-cpu"),
                .linkedLibrary("ggml-metal"),
                .linkedLibrary("ggml-blas"),
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(name: "Wisp", dependencies: ["WispCore"]),
        .executableTarget(
            name: "WispTests",
            dependencies: ["WispCore", "CWhisper"],
            path: "Tests/WispTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
