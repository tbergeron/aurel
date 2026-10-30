"""The main answer streams into the box as it arrives: fake Claude partial-message streams, no Mac actions."""
import contextlib
import io
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import Mock, patch

import aurel
from tests import native_ui
from tests.test_box_native import PRELUDE

ROOT = Path(__file__).resolve().parents[1]
ANSWER = ('Paris is the capital of France. It sits on the Seine in the north of the country, and about two million people '
          'live in the city itself.')
FRIDGE = ("A refrigerator moves heat from inside the cabinet to the room. It does this with a closed loop of refrigerant that repeatedly evaporates (absorbing heat) and condenses (releasing heat). The main parts are:\n\n"
          "1. **Compressor:** An electric motor-driven pump that squeezes low-pressure refrigerant vapor into a hot, high-pressure gas. Compression raises the refrigerant's temperature above the kitchen air temperature.\n"
          "2. **Condenser coils:** Usually on the back or underneath. The hot gas flows through these, releases its heat into the room, and condenses into a warm, high-pressure liquid. A fan often helps this heat escape.\n"
          "3. **Expansion valve (or capillary tube):** A narrow restriction where the high-pressure liquid passes through and suddenly drops in pressure. Part of it flashes into vapor, and the whole mix becomes very cold.\n"
          "4. **Evaporator coils:** Inside the fridge or freezer. The cold, low-pressure refrigerant boils here, absorbing heat from the air and food around it. A fan usually circulates the chilled air.\n"
          "5. **Return to the compressor:** The refrigerant, now a low-pressure vapor, goes back to the compressor and the cycle repeats.\n\n"
          "**Why it works:** A liquid absorbs a lot of energy when it evaporates, and it releases that energy when it condenses. Changing the pressure changes the temperature at which this happens. The compressor raises the pressure so the refrigerant gets hot enough to dump heat outside, and the expansion valve lowers the pressure so it gets cold enough to absorb heat inside.\n\n"
          "**Other parts:**\n- **Thermostat:** Senses the cabinet temperature and turns the compressor on and off to hold a set point.\n"
          "- **Defrost system (frost-free models):** A heater or hot-gas cycle melts frost off the evaporator. Drain tubes carry the meltwater away.\n")


