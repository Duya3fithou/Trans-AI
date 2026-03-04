// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TranscribeTranslateApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "TranscribeTranslateApp",
            targets: ["TranscribeTranslateApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "TranscribeTranslateApp",
            path: "app/TranscribeTranslateApp",
            exclude: ["Config"],
            sources: ["Sources"],
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
