"""Embed build-ID-matched Flutter and Dart native symbols before release signing."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import urllib.request
import zipfile

PREFIX = 'BUNDLE-METADATA/com.android.tools.build.debugsymbols/'
TARGETS = {'armeabi-v7a': ('android-arm', 'arm'),
           'arm64-v8a': ('android-arm64', 'arm64'),
           'x86_64': ('android-x64', 'x64')}


def sections(data):
    assert data[:4] == b'\x7fELF' and data[5] == 1, 'Expected little-endian ELF symbols'
    wide = data[4] == 2
    header = struct.unpack_from('<HHIQQQIHHHHHH' if wide else '<HHIIIIIHHHHHH', data, 16)
    records = [struct.unpack_from('<IIQQQQIIQQ' if wide else '<IIIIIIIIII', data,
                                 header[5] + i * header[10]) for i in range(header[11])]
    table = records[header[12]]
    names = data[table[4]:table[4] + table[5]]
    return {names[r[0]:].split(b'\0')[0].decode(): data[r[4]:r[4] + r[5]]
            for r in records if r[1] != 8}  # SHT_NOBITS has no file content.


def build_id(data):
    note = sections(data)['.note.gnu.build-id']
    namesize, size, kind = struct.unpack_from('<III', note)
    assert kind == 3 and size > 0, 'Missing GNU build ID'
    offset = 12 + ((namesize + 3) // 4) * 4
    return note[offset:offset + size].hex()


def verify_pair(library, symbols):
    expected, actual = build_id(library), build_id(symbols)
    assert expected == actual, f'Symbol build ID mismatch: {expected} != {actual}'
    sec = sections(symbols)
    assert sec.get('.symtab') or sec.get('.debug_info'), 'Stripped library is not a symbols file'
    return actual


def signature(name):
    return bool(re.fullmatch(r'META-INF/(MANIFEST\.MF|[^/]+\.(SF|RSA|DSA|EC))', name, re.I))


def payload(bundle):
    return {n: hashlib.sha256(bundle.read(n)).hexdigest() for n in bundle.namelist()
            if not signature(n) and not n.startswith(PREFIX)}


def verify(bundle_path):
    report = []
    with zipfile.ZipFile(bundle_path) as bundle:
        assert len(bundle.namelist()) == len(set(bundle.namelist())), 'Duplicate ZIP entries'
        for abi in TARGETS:
            for library in ['libflutter.so', 'libapp.so']:
                candidates = [PREFIX + abi + '/' + library + ext for ext in ['.sym', '.dbg']]
                matches = [n for n in candidates if n in bundle.namelist()]
                assert len(matches) == 1, f'Missing/ambiguous embedded symbols for {abi}/{library}'
                symbols = bundle.read(matches[0])
                identity = verify_pair(bundle.read(f'base/lib/{abi}/{library}'), symbols)
                report.append({'abi': abi, 'library': library, 'build_id': identity,
                               'metadata': matches[0], 'bytes': len(symbols)})
    print(f'PASS: {bundle_path.name} embeds all six matched Flutter/Dart symbol files', flush=True)
    return report


def embed(bundle_path, dart_dir, output):
    flutter = Path(os.environ['FLUTTER_ROOT'])
    engine = (flutter / 'bin/internal/engine.version').read_text().strip()
    assert re.fullmatch(r'[0-9a-f]{40}', engine)
    output.mkdir(parents=True, exist_ok=True)
    cache = output.parent / 'engine-cache' / engine
    cache.mkdir(parents=True, exist_ok=True)
    ndks = sorted(Path(os.environ.get('ANDROID_HOME', '/nonexistent')).glob(
        'ndk/*/toolchains/llvm/prebuilt/*/bin/llvm-objcopy'))
    objcopy = os.environ.get('LLVM_OBJCOPY') or shutil.which('llvm-objcopy') or (str(ndks[-1]) if ndks else None)
    symbols = {}
    with zipfile.ZipFile(bundle_path) as bundle:
        original = payload(bundle)
        for abi, (platform, dart_arch) in TARGETS.items():
            engine_zip = cache / f'{platform}-release.zip'
            if not engine_zip.exists():
                url = f'https://storage.googleapis.com/flutter_infra_release/flutter/{engine}/{platform}-release/symbols.zip'
                with urllib.request.urlopen(url, timeout=180) as response:
                    engine_zip.write_bytes(response.read())
            with zipfile.ZipFile(engine_zip) as archive:
                names = [n for n in archive.namelist() if n.endswith('libflutter.so')]
                assert len(names) == 1
                data = archive.read(names[0])
            verify_pair(bundle.read(f'base/lib/{abi}/libflutter.so'), data)
            abi_dir = output / abi
            abi_dir.mkdir(exist_ok=True)
            if objcopy:
                with tempfile.TemporaryDirectory() as tmp:
                    source = Path(tmp) / 'libflutter.so'
                    source.write_bytes(data)
                    dest = abi_dir / 'libflutter.so.sym'
                    subprocess.run([objcopy, '--strip-debug', str(source), str(dest)], check=True)
                    data = dest.read_bytes()
                filename = 'libflutter.so.sym'
            else:
                filename = 'libflutter.so.dbg'
                (abi_dir / filename).write_bytes(data)
            verify_pair(bundle.read(f'base/lib/{abi}/libflutter.so'), data)
            symbols[f'{abi}/{filename}'] = data
            dart = (dart_dir / f'app.android-{dart_arch}.symbols').read_bytes()
            verify_pair(bundle.read(f'base/lib/{abi}/libapp.so'), dart)
            (abi_dir / 'libapp.so.dbg').write_bytes(dart)
            symbols[f'{abi}/libapp.so.dbg'] = dart
        temporary = bundle_path.with_suffix('.symbols-unsigned.aab')
        with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED) as target:
            for info in bundle.infolist():
                if signature(info.filename) or info.filename in {PREFIX + n for n in symbols}:
                    continue
                # Replace an alternate symbol format for the same Flutter/Dart library.
                if info.filename.startswith(PREFIX) and any(
                    info.filename == PREFIX + abi + '/' + lib + ext
                    for abi in TARGETS for lib in ['libflutter.so', 'libapp.so'] for ext in ['.sym', '.dbg']):
                    continue
                target.writestr(info, bundle.read(info.filename))
            for name, data in symbols.items():
                target.writestr(PREFIX + name, data)
    with zipfile.ZipFile(temporary) as check:
        assert payload(check) == original, 'App payload changed while adding diagnostic metadata'
    temporary.replace(bundle_path)
    report = verify(bundle_path)
    (output / 'verification.json').write_text(json.dumps({'engine_revision': engine,
        'payload_unchanged': True, 'symbols': report,
        'coverage': 'Flutter engine and Dart AOT code on every Flutter release ABI. Other prebuilt third-party native libraries may not supply symbols.'}, indent=2))
    with zipfile.ZipFile(output.with_suffix('.zip'), 'w', zipfile.ZIP_DEFLATED) as archive:
        for name, data in symbols.items():
            archive.writestr(name, data)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--dart-dir', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    if args.verify_only:
        verify(args.bundle)
    else:
        assert args.dart_dir and args.output
        embed(args.bundle, args.dart_dir, args.output)
