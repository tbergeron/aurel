"""Local client (Settings → Intelligence → Local): the router, the step loop and one-shot calls, with the model mocked."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import aurel


class LocalTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        for p in (patch.multiple(aurel, DIR=str(self.root), TURN={}, CLIENT_DEFAULT='local'),
                  patch.object(aurel, 'pref', side_effect=lambda k, d: 'local' if k == 'client' else d),
                  patch.dict(os.environ, {'AUREL_ASK': str(self.root), 'AUREL_LLM': 'http://127.0.0.1:1', 'AUREL_LLM_READY': '1'})):
            p.start(); self.addCleanup(p.stop)

    def test_local_is_the_default_client_and_needs_only_its_download(self):
        self.assertEqual(aurel.client(), 'local')
        self.assertTrue(aurel.plan()['ok'])
        with patch.dict(os.environ, {'AUREL_LLM_READY': ''}):
            self.assertEqual(aurel.plan(), {'ok': False, 'need': 'download', 'client': 'local', 'text': 'Download the local model in Settings → Intelligence.'})

    def test_router_lines_run_as_the_fast_commands(self):
        said = []
        fast = lambda t: said.append(t) or f'did {t}'
        with patch.object(aurel, 'fast', side_effect=fast):
            for line, want in [('open Slack', 'open Slack'), ('scroll down bit', 'scroll down a bit'), ('scroll top', 'scroll to the top'),
                               ('scroll bottom', 'scroll to the bottom'), ('scroll up', 'scroll up'), ('press cmd+t', 'press cmd+t'),
                               ('move to left', 'move this to the left'), ('move Chrome to monitor', 'move Chrome to the monitor')]:
                self.assertEqual(aurel.route_line(line, 'Safari'), f'did {want}')
        hands = Mock(return_value=('Clicked “Send”.\nmore', True))
        with patch.object(aurel, 'hands', hands):
            self.assertEqual(aurel.route_line('click 6', 'Messages'), 'Clicked “Send”.')
            self.assertEqual(aurel.route_line('type "on my way" field 5', 'Messages'), 'Clicked “Send”.')
        self.assertEqual([c.args for c in hands.call_args_list], [('click', '6'), ('type', '5', 'on my way')])
        with patch.object(aurel, 'hands', return_value=('Nothing changed after clicking "Compose"', True)):
            self.assertIsNone(aurel.route_line('click 19', 'Fastmail'))   # a click that did nothing is not an answer: the full ask takes over

    def test_router_types_into_another_app_after_opening_it(self):
        with patch.object(aurel, 'fast', return_value='Opened Messages.') as fast, patch.object(aurel, 'app_named', return_value='Messages'), \
             patch.object(aurel.subprocess, 'run', return_value=Mock(returncode=0)) as run, patch.object(aurel, 'hands') as hands:
            self.assertEqual(aurel.route_line('type "running late" in Messages field 3', 'Safari'), 'Typed “running late”.')
        fast.assert_called_once_with('open Messages'); hands.assert_not_called()   # field 3 was Safari's: type at the cursor instead
        self.assertEqual(run.call_args.kwargs['input'], 'running late')

    def test_router_sends_through_the_apps_own_box(self):
        # Muse's map: a Search field up top, sidebar buttons, and its message bar drawn around the Dictate button
        muse = {'nodes': [{'id': 1, 'role': 'AXTextField', 'label': 'Search', 'frame': [100, 50, 180, 20]},
                          {'id': 2, 'role': 'AXButton', 'label': 'gamedev', 'frame': [90, 280, 200, 36]},
                          {'id': 3, 'role': 'AXButton', 'label': 'Dictate a message', 'frame': [1305, 992, 26, 26]},
                          {'id': 4, 'role': 'AXButton', 'label': 'Message Attach file\nSend', 'frame': [615, 976, 768, 58]}]}
        with patch.object(aurel, 'hands_map', return_value=muse):
            self.assertEqual(aurel.message_box('Muse'), '4')
        hands = Mock(return_value=('Typed into "Message Attach file\nSend"', True))
        with patch.object(aurel, 'fast', return_value='Opened Muse.'), patch.object(aurel, 'app_named', return_value='Muse'), \
             patch.object(aurel, 'hands_map', return_value=muse), patch.object(aurel, 'hands', hands), patch.object(aurel.subprocess, 'run') as run:
            self.assertEqual(aurel.route_line('type "hello world" in Muse send', 'Safari'), 'Typed into "Message Attach file')
            run.assert_not_called()   # a send never types at whatever cursor is in front
            run.return_value = Mock(returncode=1)   # no caret to type at: the app's box instead
            aurel.route_line('type "hello world" in Muse', 'Safari')
        self.assertEqual([c.args for c in hands.call_args_list], [('type', '4', 'hello world', 'submit'), ('type', '4', 'hello world')])
        with patch.object(aurel, 'hands_map', return_value={'nodes': [muse['nodes'][1]]}):
            self.assertIsNone(aurel.message_box('Muse'))   # nothing to type into: the full ask takes over
        unverified = 'Could not verify Return was accepted in the background. Read the window; if it was not sent, click its send button.'
        with patch.object(aurel, 'fast', return_value='Opened Muse.'), patch.object(aurel, 'app_named', return_value='Muse'), \
             patch.object(aurel, 'hands_map', return_value=muse), patch.object(aurel, 'hands', return_value=(unverified, False)):
            self.assertEqual(aurel.route_line('type "please wait." in Muse send', 'Muse'), 'Sent “please wait.” in Muse. I couldn’t confirm it arrived.')   # never sent twice
        with patch.object(aurel, 'fast', return_value='Opened Muse.'), patch.object(aurel, 'app_named', return_value='Muse'), patch.object(aurel, 'hands_map', return_value=muse), \
             patch.object(aurel, 'hands', return_value=('Could not see the text land in "Message". Nothing was sent; read the window before typing again.', False)):
            self.assertIsNone(aurel.route_line('type "please wait." in Muse send', 'Muse'))   # nothing went: the full ask takes over
        for task, line, elsewhere in [('Tell Muse hello world', 'type "hello world" in Muse send', False),
                                      ('Send hello world in Muse', 'type "hello world" in Muse send', False),
                                      ('Say Hello World in Muse.', 'type "Hello World" in Muse send', False),
                                      ('tell Sam I am late in Messages', 'type "I am late" in Messages send', True),   # whichever chat is open
                                      ('reply and say I am in', 'type "I am in" in Claude send', True),
                                      ('send hello', 'type "hello" send', True),
                                      ('say hello there', 'type "hello there"', False)]:
            self.assertEqual(aurel.quick_send_elsewhere(task, line), elsewhere, task)
        for task, line, several in [('switch to Muse and tell it, please wait.', 'open Muse', True), ('open Slack then scroll down', 'open Slack', True),
                                    ('switch to Muse', 'open Muse', False), ('tell Muse I am here and ready', 'type "I am here and ready" in Muse send', False),
                                    ('Tell Muse I am here And ready', 'type "I am here and ready" in Muse send', False),
                                    ('open Muse and say hi', 'type "hi" in Muse send', True), ('move Chrome and Safari left', 'move Chrome to left', True)]:
            self.assertEqual(aurel.several_steps(task, line), several, task)
        for task, aloud in [('Well, read it.', True), ('Read the last message.', True), ("Read Musist's last message", True),
                            ('Can you read me this email?', True), ('read this page out loud', True), ('Hey Aurel, read it', True),
                            ('read up on solar panels', False), ('what did Muse say', False), ('open the reading list', False),
                            ('thread the needle', False), ('summarize what I read yesterday', False)]:
            self.assertEqual(aurel.asks_aloud(task), aloud, task)
        for task, line, echo in [('Well, read it.', 'type "Well, read it." in Muse send', True), ('read it', 'type "Read it"', True),
                                 ('say hello there', 'type "hello there"', False), ('Tell Muse hello world', 'type "hello world" in Muse send', False),
                                 ('read it', 'open Muse', False)]:
            self.assertEqual(aurel.echoes(task, line), echo, task)

    def test_reply_goes_to_the_app_just_read_or_told(self):
        with tempfile.TemporaryDirectory() as root, patch.object(aurel, 'CHAT', os.path.join(root, 'last_chat')), \
             patch.object(aurel, 'front', return_value=('Aurel', '')), patch.object(aurel, 'trace'), \
             patch.object(aurel, 'route_line', return_value='Sent.') as route:
            self.assertIsNone(aurel.fast('Reply, I am on my way.'))   # nothing read or told yet: the full ask
            route.assert_not_called()
            Path(aurel.CHAT).write_text('Muse')
            for said, words in [("Reply, I gotta update you about all the changes I've put in the game. It's incredible.",
                                  "I gotta update you about all the changes I've put in the game. It's incredible."),
                                 ('respond with sounds good', 'sounds good'), ('Reply to it saying Thanks, um', 'Thanks')]:
                self.assertEqual(aurel.fast(said), 'Sent.', said)
                route.assert_called_with(f'type "{words}" in Muse send', 'Aurel')
            os.utime(aurel.CHAT, (0, 0))   # long ago: a reply to what?
            route.reset_mock()
            self.assertIsNone(aurel.fast('Reply, hi'))
            route.assert_not_called()
        with patch.dict(os.environ, {'AUREL_LIVE': '1'}), patch.object(aurel, 'route_line') as route:
            self.assertIsNone(aurel.fast('Reply, I gotta'))   # half-said: never sent
            route.assert_not_called()

    def test_router_never_types_into_the_front_app_for_an_app_it_cannot_find(self):
        with patch.object(aurel, 'fast') as fast, patch.object(aurel, 'app_named', return_value=None), \
             patch.object(aurel.subprocess, 'run') as run, patch.object(aurel, 'hands') as hands:
            self.assertIsNone(aurel.route_line('type "private note" in MissingApp field 2', 'Messages'))
        fast.assert_not_called(); run.assert_not_called(); hands.assert_not_called()

    def test_step_loop_runs_nothing_after_its_deadline(self):
        clock = [0.0]
        calls = [{'id': i, 'function': {'arguments': json.dumps({'command': f'echo {i}'})}} for i in 'ab']
        def llm(messages, **k):
            clock[0] += 100
            return {'tool_calls': calls} if clock[0] < 150 else {'content': 'late'}
        def run(*a, **k):
            clock[0] += 81
            return Mock(stdout='ok', stderr='', returncode=0)
        with patch.object(aurel, 'llm', side_effect=llm), patch.object(aurel, 'local_gate', return_value=(True, '')), \
             patch.object(aurel.time, 'monotonic', side_effect=lambda: clock[0]), patch.object(aurel.subprocess, 'run', side_effect=run) as sub:
            messages = [{'role': 'user', 'content': 'go'}]
            reply, ran = aurel.local_loop(messages, 180)
        self.assertEqual(ran, ['echo a']); self.assertEqual(sub.call_count, 1)
        self.assertLessEqual(sub.call_args.kwargs['timeout'], 80)   # bounded by what was left, not a fresh 120 s
        self.assertEqual(messages[-1]['content'], 'Not run: the request ran out of time.')
        self.assertEqual(reply, 'That took too long, so I stopped. Please try again.')

    def test_route_hands_bigger_asks_on_and_reads_the_window(self):
        seen = {'description': '1 button: Back\n2 box: Search'}
        with patch.object(aurel, 'llm_url', return_value='http://x'), patch.object(aurel, 'front', return_value=('Safari', 'Docs')), \
             patch.object(aurel, 'hands_map', return_value=seen), patch.object(aurel, 'running_apps', return_value=['Safari', 'Slack']), \
             patch.object(aurel, 'wait_commit', return_value=True), patch.object(aurel, 'llm', return_value='ai') as llm:
            self.assertIsNone(aurel.local_route('which hub is the best deal'))
            prompt = llm.call_args.args[0][1]['content']
            self.assertIn('Front app: Safari, window "Docs"\nOpen apps: Safari, Slack\nControls:\n1 button: Back\n2 box: Search', prompt)
            self.assertEqual(llm.call_args.kwargs['grammar'], aurel.ROUTER_GRAMMAR)
            llm.return_value = 'click 2'
            with patch.object(aurel, 'route_line', return_value='Clicked “Search”.'):
                self.assertEqual(aurel.local_route('click search'), ('Clicked “Search”.', 'click 2'))
            llm.return_value = 'open Muse'
            with patch.object(aurel, 'route_line') as routed:
                self.assertIsNone(aurel.local_route('switch to Muse and tell it, please wait.'))   # half an ask: the full ask does both steps
            routed.assert_not_called()
        with patch.object(aurel, 'llm_url', return_value=''):
            self.assertIsNone(aurel.local_route('switch to slack'))   # no model: the full ask decides

    def test_step_loop_runs_gated_commands_and_returns_the_answer(self):
        replies = iter([{'tool_calls': [{'id': 'a', 'function': {'arguments': json.dumps({'command': 'echo hi'})}},
                                        {'id': 'b', 'function': {'arguments': json.dumps({'command': 'rm -rf /'})}}]},
                        {'content': 'Done, it said hi.'}])
        seen = []
        def llm(messages, **k):
            seen.append(json.loads(json.dumps(messages)))
            return next(replies)
        gate = lambda c: (True, '') if c == 'echo hi' else (False, 'Aurel always blocks this command.')
        with patch.object(aurel, 'llm_url', return_value='http://x'), patch.object(aurel, 'wait_commit', return_value=True), \
             patch.object(aurel, 'llm', side_effect=llm), patch.object(aurel, 'local_gate', side_effect=gate):
            reply, cost, _ = aurel.run('say hi', ())
        self.assertEqual((reply, cost, aurel.run.ok, aurel.run.cmds), ('Done, it said hi.', 0, True, ['echo hi']))
        tools = [m for m in seen[1] if m['role'] == 'tool']
        self.assertEqual([t['content'] for t in tools], ['hi', 'Aurel always blocks this command.'])

    def test_step_loop_never_counts_written_commands_as_done(self):
        written = {'content': f'{aurel.ME} --hands see Muse\n{aurel.ME} --type "hello world"'}
        for replies, want, ok, ran in (([written, {'tool_calls': [{'id': 'a', 'function': {'arguments': json.dumps({'command': 'echo hi'})}}]},
                                         {'content': 'Sent.'}], 'Sent.', True, ['echo hi']),   # nudged once, then it ran them
                                        ([written, written], 'nothing was done', False, [])):
            replies = iter(replies)
            with patch.object(aurel, 'llm', side_effect=lambda *a, **k: next(replies)) as llm, patch.object(aurel, 'local_gate', return_value=(True, '')), \
                 patch.object(aurel.subprocess, 'run', return_value=Mock(stdout='hi', stderr='', returncode=0)):
                aurel.run.ok = False
                reply, got = aurel.local_loop([{'role': 'user', 'content': 'send hello world in Muse'}], aurel.time.monotonic() + 60)
            self.assertIn(want, reply); self.assertEqual((aurel.run.ok, got), (ok, ran))
            self.assertEqual([c.kwargs['tool_choice'] for c in llm.call_args_list][:2], [None, 'required'])   # the written turn is asked again, a call required
            self.assertNotIn(written['content'], [m.get('content') for m in llm.call_args.args[0]])   # and the written commands never become history

    def test_step_loop_never_reports_success_when_every_aurel_step_failed(self):
        # Gemma ran "--web click 1" five times for the same refusal, then said it searched Amazon and clicked a result.
        call = lambda c: {'tool_calls': [{'id': 'a', 'function': {'arguments': json.dumps({'command': c})}}]}
        click, typed = f'{aurel.ME} --web click 1', f'{aurel.ME} --web type-after "Search" "toothbrush"'
        refused = Mock(stdout=f"That page is in the user's own window; agents only read it. To act on it, open its URL in this task's window: {aurel.ME} --web read <url>\n",
                       stderr='', returncode=1)
        claim = {'content': 'I searched for "toothbrush" on Amazon.ca and clicked the first result.'}
        for replies, outputs, want, ok in (
                ([call(click), call(click), claim], [refused, refused], "That didn't work: That page is in the user's own window; agents only read it.", False),   # same failure twice: stopped
                ([call(click), call(typed), claim], [refused, refused], "That didn't work: That page is in the user's own window; agents only read it.", False),   # all failed: no claim
                ([call(click), call(f'{aurel.ME} --web search "amazon toothbrush"'), {'content': 'I found search results for "amazon toothbrush". Which result would you like to visit?'}],
                 [refused, Mock(stdout=f'There is no --web search. Use {aurel.ME} --web read "<url>".', stderr='', returncode=1)], "That didn't work: There is no --web search.", False),
                ([call(click), {'content': 'I could not click it: that page is in your window.'}], [refused], 'I could not click it', True),   # an admission stays
                ([call(click), call('echo done'), claim], [refused, Mock(stdout='done', stderr='', returncode=0)], claim['content'], True),   # something worked
                ([call('pgrep -x Spotify'), {'content': 'Spotify is not running.'}], [Mock(stdout='', stderr='', returncode=1)], 'Spotify is not running.', True)):   # a shell exit 1 is an answer
            replies, outputs = iter(replies), iter(outputs)
            with patch.object(aurel, 'llm', side_effect=lambda *a, **k: next(replies)), patch.object(aurel, 'local_gate', return_value=(True, '')), \
                 patch.object(aurel.subprocess, 'run', side_effect=lambda *a, **k: next(outputs)), patch.object(aurel, 'trace'):
                aurel.run.ok = False
                messages = [{'role': 'user', 'content': 'use Bosk and look for a toothbrush on amazon'}]
                reply, _ = aurel.local_loop(messages, aurel.time.monotonic() + 60)
            self.assertIn(want, reply); self.assertNotIn(aurel.ME, reply); self.assertEqual(aurel.run.ok, ok, want)
            self.assertEqual(messages[-1], {'role': 'assistant', 'content': reply})   # a follow-up sees what the user was told

    def test_web_rejects_made_up_commands_and_bare_sites_instead_of_reading_the_page(self):
        # "--web search" read the user's page with the words as an offset and exited 0, so the loop let "I found results" through.
        with patch.object(aurel, 'browser_adapter') as adapter:
            for args in (('search', 'amazon toothbrush'), ('open', 'https://amazon.ca'), ('read', 'amazon.ca'), ('read', '-1')):
                out = aurel.web(*args)
                self.assertIsInstance(out, aurel.Failure, args); self.assertIn('read "', out, args)
            adapter.assert_not_called()   # never touched a browser

    def test_step_loop_without_the_model_asks_for_setup(self):
        with patch.object(aurel, 'llm_url', return_value=''), patch.object(aurel, 'say') as say, patch.dict(os.environ, {'AUREL_LLM_READY': ''}):
            reply, _, _ = aurel.run('say hi', ())
        say.assert_called_with('!', 'setup')
        self.assertIn('Download the local model', reply)
        with patch.object(aurel, 'llm_url', return_value=''), patch.object(aurel, 'say') as say:
            reply, _, _ = aurel.run('say hi', ())   # downloaded, but it didn't start
        say.assert_not_called()
        self.assertEqual(reply, 'The local model didn’t start. Try again, or check Settings → Intelligence.')

    def test_bigger_asks_can_go_to_claude(self):
        with patch.object(aurel, 'pref', side_effect=lambda k, d: {'client': 'local', 'bigAsks': 'claude'}.get(k, d)), patch.object(aurel, 'big_ask', return_value=True), \
             patch.object(aurel, 'run_local') as local, patch.object(aurel, 'start_claude', return_value=None), patch.object(aurel, 'say'):
            aurel.run('research usb hubs')
        local.assert_not_called()

    def test_asks_with_pictures_can_go_to_claude(self):
        shot = [('/tmp/aurel-point-1.jpg', 'User-drawn mark')]
        for prefs, shots, local_runs in [({'claudeSees': True}, shot, False),   # Claude sees the mark
                                         ({'claudeSees': True}, (), True),      # no picture: stays on this Mac
                                         ({'claudeSees': False}, shot, True)]:    # off (the default): everything stays local
            prefs = {'client': 'local', **prefs}
            with patch.object(aurel, 'pref', side_effect=lambda k, d: prefs.get(k, d)), patch.object(aurel, 'big_ask', return_value=False), \
                 patch.object(aurel, 'run_local', return_value=('ok', 0, [])) as local, patch.object(aurel, 'start_claude', return_value=None), patch.object(aurel, 'say'):
                aurel.run('what is this', shots=shots)
            self.assertEqual(local.called, local_runs, (prefs, shots))

    def test_reading_another_app_aloud_goes_to_claude(self):
        for on, task, local_runs in [(True, "Read Muse's last reply to me", False),
                                     (True, 'read me what Slack says', False),
                                     (True, 'read this page out loud', False),
                                     (True, 'what is the weather', True),             # not a read-aloud ask: stays local
                                     (False, "Read Muse's last reply to me", True)]:  # off (the default): everything stays local
            prefs = {'client': 'local', 'readWindows': on}
            with patch.object(aurel, 'pref', side_effect=lambda k, d: prefs.get(k, d)), patch.object(aurel, 'big_ask', return_value=False), \
                 patch.object(aurel, 'run_local', return_value=('ok', 0, [])) as local, patch.object(aurel, 'start_claude', return_value=None), patch.object(aurel, 'say'):
                aurel.run(task)
            self.assertEqual(local.called, local_runs, (on, task))

    def test_read_last_reply_cuts_it_from_the_window_without_claude(self):
        # Muse's own markers: the reply between "Copy response · Reply" and "React · Reply · More options", its code buttons left out
        muse = ('Older reply.\nReact\nReply\nMore options\nYou:\nwhat’s next?\nMore options\nCopy response\nReply\n'
                'Done. The audit is\nDownload file\nCopy Code\nback and SE-03 holds.\nReact\nReply\nMore options\nMessage in Main chat\nSend')
        # another app: the local model names the lines, Aurel widens them to the buttons around them
        other = 'Older.\nReply\nYou:\nhi\nReply\nHello there,\nhow can I help?\nReply\nSend'
        prefs = {'client': 'local'}
        def ask(app, window, marks=None, said=None):
            read = aurel.subprocess.CompletedProcess([], 0, json.dumps({'text': window}), '')
            with patch.object(aurel, 'pref', side_effect=lambda k, d: prefs.get(k, d)), patch.object(aurel, 'app_named', return_value=app), \
                 patch.object(aurel, 'llm_url', return_value='http://fixture'), patch.object(aurel, 'hands_call', return_value=read) as hands, \
                 patch.object(aurel, 'llm', return_value=json.dumps(marks)) as llm, patch.object(aurel, 'trace'):
                reply = aurel.fast(said or f"Read {app}'s last reply to me")
            return reply, aurel.fast.aloud, hands.call_args, llm.called
        reply, aloud, call, used_model = ask('Muse', muse)
        self.assertEqual(reply, 'Done. The audit is\nback and SE-03 holds.')   # word for word, no AI
        self.assertTrue(aloud); self.assertFalse(used_model)
        self.assertEqual(call.args[0], ['read', 'Muse', 'tail'])
        with patch.dict(os.environ, {'AUREL_FRONT': 'Muse'}):   # "its": the app in front, no name to look up
            self.assertEqual(ask(None, muse, said='Read its last message.')[0], 'Done. The audit is\nback and SE-03 holds.')
        self.assertEqual(ask('Chat', other, {'first': 5, 'last': 5})[:2], ('Hello there,\nhow can I help?', True))   # the model was a line short
        self.assertEqual(ask('Chat', other, {'first': 5, 'last': 40})[:2], ("I couldn't find Chat's last reply.", False))   # no such line, no Claude: says so
        prefs['readWindows'] = True
        self.assertEqual(ask('Chat', other, {'first': 5, 'last': 4})[:2], (None, False))   # Claude fallback on: Claude takes it
        prefs['client'] = 'claude'
        self.assertEqual(ask('Muse', muse)[0], 'Done. The audit is\nback and SE-03 holds.')   # markers need no model, on any client
        self.assertEqual(ask('Chat', other, {'first': 5, 'last': 5})[:2], (None, False))   # no local model: Claude reads it

    def test_tell_an_open_app_types_and_sends_without_ai(self):
        sent = []
        with patch.object(aurel, 'installed_apps', return_value=['Muse', 'ChatGPT', 'Slack', 'News', 'Notes']), \
             patch.object(aurel, 'running_apps', return_value=['Muse', 'ChatGPT', 'Slack']), patch.object(aurel, 'trace'), \
             patch.object(aurel, 'route_line', side_effect=lambda line, front: sent.append(line) or 'Sent.') as route, patch.dict(os.environ, {'AUREL_FRONT': 'Muse'}):
            def tell(said):
                sent.clear(); return aurel.fast(said), (sent[0] if sent else None)
            self.assertEqual(tell('Tell Muse Hello World'), ('Sent.', 'type "Hello World" in Muse send'))   # the user's own case
            self.assertEqual(tell('Atticus tell Muse I am back')[1], 'type "I am back" in Muse send')   # the old name, and "Muse I" is not an app
            self.assertEqual(tell('R L tell Muse, that I agree.')[1], 'type "I agree." in Muse send')
            self.assertEqual(tell('Tell mules hi there')[1], 'type "hi there" in Muse send')   # a running app, misheard by a letter or two
            self.assertEqual(tell('Tell Muse what is needed for the analysis. Um')[1], 'type "what is needed for the analysis" in Muse send')
            for said in ['tell Sam hi', 'tell Slack I am late', 'tell me a joke', 'send an email to Sam', 'Tell news hello']:
                self.assertEqual(tell(said), (None, None), said)   # a person, a people chat, no app, an app not open: the full ask
            with patch.dict(os.environ, {'AUREL_LIVE': '1'}):
                self.assertEqual(tell('Tell Muse hello'), (None, None))   # mid-sentence: never send half a message

    def test_only_big_asks_go_to_claude(self):
        prefs = {'client': 'local', 'bigAsks': 'local'}
        with patch.object(aurel, 'pref', side_effect=lambda k, d: prefs.get(k, d)), patch.object(aurel, 'llm_url', return_value='http://fixture'), \
             patch.object(aurel, 'llm', side_effect=lambda m, **kw: 'big' if 'research' in m[1]['content'] else 'small') as llm:
            self.assertEqual(aurel.agent_model('research usb hubs'), 'local', 'Bigger asks: Local never uses Claude')
            llm.assert_not_called()
            prefs['bigAsks'] = 'claude'
            self.assertEqual(aurel.agent_model('send alex a message in Muse'), 'local')
            self.assertNotEqual(aurel.agent_model('research usb hubs'), 'local')
            self.assertEqual(aurel.agent_model(), 'local', 'a prewarmed worker has no ask yet')
        with patch.object(aurel, 'llm_url', return_value='http://fixture'), patch.object(aurel, 'llm', side_effect=OSError):
            self.assertFalse(aurel.big_ask('research usb hubs'), 'the model failing keeps it local')

    def test_a_rule_the_model_only_claims_to_keep_is_saved(self):
        def ask(request, *replies):
            replies = iter(replies)
            with patch.object(aurel, 'llm_url', return_value='http://x'), patch.object(aurel, 'wait_commit', return_value=True), \
                 patch.object(aurel, 'llm', side_effect=lambda *a, **k: next(replies)), patch.object(aurel, 'local_gate', return_value=(True, '')):
                aurel.run('Context: …\n\n' + request, (), request=request)
        with patch.object(aurel, 'MEMORY', str(self.root / 'memory.md')):
            ask('Remember that I like my answers short.', {'content': 'Aurel remembers your preference for short answers.'})
            ask('From now on, call me Tom.', {'content': 'I will call you Tom.'})
            ask('Remember how to file my taxes', {'content': 'Okay.'})
            ask("What's the weather?", {'content': 'Sunny.'})
            ask('Remember that my bank password is hunter2.', {'content': 'Got it.'})
            ask('Remember to send the report.', {'tool_calls': [{'id': 'a', 'function': {'arguments': json.dumps({'command': 'true'})}}]}, {'content': 'Reminder set.'})
            self.assertEqual(aurel.memory_rules(), ['I like my answers short', 'From now on, call me Tom'])

    def test_local_agent_speaks_the_agent_stream(self):
        replies = iter([{'tool_calls': [{'id': '1', 'function': {'arguments': json.dumps({'command': 'echo hi'})}}]}, {'content': 'Sent.'}])
        stdin = '\n'.join(json.dumps(e) for e in ({'type': 'control_request', 'request_id': 'initialize', 'request': {'subtype': 'initialize'}},
                                                  {'type': 'user', 'message': {'role': 'user', 'content': 'send hi in Muse'}})) + '\n'
        with patch.object(aurel, 'llm', side_effect=lambda *a, **kw: next(replies)), patch.object(aurel, 'local_gate', return_value=(True, '')), \
             patch.object(aurel.sys, 'stdin', __import__('io').StringIO(stdin)), patch('builtins.print') as out:
            aurel.local_agent()
        events = [json.loads(c.args[0]) for c in out.call_args_list]
        self.assertEqual([e['type'] for e in events], ['control_response', 'assistant', 'assistant', 'result'])
        self.assertEqual(events[0]['response']['request_id'], 'initialize')
        self.assertEqual(events[1]['message']['content'][0]['input'], {'command': 'echo hi'})
        self.assertEqual((events[3]['result'], events[3]['is_error']), ('Sent.', False))

    def test_local_agent_follow_up_keeps_the_conversation(self):
        def turn(text, reply):
            seen = []
            stdin = json.dumps({'type': 'user', 'message': {'role': 'user', 'content': text}}) + '\n'
            with patch.object(aurel, 'llm', side_effect=lambda m, **kw: seen.append([dict(x) for x in m]) or {'content': reply}), \
                 patch.object(aurel.sys, 'stdin', __import__('io').StringIO(stdin)), patch('builtins.print'):
                aurel.local_agent()
            return seen[-1]
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {'AUREL_ASK': folder}):
            turn('what is taking so much cpu?', 'Chrome, at 80%.')
            messages = turn('why?', 'It has many tabs open.')   # the task ended: a new process, as after finish()
        self.assertEqual([(m['role'], m['content']) for m in messages[1:]],
                         [('user', 'what is taking so much cpu?'), ('assistant', 'Chrome, at 80%.'), ('user', 'why?')])

    def test_dictation_cleanup_uses_the_local_model(self):
        with patch.object(aurel, 'llm', return_value='<cleaned>We need to deploy the app today.</cleaned>') as llm:
            self.assertEqual(aurel.dictate_cleanup('um we need to deploy the app today'), 'We need to deploy the app today.')
        self.assertEqual(llm.call_args.args[0][0]['content'], aurel.DICTATE_SYSTEM)

    def test_key_down_reads_the_ask_prompt_once_then_restores_it(self):
        slots = Path(self.root, 'llm', 'slots'); slots.mkdir(parents=True)
        (slots / 'ask-stale.bin').write_text('old prompt')
        saved = []
        def slot_file(action, name):
            if action == 'save': (slots / name).write_text('kv'); saved.append(name)
            return action == 'save' or (slots / name).exists()
        def warm(url):
            with patch.object(aurel, 'llm') as llm, patch.object(aurel, 'slot_file', side_effect=slot_file) as slot, patch.object(aurel, 'llm_url', return_value=url):
                aurel.local_prewarm()
            return [(c.args[0][0]['content'][:40], c.kwargs.get('slot')) for c in llm.call_args_list], [c.args[0] for c in slot.call_args_list]
        system = aurel.local_system()[:40]
        calls, actions = warm('http://one')   # first time: read it into slot 0 and save it; an older settings' copy goes
        self.assertEqual(calls, [(system, 0), (aurel.ROUTER[:40], 1), (aurel.READ_LAST_PROMPT[:40], 1)])
        self.assertEqual(actions, ['save']); self.assertEqual([p.name for p in slots.glob('ask-*.bin')], saved)
        prompts = [(aurel.ROUTER[:40], 1), (aurel.READ_LAST_PROMPT[:40], 1)]
        self.assertEqual(warm('http://one'), (prompts, []))   # same server: already there, nothing restored or saved
        self.assertEqual(warm('http://two'), (prompts, ['restore']))   # a reloaded model: from disk, not saved again

    def test_local_asks_ask_only_for_risky_commands(self):
        def gate(command):
            with patch.object(aurel.sys, 'stdin', __import__('io').StringIO(json.dumps({'tool_name': 'exec', 'tool_input': {'command': command}}))), \
                 patch.object(aurel, 'wait_commit', return_value=True), patch.object(aurel, 'ask_user', return_value='n') as ask, \
                 patch.object(aurel, 'pref', side_effect=lambda k, d: True if k == 'safe' else d), patch('builtins.print') as out, \
                 patch.dict(os.environ, {'AUREL_CLIENT': 'local'}):
                try: aurel.gate()
                except SystemExit: pass
            return ask.called, json.loads(out.call_args.args[0])['decision']
        self.assertEqual(gate('mdfind -name notes'), (False, 'approve'))
        self.assertEqual(gate('trash "/tmp/report.pdf"'), (True, 'block'))
        self.assertEqual(gate('sudo ls')[1], 'block')


if __name__ == '__main__':
    unittest.main()
