"""Setup (Onboarding.swift) shows the app as it is today. Source checks, and capsOf run natively: no window or app."""
from pathlib import Path
import re
import unittest

from tests import native_ui

ROOT = Path(__file__).resolve().parents[1]


class OnboardingMatchesAppTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.page = (ROOT / 'Onboarding.swift').read_text()

    def view(self, name):   # one type's source, up to its closing brace
        i = re.search(rf'struct {name}\b', self.page).start()
        return self.page[i:self.page.index('\n}\n', i)]

    def test_skip_all_jumps_to_the_closing_pages(self):
        self.assertIn('if (setupPages.firstIndex(of: m.cur) ?? 0) < setupPages.firstIndex(of: "improve")! { PillButton(label: "Skip All", quiet: true, plain: true, height: 30, pad: 10) { m.go("improve") } }', self.page)
        self.assertIn('{ m.post(["do": "done"]) }', self.view('Done'))
        swift = (ROOT / 'Aurel.swift').read_text()
        self.assertIn('if b["do"] == "done" { return finish() }', swift)
        finish = swift.split('    func finish() {', 1)[1].split('    func windowDidResignKey', 1)[0]
        self.assertIn('set(true, forKey: "onboarded")', finish)
        self.assertIn('win?.close()', finish)
        self.assertIn('if relaunch { relaunchSoon() }', finish)

    def test_privacy_help_drags_a_bundle_and_cleans_up(self):
        swift = (ROOT / 'Aurel.swift').read_text()
        helper = swift.split('final class PermissionIcon:', 1)[1].split('// `Aurel --look', 1)[0]
        self.assertIn('NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)', helper)
        self.assertIn('beginDraggingSession(with: [item], event: event, source: self)', helper)
        self.assertIn('if self.panel === w, allowed { self.close() }', helper)
        self.assertIn('if seen { close() }', helper)
        self.assertNotIn('timeIntervalSince', helper)   # a slow Settings launch or consent prompt must not lose the helper
        self.assertLess(helper.index('let allowed = granted()'), helper.index('guard let frame'))
        self.assertIn('func windowWillClose(_ n: Notification) { timer?.invalidate(); timer = nil; panel = nil }', helper)
        self.assertIn('styleMask: [.titled, .closable, .nonactivatingPanel]', helper)
        self.assertIn('drag: p == "Accessibility" || p == "ScreenCapture"', swift)
        for pane in ('Accessibility', 'ScreenCapture', 'Microphone', 'SpeechRecognition', 'Calendars', 'Automation'):
            self.assertIn('"' + pane + '": ', swift)
        self.assertIn('case "automation": onboarding.settings("Automation")', swift)

    def test_dictation_pill_shows_no_words(self):
        pill = self.view('DictPill')
        self.assertNotIn('Text(', pill)   # the pill has no transcript any more
        self.assertLess(pill.index('if state == "wave" { HStack'), pill.index('if state == "work" { Circle()'))   # wave, then the orb, then the check
        self.assertLess(pill.index('if state == "work"'), pill.index('if state == "done" { ZStack { Circle().fill(Color(hex: 0x30d158)); SVGPath('))
        loop = self.view('DictateStage')
        self.assertLess(loop.index('pill = "work"'), loop.index('pill = "done"'))

    def test_talk_keys_follow_the_configured_shortcut(self):
        native_ui(self, '''for (label, keys) in ["⌃⌥Space": ["⌃", "⌥", "Space"], "fn": ["fn"], "fn⌃": ["fn", "⌃"], "⌘⇧A": ["⌘", "⇧", "A"], "F5": ["F5"]] {
    precondition(capsOf(label) == keys, "\\(label) → \\(capsOf(label))")
}''')
        for page in ('Welcome', 'Try'):
            self.assertIn('capsOf(m.pstr("hotkeyLabel").isEmpty ? "⌃⌥Space" : m.pstr("hotkeyLabel"))', self.view(page))
        swift = (ROOT / 'Aurel.swift').read_text()
        self.assertIn('"hotkeyLabel": Prefs.str("hotkeyLabel")', swift)   # setup draws the keys the user set
        self.assertIn('call("ob.keys", shortcutModifierLabel(NSEvent.modifierFlags))', swift)   # any held modifier lights, not only ⌃⌥

    def test_work_demo_box_does_not_mirror_agent_steps(self):
        self.assertNotIn('Moving to an agent', self.page)   # the box says it started once; steps live on the chip
        loop = self.view('WorkStage')
        self.assertEqual(loop.count('line = "I started an agent. I’ll ping you when it’s done."'), 2)   # the loop and its Reduce Motion frame
        self.assertIn('"Agent · done"', loop)

    def test_point_demo_runs_the_leader_line_before_the_ring(self):
        loop = self.view('PointStage')
        self.assertLess(loop.index('lead = true'), loop.index('ring = true'))   # the ring shows as the line arrives, as on screen
        self.assertIn('LeadLine(on: lead)', loop)
        self.assertIn('Color(hex: 0x0a84ff)]', self.view('LeadLine'))   # blue, like the app's leader

    def test_safe_mode_line_shows_only_while_it_is_on(self):
        self.assertIn('if m.prefs["safe"] as? Bool != false { Note(s: "Safe mode is on', self.page)
        self.assertIn('"safe": Prefs.bool("safe")', (ROOT / 'Aurel.swift').read_text())

    def test_mini_screen_copy_matches_its_click(self):
        self.assertNotIn('ask to focus it', self.page)
        self.assertIn('click it to open that window', self.page)   # the mini screen opens its window on click (README)

    def test_provider_row_names_no_client_before_the_check(self):
        self.assertIn('SetupRow(id: "claude", name: "AI Provider", why: "Checking…"', self.page)   # Devin, Pi and server users never read "Claude" first
        self.assertNotIn('Checking your Claude sign-in', self.page)

    def test_failed_asks_only_open_setup_automatically_once_per_launch(self):
        swift = (ROOT / 'Aurel.swift').read_text()
        opening = swift.split('    func open(automatic: Bool = false) {', 1)[1].split('        screenInitiallyGranted', 1)[0]
        self.assertIn('if automatic && setupShown { return }', opening)
        self.assertLess(opening.index('if automatic && setupShown'), opening.index('setupShown = true'))
        self.assertLess(opening.index('setupShown = true'), opening.index('guard win == nil'))
        self.assertIn('setupShown = false', swift)
        self.assertEqual(swift.count('setupShown = true'), 1)
        self.assertIn('if line == "! setup" { onboarding.open(automatic: true); continue }', swift)
        self.assertIn('case "setup": onboarding.open()', swift)   # explicit setup stays available after dismissal
        self.assertIn('if !UserDefaults.standard.bool(forKey: "onboarded") { DispatchQueue.main.async { onboarding.open() } }', swift)
        self.assertIn('else { Onboarding.plan { c in if c["ok"] as? Bool != true { onboarding.open(automatic: true) } } }', swift)
        start = swift.split('    func open(automatic: Bool = false) {', 1)[1].split('        var tick = 0', 1)[0]
        self.assertIn('m.go(automatic ? "perms" : "welcome")', start)   # automatic opens skip the welcome
        self.assertLess(start.index('model = m'), start.index('m.go('))

    def test_setup_opens_settings_for_invalid_configuration_before_signin(self):
        swift = (ROOT / 'Aurel.swift').read_text()
        fix = swift.split('    func fixPlan() {', 1)[1].split('    func tried()', 1)[0]
        self.assertIn('if need.isEmpty, c["ok"] as? Bool == false { Aurel.settings.open(); return }', fix)
        self.assertLess(fix.index('if need.isEmpty'), fix.index('let cmd ='))

    def test_setup_checks_one_provider_process_at_a_time(self):
        swift = (ROOT / 'Aurel.swift').read_text()
        check = swift.split('    func checkPlan() {', 1)[1].split('\n    }', 1)[0]
        self.assertIn('guard !checkingPlan else { return }', check)
        self.assertLess(check.index('checkingPlan = true'), check.index('Onboarding.plan'))
        self.assertIn('self?.checkingPlan = false', check)

    def test_voice_asks_use_the_mac_language(self):
        swift = (ROOT / 'Aurel.swift').read_text()
        speech = swift.split('    func speechModule(dictate: Bool = false)', 1)[1].split('    func prepareSpeech()', 1)[0]
        self.assertNotIn('Locale.current', speech)   # SpeechTranscriber rejected the Mac's locale: every voice ask died in 1.5.0
        self.assertIn(': SpeechTranscriber(locale: locale, preset: .progressiveTranscription)', speech)
        start = swift.split('    func start(dictate: Bool, quiet: Bool = false)', 1)[1].split('    func heard(', 1)[0]
        self.assertIn('dictate || SFSpeechRecognizer.authorizationStatus() == .authorized', start)
        self.assertIn('Privacy & Security → Speech Recognition.', start)
        prepare = swift.split('    func prepareSpeech()', 1)[1].split('    var text =', 1)[0]
        self.assertIn('guard !preparingSpeech else { return }', prepare)


if __name__ == '__main__':
    unittest.main()
