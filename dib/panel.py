"""Windows made of plain Tk widgets: the main panel, the shareable result window and the update dialog.

Only widgets live here. The game logic stays in :mod:`dib.ui`, which fills the string
variables and supplies the callbacks, so every window can also be previewed on its own.

The main panel is a single borderless toolbar with all actions visible.
"""
from __future__ import annotations

import os
import tkinter as tk
from tkinter import ttk

import win32api
import win32con
import win32gui

from PIL import Image, ImageTk

from . import card, diag
from .release_notes import note_blocks

BG = '#0e1a18'
CARD = '#152623'
TEXT = '#e8f5f0'
MUTED = '#8aa69e'
ACCENT = '#69ddb3'
WARN = '#f2b880'
GOLD = '#f2ca87'
FONT = 'Microsoft YaHei UI'
NUMBERS = 'Segoe UI Semibold'

# kind -> (background, hover, foreground)
KINDS = {
    'primary': (ACCENT, '#86eac8', BG),
    'soft': ('#1f3733', '#294843', TEXT),
    'on': ('#1f5444', '#28695a', '#b6fbe0'),
    'off': ('#25322f', '#2f3f3b', MUTED),
    'ghost': (BG, '#18302c', MUTED),
    'gold': (BG, '#18302c', GOLD),
}


def format_duration(milliseconds):
    """``MM:SS.cc`` (``H:MM:SS.cc`` from one hour) for a round time in whole milliseconds."""
    centiseconds = max(0, int(milliseconds)) // 10
    seconds, centiseconds = divmod(centiseconds, 100)
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    clock = f'{hours}:{minutes:02d}:{seconds:02d}' if hours else f'{minutes:02d}:{seconds:02d}'
    return f'{clock}.{centiseconds:02d}'


class Pill(tk.Label):
    """A flat button with hover feedback; ``set`` changes its text, look and availability."""

    def __init__(self, parent, text, command, kind='soft', *, bold=False, padx=12, pady=6):
        super().__init__(parent, text=text, font=(FONT, 9, 'bold' if bold else 'normal'), cursor='hand2',
                         padx=padx, pady=pady, bd=0)
        self.command = command
        self.kind = kind
        self.enabled = True
        self.hover = False
        self.bind('<Enter>', lambda event: self._hover(True))
        self.bind('<Leave>', lambda event: self._hover(False))
        self.bind('<ButtonRelease-1>', self._release)
        self._paint()

    def set(self, text=None, kind=None, enabled=None):
        if text is not None:
            self.configure(text=text)
        if kind is not None:
            self.kind = kind
        if enabled is not None:
            self.enabled = enabled
        self._paint()

    def _hover(self, value):
        self.hover = value
        self._paint()

    def _release(self, event):
        inside = 0 <= event.x < self.winfo_width() and 0 <= event.y < self.winfo_height()
        if self.enabled and inside and self.command:
            self.command()

    def _paint(self):
        background, hover, foreground = KINDS[self.kind]
        if not self.enabled:
            self.configure(bg=KINDS['off'][0], fg='#5d726c', cursor='arrow')
            return
        self.configure(bg=hover if self.hover else background, fg=foreground, cursor='hand2')


def configure_styles(root):
    """ttk styles for the dialogs (the main window uses plain Tk widgets)."""
    style = ttk.Style(root)
    style.theme_use('clam')
    style.configure('Panel.TFrame', background=BG)
    style.configure('Table.TLabel', background=BG, foreground=TEXT, font=(FONT, 9))
    style.configure('Table.TButton', padding=(11, 6), font=(FONT, 9), background=CARD, foreground=TEXT,
                    borderwidth=0, focusthickness=1, focuscolor=ACCENT)
    style.map('Table.TButton', background=[('active', '#1d3531'), ('pressed', '#24423c')])
    style.configure('Dark.Vertical.TScrollbar', background='#2b4a44', troughcolor=CARD, bordercolor=CARD,
                    lightcolor='#2b4a44', darkcolor='#2b4a44', arrowcolor=MUTED, relief='flat', gripcount=0)
    style.map('Dark.Vertical.TScrollbar', background=[('active', '#3a645b'), ('pressed', '#3a645b')])


