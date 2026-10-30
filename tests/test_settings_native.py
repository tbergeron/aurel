"""The native Settings model (Settings.swift) with a recording post: no app, window or user settings."""
import contextlib
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

from tests import native_ui

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = (ROOT / 'Settings.swift').read_text()


def between(source, start, end):
    i = source.index(start)
    return source[i:source.index(end, i)]


def view(name):   # one type's source, up to its closing brace
    return between(SETTINGS, f'struct {name}:', '\n}\n')


# The views compute what they show in their bodies; these run those exact lines against the model.
MODEL_STATUS = 'func modelStatus(_ m: SettingsModel, _ parakeet: Bool) -> [String] {\n' \
    + between(view('ModelStatus'), '        let s = parakeet ? m.W : m.L', '        Row { _ in') \
    + '    return [text, btn, size.map { "Download \\($0)" } ?? "Download"]\n}\n'
KEY_FIELD = 'func keyField(_ m: SettingsModel) -> [String] {\n' \
    + between(view('KeyField'), '        let rec = m.recording == "dictate"', '        ZStack(alignment: .trailing) {') \
    + '    return [label.isEmpty ? text : capsOf(label).joined(), set ? "set" : "", bad ? "bad" : ""]\n}\n'
HISTORY = between(SETTINGS, 'private let askDate', '\n').replace('private ', '', 1) + '\n' \
    + 'func historyRows(_ m: SettingsModel) -> [[String: Any]] {\n' \
    + between(view('History'), '        let q = m.search.lowercased()', '        ScrollView(.vertical) {') + '    return rows\n}\n'
ROUTINE_TITLE = between(view('Routines'), '    func routineTitle(', '\n    }') + '\n    }\n'
SETUP = r'''
var posts: [[String: Any]] = []
let m = SettingsModel(); m.post = { posts.append($0) }
func spin(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func done(_ result: Any) { print(String(data: try! JSONSerialization.data(withJSONObject: ["result": result, "posts": posts]), encoding: .utf8)!) }
func line(_ hint: (String, String)?, _ fallback: String, _ taken: Bool) -> [String] { let l = hint ?? (fallback, taken ? "taken" : ""); return [l.0, l.1] }   // the views' `m.schint ?? (…)`
m.receive("load", ["prefs": ["hotkeyLabel": "⌃⌥Space", "volume": 0.16, "meeting": true]] as [String: Any])
let use: [String: Any] = ["asks": 0, "usd": 0, "secs": 0]
let base: [String: Any] = ["today": use, "week": use, "all": use, "rules": ["Keep it short"], "skills": [["say": "focus mode", "reply": "Done"]],
    "me": ["facts": [["id": "f1", "category": "basics", "kind": "name", "value": "Sam", "source": "you", "date": ""]]], "plan": ["ok": true, "text": "Ready"]]
m.receive("state", base)
'''


