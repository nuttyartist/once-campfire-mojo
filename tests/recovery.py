#!/usr/bin/env python3
"""Crash the complete owned process group during webhook delivery, then restart it."""
import contextlib,http.server,json,os,re,signal,subprocess,sys,tempfile,threading,time,unittest,urllib.parse
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'bench'))
import local

class Recovery(unittest.TestCase):
 def test_restart_preserves_acknowledged_message_and_resumes_delivery(self):
  calls=[];entered=threading.Event();release=threading.Event()
  class Hook(http.server.BaseHTTPRequestHandler):
   def log_message(self,*args):pass
   def do_POST(self):
    value=json.loads(self.rfile.read(int(self.headers['Content-Length'])));calls.append(value)
    if len(calls)==1:entered.set();release.wait(15)
    try:
     self.send_response(200);self.send_header('Content-Type','text/plain');self.end_headers();self.wfile.write(b'Recovered webhook reply')
    except (BrokenPipeError,ConnectionResetError):pass
  with contextlib.ExitStack() as stack:
   server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Hook)
   stack.callback(server.server_close);stack.callback(server.shutdown);stack.callback(release.set)
   threading.Thread(target=server.serve_forever,daemon=True).start()
   output=Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='mojo-recovery-')))
   db,runtime,_=stack.enter_context(local.server('mojo',output,cache=False))
   labels=json.loads((local.SEED/'labels.json').read_text());cookie=local.login(labels)
   def post(path,fields):return local.request(path,cookie,'POST',urllib.parse.urlencode(fields),{'Content-Type':'application/x-www-form-urlencoded'})
   response=post('/account/bots',{'user[name]':'Recovery bot','user[webhook_url]':f'http://127.0.0.1:{server.server_port}/hook'})
   self.assertEqual(response[0],303,response[2])
   with local.connection(db) as conn:bot=conn.execute("SELECT id FROM users WHERE name='Recovery bot'").fetchone()[0]
   response=post('/rooms/directs',{'user_ids[]':bot});rid=int(response[1]['Location'].rsplit('/',1)[1])
   response=post(f'/rooms/{rid}/messages',{'message[body]':'Acknowledged before crash'})
   self.assertEqual(response[0],200,response[2]);mid=int(re.search(rb'data-message-id="(\d+)"',response[2]).group(1))
   self.assertTrue(entered.wait(5),'webhook never started')
   binary=str(runtime/'app/campfire').encode();candidates=[]
   for item in Path('/proc').iterdir():
    if not item.name.isdigit():continue
    try:
     if binary in (item/'cmdline').read_bytes().split(b'\0'):candidates.append((int(item.name),int((item/'stat').read_text().split()[3])))
    except (FileNotFoundError,ProcessLookupError,PermissionError):pass
   ids={pid for pid,_ in candidates};parent=next(pid for pid,ppid in candidates if ppid not in ids)
   env=dict(x.decode().split('=',1) for x in Path(f'/proc/{parent}/environ').read_bytes().split(b'\0') if x)
   group=os.getpgid(parent);self.assertNotEqual(group,os.getpgrp());os.killpg(group,signal.SIGKILL)
   time.sleep(.2);release.set()
   log=(output/'restarted.log').open('w');stack.callback(log.close)
   proc=subprocess.Popen([str(runtime/'app/campfire')],cwd=runtime/'app',env=env,stdout=log,stderr=log,start_new_session=True)
   def stop():
    if proc.poll() is None:
     os.killpg(proc.pid,signal.SIGTERM)
     try:proc.wait(25)
     except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
   stack.callback(stop)
   deadline=time.monotonic()+10
   while time.monotonic()<deadline:
    self.assertIsNone(proc.poll(),'restarted process exited')
    with local.connection(db) as conn:
     rows=conn.execute('SELECT creator_id,body FROM messages m JOIN message_search_index i ON i.rowid=m.id WHERE room_id=? ORDER BY m.id',(rid,)).fetchall()
     pending=conn.execute('SELECT count(*) FROM mojo_jobs').fetchone()[0]
    if len(rows)==2 and pending==0:break
    time.sleep(.05)
   self.assertEqual(rows,[(labels['users.david'],'Acknowledged before crash'),(bot,'Recovered webhook reply')]);self.assertEqual(pending,0)
   self.assertEqual(len(calls),2);self.assertEqual([x['message']['id'] for x in calls],[mid,mid])
   self.assertEqual(local.request(f'/rooms/{rid}',cookie)[0],200)
   with local.connection(db) as conn:self.assertEqual(conn.execute('PRAGMA integrity_check').fetchone(),('ok',))

if __name__=='__main__':unittest.main(verbosity=2)
