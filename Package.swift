// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Record",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Record", targets: ["MeetingAudio"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.9.4"
        )
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.6/whisper-v1.8.6-xcframework.zip",
            checksum: "654f6534b1d109cf1f53c3ac94de14d1aedbc08600bf9743e2b331c1619a863f"
        ),
        .executableTarget(
            name: "MeetingAudio",
            dependencies: [
                "whisper",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