class SettingsNativeTests(unittest.TestCase):
    def page(self, script, *helpers):
        out = native_ui(self, ''.join(helpers) + SETUP + script)
        return json.loads(out.strip().splitlines()[-1])

    def test_wake_word_defaults_off_and_saves_one_toggle(self):
        out = self.page('''let before = m.bool("wakeWord"); m.set("wakeWord", !m.bool("wakeWord"))
            m.receive("load", ["prefs": ["hotkeyLabel": "⌃⌥Space", "wakeWord": false]] as [String: Any])
            done([before, m.bool("wakeWord")])''')
        self.assertEqual(out['result'], [False, False])
        self.assertEqual(out['posts'], [{'do': 'set', 'k': 'wakeWord', 'v': True}])
        self.assertIn('Switch(on: m.bool("wakeWord")) { m.set("wakeWord", !m.bool("wakeWord")) }', SETTINGS)
        talk = between(view('GeneralSection'), 'Title(b: "Shortcut opens")', 'H3(s: "Aurel")')
        self.assertIn('talkMode', talk)
        self.assertIn('wakeWord', talk.split('Row {')[-1])   # the last row of the talk group

    def test_every_voice_setting_is_drawn_and_saves_itself(self):
        sys.path.insert(0, str(ROOT)); import aurel   # aurel.py --set changes these by their Settings labels
        for k, label in aurel.switches().items():
            with self.subTest(switch=k):
                self.assertIn(f'Title(b: "{label}"', SETTINGS)
                self.assertIn(f'Switch(on: m.bool("{k}")) {{ m.set("{k}", !m.bool("{k}")) }}', SETTINGS)
        for k, (label, options) in aurel.picks().items():
            with self.subTest(pick=k):
                self.assertIn(f'Title(b: "{label}"', SETTINGS)
                self.assertIn('Seg(options: [' + ', '.join(f'("{v}", "{o}")' for o, v in options.items()) + ']', SETTINGS)
                self.assertIn(f'{{ m.set("{k}", $0) }}', SETTINGS)

    def test_sharing_compatibility_notice_preserves_saved_choice(self):
        out = self.page('''m.receive("load", ["prefs": ["hideWhenSharing": true], "sharingUnavailable": true] as [String: Any])
            let before = [m.sharingUnavailable, m.bool("hideWhenSharing")]
            m.receive("load", ["prefs": ["hideWhenSharing": false], "sharingUnavailable": false] as [String: Any])
            done([before, [m.sharingUnavailable, m.bool("hideWhenSharing")]])''')
        self.assertEqual(out['result'], [[True, True], [False, False]])
        self.assertEqual(out['posts'], [])   # a reload never saves
        self.assertIn('span: m.sharingUnavailable ? "On this macOS version, Aurel windows can appear in screen sharing." : nil', SETTINGS)

    def test_row_lines_stay_short(self):
        lines = re.findall(r'span: "([^"]+)"', SETTINGS)
        self.assertGreater(len(lines), 25)   # a floor: the pattern still finds the rows (some pick their line in code)
        self.assertEqual([t for t in lines if len(t.split()) > 14], [])   # rare detail goes in an info tip
        self.assertIn('.help(info)', view('Hint'))
        self.assertIn('span: "Risky actions need approval. Background agents use a scratch folder."', SETTINGS)

    def test_parakeet_rows_follow_the_speech_model_and_report_status(self):
        out = self.page('''
            func W(_ over: [String: Any], _ models: [[String: Any]]? = nil) -> [String: Any] {
                var w: [String: Any] = ["server": true, "model": "v3", "running": false, "models": models ?? [["id": "v3", "name": "Multilingual", "size": "469 MB", "have": false],
                    ["id": "v2", "name": "English", "size": "451 MB", "have": true]]]
                w.merge(over) { $1 }; return w
            }
            m.set("speechModel", "parakeet")
            var states: [[String]] = [modelStatus(m, true)]
            m.receive("parakeet", W(["server": false])); states.append(modelStatus(m, true))
            m.receive("parakeet", W([:])); states.append(modelStatus(m, true))
            m.receive("parakeet", W([:], [["id": "v3", "name": "Multilingual", "size": "469 MB", "have": false, "progress": 0.42]])); states.append(modelStatus(m, true))
            m.set("parakeetModel", "v2"); m.receive("parakeet", W([:])); states.append(modelStatus(m, true))
            m.set("parakeetModel", "v3"); m.receive("parakeet", W(["error": "Download failed. Check your connection and try again."])); states.append(modelStatus(m, true))
            done(states)''', MODEL_STATUS)
        self.assertEqual([s[:2] for s in out['result']], [
            ['Checking…', ''], ['The Parakeet helper is missing. Run ./build.sh again.', ''], ['Model not downloaded.', 'download'], ['Downloading 42%…', 'cancel'],
            ['Ready. Runs on this Mac.', 'delete'], ['Download failed. Check your connection and try again.', 'download']])
        self.assertEqual(out['result'][2][2], 'Download 469 MB')
        speech = between(view('DictationSection'), 'Title(b: "Speech model"', 'H3(s: "Dictionary")')
        self.assertIn('if m.str("speechModel") == "parakeet" {', speech)   # its rows show only for Parakeet
        self.assertIn('ModelStatus(m: m, title: "Parakeet status", parakeet: true)', speech.split('if m.str("speechModel") == "parakeet" {')[1])
        for action in ('Download', 'Cancel', 'Delete'):
            self.assertIn(f'm.post(["do": prefix + "{action}", "id": id])', view('ModelStatus'))

    def test_notice_shows_and_its_action_runs_once(self):
        out = self.page('''m.receive("notice", ["text": "Couldn’t save that change, so the old setting is back."])
            let shown = m.notice?.text == "Couldn’t save that change, so the old setting is back." && m.notice?.action == nil
            var ran = 0; m.showNotice("Rule forgotten.", "Undo") { ran += 1 }
            m.notice?.run?(); m.showNotice("")   // the Notice button
            done([shown, ran, m.notice == nil])''')
        self.assertEqual(out['result'], [True, 1, True])
        self.assertIn('Btn(label: a) { n.run?(); m.showNotice("") }', view('Notice'))

    def test_dictation_stays_off_until_its_shortcut_is_recorded(self):
        out = self.page('''let before = keyField(m)
            m.set("dictateMode", "cleanup")
            m.toggleRecordDictate(); let typing = keyField(m)
            m.receive("rec", "⌃⌥"); let held = keyField(m)
            m.receive("load", ["prefs": ["hotkeyLabel": "⌃⌥Space", "dictateHotkeyLabel": "⌃⌥D"]] as [String: Any])
            done([before, typing, held, keyField(m), [m.recording]])''', KEY_FIELD)
        self.assertEqual(out['result'], [['Record Shortcut', '', ''], ['Type Shortcut', '', ''], ['⌃⌥', '', ''], ['⌃⌥D', 'set', ''], ['']])
        self.assertIn({'do': 'set', 'k': 'dictateMode', 'v': 'cleanup'}, out['posts'])
        self.assertIn({'do': 'recordDictate'}, out['posts'])
        dictate = view('DictationSection')
        self.assertIn('Row(dim: m.str("dictateHotkeyLabel").isEmpty) { _ in Title(b: "Dictated text"', dictate)   # greyed until there is a shortcut
        self.assertIn('if set { XButton { m.post(["do": "clearDictate"]) }', view('KeyField'))

    def test_a_recorded_shortcut_puts_back_its_hint(self):
        # Aurel.swift's done() answers a recording with load (push): the "Press a key combo…" line must go, as the page's paint() did.
        out = self.page('''m.toggleRecordDictate(); m.receive("load", ["prefs": ["hotkeyLabel": "⌃⌥Space", "dictateHotkeyLabel": "⌃⌥D"]] as [String: Any])
            let dictate = line(m.dictatehint, m.dictateHint, m.dictateHotkeyTaken)
            m.toggleRecord(); m.receive("load", ["prefs": ["hotkeyLabel": "⌘⇧A"]] as [String: Any])
            done([dictate, line(m.schint, m.shortcutHint, m.hotkeyTaken)])''')
        self.assertIn('let line = m.dictatehint ?? (m.dictateHint, m.dictateHotkeyTaken ? "taken" : "")', view('DictationSection'))   # what line() mirrors
        self.assertIn('let line = m.schint ?? (m.shortcutHint, m.hotkeyTaken ? "taken" : "")', view('ShortcutCard'))
        self.assertEqual(out['result'], [['Hold to talk. Double-tap to lock.', ''], ['Hold it, talk, let go.', '']])

    def test_globe_key_fix_shows_only_while_macos_takes_fn(self):
        out = self.page('''m.receive("load", ["prefs": ["hotkeyLabel": "⌃⌥Space", "dictateHotkeyLabel": "fn"], "globeTaken": true] as [String: Any])
            let shown = [m.globe ? "shown" : "", m.dictateHint]; m.receive("globe", false)
            done([shown, [m.globe ? "shown" : ""]])''')
        self.assertEqual(out['result'], [['shown', 'Hold to talk. Double-tap to lock.'], ['']])
        self.assertIn('if m.globe { Row { _ in Title(b: "Set Press 🌐 key to Do Nothing"); Btn(label: "Open Keyboard Settings") { m.post(["do": "globeKey"]) } } }', SETTINGS)

    def test_dictation_clash_warns_in_its_row_then_settles(self):
        out = self.page('''m.receive("load", ["prefs": ["hotkeyLabel": "⌃⌥Space", "dictateHotkeyLabel": "⌃⌥D"], "dictateHotkeyTaken": true] as [String: Any])
            let taken = line(m.dictatehint, m.dictateHint, m.dictateHotkeyTaken) + [keyField(m)[2]]
            m.toggleRecordDictate(); m.receive("taken", ["dictate", true] as [Any])
            m.receive("load", ["prefs": ["hotkeyLabel": "⌃⌥Space", "dictateHotkeyLabel": "⌃⌥D"]] as [String: Any])
            let own = line(m.dictatehint, m.dictateHint, m.dictateHotkeyTaken) + [m.schint?.1 ?? ""]
            spin(4.2)
            done([taken, own, line(m.dictatehint, m.dictateHint, m.dictateHotkeyTaken)])''', KEY_FIELD)
        taken, own, settled = out['result']
        self.assertEqual(taken[1:], ['taken', 'bad'])
        self.assertIn('Another app uses this shortcut', taken[0])
        self.assertEqual(own, ['That’s already your Aurel shortcut. Kept your old one.', 'warn', ''])
        self.assertEqual(settled, ['Hold to talk. Double-tap to lock.', ''])
        self.assertIn('spanColor: line.1.isEmpty ? nil : th.warn', view('DictationSection'))

    def test_sections_open_at_top_and_apps_opens_under_account(self):
        out = self.page('''var scrolls: [String] = []; m.scroll = { scrolls.append($0) }
            m.openSection("brain"); m.openSection("account"); m.openSection("brain"); m.openSection("apps")
            done([scrolls, [m.section, m.navOn]])''')
        self.assertEqual(out['result'], [['top'] * 4, ['apps', 'account']])
        self.assertEqual(out['posts'], [{'do': 'apps'}])   # a fresh list each visit
        self.assertIn('Btn(label: "← Privacy & Safety") { m.openSection("account") }', view('AppsSection'))

    def test_nix_install_shows_its_real_update_path(self):
        out = self.page('''m.receive("load", ["prefs": ["hotkeyLabel": "⌃⌥Space"], "managedUpdates": true, "update": "Run nix profile upgrade or nix run again.", "version": "1.3.3 · Nix"] as [String: Any])
            done([m.managedUpdates ? "managed" : "", m.update, m.version])''')
        self.assertEqual(out['result'], ['managed', 'Run nix profile upgrade or nix run again.', 'Version 1.3.3 · Nix'])
        about = view('AboutSection')
        self.assertIn('if !m.managedUpdates { Row(first: true) { _ in Title(b: "Update automatically"', about)
        self.assertIn('Title(b: m.managedUpdates ? "Updates are managed by Nix" : "Check for updates", span: m.update)', about)
        self.assertIn('if !m.managedUpdates { Btn(label: "Check Now")', about)

    def test_retired_settings_are_hidden_and_keep_saved_values(self):
        sys.path.insert(0, str(ROOT)); import aurel
        source = (ROOT / 'Aurel.swift').read_text()
        retired = re.findall(r'"(\w+)"', source[source.index('static let retiredKeys'):source.index(']', source.index('static let retiredKeys'))])
        self.assertIn('workIn', retired)
        defaults = source[source.index('static let defaults'):source.index('static let retiredKeys')]
        self.assertIn('"quietAudio": false', defaults)
        self.assertNotIn('retiredKeys.filter', source)
        for key in retired:
            with self.subTest(key=key):
                self.assertIn(f'"{key}":', defaults)   # new users still receive a value
                self.assertNotIn(f'm.set("{key}"', SETTINGS)
                self.assertNotIn(f'm.bool("{key}")', SETTINGS)
                self.assertNotIn(key, aurel.switches())
                self.assertNotIn(key, aurel.picks())
        self.assertEqual(len(re.findall(r'NavItem\(id: "\w+"', between(SETTINGS, 'let navItems = [', '\n]'))), 6)   # 6 pages

    def test_pages_wear_their_sidebar_color_and_row_actions_show_on_hover(self):
        colors = re.findall(r'color: (0x\w+)', between(SETTINGS, 'let navItems = [', '\n]'))
        self.assertEqual(len(set(colors)), len(colors))
        for i, name in enumerate(('GeneralSection', 'DictationSection', 'BrainSection', 'MemorySection', 'AccountSection')):
            self.assertIn(f'icon: navItems[{i}])', view(name))
        self.assertIn('if let icon { Tile(item: icon', view('H1'))
        self.assertNotIn('navItems[5]', SETTINGS)   # About has its own big icon
        self.assertIn('Group { if let i = m.icon { Image(nsImage: i).resizable() } else { Color.clear } }.frame(width: 96, height: 96)', view('AboutSection'))
        self.assertIn('.opacity(shown || save ? 1 : 0)', view('RowX'))   # quiet until the row is hovered
        self.assertIn('RowX(icon: RowIcon.trash, shown: hovered)', view('RuleRow'))
        self.assertIn('m.post(["do": "quit"])', view('GeneralSection'))
        self.assertNotIn('"quit"', view('AccountSection'))

    def test_long_asks_always_move_so_there_is_no_choice(self):
        sys.path.insert(0, str(ROOT)); import aurel
        for gone in ('agentsAuto', 'longAsks'):
            self.assertNotIn(gone, SETTINGS)
            self.assertNotIn(gone, (ROOT / 'ui/settings.json').read_text())
            self.assertNotIn(gone, aurel.switches())
            self.assertNotIn(gone, aurel.picks())
        self.assertEqual(aurel.picks()['dictateMode'][1], {'Verbatim': 'verbatim', 'Clean up': 'cleanup'})

    def test_scheduled_routines_list_and_remove(self):
        out = self.page('''m.receive("load", ["prefs": ["hotkeyLabel": "⌃⌥Space"], "routines": [
                ["id": "weekday", "kind": "time", "at": "08:00", "days": "weekdays", "ask": "Summarize my calendar"],
                ["id": "hourly", "kind": "interval", "every": 3600, "ask": "Check the fixture"],
                ["id": "half", "kind": "interval", "every": 1800, "ask": "Stretch"],
                ["id": "evening", "kind": "time", "at": "18:05", "ask": "Wrap up"]]] as [String: Any])
            done((m.P["routines"] as! [[String: Any]]).map(routineTitle))''', ROUTINE_TITLE)
        self.assertEqual(out['result'], ['Weekdays at 8:00 AM', 'Every hour', 'Every 30 minutes', 'Every day at 6:05 PM'])
        self.assertIn('RowX(icon: RowIcon.trash, shown: hovered) { m.post(["do": "routineRemove", "id": r["id"] ?? ""]) }', view('Routines'))

    def test_single_deletes_wait_for_undo(self):
        out = self.page('''m.undoable(["do": "forget", "line": m.rules[0]], key: "rule-0", "Rule forgotten.")   // RuleRow's trash
            let hidden = m.hiddenRows.contains("rule-0")
            m.notice?.run?(); m.showNotice(""); let back = !m.hiddenRows.contains("rule-0")
            m.undoable(["do": "me", "action": "drop", "id": "f1"], key: "fact-f1", "Detail deleted.")
            m.undoable(["do": "unlearn", "say": "focus mode"], key: "skill-0", "Command forgotten.")   // a second delete sends the first
            let closing = m.flush(send: false) ?? [:]   // the window is closing: SettingsWindow runs it
            done([[hidden, back], closing])''')
        (hidden, back), closing = out['result']
        self.assertTrue(hidden and back)
        self.assertEqual(closing, {'do': 'unlearn', 'say': 'focus mode'})
        self.assertEqual(out['posts'], [{'do': 'me', 'action': 'drop', 'id': 'f1'}])
        self.assertIn('m.undoable(["do": "forget", "line": old], key: "rule-\\(index)", "Rule forgotten.")', view('RuleRow'))
        self.assertIn('m.undoable(["do": "me", "action": "drop", "id": id], key: "fact-\\(id)", "Detail deleted.")', view('FactRow'))
        self.assertIn('m.undoable(["do": "unlearn", "say": k["say"] ?? ""], key: key, "Command forgotten.")', view('MemorySection'))
        self.assertIn('if let b = model?.flush(send: false) { handle(b) }', (ROOT / 'Aurel.swift').read_text())

    def test_profile_deletes_flush_when_the_notice_goes(self):
        out = self.page('''let closed = m.openProfile.isEmpty
            m.undoable(["do": "me", "action": "drop", "id": "f1"], key: "fact-f1", "Detail deleted."); let waiting = posts.isEmpty
            m.receive("notice", ["text": ""])
            done([closed, waiting])''')
        self.assertEqual(out['result'], [True, True])   # categories start compact; the delete waits out Undo
        self.assertEqual(out['posts'], [{'do': 'me', 'action': 'drop', 'id': 'f1'}])
        self.assertIn('Text("\\(fact["source"] as? String ?? "") · \\(fact["date"] as? String ?? "")")', view('FactRow'))
        self.assertIn('m.post(["do": "me", "action": "set", "id": id, "text": t])', view('FactRow'))
        self.assertIn('m.post(["do": "me", "action": "add", "category": cat.0, "text": t])', view('ProfileCategory'))
        self.assertIn('m.post(v.isEmpty ? ["do": "forget", "line": old] : ["do": "rule", "old": old, "text": v])', view('RuleRow'))   # emptied = forgotten

    def test_memory_reveal_opens_the_category_and_glows_the_item(self):
        out = self.page('''var scrolls: [String] = []; m.scroll = { scrolls.append($0) }
            var s = base; s["rules"] = ["Use Chrome for browsing"]
            s["me"] = ["facts": [["id": "dad1", "category": "people", "kind": "dad email", "value": "pat@example.test", "source": "learned", "date": "2026-10-13"]]]
            m.receive("state", s); m.receive("reveal", ["c": "people", "t": "dad email: pat@example.test"]); spin()
            let fact = [m.openProfile.contains("people") ? "open" : "", m.flash ?? ""]
            m.receive("reveal", ["c": "rules", "t": "Something already forgotten"]); spin()
            done([fact, [m.flash ?? ""], scrolls])''')
        self.assertEqual(out['result'], [['open', 'fact-dad1'], ['rules'], ['fact-dad1', 'rules']])

    def test_import_turns_into_refresh_and_reports_each_source(self):
        out = self.page('''m.profileBusy = true
            m.receive("profileImport", ["counts": ["contacts": 1, "mail": 2], "errors": [String]()] as [String: Any])
            var s = base; s["me"] = ["facts": [["id": "c1", "category": "contact", "kind": "email", "value": "a@b.test", "source": "contacts", "date": ""]]]
            m.receive("state", s)
            done([m.profileBusy ? "busy" : "", m.profileStatus, "\\(m.sourceCounts["contacts"] ?? 0)"])''')
        busy, status, contacts = out['result']
        self.assertEqual((busy, contacts), ('', '1'))
        self.assertIn('2 from Mail', status)
        memory = view('MemorySection')
        self.assertIn('Btn(label: imported > 0 ? "Refresh" : "Import from your Mac", kind: "blue", disabled: m.profileBusy)', memory)
        self.assertIn('m.profileBusy = true; m.profileStatus = "Importing from Contacts and Mail…"; m.profileStatusFix = nil; m.post(["do": "profileImport"])', memory)
        self.assertIn('m.post(["do": "me", "action": "forget-source", "source": s])', memory)

    def test_intelligence_offers_three_modes_and_cheapest_needs_no_work_model(self):
        out = self.page('''var modes: [String] = []
            for p in [["routing": "balanced"], ["model": "opus"], ["model": "haiku", "escalate": false], ["model": "haiku"]] as [[String: Any]] {
                m.receive("load", ["prefs": p] as [String: Any]); modes.append(m.routing)
            }
            done(modes)''')
        self.assertEqual(out['result'], ['balanced', 'capable', 'cheapest', 'balanced'])   # older settings pick their mode
        brain = view('BrainSection')
        self.assertIn('Seg(options: [("cheapest", "Cheapest"), ("balanced", "Balanced"), ("capable", "Most capable")], value: m.routing) { m.set("routing", $0) }', brain)
        self.assertIn('if m.routing != "cheapest" {', brain)
        self.assertIn('value: m.str("model") == "haiku" ? (m.str("agentModel") == "opus" ? "opus" : "sonnet") : m.str("model")', brain)

    def test_local_client_explains_itself_and_hides_claude_models(self):
        out = self.page('''m.receive("load", ["prefs": ["hotkeyLabel": "⌃⌥Space"]] as [String: Any]); let fresh = m.local
            m.receive("load", ["prefs": ["client": "claude"]] as [String: Any]); done([fresh, m.local])''')
        self.assertEqual(out['result'], [True, False])   # Local is the default client
        brain = view('BrainSection')
        self.assertIn('Lede(s: local ? "Aurel thinks with a model that runs on this Mac. Nothing leaves it."', brain)
        self.assertIn('span: local ? "Free, private, works offline."', brain)
        local, claude = brain.split('if local {', 1)[1].split('} else {', 1)
        self.assertNotIn('"model"', local)   # no Claude routing or work model for Local
        self.assertIn('"routing"', claude.split('if !local {')[0])
        self.assertIn('if !local {\n                H3(s: "Background agents")', brain)
        self.assertIn('T(s: m.local ? "Local model" : "Claude", weight: 500)', view('AccountSection'))
        self.assertIn('approval', between(view('AccountSection'), 'Title(b: "Safe mode"', '\n'))

    def test_microphone_picker_starts_recommended_and_falls_back(self):
        out = self.page('''m.receive("mics", [["uid": "built-in-fixture", "name": "MacBook Microphone"], ["uid": "usb-fixture", "name": "Studio Mic"]])
            let listed = m.mics.map { $0.id }, start = m.str("microphone"); m.set("microphone", "usb-fixture")
            done([listed, [start]])''')
        self.assertEqual(out['result'], [['built-in-fixture', 'usb-fixture'], ['automatic']])
        self.assertIn({'do': 'set', 'k': 'microphone', 'v': 'usb-fixture'}, out['posts'])   # by UID
        mic = between(view('DictationSection'), 'Title(b: "Microphone")', 'Row {')
        self.assertIn('[("automatic", "Automatic (recommended)")] + m.mics.map', mic)
        self.assertIn('value: opts.contains { $0.0 == m.str("microphone") } ? m.str("microphone") : "automatic"', mic)   # unplugged: Automatic

    def test_talk_mode_and_input_explain_the_shortcut(self):
        out = self.page('''let first = [m.str("talkMode"), m.shortcutHint, m.bool("speak") ? "speak" : ""]
            m.set("talkMode", "toggle"); let toggle = m.shortcutHint
            m.receive("load", ["prefs": ["input": "type", "talkMode": "toggle"]] as [String: Any])
            done([first, [toggle, m.shortcutHint]])''')
        self.assertEqual(out['result'], [['hold', 'Hold it, talk, let go.', ''], ['Press to listen. Press again to send.', 'Press to type. Return sends.']])
        general = view('GeneralSection')
        self.assertIn('if m.str("input") != "type" {', general)   # typing has no hold or toggle
        self.assertIn('span: m.str("talkMode") == "toggle" ? "Pauses keep listening." : "Esc cancels."', general)

    def test_recording_has_a_cancel_and_switching_sections_cancels_it(self):
        out = self.page('''m.toggleRecord(); let rec = [m.recording, m.recCaps?.hint ?? ""]
            m.toggleRecord(); let cancelled = m.recording
            m.toggleRecord(); m.openSection("brain")
            done([rec, [cancelled, m.recording]])''')
        self.assertEqual(out['result'], [['main', 'Recording — press your shortcut'], ['', '']])
        self.assertEqual([p['do'] for p in out['posts']], ['record', 'cancelRecord', 'record', 'cancelRecord'])
        self.assertIn('Btn(label: rec ? "Cancel Recording" : "Change Shortcut", kind: "blue") { m.toggleRecord() }', view('ShortcutCard'))
        self.assertIn('let caps = rec ? capsOf(m.recCaps?.label ?? "") : capsOf(m.str("hotkeyLabel"))', view('ShortcutCard'))   # cancel shows the old keys again

    def test_clicking_away_cancels_recording(self):
        # The hint says "Esc or click away cancels." The page cancelled on any click outside the two shortcut fields.
        self.assertIn('Esc or click away cancels.', SETTINGS)
        native_ui(self, r'''
let m = SettingsModel(); var posts: [[String: Any]] = []; m.post = { posts.append($0) }
m.recFields = ["main": CGRect(x: 240, y: 100, width: 500, height: 180), "dictate": CGRect(x: 560, y: 400, width: 140, height: 28)]
m.toggleRecord(); m.clicked(CGPoint(x: 300, y: 150)); precondition(m.recording == "main", "a click in the field cancelled")
m.clicked(CGPoint(x: 100, y: 150)); precondition(m.recording.isEmpty && posts.last?["do"] as? String == "cancelRecord", "a click away kept recording")
m.toggleRecordDictate(); m.clicked(CGPoint(x: 600, y: 410)); precondition(m.recording == "dictate")
m.clicked(CGPoint(x: 600, y: 300)); precondition(m.recording.isEmpty)
''')
        self.assertIn('.simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("prefs")).onEnded { m.clicked($0.location) })', view('SettingsView'))

    def test_agents_rows_show_live_status_and_enable_all_marks_its_step(self):
        out = self.page('''m.receive("perms", ["mic": true, "speech": true, "ax": true, "screen": true, "auto": true, "chrome": false, "calendar": false])
            m.receive("connectors", ["connected": ["Gmail", "Google Drive"], "signin": ["Notion"]] as [String: Any])
            m.receive("walk", "calendar")
            done([m.perms["calendar"] == false && m.perms["auto"] == true, m.connText, m.connected, m.walking ?? ""])''')
        self.assertEqual(out['result'], [True, 'Gmail, Google Drive connected · 1 need sign-in', True, 'calendar'])
        self.assertIn('m.post(["do": "enableAll", "connected": String(m.connected)])', view('AccountSection'))
        perm = view('PermRow')
        self.assertIn('Row(first: first, now: m.walking == id)', perm)
        self.assertIn('if m.perms[id] ?? false { Pill(s: okLabel, kind: "ok") } else { Btn(label: button) { m.post(["do": "grant", "id": id]) }', perm)

    def test_every_control_has_an_accessible_name(self):
        # The page named every switch, choice and slider for VoiceOver (aria-label from its row). The native Switch and Seg are tap-only shapes.
        for name in ('Switch', 'SegButton'):
            with self.subTest(control=name):
                self.assertTrue('.accessibility' in view(name), f'{name} has no accessibility label, value or traits')

    def test_import_failure_offers_the_settings_that_fix_it(self):
        out = self.page('''m.receive("profileImport", ["errors": ["mail"], "errorReasons": ["mail": "automation"], "counts": ["contacts": 3]] as [String: Any])
            let one = [m.profileStatus, m.profileStatusFix ?? ""]
            m.receive("profileImport", ["errors": ["contacts", "mail"], "errorReasons": ["contacts": "automation", "mail": "automation"], "counts": [String: Int]()] as [String: Any])
            done([one, [m.profileStatus, m.profileStatusFix ?? ""]])''')
        (one, fix), (_, both) = out['result']
        self.assertIn('3 from Contacts', one); self.assertEqual(fix, 'Allow Mail in Automation')
        self.assertEqual(both, 'Allow Contacts and Mail in Automation')
        self.assertIn('if let fix = m.profileStatusFix { Btn(label: fix) { m.post(["do": "automation"]) }', view('MemorySection'))

    def test_import_read_failure_offers_retry_without_false_permission_action(self):
        out = self.page('''m.receive("profileImport", ["errors": ["contacts", "mail"], "errorReasons": ["contacts": "read", "mail": "automation"], "counts": [String: Int]()] as [String: Any])
            let mixed = [m.profileStatus, m.profileStatusFix ?? ""]
            m.receive("profileImport", ["errors": ["mail"], "errorReasons": ["mail": "read"], "counts": ["contacts": 2]] as [String: Any])
            done([mixed, [m.profileStatus, m.profileStatusFix ?? ""]])''')
        (status, fix), (retry, none) = out['result']
        self.assertEqual(fix, 'Allow Mail in Automation')
        self.assertIn('Try importing again', status)
        self.assertIn('Try importing again', retry)
        self.assertEqual(none, '')

    def test_history_lists_searches_and_copies_answers(self):
        out = self.page('''var s = base; s["asks"] = [["at": "2026-10-15 09:30:00", "task": "weather", "reply": "Sunny"], ["at": "2026-10-14 08:00:00", "task": "open notes", "reply": "Opened Notes"]]
            m.receive("state", s); let all = historyRows(m).map { $0["text"] as? String ?? "" }
            m.search = "notes"; done([all, historyRows(m).map { $0["reply"] as? String ?? "" }])''', HISTORY)
        self.assertEqual(out['result'], [['weather', 'open notes'], ['Opened Notes']])   # newest first; search finds the answer too
        self.assertIn('m.post(["do": "copy", "text": (ask ? item["reply"] : item["text"]) ?? ""])', view('HistRow'))   # an ask copies its answer

    def test_state_lists_recent_answers_newest_first(self):
        sys.path.insert(0, str(ROOT)); import aurel
        rows = [{'at': '2026-10-14 08:00:00', 'task': 'open notes', 'reply': 'Opened Notes', 'usd': 0, 'secs': 1},
                {'id': '1-1', 'at': '2026-10-15 09:00:00', 'task': 'weather', 'status': 'running', 'pid': os.getpid()},   # a checkpoint with no answer yet
                {'at': '2026-10-15 09:30:00', 'task': 'weather', 'reply': 'Sunny', 'usd': 0, 'secs': 1}]
        with tempfile.TemporaryDirectory() as root:
            Path(root, 'log.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
            with patch.object(aurel, 'DIR', root), patch.object(aurel, 'MEMORY', str(Path(root) / 'memory.md')), \
                 patch.object(aurel, 'SKILLS', str(Path(root) / 'skills.json')), patch.object(aurel, 'plan', return_value={}), \
                 patch.object(aurel, 'me', return_value={}), patch('sys.argv', ['aurel.py', '--state']), \
                 contextlib.redirect_stdout(io.StringIO()) as out:
                aurel.main()
        self.assertEqual([(a['task'], a['reply']) for a in json.loads(out.getvalue())['asks']], [('weather', 'Sunny'), ('open notes', 'Opened Notes')])


if __name__ == '__main__':
    unittest.main()
