"""Local client (Settings → Intelligence → Local): the router, the step loop and one-shot calls, with the model mocked."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import atticus


class LocalTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        for p in (patch.multiple(atticus, DIR=str(self.root), TURN={}, CLIENT_DEFAULT='local'),
                  patch.object(atticus, 'pref', side_effect=lambda k, d: 'local' if k == 'client' else d),
                  patch.dict(os.environ, {'ATTICUS_ASK': str(self.root), 'ATTICUS_LLM': 'http://127.0.0.1:1', 'ATTICUS_LLM_READY': '1'})):
            p.start(); self.addCleanup(p.stop)

    def test_local_is_the_default_client_and_needs_only_its_download(self):
        self.assertEqual(atticus.client(), 'local')
        self.assertTrue(atticus.plan()['ok'])
        with patch.dict(os.environ, {'ATTICUS_LLM_READY': ''}):
            self.assertEqual(atticus.plan(), {'ok': False, 'need': 'download', 'client': 'local', 'text': 'Download the local model in Settings → Intelligence.'})

    def test_router_lines_run_as_the_fast_commands(self):
        said = []
        fast = lambda t: said.append(t) or f'did {t}'
        with patch.object(atticus, 'fast', side_effect=fast):
            for line, want in [('open Slack', 'open Slack'), ('scroll down bit', 'scroll down a bit'), ('scroll top', 'scroll to the top'),
                               ('scroll bottom', 'scroll to the bottom'), ('scroll up', 'scroll up'), ('press cmd+t', 'press cmd+t'),
                               ('move to left', 'move this to the left'), ('move Chrome to monitor', 'move Chrome to the monitor')]:
                self.assertEqual(atticus.route_line(line, 'Safari'), f'did {want}')
        hands = Mock(return_value=('Clicked “Send”.\nmore', True))
        with patch.object(atticus, 'hands', hands):
            self.assertEqual(atticus.route_line('click 6', 'Messages'), 'Clicked “Send”.')
            self.assertEqual(atticus.route_line('type "on my way" field 5', 'Messages'), 'Clicked “Send”.')
        self.assertEqual([c.args for c in hands.call_args_list], [('click', '6'), ('type', '5', 'on my way')])

    def test_router_types_into_another_app_after_opening_it(self):
        with patch.object(atticus, 'fast', return_value='Opened Messages.') as fast, patch.object(atticus, 'app_named', return_value='Messages'), \
             patch.object(atticus.subprocess, 'run', return_value=Mock(returncode=0)) as run, patch.object(atticus, 'hands') as hands:
            self.assertEqual(atticus.route_line('type "running late" in Messages field 3', 'Safari'), 'Typed “running late”.')
        fast.assert_called_once_with('open Messages'); hands.assert_not_called()   # field 3 was Safari's: type at the cursor instead
        self.assertEqual(run.call_args.kwargs['input'], 'running late')

    def test_route_hands_bigger_asks_on_and_reads_the_window(self):
        seen = {'description': '1 button: Back\n2 box: Search'}
        with patch.object(atticus, 'llm_url', return_value='http://x'), patch.object(atticus, 'front', return_value=('Safari', 'Docs')), \
             patch.object(atticus, 'hands_map', return_value=seen), patch.object(atticus, 'running_apps', return_value=['Safari', 'Slack']), \
             patch.object(atticus, 'wait_commit', return_value=True), patch.object(atticus, 'llm', return_value='ai') as llm:
            self.assertIsNone(atticus.local_route('which hub is the best deal'))
            prompt = llm.call_args.args[0][1]['content']
            self.assertIn('Front app: Safari, window "Docs"\nOpen apps: Safari, Slack\nControls:\n1 button: Back\n2 box: Search', prompt)
            self.assertEqual(llm.call_args.kwargs['grammar'], atticus.ROUTER_GRAMMAR)
            llm.return_value = 'click 2'
            with patch.object(atticus, 'route_line', return_value='Clicked “Search”.'):
                self.assertEqual(atticus.local_route('click search'), ('Clicked “Search”.', 'click 2'))
        with patch.object(atticus, 'llm_url', return_value=''):
            self.assertIsNone(atticus.local_route('switch to slack'))   # no model: the full ask decides

    def test_step_loop_runs_gated_commands_and_returns_the_answer(self):
        replies = iter([{'tool_calls': [{'id': 'a', 'function': {'arguments': json.dumps({'command': 'echo hi'})}},
                                        {'id': 'b', 'function': {'arguments': json.dumps({'command': 'rm -rf /'})}}]},
                        {'content': 'Done, it said hi.'}])
        seen = []
        def llm(messages, **k):
            seen.append(json.loads(json.dumps(messages)))
            return next(replies)
        gate = lambda c: (True, '') if c == 'echo hi' else (False, 'Atticus always blocks this command.')
        with patch.object(atticus, 'llm_url', return_value='http://x'), patch.object(atticus, 'wait_commit', return_value=True), \
             patch.object(atticus, 'llm', side_effect=llm), patch.object(atticus, 'local_gate', side_effect=gate):
            reply, cost, _ = atticus.run('say hi', ())
        self.assertEqual((reply, cost, atticus.run.ok, atticus.run.cmds), ('Done, it said hi.', 0, True, ['echo hi']))
        tools = [m for m in seen[1] if m['role'] == 'tool']
        self.assertEqual([t['content'] for t in tools], ['hi', 'Atticus always blocks this command.'])

    def test_step_loop_without_the_model_asks_for_setup(self):
        with patch.object(atticus, 'llm_url', return_value=''), patch.object(atticus, 'say') as say, patch.dict(os.environ, {'ATTICUS_LLM_READY': ''}):
            reply, _, _ = atticus.run('say hi', ())
        say.assert_called_with('!', 'setup')
        self.assertIn('Download the local model', reply)
        with patch.object(atticus, 'llm_url', return_value=''), patch.object(atticus, 'say') as say:
            reply, _, _ = atticus.run('say hi', ())   # downloaded, but it didn't start
        say.assert_not_called()
        self.assertEqual(reply, 'The local model didn’t start. Try again, or check Settings → Intelligence.')

    def test_bigger_asks_can_go_to_claude(self):
        with patch.object(atticus, 'pref', side_effect=lambda k, d: {'client': 'local', 'bigAsks': 'claude'}.get(k, d)), \
             patch.object(atticus, 'run_local') as local, patch.object(atticus, 'start_claude', return_value=None), patch.object(atticus, 'say'):
            atticus.run('research usb hubs')
        local.assert_not_called()

    def test_dictation_cleanup_uses_the_local_model(self):
        with patch.object(atticus, 'llm', return_value='<cleaned>We need to deploy the app today.</cleaned>') as llm:
            self.assertEqual(atticus.dictate_cleanup('um we need to deploy the app today'), 'We need to deploy the app today.')
        self.assertEqual(llm.call_args.args[0][0]['content'], atticus.DICTATE_SYSTEM)

    def test_key_down_prewarms_both_prompts(self):
        with patch.object(atticus, 'llm') as llm:
            atticus.local_prewarm()
        self.assertEqual([c.args[0][0]['content'][:40] for c in llm.call_args_list], [atticus.ROUTER[:40], atticus.system_prompt(atticus.ASK_FIRST)[:40]])
        self.assertTrue(all(c.kwargs['max_tokens'] == 1 for c in llm.call_args_list))

    def test_local_asks_ask_only_for_risky_commands(self):
        def gate(command):
            with patch.object(atticus.sys, 'stdin', __import__('io').StringIO(json.dumps({'tool_name': 'exec', 'tool_input': {'command': command}}))), \
                 patch.object(atticus, 'wait_commit', return_value=True), patch.object(atticus, 'ask_user', return_value='n') as ask, \
                 patch.object(atticus, 'pref', side_effect=lambda k, d: True if k == 'safe' else d), patch('builtins.print') as out, \
                 patch.dict(os.environ, {'ATTICUS_CLIENT': 'local'}):
                try: atticus.gate()
                except SystemExit: pass
            return ask.called, json.loads(out.call_args.args[0])['decision']
        self.assertEqual(gate('mdfind -name notes'), (False, 'approve'))
        self.assertEqual(gate('trash "/tmp/report.pdf"'), (True, 'block'))
        self.assertEqual(gate('sudo ls')[1], 'block')


if __name__ == '__main__':
    unittest.main()
