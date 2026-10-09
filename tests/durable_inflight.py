#!/usr/bin/env python3
"""Crash while jobs and recipient receipts are actively progressing in all three ports."""
import concurrent.futures,contextlib,json,os,signal,subprocess,sys,tempfile,time,unittest,urllib.parse
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'bench'))
import local as b
import durable


def drain_recovered(db,app,expected,subscriptions,timeout=180):
 # Reclaiming a killed worker's lease legitimately increments attempts. Retained
 # handler failures still fail this gate; the benchmark itself forbids retries.
 started=time.monotonic()
 while True:
  pending,_,completed,receipts=durable.state(db,app)
  with b.connection(db) as c:
   query='SELECT count(*) FROM mojo_jobs WHERE failed<>0 OR error IS NOT NULL' if app=='mojo' else "SELECT count(*) FROM campfire_jobs WHERE error<>''"
   failed=c.execute(query).fetchone()[0]
  assert failed==0,(app,failed)
  if pending==0 and completed==expected:break
  assert time.monotonic()-started<timeout,(app,pending,len(completed))
  time.sleep(.01)
 assert receipts=={(m,s) for m in expected for s in subscriptions}
 return {'pending':pending,'failed':failed,'completed_messages':len(completed),'completed_notifications':len(receipts),'drain_seconds':time.monotonic()-started}

class Durability(unittest.TestCase):
 def test_every_ack_and_notification_recovers_after_sigkill(self):
  os.environ.update(durable.ENV)
  evidence=[]
  labels=json.loads((b.SEED/'labels.json').read_text());room=int(labels['rooms.hq'])
  for app in ['rust','c','mojo']:
   with self.subTest(app=app),tempfile.TemporaryDirectory() as out:
    os.environ.pop('CAMPFIRE_JOBS_PAUSED',None)
    dest=Path(os.environ.get('DURABLE_TEST_RESULTS',out))/app
    with b.server(app,dest,cache=False,verify_log=True) as (db,runtime,_):
     cookie=b.login(labels)
     with b.connection(db) as c:
      baseline={r[0] for r in c.execute('select id from messages where room_id=?',(room,))}
      subscriptions={r[0] for r in c.execute("SELECT ps.id FROM push_subscriptions ps JOIN memberships mm ON mm.user_id=ps.user_id WHERE mm.room_id=? AND mm.user_id<>? AND mm.involvement='everything'",(room,labels['users.david']))}
     parents=[]
     for entry in Path('/proc').glob('[0-9]*'):
      try:
       pid=int(entry.name)
       if os.readlink(entry/'exe')==str(runtime/'app/campfire') and os.getpgid(pid)==pid:parents.append(pid)
      except (OSError,ValueError):pass
     self.assertEqual(len(parents),1);pid=parents[0]
     environment=dict(item.split(b'=',1) for item in Path(f'/proc/{pid}/environ').read_bytes().split(b'\0') if item)
     env={k.decode():v.decode() for k,v in environment.items()};env.pop('CAMPFIRE_JOBS_PAUSED',None)
     command=[x.decode() for x in Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0') if x]
     def post(i):
      body=urllib.parse.urlencode({'message[body]':f'inflight durable accepted {i}','message[client_message_id]':f'crash-acceptance-{i}'})
      result=b.request(f'/rooms/{room}/messages',cookie,'POST',body,{'Content-Type':'application/x-www-form-urlencoded','Accept':'text/vnd.turbo-stream.html'})
      self.assertEqual(result[0],200,result[2][:150])
     with concurrent.futures.ThreadPoolExecutor(max_workers=8) as workers:list(workers.map(post,range(1200)))
     expected=durable.new_ids(db,room,baseline);self.assertEqual(len(expected),1200)
     deadline=time.monotonic()+10
     while True:
      pending,failed,complete,receipts=durable.state(db,app)
      table='mojo_jobs' if app=='mojo' else 'campfire_jobs'
      with b.connection(db) as c:leased=c.execute('SELECT count(*) FROM '+table+' WHERE lease_until>unixepoch()').fetchone()[0]
      if pending>0 and leased>0 and receipts:break
      self.assertLess(time.monotonic(),deadline,'No active backlog to crash')
      time.sleep(.001)
     os.killpg(pid,signal.SIGKILL)
     time.sleep(.15)
     pending_at_crash,_,_,receipts_at_crash=durable.state(db,app)
     with b.connection(db) as c:leased_at_crash=c.execute('SELECT count(*) FROM '+table+' WHERE lease_until>unixepoch()').fetchone()[0]
     self.assertGreater(pending_at_crash,0);self.assertGreater(leased_at_crash,0);self.assertGreater(len(receipts_at_crash),0)
     with (dest/'restart.log').open('w') as log:
      proc=subprocess.Popen(['taskset','-c','0-3',*command],cwd=runtime/'app',env=env,stdout=log,stderr=log,start_new_session=True)
      try:
       deadline=time.monotonic()+30
       while True:
        self.assertIsNone(proc.poll())
        try:
         if b.request('/up')[0]==200:break
        except (OSError,Exception) as e:
         if time.monotonic()>deadline:raise e
        time.sleep(.05)
       receipt=drain_recovered(db,app,expected,subscriptions)
       self.assertEqual(durable.new_ids(db,room,baseline),expected)
       with b.connection(db) as c:
        self.assertEqual(c.execute('PRAGMA integrity_check').fetchone(),('ok',))
        self.assertEqual(c.execute('SELECT count(*) FROM messages WHERE id NOT IN (SELECT rowid FROM message_search_index)').fetchone(),(0,))
       # Completed jobs must not rerun on the next restart.
       os.killpg(proc.pid,signal.SIGTERM);proc.wait(15)
       b.validate_server_log(dest/'restart.log')
       second=subprocess.Popen(['taskset','-c','0-3',*command],cwd=runtime/'app',env=env,stdout=log,stderr=log,start_new_session=True)
       try:
        time.sleep(.4);self.assertIsNone(second.poll());again=drain_recovered(db,app,expected,subscriptions)
        self.assertEqual(again['completed_notifications'],receipt['completed_notifications'])
       finally:os.killpg(second.pid,signal.SIGTERM);second.wait(15)
       evidence.append({'app':app,'acknowledged_before_crash':1200,'jobs_pending_at_crash':pending_at_crash,'leased_jobs_at_crash':leased_at_crash,'recipient_receipts_at_crash':len(receipts_at_crash),'mode':'inflight','completed_after_restart':receipt,'restart_did_not_duplicate_receipts':True})
      finally:
       if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
     b.validate_server_log(dest/'restart.log')
  os.environ.pop('CAMPFIRE_JOBS_PAUSED',None)
  print(json.dumps(evidence),flush=True)
  if os.environ.get('DURABLE_TEST_RESULTS'):b.write_json(Path(os.environ['DURABLE_TEST_RESULTS'])/'recovery.json',evidence)

if __name__=='__main__':unittest.main(verbosity=2)
