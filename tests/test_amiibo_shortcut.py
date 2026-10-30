"""Exercise the BotW Amiibo shortcut and NFC state machine without game data."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin", "AppKit requires macOS")
class AmiiboShortcut(unittest.TestCase):
    def test_shortcut_and_nfp(self):
        source = ROOT / 'games/totk/tests/amiibo_shortcut/probe.m'
        include = ROOT / 'games/totk/third_party/d2r_gfx/gfx/nvn/include'
        with tempfile.TemporaryDirectory(prefix='botw-amiibo-') as folder:
            binary = Path(folder) / 'probe'
            subprocess.run(['xcrun', 'clang', '-std=c11', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                            '-Wno-deprecated-declarations', '-I' + str(include),
                            '-Wl,-undefined,dynamic_lookup', '-Wl,-dead_strip', str(source),
                            '-framework', 'Cocoa', '-framework', 'QuartzCore', '-framework', 'Metal',
                            '-framework', 'CoreVideo', '-o', str(binary)], check=True)
            env = dict(os.environ, CFFIXED_USER_HOME=folder, TOTK_UI_LANG='zh')
            result = subprocess.run([str(binary), folder], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('pass: Amiibo shortcut', result.stdout)
            restarted = subprocess.run([str(binary), folder, '--resume'], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(restarted.returncode, 0, restarted.stdout + restarted.stderr)
            self.assertIn('continues after restart', restarted.stdout)


if __name__ == '__main__':
    unittest.main()
