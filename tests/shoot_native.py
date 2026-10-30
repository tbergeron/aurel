"""The native box, Settings and setup, picture by picture (opt-in, not discovered: run it by name, on a Mac with a screen).

AUREL_ALLOW_HOST_UI=1 python3 -m tests.shoot_native settings [scene-prefix]
→ test-artifacts/native/<surface>/native/<scene>-<look>.png. Where test-artifacts/native/<surface>/html/ holds the same scenes
as the HTML pages drew them (captured before they were deleted), a triptych per scene in diff/ and a pass/fail table.
"""
import base64
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NATIVE = ['NativeUI.swift', 'Orb.swift', 'Answer.swift', 'Settings.swift', 'Onboarding.swift', 'Box.swift']

# A filled-in Settings: what SettingsWindow sends on load.
PREFS = {'hotkeyLabel': '⌃⌥Space', 'login': True, 'paused': False, 'volume': .16, 'client': 'claude', 'model': 'haiku',
         'routing': 'balanced', 'microphone': 'automatic', 'agentModel': 'sonnet', 'agentUserTools': True, 'screen': 'auto',
         'speak': False, 'hideWhenSharing': True, 'menuIcon': True, 'autoUpdate': True, 'safe': True,
         'learnMe': True, 'stats': True, 'tips': True, 'draw': True, 'dictateMode': 'verbatim',
         'dictateHotkeyLabel': '', 'dictateHistory': True, 'input': 'voice', 'talkMode': 'hold', 'speechModel': 'speech',
         'improve': False}
STATE = {'today': {'asks': 3, 'usd': .004, 'secs': 3}, 'week': {'asks': 21, 'usd': .03, 'secs': 3.4}, 'all': {'asks': 140, 'usd': .2, 'secs': 3.8},
         'rules': ['When I say focus mode, close Slack and open Notes'], 'skills': [{'say': 'standup', 'reply': 'Opened Zoom and the standup notes'}],
         'me': {'facts': [{'id': 'f1', 'category': 'basics', 'kind': 'name', 'value': 'Sam', 'source': 'you', 'date': 'Oct 19'}]}, 'plan': {'ok': True, 'text': 'Signed in. Claude Max.'},
         'asks': [{'at': '2026-10-19 09:30:00', 'task': 'weather tomorrow', 'reply': 'Sunny, 68°F.'}, {'at': '2026-10-19 08:10:00', 'task': 'open my notes', 'reply': 'Opened Notes.'}]}
ROUTINES = [{'id': 'r1', 'kind': 'time', 'at': '08:00', 'days': 'weekdays', 'ask': 'Summarize my calendar', 'mode': 'cheapest'}]
DICTATION = {'words': ['Aurel', 'PostHog'], 'stats': {'today': 412, 'words': 18250, 'minutes': 96, 'sessions': 320},
             'history': [{'id': 'd1', 'timestamp': 1792425600, 'app': 'Notes', 'text': 'Pick up the desk lamp after school.'},
                         {'id': 'd2', 'timestamp': 1792422000, 'app': 'Messages', 'text': 'On my way, see you in ten.'}]}
TILE = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 30 30'%3E%3Crect width='30' height='30' rx='7' fill='%23COLOR'/%3E%3C/svg%3E"
APPS = [{'id': n, 'name': n, 'icon': TILE.replace('COLOR', c), 'suggested': True, 'status': st} for n, c, st in
        [('Notes', 'ffcc00', 'allowed'), ('Mail', '0a84ff', 'new'), ('Music', 'ff375f', 'blocked'), ('Calendar', 'ff453a', 'new')]]
PERMS = {'mic': True, 'speech': True, 'ax': True, 'screen': True, 'auto': True, 'chrome': False, 'calendar': True}

def icon():
    out = ROOT / 'test-artifacts' / 'native' / 'icon.png'
    if not out.exists():
        out.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['sips', '-s', 'format', 'png', '-z', '192', '192', str(ROOT / 'ui' / 'AppIcon.icns'), '--out', str(out)], check=True, capture_output=True)
    return 'data:image/png;base64,' + base64.b64encode(out.read_bytes()).decode()

