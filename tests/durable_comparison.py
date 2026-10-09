#!/usr/bin/env python3
"""Shared crash acceptance for all locally patched durable implementations."""
import concurrent.futures,contextlib,json,os,signal,subprocess,sys,tempfile,time,unittest,urllib.parse
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'bench'))
import local as b
import durable

class Durability(unittest.TestCase):
 def test_every_ack_and_notification_recovers_after_sigkill(self):
  os.environ.update(durable.ENV)
  evidence=[]
  labels=json.loads((b.SEED/'labels.json').read_text());room=int(labels['rooms.hq'])
  for app in ['rust','c','mojo']:
   with self.subTest(app=app),tempfile.TemporaryDirectory() as out:
    os.environ['CAMPFIRE_JOBS_PAUSED']='1'
    dest=Path(os.environ.get('DURABLE_TEST_RESULTS',out))/app
    with b.server(app,dest,cache=False,verify_log=True) as (db,runtime,_):
     cookie=b.login(labels)
     with b.connection(db) as c:
      baseline={r[0] for r in c.execute('select id from messages where room_id=?',(room,))}
      subscriptions={r[0] for r in c.execute("SELECT ps.id FROM push_subscriptions ps JOIN memberships mm ON mm.user_id=ps.user_id WHERE mm.room_id=? AND mm.user_id<>? AND mm.involvement='everything'",(room,labels['users.david']))}
     def post(i):
      body=urllib.parse.urlencode({'message[body]':f'durable crash accepted {i}','message[client_message_id]':f'crash-acceptance-{i}'})
      result=b.request(f'/rooms/{room}/messages',cookie,'POST',body,{'Content-Type':'application/x-www-form-urlencoded','Accept':'text/vnd.turbo-stream.html'})
      self.assertEqual(result[0],200,result[2][:150])
     with concurrent.futures.ThreadPoolExecutor(max_workers=8) as workers:list(workers.map(post,range(160)))
     expected=durable.new_ids(db,room,baseline);self.assertEqual(len(expected),160)
     pending,failed,complete,receipts=durable.state(db,app)
     self.assertEqual((pending,failed,len(complete),len(receipts)),(160,0,0,0))
     # A rejected request must not enqueue orphan work.
     self.assertIn(b.request('/rooms/999999999999/messages',cookie,'POST','message[body]=rejected',{'Content-Type':'application/x-www-form-urlencoded'})[0],(200,403,404))
     self.assertEqual(durable.state(db,app)[0],160)
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
     os.killpg(pid,signal.SIGKILL)
     time.sleep(.15)
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
       receipt=durable.drain(db,app,expected,subscriptions)
       self.assertEqual(durable.new_ids(db,room,baseline),expected)
       with b.connection(db) as c:
        self.assertEqual(c.execute('PRAGMA integrity_check').fetchone(),('ok',))
        self.assertEqual(c.execute('SELECT count(*) FROM messages WHERE id NOT IN (SELECT rowid FROM message_search_index)').fetchone(),(0,))
       # Completed jobs must not rerun on the next restart.
       os.killpg(proc.pid,signal.SIGTERM);proc.wait(15)
       b.validate_server_log(dest/'restart.log')
       second=subprocess.Popen(['taskset','-c','0-3',*command],cwd=runtime/'app',env=env,stdout=log,stderr=log,start_new_session=True)
       try:
        time.sleep(.4);self.assertIsNone(second.poll());again=durable.drain(db,app,expected,subscriptions)
        self.assertEqual(again['completed_notifications'],receipt['completed_notifications'])
       finally:os.killpg(second.pid,signal.SIGTERM);second.wait(15)
       evidence.append({'app':app,'acknowledged_before_crash':160,'jobs_pending_at_crash':160,'completed_after_restart':receipt,'restart_did_not_duplicate_receipts':True})
      finally:
       if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
     b.validate_server_log(dest/'restart.log')
  os.environ.pop('CAMPFIRE_JOBS_PAUSED',None)
  print(json.dumps(evidence),flush=True)
  if os.environ.get('DURABLE_TEST_RESULTS'):b.write_json(Path(os.environ['DURABLE_TEST_RESULTS'])/'recovery.json',evidence)

if __name__=='__main__':unittest.main(verbosity=2)
