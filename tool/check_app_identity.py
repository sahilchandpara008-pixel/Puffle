"""Fail builds if legacy branding or another backend enters Puffle's tracked source/artifacts."""
from pathlib import Path
import subprocess, sys, zipfile
legacy=bytes.fromhex('6f72626978')
root=Path(__file__).resolve().parent.parent
fail=[]
paths=subprocess.check_output(['git','ls-files','-z'],cwd=root).decode().split('\0')
for name in filter(None,paths):
 p=root/name
 if not p.is_file(): continue
 data=p.read_bytes().lower()
 if legacy in name.lower().encode() or legacy in data or legacy.decode().encode('utf-16le') in data: fail.append(name)
for name in sys.argv[1:]:
 with zipfile.ZipFile(root/name) as archive:
  for entry in archive.infolist():
   data=archive.read(entry).lower()
   if legacy in entry.filename.lower().encode() or legacy in data or legacy.decode().encode('utf-16le') in data: fail.append(name+':'+entry.filename)
assert not fail,'Legacy identity found: '+', '.join(fail)
assert 'com.pufflecloud.app' in (root/'mobile/android/app/build.gradle.kts').read_text()
assert 'dqufassvbkattmmsuwmf' in (root/'mobile/lib/config.dart').read_text()
print('Puffle identity checks passed.')
