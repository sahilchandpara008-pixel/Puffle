"""Repair only the public signatures of the existing v1.0.12 AAB payloads."""
import base64, gzip, hashlib, json, re, subprocess, sys, zipfile
from pathlib import Path

root=Path(sys.argv[1]).resolve()
patch=json.loads(gzip.decompress(base64.b64decode(Path(__file__).with_name('puffle-v1.0.12-signatures.json.gz.b64').read_text())))
def sig(name):
    return name.upper()=='META-INF/MANIFEST.MF' or bool(re.match(r'^META-INF/[^/]+\.(SF|RSA|DSA|EC)$',name.upper()))
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def certificate(path):
    return subprocess.run(['keytool','-printcert','-jarfile',str(path)],capture_output=True,text=True,check=True).stdout
records={}
for name,change in patch['bundles'].items():
    source=root/name
    if patch['certificate_sha256'] not in certificate(source):
        assert sha(source)==change['original_sha256'], 'Unexpected source bundle: '+name
        temp=source.with_suffix('.fixed.aab')
        with zipfile.ZipFile(source) as old,zipfile.ZipFile(temp,'w') as new:
            for n,data in change['signatures'].items():
                info=zipfile.ZipInfo(n,(2026,11,15,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED
                new.writestr(info,base64.b64decode(data))
            for info in old.infolist():
                if not sig(info.filename):new.writestr(info,old.read(info))
        with zipfile.ZipFile(source) as old,zipfile.ZipFile(temp) as new:
            assert {n:hashlib.sha256(old.read(n)).hexdigest() for n in old.namelist() if not sig(n)} == {n:hashlib.sha256(new.read(n)).hexdigest() for n in new.namelist() if not sig(n)}, 'App payload changed'
        temp.replace(source)
    verified=subprocess.run(['jarsigner','-verify',str(source)],capture_output=True,text=True,check=True)
    assert 'jar verified.' in verified.stdout
    cert=certificate(source)
    assert 'Android Debug' not in cert and patch['certificate_sha256'] in cert
    records[name]={'sha256':sha(source),'bytes':source.stat().st_size,'payload_unchanged':True,'release_signed':True}

builds=['Puffle.apk','Puffle-ads.apk','Puffle-play.aab','Puffle-play-with-plans.aab']
checks=''.join(sha(root/n)+'  '+n+'\n' for n in builds)
(root/'checksums.txt').write_text(checks)
(root/'release-signing-verification.json').write_text(json.dumps({'certificate_sha256':patch['certificate_sha256'],'bundles':records,'apks':'Existing APK test builds are unchanged; this repair corrects the AAB signatures.'},indent=2))
with zipfile.ZipFile(root/'Puffle-apks-v1.0.12.zip','w',zipfile.ZIP_DEFLATED) as z:
    for name in builds+['checksums.txt','release-signing-verification.json']:z.write(root/name,name)
kit_zip=root/'Puffle-Play-Console-kit-v1.0.12.zip';kit=root/'kit';kit.mkdir(exist_ok=True)
with zipfile.ZipFile(kit_zip) as z:
    for name in z.namelist():
        dest=(kit/name).resolve()
        assert dest.is_relative_to(kit), 'Unsafe archive entry'
        assert not any(x in name.lower() for x in ['.jks','.p12','credentials','private-backup'])
    z.extractall(kit)
for name in builds+['checksums.txt','release-signing-verification.json']:(kit/name).write_bytes((root/name).read_bytes())
with (kit/'README.txt').open('a') as f:f.write('\nAAB SIGNING CORRECTION: Both AABs now use the dedicated Puffle upload certificate; app payloads and payment behavior are unchanged. APK test builds are unchanged. Keep the private upload key outside this kit.\n')
(kit/'kit-checksums.txt').write_text(''.join(sha(p)+'  '+p.relative_to(kit).as_posix()+'\n' for p in sorted(kit.rglob('*')) if p.is_file() and p.name!='kit-checksums.txt'))
with zipfile.ZipFile(kit_zip,'w',zipfile.ZIP_DEFLATED) as z:
    for p in sorted(kit.rglob('*')):
        if p.is_file():z.write(p,p.relative_to(kit).as_posix())
for n in ['Puffle-apks-v1.0.12.zip','Puffle-Play-Console-kit-v1.0.12.zip']:
    with zipfile.ZipFile(root/n) as z:
        assert z.testzip() is None
        for aab in patch['bundles']:assert hashlib.sha256(z.read(aab)).hexdigest()==records[aab]['sha256']
print(json.dumps(records))
