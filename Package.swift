// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Record",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Record", targets: ["MeetingAudio"])
    ],
    targets: [
        .executableTarget(name: "MeetingAudio")
    ],
    swiftLanguageModes: [.v5]
)