LOAD = {'icon': icon(), 'prefs': PREFS, 'state': STATE, 'routines': ROUTINES, 'version': '1.6.0', 'mics': [{'uid': 'm1', 'name': 'MacBook Pro Microphone'}],
        'update': {}, 'managedUpdates': False, 'sharingUnavailable': True, 'hotkeyTaken': False, 'dictateHotkeyTaken': False, 'globeTaken': False}
def load(**prefs):
    return [['load', {**LOAD, 'prefs': {**PREFS, **prefs}}], ['state', STATE], ['perms', PERMS], ['dictation', DICTATION], ['motion', False]]

OB = [['prefs', {'draw': True, 'routing': 'balanced', 'hotkeyLabel': '⌃⌥Space', 'safe': True, 'dictateMode': 'verbatim', 'dictateHotkeyLabel': 'fn', 'globeTaken': False}],
      ['plan', {'ok': True, 'client': 'claude', 'text': 'Signed in. Claude Max.'}],
      ['set', {'mic': True, 'speech': True, 'ax': True, 'screen': False, 'auto': True, 'calendar': False, 'tools': True, 'chrome': False}], ['mode', False]]

ANSWER = ("Here is **what changed** in the plan:\n\n## Summary\n- First, the `build.sh` step now runs `swift build`\n- Then the app copies its resources\n1. Open [the docs](https://example.com)\n2. Read it\n\n"
          "The area is $A = \\pi r^2$ and the ratio is $\\frac{a}{b}$.\n\n$$\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$$\n\n| Item | Cost |\n|---|---|\n| Desk | $420 |\n| Chair | $180 |\n\n```\nswift build -c release\n```")
RESET = [['reset'], ['visible', True], ['mode', True], ['models', {'list': ['cheapest', 'balanced', 'capable'], 'pick': 'balanced'}], ['limit', 900]]
def ask(words): return RESET + [['listen', True], ['words', words], ['think']]
ROW = {'id': 'abcd1234', 'title': 'Standing desks', 'status': 'done', 'result': 'Found **3 desks** under $600:\n- Flexispot E7 · $499\n- Uplift V2 · $579\n- IKEA Bekant · $349',
       'made': [{'url': 'https://docs.google.com/spreadsheets/d/x', 'title': 'Desk comparison', 'type': 'spreadsheet'}, {'url': '/Users/me/Desktop/desks.md', 'title': ''}], 'cost': 0.042}

