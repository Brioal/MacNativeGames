#!/usr/bin/env python3
"""Inspect unpacked RomFS mod folders and prepare one immutable BotW overlay generation."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

JUNK = {'desktop.ini', 'thumbs.db', '.ds_store'}


def mod_records(source):
    source = Path(source)
    if not source.is_dir():
        raise ValueError(f'{source} is not a folder')
    records = []
    for folder in sorted(source.iterdir(), key=lambda p: (p.name.casefold(), p.name)):
        if folder.name.startswith('.'):
            continue
        if folder.is_symlink():
            raise ValueError(f'{folder.name}: symbolic-link mod folders are not supported')
        if not folder.is_dir():
            continue
        payload = folder / 'romfs' if (folder / 'romfs').is_dir() else folder
        files, has_code, has_archive = [], False, False
        for root, dirs, names in os.walk(folder, followlinks=False):
            root = Path(root)
            for name in list(dirs):
                if name.startswith('.'):
                    dirs.remove(name)
                    continue
                item = root / name
                if item.is_symlink():
                    raise ValueError(f'{folder.name}: symbolic links are not supported: {item.relative_to(folder)}')
            for name in names:
                item = root / name
                relative_folder = item.relative_to(folder)
                if any(part.startswith('.') for part in relative_folder.parts) or name.lower() in JUNK or name == 'manifest.tsv' or name.endswith('.mod-original'):
                    continue
                if any(part.lower() == 'exefs' for part in relative_folder.parts):
                    has_code = True
                if item.suffix.lower() in {'.ips', '.ips32', '.pchtxt'}:
                    has_code = True
                if item.suffix.lower() in {'.zip', '.7z', '.rar', '.nsp', '.xci'}:
                    has_archive = True
                try:
                    relative = item.relative_to(payload)
                except ValueError:
                    if item.is_symlink():
                        raise ValueError(f'{folder.name}: symbolic links are not supported: {relative_folder.as_posix()}')
                    continue
                if item.is_symlink() or not item.is_file():
                    raise ValueError(f'{folder.name}: not a regular file: {relative.as_posix()}')
                path = relative.as_posix()
                if any(c in path for c in '\t\r\n'):
                    raise ValueError(f'{folder.name}: a RomFS path contains a tab or newline: {path!r}')
                files.append(path)
        files.sort(key=lambda p: (p.casefold(), p))
        if has_code:
            records.append({'name': folder.name, 'supported': False,
                            'reason': 'contains ExeFS or code patches', 'files': []})
            continue
        if has_archive:
            records.append({'name': folder.name, 'supported': False,
                            'reason': 'contains an archive; extract it first', 'files': []})
            continue
        records.append({'name': folder.name, 'supported': bool(files),
                        'reason': '' if files else 'contains no RomFS files', 'files': files})
    return records


def selected_records(source, names):
    records = mod_records(source)
    by_name = {record['name']: record for record in records}
    missing = sorted(set(names) - by_name.keys())
    if missing:
        raise ValueError('selected mod folder no longer exists: ' + ', '.join(missing))
    unsupported = [name for name in names if not by_name[name]['supported']]
    if unsupported:
        raise ValueError('unsupported mod cannot be enabled: ' + ', '.join(unsupported))
    return [by_name[name] for name in names]


def path_conflicts(records):
    owners = {}
    for record in records:
        for path in record['files']:
            owners.setdefault(path.casefold(), []).append((path, record['name']))
    conflicts = []
    for values in owners.values():
        if len(values) > 1:
            paths = sorted({path for path, _ in values}, key=lambda p: (p.casefold(), p))
            conflicts.append({'path': paths[0], 'mods': sorted({name for _, name in values})})
    return sorted(conflicts, key=lambda item: (item['path'].casefold(), item['path']))


def copy_mod(records, source, destination):
    source = Path(source)
    for record in records:
        folder = source / record['name']
        payload = folder / 'romfs' if (folder / 'romfs').is_dir() else folder
        for path in record['files']:
            target = destination / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(payload / path, target)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    scan = sub.add_parser('scan')
    scan.add_argument('--source', type=Path, required=True)
    check = sub.add_parser('conflicts')
    check.add_argument('--source', type=Path, required=True)
    check.add_argument('--mod', action='append', default=[])
    prepare = sub.add_parser('prepare')
    prepare.add_argument('--source', type=Path, required=True)
    prepare.add_argument('--app', type=Path, required=True)
    prepare.add_argument('--generations', type=Path, required=True)
    prepare.add_argument('--version', choices=('botw160',), required=True)
    prepare.add_argument('--mod', action='append', default=[])
    args = parser.parse_args()
    try:
        if args.command == 'scan':
            records = mod_records(args.source)
            print(json.dumps([{'name': r['name'], 'supported': r['supported'], 'reason': r['reason'], 'files': len(r['files'])}
                              for r in records], ensure_ascii=False))
            return 0
        records = selected_records(args.source, args.mod)
        conflicts = path_conflicts(records)
        if args.command == 'conflicts':
            print(json.dumps(conflicts, ensure_ascii=False))
            return 0
        if conflicts:
            raise ValueError('selected mods replace the same RomFS path: ' + '; '.join(
                f"{item['path']} ({', '.join(item['mods'])})" for item in conflicts))
        args.generations.mkdir(parents=True, exist_ok=True)
        generation = args.generations / str(uuid.uuid4())
        staging = args.generations / ('.' + generation.name + '.tmp')
        staging.mkdir()
        try:
            copy_mod(records, args.source, staging)
            script = Path(__file__).with_name('make_mod_manifest.py')
            result = subprocess.run([sys.executable, str(script), str(staging), '--app', str(args.app),
                                    '--version', args.version], cwd=Path(__file__).resolve().parents[1],
                                   capture_output=True, text=True)
            output = (result.stdout + result.stderr).strip()
            if result.returncode:
                detail = '\n'.join(output.splitlines()[-8:])
                raise ValueError(detail or f'make_mod_manifest.py failed with exit code {result.returncode}')
            manifest = staging / 'manifest.tsv'
            if not manifest.is_file():
                raise ValueError(output or 'manifest generator produced no manifest.tsv')
            count = sum(1 for line in manifest.read_text().splitlines() if line and not line.startswith('#'))
            if count == 0:
                raise ValueError('the selected mods contain no files this app can load')
            staging.rename(generation)
        except (OSError, ValueError, UnicodeError):
            shutil.rmtree(staging)
            raise
        print(json.dumps({'generation': str(generation), 'files': count, 'mods': [r['name'] for r in records]}, ensure_ascii=False))
        return 0
    except (OSError, ValueError) as error:
        print(json.dumps({'error': str(error)}, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    sys.exit(main())
