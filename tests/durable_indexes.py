import json,re,sqlite3
from pathlib import Path
root=Path('/workspace')
evidence={}
for name in ['rust','c']:
 repo=root/('once-campfire-'+name)
 source=(repo/('crates/db/src/durable.rs' if name=='rust' else 'src/jobs/durable.h')).read_text()
 schema=re.search(r'"(CREATE TABLE IF NOT EXISTS campfire_jobs[^"\n]+)"',source)[1]
 queue=(repo/('crates/campfire/src/jobs.rs' if name=='rust' else 'src/jobs/queue.c')).read_text()
 query=re.search(r'"(UPDATE campfire_jobs SET lease_until=unixepoch\(\)\+600,attempts=attempts\+1[^"\n]+)"',queue)[1]
 handler=(repo/('crates/campfire/src/integrations/jobs.rs' if name=='rust' else 'src/jobs/handlers.c')).read_text()
 renew=re.search(r'"(UPDATE campfire_jobs SET lease_until=unixepoch\(\)\+600 WHERE[^"\n]+)"',handler)[1]
 conn=sqlite3.connect(':memory:');conn.executescript(schema)
 plans={}
 for label,sql,args in [('claim',query,() if name=='rust' else (0,)),('renew',renew,(123,))]:
  plans[label]=[r[3] for r in conn.execute('EXPLAIN QUERY PLAN '+sql,args)]
  assert not any('TEMP B-TREE' in x for x in plans[label]),plans[label]
  assert any(('campfire_jobs_pending' if label=='claim' else 'campfire_jobs_message') in x for x in plans[label]),plans[label]
 evidence[name]=plans
print(json.dumps(evidence,indent=2));print('PASS: both reference claim and lease-renewal queries use bounded pending-job indexes without temporary sorting')