SCENES = {
    'box': [
        {'name': 'listening', 'calls': RESET + [['listen', False], ['words', 'What is the weather in Montreal tomorrow']], 'wait': 1.2},
        {'name': 'thinking', 'calls': ask('Find standing desks under 600') + [['line', '▸ Searching the web: standing desks'], ['line', '▸ Reading wirecutter.com'], ['line', '· Comparing prices']], 'wait': 1.2},
        {'name': 'answer', 'calls': ask('Explain the plan') + [['line', '✓ ' + ANSWER]], 'wait': 2.5},
        {'name': 'approval', 'calls': ask('Delete the old notes on my desktop') + [['ask', ['Delete this file?', 'rm ~/Desktop/old-notes.txt', '', '']]], 'wait': 1.2},
        {'name': 'retry', 'calls': ask('Open Figma') + [['ask', ['Couldn’t open Figma', 'It is not installed on this Mac.', 'retry', 'details']]], 'wait': 1.2},
        {'name': 'pick', 'calls': ask('Play my playlist') + [['pick', {'q': 'Which **playlist**?', 'options': [{'label': 'Lo-fi beats', 'sub': 'Spotify · 120 songs'}, {'label': 'Morning run', 'sub': 'Spotify · 40 songs'}, {'label': 'Focus', 'sub': 'Apple Music'}]}]], 'wait': 1.2},
        {'name': 'agent-done', 'calls': RESET + [['agentDone', ROW]], 'wait': 1.5},
        {'name': 'receipt', 'calls': ask('Remember I use Chrome') + [['line', '✓ Got it.'], ['line', '✎ ' + '[{"c":"preferences","label":"Preferences","t":"browser: Chrome","add":true}]'], ['line', 'i Say “remember…” to teach Aurel anything.']], 'wait': 1.5},
        {'name': 'rewrite', 'calls': ask('make this polite') + [['selected', 'hey can u send me the notes'], ['line', '✓ Hi! Could you send me the notes? Thank you.'], ['rewrite', ['Hi! Could you send me the notes? Thank you.', 'replace', True]]], 'wait': 1.5},
        {'name': 'stopped', 'calls': ask('Organize my desktop') + [['line', '▸ Moving files to Documents'], ['stopped', 'Stopped']], 'wait': 1.2},
        {'name': 'paused', 'calls': RESET + [['paused', True]], 'wait': 1.2},
        {'name': 'composer', 'calls': RESET + [['listen', True], ['words', 'Open Notes'], ['msg', 'Opened Notes.'], ['hover', True], ['agentCount', {'count': 2, 'attention': True}], ['mode', False]], 'wait': 1.2},
        {'name': 'dictate', 'calls': RESET + [['listen', 'dict'], ['level', 0.6], ['level', 0.3], ['level', 0.8]], 'wait': 1.0},
        {'name': 'dictated', 'calls': RESET + [['listen', 'dict'], ['dictated', {'text': 'Nothing to type into', 'words': 'pick up milk', 'history': True}]], 'wait': 1.0},
    ],
    'onboarding': [
{'name': 'welcome', 'calls': OB, 'wait': 2}] + [{'name': p, 'calls': [['_go', p]], 'wait': 3.2} for p in
                   ['perms', 'agents', 'try', 'mac', 'text', 'dictate', 'point', 'work', 'improve', 'done']] + [
                  {'name': 'perms-sheet', 'calls': [['_go', 'perms'], ['_sheet']], 'wait': 1.5}],
    'settings': [
        {'name': 'general', 'calls': load() + [['tab', 'general']]},
        {'name': 'general-end', 'calls': [['_end']]},
        {'name': 'general-type', 'calls': load(input='type') + [['tab', 'general']]},
        {'name': 'dictation', 'calls': load(dictateHotkeyLabel='fn') + [['tab', 'dictation']]},
        {'name': 'dictation-end', 'calls': [['_end']]},
        {'name': 'dictation-parakeet', 'calls': load(speechModel='parakeet') + [['tab', 'dictation'], ['parakeet', {'models': [{'id': 'v3', 'state': 'ready'}]}]]},
        {'name': 'brain', 'calls': load() + [['tab', 'brain']]},
        {'name': 'brain-local', 'calls': load(client='local') + [['tab', 'brain']]},
        {'name': 'memory', 'calls': load() + [['tab', 'memory'], ['_open', 0]]},
        {'name': 'memory-end', 'calls': [['_end']]},
        {'name': 'account', 'calls': load() + [['tab', 'account']]},
        {'name': 'account-end', 'calls': [['_end']]},
        {'name': 'apps', 'calls': load() + [['tab', 'apps'], ['apps', APPS]]},
        {'name': 'about', 'calls': load() + [['tab', 'about']]},
        {'name': 'toast', 'calls': load() + [['tab', 'general'], ['notice', {'text': 'Forgot that rule', 'undo': True}]]},
    ],
}


def build():
    out = ROOT / 'test-artifacts' / 'native'; out.mkdir(parents=True, exist_ok=True)
    main = out / 'main.swift'; main.write_text((ROOT / 'tests' / 'shoot_native.swift').read_text())   # top-level code must live in main.swift
    srcs = [str(main)] + [str(ROOT / f) for f in NATIVE if (ROOT / f).exists()]
    subprocess.run(['swiftc', '-O', '-suppress-warnings', '-o', str(out / 'shoot')] + srcs, check=True)
    subprocess.run(['swiftc', '-O', '-o', str(out / 'imgdiff'), str(ROOT / 'tests' / 'imgdiff.swift')], check=True)
    return out


def main():
    surface = sys.argv[1]
    prefix = sys.argv[2] if len(sys.argv) > 2 else ''
    out = build()
    scenes = [s for s in SCENES[surface] if s['name'].startswith(prefix)]
    for look in ['light', 'dark'] if surface != 'box' else ['dark']:
        path = out / f'{surface}-{look}.json'; path.write_text(json.dumps([{**s, 'name': f"{s['name']}-{look}"} for s in scenes]))
        d = out / surface / 'native'; d.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(out / 'shoot'), surface, str(path), str(d), look], check=True, timeout=600)
    if (out / surface / 'html').is_dir():
        sys.exit(subprocess.run([str(out / 'imgdiff'), str(out / surface / 'html'), str(out / surface / 'native'), str(out / surface / 'diff')]).returncode)


if __name__ == '__main__':
    main()
