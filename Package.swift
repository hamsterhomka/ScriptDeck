// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScriptDeck",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ScriptDeck",
            path: "Sources/ScriptDeck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
