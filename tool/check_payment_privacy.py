"""Block real payment handles and private signing files from tracked source."""
from pathlib import Path
import argparse,json,re,subprocess,sys

root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser();parser.add_argument('--paths',type=Path);args=parser.parse_args()
paths=json.loads(args.paths.read_text()) if args.paths else subprocess.check_output(['git','ls-files','-z'],cwd=root).decode().split('\0')
handle=re.compile(r'(?<![A-Za-z0-9._-])([A-Za-z0-9._-]{2,100})(?:@|%40)([A-Za-z][A-Za-z0-9]{1,63})(?![A-Za-z0-9.-])',re.I)
fixture_names={'test','demo','fixture','merchant','newname','evil'}
fail=[]
for name in filter(None,paths):
 name=name.replace('\\','/');p=root/name
 if not p.is_file():continue
 if p.suffix.lower() in {'.jks','.keystore','.p12','.pfx'} or p.name in {'key.properties','credentials.json','github-secrets.json'}:
  fail.append(name+': private signing file');continue
 try:text=p.read_text(encoding='utf-8')
 except UnicodeError:continue
 for match in handle.finditer(text):
  # Action version references and Kotlin return labels are code, not payment addresses.
  if name.startswith('.github/workflows/') and re.fullmatch(r'v[0-9]+',match.group(2)):continue
  if p.suffix=='.kt' and match.group(1)=='return' and match.group(2)=='setMethodCallHandler':continue
  if match.group(1) in {'name','yourname'} and match.group(2)=='bank':continue
  fixture=name.startswith(('mobile/test/','supabase/tests/')) and match.group(1).lower() in fixture_names and match.group(2).lower()=='upi'
  if not fixture:fail.append(name+': payment handle at line '+str(text.count('\n',0,match.start())+1))
if fail:
 print('Blocked tracked payment/signing data (values withheld):\n'+'\n'.join(sorted(set(fail))));sys.exit(1)
print('PASS: tracked source contains no real UPI handles or private signing files.')

