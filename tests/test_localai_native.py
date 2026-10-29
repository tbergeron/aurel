"""Local AI engine (Atticus.swift `// MARK: Local AI` section) compiled alone against a scratch ATTICUS_DIR."""
import functools
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import threading
import unittest
from unittest.mock import patch

from tests import run_swift

ROOT = Path(__file__).resolve().parents[1]
GEMMA = Path.home() / '.config/atticus/llm/gemma-4-E4B_q4_0-it.gguf'

# Stands in for llama-server: answers /health on the port Atticus gives it.
FAKE_SERVER = f"""#!{sys.executable} -I
import http.server, sys
port = int(sys.argv[sys.argv.index('--port') + 1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200 if self.path == '/health' else 404); self.end_headers(); self.wfile.write(b'{{"status":"ok"}}')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
"""


def engine():
    source = (ROOT / 'Atticus.swift').read_text()
    prefs = source[source.index('enum Prefs'):source.index('func applySharing(')]
    local = source[source.index('// MARK: Local AI'):source.index('// MARK: end Local AI')]
    return 'import Cocoa\nlet controlKey = 1, optionKey = 2\n' + prefs + local


def tarball():
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w:gz') as t:
        body = FAKE_SERVER.encode()
        info = tarfile.TarInfo('llama-b11606/llama-server'); info.size = len(body); info.mode = 0o755
        t.addfile(info, io.BytesIO(body))
    return data.getvalue()


@unittest.skipUnless(sys.platform == 'darwin', 'macOS Swift regression')
class LocalAINativeTests(unittest.TestCase):
    def scratch(self):
        root = Path(tempfile.mkdtemp(prefix='atticus-local-')); self.addCleanup(shutil.rmtree, root, True)
        p = patch.dict(os.environ, {'ATTICUS_DIR': str(root)}); p.start(); self.addCleanup(p.stop)
        return root

    def serve(self, files):
        site = Path(tempfile.mkdtemp(prefix='atticus-site-')); self.addCleanup(shutil.rmtree, site, True)
        for name, data in files.items(): (site / name).write_bytes(data)
        class Quiet(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *a): pass
        httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Quiet, directory=str(site)))
        threading.Thread(target=httpd.serve_forever, daemon=True).start(); self.addCleanup(httpd.shutdown)
        return f'http://127.0.0.1:{httpd.server_address[1]}/'

    def test_download_unpacks_verifies_and_serves(self):
        self.scratch()
        tar, model = tarball(), os.urandom(200_000)
        base = self.serve({'llama.tar.gz': tar, 'good.gguf': model, 'bad.gguf': model})
        sha = lambda b: hashlib.sha256(b).hexdigest()
        out = run_swift(self, engine() + f"""
LocalAI.runtime = LocalAI.Model(id: "runtime", name: "llama.cpp", url: "{base}llama.tar.gz", file: "llama.tar.gz", sha256: "{sha(tar)}", bytes: {len(tar)})
LocalAI.models = [LocalAI.Model(id: "good", name: "Good", url: "{base}good.gguf", file: "good.gguf", sha256: "{sha(model)}", bytes: {len(model)}),
                  LocalAI.Model(id: "bad", name: "Bad", url: "{base}bad.gguf", file: "bad.gguf", sha256: "{'0' * 64}", bytes: {len(model)})]
let l = LocalAI.shared, sem = DispatchSemaphore(value: 0), fm = FileManager.default
func fetch(_ id: String) {{
    l.download(id) {{ sem.signal() }}
    for _ in 0..<200 {{
        _ = sem.wait(timeout: .now() + 0.1)
        let s = l.status(), m = (s["models"] as! [[String: Any]]).first {{ $0["id"] as? String == id }}!
        if m["progress"] is NSNull && s["runtime"] is NSNull {{ return }}
    }}
    preconditionFailure("download of \\(id) never finished")
}}
precondition(l.address() == "" && !l.ready)   // nothing downloaded: no server
fetch("good")
precondition(fm.isExecutableFile(atPath: LocalAI.server) && !fm.fileExists(atPath: LocalAI.dir + "/llama.tar.gz.part") && !fm.fileExists(atPath: LocalAI.dir + "/.unpack"))
precondition(l.status()["server"] as? Bool == true && l.status()["error"] is NSNull && l.ready)
fetch("bad")
precondition(l.status()["error"] as? String == "The download didn’t match. Try again." && !fm.fileExists(atPath: LocalAI.dir + "/bad.gguf"))
let url = l.address()
precondition(url.hasPrefix("http://127.0.0.1:") && l.address() == url)   // a second ask reuses the running server
var up = false
for _ in 0..<100 where !up {{
    if let (_, r) = try? await URLSession.shared.data(from: URL(string: url + "/health")!), (r as? HTTPURLResponse)?.statusCode == 200 {{ up = true }}
    else {{ try? await Task.sleep(nanoseconds: 100_000_000) }}
}}
precondition(up && l.status()["running"] as? Bool == true)
l.delete("good")
precondition(l.status()["running"] as? Bool == false && !l.ready && !fm.fileExists(atPath: LocalAI.dir + "/good.gguf"))
print("ok")
""", timeout=60)
        self.assertEqual(out.strip(), 'ok')

    def test_live_router_with_the_real_runtime(self):
        if not GEMMA.exists() or not os.environ.get('ATTICUS_LIVE_LOCAL'):
            self.skipTest('set ATTICUS_LIVE_LOCAL=1 with Gemma downloaded: downloads llama.cpp and runs the model')
        root = self.scratch()
        (root / 'llm').mkdir(); (root / 'llm' / GEMMA.name).symlink_to(GEMMA)
        import atticus
        out = run_swift(self, engine() + f"""
let l = LocalAI.shared, sem = DispatchSemaphore(value: 0)
l.download("gemma4") {{ sem.signal() }}
for _ in 0..<600 where !l.ready || !(l.status()["runtime"] is NSNull) {{ _ = sem.wait(timeout: .now() + 0.1) }}
precondition(l.ready, "\\(l.status())")
let url = l.address()
var reply = ""
for _ in 0..<600 where reply.isEmpty {{
    var r = URLRequest(url: URL(string: url + "/v1/chat/completions")!); r.httpMethod = "POST"
    r.httpBody = try! JSONSerialization.data(withJSONObject: ["messages": [["role": "system", "content": {json.dumps(atticus.ROUTER)}],
        ["role": "user", "content": "Front app: Safari, window \\"Docs\\"\\nOpen apps: Safari, Slack\\nRequest: switch over to slack"]],
        "grammar": {json.dumps(atticus.ROUTER_GRAMMAR)}, "temperature": 0, "max_tokens": 20])
    if let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let c = j["choices"] as? [[String: Any]],
       let m = c.first?["message"] as? [String: Any] {{ reply = m["content"] as? String ?? "" }}
    else {{ try? await Task.sleep(nanoseconds: 100_000_000) }}
}}
print(reply); l.stop()
""", timeout=300)
        self.assertEqual(out.strip(), 'open Slack')


if __name__ == '__main__':
    unittest.main()
