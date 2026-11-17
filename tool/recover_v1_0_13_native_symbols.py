import concurrent.futures
import hashlib
import io
import json
from pathlib import Path
import struct
import urllib.request
import zipfile

import os
ROOT = Path(__file__).resolve().parent.parent
OUT = Path(os.environ.get('PUFFLE_SYMBOLS_OUT', str(ROOT / 'native-symbols')))
OUT.mkdir(parents=True, exist_ok=True)
ENGINE = '82bd5b7209295a5b7ff8cae0df96e7870171e3a5'
AAB = Path(os.environ.get('PUFFLE_AAB', str(ROOT / 'Puffle-play-with-plans.aab')))
EXPECTED = '757b05e31a12a463c2cd6c44ae940e17832bab98ff07ed40ef2b9a97cefadf86'

def sections(data):
    fmt = '<HHIQQQIHHHHHH' if data[4] == 2 else '<HHIIIIIHHHHHH'
    h = struct.unpack_from(fmt, data, 16)
    sf = '<IIQQQQIIQQ' if data[4] == 2 else '<IIIIIIIIII'
    ss = [struct.unpack_from(sf, data, h[5] + i*h[10]) for i in range(h[11])]
    names = data[ss[h[12]][4]:ss[h[12]][4]+ss[h[12]][5]]
    return {names[s[0]:].split(b'\0')[0].decode():data[s[4]:s[4]+s[5]] for s in ss}

def build_id(data):
    note = sections(data)['.note.gnu.build-id']
    ns, ds, typ = struct.unpack_from('<III', note)
    assert typ == 3
    return note[12 + ((ns+3)//4)*4:12 + ((ns+3)//4)*4 + ds].hex()

def download(pair):
    abi, platform = pair
    url = f'https://storage.googleapis.com/flutter_infra_release/flutter/{ENGINE}/{platform}-release/symbols.zip'
    cache = OUT / f'{platform}-symbols.zip'
    if not cache.exists():
        with urllib.request.urlopen(url, timeout=180) as response:
            cache.write_bytes(response.read())
    with zipfile.ZipFile(cache) as archive:
        names = [n for n in archive.namelist() if n.endswith('libflutter.so')]
        assert len(names) == 1, archive.namelist()
        data = archive.read(names[0])
    with zipfile.ZipFile(AAB) as bundle:
        expected = build_id(bundle.read(f'base/lib/{abi}/libflutter.so'))
    actual = build_id(data)
    assert actual == expected, (abi, expected, actual)
    assert '.symtab' in sections(data) or '.debug_info' in sections(data)
    print(f'{abi}: exact build ID {actual}; symbols verified', flush=True)
    return abi, data, {'abi':abi,'library':'libflutter.so','build_id':actual,'source':url,'sha256':hashlib.sha256(data).hexdigest()}

if __name__ == '__main__':
    assert hashlib.sha256(AAB.read_bytes()).hexdigest() == EXPECTED, 'This recovery tool is only for the original v1.0.13 code14 plans AAB'
    pairs = [('armeabi-v7a','android-arm'),('arm64-v8a','android-arm64'),('x86_64','android-x64')]
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(download, pairs))
    target = OUT/'Puffle-v1.0.13-code14-native-debug-symbols.zip'
    with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
        for abi,data,_ in results:
            archive.writestr(f'{abi}/libflutter.so',data)
    report = {'version':'1.0.13','version_code':14,'bundle_sha256':hashlib.sha256(AAB.read_bytes()).hexdigest(),'engine_revision':ENGINE,'libraries':[r[2] for r in results],'coverage':'Flutter engine native symbols only. Original libapp.so Dart AOT and AndroidX datastore symbols were not retained by the original build. These cannot be recovered from stripped binaries.','archive_sha256':hashlib.sha256(target.read_bytes()).hexdigest()}
    (OUT/'Puffle-v1.0.13-code14-native-symbols-verification.json').write_text(json.dumps(report,indent=2))
    print(target, target.stat().st_size, flush=True)
