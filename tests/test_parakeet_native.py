"""Parakeet engine (Atticus.swift `// MARK: Parakeet` section) compiled alone against a scratch ATTICUS_DIR and a fake helper."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from tests import run_swift

ROOT = Path(__file__).resolve().parents[1]
HELPER = Path(os.environ.get("XDG_CACHE_HOME", "~/.cache")).expanduser() / "atticus-parakeet/release/atticus-parakeet"   # build.sh's build

# Speaks atticus-parakeet's protocol with no model: "serve" answers each request with its sample count and first sample.
FAKE = f"""#!{sys.executable} -I
import json, struct, sys
mode, version = sys.argv[1], sys.argv[2]
if mode == "download":
    if version == "v2": print("progress 0.5\\nerror No space left", flush=True); sys.exit(1)
    for p in (0.1, 0.5, 1.0): print(f"progress {{p}}", flush=True)
    open(sys.argv[3], "w").write(sys.argv[4] if len(sys.argv) > 4 else "/nowhere"); print("done"); sys.exit(0)
print("ready", flush=True)
while head := sys.stdin.buffer.read(4):
    n = struct.unpack("<I", head)[0]; pcm = struct.unpack(f"<{{n}}f", sys.stdin.buffer.read(n * 4))
    if pcm[0] == -1: print("not json", flush=True); continue
    print(json.dumps({{"error": "boom"}} if pcm[0] == -2 else {{"text": f"  {{n}} samples   first {{pcm[0]:g}} "}}), flush=True)
"""


def engine():
    source = (ROOT / "Atticus.swift").read_text()
    prefs = source[source.index("enum Prefs"):source.index("func applySharing(")]
    parakeet = source[source.index("// MARK: Parakeet"):source.index("// MARK: end Parakeet")]
    return "import Cocoa\nimport AVFoundation\nlet controlKey = 1, optionKey = 2\n" + prefs + parakeet


@unittest.skipUnless(sys.platform == "darwin", "macOS Swift regression")
class ParakeetNativeTests(unittest.TestCase):
    def scratch(self, helper=None):
        root = Path(tempfile.mkdtemp(prefix="atticus-parakeet-")); self.addCleanup(shutil.rmtree, root, True)
        if helper is None:
            helper = root / "fake"; helper.write_text(FAKE); helper.chmod(0o755)
        p = patch.dict(os.environ, {"ATTICUS_DIR": str(root), "ATTICUS_PARAKEET": str(helper)}); p.start(); self.addCleanup(p.stop)
        return root

    def test_request_audio_and_catalog(self):
        self.scratch(helper="/nonexistent")
        run_swift(self, engine() + """
let r = Parakeet.request([1, -0.5])
precondition(r.count == 4 + 8 && Array(r[0..<4]) == [2, 0, 0, 0])
precondition(Array(r[4..<8]) == [0, 0, 0x80, 0x3f] && Array(r[8..<12]) == [0, 0, 0, 0xbf])   // 1.0 and -0.5, little-endian
precondition(Parakeet.models.map(\\.id) == ["v3", "ultra", "redux", "v2"] && Parakeet.model("nope").id == "v3" && Parakeet.model("").id == "v3")
precondition(Parakeet.dir.hasSuffix("/parakeet") && Parakeet.marker(Parakeet.model("v2")).hasSuffix("/parakeet/v2"))
precondition(Parakeet.helperPath() == nil && !Parakeet.shared.ready)
let a = ParakeetAudio(), f = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 8000)!; b.frameLength = 8000
a.append(b); a.append(b)
precondition(a.seconds == 1 && a.snapshot().count == 16000 && a.take().count == 16000 && a.seconds == 0)
let sem = DispatchSemaphore(value: 0)
Task {
    let tap = try await Parakeet.shared.transcribe([0.5, -0.5])   // a tap: no helper needed
    precondition(tap == "")
    do { _ = try await Parakeet.shared.transcribe([Float](repeating: 0.1, count: 16000)); preconditionFailure("no helper") }
    catch { precondition(error.localizedDescription == "The Parakeet helper is missing. Run ./build.sh again.") }
    sem.signal()
}
sem.wait()
print("ok")
""")

    def test_serve_answers_in_order_and_survives_a_bad_reply(self):
        root = self.scratch()
        (root / "parakeet").mkdir(); (root / "parakeet" / "v3").write_text("/x")
        out = run_swift(self, engine() + """
