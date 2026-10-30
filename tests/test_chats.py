"""Saved chats with scratch state and fake asks; execute through the VM runner only."""
import json
import os
from pathlib import Path
import shlex
import tempfile
import unittest
from unittest.mock import patch

import aurel


class ChatTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.prefs = {'saveChats': True, 'screen': 'never', 'learn': False, 'routing': 'cheapest'}
        p = patch.multiple(aurel, DIR=tmp.name, HOME=tmp.name, RECENT=str(self.root/'recent.jsonl'),
                           PREFS=str(self.root/'settings.json'), WORKED=str(self.root/'worked.json'),
                           pref=lambda k,d:self.prefs.get(k,d))
        p.start(); self.addCleanup(p.stop)

    def turn(self, t=1, q='First question', a='Answer'):
        return {'t': t, 'q': q, 'a': a}

    def test_classification_uses_results_and_read_receipts(self):
        helper = shlex.quote(aurel.ME)
        for ran in ([], ['<Read>'], ['<WebSearch>', '<WebFetch>'], [f'python3 {helper} --window']):
            self.assertTrue(aurel.plain_chat(True, False, None, 'ask', 'ask', ran), ran)
        for ran in (['open -a Notes'], [f'python3 {helper} --draw'], ['<Bash>'], ['<Unknown>']):
            self.assertFalse(aurel.plain_chat(True, False, None, 'ask', 'ask', ran), ran)
        for ok, failed, replacement, task in ((False,False,None,'ask'), (True,True,None,'ask'),
                                              (True,False,'draft','ask'), (True,False,None,'remaining')):
            self.assertFalse(aurel.plain_chat(ok, failed, replacement, task, 'ask', []))

    def ask(self, question, answer, ran=(), ok=True):
        def fake(*args, **kwargs):
            worker.ok = ok; worker.work = False; worker.ran = list(ran); worker.cmds = []
            worker.observed = []; worker.handoff = None; worker.handoffs = []; worker.why = ''
            return answer, 0, []
        with patch.multiple(aurel, fast=lambda _:None,
                            front=lambda:('Fixture','Window'), osa=lambda *_:'', screens=lambda:[],
                            describe=lambda *_:'Fixture', me_line=lambda:'', selection_context=lambda:'',
                            relevant_rules=lambda _:'', workflows=lambda *args:'', tool_help=lambda *args,**kw:'',
                            memory_items=lambda:set(), memory_receipt=lambda _: '', relay=lambda *args:None,
                            log_turn=lambda *args,**kw:None, restore_focus=lambda *args:None, tip=lambda *args:None,
                            allow_focus=lambda *args:None), \
             patch.object(aurel, 'run', side_effect=fake) as worker, patch.object(aurel,'say'), \
             patch.dict(os.environ, {'AUREL_UI':'0','AUREL_COMMIT':''}), \
             patch('sys.argv', ['aurel.py', question]):
            aurel.main()
        return worker.call_args.args[0]

    def test_real_asks_continue_reset_and_never_load_saved_context(self):
        self.ask('First private topic', 'Unique saved answer')
        self.ask('Tell me more', 'Second answer', ['<WebSearch>'])
        chats = aurel.saved_chats()
        self.assertEqual(len(chats), 1)
        self.assertEqual(len(chats[0]['turns']), 2)
        self.ask('Action request', 'Opened.', ['open -a Notes'])
        self.assertEqual(aurel.saved_chats(), chats)
        (self.root/'recent.jsonl').unlink()
        prompt = self.ask('Fresh topic', 'Fresh answer')
        self.assertEqual(len(aurel.saved_chats()), 2)
        self.assertNotIn('First private topic', prompt)
        self.assertNotIn('Unique saved answer', prompt)
        self.assertEqual(aurel.agent_history(), [])
        self.assertNotIn('Unique saved answer', aurel.agent_context('First private topic'))

    def test_save_setting_off_keeps_existing_chats(self):
        self.ask('Saved topic', 'Saved answer')
        saved = aurel.saved_chats()
        self.prefs['saveChats'] = False
        self.ask('Unsaved topic', 'Unsaved answer')
        self.assertEqual(aurel.saved_chats(), saved)
        (self.root/'chats.json').unlink()
        self.ask('Still off', 'Answer')
        self.assertFalse((self.root/'chats.json').exists())

    def test_cap_and_private_storage(self):
        previous = None
        for n in range(55):
            turn = self.turn(n)
            aurel.update_chats(turn=turn, previous=previous); previous = turn
        self.assertEqual(len(aurel.saved_chats()[0]['turns']), 50)
        aurel.update_chats(turn=self.turn(100, a='界'*350000))
        chats = aurel.saved_chats()
        self.assertEqual(len(chats), 1)
        self.assertEqual(chats[0]['created'], 100)
        self.assertLessEqual((self.root/'chats.json').stat().st_size, 1_000_000)
        for name in ('chats.json', 'chats.lock'):
            self.assertEqual((self.root/name).stat().st_mode & 0o777, 0o600)

    def test_delete_command(self):
        aurel.update_chats(turn=self.turn(1)); aurel.update_chats(turn=self.turn(2, q='Second'))
        events = []
        manager = aurel.Agents(emit=events.append, launch=lambda _:None)
        self.addCleanup(manager.close)
        keep, gone = (c['id'] for c in aurel.saved_chats()[::-1])
        manager.command({'action':'chat-delete', 'id':gone})
        self.assertEqual([c['id'] for c in aurel.saved_chats()], [keep])
        self.assertEqual(events[-1], {'event':'chats', 'chats':aurel.saved_chats()})
        before = len(events)
        manager.command({'action':'chat-delete', 'id':'unknown'})
        self.assertEqual(len(events), before)

    def test_rename_command_validation_and_delivery(self):
        aurel.update_chats(turn=self.turn())
        events = []
        manager = aurel.Agents(emit=events.append, launch=lambda _:None)
        self.addCleanup(manager.close)
        identifier = aurel.saved_chats()[0]['id']
        manager.command({'action':'chats'})
        self.assertEqual(events[-1]['chats'], aurel.saved_chats())
        manager.command({'action':'rename', 'id':identifier, 'title':'  New title  '})
        self.assertEqual(aurel.saved_chats()[0]['title'], 'New title')
        self.assertEqual(events[-1], {'event':'chats', 'chats':aurel.saved_chats()})
        saved = (self.root/'chats.json').read_bytes()
        for title in ('', '  ', 12, None, []):
            manager.command({'action':'rename','id':identifier,'title':title})
        before = len(events)
        manager.command({'action':'rename','id':'unknown','title':'Ignored'})
        self.assertEqual(len(events), before)
        self.assertEqual((self.root/'chats.json').read_bytes(), saved)
        events.clear(); manager.tick()
        self.assertTrue(any(e.get('event') == 'chats' for e in events))
        self.assertFalse(manager.rows)
