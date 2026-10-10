#!/usr/bin/env python3
"""Compare complete durable workloads using local outbox-enabled Rust/C branches."""
import argparse,hashlib,json,os,statistics,time
from pathlib import Path
import local as b

ENV={'CAMPFIRE_DURABLE_JOBS':'1','CAMPFIRE_SQLITE_SYNCHRONOUS':'FULL','CAMPFIRE_JOB_RECEIPTS':'1','CF_JOB_WORKERS':'3'}

def state(db,app):
 with b.connection(db) as c:
  if app=='mojo':
   pending=c.execute('SELECT count(*) FROM mojo_jobs').fetchone()[0]
   failed=c.execute('SELECT count(*) FROM mojo_jobs WHERE failed<>0 OR error IS NOT NULL').fetchone()[0]
   completed={r[0] for r in c.execute("SELECT message_id FROM campfire_completed_jobs WHERE kind='message'")}
  else:
   pending=c.execute('SELECT count(*) FROM campfire_jobs WHERE completed_at IS NULL').fetchone()[0]
   failed=c.execute("SELECT count(*) FROM campfire_jobs WHERE error<>'' OR attempts>1").fetchone()[0]
   query="SELECT b FROM campfire_jobs WHERE kind='push' AND completed_at IS NOT NULL" if app=='rust' else 'SELECT message_id FROM campfire_jobs WHERE kind=0 AND completed_at IS NOT NULL'
   completed={r[0] for r in c.execute(query)}
  receipts=set(c.execute("SELECT message_id,target_id FROM campfire_delivery_receipts WHERE kind='push'"))
 return pending,failed,completed,receipts

def drain(db,app,expected,subscriptions,timeout=180):
 started=time.monotonic()
 while True:
  pending,failed,completed,receipts=state(db,app)
  if failed:raise AssertionError((app,'failed/retried jobs',failed,pending))
  if pending==0 and completed==expected:break
  if time.monotonic()-started>timeout:raise AssertionError((app,'drain timeout',pending,len(completed),len(expected)))
  time.sleep(.01)
 assert receipts=={(m,s) for m in expected for s in subscriptions},(app,len(receipts),len(expected),subscriptions)
 return {'pending':pending,'failed':failed,'completed_messages':len(completed),'completed_notifications':len(receipts),'drain_seconds':time.monotonic()-started}

def new_ids(db,room,baseline):
 with b.connection(db) as c:return {r[0] for r in c.execute('SELECT id FROM messages WHERE room_id=?',(room,))}-baseline

