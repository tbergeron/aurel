"""The native box (Box.swift's BoxModel) driven the way the app drives it: the calls the page took, the posts it sent back.
No window opens; what only a SwiftUI view decides is checked in its source, as these tests always did for the page."""
import re
import unittest
from pathlib import Path

from tests import native_ui

ROOT = Path(__file__).resolve().parents[1]
BOX = (ROOT / 'Box.swift').read_text()

# A BoxModel with its posts and scroll requests recorded, and the answer read back as the page's textContent was.
PRELUDE = r'''
let m = BoxModel()
var posts: [[String: Any]] = []
m.post = { posts.append($0) }
var scrolls: [(UUID?, Bool)] = []
m.scrollTo = { scrolls.append(($0, $1)) }
func ui(_ call: String, _ v: Any = NSNull()) { m.receive(call, v) }
func line(_ l: String) { ui("line", l) }
var turn: Turn { m.turns.last! }
func wait(_ s: Double) { RunLoop.main.run(until: Date() + s) }
func json(_ o: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
// marks: true keeps **bold**, `code` and [links](url) as written; a formula reads ⟨tex⟩ either way
func render(_ items: [Inline], _ marks: Bool) -> String {
    items.map { x -> String in
        switch x {
        case .text(let s): return s
        case .code(let s): return marks ? "`\(s)`" : s
        case .strong(let k): return marks ? "**\(render(k, marks))**" : render(k, marks)
        case .em(let k): return marks ? "_\(render(k, marks))_" : render(k, marks)
        case .link(let l, let u): return marks ? "[\(l)](\(u))" : l
        case .math(let t): return "⟨\(t)⟩"
        case .br: return "\n"
        }
    }.joined()
}
func render(_ blocks: [MDBlock], _ marks: Bool = false) -> String {
    blocks.map { b -> String in
        switch b {
        case .para(let i), .heading(let i): return render(i, marks)
        case .list(_, _, let items): return items.map { render($0, marks) }.joined(separator: "\n")
        case .pre(let s): return s
        case .table(let h, let rows): return ([h] + rows).map { $0.map { render($0, marks) }.joined(separator: " ") }.joined(separator: "\n")
        case .hr: return ""
        case .math(let t): return "⟨\(t)⟩"
        }
    }.joined(separator: "\n")
}
func words(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
var shown: String { words(render(turn.aBlocks)) }
func kind(_ b: MDBlock) -> String {
    switch b { case .para: "p"; case .heading: "h"; case .list(let o, _, _): o ? "ol" : "ul"; case .pre: "pre"; case .table: "table"; case .hr: "hr"; case .math: "math" }
}
var cards: [Card] { m.turns.flatMap { $0.parts.compactMap { if case .card(let c) = $0, !c.gone { return c }; return nil } } }
var clocks: [UUID] { turn.parts.compactMap { if case .clock(let id) = $0 { return id }; return nil } }
var picks: [String] { posts.compactMap { $0["pick"] as? String } }
func posted(_ key: String) -> [Any] { posts.compactMap { $0[key] } }
'''
AGENT = r'''
var agent: (title: String, answer: [MDBlock], learned: String?, acts: [KeyAction], cost: String?)? {
    for c in cards { if case .agent(_, let t, let a, let l, _, let acts, let cost, _) = c.kind { return (t, a, l, acts, cost) } }
    return nil
}
func act(_ go: Bool) -> KeyAction? { agent?.acts.first { go ? $0.go : $0.esc } }
'''


