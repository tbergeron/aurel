// swift-tools-version: 6.0
// Aurel.app's executable: Aurel.swift (as main.swift, so its top-level code runs) and the native windows beside it, plus Textual and
// SwiftUIMath, which draw Markdown and math answers natively. build.sh builds it. Without them (plain swiftc), math shows as its TeX source.
import PackageDescription

let package = Package(
    name: "Aurel",
    platforms: [.macOS("26.0")],
    dependencies: [.package(url: "https://github.com/gonzalezreal/textual", exact: "0.5.0"), .package(url: "https://github.com/gonzalezreal/swiftui-math", exact: "0.1.0")],
    targets: [.executableTarget(name: "Aurel", dependencies: [.product(name: "Textual", package: "textual"), .product(name: "SwiftUIMath", package: "swiftui-math")], path: ".", sources: ["main.swift", "NativeUI.swift", "Orb.swift", "Settings.swift", "Onboarding.swift", "Answer.swift", "Box.swift"],
                                swiftSettings: [.swiftLanguageMode(.v5)])]
)
