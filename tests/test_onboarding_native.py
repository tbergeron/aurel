"""The native setup model (Onboarding.swift) with a recording post: no app, window or user settings."""
import json
from pathlib import Path
import re
import unittest

from tests import native_ui

ROOT = Path(__file__).resolve().parents[1]
SETUP_SOURCE = (ROOT / 'Onboarding.swift').read_text()
VIEWS = SETUP_SOURCE[SETUP_SOURCE.index('// MARK: - Pieces'):]


def between(source, start, end):
    i = source.index(start)
    return source[i:source.index(end, i)]


def view(name):   # one type's source, up to its closing brace
    i = re.search(rf'struct {name}\b', SETUP_SOURCE).start()
    return SETUP_SOURCE[i:SETUP_SOURCE.index('\n}\n', i)]


# The views compute what they show in their bodies; these run those exact lines against the model.
KEY_FIELD = 'func keyField(_ m: OnboardingModel) -> [String] {\n' \
    + between(view('SetupKeyField'), '        let rec = m.recording, label', '        ZStack(alignment: .trailing) {') \
    + '    return [label.isEmpty ? text : capsOf(label).joined(), set ? "set" : ""]\n}\n'
ROW_OK = 'func rowOK(_ m: OnboardingModel, _ row: SetupRow) -> Bool {\n' + between(view('PermRowView'), '        let ok = ', '\n') + '\n    return ok\n}\n'
AGENTS_LEFT = 'func agentsLeft(_ m: OnboardingModel) -> Int {\n' + between(view('Agents'), '        let s = m.status', '        VStack(spacing: 0) {') + '    return left\n}\n' \
    + between(SETUP_SOURCE, '    func walkWhy(', '\n').replace('func walkWhy(', 'func walkWhy(_ m: OnboardingModel, ') + '\n'
DONE_MISSING = 'func missing(_ m: OnboardingModel) -> [String] {\n' + between(view('Done'), '        let s = m.status', '        let key = ') \
    + '    return [missing.joined(separator: ", "), voice ? "voice" : ""]\n}\n'
SETUP = r'''
var posts: [[String: String]] = []
let m = OnboardingModel(); m.post = { posts.append($0) }
func spin(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func done(_ result: Any) { print(String(data: try! JSONSerialization.data(withJSONObject: ["result": result, "posts": posts]), encoding: .utf8)!) }
func plan(_ ok: Bool, _ need: String, _ client: String, _ text: String) { m.receive("plan", [["ok": ok, "need": need, "client": client, "text": text]] as [Any]) }   // as Onboarding.call sends it
let every = ["mic", "speech", "ax", "screen", "auto", "calendar", "tools", "chrome"]
m.go("welcome")
'''


