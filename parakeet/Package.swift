// swift-tools-version: 6.2
// aurel-parakeet: the Parakeet speech helper Aurel.app runs (Settings → Speech model → Parakeet). build.sh builds it.
import PackageDescription

let package = Package(
    name: "aurel-parakeet",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])],   // ASR + VAD only
    targets: [.executableTarget(name: "aurel-parakeet", dependencies: ["FluidAudio"])]
)
