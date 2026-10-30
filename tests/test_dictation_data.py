"""Local dictation storage and conservative corrections; no UI, mic, apps or model calls."""
from pathlib import Path
import unittest
from unittest.mock import patch

from tests import native_ui, run_swift

ROOT = Path(__file__).resolve().parents[1]


class DictationDataTests(unittest.TestCase):
    def test_private_bounded_history_stats_and_dictionary(self):
        source = (ROOT / 'Aurel.swift').read_text()
        store = source[source.index('enum DictationData {'):source.index('enum Prefs {')]
        swift = r'''import AppKit
struct Prefs {
    static let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path + "/settings.json"
    static var d: [String: Any] = ["dictateHistory": true]
    static func bool(_ k: String) -> Bool { d[k] as? Bool ?? false }
    static func set(_ k: String, _ v: Any) -> Bool { d[k] = v; return true }
}
''' + store + r'''
defer { try? FileManager.default.removeItem(atPath: (Prefs.path as NSString).deletingLastPathComponent) }
precondition(DictationData.word("Saarth"))
precondition(DictationData.word("Saarth") && DictationData.words == ["Saarth"])
precondition(DictationData.word("Aurel", replacing: "Saarth") && DictationData.words == ["Aurel"])
precondition(!DictationData.word("\n") && !DictationData.word("bad\nword") && !DictationData.word(String(repeating:"a", count:81)))
precondition(DictationData.record("Three final words", raw: "um Three final words", app: "Example", seconds: 1))
let row = DictationData.archive.history[0]
precondition(row.raw == "um Three final words" && row.app == "Example" && row.text == "Three final words")
let attr = try! FileManager.default.attributesOfItem(atPath: DictationData.path)
precondition((attr[.posixPermissions] as! NSNumber).intValue == 0o600)
let folder = try! FileManager.default.attributesOfItem(atPath: (Prefs.path as NSString).deletingLastPathComponent)
precondition((folder[.posixPermissions] as! NSNumber).intValue == 0o700)
let decoded = try! JSONDecoder().decode(DictationData.Archive.self, from: Data(contentsOf: URL(fileURLWithPath: DictationData.path)))
precondition(decoded.history.count == 1 && decoded.words == 3 && decoded.todayWords == 3)
Prefs.set("dictateHistory", false)
precondition(DictationData.record("No stored text", raw: "No stored text", app: "Private", seconds: 1))
precondition(DictationData.archive.history.count == 1 && DictationData.archive.words == 6 && DictationData.archive.sessions == 2)
DictationData.archive.history = []; precondition(DictationData.save())
precondition(DictationData.archive.words == 6)
DictationData.archive.day = "2000-01-01"
precondition((DictationData.state()["stats"] as! [String: Int])["today"] == 0)
precondition(DictationData.record("New day", raw: "New day", app: "Example", seconds: 0))
precondition(DictationData.archive.todayWords == 2 && DictationData.archive.words == 8)
let recent = DictationData.Entry(id:"new", timestamp:Date().timeIntervalSince1970, app:"A", text:"B", raw:nil)
let expired = DictationData.Entry(id:"old", timestamp:Date().timeIntervalSince1970 - 31 * 86400, app:"A", text:"B", raw:nil)
DictationData.archive.history = [expired] + Array(repeating:recent, count:501)
DictationData.prune()
precondition(DictationData.archive.history.count == 500 && !DictationData.archive.history.contains { $0.id == "old" })
precondition(DictationData.save())
// A failed write must leave the previous in-memory totals intact.
let count = DictationData.archive.words
try! FileManager.default.removeItem(atPath: (Prefs.path as NSString).deletingLastPathComponent)
try! Data().write(to: URL(fileURLWithPath: (Prefs.path as NSString).deletingLastPathComponent))
precondition(!DictationData.record("failure", raw:"failure", app:"A", seconds:0))
precondition(DictationData.archive.words == count)
print("private dictation data ok")
'''
        self.assertIn('private dictation data ok', run_swift(self, swift))

    def test_corrections_are_single_words_and_reject_rewrites(self):
        source = (ROOT / 'Aurel.swift').read_text()
        store = source[source.index('enum DictationData {'):source.index('enum Prefs {')]
        swift = r'''import AppKit
struct Prefs {
    static var path = "/tmp/unused-aurel-dictation-test/settings.json"
    static var d: [String: Any] = [:]
    static func bool(_ k: String) -> Bool { false }
    static func set(_ k: String, _ v: Any) -> Bool { true }
}
''' + store + r'''
let saarth = DictationData.correction("Hello Sarth.", "Hello Saarth.")
precondition(saarth?.heard == "Sarth" && saarth?.word == "Saarth")
precondition(DictationData.correction("open aurel", "open Aurel")?.word == "Aurel")
precondition(DictationData.correction("Hi Andree", "Hi André")?.word == "André")
precondition(DictationData.correction("I went their", "I went there") == nil)   // an everyday word is no name to learn
let sarda = DictationData.correction("Can you make sure Sarda does that?", "Can you make sure Saarth does that?")
precondition(sarda?.heard == "Sarda" && sarda?.word == "Saarth", "sound-alike fix")
let two = DictationData.correction("You make sure start to does that.", "You make sure Saarth does that.")
precondition(two?.heard == "start to" && two?.word == "Saarth", "two heard words, one name")
let three = DictationData.correction("Can you ask some of you to do that?", "Can you ask Semva to do that?")
precondition(three?.heard == "some of you" && three?.word == "Semva", "three heard words, one name")
precondition(DictationData.correction("ask some of b to", "ask Semva to")?.word == "Semva", "garbled three words")
precondition(DictationData.correction("Can you ask somebody to do that?", "Can you ask Semva to do that?")?.heard == "somebody", "a real word that sounds like the name")
precondition(DictationData.correction("send it to the team", "send it Tuesday") == nil, "several words that don't sound alike")
precondition(DictationData.correction("Ship it Friday.", "Ship it Monday.") == nil, "a new idea")
precondition(DictationData.correction("ask Sarda now", "ask Saarth there now") == nil, "one word became two")
precondition(DictationData.sound("Saarth") == "srt" && DictationData.sound("start to") == "strt" && DictationData.sound("André") == "amtr")
var keys = DictationData.Replay("make sure start to does")
for (code, typed, option) in [(123, "", true), (51, "", true), (51, "", true)] { precondition(keys.key(code, typed, option: option, control: false, command: false)) }
for c in "Saarth " { precondition(keys.key(0, String(c), option: false, control: false, command: false)) }
precondition(keys.text == "make sure Saarth does", keys.text)
precondition(DictationData.correction("make sure start to does", keys.text)?.heard == "start to", "replayed fix")
var ends = DictationData.Replay("hi")
precondition(!ends.key(36, "\r", option: false, control: false, command: false), "Return")
precondition(!ends.key(9, "v", option: false, control: false, command: true), "⌘V")
precondition(!ends.key(126, "\u{F700}", option: false, control: false, command: false), "up arrow")
precondition(ends.key(51, "", option: false, control: false, command: false) && ends.key(4, "h", option: false, control: true, command: false) && !ends.key(51, "", option: false, control: false, command: false), "deleting past the dictated words")
for text in ["Hello", "Hello Sarth. again", "Changed everything.", "Hello 123.", "Hello Sarth.", "Hi Saarth."] {
    precondition(DictationData.correction("Hello Sarth.", text) == nil, text)
}
print("correction bounds ok")
'''
        self.assertIn('correction bounds ok', run_swift(self, swift))

    def test_learned_fix_swaps_the_heard_word_until_forgotten(self):
        source = (ROOT / 'Aurel.swift').read_text()
        store = source[source.index('enum DictationData {'):source.index('enum Prefs {')]
        swift = r'''import AppKit
struct Prefs {
    static var path = "/tmp/unused-aurel-dictation-test/settings.json"
    static var d: [String: Any] = [:]
    static func bool(_ k: String) -> Bool { false }
    static func set(_ k: String, _ v: Any) -> Bool { d[k] = v; return true }
}
''' + store + r'''
precondition(DictationData.word("Saarth") && DictationData.fix("Sarth", "Saarth"), "saved fix")
precondition(DictationData.fixed("sarth met Sarth's friend, not Sarthak.") == "Saarth met Saarth's friend, not Sarthak.", "whole-word swap")
precondition(DictationData.word("cache") && DictationData.fix("cash", "cache"), "real heard word kept for hints")
precondition(DictationData.fixed("cash it") == "cash it", "real word swapped")   // only cleanup, with context, may change it
precondition(!DictationData.fix("Bob", "Robert"), "non-dictionary fix")   // only a dictionary word gets a fix
precondition(DictationData.word("vexlar") && DictationData.fix("vexlor", "vexlar"), "lowercase fix")
precondition(DictationData.fixed("Vexlor then vexlor.") == "Vexlar then vexlar.", "capital kept")
precondition(DictationData.word("Vexlar", replacing: "vexlar") && DictationData.fixes["vexlor"] == "Vexlar", "edit retargets")
precondition(DictationData.forget("Saarth") && DictationData.fixes["sarth"] == nil && !DictationData.words.contains("Saarth"), "forget")
precondition(DictationData.fixed("Sarth") == "Sarth", "forgotten swap")
print("learned fixes ok")
'''
        self.assertIn('learned fixes ok', run_swift(self, swift))
        self.assertIn('fitted(DictationData.fixed(rest), into: target)', source)   # every insert path goes through insertDictation
        self.assertIn('DictationData.fix(fix.heard, word)', source)
        self.assertEqual(source.count('DictationData.forget('), 2)   # Undo and Settings remove both drop the fix

    def test_words_fit_the_text_around_the_cursor(self):
        source = (ROOT / 'Aurel.swift').read_text()
        store = source[source.index('enum DictationData {'):source.index('enum Prefs {')]
        swift = r"""import AppKit
struct Prefs {
    static var path = "/tmp/unused-aurel-dictation-test/settings.json"
    static var d: [String: Any] = ["dictateWords": ["Saarth"]]
    static func bool(_ k: String) -> Bool { false }
    static func set(_ k: String, _ v: Any) -> Bool { d[k] = v; return true }
}
""" + store + r"""
func check(_ heard: String, _ before: String, _ after: String, _ want: String) {
    let got = DictationData.fit(heard, before: before, after: after)
    precondition(got == want, "\(heard) between \(before.debugDescription) and \(after.debugDescription): \(got.debugDescription)")
}
check("Hello there.", "", "", "Hello there.")                                  // an empty field: as heard
check("See you Thursday.", "Sounds good,", "", " see you Thursday.")           // mid-sentence: a space, lowercase
check("See you Thursday.", "Sounds good, ", "", "see you Thursday.")           // the space is already there
check("thanks.", "Done.", "", " Thanks.")                                        // after a sentence: capital
check("thanks.", "Done.\n", "", "Thanks.")                                       // a new line starts a sentence
check("Quick brown.", "The ", " fox jumps", "quick brown")                     // the sentence goes on: no period
check("Next one.", "Done. ", " Then more.", "Next one.")                        // before a new sentence: the period stays
check("Word", "(", ")", "word")                                                  // inside brackets: no spaces
check("Ok", "Say ", "now", "ok ")                                                // more text right after: a space
check("I think so.", "Well, ", "", "I think so.")                               // I stays capital
check("NASA called.", "Then ", "", "NASA called.")                              // acronyms stay
check("iPhone is here.", "My ", "", "iPhone is here.")                         // mixed case stays
check("Saarth said hi.", "Then ", "", "Saarth said hi.")                        // Dictionary words keep their case
check(", and more", "Apples", "", ", and more")                                 // punctuation sticks to the word before
print("fit ok")
"""
        self.assertIn('fit ok', run_swift(self, swift))

    def test_dictionary_reaches_cleanup_and_keeps_saved_rules(self):
        import aurel
        with patch.object(aurel, 'pref', return_value=['Saarth', 'Aurel', None, 'bad\nword']), \
             patch.object(aurel, 'relevant_rules', return_value='Spell my name Saarth.'):
            request = aurel.dictate_request('say Sarth')
            self.assertIn('["Saarth", "Aurel"]', request)
            self.assertIn('Spell my name Saarth.', request)
            self.assertNotIn('bad', request)
            self.assertEqual(aurel.dictate_result('say Sarth', '<cleaned>Say Saarth.</cleaned>', {'Sarth': 'Saarth'}), 'Say Saarth.')

    def test_cleanup_gets_sound_alike_hints_and_may_write_the_name(self):
        import aurel
        prefs = {'dictateWords': ['Saarth'], 'dictateFixes': {'some veto': 'Saarth', 'old': 'Gone'}}
        with patch.object(aurel, 'pref', side_effect=lambda k, d=None: prefs.get(k, d)), \
             patch.object(aurel, 'relevant_rules', return_value=''):
            self.assertEqual(aurel.dictate_hints('Can you make sure Sarda does that?', ['Saarth']), {'Sarda': 'Saarth'})
            self.assertEqual(aurel.dictate_hints('You make sure some veto that.', ['Saarth']), {'some veto': 'Saarth'})   # a learned heard form
            self.assertEqual(aurel.dictate_hints('Saarth sorted it', ['Saarth']), {})   # already said right
            self.assertEqual(aurel.dictate_hints('Hi there', ['Saarth']), {})
            self.assertEqual(aurel.dictate_hints('Can you ask some of you to do that?', ['Semva']).get('some of you'), 'Semva')
            text = 'You make sure start to does that.'
            request = aurel.dictate_spellings(text)
            self.assertIn('"start": "Saarth"', request)
            hints = aurel.dictate_hints(text, ['Saarth'])
            self.assertEqual(aurel.dictate_result(text, '<cleaned>You make sure Saarth does that.</cleaned>', hints), 'You make sure Saarth does that.')
            ordinary = 'Send the update to him this afternoon please.'
            changed = '<cleaned>Send the update to Saarth this afternoon please.</cleaned>'
            self.assertEqual(aurel.dictate_result(ordinary, changed, {}), ordinary)
            self.assertEqual(aurel.dictate_result(ordinary, changed, {'him': 'Saarth'}),
                             'Send the update to Saarth this afternoon please.')
        self.assertEqual((aurel.dictate_sound('Saarth'), aurel.dictate_sound('start to'), aurel.dictate_sound('André')), ('srt', 'strt', 'amtr'))   # same as DictationData.sound

    def test_correction_window_is_scoped_and_secure_before_read(self):
        source = (ROOT / 'Aurel.swift').read_text()
        monitor = source[source.index('    func prepareDictation('):source.index('    func stopDictationCleanup(')]
        for guard in ['addingTimeInterval(20)', 'dictateID == id', '!engine.isRunning', '!busy',
                      'frontmostApplication == target.app', 'CFEqual(focused, target.focus)',
                      'current.hasPrefix(prefix)', 'current.hasSuffix(suffix)', 'timer.invalidate()']:
            self.assertIn(guard, monitor)
        self.assertLess(monitor.index('kAXSecureTextFieldSubrole'), monitor.index('target.value'))
        poll = monitor[monitor.index('Timer.scheduledTimer'):]
        self.assertLess(poll.index('kAXSecureTextFieldSubrole'), poll.index('target.value'))
        # Keys are read only where the field can't be: in the dictated app, never under secure input, for 20 s, then the monitor goes.
        self.assertLess(monitor.index('kAXSecureTextFieldSubrole'), monitor.index('replayEdits(value'))
        replay = source[source.index('    func replayEdits('):source.index('    func stopReplay()')]
        for guard in ['dictateID != id', 'frontmostApplication != app', 'IsSecureEventInputEnabled() ? "secure input"', 'guard why == nil',
                      'withTimeInterval: 20', 'stopReplay()']:
            self.assertIn(guard, replay)
        self.assertIn('NSEvent.removeMonitor(editKeys)', source[source.index('    func stopReplay()'):])
        capture = source[source.index('    static func capture('):source.index('    var caret:')]
        self.assertLess(capture.index('kAXSecureTextFieldSubrole'), capture.index('kAXValueAttribute'))
        session = source[source.index('    func captureDictationSelection('):source.index('    func start()')]
        self.assertIn('onSecure: { secureField = true }', session)
        self.assertLess(session.index('if secureField'), session.index('dictateSelectionPending = false'))
        self.assertIn('hush(); js("dictated"', session)
        self.assertIn('guard let selected else', session)
        self.assertIn('dictateSelection = selected', session)
        self.assertNotIn('selected.text.count <= 6000', session)
        self.assertIn('if AXIsProcessTrusted() {', session)   # no text field: keep listening, the words go to History
        self.assertLess(session.index('dictateSelectionPending = false'), session.index('guard let selected else'))
        self.assertIn('dictationTargetApp = NSWorkspace.shared.frontmostApplication', session)
        self.assertIn('if retry { finishDictation() }', session)
        finish = source[source.index('    func finishDictation()'):source.index('    func recordDictationEvent(')]
        self.assertIn('captureDictationSelection(retry: true)', finish)
        self.assertIn('!dictateSelectionRetried', finish)
        self.assertIn('NSWorkspace.shared.frontmostApplication == app', finish)
        self.assertLess(finish.index('dictateSelectionRetried = true'), finish.index('captureDictationSelection(retry: true)'))
        self.assertLess(finish.index('captureDictationSelection(retry: true)'), finish.index('let spoken ='))
        start = source[source.index('    func start(dictate: Bool, quiet: Bool = false)'):source.index('    func heard(')]
        self.assertLess(start.index('if dictate && !AXIsProcessTrusted()'), start.index('captureDictationSelection()'))
        self.assertIn('Allow Accessibility in System Settings → Privacy & Security → Accessibility', start)


