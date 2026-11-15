"""Clear-table controls share paint/hit geometry and use the existing UI actions."""
import queue
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from dib.art import round_actions_art, round_actions_layout
from dib.overlay import BilliardsOverlay
from dib.table import BilliardsMotion
from dib.ui import DesktopBilliardsApp


class RoundActionTests(unittest.TestCase):
    def test_buttons_fit_and_only_draw_after_clear_then_hide_on_restart(self):
        for area in ((0, 0, 640, 440), (0, 0, 2560, 1528), (-1080, -300, 0, 1580)):
            with self.subTest(area=area):
                game = BilliardsMotion(area, [(64, 64)] * 15)
                _, rows = round_actions_layout(game)
                frame, x, y = round_actions_art(game)
                left, top, right, bottom = game.bounds
                self.assertEqual([r[1] for r in rows], ['再来一局', '退出游戏'])
                self.assertGreaterEqual(x, left)
                self.assertGreaterEqual(y, top)
                self.assertLessEqual(x + frame.width, right)
                self.assertLessEqual(y + frame.height, bottom)
                self.assertAlmostEqual(x + frame.width / 2, (left + right) / 2, delta=.5)
                self.assertAlmostEqual(y + frame.height / 2, (top + bottom) / 2, delta=.5)
        overlay = object.__new__(BilliardsOverlay)
        overlay.table = game
        overlay.round_actions_key = None
        overlay.round_action_hover = overlay.round_action_pressed = None
        overlay.table_windows = {'round_actions': 42}
        overlay.present = Mock()
        overlay.position_layer = Mock()
        overlay.felt_visible = False  # Buttons remain available with the table hidden.
        with patch('dib.overlay.win32gui.ShowWindow') as hide:
            overlay.draw_round_actions()
            overlay.present.assert_not_called()
            game.state = 'finished'
            overlay.draw_round_actions()
            overlay.draw_round_actions()
            overlay.present.assert_called_once()  # No repeated painting of unchanged buttons.
            game.reset()
            overlay.draw_round_actions()
            hide.assert_called_once()
            self.assertIsNone(overlay.round_actions_key)

    def test_click_requires_same_visible_button_and_dispatch_checks_round(self):
        game = BilliardsMotion((0, 0, 1920, 1080), [(64, 64)] * 15)
        overlay = object.__new__(BilliardsOverlay)
        overlay.table = game
        overlay.round_actions = queue.SimpleQueue()
        overlay.round_action_hover = overlay.round_action_pressed = None
        overlay.round_action_was_down = False
        _, rows = round_actions_layout(game)
        points = [((l + r) / 2, (t + b) / 2) for _, _, (l, t, r, b) in rows]

        def click(start, end, visible=True):
            overlay.update_round_action_pointer(*start, True, visible)
            overlay.update_round_action_pointer(*end, False, visible)

        click(points[0], points[0])  # No control in an active game.
        self.assertTrue(overlay.round_actions.empty())
        game.state = 'finished'
        click(points[0], points[1])
        click(points[0], points[0], visible=False)  # Covered by another window.
        overlay.update_round_action_pointer(*points[0], True, True)
        overlay.update_round_action_pointer(*points[0], True, False)
        overlay.update_round_action_pointer(*points[0], False, True)
        self.assertTrue(overlay.round_actions.empty())
        app = object.__new__(DesktopBilliardsApp)
        app.restart_after_serial = None
        app.closing = False
        app.play_again = Mock()
        app.close = Mock(side_effect=lambda: setattr(app, 'closing', True))
        for index, action in enumerate(('again', 'quit')):
            click(points[index], points[index])
            self.assertEqual(overlay.round_actions.get_nowait(), (game.round_serial, action))
            overlay.round_actions.put((game.round_serial - 1, action))
            app.handle_round_actions(overlay, game.snapshot())
            (app.play_again if action == 'again' else app.close).assert_not_called()
            overlay.round_actions.put((game.round_serial, action))
            self.assertEqual(app.handle_round_actions(overlay, game.snapshot()), action == 'quit')
            (app.play_again if action == 'again' else app.close).assert_called_once()
        app.restart_after_serial = game.round_serial
        overlay.round_actions.put((game.round_serial, 'again'))
        app.handle_round_actions(overlay, game.snapshot())
        app.play_again.assert_called_once()
