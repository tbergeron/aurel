// swift-tools-version: 6.2
// atticus-parakeet: the Parakeet speech helper Atticus.app runs (Settings → Speech model → Parakeet). build.sh builds it.
import PackageDescription

let package = Package(
    name: "atticus-parakeet",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])],   // ASR + VAD only
    targets: [.executableTarget(name: "atticus-parakeet", dependencies: ["FluidAudio"])]
)
