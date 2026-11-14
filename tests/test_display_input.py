"""Temporary input-desktop loss and physical multi-monitor coordinates."""
import ctypes
from ctypes import wintypes
from contextlib import nullcontext
import unittest
from unittest.mock import Mock, patch

import win32gui

from dib.display import monitors
from dib.overlay import BilliardsOverlay, TablePointer, map_rect
from dib.table import BilliardsMotion


class DisplayInputTests(unittest.TestCase):
    def test_denied_cursor_pauses_once_and_requires_a_fresh_press_on_return(self):
        overlay = object.__new__(BilliardsOverlay)
        game = overlay.table = BilliardsMotion((0, 0, 1920, 1040), [(64, 64)] * 15)
        overlay.pointer = TablePointer()
        overlay.input_suspended = overlay.input_pause_owned = False
        overlay.credit_pressed = 'pending link'
        overlay.credit_was_down = False
        game.first_shot_at, game.clock = 10., 13.
        game.charge = .8
        overlay.pointer.was_down = True
        overlay.pointer.held_since = 12.
        denied = win32gui.error(5, 'GetCursorPos', 'Access denied')
        with patch('dib.overlay.win32gui.GetCursorPos', side_effect=[denied, denied, (900, 500)]), \
                patch('dib.overlay.diag.log') as log:
            # draw must return before display queries, physics, or window painting.
            overlay.draw(13., .016)
            overlay.draw(14., .016)
            self.assertEqual(game.play_ms, 3000)
            self.assertEqual(game.paused_at, 13.)
            self.assertEqual(game.charge, 0)
            self.assertIsNone(overlay.pointer.held_since)
            self.assertIsNone(overlay.credit_pressed)
            self.assertEqual(log.call_count, 1)
            self.assertEqual(overlay.read_pointer(20.), (900, 500))
            game.step(0, 20.)
            self.assertEqual(game.play_ms, 3000)
            self.assertIsNone(game.paused_at)
            self.assertEqual(log.call_count, 2)
        overlay.pointer.update(game, 20., 900, 500, True, True)
        overlay.pointer.update(game, 20.1, 900, 500, False, True)
        self.assertEqual(game.shots, 0)
        overlay.pointer.update(game, 21., 900, 500, True, True)
        overlay.pointer.update(game, 21.1, 900, 500, False, True)
        self.assertEqual(game.shots, 1)
        # A hidden game already owns its pause; input recovery must not resume it.
        game.pause(22.)
        with patch('dib.overlay.win32gui.GetCursorPos', side_effect=[denied, (900, 500)]), \
                patch('dib.overlay.diag.log'):
            overlay.read_pointer(23.)
            overlay.read_pointer(25.)
        self.assertEqual(game.paused_at, 22.)
        with patch('dib.overlay.win32gui.GetCursorPos', side_effect=win32gui.error(6, 'GetCursorPos', 'Invalid handle')):
            with self.assertRaises(win32gui.error):
                overlay.read_pointer(26.)

    def test_mixed_dpi_monitors_keep_physical_rectangles_and_full_size_handles(self):
        handles = [0x100000001, 0x200000002]
        infos = {
            handles[0]: {'Device': 'left', 'Monitor': (-3840, -200, 0, 1960),
                         'Work': (-3840, -200, 0, 1880), 'Flags': 0},
            handles[1]: {'Device': 'primary', 'Monitor': (0, 0, 2560, 1600),
                         'Work': (0, 0, 2560, 1528), 'Flags': 1},
        }
        def get_dpi(handle, kind, x, y):
            dpi = 192 if handle == handles[0] else 144
            ctypes.cast(x, ctypes.POINTER(ctypes.c_uint)).contents.value = dpi
            ctypes.cast(y, ctypes.POINTER(ctypes.c_uint)).contents.value = dpi
            return 0
        native = Mock(side_effect=get_dpi)
        with patch('dib.display.dpi_context', return_value=nullcontext()), \
                patch('dib.display.win32api.EnumDisplayMonitors', return_value=[(h, None, None) for h in handles]), \
                patch('dib.display.win32api.GetMonitorInfo', side_effect=lambda h: infos[h]), \
                patch('dib.display.ctypes.windll.shcore.GetDpiForMonitor', native):
            screens = monitors()
        self.assertEqual(native.argtypes[0], wintypes.HANDLE)
        self.assertEqual([call.args[0] for call in native.call_args_list], handles)
        self.assertEqual(screens[0][1:4], (infos[handles[0]]['Monitor'], infos[handles[0]]['Work'], 192))
        self.assertEqual(screens[1][3:], (144, True))
        parent = (-3840, -200)
        client = map_rect(screens[1][2], (0, 0), parent)
        self.assertEqual(client, (3840, 200, 6400, 1728))
        self.assertEqual(map_rect(client, parent, (0, 0)), screens[1][2])


if __name__ == '__main__':
    unittest.main()
