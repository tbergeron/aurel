"""ui/web.js runs in the user's browser, so Node checks its syntax; the box's answers and cards are native (Box.swift, Answer.swift)."""
from pathlib import Path
import shutil
import subprocess
import unittest

from tests import native_ui

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('node'), 'Node is optional for UI syntax checks')
class JavaScriptTests(unittest.TestCase):
    def test_web_script_parses(self):
        p = subprocess.run(['node', '--check', str(ROOT / 'ui' / 'web.js')], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)


# The box's Markdown as tags, the way the page's DOM read: text only, never HTML; math kept as its TeX.
MARKUP = r'''
func h(_ i: [Inline]) -> String { i.map { x -> String in switch x {
    case .text(let s): return s
    case .strong(let k): return "<strong>" + h(k) + "</strong>"
    case .em(let k): return "<em>" + h(k) + "</em>"
    case .code(let s): return "<code>" + s + "</code>"
    case .link(let t, let u): return "<a href=" + u + ">" + t + "</a>"
    case .math(let s): return "<math>" + s + "</math>"
    case .br: return "<br>"
} }.joined() }
func md(_ s: String) -> String { parseMarkdown(s).map { b -> String in switch b {
    case .para(let i): return "<p>" + h(i) + "</p>"
    case .heading(let i): return "<div.h>" + h(i) + "</div>"
    case .list(let o, let start, let items): return (o ? "<ol start=\(start)>" : "<ul>") + items.map { "<li>" + h($0) + "</li>" }.joined() + (o ? "</ol>" : "</ul>")
    case .pre(let s): return "<pre>" + s + "</pre>"
    case .table(let head, let rows): return "<table><tr>" + head.map { "<th>" + h($0) + "</th>" }.joined() + "</tr>" + rows.map { "<tr>" + $0.map { "<td>" + h($0) + "</td>" }.joined() + "</tr>" }.joined() + "</table>"
    case .hr: return "<hr>"
    case .math(let s): return "<math display=block>" + s.trimmingCharacters(in: .whitespacesAndNewlines) + "</math>"
} }.joined() }
func expect(_ text: String, _ want: String, _ name: String) { let got = md(text); precondition(got == want, name + "\n got: " + got + "\nwant: " + want) }
'''


