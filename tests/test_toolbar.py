"""The compact toolbar and hotkeys must survive a withdrawn Tk window."""
from types import SimpleNamespace

import tkinter as tk
import unittest

import win32con
import win32gui

from dib import config
from dib.hotkeys import Hotkeys
from dib.panel import MainPanel


class ToolbarTests(unittest.TestCase):
    def setUp(self):
        self.root = tk.Tk()
        self.addCleanup(self.root.destroy)

    def test_only_exit_hotkey_is_enabled(self):
        hotkeys = Hotkeys()
        self.addCleanup(hotkeys.close)
        self.assertNotIn(config.HIDE_HOTKEY_ID, hotkeys.registered)
        self.assertIn(config.HOTKEY_ID, hotkeys.registered)
        self.root.withdraw()
        for identifier in (config.HIDE_HOTKEY_ID, config.HOTKEY_ID):
            win32gui.PostMessage(hotkeys.hwnd, win32con.WM_HOTKEY, identifier, 0)
        self.root.after(100, self.root.quit)
        self.root.mainloop()
        self.assertEqual(self.root.state(), 'withdrawn')
        self.assertEqual(hotkeys.pending.get_nowait(), config.HOTKEY_ID)
        self.assertTrue(hotkeys.pending.empty())

    def test_all_actions_are_visible_in_two_borderless_rows(self):
        calls = []
        actions = (
            ('guide', 'toggle_guide'), ('felt', 'toggle_felt'), ('white', 'white_ball'),
            ('rank', 'toggle_rank'), ('leaderboard', 'leaderboard'),
            ('update', 'check_updates'), ('donate', 'donate'),
            ('restart', 'restart'), ('quit', 'quit'),
        )
        callbacks = {name: lambda name=name: calls.append(name)
                     for name in (*[command for _, command in actions], 'open_credit')}
        panel = MainPanel(self.root, config.VERSION, callbacks, config.CREDIT)
        self.root.update()
        self.assertTrue(self.root.overrideredirect())
        self.assertEqual(set(panel.pills),
                         {'guide', 'felt', 'white', 'rank', 'leaderboard', 'update', 'donate', 'restart', 'quit'})

        functions = panel.pills['guide'].master.master
        credits = [widget for widget in functions.winfo_children()
                   if isinstance(widget, tk.Label) and widget.cget('text') == config.CREDIT]
        self.assertEqual(len(credits), 1)
        credit = credits[0]
        top = [panel.pills[key] for key in ('guide', 'felt', 'white', 'rank', 'leaderboard', 'update', 'donate')]
        bottom = [panel.pills[key] for key in ('restart', 'quit')]
        self.assertTrue(all(pill.master.master is functions for pill in top))
        for row in (top, bottom):
            positions = [pill.winfo_rooty() for pill in row]
            self.assertLessEqual(max(positions) - min(positions), 2)
            for left, right in zip(row, row[1:]):
                self.assertLessEqual(left.winfo_rootx() + left.winfo_width(), right.winfo_rootx())
        self.assertLessEqual(max(widget.winfo_rooty() + widget.winfo_height() for widget in top + [credit]),
                             min(pill.winfo_rooty() for pill in bottom))
        self.assertGreaterEqual(credit.winfo_rootx(), top[-1].winfo_rootx() + top[-1].winfo_width())

        def bounds(widget):
            x, y = widget.winfo_rootx(), widget.winfo_rooty()
            return x, y, x + widget.winfo_width(), y + widget.winfo_height()

        root_left, root_top, root_right, root_bottom = bounds(self.root)
        widgets = top + bottom + [credit]
        for index, widget in enumerate(widgets):
            with self.subTest(widget=widget.cget('text')):
                self.assertTrue(widget.winfo_ismapped())
                left, upper, right, lower = bounds(widget)
                self.assertGreater(right, left)
                self.assertGreater(lower, upper)
                self.assertGreaterEqual(left, root_left)
                self.assertGreaterEqual(upper, root_top)
                self.assertLessEqual(right, root_right)
                self.assertLessEqual(lower, root_bottom)
                for other in widgets[index + 1:]:
                    other_left, other_top, other_right, other_bottom = bounds(other)
                    self.assertTrue(right <= other_left or other_right <= left or
                                    lower <= other_top or other_bottom <= upper)

        for key, command in actions:
            with self.subTest(action=key):
                calls.clear()
                panel.pills[key]._release(SimpleNamespace(x=1, y=1))
                self.assertEqual(calls, [command])
        self.assertNotIn('hide', panel.pills)
        calls.clear()
        credit.event_generate('<ButtonRelease-1>', x=1, y=1)
        self.assertEqual(calls, ['open_credit'])


if __name__ == '__main__':
    unittest.main()
