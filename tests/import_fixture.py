#!/usr/bin/env python3
"""Copy the independently generated Rails fixture into a disposable Docker volume."""
import importlib.util,json,os,shlex,sqlite3,tempfile
from pathlib import Path
spec=importlib.util.spec_from_file_location('manage',Path(__file__).resolve().parents[1]/'tools/manage.py');manage=importlib.util.module_from_spec(spec);spec.loader.exec_module(manage)
source=Path('/workspace/once-campfire-verification/fixtures/default');destination=Path('/migration/site')
allowed={'SECRET_KEY_BASE','VAPID_PRIVATE_KEY','VAPID_PUBLIC_KEY','VAPID_SUBJECT'}
values={k:v for k,v in (line.split('=',1) for line in (source/'reference.env').read_text().splitlines() if line and not line.startswith('#')) if k in allowed}
with tempfile.TemporaryDirectory() as temp:
 keys=Path(temp)/'keys.env';keys.write_text(''.join(k+'='+shlex.quote(v)+'\n' for k,v in values.items()));keys.chmod(0o600)
 # The upstream fixture intentionally contains one message with a missing user.
 try:manage.import_rails(source/'db/production.sqlite3',source/'storage',destination,keys)
 except SystemExit:pass
 else:raise AssertionError('Strict import must detect the fixture orphan')
 manage.import_rails(source/'db/production.sqlite3',source/'storage',destination,keys,allow_existing_orphans=True)
with manage.connect((source/'db/production.sqlite3').as_uri()+'?mode=ro',uri=True) as original,manage.connect(destination/'production.sqlite3') as imported:
 for table in ['users','rooms','messages','memberships','sessions','action_text_rich_texts','active_storage_blobs','active_storage_attachments']:
  assert original.execute('SELECT * FROM '+table+' ORDER BY 1').fetchall()==imported.execute('SELECT * FROM '+table+' ORDER BY 1').fetchall(),table
for path in [Path('/migration'),destination,*destination.rglob('*')]:os.chown(path,10001,10001)
print('PASS: imported original Rails fixture without changing its rows, objects, or keys')
