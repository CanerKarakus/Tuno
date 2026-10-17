// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tuno",
    defaultLocalization: "tr",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Site üzerinden dağıtılan sürüm için otomatik güncelleme.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Tuno",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Tuno",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework uygulama paketinin Frameworks klasöründen yüklenir.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