class NativeBoxTests(unittest.TestCase):
    def test_answer_markdown_and_math_parse_to_safe_blocks(self):
        # TeX itself is typeset by SwiftUIMath (MathCache; nil shows the source as written): here, which spans are math
        native_ui(self, MARKUP + r'''
expect("$\\frac{\\sqrt{7}}{\\sqrt{10}-\\sqrt{2}}$", "<p><math>\\frac{\\sqrt{7}}{\\sqrt{10}-\\sqrt{2}}</math></p>", "A formula is math")
expect("$$x^2_1$$", "<math display=block>x^2_1</math>", "Display math stands alone")
expect("$\\frac12$ and $\\text{area } r$", "<p><math>\\frac12</math> and <math>\\text{area } r</math></p>", "Two inline formulas")
expect("$$\na^2\n$$", "<math display=block>a^2</math>", "Display math may span lines")
expect("It costs $5 or $10, and \\$3 more.", "<p>It costs $5 or $10, and $3 more.</p>", "Dollar amounts stay money")
expect("**Bold** *it* `code` [OpenTable](https://www.opentable.com) see https://example.com/a.",
       "<p><strong>Bold</strong> <em>it</em> <code>code</code> <a href=https://www.opentable.com>OpenTable</a> see <a href=https://example.com/a>https://example.com/a</a>.</p>", "Inline Markdown")
expect("[x](javascript:alert(1)) <img src=x onerror=alert(1)>", "<p>[x](javascript:alert(1)) <img src=x onerror=alert(1)></p>", "No script links and no HTML: only text")
expect("## Steps\n3. one\n4. **two**\n\n- a\n- b", "<div.h>Steps</div><ol start=3><li>one</li><li><strong>two</strong></li></ol><ul><li>a</li><li>b</li></ul>", "Headings and lists")
expect("one line\nnext line\n\nnew para", "<p>one line<br>next line</p><p>new para</p>", "Paragraphs keep the line breaks the answer has")
expect("**Branch:** r2\n**Commit:** 3c14f84", "<p><strong>Branch:</strong> r2<br><strong>Commit:</strong> 3c14f84</p>", "Label lines stay on their own lines")
expect("Desks:\n| Desk | Price |\n|---|:-:|\n| **E7** | $300 |", "<p>Desks:</p><table><tr><th>Desk</th><th>Price</th></tr><tr><td><strong>E7</strong></td><td>$300</td></tr></table>", "Tables")
expect("See:\n```\n  /|\n\n /_|  **b**\n```\nDone.", "<p>See:</p><pre>  /|\n\n /_|  **b**</pre><p>Done.</p>", "Fenced blocks keep their lines as plain text")
expect("Above\n---\nBelow", "<p>Above</p><hr><p>Below</p>", "A rule between paragraphs")
expect("snake_case_name and _em_", "<p>snake_case_name and <em>em</em></p>", "Underscores inside words stay")
''')

    def test_dictation_pill_shows_the_wave_not_the_words(self):
        native_ui(self, r'''
let m = BoxModel()
m.receive("dictate", true); m.receive("listen", "dict"); m.receive("level", 0.8)
precondition(m.hearing && m.wave.count == 9 && m.wave.contains { $0 > 3 })
m.receive("dictated", ["text": "Inserted", "ok": true])
precondition(!m.hearing && m.pill == "said")
m.receive("dictate", true)   // the next dictation: no last wave, state or empty turn
precondition(m.wave.allSatisfy { $0 == 3 } && m.pill == "" && !m.turns.contains { $0.dict })
''')
        box = (ROOT / 'Box.swift').read_text()
        self.assertIn('if m.hearing && m.pill.isEmpty {', box)   # the wave, only while it hears; never the words
        self.assertIn('if dictating { scheduleDictateAhead(); return }', (ROOT / 'Aurel.swift').read_text())

    def test_onboarding_finish_names_missing_voice_requirements(self):
        done = (ROOT / 'Onboarding.swift').read_text()
        done = done[done.index('private struct Done: View {'):]
        self.assertIn('let core = [("claude", "AI provider"), ("mic", "Microphone"), ("speech", "Speech Recognition"), ("ax", "Accessibility")]', done)
        self.assertIn('voice = ["claude", "mic", "speech"].allSatisfy { s[$0] ?? false }', done)
        self.assertIn('missing.isEmpty ? "You’re all set" : voice ? "Voice is ready" : "Setup isn’t finished yet"', done)
        self.assertIn('missing.joined(separator: ", ")', done)
        self.assertIn('PillButton(label: voice ? "Start Using Aurel" : "Finish Setup Later")', done)

    def test_worker_start_failure_has_persistent_recovery_actions(self):
        box = (ROOT / 'Box.swift').read_text()
        native = (ROOT / 'Aurel.swift').read_text()
        worker = box[box.index('        case .worker:'):box.index('        case .pick(')]
        self.assertIn('Aurel’s helper couldn’t start', worker)
        self.assertIn('m.post(["workerRetry": true])', worker)
        self.assertIn('m.post(["setup": true])', worker)
        self.assertIn('pinned = true; js("workerFailed"); show()', native)
        self.assertIn('if b["workerRetry"] != nil, !busy', native)
        native_ui(self, r'''
let m = BoxModel()
m.receive("listen", NSNull()); m.receive("think", NSNull()); m.receive("workerFailed", NSNull())
let worker = { m.liveCard { if case .worker = $0 { return true }; return false } != nil }
precondition(worker() && m.status == "Couldn’t start")
precondition(!m.respond("retry") && worker(), "typed asks are not answers to this card")
m.receive("listen", NSNull()); precondition(!worker(), "a new ask keeps the old card")
''')

    def test_paused_shortcut_offers_rate_limited_resume(self):
        box = (ROOT / 'Box.swift').read_text()
        native = (ROOT / 'Aurel.swift').read_text()
        self.assertIn('m.post(["resume": true])', box[box.index('        case .paused:'):box.index('        case .worker:')])
        self.assertIn("Date().timeIntervalSince(pausedNotice) > 4", native)
        resume = native[native.index('if b["resume"] != nil {'):native.index('if b["replace"] != nil')]
        self.assertIn('Aurel.settings.apply("paused", false)', resume)


if __name__ == '__main__':
    unittest.main()