def run_one(app,round_no,args,labels):
 assert os.environ.get('CAMPFIRE_TEST_NO_AFFINITY')!='1','Benchmark requires explicit CPU affinity; unset the CI test override'
 dest=args.output/f'{app}-{round_no}';samples=[];audit_files=[];acknowledged=0
 with b.server(app,dest,args.server_cpus,not args.no_cache,verify_log=True) as (db,runtime,binary):
  cookie=b.login(labels,args.client_cpus)
  contracts,paths,preflight=b.contracts(db,labels,cookie,dest/'contracts')
  room=int(labels['rooms.hq'])
  with b.connection(db) as c:
   baseline={r[0] for r in c.execute('SELECT id FROM messages WHERE room_id=?',(room,))}
   subscriptions={r[0] for r in c.execute("SELECT ps.id FROM push_subscriptions ps JOIN memberships mm ON mm.user_id=ps.user_id JOIN users u ON u.id=ps.user_id WHERE mm.room_id=? AND mm.user_id<>? AND u.status=0 AND mm.involvement='everything' AND (mm.connected_at IS NULL OR mm.connected_at<datetime('now','-60 seconds'))",(room,labels['users.david']))}
  assert len(subscriptions)==3
  for route in b.ROUTES:
   target=['--path',paths[route]] if route in paths else ['--post-room',str(room),'--csrf','']
   for phase,duration,conc in [('warmup',args.warmup,4),('timed',args.duration,16)]:
    audit=[]
    if route=='post_message':
     audit_path=dest/f'{phase}-acknowledgements.jsonl';audit_files.append(audit_path);audit=['--audit-writes',audit_path]
    before=os.times();started=time.monotonic()
    sample=b.loadgen('http','--base',b.BASE,'--cookie',cookie,*target,'--validate',contracts[route],*audit,'--conc',str(conc),'--duration',str(duration),client_cpus=args.client_cpus)
    http_elapsed=time.monotonic()-started;after=os.times();b.check_sample(sample)
    sample['route']=route;sample['http_rps']=sample['rps'];sample['http_elapsed_seconds']=http_elapsed
    if route=='post_message':
     acknowledged+=sample['ok']
     ids=new_ids(db,room,baseline);assert len(ids)==acknowledged
     sample['completion']=drain(db,app,ids,subscriptions)
     complete_elapsed=time.monotonic()-started
     sample['completed_work_seconds']=complete_elapsed
     sample['rps']=sample['ok']/complete_elapsed
    sample['generator_cpu_percent']=100*(after.children_user+after.children_system-before.children_user-before.children_system)/http_elapsed
    b.write_json(dest/f'{route}-{phase}.json',sample)
    if phase=='timed':
     samples.append(sample)
     print(f'{app} {round_no} {route}: {sample["rps"]:.1f} completed workloads/s',flush=True)
  audit=json.loads(b.command(['ruby',b.VERIFICATION/'bench/validate_acks.rb',db,room,acknowledged,*audit_files]))
  finish=drain(db,app,new_ids(db,room,baseline),subscriptions)
  with b.connection(db) as c:
   assert c.execute('PRAGMA integrity_check').fetchone()==('ok',)
   assert c.execute('SELECT count(*) FROM messages WHERE id NOT IN (SELECT rowid FROM message_search_index)').fetchone()==(0,)
  result={'app':app,'round':round_no,'http':samples,'preflight':preflight,'post_write_audit':audit,'completed':finish,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest()}
 result['server_log_gate']={'passed':True};b.write_json(dest/'result.json',result);return result

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--output',required=True,type=Path);parser.add_argument('--rounds',type=int,default=3)
 parser.add_argument('--duration',type=int,default=8);parser.add_argument('--warmup',type=int,default=2)
 parser.add_argument('--server-cpus',default='0-3');parser.add_argument('--client-cpus',default='4-7');parser.add_argument('--no-cache',action='store_true')
 args=parser.parse_args();assert not args.output.exists();args.output.mkdir(parents=True)
 os.environ.update(ENV);os.environ.pop('CAMPFIRE_JOBS_PAUSED',None)
 (args.output/'index-plans.log').write_text(b.command(['python3',b.MOJO/'tests/durable_indexes.py']))
 gate=b.command(['python3',b.MOJO/'tests/parity.py'],env=os.environ|{'PARITY_RESULTS':str((args.output/'parity').resolve())})
 (args.output/'parity.log').write_text(gate)
 parity=json.loads((args.output/'parity/comparison.json').read_text());assert parity['passed']
 labels=json.loads((b.SEED/'labels.json').read_text());seed=hashlib.sha256((b.SEED/'db/production.sqlite3').read_bytes()).hexdigest()
 metadata={'complete':False,'started_at_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'platform':list(os.uname()),'server_cpus':args.server_cpus,'client_cpus':args.client_cpus,'rounds':args.rounds,'order':'rotating Latin-square order: Rust/C/Mojo, C/Mojo/Rust, Mojo/Rust/C','duration_seconds':args.duration,'warmup_seconds':args.warmup,'concurrency':16,'response_cache_mib':0 if args.no_cache else 64,'seed_sha256':seed,'durability':'SQLite WAL synchronous=FULL; atomic message/outbox; persisted retries and receipts; at-least-once recovery','completion':'Post rate includes HTTP plus final job drain, exact message IDs and subscription receipt sets required','notifications':'Three selected subscriptions/message; canonical notification preparation and identical endpoint-policy rejection; no remote push network in timed workloads','active_cable_subscribers':0,'parity_gate':parity,'local_reference_patches':True,'environment':ENV,'revisions':{},'patch_sha256':{},'loadgen_sha256':hashlib.sha256(b.LOADGEN.read_bytes()).hexdigest()}
 for app in ['rust','c','mojo']:
  path=b.WORKSPACE/f'once-campfire-{app}'
  metadata['revisions'][app]=b.command(['git','-C',path,'rev-parse','HEAD']).strip()
  metadata['patch_sha256'][app]=hashlib.sha256(b.command(['git','-C',path,'diff','HEAD']).encode()).hexdigest()
 b.write_json(args.output/'metadata.json',metadata)
 results=[]
 for round_no in range(1,args.rounds+1):
  for app in (['rust','c','mojo'][(round_no-1)%3:]+['rust','c','mojo'][:(round_no-1)%3]):results.append(run_one(app,round_no,args,labels))
 assert hashlib.sha256((b.SEED/'db/production.sqlite3').read_bytes()).hexdigest()==seed
 summary={app:{route:{'median_rps':statistics.median(v['rps'] for r in results if r['app']==app for v in r['http'] if v['route']==route),'runs':[v['rps'] for r in results if r['app']==app for v in r['http'] if v['route']==route]} for route in b.ROUTES} for app in ['rust','c','mojo']}
 metadata['complete']=True;metadata['acknowledged_and_completed_messages']=sum(r['completed']['completed_messages'] for r in results);metadata['completed_notification_receipts']=sum(r['completed']['completed_notifications'] for r in results)
 b.write_json(args.output/'metadata.json',metadata);b.write_json(args.output/'summary.json',{'metadata':metadata,'results':summary});print(json.dumps(summary,indent=2))

if __name__=='__main__':main()