class MainPanel:
    """A draggable toolbar with functions above the current round and its actions."""

    DEFAULT_LOOK = {
        'guide': {'text': '辅助线 开', 'kind': 'on'},
        'rank': {'text': '排名', 'kind': 'off'},
        # 'hide': {'text': '隐藏', 'kind': 'soft'},
        'felt': {'text': '台面 开', 'kind': 'ghost'},
        'update': {'text': '检查更新', 'kind': 'ghost'},
    }

    def __init__(self, root, version, callbacks, credit=''):
        configure_styles(root)
        root.configure(bg=BG)
        root.overrideredirect(True)
        self.root = root
        self.pills = {}
        self.look = {key: dict(value) for key, value in self.DEFAULT_LOOK.items()}
        self.time_title = tk.StringVar(root, value='本局用时')
        self.time_value = tk.StringVar(root, value='00:00')
        self.count_title = tk.StringVar(root, value='图标入袋')
        self.count_value = tk.StringVar(root, value='—')
        self.remaining_title = tk.StringVar(root, value='剩余')
        self.remaining_value = tk.StringVar(root, value='—')
        self.shell = tk.Frame(root, bg=BG, padx=10, pady=8)
        self.shell.pack(fill='both', expand=True)
        self.shell.columnconfigure(1, weight=1)
        grip = tk.Label(self.shell, text='⋮⋮', font=(FONT, 11), fg=MUTED, bg=BG, cursor='fleur')
        grip.grid(row=0, column=0, rowspan=3, padx=(0, 12), sticky='ns')
        self._draggable(grip)
        self._draggable(self.shell)
        functions = tk.Frame(self.shell, bg=BG)
        functions.grid(row=0, column=1, sticky='ew')
        groups = []
        for items in (
                (('guide', '辅助线', 'toggle_guide', 'on'),
                 ('felt', '台面', 'toggle_felt', 'ghost'),
                 ('white', '白球外观', 'white_ball', 'ghost')),
                (('rank', '排名', 'toggle_rank', 'off'),
                 ('leaderboard', '排行榜', 'leaderboard', 'soft')),
                (('update', '检查更新', 'check_updates', 'ghost'),
                 ('donate', '打赏', 'donate', 'gold'))):
            group = tk.Frame(functions, bg=BG)
            groups.append(group)
            self._draggable(group)
            for key, text, command, kind in items:
                look = self.look.get(key, {})
                pill = Pill(group, look.get('text', text), callbacks.get(command),
                            look.get('kind', kind), padx=8, pady=4)
                pill.set(enabled=look.get('enabled', True))
                pill.pack(side='left', padx=(0, 4))
                self.pills[key] = pill
        if credit:
            link = tk.Label(functions, text=credit, font=(FONT, 8), fg=MUTED, bg=BG, cursor='hand2')
            link.bind('<ButtonRelease-1>', lambda event: callbacks['open_credit']())
            groups.append(link)
        root.update_idletasks()
        monitor = win32api.MonitorFromPoint((root.winfo_rootx(), root.winfo_rooty()),
                                           win32con.MONITOR_DEFAULTTONEAREST)
        left, _, right, _ = win32api.GetMonitorInfo(monitor)['Work']
        available = max(1, right - left - 64)
        row = column = used = 0
        for group in groups:
            width = group.winfo_reqwidth() + 12
            if used and used + width > available:
                row, column, used = row + 1, 0, 0
            group.grid(row=row, column=column, sticky='w', padx=(0, 12), pady=(0, 2))
            column += 1
            used += width
        separator = tk.Frame(self.shell, bg='#263d36', height=1)
        separator.grid(row=1, column=1, sticky='ew', pady=7)
        stats = tk.Frame(self.shell, bg=BG)
        stats.grid(row=2, column=1, sticky='ew')
        self._draggable(stats)
        for title, value in ((self.time_title, self.time_value), (self.count_title, self.count_value),
                             (self.remaining_title, self.remaining_value)):
            box = tk.Frame(stats, bg=BG)
            box.pack(side='left', padx=(0, 14))
            self._draggable(box)
            for variable, color, font in ((title, MUTED, (FONT, 8)), (value, TEXT, (NUMBERS, 11))):
                label = tk.Label(box, textvariable=variable, font=font, fg=color, bg=BG)
                label.pack(side='left', padx=(0, 5))
                self._draggable(label)
        self.pills['quit'] = Pill(stats, '退出', callbacks['quit'], 'soft', padx=10, pady=4)
        self.pills['quit'].pack(side='right')
        self.pills['restart'] = Pill(stats, '重新开始', callbacks['restart'], 'primary', bold=True, padx=10, pady=4)
        self.pills['restart'].pack(side='right', padx=(0, 8))
        root.update_idletasks()

    def _draggable(self, widget):
        widget.bind('<ButtonPress-1>', self._drag_start)
        widget.bind('<B1-Motion>', self._drag_move)

    def _drag_start(self, event):
        self.drag_offset = (event.x_root - self.root.winfo_x(), event.y_root - self.root.winfo_y())

    def _drag_move(self, event):
        x, y = self.drag_offset
        self.root.geometry(f'+{event.x_root - x}+{event.y_root - y}')

    def set_look(self, key, text=None, kind=None, enabled=None):
        look = self.look.setdefault(key, {})
        for name, value in (('text', text), ('kind', kind), ('enabled', enabled)):
            if value is not None:
                look[name] = value
        pill = self.pills.get(key)
        if pill is not None and pill.winfo_exists():
            pill.set(text, kind, enabled)

    def is_enabled(self, key):
        return self.look.get(key, {}).get('enabled', True)


