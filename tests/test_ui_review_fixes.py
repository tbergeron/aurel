"""Regressions from the 1.3.2 UI review, on the native box, Settings and setup: source checks and model runs, no windows."""
from pathlib import Path
import re
import unittest

from tests import native_ui


ROOT = Path(__file__).resolve().parents[1]


def contrast(fg, bg):
    def lum(h):
        c = [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]
        c = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in c]
        return .2126 * c[0] + .7152 * c[1] + .0722 * c[2]
    a, b = lum(fg), lum(bg)
    return (max(a, b) + .05) / (min(a, b) + .05)


def tint(color, alpha, bg='#ffffff'):
    return '#' + ''.join('%02x' % round(alpha * int(color[i:i + 2], 16) + (1 - alpha) * int(bg[i:i + 2], 16)) for i in (1, 3, 5))


def token(source, theme, name):
    """(dark, light) hex of a PrefsTheme/SetupTheme colour: `var fg3: Color { dark ? Color(hex: 0x…) : Color(hex: 0x…) }`."""
    body = source[source.index('struct ' + theme + ' {'):]
    m = re.search(r'var ' + name + r': Color \{ dark \? Color\(hex: 0x([0-9a-f]{6})\) : Color\(hex: 0x([0-9a-f]{6})\) \}', body)
    return '#' + m.group(1), '#' + m.group(2)


def part(source, start, end):
    i = source.index(start)
    return source[i:source.index(end, i)]


