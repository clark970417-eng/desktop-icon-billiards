import queue
from pathlib import Path
import tempfile
import unittest
import tkinter as tk
from types import SimpleNamespace
from unittest.mock import Mock, patch

from PIL import Image, ImageDraw

from dib.art import white_art
from dib.overlay import BilliardsOverlay
from dib.table import BilliardsMotion
from dib.white_ball import CropDialog, crop_box, crop_texture, read_texture, save_texture


class WhiteBallTests(unittest.TestCase):
    def test_short_side_crop_zoom_and_pan_never_leave_the_image(self):
        source = Image.new('RGB', (300, 100), 'red')
        ImageDraw.Draw(source).rectangle((100, 0, 199, 99), fill='green')
        self.assertEqual(crop_box(source), (100, 0, 200, 100))
        self.assertEqual(crop_box(source, 2, (-100, 999)), (0, 50, 50, 100))
        self.assertEqual(crop_texture(source, 2, (25, 50)).getpixel((128, 128)), (255, 0, 0))
        self.assertEqual(crop_texture(source).getpixel((128, 128)), (0, 128, 0))
        portrait = source.transpose(Image.Transpose.ROTATE_90)
        self.assertEqual(crop_box(portrait), (0, 100, 100, 200))

    def test_crop_editor_only_applies_on_confirmation(self):
        root = tk.Tk()
        self.addCleanup(root.destroy)
        root.withdraw()
        apply = Mock()
        source = Image.new('RGB', (300, 100), 'red')
        ImageDraw.Draw(source).rectangle((100, 0, 199, 99), fill='green')
        editor = CropDialog(root, source, apply)
        root.update()
        editor.scale('2')
        editor.start_drag(SimpleNamespace(x=100, y=100))
        editor.move(SimpleNamespace(x=1000, y=100))
        editor.confirm()
        self.assertEqual(apply.call_count, 1)
        self.assertEqual(apply.call_args.args[0].getpixel((128, 128)), (255, 0, 0))
        self.assertFalse(editor.window.winfo_exists())
        apply.reset_mock()
        editor = CropDialog(root, source, apply)
        editor.scale('3')
        editor.close()
        root.update()
        apply.assert_not_called()

    def test_center_crop_round_mask_and_atomic_local_storage(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'source.png'
            cache = Path(directory) / 'white-ball.png'
            image = Image.new('RGB', (300, 100), 'red')
            ImageDraw.Draw(image).rectangle((100, 0, 199, 99), fill='green')
            for candidate in (image, image.transpose(Image.Transpose.ROTATE_90)):
                candidate.save(source)
                texture = read_texture(source)
                self.assertEqual(texture.size, (256, 256))
                self.assertEqual(texture.getpixel((128, 128)), (0, 128, 0))
                self.assertEqual(texture.getpixel((10, 10)), (0, 128, 0))
            save_texture(cache, texture)
            self.assertEqual(read_texture(cache).tobytes(), texture.tobytes())
            original = cache.read_bytes()
            with patch('dib.white_ball.os.replace', side_effect=OSError('denied')):
                with self.assertRaises(OSError):
                    save_texture(cache, Image.new('RGB', (256, 256), 'blue'))
            self.assertEqual(cache.read_bytes(), original)
            self.assertFalse(cache.with_suffix('.tmp').exists())
            source.write_text('not an image', encoding='utf-8')
            with self.assertRaises(OSError):
                read_texture(source)
            self.assertEqual(cache.read_bytes(), original)
            frame = white_art(24, shaded=True, texture=texture)
            self.assertEqual(frame.size, white_art(24, shaded=True).size)
            self.assertEqual(frame.getpixel((0, 0))[3], 0)
            self.assertEqual(frame.getpixel((frame.width // 2, frame.height // 2))[3], 255)
            save_texture(cache, None)
            self.assertFalse(cache.exists())

    def test_texture_changes_are_cached_and_do_not_modify_physics(self):
        overlay = object.__new__(BilliardsOverlay)
        game = overlay.table = BilliardsMotion((0, 0, 1920, 1080), [(64, 64)] * 15)
        overlay.table_windows = {'white': 1, 'rail': 2}
        overlay.white_requests = queue.SimpleQueue()
        overlay.white_texture = overlay.white_frame = overlay.white_position = None
        overlay.aim_visible = False
        overlay.cue_key = None
        overlay.present = Mock()
        overlay.position_layer = Mock()
        snapshot = game.snapshot()
        white = vars(game.white).copy()
        with patch('dib.overlay.white_art', wraps=white_art) as render:
            overlay.draw_table()
            texture = Image.new('RGB', (256, 256), 'blue')
            overlay.request_white_texture(texture)
            texture.paste('red', (0, 0, 256, 256))
            overlay.draw_table()
            self.assertEqual(overlay.white_texture.getpixel((0, 0)), (0, 0, 255))
            for _ in range(100):
                overlay.draw_table()
            self.assertEqual(render.call_count, 2)
            overlay.request_white_texture(None)
            overlay.draw_table()
            self.assertEqual(render.call_count, 3)
            self.assertEqual(overlay.white_frame.tobytes(), white_art(game.white.radius, shaded=True).tobytes())
        self.assertEqual(game.snapshot(), snapshot)
        self.assertEqual(vars(game.white), white)


if __name__ == '__main__':
    unittest.main()
