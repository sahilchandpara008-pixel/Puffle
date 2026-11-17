"""Apply public signature metadata to exact tested candidates; never receives a private key."""
from pathlib import Path
import base64,gzip,hashlib,json,re,shutil,subprocess,sys,zipfile
root=Path(sys.argv[1]).resolve()
patch=json.loads(gzip.decompress(base64.b64decode(Path(__file__).with_name('puffle-v1.0.13-signatures.json.gz.b64').read_text())))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def sig(n):return n.upper()=='META-INF/MANIFEST.MF' or bool(re.match(r'^META-INF/[^/]+\.(SF|RSA|DSA|EC)$',n.upper()))
def payload(p):
 with zipfile.ZipFile(p) as z:return {n:hashlib.sha256(z.read(n)).hexdigest() for n in z.namelist() if not sig(n)}
records={}
for name,change in patch['files'].items():
 p=root/name;assert sha(p)==change['original_sha256'],'Wrong candidate: '+name
 before=payload(p)
 if change['kind']=='apk_segments':
  original=p.read_bytes();parts=[]
  for segment in change['segments']:
   if 'copy' in segment:
    start,length=segment['copy'];assert start>=0 and length>=0 and start+length<=len(original);parts.append(original[start:start+length])
   else:parts.append(base64.b64decode(segment['data']))
  p.write_bytes(b''.join(parts));assert sha(p)==change['signed_sha256']
  tool=Path(sys.argv[2])
  command=['java','-jar',str(tool),'verify','--verbose','--print-certs',str(p)] if tool.suffix=='.jar' else [str(tool),'verify','--verbose','--print-certs',str(p)]
  verified=subprocess.run(command,capture_output=True,text=True,check=True).stdout
  assert patch['certificate_sha256'].replace(':','').lower() in verified.lower()
  assert 'Verified using v2 scheme (APK Signature Scheme v2): true' in verified
 else:
  temp=p.with_suffix('.fixed.aab')
  with zipfile.ZipFile(p) as old,zipfile.ZipFile(temp,'w') as new:
   for n,data in change['signatures'].items():
    entry=zipfile.ZipInfo(n,(2026,11,17,0,0,0));entry.compress_type=zipfile.ZIP_DEFLATED;new.writestr(entry,base64.b64decode(data))
   for entry in old.infolist():
    if not sig(entry.filename):new.writestr(entry,old.read(entry))
  temp.replace(p)
  assert 'jar verified.' in subprocess.run(['jarsigner','-verify',str(p)],capture_output=True,text=True,check=True).stdout
  cert=subprocess.run(['keytool','-printcert','-jarfile',str(p)],capture_output=True,text=True,check=True).stdout
  assert patch['certificate_sha256'] in cert and 'Android Debug' not in cert
 assert payload(p)==before,'App payload changed: '+name
 records[name]={'sha256':sha(p),'bytes':p.stat().st_size,'payload_unchanged':True,'release_signed':True}
(root/'checksums.txt').write_text(''.join(sha(root/n)+'  '+n+'\n' for n in records))
(root/'release-signing-verification.json').write_text(json.dumps({'version':patch['version'],'version_code':patch['version_code'],'certificate_sha256':patch['certificate_sha256'],'files':records},indent=2))
(root/'README.txt').write_text('Puffle v1.0.13 (14)\nPuffle.apk: Organic direct Android app.\nPuffle-ads.apk: Ads direct Android app.\nPuffle-play-with-plans.aab: Google Play upload with existing plans/UPI flow. Applicable Play billing enrollment/policy requirements still apply.\nPuffle-play.aab: standard Play configuration without the direct UPI/pricing flow.\nAll four files use the dedicated Puffle upload certificate; no debug certificate or private signing key is included.\nSecure an existing paid guest account before uninstalling an older test APK if Android reports an incompatible signing certificate.\n',encoding='utf-8')
files=list(records)+['checksums.txt','release-signing-verification.json','README.txt']
for zipname in ['Puffle-apks-v1.0.13.zip','Puffle-Play-Console-kit-v1.0.13.zip']:
 with zipfile.ZipFile(root/zipname,'w',zipfile.ZIP_DEFLATED) as z:
  for name in files:z.write(root/name,name)
  if 'Console' in zipname:
   for p in sorted((root/'image-assets').rglob('*.png')):z.write(p,'image-assets/'+p.name)
 with zipfile.ZipFile(root/zipname) as z:assert z.testzip() is None
print(json.dumps(records))

