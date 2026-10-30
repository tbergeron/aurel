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
        for task, line, elsewhere in [('Tell Muse hello world', 'type "hello world" in Muse send', False),
                                      ('Send hello world in Muse', 'type "hello world" in Muse send', False),
                                      ('Say Hello World in Muse.', 'type "Hello World" in Muse send', False),
                                      ('tell Sam I am late in Messages', 'type "I am late" in Messages send', True),   # whichever chat is open
                                      ('reply and say I am in', 'type "I am in" in Claude send', True),
                                      ('send hello', 'type "hello" send', True),
                                      ('say hello there', 'type "hello there"', False)]:
            self.assertEqual(aurel.quick_send_elsewhere(task, line), elsewhere, task)

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

    def test_key_down_prewarms_both_prompts(self):
        with patch.object(aurel, 'llm') as llm:
            aurel.local_prewarm()
        self.assertEqual([c.args[0][0]['content'][:40] for c in llm.call_args_list], [aurel.ROUTER[:40], aurel.system_prompt(aurel.ASK_FIRST)[:40]])
        self.assertTrue(all(c.kwargs['max_tokens'] == 1 for c in llm.call_args_list))

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
