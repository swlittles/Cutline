#!/usr/bin/env python3
from release_config import release_repository
"""Commit signed bytes to the public feed branch only after release assets exist."""
import base64,json,subprocess,sys,xml.etree.ElementTree as ET
from pathlib import Path
root=Path(sys.argv[1]); sha=sys.argv[2]; meta=json.loads((root/'release.json').read_text())
repo='repos/' + release_repository()
def api(path, payload=None):
    args=['gh','api',f'{repo}/{path}']
    if payload is not None: args+=['--method','POST','--input','-']
    p=subprocess.run(args,input=json.dumps(payload) if payload is not None else None,text=True,capture_output=True)
    if p.returncode: raise RuntimeError(p.stderr)
    return json.loads(p.stdout) if p.stdout.strip() else None
try: ref=api('git/ref/heads/updates')
except RuntimeError as error:
    if 'HTTP 404' not in str(error): raise
    ref=None
head=ref['object']['sha'] if ref else None
commit=api(f'git/commits/{head}') if head else None
try:
    old=api('contents/release.json?ref=updates') if head else None
except RuntimeError as error:
    if 'HTTP 404' not in str(error): raise
    old=None
if old:
    previous=json.loads(base64.b64decode(old['content']))
    if previous['tag']==meta['tag'] and previous['build']==meta['build']:
        print('Feed already points at this release.'); sys.exit(0)
    assert previous['build'] < meta['build'], 'Refusing to roll back update feed'
    assert previous['mode'] != 'signed' or meta['mode'] == 'signed', 'Refusing to replace a stable feed with a preview'
meta['commit']=sha
entries=[]
for name,data in [('appcast.xml',(root/'appcast.xml').read_bytes()),('release.json',(json.dumps(meta,indent=2)+'\n').encode())]:
    blob=api('git/blobs',{'content':base64.b64encode(data).decode(),'encoding':'base64'})
    entries.append({'path':name,'mode':'100644','type':'blob','sha':blob['sha']})
tree_payload={'tree':entries}
if commit: tree_payload['base_tree']=commit['tree']['sha']
tree=api('git/trees',tree_payload)
new=api('git/commits',{'message':f"Publish {meta['tag']} update feed",'tree':tree['sha'],'parents':[head] if head else []})
if not head:
    api('git/refs',{'ref':'refs/heads/updates','sha':new['sha']})
    print('Published initial signed update feed for',meta['tag']); sys.exit(0)
# Non-force update rejects concurrent publication instead of losing a newer release.
p=subprocess.run(['gh','api',f'{repo}/git/refs/heads/updates','--method','PATCH','--input','-'],input=json.dumps({'sha':new['sha'],'force':False}),text=True,capture_output=True)
if p.returncode: raise RuntimeError(p.stderr)
print('Published signed update feed for',meta['tag'])