def deltas(text, size=7):
    return [{'type': 'stream_event', 'event': {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': text[i:i + size]}}}
            for i in range(0, len(text), size)]


def message(text='', tool=None):
    rows = [{'type': 'stream_event', 'event': {'type': 'message_start', 'message': {}}},
            {'type': 'stream_event', 'event': {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}}}]
    rows += deltas(text)
    blocks = [{'type': 'text', 'text': text}] if text else []
    if tool:
        rows.append({'type': 'stream_event', 'event': {'type': 'content_block_start', 'index': 1,
                                                       'content_block': {'type': 'tool_use', 'id': tool[0], 'name': 'Bash', 'input': {}}}})
        blocks.append({'type': 'tool_use', 'id': tool[0], 'name': 'Bash', 'input': {'command': tool[1]}})
    return rows + [{'type': 'assistant', 'message': {'content': blocks}}]


def result(tool_id, content='Observed state'):
    return {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': tool_id, 'content': content}]}}


class StreamTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory(); self.addCleanup(self.root.cleanup)
        patcher = patch.multiple(aurel, DIR=self.root.name, HOME=self.root.name, PREFS=str(Path(self.root.name) / 'settings.json'))
        patcher.start(); self.addCleanup(patcher.stop)

    def run_stream(self, rows, final, env=None, ask=''):
        p = Mock(); p.stdin = io.StringIO(); p.ask = ask; p.returncode = 0
        p.stdout = map(json.dumps, rows + [{'type': 'result', 'result': final, 'total_cost_usd': .001}])
        with patch.dict(os.environ, {'AUREL_UI': '1', 'AUREL_COMMIT': '', **(env or {})}), patch.object(aurel.threading, 'Thread'), \
             patch.object(aurel.threading, 'Timer'), patch.object(aurel, 'preview_commands'), contextlib.redirect_stdout(io.StringIO()) as out:
            reply, _, _ = aurel.run('Request: fixture', p)
        lines = out.getvalue().rstrip('\n').split('\n')   # not splitlines(): an answer's own line breaks travel as U+2028
        return reply, lines, [line[2:] for line in lines if line.startswith('… ')]

    def test_streamed_answer_never_shows_tags_drafts_handoffs_or_sources(self):
        long = ANSWER + ' '
        self.assertEqual(aurel.streamed_answer(long), ANSWER)
        self.assertEqual(aurel.streamed_answer(ANSWER[:100]), '')   # could still be a 3-8 word note
        for held in ('[draft] ' + long, '[insert] ' + long, '[replace] ' + long, '  \n[agent {\n  "title": "x",\n' + long,
                     '```json\n[agent ' + long, '[sonnet]', '[steer {"id":"a","text":"' + long, '[agent-profile {' + long):
            self.assertEqual(aurel.streamed_answer(held), '', held)
        for tag in ('[tip Say "remember: x"]', '[point 1 20 30]', '[workflow x | y]', '[replay open -a Notes]', '[done]',
                    '[agent {"title":"x","brief":"y"}]', '[agent-result {}]', '[steer {"id":"a"}]'):
            self.assertEqual(aurel.streamed_answer(long + tag + ' after the tag'), ANSWER, tag)
        self.assertEqual(aurel.streamed_answer(long + '\nSources: https://x.example'), ANSWER)
        self.assertEqual(aurel.streamed_answer(long + '\nSour'), ANSWER)   # may still become "Sources:"
        self.assertEqual(aurel.streamed_answer(ANSWER + '\n- More'), ANSWER + '\n- More')
        for text in ('See [1], [ ] and a[0].', 'See [the guide](https://x.example) and [Apple](https://apple.example).'):
            self.assertEqual(aurel.streamed_answer(long + text), long + text)   # not a tag: the rest keeps streaming
        self.assertEqual(aurel.streamed_answer(long + 'See [the guide'), long + 'See')   # may still be a tag until it closes as a link
        self.assertEqual(aurel.streamed_answer(long + '[agent {"brief":"read [x](y)"}] after'), ANSWER)

    def test_plain_answer_streams_and_the_final_reply_replaces_it(self):
        reply, lines, shown = self.run_stream(message(ANSWER), ANSWER)
        self.assertEqual(reply, ANSWER)
        self.assertGreater(len(shown), 2, 'the answer arrives in pieces')
        self.assertTrue(all(ANSWER.startswith(s) for s in shown)); self.assertEqual(shown[-1], ANSWER)
        self.assertEqual(shown, sorted(shown, key=len), 'the shown text only grows')
        self.assertTrue(all(len(s) >= 120 for s in shown))

    def test_multi_line_agent_handoff_never_prints_text_and_hands_off(self):
        marker = '[agent ' + json.dumps({'title': 'Research desks', 'brief': 'Compare standing desks under $600 across sources', 'context': ANSWER}, indent=2) + ']'
        ask = tempfile.mkdtemp(dir=self.root.name)
        with patch.object(aurel, 'wait_commit', return_value=True):
            reply, lines, shown = self.run_stream(message(marker + '\n' + ANSWER), marker + '\n' + ANSWER, ask=ask)
        self.assertEqual(reply, ''); self.assertEqual(shown, [])
        self.assertEqual(sum(line.startswith('⤴ ') for line in lines), 1)
        self.assertEqual(aurel.run.handoff['title'], 'Research desks')
        self.assertFalse(any(line.startswith(('✓', '·')) for line in lines))

    def test_note_before_a_tool_never_shows_as_the_answer(self):
        rows = message('Checking the weather', ('t1', 'curl -s wttr.in')) + [result('t1')] + message(ANSWER)
        reply, lines, shown = self.run_stream(rows, ANSWER)
        self.assertEqual(reply, ANSWER)
        self.assertNotIn('Checking the weather', ''.join(shown))
        self.assertIn('· Checking the weather', lines)   # the note is still a status line, as before
        self.assertEqual(shown[-1], ANSWER)
        self.assertLess(lines.index('· Checking the weather'), next(i for i, line in enumerate(lines) if line.startswith('… ')))

    def test_a_long_note_is_cleared_when_its_tool_call_starts(self):
        note = 'I will look this up first. ' * 6
        rows = message(note, ('t1', 'curl -s wttr.in')) + [result('t1')] + message(ANSWER)
        _, lines, shown = self.run_stream(rows, ANSWER)
        clear = lines.index('… ')
        self.assertTrue(any(line.startswith('… I will') for line in lines[:clear]))
        self.assertFalse(any(line.startswith('… I will') for line in lines[clear:]))
        self.assertLess(clear, next(i for i, line in enumerate(lines) if line.startswith(('· ', '▸ '))), 'cleared before its note and step show')

    def test_control_tags_mid_stream_are_never_shown(self):
        for tag in ('[tip Say "remember: open means front"]', '[point 1 200 300]', '[workflow Plan | method]', '[done]', '[agent {"title":"a","brief":"b"}]'):
            with self.subTest(tag=tag):
                text = ANSWER + ' ' + tag + ' Words after the tag.'
                _, _, shown = self.run_stream(message(text), text)
                self.assertTrue(shown); self.assertFalse(any('[' in s or 'after the tag' in s for s in shown))

    def test_nothing_streams_before_the_transcript_is_confirmed_or_outside_the_box(self):
        commit = Path(self.root.name) / 'commit'
        _, _, shown = self.run_stream(message(ANSWER), ANSWER, env={'AUREL_COMMIT': str(commit)})
        self.assertEqual(shown, [])
        commit.write_text('go')
        _, _, shown = self.run_stream(message(ANSWER), ANSWER, env={'AUREL_COMMIT': str(commit)})
        self.assertEqual(shown[-1], ANSWER)
        _, _, shown = self.run_stream(message(ANSWER), ANSWER, env={'AUREL_UI': ''})
        self.assertEqual(shown, [])

    def failed_early_start(self, commit, getppid=os.getppid, sleep=aurel.time.sleep):
        p = Mock(); p.stdin = io.StringIO(); p.ask = ''; p.returncode = 0; p.errors = io.StringIO()
        p.stdout = map(json.dumps, [{'type': 'result', 'is_error': True, 'result': 'API Error: fixture', 'total_cost_usd': 0,
                                     'usage': {'input_tokens': 0, 'output_tokens': 0}, 'modelUsage': {}}])   # ended before any model call
        with patch.dict(os.environ, {'AUREL_UI': '1', 'AUREL_COMMIT': str(commit)}), patch.object(aurel.threading, 'Thread'), \
             patch.object(aurel.threading, 'Timer'), patch.object(aurel.os, 'getppid', getppid), \
             patch.object(aurel.time, 'sleep', sleep), contextlib.redirect_stdout(io.StringIO()) as out:
            reply, _, _ = aurel.run('Request: fixture', p)
        return reply, out.getvalue().splitlines()

    def test_a_failed_early_start_opens_setup_only_after_the_transcript_is_confirmed(self):
        commit = Path(self.root.name) / 'commit'
        reply, lines = self.failed_early_start(commit, getppid=Mock(side_effect=[100, 101]))   # the app dropped this start unconfirmed
        self.assertIn('Claude stopped', reply)
        self.assertNotIn('! setup', lines)
        _, lines = self.failed_early_start(commit, sleep=lambda _: commit.write_text('go'))   # the user lets go and these words are confirmed
        self.assertEqual(lines.count('! setup'), 1)
        with patch.dict(os.environ, {'AUREL_COMMIT': ''}), contextlib.redirect_stdout(io.StringIO()) as out:
            aurel.say('!', 'setup')   # typed asks have no transcript to wait for
        self.assertEqual(out.getvalue(), '! setup\n')

    def test_show_answers_setting_streams_as_they_arrive_or_shows_all_at_once(self):
        _, _, shown = self.run_stream(message(ANSWER), ANSWER)
        self.assertEqual(shown[-1], ANSWER)   # default: as they arrive
        for value, streams in (('stream', True), ('once', False)):
            with self.subTest(value=value):
                Path(aurel.PREFS).write_text(json.dumps({'showAnswers': value}))
                reply, _, shown = self.run_stream(message(ANSWER), ANSWER)
                self.assertEqual(bool(shown), streams); self.assertEqual(reply, ANSWER)   # all at once: only the final reply, with its classic fade
        self.assertEqual(aurel.picks()['showAnswers'], ('Show answers', {'As they arrive': 'stream', 'All at once': 'once'}))
        self.assertIn('"showAnswers": "stream"', (ROOT / 'Aurel.swift').read_text())

    def test_drawing_or_pointing_replies_do_not_stream(self):
        rows = message('Drawing it', ('d1', f'{aurel.ME} --draw \'{{"steps":[]}}\'')) + [result('d1', 'Guide shown (step 1 of 1).')] + message(ANSWER)
        _, _, shown = self.run_stream(rows, ANSWER)
        self.assertEqual(shown, [])

    def test_main_asks_request_partial_messages_and_stay_strict(self):
        with patch.object(aurel.shutil, 'which', return_value='/fixture/claude'), patch.object(aurel.subprocess, 'Popen') as popen, \
             patch.object(aurel.atexit, 'register'), patch.object(aurel.signal, 'signal'):
            aurel.start_claude().errors.close()
        args = popen.call_args.args[0]
        for flag in ('--include-partial-messages', '--no-session-persistence', '--strict-mcp-config'): self.assertIn(flag, args)

    def box(self, checks, *args, **kw):
        """Runs the native box's real line()/parseMarkdown()/Reveal on BoxModel, a turn listening and thinking."""
        return native_ui(self, PRELUDE + 'ui("listen"); ui("words", "Request"); ui("think")\n' + checks, *args, **kw)

    def lines(self, text):
        """What the box gets for a streamed `text`: each … line, then the final ✓ reply (Swift unfolds its lines)."""
        _, _, shown = self.run_stream(message(text), text)
        with contextlib.redirect_stdout(io.StringIO()) as out: aurel.say('✓', text)
        path = Path(self.root.name) / 'lines.json'
        path.write_text(json.dumps(['… ' + s for s in shown] + [out.getvalue().strip().replace(' ', '\n')]))
        return str(path)

    def test_box_shows_the_answer_so_far_and_replaces_or_clears_it(self):
        self.box(r"""
line("… First words here"); precondition(shown == "First words" && turn.aKind == "streaming", "shows the answer so far, its last word may still be arriving: \(shown)")
line("… First words\u{2028}- a list item"); precondition(turn.aBlocks.map(kind) == ["p", "ul"] && shown == "First words a list", "keeps its line breaks")
line("· Checking the weather"); precondition(turn.aBlocks.isEmpty && turn.aText.isEmpty && turn.aKind != "streaming", "a note clears it")
line("… Again and"); line("… "); precondition(turn.aBlocks.isEmpty, "an empty line clears it")
for open in ["… It **moves heat from", "… It `comp and so", "… It [the link](https://x.co"] { line(open); precondition(shown == "It", "an open mark waits, never shown as a symbol: \(open) → \(shown)") }
line("… It **moves heat** via `gas` and [a link](https://x.co) then")
precondition(words(render(turn.aBlocks, true)) == "It **moves heat** via `gas` and [a link](https://x.co)", "closed marks show as bold, code and a link: \(render(turn.aBlocks, true))")
line("… See [1] and a[0]\u{2028}- [ ] a task and"); precondition(shown == "See [1] and a[0] [ ] a task", "a bracket that is not a link shows at once: \(shown)")
line("… ```\u{2028}x = a[0] and"); precondition(shown.contains("a[0]"), "inside a code block a bracket is text")
line("… ")
line("… Final answer"); line("✓ Final answer"); precondition(shown == "Final answer" && turn.aKind == "normal" && turn.aAnswer == "Final answer", "the final reply replaces it")
line("… Late words"); precondition(shown == "Final answer", "a finished answer stays")
ui("listen"); ui("think"); line("✓ Fresh reply"); precondition(turn.reveal.words.count == 2 && turn.reveal.at.count == 2 && !turn.reveal.done, "an answer that did not stream still fades in")
// a hand-off, an ask card or a choices card never leaves the provisional text
let calls: [(String, Any)] = [("finished", NSNull()), ("ask", ["Allow?", "echo x"]), ("pick", ["q": "Which?", "options": [["label": "A"]]])]
for (call, arg) in calls {
    ui("listen"); ui("think"); line("… Some words so far and"); ui(call, arg)
    precondition(turn.aBlocks.isEmpty && turn.aKind != "streaming", "\(call) clears the streamed text")
}
""")
        # the streamed words reuse the answer's fade, and Reduce Motion turns it off
        self.assertIn('let still = reveal == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion', (ROOT / 'Answer.swift').read_text())

    def test_streamed_words_fade_in_once_and_the_box_keeps_the_answers_start_in_view(self):
        self.box(r"""
func long(_ n: Int) -> String { (0..<n).map { "w\($0)" }.joined(separator: " ") }
let a = m.answerID(m.turns.count - 1)!
scrolls = []; var t0 = CACurrentMediaTime(); line("… " + long(6)); let first = turn.reveal.at
precondition(turn.reveal.words == (0..<5).map { "w\($0)" } && first[0] >= t0 && first[0] <= CACurrentMediaTime(), "the first words fade in, the first at once")
precondition(scrolls.count == 1 && scrolls[0].0 == a && scrolls[0].1, "following: the box keeps the answer's start in view, not the bottom")
Thread.sleep(forTimeInterval: 0.3); t0 = CACurrentMediaTime(); line("… " + long(20)); let next = turn.reveal.at
precondition(Array(next.prefix(5)) == first, "words on screen keep their moment and are not animated again")
precondition(next.count == 19 && next[5] >= t0, "only the new words fade in, the first of them at once")
precondition(scrolls.count == 2 && scrolls[1].0 == a && scrolls[1].1, "it stays at the start while more arrives")
m.atBottom = false; scrolls = []; line("… " + long(45)); precondition(scrolls.isEmpty, "the user scrolled away: stays there")
let shownAt = turn.reveal.at; Thread.sleep(forTimeInterval: 0.3); t0 = CACurrentMediaTime(); line("✓ " + long(45) + " end."); let done = turn.reveal.at
precondition(Array(done.prefix(44)) == shownAt, "the final reply never re-fades words already shown")
precondition(done.count == 46 && Array(turn.reveal.words.suffix(2)) == ["w44", "end."] && done[44] >= t0, "only its words not yet shown fade in")
precondition(scrolls.isEmpty, "the final reply does not jump")
""")
        # The page let a full box stop at the answer's start (atBottom = start >= end) and the user's own wheel clear atBottom,
        # so later lines never pulled a reader up or down. Natively something must clear it the same way.
        self.assertTrue(re.search(r'atBottom\s*=(?!=)(?!\s*true\b)', (ROOT / 'Box.swift').read_text()), 'nothing ever clears BoxModel.atBottom')

    def test_a_long_streamed_answer_fades_in_reading_order_once(self):
        path = self.lines(FRIDGE)
        self.box(r"""
let lines = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String]
precondition(lines.count > 100)
var first: [Double] = [], last = 0.0
for l in lines {
    last = CACurrentMediaTime(); line(l); Thread.sleep(forTimeInterval: 0.01)
    let r = turn.reveal
    precondition(r.at.count == r.words.count && r.words == answerWords(turn.aBlocks), "no word appears without its fade")
    for (i, t) in r.at.enumerated() {
        if i < first.count { precondition(t == first[i], "a word re-rendered with the same text never fades again: \(r.words[i])") } else { first.append(t) }
    }
}
precondition(turn.aKind == "normal" && turn.reveal.words == answerWords(parseMarkdown(String(lines.last!.dropFirst(2)))), "the final reply is all there")
precondition(zip(first, first.dropFirst()).allSatisfy { $0 <= $1 }, "words fade in reading order")
precondition(first.max()! - last <= 0.9 + 1e-6, "a long backlog catches up instead of lagging")
""", path, timeout=60)

    def test_closed_output_pipe_cancels_without_a_traceback(self):
        with patch('builtins.print', side_effect=BrokenPipeError), patch('sys.stdout', io.StringIO()), \
             patch.object(aurel, 'stop_workers', side_effect=SystemExit(0)) as stop:
            with self.assertRaises(SystemExit) as ended:
                aurel.say('✓', 'Finished.')
            aurel.sys.stdout.close()
        self.assertEqual(ended.exception.code, 0)
        stop.assert_called_once_with()

    def test_a_streamed_blocks_marker_background_or_border_never_shows_before_its_first_word(self):
        text = ("A fridge pumps heat out of the cabinet. Its work per cycle is $$W = Q_h - Q_c$$ and the main parts are:\n\n## Parts\n\n"
                "- **Compressor:** squeezes the vapor so it gets hot.\n- **Condenser:** gives that heat to the room, check it with `fridge --status` daily.\n\n"
                "1. Compression raises the pressure.\n2. Expansion drops it again.\n\n```\nstate: cooling\nfan: on\n```\n\n"
                "| Part | Where |\n|---|---|\n| Coils | Back |\n| Fan | Inside |\n")
        self.box(r"""
let lines = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String]
func has(_ i: [Inline]) -> Bool { !words(render(i, false)).isEmpty }
var empty = Set<String>()
for l in lines {
    line(l)
    for b in turn.aBlocks {   // a list item, heading, code block or table cell shows only once it has a word
        switch b {
        case .heading(let i): if !has(i) { empty.insert("a heading") }
        case .list(_, _, let items): if !items.allSatisfy(has) { empty.insert("a list item (its marker)") }
        case .pre(let s): if words(s).isEmpty { empty.insert("a code block (its background)") }
        case .table(let h, let rows): if !([h] + rows).allSatisfy({ $0.allSatisfy(has) }) { empty.insert("a table cell (its border)") }
        default: break
        }
    }
}
let all = Set(turn.aBlocks.map(kind))
precondition(["ul", "ol", "h", "pre", "table", "math"].allSatisfy(all.contains) && render(turn.aBlocks, true).contains("`fridge --status`"), "every kind of block was there: \(all)")
precondition(empty.isEmpty, "shown before its first word: \(empty.sorted())")
""", self.lines(text))
        # Each block's marker, background or border fades with its first word (fade(first)); Reduce Motion stills them (AnswerView).
        answer = (ROOT / 'Answer.swift').read_text()
        self.assertIn('.opacity(fade(rows[k].1))', answer)   # a list marker
        self.assertIn('.background(rr(10).fill(Color.white(0.07))).opacity(fade(f))', answer)   # a code block's background
        cell = answer[answer.index('    func cell('):answer.index('    func upper(')]
        self.assertIn('fade(', cell, "a table cell's border fades with its first word")

if __name__ == '__main__':
    unittest.main()