class ResultDialog:
    """The round-end window: a preview of the shareable result card and the buttons to share it.

    :meth:`update` takes a ``view`` dict and may be called every frame; the card is only redrawn
    when the view changes. Keys: ``time``, ``average``, ``balls``, ``shots``, ``note`` and
    ``rank`` (phase ``off`` / ``unavailable`` / ``skipped`` / ``pending`` / ``ok`` / ``error``).
    """

    PREVIEW = (600, 750)

    def __init__(self, root, callbacks, credit='', site=''):
        self.callbacks = callbacks
        self.credit = credit
        self.site = site
        self.image = None
        self.photo = None
        self.last = None
        self.folder = None
        self.root = root
        self.top = tk.Toplevel(root)
        try:
            self._build(root, callbacks)
        except Exception:
            self.close()
            raise

    def _build(self, root, callbacks):
        top = self.top
        top.title('清台完成')
        for event in ('<Map>', '<Unmap>', '<Destroy>'):
            top.bind(event, lambda e, name=event: diag.log(f'result window event: {name}')
                     if e.widget is top else None, add='+')
        top.configure(bg=BG)
        top.transient(root)
        top.resizable(False, False)
        top.iconbitmap(str(card.LOGO.with_suffix('.ico')))
        shell = tk.Frame(top, bg=BG)
        shell.pack(fill='both', expand=True)

        self.photo = ImageTk.PhotoImage(Image.new('RGB', self.PREVIEW, CARD), master=top)
        self.preview = tk.Label(shell, image=self.photo, bg=BG, bd=0)
        self.preview.pack()

        if callbacks.get('leaderboard'):
            Pill(shell, '查看排行榜  ›', callbacks['leaderboard'], 'ghost', pady=8).pack(fill='x')

        share = tk.Frame(shell, bg=BG, padx=12, pady=12)
        share.pack(fill='x')
        for column, (text, command, kind) in enumerate((
                ('保存图片', self.save, 'soft'), ('复制图片', self.copy, 'soft'),
                ('再来一局', callbacks['again'], 'primary'))):
            share.columnconfigure(column, weight=1, uniform='actions')
            Pill(share, text, command, kind, bold=kind == 'primary', padx=8, pady=11).grid(
                row=0, column=column, sticky='ew', padx=(0 if column == 0 else 6, 0 if column == 2 else 6))
        status = self.status = tk.Frame(shell, bg=BG, height=30)
        status.pack_propagate(False)
        self.feedback_text = tk.StringVar(top)
        self.feedback = tk.Label(status, textvariable=self.feedback_text, font=(FONT, 8), fg=MUTED, bg=BG,
                                 anchor='w', justify='left')
        self.feedback.pack(side='left', fill='x', expand=True)
        self.feedback.bind('<ButtonRelease-1>', lambda event: self.open_folder())

        self.offer = Pill(status, '开启全球排名', callbacks['enable_rank'], 'ghost', padx=0, pady=0)
        top.bind('<Escape>', lambda event: self.close())
        top.protocol('WM_DELETE_WINDOW', self.close)
        top.update_idletasks()
        self._fit_screen(root)
        top.lift()

    def _fit_screen(self, root):
        # Use the toolbar's monitor and its work area (excluding the taskbar),
        # with measured native borders and DPI-scaled controls rather than a fixed height.
        monitor = win32api.MonitorFromPoint((root.winfo_rootx(), root.winfo_rooty()),
                                           win32con.MONITOR_DEFAULTTONEAREST)
        left, upper, right, bottom = win32api.GetMonitorInfo(monitor)['Work']
        top = self.top
        hwnd = win32gui.GetAncestor(top.winfo_id(), win32con.GA_ROOT)
        x0, y0, x1, y1 = win32gui.GetWindowRect(hwnd)
        border_w = x1 - x0 - top.winfo_width()
        border_h = y1 - y0 - top.winfo_height()
        extra_w = top.winfo_reqwidth() - self.photo.width() + border_w
        extra_h = top.winfo_reqheight() - self.photo.height() + border_h
        scale = min(1, (right - left - extra_w - 32) / self.PREVIEW[0],
                    (bottom - upper - extra_h - 32) / self.PREVIEW[1])
        self.preview_size = (max(1, int(self.PREVIEW[0] * scale)), max(1, int(self.PREVIEW[1] * scale)))
        frame = self.image.resize(self.preview_size, Image.Resampling.LANCZOS) if self.image else Image.new('RGB', self.preview_size, CARD)
        self.photo = ImageTk.PhotoImage(frame, master=top)
        self.preview.configure(image=self.photo)
        top.update_idletasks()
        width, height = top.winfo_reqwidth() + border_w, top.winfo_reqheight() + border_h
        x = left + max(0, (right - left - width) // 2)
        y = upper + max(0, (bottom - upper - height) // 2)
        top.geometry(f'+{x}+{y}')

    def alive(self):
        return self.top is not None and self.top.winfo_exists()

    def close(self):
        if self.alive():
            diag.log('result close requested')
            self.top.destroy()
        self.top = None

    def update(self, view):
        if not self.alive() or view == self.last:
            return
        image = card.render_card(view, credit=self.credit, site=self.site)
        previous, previous_image = self.last, self.image
        self.last, self.image = view, image
        try:
            if view['rank']['phase'] == 'off':
                self.offer.pack(side='right')
            else:
                self.offer.pack_forget()
            self._layout_status()
        except Exception:
            self.last, self.image = previous, previous_image
            raise
        diag.log(f'result rendered: rank_phase={view["rank"]["phase"]} '
                 f'window_state={self.top.state()} visible={self.top.winfo_viewable()}')

    def _layout_status(self):
        if self.feedback_text.get() or (self.last and self.last['rank']['phase'] == 'off'):
            self.status.pack(fill='x', padx=12, pady=(0, 8))
        else:
            self.status.pack_forget()
        self.top.update_idletasks()
        self._fit_screen(self.root)

    def save(self):
        if self.image is None:
            return
        try:
            path = card.save_card(self.image)
        except OSError as error:
            self._say(f'保存失败：{error}', MUTED)
            return
        self.folder = path.parent
        self._say('已保存，点此打开所在文件夹', ACCENT)

    def copy(self):
        if self.image is None:
            return
        try:
            card.copy_card(self.image)
        except Exception:  # the clipboard can be locked by another program
            self._say('复制失败，请改用「保存图片」', WARN)
            return
        self._say('已复制，可直接粘贴到微信、QQ 或帖子里', ACCENT)

    def open_folder(self):
        if self.folder is not None:
            try:
                os.startfile(self.folder)
            except OSError:
                pass

    def _say(self, text, colour):
        self.feedback_text.set(text)
        self._layout_status()
        self.feedback.configure(fg=colour, cursor='hand2' if self.folder is not None and '点此' in text else 'arrow')


def show_update_dialog(root, current, info, entries, on_download):
    """Native, display-only rich release notes with fixed header/footer."""
    dialog = tk.Toplevel(root)
    dialog.withdraw()
    dialog.title('软件更新')
    dialog.configure(bg=BG)
    if root.state() != 'withdrawn':
        dialog.transient(root)
    dialog.resizable(True, True)
    scale = max(1., root.winfo_fpixels('1i') / 96)
    pad = round(18 * scale)
    try:
        dialog.iconbitmap(str(card.LOGO.with_suffix('.ico')))
    except tk.TclError:
        pass
    shell = tk.Frame(dialog, bg=BG, padx=pad, pady=pad)
    shell.pack(fill='both', expand=True)
    header = tk.Frame(shell, bg=BG)
    header.pack(fill='x', pady=(0, round(12 * scale)))
    tk.Label(header, text='更新内容', font=(FONT, 13, 'bold'), fg=TEXT, bg=BG).pack(side='left')
    tk.Label(header, text=f'当前 v{current}', font=(FONT, 9), fg=MUTED, bg=BG).pack(side='right')

    footer = tk.Frame(shell, bg=BG)
    footer.pack(side='bottom', fill='x', pady=(round(12 * scale), 0))
    Pill(footer, '下载更新', lambda: on_download(dialog), 'primary', bold=True,
         padx=20, pady=10).pack(side='right')
    Pill(footer, '稍后', dialog.destroy, 'soft', padx=18, pady=10).pack(side='right', padx=(0, 10))
    body = tk.Frame(shell, bg=CARD, highlightthickness=1, highlightbackground='#29443c')
    body.pack(fill='both', expand=True)
    notes = tk.Text(body, width=38, height=10, wrap='word', bg=CARD, fg=TEXT, relief='flat', bd=0,
                    highlightthickness=0, padx=round(18 * scale), pady=round(14 * scale),
                    font=(FONT, 10), spacing1=2, spacing3=round(9 * scale), cursor='arrow',
                    insertwidth=0, selectbackground='#2b4a44')
    scrollbar = ttk.Scrollbar(body, orient='vertical', command=notes.yview, style='Dark.Vertical.TScrollbar')
    notes.configure(yscrollcommand=scrollbar.set)
    scrollbar.pack(side='right', fill='y')
    notes.pack(side='left', fill='both', expand=True)
    notes.tag_configure('body', foreground='#c4d9d2')
    notes.tag_configure('heading', font=(FONT, 12, 'bold'), foreground=TEXT,
                        spacing1=round(12 * scale), spacing3=round(8 * scale))
    notes.tag_configure('version', font=(NUMBERS, 13, 'bold'), foreground=ACCENT,
                        spacing1=round(18 * scale), spacing3=round(12 * scale))
    notes.tag_configure('first_version', spacing1=0)
    notes.tag_configure('date', font=(FONT, 9), foreground=MUTED)
    notes.tag_configure('list', lmargin1=0, lmargin2=round(19 * scale), foreground='#c4d9d2')
    notes.tag_configure('quote', foreground=MUTED, lmargin1=round(12 * scale), lmargin2=round(12 * scale))
    notes.tag_configure('bold', font=(FONT, 10, 'bold'), foreground=TEXT)
    notes.tag_configure('code', font=('Consolas', 10), foreground=ACCENT, background='#203a32')
    notes.tag_configure('space', font=(FONT, 3), spacing1=0, spacing3=0)

    def render():
        notes.configure(state='normal')
        notes.delete('1.0', 'end')
        for index, entry in enumerate(entries):
            tags = ('version', 'first_version') if index == 0 else ('version',)
            notes.insert('end', f'v{entry["version"]}'+ ('  ·  最新版本' if index == 0 else ''), tags)
            if entry.get('date'):
                notes.insert('end', f'    {entry["date"]}', (*tags, 'date'))
            notes.insert('end', '\n', tags)
            for kind, spans in note_blocks(entry['notes'] or '暂无更新说明'):
                if kind == 'space':
                    notes.insert('end', '\n', 'space')
                    continue
                for text, style in spans:
                    tags = (kind, style) if style and not (kind == 'heading' and style == 'bold') else (kind,)
                    notes.insert('end', text, tags)
                notes.insert('end', '\n', kind)
        notes.configure(state='disabled')
        notes.yview_moveto(0)

    render()
    dialog.bind('<Escape>', lambda event: dialog.destroy())
    dialog.update_idletasks()
    monitor = win32api.MonitorFromPoint((root.winfo_rootx(), root.winfo_rooty()),
                                       win32con.MONITOR_DEFAULTTONEAREST)
    left, top, right, bottom = win32api.GetMonitorInfo(monitor)['Work']
    # Leave space for native borders and taskbar, including high-DPI small displays.
    width = max(1, min(round(620 * scale), right - left - round(32 * scale)))
    height = max(1, min(round(520 * scale), bottom - top - round(64 * scale)))
    dialog.minsize(min(width, round(400 * scale)), min(height, round(280 * scale)))
    dialog.maxsize(width, height)
    x = left + (right - left - width) // 2
    y = top + (bottom - top - height) // 2
    dialog.geometry(f'{width}x{height}+{x}+{y}')
    dialog.deiconify()
    dialog.lift()
    return dialog
