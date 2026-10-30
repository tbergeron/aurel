// Parakeet speech for Aurel, through FluidAudio.
//   aurel-parakeet download <model> <marker>   fetches the model and the voice detector, prints "progress <0-1>" lines,
//                                                then writes the model folder's path to <marker> (Aurel reads it as "downloaded")
//   aurel-parakeet serve <model>               prints "ready", then per request reads a UInt32 sample count and that many
//                                                16 kHz mono Float32 samples (little-endian) on stdin, and answers one JSON line
//   aurel-parakeet bench <model> <audio file>  load and transcription times, memory and the text, cold and then warm
// Models: v3 (multilingual), ultra (most accurate), redux (light), v2 (English).
import CoreML
import Darwin
import FluidAudio
import Foundation

func say(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
func fail(_ why: String) -> Never { say("error " + why.split(whereSeparator: \.isNewline).joined(separator: " ")); exit(1) }
let usage = "usage: aurel-parakeet download <model> <marker> | serve <model> | bench <model> <audio>"

let args = CommandLine.arguments
let versions: [String: AsrModelVersion] = ["v3": .v3, "v2": .v2, "ultra": .ultra, "redux": .redux]
guard args.count >= 3, let version = versions[args[2]] else { fail(usage) }
let folder = AsrModels.defaultCacheDirectory(for: version)

// Exact commits, so an upstream change can't swap the model under the user. FluidAudio checks each file's size and hash
// against that commit's listing. Moving one means listening to real audio with the new files first.
ModelRegistry.revisionOverrides = [
    "FluidInference/parakeet-tdt-0.6b-v3-coreml": "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
    "FluidInference/parakeet-tdt-0.6b-v2-coreml": "ee09c569f73759e6d44c9bd16766f477b2b36d39",
    "FluidInference/parakeet-ultra-coreml": "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
    "FluidInference/parakeet-redux-coreml": "8c5ef97a29cd120dc76b354b3f22b7fec3b486f9",
    "FluidInference/silero-vad-coreml": "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
]
// Redux's 2-bit encoder runs on the GPU: on the Neural Engine it compiles for ~25 s every start (measured on an M1).
// On an M1 the GPU is ~5x slower than the Neural Engine models; newer Macs close that gap. speech_bench.sh measures it.
let encoderUnits: MLComputeUnits? = version == .redux ? .cpuAndGPU : nil

func readExactly(_ n: Int) -> Data? {
    var d = Data(capacity: n)
    while d.count < n {
        let chunk = FileHandle.standardInput.readData(ofLength: n - d.count)
        if chunk.isEmpty { return nil }   // Aurel closed the pipe
        d.append(chunk)
    }
    return d
}

func json(_ o: [String: String]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }

func load() async throws -> (AsrManager, VadManager) {
    guard AsrModels.modelsExist(at: folder, version: version) else { fail("The model isn’t downloaded.") }
    let asr = AsrManager(config: .default)
    try await asr.loadModels(try await AsrModels.load(from: folder, version: version, encoderComputeUnits: encoderUnits))
    return (asr, try await VadManager(config: VadConfig(defaultThreshold: 0.6)))
}

func transcribe(_ pcm: [Float], _ asr: AsrManager, _ vad: VadManager) async throws -> String {
    // no voice anywhere in it: say nothing instead of guessing words from noise
    guard try await vad.process(pcm).contains(where: \.isVoiceActive) else { return "" }
    var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    return try await asr.transcribe(pcm, decoderState: &state).text
}

func footprintMB() -> Double {   // what Activity Monitor calls Memory
    var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let ok = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return ok == KERN_SUCCESS ? Double(info.phys_footprint) / 1_000_000 : 0
}

switch args[1] {
case "download" where args.count == 4:
    let progress: ProgressHandler = { p in say("progress \((p.fractionCompleted * 100).rounded() / 100)") }   // Aurel keeps only the latest
    do {
        _ = try await AsrModels.downloadAndLoad(version: version, encoderComputeUnits: encoderUnits, progressHandler: progress)   // load too: compiles it once
        _ = try await VadManager()
        try folder.path.write(toFile: args[3], atomically: true, encoding: .utf8)
        say("done")
    } catch { fail(error.localizedDescription) }

case "serve":
    let asr: AsrManager, vad: VadManager
    do { (asr, vad) = try await load() } catch { fail(error.localizedDescription) }
    say("ready")
    while let head = readExactly(4) {
        let n = Int(head.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard let body = readExactly(n * 4) else { break }
        let pcm = body.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        do { say(json(["text": try await transcribe(pcm, asr, vad)])) } catch { say(json(["error": error.localizedDescription])) }
    }

case "bench" where args.count == 4:   // same audio, same build, an otherwise idle Mac: the numbers compare across models and Macs
    do {
        let pcm = try AudioConverter().resampleAudioFile(path: args[3])
        var start = Date()
        let (asr, vad) = try await load()
        say(String(format: "load %.2f s, %.0f MB", Date().timeIntervalSince(start), footprintMB()))
        for pass in ["cold", "warm"] {
            start = Date()
            let text = try await transcribe(pcm, asr, vad)
            say(String(format: "%@ %.3f s for %.1f s of audio, %.0f MB: ", pass, Date().timeIntervalSince(start), Double(pcm.count) / 16000, footprintMB()) + text)
        }
    } catch { fail(error.localizedDescription) }

default:
    fail(usage)
}
