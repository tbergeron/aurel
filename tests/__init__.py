"""Isolate config before importing any Aurel test module."""
import atexit
import os
import tempfile

config = tempfile.TemporaryDirectory(prefix='aurel-test-config-')
os.environ['AUREL_DIR'] = config.name
atexit.register(config.cleanup)


def scratch_dir(test):
    """A temp aurel.DIR with default prefs for one test, undone at cleanup; returns the folder."""
    from pathlib import Path
    from unittest.mock import patch
    import aurel
    root = tempfile.TemporaryDirectory(); test.addCleanup(root.cleanup)
    for p in (patch.object(aurel, 'DIR', root.name), patch.object(aurel, 'pref', side_effect=lambda k, d: d)):
        p.start(); test.addCleanup(p.stop)
    return Path(root.name)


def run_swift(test, source, timeout=10):
    """Compile Swift source to a temp binary, run it, assert both succeed; returns its stdout."""
    import subprocess, sys
    from pathlib import Path
    if sys.platform != 'darwin': test.skipTest('needs macOS frameworks (Cocoa, AppKit)')
    with tempfile.TemporaryDirectory() as root:
        path, binary = Path(root) / 'test.swift', Path(root) / 'test'
        path.write_text(source)
        result = subprocess.run(['swiftc', str(path), '-o', str(binary)], capture_output=True, text=True)
        test.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=timeout)
        test.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout


def app_sources():
    """Package.swift's sources, in order: main.swift (Aurel.swift) first, then the native windows' files."""
    import re
    from pathlib import Path
    root = Path(__file__).resolve().parents[1]
    names = re.search(r'sources: \[([^\]]*)\]', (root / 'Package.swift').read_text()).group(1)
    return [root / n for n in re.findall(r'"([^"]+)"', names)]


def swiftc_with_ui(main, out, *flags):
    """swiftc arguments for a fixture `main` (top-level code) plus the native UI files a slice of Aurel.swift may use.
    The fixture is copied to main.swift beside it: Swift only runs top-level code from main.swift in a multi-file build."""
    import shutil
    from pathlib import Path
    main = Path(main)
    if main.name != 'main.swift':
        target = main.with_name('main.swift'); shutil.copy(main, target); main = target
    return ['swiftc', *flags, '-suppress-warnings', '-module-name', 'Aurel', str(main), *map(str, app_sources()[1:]), '-o', str(out)]


def app_swiftc(out, *flags):
    """swiftc arguments for the whole app as build.sh's swift build compiles it, minus Textual and SwiftUIMath."""
    return ['swiftc', *flags, '-suppress-warnings', '-module-name', 'Aurel', *map(str, app_sources()), '-o', str(out)]


def native_ui(test, source, *args, timeout=20):
    """Run Swift `source` against the native box, Settings and onboarding (`@testable import AurelUI` is added); returns stdout.
    The UI files build once into a cached library, so each check compiles in about a second. Nothing opens a window."""
    import hashlib, subprocess, sys
    from pathlib import Path
    if sys.platform != 'darwin': test.skipTest('needs macOS frameworks (AppKit, SwiftUI)')
    cache = Path.home() / '.cache' / 'aurel-tests'   # not under the temp folder, which the host guard keeps for windowed fixtures
    files = app_sources()[1:]
    lib = cache / hashlib.sha1(b''.join(f.read_bytes() for f in files)).hexdigest()[:16]
    def once(folder, build):   # built in a scratch folder, then renamed into place: two test runs never see a half-built one
        if folder.exists(): return
        cache.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=cache) as scratch:
            built = subprocess.run(build(Path(scratch)), capture_output=True, text=True)
            test.assertEqual(built.returncode, 0, built.stderr)
            try: os.rename(scratch, folder); os.mkdir(scratch)   # the context manager removes the empty stand-in
            except OSError: pass   # another run finished it first
    once(lib, lambda d: ['swiftc', '-emit-library', '-static', '-emit-module', '-enable-testing', '-suppress-warnings', '-module-name', 'AurelUI',
                         '-emit-module-path', str(d / 'AurelUI.swiftmodule'), '-o', str(d / 'libAurelUI.a'), *map(str, files)])
    source = '@testable import AurelUI\nimport AppKit\nimport SwiftUI\n' + source
    run = lib / hashlib.sha1(source.encode()).hexdigest()[:16]
    def check(d):
        (d / 'main.swift').write_text(source)
        return ['swiftc', '-suppress-warnings', '-I', str(lib), '-L', str(lib), '-lAurelUI', str(d / 'main.swift'), '-o', str(d / 'check')]
    once(run, check)
    result = subprocess.run([str(run / 'check'), *args], capture_output=True, text=True, timeout=timeout)
    test.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    return result.stdout


# Host guard: window/app-driving tests run only in the VM (run.sh sets AUREL_VM=1). On Saarth's Mac, launching a
# compiled fixture/harness, osascript, `open` or the Aurel binary skips the test instead of taking over his screen.
if not os.environ.get('AUREL_VM') and not os.environ.get('AUREL_ALLOW_HOST_UI'):
    import subprocess, unittest
    _popen_init = subprocess.Popen.__init__
    _tmp = os.path.realpath(tempfile.gettempdir())

    def _guarded(self, args, *a, **k):
        first = args if isinstance(args, (str, bytes, os.PathLike)) else (args[0] if args else '')
        exe = os.path.realpath(str(first).split()[0]) if first else ''
        name = os.path.basename(exe)
        if exe.startswith(_tmp) or name in ('osascript', 'open', 'Aurel', 'swift') or '/Aurel.app/' in exe:
            raise unittest.SkipTest(f'host guard: {name} runs only in the VM (run.sh)')
        _popen_init(self, args, *a, **k)
    subprocess.Popen.__init__ = _guarded


# The app runs one ask per process. A test's in-process aurel.main() left its ask folder, env and relay thread behind;
# the relay polls time.sleep until the folder goes, so a later test's fake clock or sleep mock counted its naps.
import shutil
import aurel
aurel.CLIENT_DEFAULT = 'claude'   # most tests drive the Claude client; tests/test_local.py covers Local, the app's default
_main = aurel.main


def _one_ask(*a, **k):
    env = dict(os.environ)
    try:
        return _main(*a, **k)
    finally:
        state = os.path.dirname(os.environ.get('AUREL_HANDS_STATE', ''))
        if os.environ.get('AUREL_HANDS_STATE') != env.get('AUREL_HANDS_STATE') and os.path.basename(state).startswith('aurel-hands-'):
            shutil.rmtree(state, True)
        os.environ.clear(); os.environ.update(env)
aurel.main = _one_ask
