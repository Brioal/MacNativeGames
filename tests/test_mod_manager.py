"""Check the BotW 1.6.0 mod scanner and immutable generation builder with synthetic RomFS data."""
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'games/totk/scripts/prepare_mod_generation.py'


def fake_app(path, files):
    romfs = path / 'Contents/Resources/totk/extracted/botw160/romfs'
    romfs.mkdir(parents=True)
    image = bytearray()
    strings = bytearray()
    rows = []
    for name, data in sorted(files.items()):
        offset = len(image)
        image.extend(data)
        name_offset = len(strings)
        encoded = name.encode()
        strings.extend(encoded + b'\0')
        rows.append((offset, len(data), name_offset, len(encoded) + 1))
    (romfs / 'romfs.bin').write_bytes(image)
    strings_at = 24 + len(rows) * 24
    index = bytearray(struct.pack('<8sQQ', b'TOTKRFS1', len(rows), strings_at))
    for row in rows:
        index.extend(struct.pack('<QQII', *row))
    index.extend(strings)
    (romfs / 'runtime-index.bin').write_bytes(index)


class ModManager(unittest.TestCase):
    def run_helper(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)],
                              capture_output=True, text=True, timeout=30)

    def test_scan_rejects_code_and_archive_mods(self):
        with tempfile.TemporaryDirectory(prefix='botw-mod-scan-') as temp:
            root = Path(temp) / 'mods'
            (root / 'RomFSOnly' / 'romfs/Actor').mkdir(parents=True)
            (root / 'RomFSOnly/romfs/Actor/file.byml').write_bytes(b'x')
            (root / 'Code/exefs').mkdir(parents=True)
            (root / 'Code/exefs/main.ips').write_bytes(b'patch')
            (root / 'Archive').mkdir()
            (root / 'Archive/mod.zip').write_bytes(b'zip')
            result = self.run_helper('scan', '--source', root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            records = {row['name']: row for row in json.loads(result.stdout)}
            self.assertEqual(records['RomFSOnly']['files'], 1)
            self.assertTrue(records['RomFSOnly']['supported'])
            self.assertFalse(records['Code']['supported'])
            self.assertIn('ExeFS', records['Code']['reason'])
            self.assertFalse(records['Archive']['supported'])
            self.assertIn('extract', records['Archive']['reason'])

    def test_conflicts_and_generation(self):
        with tempfile.TemporaryDirectory(prefix='botw-mod-build-') as temp:
            root = Path(temp)
            source = root / 'mods'
            for name, content in (('One', b'one'), ('Two', b'two')):
                path = source / name / 'romfs/UI/Marker.bin'
                path.parent.mkdir(parents=True)
                path.write_bytes(content)
            app = root / 'Breath of the Wild.app'
            fake_app(app, {'UI/Marker.bin': b'original'})
            conflicts = self.run_helper('conflicts', '--source', source, '--mod', 'One', '--mod', 'Two')
            self.assertEqual(conflicts.returncode, 0, conflicts.stdout + conflicts.stderr)
            conflict_rows = json.loads(conflicts.stdout)
            self.assertEqual(conflict_rows[0]['path'], 'UI/Marker.bin')
            self.assertEqual(conflict_rows[0]['mods'], ['One', 'Two'])
            blocked = self.run_helper('prepare', '--source', source, '--app', app,
                                      '--generations', root / 'generations', '--version', 'botw160',
                                      '--mod', 'One', '--mod', 'Two')
            self.assertNotEqual(blocked.returncode, 0)
            self.assertIn('same RomFS path', json.loads(blocked.stdout)['error'])
            self.assertFalse((root / 'generations').exists())

            add = source / 'Added/romfs/Pack/Extra.pack'
            add.parent.mkdir(parents=True)
            add.write_bytes(b'new resource')
            prepared = self.run_helper('prepare', '--source', source, '--app', app,
                                       '--generations', root / 'generations', '--version', 'botw160', '--mod', 'One',
                                       '--mod', 'Added')
            self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
            generation = Path(json.loads(prepared.stdout)['generation'])
            lines = (generation / 'manifest.tsv').read_text().splitlines()
            self.assertEqual({line.split('\t')[0] for line in lines[1:]}, {'UI/Marker.bin', 'Pack/Extra.pack'})
            self.assertEqual((source / 'One/romfs/UI/Marker.bin').read_bytes(), b'one')
            self.assertFalse((source / 'One/romfs/manifest.tsv').exists())
            self.assertEqual(json.loads(prepared.stdout)['files'], 2)


if __name__ == '__main__':
    unittest.main()
