"""Crash, pipe and error-text handling, without network access."""
import io
import os
from pathlib import Path
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import aurel


class CrashHandlingTests(unittest.TestCase):
    def test_error_text_drops_text_applescript_types_or_writes(self):
        steps = ['osascript -e \'tell application "System Events" to keystroke "hunter2"\'',
                 'osascript -e \'tell application "Notes" to make new note with properties {name:"Diary", body:"private words"}\'',
                 'osascript -e \'tell application "Notes" to set body of note 1 to "private words"\'']
        cleaned = ' '.join(map(aurel.clean, steps))
        self.assertFalse(any(word in cleaned for word in ('hunter2', 'Diary', 'private')))
        self.assertIn('tell application "Notes"', cleaned)

    def test_setup_problems_are_classified(self):
        for detail, why in [('OAuth session expired', 'signed_out'),
                            ('HTTP 429', 'rate_limited'), ('Rate limit reached for requests', 'rate_limited'),
                            ('You’ve hit your weekly limit · resets 3pm', 'plan_limit'), ('Context window limit reached', 'too_long'),
                            ('network connection failed', 'offline'), ('Unknown process failure', 'stopped')]:
            self.assertEqual(aurel.failure_why(detail), why)

    def test_allow_decisions_share_denial_without_matching_reply_text(self):
        with tempfile.TemporaryDirectory() as root, patch.object(aurel, 'DIR', root), \
             patch.dict(os.environ, {'AUREL_ASK': root}):
            marker = Path(root, 'declined')
            for question, answer, declined in [({'q': 'Send?', 'cmd': 'fixture'}, 'n', True),
                                                ({'q': 'Send?', 'cmd': 'fixture'}, 'y', False),
                                                ({'q': 'Send?', 'cmd': 'fixture'}, 'task', False),
                                                ({'pick': 'Which?', 'options': []}, '', False),
                                                ({'q': 'Retry?', 'retry': True}, 'n', False),
                                                ({'q': 'Permission?', 'need': 'screen'}, 'n', False)]:
                marker.unlink(missing_ok=True)
                def respond(path, data): Path(data['_a']).write_text(answer)
                with patch.object(aurel, 'private_json', side_effect=respond):
                    self.assertEqual(aurel.ask_user(question, 1), answer)
                self.assertEqual(marker.exists(), declined)
            aurel.ask_user({'q': 'Send?', 'cmd': 'fixture'}, 0)
            self.assertTrue(marker.exists())
            with patch.object(Path, 'touch', side_effect=FileNotFoundError):
                self.assertIsNone(aurel.ask_user({'q': 'Send?', 'cmd': 'fixture'}, 0))

    def test_question_after_ask_cleanup_is_cancelled_without_publishing_a_card(self):
        with tempfile.TemporaryDirectory() as root, patch.object(aurel, 'DIR', root), \
             patch.dict(os.environ, {'AUREL_ASK': str(Path(root, 'removed-ask'))}), \
             patch.object(aurel, 'private_json') as publish:
            directory = Path(root, 'removed-ask')
            directory.mkdir()
            open_lock = os.open
            def cancelled_before_lock(path, flags, mode):
                directory.rmdir()
                return open_lock(path, flags, mode)
            with patch.object(aurel.os, 'open', side_effect=cancelled_before_lock):
                self.assertIsNone(aurel.ask_user({'q': 'Send?', 'cmd': 'fixture'}, 60))
            self.assertIsNone(aurel.ask_user({'q': 'Send?', 'cmd': 'fixture'}, 60))
            publish.assert_not_called()
            self.assertFalse(Path(root, 'removed-ask').exists())

    def test_main_crash_ends_the_turn_and_exits_70(self):
        with patch.object(aurel, 'main', side_effect=RuntimeError('private detail')), \
             patch.object(aurel, 'end_turn') as end, patch('sys.stderr', io.StringIO()):
            with self.assertRaises(SystemExit) as stopped: aurel.run_main()
        self.assertEqual(stopped.exception.code, 70)
        end.assert_called_once_with('crashed')

    def test_normal_exits_and_a_closed_output_pipe_are_not_crashes(self):
        with patch.object(aurel, 'end_turn') as end:
            with patch.object(aurel, 'main', side_effect=SystemExit(0)):
                with self.assertRaises(SystemExit): aurel.run_main()
            reader, writer = os.pipe(); os.close(reader)
            with os.fdopen(writer, 'w') as output, patch.object(aurel, 'main', side_effect=BrokenPipeError), \
                 patch.object(aurel, 'stop_workers') as stop, patch('sys.stdout', output):
                aurel.run_main()
                sys.stdout.close()   # run_main replaced it with devnull
            stop.assert_called_once()
        end.assert_not_called()

    def test_a_failed_crash_checkpoint_still_exits_70(self):
        with patch.object(aurel, 'main', side_effect=ValueError('private detail')), \
             patch.object(aurel, 'end_turn', side_effect=OSError('unwritable log')), patch('sys.stderr', io.StringIO()):
            with self.assertRaises(SystemExit) as stopped: aurel.run_main()
        self.assertEqual(stopped.exception.code, 70)

    def test_thread_exit_is_normal_and_a_closed_relay_pipe_cancels_the_process(self):
        reader, writer = os.pipe(); os.close(reader)
        with os.fdopen(writer, 'w') as output, patch.object(threading, 'excepthook') as previous, \
             patch.object(aurel, 'stop_workers') as stop, patch('sys.stdout', output):
            aurel.install_exception_hooks()
            for error in (SystemExit(0), BrokenPipeError()):
                threading.excepthook(SimpleNamespace(exc_type=type(error), exc_value=error, exc_traceback=None))
            sys.stdout.close()
        stop.assert_called_once(); previous.assert_not_called()

    def test_a_daemon_thread_failing_during_shutdown_is_not_a_crash(self):
        with patch.object(threading, 'excepthook') as previous:
            aurel.install_exception_hooks()
            with patch.object(threading, 'main_thread', return_value=SimpleNamespace(is_alive=lambda: False)):
                threading.excepthook(SimpleNamespace(exc_type=ValueError, exc_value=ValueError(), exc_traceback=None))
            error = RuntimeError('cannot schedule new futures after interpreter shutdown')
            threading.excepthook(SimpleNamespace(exc_type=type(error), exc_value=error, exc_traceback=None))
            previous.assert_not_called()
            for detail in ('real worker failure', 'cannot schedule new futures after shutdown'):
                error = RuntimeError(detail)
                threading.excepthook(SimpleNamespace(exc_type=type(error), exc_value=error, exc_traceback=None))
        self.assertEqual(previous.call_count, 2)

    def test_a_backend_broken_pipe_with_live_output_is_a_real_failure(self):
        with patch.object(aurel, 'main', side_effect=BrokenPipeError), patch.object(aurel, 'end_turn'), \
             patch('sys.stdout', io.StringIO()), patch('sys.stderr', io.StringIO()):
            with self.assertRaises(SystemExit) as stopped: aurel.run_main()
        self.assertEqual(stopped.exception.code, 70)

    def test_agent_read_failure_retries_only_the_current_worker(self):
        for active in (True, False):
            with self.subTest(active=active):
                manager = aurel.Agents.__new__(aurel.Agents)
                manager.lock = threading.RLock()
                worker = Mock()
                worker.stdout.__iter__ = Mock(side_effect=OSError(5, 'fixture'))
                manager.processes = {'fixture': worker} if active else {}
                manager.revive = Mock()
                manager.read({'id': 'fixture'}, worker)
                self.assertEqual(manager.revive.call_count, int(active))

    def test_the_ask_log_and_its_folder_are_private_even_on_older_installs(self):
        with tempfile.TemporaryDirectory() as root, patch.object(aurel, 'DIR', root):
            os.chmod(root, 0o755); log = Path(root, 'log.jsonl'); log.write_text(''); log.chmod(0o644)
            aurel.append_log({'task': 'Summarize my inbox'})
            self.assertEqual((os.stat(root).st_mode & 0o777, log.stat().st_mode & 0o777), (0o700, 0o600))


if __name__ == '__main__':
    unittest.main()
