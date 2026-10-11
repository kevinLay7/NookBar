// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NookBar",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "NookBar", targets: ["NookBar"])],
    targets: [
        .target(name: "NativeMenuBar", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .executableTarget(name: "NookBar", dependencies: ["NativeMenuBar"])
    ]
)
