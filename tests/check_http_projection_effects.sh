#!/usr/bin/env bash
# Actual compiler tag-ceiling errors must name their operation and the precise
# unlisted-effect diagnostic. Each own tag-removal inverse must compile the same
# ceiling; strict tagged positive compilation prevents a broken setup passing.
set -euo pipefail
python3 - <<'PY'
from pathlib import Path
import tempfile,subprocess,shutil
root=Path.cwd(); work=Path(tempfile.mkdtemp(prefix='ne-http-effects-'))
fixture=root/'tests/http_projection_fixture.nim'
def compile(extra,path,out):
 return subprocess.run(['nim','js','-d:isonimStrictNondet','--path:'+str(path),'--out:'+str(out),*extra,str(fixture)],capture_output=True,text=True)
p=compile(['-d:extractedHttpComposition'],root/'src',work/'positive.js')
(work/'positive.log').write_text(p.stdout+p.stderr)
assert p.returncode==0,p.stdout+p.stderr
for mode,operation in [('Prepare','prepareHttpRequestRaw'),('Init','buildHttpRequestInitRaw'),('Project','projectHttpResponseRaw')]:
 p=compile(['-d:raw'+mode+'EffectCeiling'],root/'src',work/(mode+'.js'))
 text=p.stdout+p.stderr;(work/(mode+'.log')).write_text(text)
 assert p.returncode!=0,operation+' accepted tags:[]'
 assert 'Error: '+operation+'(' in text and 'can have an unlisted effect: RawNondet' in text,text
 copy=work/mode;shutil.copytree(root/'src',copy)
 file=copy/'nim_everywhere/http.nim';source=file.read_text()
 start=source.index('  proc '+operation+'*');end=source.index(' =\n',start)
 signature=source[start:end];assert signature.count('{.tags: [RawNondet].}')==1
 file.write_text(source[:start]+signature.replace(' {.tags: [RawNondet].}','')+source[end:])
 p=compile(['-d:raw'+mode+'EffectCeiling'],copy,work/(mode+'-inverse.js'))
 (work/(mode+'-inverse.log')).write_text(p.stdout+p.stderr)
 assert p.returncode==0,p.stdout+p.stderr
 print(operation+': precise effect refusal and own tag-removal inverse PASS')
print('retained effects inputs/logs',work)
PY