let p = Parakeet.shared, sem = DispatchSemaphore(value: 0)
precondition(p.ready)
func pcm(_ first: Float, _ n: Int) -> [Float] { [first] + [Float](repeating: 0, count: n - 1) }
Task {
    async let a = p.transcribe(pcm(1, 6000)), b = p.transcribe(pcm(2, 7000)), c = p.transcribe(pcm(3, 8000))   // one queue: none mixes up
    print(try await [a, b, c].joined(separator: "|"))
    precondition(p.status()["running"] as? Bool == true)
    do { _ = try await p.transcribe(pcm(-2, 6000)); preconditionFailure("error reply") } catch { precondition(error.localizedDescription == "boom") }
    do { _ = try await p.transcribe(pcm(-1, 6000)); preconditionFailure("bad reply") } catch { precondition(error.localizedDescription == "Parakeet stopped.") }
    precondition(p.status()["running"] as? Bool == false)
    print(try await p.transcribe(pcm(4, 6000)))   // the next request starts a fresh helper
    p.stop(); sem.signal()
}
sem.wait()
""", timeout=30)
        self.assertEqual(out.splitlines(), ["6000 samples first 1|7000 samples first 2|8000 samples first 3", "6000 samples first 4"])

    def test_download_progress_failure_and_delete(self):
        root = self.scratch()
        cache = Path.home() / "Library/Application Support/FluidAudio/Models"
        outside = root / "keep"; outside.mkdir()
        out = run_swift(self, engine() + f"""
let p = Parakeet.shared, sem = DispatchSemaphore(value: 0), fm = FileManager.default
func fetch(_ id: String) -> [String: Any] {{
    p.download(id) {{ sem.signal() }}
    p.download(id) {{ }}   // a second click while it runs is ignored
    for _ in 0..<100 {{
        _ = sem.wait(timeout: .now() + 0.1)
        let m = (p.status()["models"] as! [[String: Any]]).first {{ $0["id"] as? String == id }}!
        if m["progress"] is NSNull {{ return m }}
    }}
    preconditionFailure("download of \\(id) never finished")
}}
precondition(fetch("v3")["have"] as? Bool == true && p.status()["error"] is NSNull)
precondition(fetch("v2")["have"] as? Bool == false && p.status()["error"] as? String == "No space left")
try! "{outside}".write(toFile: Parakeet.marker(Parakeet.model("v3")), atomically: true, encoding: .utf8)   // a marker that points outside the cache
p.delete("v3")
precondition(fm.fileExists(atPath: "{outside}") && !fm.fileExists(atPath: Parakeet.marker(Parakeet.model("v3"))) && !p.ready)
precondition(Parakeet.cache == "{cache}/")
print("ok")
""", timeout=30)
        self.assertEqual(out.strip(), "ok")

    def test_live_transcription(self):
        model = Path.home() / "Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
        if not HELPER.exists() or not model.exists() or not shutil.which("afconvert"):
            self.skipTest("needs build.sh's Parakeet helper, the v3 model and afconvert")
        root = self.scratch(helper=HELPER)
        (root / "parakeet").mkdir(); (root / "parakeet" / "v3").write_text(str(model))
        aiff, wav = root / "a.aiff", root / "a.wav"
        subprocess.run(["say", "-o", str(aiff), "The quick brown fox jumps over the lazy dog."], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32@16000", "-c", "1", str(aiff), str(wav)], check=True)
        out = run_swift(self, engine() + f"""
let file = try! AVAudioFile(forReading: URL(fileURLWithPath: "{wav}"))
let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try! file.read(into: buf)
let audio = ParakeetAudio(); audio.append(buf)
let sem = DispatchSemaphore(value: 0)
Task {{
    print(try await Parakeet.shared.transcribe(audio.take()))
    print(try await Parakeet.shared.transcribe([Float](repeating: 0, count: 32000)) == "" ? "silent" : "invented words")   // no voice, no words
    Parakeet.shared.stop(); sem.signal()
}}
sem.wait()
""", timeout=90)
        self.assertIn("fox", out.lower())
        self.assertIn("silent", out)


if __name__ == "__main__":
    unittest.main()