class DictationUIDataTests(unittest.TestCase):
    def test_dictionary_and_history_actions_use_text_and_search_raw(self):
        settings = (ROOT / 'Settings.swift').read_text()
        view = lambda name: settings[settings.index(f'struct {name}:'):settings.index('\n}\n', settings.index(f'struct {name}:'))]
        stats, history = view('Stats'), view('History')
        between = lambda s, a, b: s[s.index(a):s.index(b, s.index(a))]
        swift = between(stats, '    func fmt(', '\n    }') + '\n    }\n' \
            + 'func cells(_ m: SettingsModel) -> [String] {\n' + between(stats, '        let n = m.stats', '        GeometryReader') + '    return cells.flatMap { [$0.1, $0.2] }\n}\n' \
            + between(settings, 'private let askDate', '\n').replace('private ', '', 1) + '\n' \
            + 'func rows(_ m: SettingsModel) -> [String] {\n' + between(history, '        let q = m.search.lowercased()', '        ScrollView') + '    return rows.map { $0["text"] as? String ?? "" }\n}\n' + r"""
let m = SettingsModel(); var posts: [[String: Any]] = []; m.post = { posts.append($0) }
m.receive("dictation", ["words": ["<Saarth>"], "history": [["id": "1", "timestamp": 1, "app": "Editor", "text": "Final <text>", "raw": "Raw Sarth"], ["id": "2", "timestamp": 2, "app": "Chat", "text": "Other text"]],
                        "stats": ["today": 2, "words": 9, "minutes": 1, "sessions": 2]] as [String: Any])
precondition(cells(m) == ["2", "words", "9", "words", "1", "minutes", "2", "dictations"], "\(cells(m))")
precondition(m.words == ["<Saarth>"], "dictionary did not keep literal text")
m.search = "raw sarth"; precondition(rows(m) == ["Final <text>"], "raw transcript not searchable")
m.search = "chat"; precondition(rows(m) == ["Other text"], "app not searchable")
m.search = ""; precondition(rows(m) == ["Other text", "Final <text>"], "history not newest first")
m.receive("dictation", ["words": [String](), "history": [[String: Any]](), "stats": ["today": 0, "words": 12345, "minutes": 90, "sessions": 1]] as [String: Any])
precondition(cells(m)[2...5] == ["12,345", "words", "1.5", "hours"], "stats not formatted for long use: \(cells(m))")
var cleared = false; m.showNotice("Clear all saved dictations?", "Clear all") { cleared = true }
precondition(!cleared && posts.isEmpty, "clear all did not wait for its click")
"""
        native_ui(self, swift)
        dictate = view('DictationSection')
        self.assertIn('m.showNotice("Clear all saved dictations?", "Clear all") { m.post(["do": "dictationClear"]) }', dictate)   # clear all waits for its click
        self.assertIn('AddRow(placeholder: "Add a word or phrase", button: "Add Word", first: true) { m.post(["do": "dictationWord", "word": $0]) }', dictate)
        self.assertIn('{ add(text); text = "" }', view('AddRow'))   # the field empties after Add
        self.assertIn('m.words.isEmpty ? "No words yet. Add names, slang or product names." : "Names, slang and product names."', dictate)
        self.assertIn('"Your dictations and asks will appear here."', history)
        word = view('WordRow')
        self.assertIn('.onAppear { text = word }', word)   # the word as typed, never as markup
        self.assertIn('if text != word { RowX(icon: RowIcon.check, shown: true, save: true) { m.post(["do": "dictationWord", "old": word, "word": text]) } }', word)   # save shows once edited
        self.assertIn('m.post(["do": "dictationWordDelete", "word": word])', word)
        row = view('HistRow')
        self.assertIn('m.post(["do": "copy", "text": (ask ? item["reply"] : item["text"]) ?? ""])', row)
        self.assertIn('if !ask { RowX(icon: RowIcon.trash, shown: hover) { m.post(["do": "dictationDelete", "id": item["id"] ?? ""]) } }', row)
        self.assertIn('T(s: item["text"] as? String ?? "", lh: 1.45)', row)   # history text stays literal

    def test_learned_toast_undo_posts_and_disables_its_button(self):
        native_ui(self, """let m = BoxModel(); var sent: [[String: Any]] = []; m.post = { sent.append($0) }
m.receive("learned", "Saarth")
precondition(m.dn == "Learned “Saarth”" && m.dnButtons.map { $0.0 } == ["Undo"], m.dn)
m.dnButtons[0].1()
precondition(sent.count == 1 && sent[0]["learnedUndo"] as? Bool == true, "learned undo not sent")
precondition(m.dnButtons.isEmpty, "Undo stays clickable after it ran")
""")

if __name__ == '__main__':
    unittest.main()
