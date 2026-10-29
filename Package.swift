// swift-tools-version: 6.0
// Atticus.app's executable: Atticus.swift plus Textual, which draws Markdown and math answers natively. build.sh builds it.
// Plain `swiftc Atticus.swift` (the tests) still works: without Textual, answers fall back to SwiftUI's own Markdown.
import PackageDescription

let package = Package(
    name: "Atticus",
    platforms: [.macOS("26.0")],
    dependencies: [.package(url: "https://github.com/gonzalezreal/textual", exact: "0.5.0")],
    targets: [.executableTarget(name: "Atticus", dependencies: [.product(name: "Textual", package: "textual")], path: ".", sources: ["Atticus.swift"],
                                swiftSettings: [.swiftLanguageMode(.v5)])]
)