class BoxNativeTests(unittest.TestCase):
    def box(self, checks, *args, **kw):
        return native_ui(self, PRELUDE + checks, *args, **kw)

    def test_quiet_follow_up_only_changes_status(self):
        self.box(r'''
ui("listen"); ui("words", "First ask"); ui("think"); line("✓ An answer to read."); ui("finished")
let before = m.turns.map { $0.parts.map(\.id) }, orb = m.orbState
ui("quietListen", true)
precondition(m.hf && m.status == "" && !m.hearing && m.orbState == orb, "hands-free: Listening... by the timer, nothing else changes")
ui("quietListen", false)
precondition(!m.hf && m.turns.map { $0.parts.map(\.id) } == before, "its timeout leaves the box as it was")
ui("quietListen", true); ui("listen"); ui("words", "And these words")
precondition(!m.hf && turn.q == "And these words", "words arriving start a real turn")
''')
        self.assertIn('if m.hf { HfDots()', BOX)   # Listening… sits in the timer row

    def test_a_step_that_is_the_answer_shows_once(self):
        self.box(r'''
ui("listen"); ui("words", "Open Muse"); line("▸ Opened Muse."); line("✓ Opened Muse.")
precondition(turn.steps.isEmpty && turn.aAnswer == "Opened Muse.", "Opened Muse. showed as a step and as the answer")
ui("listen"); ui("words", "Open Muse and say hi"); line("▸ Opened Muse."); line("✓ Sent hi in Muse.")
precondition(turn.steps.map(\.text) == ["Opened Muse."], "a step that is not the answer was dropped")
''')

    def test_streamed_links_and_math_wait_until_they_close(self):
        self.box(r'''
ui("listen"); ui("words", "what is it"); ui("think")
line("… See [1] and a[0]\u{2028}- [ ] a task and")
precondition(turn.aBlocks.map { words(render([$0])) } == ["See [1] and a[0]", "[ ] a task"], "a bracket that is no link shows at once: \(shown)")
line("… "); line("… It [the link](https://x.co"); precondition(shown == "It", "a link still arriving waits: \(shown)")
line("… It [the link](https://x.co) and"); precondition(words(render(turn.aBlocks, true)) == "It [the link](https://x.co)", "then shows as a link")
line("✓ It [the link](https://x.co) and more."); precondition(shown == "It the link and more." && turn.aKind == "normal", "the final reply")
ui("listen"); ui("words", "area"); ui("think")
var math: [String] = []
for s in ["the area is $", "the area is $\\pi r", "the area is $\\pi r^2", "the area is $\\pi r^2$ cm", "the area is $\\pi r^2$ cm and costs $5 today"] { line("… " + s); math.append(shown) }
precondition(math[0...2].allSatisfy { $0 == "the area is" }, "math still arriving waits, never a raw $: \(math)")
precondition(math[3] == "the area is ⟨\\pi r^2⟩", "then shows as a formula: \(math[3])")
precondition(math[4] == "the area is ⟨\\pi r^2⟩ cm and costs $5", "a price shows at once: \(math[4])")
''')

    def test_agent_done_card_leads_with_the_answer_and_offers_its_keys(self):
        self.box(AGENT + r'''
ui("agentDone", ["id": "x", "title": "Compare phones", "status": "done", "result": "Found **three** phones [1].", "summary": ""])
precondition(agent?.title == "Compare phones" && words(render(agent!.answer)) == "Found three phones [1]." && agent!.acts.map(\.label).contains("Later"), "the card: title, answer, Later")
ui("agentDone", ["id": "setup", "title": "Set up focus time", "summary": "Ready.", "learned": "focus time"])
precondition(cards.count == 1 && agent?.learned == "focus time", "a learned phrase rides on its card (Say “focus time” any time.)")
ui("agentDone", ["id": "other", "title": "Other task", "summary": "Done."]); precondition(agent?.learned == nil, "and never on the next one")

ui("reset"); ui("listen", true); ui("think")
let row: [String: Any] = ["id": "11111111111111111111111111111111", "title": "Prepare report", "summary": "Made the report."], id = row["id"] as! String
func with(_ more: [String: Any]) -> [String: Any] { row.merging(more) { $1 } }
ui("agentDone", row)
precondition(act(true)?.label == "Details" && act(true)?.key == "↩" && act(false)?.label == "Later" && act(false)?.key == "esc", "nothing made: Details ↩ and Later esc")
precondition(posted("agentDefault").contains { $0 as? Bool == true }, "an actionable card registers the native Return default")
m.ask = "Draft"; ui("agentDefaultAction"); precondition(posted("agentOpen").isEmpty, "native Return keeps a typed draft")
m.ask = ""; ui("agentDefaultAction"); precondition(posted("agentOpen").contains { $0 as? String == id }, "native Return opens the finished agent")
precondition(posted("agentDefault").contains { $0 as? Bool == false }, "and the default goes with its card")
ui("agentCount", 2); precondition(m.agents == 2 && !m.agentsAttention, "running agents: a header badge")
ui("agentCount", ["count": 1, "attention": true]); precondition(m.agents == 1 && m.agentsAttention, "amber when an agent needs you")
ui("agentCount", 0); precondition(m.agents == 0, "no agents, no badge")
m.ask = "Keep this draft"; ui("agentDone", with(["summary": "The report is ready.", "cost": 0.012, "links": ["/tmp/result.csv"]]))
precondition(m.ask == "Keep this draft", "a done card keeps typed text")
precondition(act(true)?.label == "Open" && act(false)?.label == "Later" && agent?.cost == "≈1.20¢ at API prices", "Open ↩ / Later esc with its cost, as Usage shows it")
m.ask = ""; posts = []; ui("agentDefaultAction")
precondition(posts.contains { $0["agentOpen"] as? String == id && $0["target"] as? String == "/tmp/result.csv" }, "Return opens what the agent made")
ui("agentDone", with(["summary": "Done."])); ui("agentEscape")
precondition(posted("agentLater").contains { $0 as? String == id } && agent == nil, "Esc picks Later")
ui("agentEscape"); precondition(!posted("agentGone").isEmpty, "Esc without a card hands back to the box")
ui("agentDone", with(["summary": "Short.", "result": "Three picks:\n\n| Desk | Price |\n|---|---|\n| E7 | $480 |\n\n[agent-result {\"summary\":\"Short.\"}]"]))
precondition(agent!.answer.map(kind) == ["p", "table"] && render(agent!.answer).contains("E7") && !render(agent!.answer).contains("agent-result"), "the full answer leads, tables and all")
// the app sends missingConnector as the connector's name (aurel.py), "" when none is missing
ui("agentDone", with(["missingConnector": "Requested connector", "summary": "Connect the requested account to continue."]))
precondition(act(true)?.label == "Connect in Claude", "a missing connector offers the user's own Claude connectors: \(act(true)?.label ?? "-")")
m.tapAction(act(true)); precondition(!posted("agentConnect").isEmpty, "Connect uses the native link action")
''')

    def test_native_pointer_tints_what_it_is_over_and_asks_for_the_hand(self):
        # The panel never activates: native tracking calls pointer(); the smallest target under it decides the cursor.
        self.box(r'''
m.targets = [TargetEntry("card", CGRect(x: 0, y: 0, width: 200, height: 200), false, .area), TargetEntry("later", CGRect(x: 10, y: 10, width: 60, height: 28), true, .button {})]
precondition(m.pointer(CGPoint(x: 20, y: 20), overX: false) && m.hot == ["card", "later"] && m.bodyHot, "over a card button: the hand, the button and its card tinted")
precondition(!m.pointer(nil, overX: false) && m.hot.isEmpty && !m.bodyHot, "off the box: arrow, no tint")
precondition(m.pointer(CGPoint(x: 20, y: 20), overX: true) && m.hot == ["x"], "native's × corner lights only the ×")
''')

    def test_agent_starts_and_steers_answer_in_one_line_in_order(self):
        self.box(r'''
ui("reset"); ui("listen", true); ui("words", "Find three standing desks"); ui("think"); ui("agentStarted", ["id": "a1", "title": "Standing desks", "status": "running"])
precondition(m.status == "Agent started" && !m.statusLive && turn.aText == "I started an agent on “Standing desks”. I’ll ping you when it’s done." && turn.aKind == "ack" && turn.aOrb, "starting an agent says so plainly beside its orb")
ui("reset"); ui("listen", true); ui("think"); ui("agentStarted", ["id": "a1", "title": "Standing desks", "status": "queued"])
precondition(m.status == "Agent queued" && turn.aText.hasPrefix("Queued an agent"), "a queued agent says it waits its turn")
ui("reset"); ui("listen", true); ui("words", "Only include products under $200"); ui("think")
ui("agentSteered", ["id": "11", "title": "Prepare report", "steer": ["text": "Only include products under $200."]])
precondition(turn.aText == "Told the Prepare report agent: Only include products under $200." && turn.aOrb, "steering answers with the agent's orb and the exact correction")
ui("listen"); ui("agentSteered", ["id": "b1", "title": "Ebikes", "steer": ["text": "under $1500"]]); ui("agentStarted", ["id": "c1", "title": "Bike locks", "status": "running"])
precondition(turn.aText == "Told the Ebikes agent: under $1500. I started an agent on “Bike locks”. I’ll ping you when it’s done.", "one ask, both parts, in order: \(turn.aText)")
ui("listen"); ui("agentStarted", ["id": "c1", "title": "Ebikes", "status": "running"]); ui("agentStarted", ["id": "d1", "title": "Helmets", "status": "queued"])
precondition(turn.aText == "I started an agent on “Ebikes”. I’ll ping you when it’s done. Queued an agent for “Helmets”. It starts when another one finishes.", "the queued one is not called started: \(turn.aText)")
ui("listen"); for (k, t, s) in [("e1", "Tents", "queued"), ("f1", "Stoves", "running"), ("g1", "Maps", "running")] { ui("agentStarted", ["id": k, "title": t, "status": s]) }
precondition(turn.aText == "Queued an agent for “Tents”. It starts when another one finishes. I started agents on “Stoves” and “Maps”. I’ll ping you when they’re done.", turn.aText)
''')

    def test_dismissing_an_old_agent_card_keeps_the_foreground_timer(self):
        # AgentPanels.tick cancels a previous done card while the box is busy or listening: its timer and status must stay.
        self.box(r'''
for mode in ["typed", "voice-step", "voice-stream", "approval"] {
    ui("reset"); ui("agentDone", ["id": "a1", "title": "Earlier task", "status": "done", "result": "Finished."])
    ui("listen", mode == "typed"); ui("words", "Explain the result")
    if mode == "typed" || mode == "approval" { ui("think") } else { line(mode == "voice-step" ? "▸ Reading the request" : "… Here is the explanation and") }
    let timer = clocks; precondition(timer.count == 1 && m.clockStart != nil, "\(mode): a running timer before the card goes")
    if mode == "approval" { ui("ask", ["Continue?", "echo preview"]) }
    let status = m.status
    ui("agentCancelled")
    precondition(!cards.contains { if case .agent = $0.kind { return true }; return false } && m.status == status, "\(mode): the card goes, the status stays")
    if mode == "approval" {
        precondition(m.clockStart == nil && m.clockHeld != nil, "waiting for approval is not work")
        m.answerApproval(cards[0].id, true)
    }
    precondition(m.clockStart != nil, "\(mode): the timer runs")
    ui("think"); line("▸ Explaining the result"); line("… Here is the explanation and")
    precondition(clocks == timer && m.clockStart != nil, "\(mode): one timer, the same one, still running")
    if mode == "voice-stream" { ui("stopped", "Answer stopped") } else { line("✓ Explained."); ui("finished") }
    precondition(m.clockStart == nil && m.clockFinal != nil, "\(mode): a finished or stopped timer stops")
}
''')

    def test_each_new_ask_gets_one_timer_and_a_live_step(self):
        self.box(r'''
ui("listen", true); ui("words", "Earlier ask"); ui("think"); line("✓ Earlier answer")
ui("dictate", true); ui("listen", "dict"); ui("finishing", ""); ui("dictated", ["text": "", "ok": true])
ui("listen"); ui("dictate", false); ui("words", "Why is the sky blue?"); ui("think"); line("▸ Thinking it through")
precondition(m.turns.count == 2 && turn.q == "Why is the sky blue?" && clocks.count == 1 && turn.steps.map(\.text) == ["Thinking it through"], "a dictation in between: the new ask still gets its own turn, timer and step")
ui("reset")
for i in 0..<10 {
    ui("listen", true); ui("words", i == 1 ? "Save it as a shortcut" : "Change the setting")
    if i % 2 == 0 { ui("think") }   // instant or speculative work can send a step before think()
    line("▸ Changing the setting")
    precondition(clocks.count == 1 && m.clockStart != nil && turn.steps.last?.state == "live", "turn \(i): a live step with its timer running")
    ui("think"); precondition(clocks.count == 1, "turn \(i): a later think keeps the timer")
    line("… The setting is changed and"); precondition(clocks.count == 1 && m.clockStart != nil, "turn \(i): the timer row stays while the answer streams")
    line("✓ Changed the setting."); if i == 1 { line("i Learned: change the setting") }; ui("finished")
    precondition(m.clockStart == nil && m.clockFinal != nil, "turn \(i): done, the timer stops")
    if i > 0 { precondition(m.turns.dropLast().allSatisfy { $0.clock != nil }, "turn \(i): earlier turns keep their own finished time") }
}
''')

    def test_minimize_keeps_live_work(self):
        self.box(r'''
ui("listen", true); ui("words", "Explain"); ui("think"); ui("mode", false)
line("… " + String(repeating: "A long answer. ", count: 300))
m.foldBox(true)   // the fold button
precondition(m.folded && !m.compOpen && m.safeOff, "minimized")
line("▸ Reading the document"); precondition(m.status == "Reading the document" && m.folded, "the status line keeps working")
m.tap(CGPoint(x: 30, y: 20)); ui("hover", true); precondition(m.folded && !m.compOpen, "a click or hover keeps it minimized")
_ = m.pointer(CGPoint(x: 10, y: 10), overX: false); precondition(m.bodyHot, "the pointer over it shows the expand button"); _ = m.pointer(nil, overX: false)
line("✓ " + String(repeating: "Finished. ", count: 300)); ui("finished"); precondition(m.folded && m.status.isEmpty, "the answer lands without opening it (its status reads Done)")
m.foldBox(false); precondition(!m.folded, "expand")
m.foldBox(true); ui("listen"); precondition(!m.folded, "a new ask opens it")
m.foldBox(true); ui("compose", true); precondition(!m.folded, "the typing shortcut opens it")
''')
        self.assertIn('let s = m.status.isEmpty && m.folded ? "Done" : m.status', BOX)
        self.assertIn('if !m.folded || m.bodyHot {', BOX)   # the fold button shows on a minimized box only under the pointer
        head = BOX[BOX.index('private struct Head: View'):BOX.index('private struct StatusLine')]
        # minimized, the page showed only the orb, status, fold and ×: the agents badge and Full access hid
        for chip in ('m.agents > 0', 'm.safeOff'):
            with self.subTest(chip=chip):
                self.assertTrue(re.search(r'if [^{]*' + re.escape(chip) + r'[^{]*folded', head), f'the {chip} chip hides while minimized')

    def test_picker_renders_answers_and_accepts_spoken_other(self):
        self.box(r'''
ui("listen"); ui("words", "choose"); ui("think")
ui("pick", ["q": "**Which** $x^2$?", "options": [["label": "**Answer** $\\frac{1}{2}$ <img src=x onerror=alert(1)>", "sub": ""]]])
guard case .pick(let q, let options, _) = cards[0].kind else { fatalError("no choices card") }
precondition(render(q, true) == "**Which** ⟨x^2⟩?", "the question renders bold and math: \(render(q, true))")
precondition(render(parseMarkdown(options[0].label), true) == "**Answer** ⟨\\frac{1}{2}⟩ <img src=x onerror=alert(1)>", "so does a choice, and markup in it stays text")
precondition(m.respond("use a different answer") && cards.isEmpty, "the main box answers it as Something else")
precondition(picks == ["=use a different answer"], "\(picks)")
''')
        card = BOX[BOX.index('private struct PickCard'):BOX.index('private struct OtherField')]
        self.assertIn('AnswerView(blocks: q,', card)
        self.assertIn('AnswerView(blocks: parseMarkdown(o.label)', card)   # never HTML: a label is Markdown drawn as text

    def test_talking_over_a_picker_hides_it_and_cancel_brings_it_back(self):
        self.box(r'''
ui("listen"); ui("words", "choose"); ui("think")
ui("pick", ["q": "Which?", "options": [["label": "Blue", "sub": ""], ["label": "Red", "sub": ""]]])
func reply() -> String? { for t in m.turns { for p in t.parts { if case .qReply(_, let w, _) = p { return w } } }; return nil }
let id = cards[0].id
ui("pickHear", ""); ui("pickHear", "the red")
precondition(m.turns.flatMap(\.parts).contains { if case .card(let c) = $0 { return c.id == id && c.hidden }; return false }, "talking hides the card")
precondition(reply() == "the red" && m.status == "Listening…" && m.ask.isEmpty, "what you say shows as your reply")
ui("pickHear")
guard case .pick(_, let options, _) = cards[0].kind else { fatalError() }
precondition(!cards[0].hidden && reply() == nil && m.status == "Waiting for you" && options.count == 2, "cancel brings the card back")
ui("pickHear", ""); ui("pickHear", "the red one")
precondition(m.respond("the red one") && cards.isEmpty && reply() == nil && picks == ["=the red one"], "a spoken answer picks Something else: \(picks)")
''')

    def test_typing_box_opens_on_hover_and_keeps_a_draft(self):
        self.box(r'''
ui("listen"); precondition(!m.compOpen, "voice starts with the typing box hidden")
ui("hover", true); precondition(m.compOpen, "hover reveals it")
ui("hover", false); precondition(!m.compOpen, "leaving collapses an untouched one")
ui("hover", true); m.askFocused = true; ui("hover", false); precondition(m.compOpen, "focused typing stays open on mouse exit")
m.ask = "Keep my draft"; m.askFocused = false; ui("hover", false); precondition(m.compOpen, "a typed draft survives mouse exit and blur")
ui("models", ["list": ["cheapest", "balanced", "capable"], "pick": "balanced"])
precondition(m.modelName(m.modelPick) == "Balanced" && m.modelName("capable") == "Most capable", "the same intelligence choices as Settings")
ui("models", ["list": ["haiku", "sonnet", "opus"], "pick": "haiku"]); precondition(m.models.count == 3 && m.modelName(m.modelPick) == "Haiku", "the current model")
ui("models", ["list": [String](), "pick": ""]); precondition(m.models.isEmpty, "no model chip for a client without one")
ui("draft", "Please check these partial words"); precondition(m.ask == "Please check these partial words" && m.compOpen && m.focusAsk > 0, "unconfirmed speech is editable and focused")
''')
        comp = BOX[BOX.index('private struct Composer'):BOX.index('let micGlyphBox')]
        self.assertIn('if !m.models.isEmpty && !m.pickRow', comp)
        pick = comp[comp.index('m.modelPick = v'):comp.index('.transition(.scale(scale: 0.9')]
        self.assertTrue('accessibilityDisplayShouldReduceMotion' in pick, 'Reduce Motion: the pick closes the row at once, no 0.17 s beat')

    def test_listening_thinking_and_the_timer(self):
        self.box(r'''
ui("listen")
precondition(m.turns.count == 1 && m.status == "Listening…" && turn.qHear && turn.qEmpty, "listening: one turn, its bubble says Listening…")
ui("words", ""); precondition(turn.qEmpty && turn.qHear, "empty speech keeps the Listening bubble")
line("· Preparing a response"); precondition(m.status == "Listening…", "early reasoning keeps Listening")
ui("words", "Open Notes"); precondition(!turn.qEmpty && clocks.isEmpty, "speaking does not count as response time")
ui("think"); precondition(clocks.count == 1 && m.clockStart != nil && m.status == "Thinking…", "sending: Thinking, and the timer starts")
wait(0.07); let t = m.clockText(CACurrentMediaTime())
precondition(t.range(of: #"^\d+\.\d{2} s$"#, options: .regularExpression) != nil && Double(t.dropLast(2))! > 0, "it counts in hundredths: \(t)")
ui("think"); precondition(clocks.count == 1, "thinking again keeps one timer")
line("✓ Notes is open."); let done = m.clockText(CACurrentMediaTime()); wait(0.07)
precondition(m.clockText(CACurrentMediaTime()) == done, "completion freezes it")
ui("listen", true); ui("words", "Worker completion"); ui("think"); ui("finished")
precondition(m.clockStart == nil && m.clockFinal != nil, "a worker exit freezes it even without an answer")
ui("reset"); ui("listen", true); ui("words", "Find tablecloths"); ui("think")
for s in ["Scrolling down", "Scrolling down 2 pages", "Reading the page"] { line("▸ " + s) }
precondition(turn.steps.map(\.text) == ["Scrolling down 2 pages", "Reading the page"], "steps of one kind share one updating row: \(turn.steps.map(\.text))")
line("✓ Here are tablecloths."); precondition(turn.redo, "the latest answer offers Try again")
scrolls = []; ui("listen", true); ui("think"); line("▸ Reading part 1")
precondition(scrolls.last.map { $0.0 == nil && !$0.1 } == true, "at the bottom, new steps keep following")
m.atBottom = false; scrolls = []; line("▸ Reading part 2"); precondition(scrolls.isEmpty, "scrolled up to read: a new step does not pull the list back down")
''')
        self.assertIn("That's wrong, try again: \\(q)", BOX)   # Try again resends the ask as a correction

    def test_rewrite_offers_its_actions_and_says_what_happened(self):
        self.box(r'''
func bar() -> (labels: [String], editable: Bool)? { for p in turn.parts { if case .rewrite(_, _, let a, _, let e) = p { return (a.map(\.0), e) } }; return nil }
func note() -> String? { for p in turn.parts { if case .note(_, let s) = p { return s } }; return nil }
ui("listen", true); ui("words", "Polish this"); ui("think")
ui("rewrite", ["A polished draft.\nSecond line.", "replace", true]); line("✓ A polished draft.\nSecond line.")
precondition(turn.aKind == "draft" && turn.aText == "A polished draft.\nSecond line." && turn.aBlocks.isEmpty, "a rewrite previews exactly as it will paste, line breaks kept")
precondition(bar()?.labels == ["Replace", "Try again", "Copy"] && bar()?.editable == true, "replace, try again or copy")
ui("replaced", false); precondition(bar()?.editable == false && note()?.contains("Selection changed") == true, "a stale selection says so and disables replacing")
ui("rewrite", ["Hi Dana,", "draft", true]); precondition(bar()?.labels.first == "Insert", "a draft with a cursor offers Insert first")
ui("replaced", true); precondition(note() == "Inserted", "Insert confirms")
ui("rewrite", ["Hi Dana,", "draft", false]); precondition(bar()?.labels.first == "Copy", "no cursor: Copy first")
ui("listen", true); precondition(bar() == nil, "a new ask removes stale replacement actions")
''')

    def test_clicking_an_answer_copies_it_and_a_question_edits_it(self):
        self.box(r'''
ui("listen", true); ui("words", "Open Notes"); ui("think"); line("✓ Notes is open.")
let a = m.answerID(0)!, q = m.turns[0].parts.first { if case .q = $0 { return true }; return false }!.id
ui("listen", true); ui("words", "Open Safari"); ui("think"); line("✓ Safari is open.")
m.targets = [TargetEntry("a:" + a.uuidString, CGRect(x: 0, y: 0, width: 200, height: 40), false, .answer)]
m.tap(CGPoint(x: 10, y: 10)); precondition(posted("copy").last as? String == "Notes is open.", "copying an older answer copies that answer")
m.targets = [TargetEntry("q:" + q.uuidString, CGRect(x: 0, y: 0, width: 200, height: 40), true, .question)]
m.tap(CGPoint(x: 10, y: 10)); precondition(m.ask == "Open Notes" && m.compOpen, "click a transcript to edit it")
''')

    def test_approval_and_retry_cards(self):
        self.box(r'''
func live(_ f: (CardKind) -> Bool) -> Int { cards.filter { f($0.kind) }.count }
let isRetry = { (k: CardKind) -> Bool in if case .retry = k { return true }; return false }
ui("listen", true); ui("words", "Send it"); ui("think")
ui("ask", ["Send this?", "echo preview"])
precondition(live { if case .approval = $0 { return true }; return false } == 1 && m.clockHeld != nil, "an approval card, the timer held")
ui("stopped", "Answer stopped"); precondition(cards.isEmpty && m.clockStart == nil && m.clockHeld == nil, "cancelling removes it and stops the timer")
ui("listen", true); ui("think"); ui("ask", ["Couldn’t finish this", "Try again.", "retry"])
precondition(live(isRetry) == 1, "a failure card")
precondition(m.respond("maybe later") && live(isRetry) == 1 && m.ask == "maybe later", "a reply that is not an answer keeps the card and shows what was heard")
precondition(m.respond("Um, try again, please.") && picks == ["r"], "spoken try again answers Retry")
wait(0.4); precondition(live(isRetry) == 0, "and the card goes")
ui("ask", ["Couldn’t finish this", "Try again.", "retry"]); _ = m.respond("yes"); precondition(picks == ["r", "r"], "yes means Retry")
ui("ask", ["Couldn’t finish this", "Try again.", "retry"]); m.ask = "retry"; m.send(); precondition(picks == ["r", "r", "r"], "typed Retry reaches the same answer")
''')

    def test_choices_card_waits_for_you_and_sends_the_pick(self):
        self.box(r'''
ui("listen", true); ui("words", "Open my essay"); ui("think")
ui("pick", ["q": "Which essay?", "options": [["label": "essay.pdf", "sub": "~/Documents · Oct 9, 2026", "img": "data:image/gif;base64,R0lGODlhAQABAAAAACw="], ["label": "essay.docx", "sub": "~/Desktop", "img": "", "kind": "DOCX"]]])
guard case .pick(_, let options, let pics) = cards[0].kind else { fatalError() }
precondition(pics && options.count == 2 && options[1].kind == "DOCX" && options[1].img == nil, "every option, a file type when there is no preview")
let paused = m.clockText(CACurrentMediaTime()); wait(0.07)
precondition(m.clockStart == nil && m.clockText(CACurrentMediaTime()) == paused, "the timer pauses while the choices wait for you")
m.pickDone(cards[0].id, 0)
precondition(picks == ["0"] && turn.steps.last?.text == "Picked essay.pdf" && m.clockStart != nil, "Use this sends the one picked, and the timer runs again")
ui("pick", ["q": "Which song?", "options": [["label": "Yellow", "sub": "", "img": ""]]])
m.ask = "the live version"; m.send()
precondition(picks.last == "=the live version" && posted("send").isEmpty, "typing in the main box answers an open choices card")
ui("pick", ["q": "Which song?", "options": [["label": "Yellow", "sub": "", "img": ""]]]); ui("stopped", "Answer stopped")
precondition(cards.isEmpty, "cancelling removes the choices")
ui("reset"); ui("listen", true); ui("words", "Make the report"); ui("think")
ui("pick", ["q": "Which file?", "options": [["label": "A"], ["label": "B"]]]); ui("movePending")
precondition(cards.isEmpty && m.status.contains("Moving to an agent"), "moving takes the waiting card with the ask and says so")
ui("agentStarted"); m.ask = "A new question"; m.send(); precondition(posted("send").contains { $0 as? String == "A new question" }, "an accepted move frees the typing box")
ui("reset"); ui("listen", true); ui("think"); ui("moveFailed"); precondition(m.status == "Could not move", "a failed move says so")
''')

    def test_resize_fits_the_screen_and_reset_clears_it(self):
        self.box(r'''
ui("listen", true); ui("limit", 280); ui("compose", true); ui("hold", 1000)
precondition(m.held == 280 && !posted("boxH").isEmpty, "a manual resize fits the available screen")
ui("reset"); precondition(m.held == nil && m.threadMax == 420 && m.turns.isEmpty, "a new conversation clears it")
''')

    def test_mini_screen_waits_maps_points_and_clears(self):
        self.box(r'''
ui("limit", 700); ui("listen", true); ui("words", "Work in the background"); ui("think")
let target: [String: Any] = ["pid": 123, "windowID": "42", "windowFrame": [50, 40, 1000, 600], "window": "Fixture", "app": "Notes", "action": "click"]
func with(_ more: [String: Any]) -> [String: Any] { target.merging(more) { $1 } }
func index(_ f: (Part) -> Bool) -> Int? { turn.parts.firstIndex(where: f) }
line("▸ Clicking “Export”"); line("▣ " + json(target))
precondition(turn.mini?.on == false, "it waits half a second, so quick tasks never flash it")
wait(0.6); precondition(turn.mini?.on == true && turn.mini?.tag == "Notes", "then shows, its tag naming the app")
precondition(index { if case .mini = $0 { return true }; return false }! < index { if case .steps = $0 { return true }; return false }!, "above this turn's steps")
for i in 2...12 { line("▸ " + ["Reading", "Clicking", "Typing", "Scrolling"][i % 4] + " step \(i)") }
precondition(turn.steps.count == 4 && turn.more > 0, "long tasks keep a bounded step stack")
m.rects["mini-view"] = CGRect(x: 0, y: 0, width: 320, height: 200); m.rects["thread"] = CGRect(x: 0, y: -40, width: 320, height: 420)
line("@ 550 340"); let p = turn.mini!.point!
precondition(abs(p.x - 160) < 1 && abs(p.y - 100) < 1 && p.kind == "click", "screen points map to the picture with letterboxing")
ui("mini", with(["action": "type"])); line("@ 550 340"); precondition(turn.mini?.point?.kind == "type", "typing adds a caret")
ui("mini", with(["action": "scroll", "direction": "up"])); line("@ 550 340"); precondition(turn.mini?.point?.dy == -14, "scroll feedback follows its direction")
let last = turn.mini?.point?.id; line("@ 99999 99999"); precondition(turn.mini?.point?.id == last, "an out-of-window point adds no misplaced feedback")
var reported: [[String: Any]] = []; m.onMini = { reported.append($0) }; m.reportMini()
precondition((reported.last?["rect"] as? [CGFloat])?[2] ?? 0 > 0, "the picture reports its frame to native")
ui("mini", with(["shown": false])); precondition(turn.mini?.on == false, "a fully visible window quietly collapses it")
ui("mini", with(["shown": true, "live": false])); precondition(turn.mini?.on == true && turn.mini?.live == false, "no capture permission: the window title in the same frame")
ui("mini", with(["windowID": "43", "window": "Second", "live": true]))
precondition(turn.parts.filter { if case .mini = $0 { return true }; return false }.count == 1 && turn.mini?.title == "Second", "a new target reuses one picture and names the window")
line("✓ Finished"); precondition(turn.mini?.done == true && turn.mini?.on == true, "completion holds the last frame with a check")
ui("mini", target); line("✓ Finished"); ui("listen", true); ui("words", "Next task"); ui("mini", target)
wait(0.6); precondition(turn.mini?.on == true, "an old completion cannot remove the next turn's picture")
ui("stopped", "Stopped"); precondition(turn.mini == nil && index { if case .mini = $0 { return true }; return false } == nil, "cancelling clears it at once")
''')
        steps = BOX[BOX.index('private struct StepsView'):BOX.index('private struct AnswerPart')]
        self.assertIn('.animation(preview ? css(', steps)   # css() is nil under Reduce Motion: steps arrive without sliding

    def test_memory_receipt_sits_under_the_answer(self):
        self.box(r'''
ui("listen", true); ui("words", "Remember that"); ui("think"); line("✓ Saved.")
line("✎ " + json([["c": "people", "label": "People", "t": "dad email: pat@example.test", "add": true], ["c": "rules", "label": "Rules", "t": "Use Safari", "add": false]]))
let k = turn.parts.firstIndex { if case .answer = $0 { return true }; return false }!
guard case .mem(_, let items) = turn.parts[k + 1] else { fatalError("the receipt is not right under the answer") }
precondition(items.map(\.label) == ["People", "Rules"] && items.map(\.add) == [true, false] && items[1].t == "Use Safari", "each item, forgotten ones marked")
''')
        self.assertIn('adds && dels ? "Updated" : adds ? "Remembered" : "Forgot"', BOX)
        self.assertIn('m.post(["memory": ["c": it.c, "t": it.t]])', BOX)   # an item opens Settings → Memory at it

    def test_point_at_your_screen_coach_pointing_and_mark(self):
        self.box(r'''
let pixel = "data:image/gif;base64,R0lGODlhAQABAIAAAP///wAAACwAAAAAAQABAAACAkQBADs="
ui("pointCoach"); precondition(m.pointState == nil, "the coach mark waits until the button is on screen")
ui("hover", true); precondition(m.pointState == "coach", "first use explains the pointer button once")
m.coachDone(); precondition(m.pointState == nil && !posted("pointCoached").isEmpty, "Got it hides the coach mark and records it")
ui("hover", false); ui("hover", true); precondition(m.pointState == nil, "it does not come back")
ui("point", ["active": true, "marked": false])
precondition(m.pointState == "on" && m.pointHint == "Click, circle or scribble on anything, then ask" && m.status == "Pointing…" && m.compOpen && m.focusAsk > 0, "pointing: one hint, the cursor in the box to ask")
ui("point", ["active": true, "marked": true, "thumb": pixel]); precondition(m.pointThumb != nil && m.pointMarked, "a mark shows its picture")
ui("point", ["active": false, "marked": true]); precondition(m.pointState == "marked" && m.pointThumb != nil && m.status == "Marked", "after pointing the chip keeps the picture")
ui("hover", false); precondition(m.pointState == "marked", "the chip stays when the typing box folds away")
ui("point", false); precondition(m.pointState == nil && m.pointThumb == nil && m.status == "", "clearing removes the chip and its status")
ui("point", ["active": false, "marked": true, "thumb": ""]); precondition(m.pointState == "marked" && m.pointThumb == nil, "a mark without a picture shows the pointer glyph")
''')
        self.assertIn('if m.working { return m.setStatus("Finish or stop the current answer first") }', BOX)   # pointing during an answer says why it waits

    def test_box_text_stays_aa_over_its_tint_on_a_white_page(self):
        # The box's tint (Aurel.swift) over a white page; text sits on it or on a card's white .07 glass.
        tint = re.search(r'tint\.layer\?\.backgroundColor = NSColor\(calibratedRed:(\d+)/255,green:(\d+)/255,blue:(\d+)/255,alpha:([\d.]+)\)',
                         (ROOT / 'Aurel.swift').read_text())
        *rgb, alpha = map(float, tint.groups())
        bx = BOX[BOX.index('enum BX {'):BOX.index('static func ease')]
        tokens = {k: int(v, 16) for k, v in re.findall(r'(\w+) = Color\(hex: 0x([0-9a-f]{6})\)', bx)}
        rgb_of = lambda h: [(h >> s) & 255 for s in (16, 8, 0)]
        over = lambda fg, a, bg: [f * a + b * (1 - a) for f, b in zip(fg, bg)]
        lum = lambda c: sum(w * (v / 255 / 12.92 if v / 255 <= .04045 else ((v / 255 + .055) / 1.055) ** 2.4) for w, v in zip((.2126, .7152, .0722), c))
        ratio = lambda a, b: (max(lum(a), lum(b)) + .05) / (min(lum(a), lum(b)) + .05)
        box = over(rgb, alpha, [255] * 3)
        for bg in (box, over([255] * 3, .07, box)):
            for name in ('fg', 'fg2', 'link'):
                self.assertGreaterEqual(ratio(rgb_of(tokens[name]), bg), 4.5, name)
        self.assertGreaterEqual(ratio([255] * 3, rgb_of(tokens['accent'])), 4.5)   # white on the blue Allow / Open buttons


if __name__ == '__main__':
    unittest.main()
