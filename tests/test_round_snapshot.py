"""Deterministic restart/read interleavings and result-window recovery."""
from dataclasses import FrozenInstanceError
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from dib.panel import ResultDialog
from dib.runner import BilliardsRunner
from dib.table import BilliardsMotion
from dib.ui import DesktopBilliardsApp


class Dialog:
    def __init__(self, *args):
        self.open = True
        self.views = []

    def alive(self):
        return self.open

    def close(self):
        self.open = False

    def update(self, view):
        self.views.append(view)


def app_for(runner):
    app = object.__new__(DesktopBilliardsApp)
    app.root = Mock()
    app.root.state.return_value = 'normal'
    app.runner = runner
    runner.shown.set()
    app.rank = Mock(serial=1)
    app.rank.view.return_value = {'phase': 'off'}
    app.result_dialog = app.result_serial = app.result_observation = None
    app.result_attempt_serial = app.restart_after_serial = app.round_snapshot = None
    app.result_attempts = 0
    app.result_retry_at = 0.
    app.toolbar_hidden = False
    for name in ('time_value', 'time_title', 'count_title', 'count_value', 'remaining_value'):
        setattr(app, name, Mock())
    return app


def finish(game):
    game.first_shot_at = 10.
    game.clock = game.finished_at = 12.
    game.shots = 2
    game.sunk = set(range(1, game.icon_count + 1))
    game.state = 'finished'
    return game.snapshot()


class RoundSnapshotTests(unittest.TestCase):
    def test_restart_between_state_and_serial_reads_cannot_consume_the_new_result(self):
        game = BilliardsMotion((0, 0, 1920, 1080), [(64, 64)] * 15)
        overlay = SimpleNamespace(table=game, ball_info='15 icons', request_restart=Mock())
        runner = BilliardsRunner(overlay)
        game.snapshot_sink = runner.publish_snapshot
        old = finish(game)
        runner.publish_snapshot(old)
        app = app_for(runner)
        made = []

        def create(*args):
            dialog = Dialog()
            made.append(dialog)
            return dialog

        with patch('dib.ui.ResultDialog', side_effect=create), patch('dib.ui.diag.log'):
            app.observe_snapshots(overlay, runner.take_snapshots())
            self.assertEqual(len(made), 1)
            made[-1].close()
            app.observe_snapshots(overlay, runner.take_snapshots())
            self.assertEqual(len(made), 1)  # Intentional dismissal is respected.

            entered, release = threading.Event(), threading.Event()
            original_aim = game._aim

            def blocked_aim():
                entered.set()
                if not release.wait(3):
                    raise RuntimeError('test synchronization timed out')
                return original_aim()

            game._aim = blocked_aim
            cached_state = game.state  # This was the UI's first, separate live read.
            worker = threading.Thread(target=game.reset)
            worker.start()
            try:
                self.assertTrue(entered.wait(3))
                # Reproduce the exact old bug: finished from round 1, serial from round 2.
                self.assertEqual((cached_state, game.round_serial, game.pocketed_icons), ('finished', 2, 0))
                stable = runner.take_snapshots()
                self.assertEqual(stable[-1], old)
                app.observe_snapshots(overlay, stable)
                self.assertEqual(app.result_serial, 1)
                with self.assertRaises(FrozenInstanceError):
                    stable[-1].state = 'ready'
            finally:
                release.set()
                worker.join(3)
                game._aim = original_aim
            self.assertFalse(worker.is_alive())
            # Ordinary frames coalesce, but ready -> first shot -> finished are retained.
            for _ in range(1000):
                runner.publish_snapshot(game.snapshot())
            game.shoot(.5, 10.)
            runner.publish_snapshot(game.snapshot())
            runner.publish_snapshot(finish(game))
            batch = runner.take_snapshots()
            self.assertEqual([s.state for s in batch], ['ready', 'stroke', 'finished'])
            app.observe_snapshots(overlay, batch)
            self.assertEqual(app.result_serial, 2)
            self.assertEqual(len(made), 2)
            self.assertEqual(made[-1].views[-1]['balls'], '15')
            self.assertEqual(made[-1].views[-1]['time'], '00:02.00')
            self.assertEqual(app.rank.observe.call_args_list[-3:][0].args[0].state, 'ready')
            app.play_again()
            app.observe_snapshots(overlay, runner.take_snapshots())
            self.assertEqual(len(made), 2)  # Pending restart cannot reopen the old result.
            game.reset()
            app.observe_snapshots(overlay, runner.take_snapshots())
            runner.publish_snapshot(finish(game))
            app.observe_snapshots(overlay, runner.take_snapshots())
            self.assertEqual((app.result_serial, len(made)), (3, 3))

    def test_window_failures_are_bounded_and_ranking_errors_do_not_hide_local_results(self):
        game = BilliardsMotion((0, 0, 1920, 1080), [(64, 64)] * 15)
        overlay = SimpleNamespace(table=game, ball_info='15 icons')
        state = finish(game)
        for failure in ('construct', 'render', 'persistent'):
            with self.subTest(failure=failure):
                app = app_for(BilliardsRunner(overlay))
                app.rank.observe.side_effect = RuntimeError('ranking unavailable')
                app.rank.view.side_effect = RuntimeError('ranking unavailable')
                made = []
                calls = []

                def create(*args):
                    calls.append(1)
                    if failure == 'persistent' or (failure == 'construct' and len(calls) == 1):
                        raise RuntimeError('construction failed')
                    dialog = Dialog()
                    made.append(dialog)
                    if failure == 'render' and len(calls) == 1:
                        dialog.update = Mock(side_effect=RuntimeError('render failed'))
                    return dialog

                with patch('dib.ui.ResultDialog', side_effect=create), patch('dib.ui._write_log'), \
                        patch('dib.ui.diag.log'), patch('dib.ui.time.monotonic', return_value=10.):
                    app.observe_snapshots(overlay, [state])
                    self.assertIsNone(app.result_serial)
                    if made:
                        self.assertFalse(made[0].alive())
                    app.observe_snapshots(overlay, [state])
                    self.assertEqual(len(calls), 1)  # No per-frame retry loop.
                    app.result_retry_at = 0.
                    app.observe_snapshots(overlay, [state])
                    self.assertEqual(len(calls), 2)
                    if failure == 'persistent':
                        app.result_retry_at = 0.
                        app.observe_snapshots(overlay, [state])
                        self.assertEqual(len(calls), 2)
                        self.assertIsNone(app.result_serial)
                    else:
                        self.assertEqual(app.result_serial, state.round_serial)
                        self.assertEqual(made[-1].views[-1]['rank']['phase'], 'error')
                        self.assertEqual(made[-1].views[-1]['shots'], '2')
        # Exercise the actual dialog constructor's partial-window cleanup.
        top = Mock()
        with patch('dib.panel.tk.Toplevel', return_value=top), \
                patch.object(ResultDialog, '_build', side_effect=RuntimeError('widget failure')):
            with self.assertRaisesRegex(RuntimeError, 'widget failure'):
                ResultDialog(Mock(), {})
        top.destroy.assert_called_once()