class UIReviewFixTests(unittest.TestCase):
    def setUp(self):
        self.swift = (ROOT / 'Aurel.swift').read_text()
        self.box = (ROOT / 'Box.swift').read_text()
        self.settings = (ROOT / 'Settings.swift').read_text()
        self.onboarding = (ROOT / 'Onboarding.swift').read_text()

    def test_native_clicks_reach_try_again_the_agents_pill_and_pill_buttons(self):
        # Try again, the agents pill and the dictation pill's buttons are buttons, so a click on them is not a click on the answer
        self.assertIn('.boxTarget("redo", kind: .button {', self.box)
        self.assertIn('.boxTarget("agents", kind: .button {', self.box)
        self.assertIn('.boxTarget("dn\\(i)", kind: .button(m.dnButtons[i].1))', self.box)
        native_ui(self, r'''
let m = BoxModel(); var sent: [[String: Any]] = []; m.post = { sent.append($0) }
m.receive("listen", NSNull()); m.receive("words", "why"); m.receive("think", NSNull()); m.receive("line", "✓ Because.")
guard case .answer(let a)? = m.turns.last?.parts.first(where: { if case .answer = $0 { return true }; return false }) else { fatalError() }
var clicked = ""
let answer = TargetEntry("a:" + a.uuidString, CGRect(x: 0, y: 0, width: 300, height: 100), false, .answer)
m.targets = [answer, TargetEntry("redo", CGRect(x: 10, y: 80, width: 60, height: 16), true, .button { clicked = "redo" })]
m.tap(CGPoint(x: 20, y: 85)); precondition(clicked == "redo" && sent.allSatisfy { $0["copy"] == nil }, "Try again copied the answer")
m.targets = [answer]; m.tap(CGPoint(x: 20, y: 20)); precondition(sent.contains { $0["copy"] as? String == "Because." }, "a click on the answer copies it")
m.receive("dictate", true); sent = []
m.targets = [TargetEntry("pill", CGRect(x: 0, y: 0, width: 200, height: 36), false, .area), TargetEntry("dn0", CGRect(x: 150, y: 4, width: 40, height: 28), true, .button { clicked = "dn" })]
m.tap(CGPoint(x: 160, y: 10)); precondition(clicked == "dn")
clicked = ""; m.tap(CGPoint(x: 20, y: 10)); precondition(clicked.isEmpty && sent.isEmpty, "a click on the dictation pill opened the typing box")
''')

    def test_typing_row_animates_everything_it_changes(self):
        # Oct 20, 2026: the open row's -4px side margins jumped while its padding animated. Natively the margins never change
        # and every change to the row comes from compOpen, which only changes inside one animation.
        composer = part(self.box, 'private struct Composer: View {', '    func bead(')
        self.assertIn('.padding(.horizontal, -4).padding(.top, m.compOpen ?', composer)
        self.assertIn('if compOpen != on { withAnimation(BX.ease(0.24)) { compOpen = on } }', self.box)

    def test_choice_number_shortcuts_work_from_the_empty_composer(self):
        keys = part(self.box, '    func keys(_ k: KeyPress) -> KeyPress.Result {', '\n    }\n')
        self.assertIn('guard m.ask.isEmpty, k.modifiers.isEmpty else { return .ignored }', keys)   # "version 2" is typing, not a pick
        digit = keys[keys.index('if let d = Int(k.characters)'):keys.index('return .handled')]
        self.assertIn('m.pickDone(c.id, d - 1)', digit)
        self.assertNotIn('if pics', digit, 'the page picked a choice with pictures too (c.choose = () => done(i))')
        native_ui(self, r'''
let m = BoxModel(); var sent: [[String: Any]] = []; m.post = { sent.append($0) }
m.receive("listen", NSNull()); m.receive("words", "which"); m.receive("think", NSNull())
m.receive("pick", ["q": "Which?", "options": [["label": "A"], ["label": "B"], ["label": "C"]]])
guard let c = m.liveCard({ if case .pick = $0 { return true }; return false }) else { fatalError() }
m.pickDone(c.id, 1)
precondition(sent.contains { $0["pick"] as? String == "1" } && m.turns.last?.steps.last?.text == "Picked B")
''')

    def test_full_access_badge_is_a_keyboard_control(self):
        # The box never takes keyboard focus; a click on the badge turns safe mode back on
        self.assertIn('.boxTarget("mode", kind: .mode).help("Safe mode is off. Click to turn it on.")', self.box)
        native_ui(self, r'''
let m = BoxModel(); var sent: [[String: Any]] = []; m.post = { sent.append($0) }
m.receive("mode", false); precondition(m.safeOff)
m.targets = [TargetEntry("mode", CGRect(x: 0, y: 0, width: 80, height: 22), true, .mode)]
m.tap(CGPoint(x: 10, y: 10))
precondition(sent.contains { $0["safe"] as? Bool == true } && m.status == "Safe mode on · Settings turns it off")
''')

    def test_failed_dictation_offers_its_words_to_copy(self):
        native_ui(self, r'''
let m = BoxModel(); var sent: [[String: Any]] = []; m.post = { sent.append($0) }
m.receive("dictate", true)
m.receive("dictated", ["text": "Nothing selected to insert — saved to History.", "ok": false]); precondition(m.dnButtons.isEmpty)
m.receive("dictated", ["text": "Couldn’t insert. Your words are still here.", "ok": false, "words": "my words"])
precondition(m.dnButtons.map { $0.0 } == ["Copy"]); m.dnButtons[0].1()
precondition(sent.last?["copy"] as? String == "my words")
precondition(m.dnButtons.first?.0 == "Copied", "the Copy button still says \(m.dnButtons.first?.0 ?? "nothing") after copying")
m.receive("dictated", ["text": "Couldn’t insert. Press ⌃⌘V to paste it.", "ok": false, "history": true])
precondition(m.dnButtons.map { $0.0 } == ["History"]); m.dnButtons[0].1()
precondition(sent.last?["dictationHistory"] as? Bool == true)
''')

    def test_agent_start_releases_an_empty_typed_composer_for_the_fade(self):
        native_ui(self, r'''
let m = BoxModel()
m.comp(true); m.receive("agentStarted", ["title": "Report"]); precondition(!m.compOpen, "an empty typing box held the box open")
m.comp(true); m.ask = "and also"; m.receive("agentStarted", ["title": "Report"]); precondition(m.compOpen, "the start took typed words away")
''')

    def test_learned_word_shows_in_the_pill_after_it_folded(self):
        self.assertIn('learnedWord = word; pill(true); show(); js("learned", word)', self.swift)

    def test_reduce_motion_stops_onboarding_loops(self):
        # The page followed Reduce Motion while open: loops snapped to their last frame. Natively every preview takes m.reduce
        # and shows its last frame, but the model must hear the change.
        for stage in ('MacStage(run: active, reduce: m.reduce)', 'TextStage(run: active, reduce: m.reduce)', 'PointStage(run: active, reduce: m.reduce)',
                      'WorkStage(run: on, reduce: m.reduce)', 'DictateStage(run: on, reduce: m.reduce'):
            self.assertIn(stage, self.onboarding)
        self.assertIn('if reduce { snapped = true; play = true; box = true; return }', self.onboarding)
        native_ui(self, r'''
let m = OnboardingModel()
m.receive("motion", true); precondition(m.reduce, "setup ignores a Reduce Motion change")
m.receive("motion", false); precondition(!m.reduce)
''')
        self.assertTrue('accessibilityDisplayOptionsDidChangeNotification' in self.swift, 'nothing tells setup when Reduce Motion changes')

    def test_onboarding_welcome_orb_keeps_animating(self):
        welcome = part(self.onboarding, 'ZStack { Glow(inset: 60); OrbRep(', '\n')
        self.assertIn('OrbRep(running: on && !m.reduce)', welcome)   # runs on its page; still under Reduce Motion or away
        orb = (ROOT / 'Orb.swift').read_text()
        view = part(orb, 'final class OrbView: NSView {', '\n}\n')
        self.assertIn('prev = CACurrentMediaTime(); paint()', view)   # a still orb is painted once, never blank
        self.assertIn('guard running else { l.isPaused = true; return }', view)   # no frames while still
        self.assertIn('if running && !oldValue { prev = CACurrentMediaTime(); link?.isPaused = false }', view)   # and it wakes on its page

    def test_settings_and_agents_text_colours_are_readable(self):
        dark, light = {}, {}
        for name in ('fg3', 'warn', 'danger', 'okText'):
            dark[name], light[name] = token(self.settings, 'PrefsTheme', name)
        bg_dark, bg_light = token(self.settings, 'PrefsTheme', 'bg')
        card_dark, card_light = token(self.settings, 'PrefsTheme', 'card')
        self.assertGreaterEqual(contrast(light['fg3'], bg_light), 4.5, 'fg3')
        for name in ('warn', 'danger'):
            self.assertGreaterEqual(contrast(light[name], card_light), 4.5, name)
        for name in ('fg3', 'warn'):
            self.assertGreaterEqual(contrast(dark[name], card_dark), 4.5, 'dark ' + name)
        self.assertIn('.background(rr(10).fill(kind == "ok" ? Color.rgba(52, 199, 89, 0.13) : kind == "no" ? .rgba(255, 159, 10, 0.14)', self.settings)
        self.assertGreaterEqual(contrast(light['okText'], tint('#34c759', .13)), 4.5)
        self.assertGreaterEqual(contrast(light['warn'], tint('#ff9f0a', .14)), 4.5)
        self.assertNotRegex(self.settings, r'foregroundColor\(Color\(hex: 0xff(9f0a|453a)\)\)')   # text uses the tokens; fills may keep the bright colours
        setup_dark, setup_light = token(self.onboarding, 'SetupTheme', 'fg3')
        sheet_dark, sheet_light = token(self.onboarding, 'SetupTheme', 'sheet')
        self.assertGreaterEqual(contrast(setup_light, sheet_light), 4.5)
        self.assertGreaterEqual(contrast(setup_dark, sheet_dark), 4.5)

    def test_onboarding_recorder_names_a_lone_modifier(self):
        self.assertIn('a modifier on its own', self.onboarding)
        self.assertNotIn('Use modifiers with a key', self.onboarding)

    def test_removed_sonnet_offer_leaves_no_card_branch(self):
        self.assertNotIn('Sonnet', part(self.box, '    func respond(_ text: String) -> Bool {', '    func ask(_ a: [Any]) {'))
        app = self.swift.index('final class App: NSObject {')
        self.assertNotIn('"escalate"', self.swift[self.swift.index('    func handle(_ b: [String: Any]) {', app):self.swift.index('    func show()', app)])
        self.assertNotIn("j.get('off'", (ROOT / 'aurel.py').read_text())

    def test_agent_cost_reads_like_usage(self):
        # The Agent view's AgentRow.cost has the same checks in Aurel --selftest
        native_ui(self, r'''
let m = BoxModel()
for (cost, want) in [(0.0412, "≈4.12¢ at API prices"), (0.1861, "≈18.6¢ at API prices"), (2.5, "≈$2.50 at API prices")] {
    m.receive("agentDone", ["id": "a", "title": "Report", "result": "Done.", "cost": cost])
    guard case .agent(_, _, _, _, _, _, let got, _)? = m.liveCard({ if case .agent = $0 { return true }; return false })?.kind else { fatalError() }
    precondition(got == want, "\(got ?? "nil") != \(want)")
}
''')
        self.assertNotIn('Plan usage', self.box + self.swift)

    def test_box_card_screenshots_define_the_agents_panel(self):
        self.assertTrue((ROOT / 'tests/shoot_agents_design.py').read_text().split("CARDS = r'''", 1)[1].startswith('let agentsUI=AgentPanels()\n'))

    def test_a_new_ask_drops_a_paused_card_left_by_resuming_elsewhere(self):
        native_ui(self, r'''
let m = BoxModel()
m.receive("paused", true); precondition(m.liveCard { if case .paused = $0 { return true }; return false } != nil)
m.receive("listen", NSNull())
precondition(m.liveCard { if case .paused = $0 { return true }; return false } == nil, "a new ask kept the paused card")
''')

    def test_rewrite_buttons_answer_hover_and_press_like_card_buttons(self):
        bar = part(self.box, 'private struct RewriteBar: View {', '\n}\n')
        self.assertIn('OkButton(id: "rw\\(i)"', bar)   # the same button as the cards'
        ok = part(self.box, 'private struct OkButton: View {', '\n}\n')
        self.assertIn('let hot = m.hot.contains(id) && !disabled', ok)
        self.assertIn('.scaleEffect(hot ? 1.03 : 1)', ok)

    def test_agent_card_fits_a_short_box(self):
        # The page shrank the answer (to 60 px at least) by however much the card overflowed the thread's height,
        # so the title and actions stay in view in a short box
        card = part(self.box, 'private struct AgentCardView: View {', '\n}\n')
        self.assertIn('m.threadMax - (cardH - shownH)', card, 'the answer cap ignores the box height the user set')
        self.assertIn('max(60, min(260,', card)
        self.assertIn('.frame(maxHeight: cap)', card[card.index('ScrollView(.vertical'):card.index('.mask(')])

    def test_rewrite_actions_sit_above_the_timer_with_one_try_again(self):
        native_ui(self, r'''
let m = BoxModel()
m.receive("listen", NSNull()); m.receive("words", "reply to Dana"); m.receive("think", NSNull())
m.receive("rewrite", ["Hi Dana,", "draft", true])
let kinds = m.turns.last!.parts.map { p -> String in switch p { case .rewrite: return "rewrite"; case .clock: return "clock"; default: return "" } }.filter { !$0.isEmpty }
precondition(kinds == ["rewrite", "clock"], "\(kinds)")
m.receive("line", "✓ Hi Dana,")
precondition(!m.turns.last!.redo, "the timer row's Try again shows beside the bar's own")
''')

    def test_resize_releases_fixed_height_and_uses_live_box_spacing(self):
        native_ui(self, r'''
let m = BoxModel(); var sent: [[String: Any]] = []; m.post = { sent.append($0) }
m.rects = ["card": CGRect(x: 0, y: 0, width: 400, height: 246), "thread": CGRect(x: 0, y: 60, width: 360, height: 120)]
m.receive("hold", 500)
precondition(m.held == 500 && m.threadMax == 374 && sent.first?["boxH"] as? CGFloat == 374, "\(m.threadMax)")
m.receive("resizeDone", NSNull()); precondition(m.held == nil)
''')
        self.assertIn('let chrome = card - thread', self.box)   # header, composer and spacing as they are now, not a constant
        start = self.swift.index('            default:', self.swift.index('var sizing:'))
        self.assertIn('js("resizeDone")', self.swift[start:self.swift.index('            return nil', start)])

    def test_settings_disabled_segment_looks_off(self):
        seg = part(self.settings, 'struct Seg: View {', '\n}\n')
        self.assertIn('.opacity(disabled ? 0.4 : 1).allowsHitTesting(!disabled)', seg)
        setup = part(self.onboarding, 'private struct SetupSeg: View {', '\n}\n')
        self.assertIn('.allowsHitTesting(!disabled)', setup, 'a disabled setup segment still takes clicks')

    def test_small_leftovers(self):
        native_ui(self, r'''
let m = BoxModel(); m.receive("moveFailed", NSNull()); precondition(m.status == "Could not move" && !m.statusLive)   // a failure, not live work
''')
        self.assertNotIn('js("shortcut"', self.swift)
        self.assertNotIn('case "shortcut"', self.box)
        self.assertIn('ForEach(setupPages.filter { !m.skip($0) }', self.onboarding)   # Devin/Pi: no dots for skipped pages
        self.assertNotIn('These need your click', self.onboarding)
        self.assertNotIn('Use Verbatim instead', self.onboarding)
        self.assertIn('Btn(label: "← Privacy & Safety") { m.openSection("account") }', self.settings)   # Apps has its way back


if __name__ == '__main__':
    unittest.main()
