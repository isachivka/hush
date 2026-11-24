// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hush",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Hush")],
    swiftLanguageModes: [.v5]
)