class OnboardingNativeTests(unittest.TestCase):
    def page(self, script, *helpers):
        out = native_ui(self, ''.join(helpers) + SETUP + script)
        return json.loads(out.strip().splitlines()[-1])

    def test_skip_all_stays_at_top_right_and_jumps_to_improve(self):
        out = self.page('''var landed: [String] = []
            for client in ["claude", "local"] {
                plan(true, "", client, "Ready")
                for p in setupPages.prefix(upTo: setupPages.firstIndex(of: "improve")!) { m.go(p); m.go("improve"); landed.append(m.cur) }   // Skip All
            }
            done(Array(Set(landed)))''')
        self.assertEqual(out['result'], ['improve'])
        self.assertNotIn({'do': 'done'}, out['posts'])   # it skips the tour, not the closing pages
        bar = between(view('OnboardingView'), 'HStack {', '}.padding(.horizontal, 22)')
        self.assertLess(bar.index('Spacer()'), bar.index('"Skip All"'))   # top right, after Back
        self.assertIn('if (setupPages.firstIndex(of: m.cur) ?? 0) < setupPages.firstIndex(of: "improve")! { PillButton(label: "Skip All", quiet: true, plain: true, height: 30, pad: 10) { m.go("improve") } }', bar)

    def test_every_permission_row_can_be_allowed_or_shows_its_check(self):
        for granted in (False, True):
            with self.subTest(granted=granted):
                out = self.page(f'''let on = {str(granted).lower()}
                    plan(on, on ? "" : "login", "claude", on ? "Ready with your Claude plan." : "Sign in to Claude Code to use your plan.")
                    m.receive("set", [Dictionary(uniqueKeysWithValues: every.map {{ ($0, on) }})] as [Any])
                    m.receive("connectors", [on ? ["connected": ["Gmail", "Drive"], "signin": [String]()] : ["connected": [String](), "signin": ["Notion"]]] as [Any])
                    let rows = permRows + ownRows + yourRows, oks = rows.map {{ rowOK(m, $0) }}
                    if !on {{ for r in rows {{ m.grant(r.id) }} }}
                    done([rows.map {{ $0.id }}, oks, [m.waiting.count]])''', ROW_OK)
                ids, oks, (waiting,) = out['result']
                self.assertEqual((len(ids[:7]), len(ids[7:])), (7, 7))   # setup's list, then the agents' two lists
                self.assertEqual(oks, [granted] * 14)
                self.assertEqual([p['id'] for p in out['posts'] if p['do'] == 'grant'], [] if granted else ids)
                self.assertEqual(waiting, 0 if granted else len(set(ids)))
        row = view('PermRowView')
        self.assertIn('if ok { CheckMark()', row)
        self.assertIn('.onTapGesture { if !(wait || now) { m.grant(row.id) } }', row)   # Waiting while System Settings is up
        self.assertIn('HStack(spacing: 6) { Text(wait || now ? "Waiting" : label); if wait || now { Spinner() } }', row)

    def test_plan_row_names_the_provider_and_offers_its_fix(self):
        out = self.page('''var seen: [[String]] = []
            plan(false, "upgrade", "claude", "Aurel needs a paid Claude plan (Pro or Max)."); seen.append([m.provider, m.planNeed, m.planText])
            plan(false, "download", "local", "Download the local model in Settings → Intelligence."); seen.append([m.provider, m.planNeed, m.planText])
            done(seen)''')
        self.assertEqual(out['result'], [['claude', 'upgrade', 'Aurel needs a paid Claude plan (Pro or Max).'],
                                         ['local', 'download', 'Download the local model in Settings → Intelligence.']])
        perms = view('Perms')
        self.assertIn('label: ["install": "Install", "login": "Sign In", "upgrade": "Upgrade", "download": "Download"][m.planNeed] ?? "Allow"', perms)
        self.assertIn('name: m.provider == "claude" ? "Claude Plan" : "Local Model", why: m.planText) { m.pick = m.provider; withAnimation(eased(0.25)) { m.sheet = true } }', perms)
        self.assertIn('SetupRow(id: "claude", name: "AI Provider", why: "Checking…"', SETUP_SOURCE)   # no client named before the check

    def test_provider_choice_saves_and_ignores_a_stale_check(self):
        out = self.page('''plan(false, "upgrade", "claude", "old"); m.pick = m.provider; m.sheet = true   // Change provider opens on the current one
            let opened = m.pick
            m.pick = "local"; m.useProvider()
            let saved = [m.sheet ? "sheet" : "", m.provider, m.planText]
            plan(false, "upgrade", "claude", "old Claude check"); let stale = m.planText
            plan(false, "download", "local", "Download the local model in Settings → Intelligence.")
            done([[opened], saved, [stale, m.planText]])''')
        self.assertEqual(out['result'], [['claude'], ['', 'local', 'Checking…'], ['Checking…', 'Download the local model in Settings → Intelligence.']])
        self.assertEqual(out['posts'], [{'do': 'provider', 'client': 'local'}])
        sheet = view('ProviderSheet')
        self.assertIn('.onExitCommand { close() }', sheet)   # Escape cancels without saving
        self.assertNotIn('post', between(SETUP_SOURCE, '    func close() {', '\n'))
        self.assertIn('PillButton(label: "Use " + (m.pick == "local" ? "Local" : "Claude")', sheet)

    def test_agents_step_asks_for_connectors_and_shows_live_status(self):
        out = self.page('''m.go("agents"); let local = m.cur
            plan(true, "", "claude", "Signed in."); m.go("agents")
            m.receive("set", [["mic": true, "speech": true, "ax": true, "screen": false, "auto": true, "chrome": false, "calendar": true, "tools": true]] as [Any])
            m.receive("connectors", [["connected": ["Gmail"], "signin": ["Notion"]]] as [Any])
            let some = [m.connText, "\\(agentsLeft(m))"]
            m.receive("walk", ["screen"] as [Any])
            let walking = [walkWhy(m, yourRows[1], own: false), walkWhy(m, yourRows[0], own: false)]
            m.receive("walk", ["chrome"] as [Any]); let own = walkWhy(m, ownRows[1], own: true)
            m.receive("set", [Dictionary(uniqueKeysWithValues: every.map { ($0, true) })] as [Any]); m.receive("walk", [""] as [Any])
            done([[local], some, walking, [own], ["\\(agentsLeft(m))", m.walking ?? "none"]])''', AGENTS_LEFT)
        local, some, walking, own, after = out['result']
        self.assertEqual(local, ['try'])   # Local has no background agents
        self.assertEqual(some, ['Gmail connected · 1 need sign-in', '2'])   # Screen Recording and Chrome
        self.assertEqual(walking, ['Turn on Aurel in System Settings.', 'Clicks and types in apps for an agent.'])
        self.assertEqual(own, ['Turning it on…'])
        self.assertEqual(after, ['0', 'none'])
        self.assertEqual(out['posts'], [{'do': 'connectors'}])   # only for Claude
        agents = view('Agents')
        self.assertIn('PillButton(label: left > 0 ? "Skip for Now" : "Continue", quiet: left > 0) { m.go("try") }', agents)
        self.assertIn('if left > 0 { PillButton(label: m.walking != nil ? "Enabling…" : "Enable All", disabled: m.walking != nil) { m.post(["do": "enableAll", "connected": String(m.connected)]) } }', agents)

    def test_try_next_waits_for_the_shortcut(self):
        out = self.page('''m.receive("keys", ["⌃⌥"] as [Any]); m.receive("tried", [Any]()); let early = [m.held, m.tried ? "tried" : ""]
            m.go("try"); m.receive("keys", ["⌃⌥"] as [Any]); let held = m.held
            m.receive("tried", [Any]()); m.receive("keys", ["⌃"] as [Any])
            done([early, [held], [m.held, m.tried ? "tried" : ""]])''')
        self.assertEqual(out['result'], [['', ''], ['⌃⌥'], ['', 'tried']])   # only the try page reacts, and only until it worked
        self.assertIn('if m.tried { PillButton(label: "Next") { m.go("mac") } } else { PillButton(label: "Skip", quiet: true) { m.go("mac") } }', view('Try'))

    def test_dictation_starts_unset_and_records_in_place(self):
        out = self.page('''let P0: [String: Any] = ["draw": true, "routing": "balanced", "dictateMode": "verbatim", "dictateHotkeyLabel": ""]
            m.go("dictate"); m.receive("prefs", [P0] as [Any]); let start = keyField(m)
            m.toggleRecord(); let typing = keyField(m)
            m.receive("rec", ["⌃⌥"] as [Any]); m.receive("prefs", [P0] as [Any]); let held = keyField(m)   // the every-second refresh leaves a recording alone
            m.receive("taken", ["dictate", false] as [Any]); m.receive("recorded", [""] as [Any]); let clash = keyField(m) + [m.dcWarn ?? ""]
            m.toggleRecord(); m.receive("recorded", ["⌃⌥D"] as [Any]); let recorded = keyField(m)
            m.set("dictateMode", "cleanup")
            done([start, typing, held, clash, recorded])''', KEY_FIELD)
        start, typing, held, clash, recorded = out['result']
        self.assertEqual(start, ['Record Shortcut', ''])
        self.assertEqual(typing, ['Type Shortcut', ''])
        self.assertEqual(held, ['⌃⌥', ''])
        self.assertEqual(clash[:2], ['Record Shortcut', ''])   # a clash warns in place and keeps the old shortcut
        self.assertIn('Another app', clash[2])
        self.assertEqual(recorded, ['⌃⌥D', 'set'])
        self.assertEqual([p['do'] for p in out['posts']], ['recordDictate', 'recordDictate', 'set'])
        self.assertIn({'do': 'set', 'k': 'dictateMode', 'v': 'cleanup'}, out['posts'])
        page = view('DictatePage')
        self.assertIn('.opacity(key.isEmpty ? 0.45 : 1)', page)   # its mode greys out until there is a shortcut
        self.assertIn('hint: m.dcWarn ?? (rec ?', page)
        self.assertIn('.onTapGesture { m.prefs["dictateHotkeyLabel"] = ""; m.post(["do": "clearDictate"]) }', view('SetupKeyField'))
        self.assertIn('if m.pbool("globeTaken") {', page)
        self.assertIn('m.post(["do": "globeKey"])', page)

    def test_leaving_mid_recording_cancels_it(self):
        out = self.page('m.go("dictate"); m.toggleRecord(); m.go("point"); done([m.cur])')
        self.assertEqual(out['result'], ['point'])
        self.assertEqual([p['do'] for p in out['posts']], ['recordDictate', 'cancelRecord'])

    def test_clicking_away_cancels_dictation_recording(self):
        # The page posted cancelRecord on any click outside the field while recording
        native_ui(self, r'''
let m = OnboardingModel(); var posts: [[String: String]] = []; m.post = { posts.append($0) }
m.recField = CGRect(x: 250, y: 300, width: 140, height: 28)
m.clicked(CGPoint(x: 10, y: 10)); precondition(posts.isEmpty, "a click cancelled a recording that was not running")
m.toggleRecord(); m.clicked(CGPoint(x: 260, y: 310)); precondition(posts.count == 1, "a click in the field cancelled")
m.clicked(CGPoint(x: 10, y: 10)); precondition(posts.last?["do"] == "cancelRecord", "a click away kept recording")
''')
        self.assertIn('.simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("setup")).onEnded { m.clicked($0.location) })', VIEWS)

    def test_local_skips_agents_and_work_and_back_returns_past_them(self):
        out = self.page('''var path: [String] = []
            plan(true, "", "local", "Using the local model on this Mac.")
            m.go("point"); m.go("work"); path.append(m.cur); m.back(); path.append(m.cur)
            m.go("try"); m.back(); path.append(m.cur)
            plan(true, "", "claude", "Signed in."); m.go("work"); path.append(m.cur)
            done(path)''')
        self.assertEqual(out['result'], ['improve', 'point', 'perms', 'work'])
        self.assertIn('ForEach(setupPages.filter { !m.skip($0) }', view('Dots'))

    def test_feature_pages_show_what_they_teach(self):
        page = view('PageView')
        self.assertIn('click it to open that window', page)   # the mini screen opens its window on click (README)
        self.assertNotIn('ask to focus it', SETUP_SOURCE)
        self.assertIn('Run apps, arrange windows and play music in the background.', page)
        self.assertIn('whiteboard', between(page, 'case "point":', 'case "work":'))
        self.assertIn('m.prefs["draw"] = !m.pbool("draw"); m.post(["do": "set", "k": "draw", "v": String(m.pbool("draw"))])', page)
        self.assertIn('if m.prefs["safe"] as? Bool != false { Note(s: "Safe mode is on', page)   # the line shows only while Safe mode is on
        self.assertEqual(len(re.findall(r'\("[^"]+", "', between(SETUP_SOURCE, 'private let dcExamples', '\nprivate func'))), 5)
        for example in ('Scratch that', 'New line'):
            self.assertIn(f'("{example}", ', SETUP_SOURCE)
        work = view('WorkPage')
        self.assertIn('⌃⌥↩', work)
        self.assertIn('Haiku for every ask. Fastest, and uses the least of your plan.', work)
        self.assertIn('Haiku for quick asks.', work)
        self.assertIn('{ m.set("routing", $0) }', work)
        self.assertNotIn('longAsks', SETUP_SOURCE)   # long asks always move: no setting
        improve = view('Improve')
        self.assertIn('Anonymous', improve)
        self.assertIn('PillButton(label: "Help Improve") { m.post(["do": "set", "k": "improve", "v": "true"]); m.go("done") }', improve)   # the main action
        self.assertIn('PillButton(label: "Not Now", quiet: true)', improve)

    def test_done_page_says_what_is_missing_and_ends_setup(self):
        out = self.page('''var seen = [missing(m)]
            m.receive("set", [["mic": true, "speech": true]] as [Any]); plan(true, "", "claude", "Ready"); seen.append(missing(m))
            m.receive("set", [Dictionary(uniqueKeysWithValues: every.map { ($0, true) })] as [Any]); seen.append(missing(m))
            done(seen)''', DONE_MISSING)
        self.assertEqual(out['result'], [['AI provider, Microphone, Speech Recognition, Accessibility', ''], ['Accessibility', 'voice'], ['', 'voice']])
        self.assertTrue(re.search(r'let setupPages = \[[^\]]+, "done"\]', SETUP_SOURCE))   # setup ends on things to try
        done = view('Done')
        self.assertIn('let shown = ideas.indices.filter { ideas[$0].2 != "DICTATE" || !key.isEmpty }', done)   # no dictation shortcut, no dictation idea
        self.assertEqual(len(re.findall(r'^    \(0x', between(SETUP_SOURCE, 'private let ideas', '\n]'), re.M)), 15)
        self.assertIn('“Convert this JPEG to PNG”', SETUP_SOURCE)
        self.assertIn('Text("Be great.")', done)
        self.assertIn('PillButton(label: voice ? "Start Using Aurel" : "Finish Setup Later") { m.post(["do": "done"]) }', done)

    def test_reduce_motion_shows_the_final_previews(self):
        for stage, final in (('MacStage', 'if reduce { snapped = true; play = true; box = true; return }'),
                             ('TextStage', 'if reduce { box = true; sel = true; return }'),
                             ('DictateStage', 'if reduce || !run { if reduce { show(at) }; return }'),
                             ('PointStage', 'if reduce { wb = true; step = 3; return }'),
                             ('WorkStage', 'if reduce { line = "I started an agent. I’ll ping you when it’s done."; box = true; chip = true; return }')):
            self.assertIn(final, view(stage))
        self.assertIn('guard on, !m.reduce else {', view('Welcome'))   # no welcome key loop
        self.assertIn('OrbRep(running: on && !m.reduce)', view('Welcome'))   # the orb renders once
        self.assertIn('guard on, !m.reduce else { hi = -1; return }', view('Done'))

    def test_reduce_motion_follows_a_change_while_setup_is_open(self):
        # The page listened for prefers-reduced-motion changes and jumped every preview to its last frame. OnboardingModel reads it once.
        aurel = (ROOT / 'Aurel.swift').read_text()
        onboarding = aurel[aurel.index('final class Onboarding:'):aurel.index('\n}\n', aurel.index('final class Onboarding:'))]
        self.assertTrue('accessibilityDisplayOptionsDidChangeNotification' in SETUP_SOURCE + onboarding or 'reduce = ' in onboarding,
                        'setup never updates m.reduce after it opens')

    def test_setup_controls_have_accessible_names(self):
        # The page's switches and choices were labelled inputs and buttons. The native ones are tap-only shapes.
        for name in ('SetupSwitch', 'SetupSeg'):
            with self.subTest(control=name):
                self.assertTrue('.accessibility' in view(name), f'{name} has no accessibility label, value or traits')


if __name__ == '__main__':
    unittest.main()
