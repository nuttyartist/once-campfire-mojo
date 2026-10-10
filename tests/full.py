#!/usr/bin/env python3
"""Application gates beyond the HTTP benchmark: actual files, roles and Cable."""
import base64,contextlib,hashlib,http.client,json,os,re,socket,sqlite3,struct,sys,tempfile,time,unittest,urllib.parse
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'bench'))
import local

class WS:
 def __init__(self,cookie):
  self.s=socket.create_connection(('127.0.0.1',local.PORT),timeout=5);self.buf=b''
  key=base64.b64encode(os.urandom(16)).decode()
  self.s.sendall((f'GET /cable HTTP/1.1\r\nHost: 127.0.0.1:{local.PORT}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Protocol: actioncable-v1-json\r\nCookie: {cookie}\r\n\r\n').encode())
  while b'\r\n\r\n' not in self.buf:self.buf+=self.s.recv(65536)
  head,self.buf=self.buf.split(b'\r\n\r\n',1)
  assert head.startswith(b'HTTP/1.1 101'),head
  assert base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()) in head
  assert self.read()['type']=='welcome'
 def exact(self,n):
  while len(self.buf)<n:
   b=self.s.recv(65536)
   if not b:raise EOFError()
   self.buf+=b
  a,self.buf=self.buf[:n],self.buf[n:];return a
 def read(self):
  a,b=self.exact(2);n=b&127
  if n==126:n=struct.unpack('!H',self.exact(2))[0]
  if n==127:n=struct.unpack('!Q',self.exact(8))[0]
  data=self.exact(n)
  if a&15==8:return {'type':'closed'}
  return json.loads(data)
 def send(self,obj,fragment=False):
  data=json.dumps(obj,separators=(',',':')).encode()
  chunks=[data[:len(data)//2],data[len(data)//2:]] if fragment else [data]
  for i,chunk in enumerate(chunks):
   op=(1 if i==0 else 0)|(128 if i==len(chunks)-1 else 0)
   n=len(chunk);head=bytes([op,128+n]) if n<126 else bytes([op,254])+struct.pack('!H',n)
   mask=os.urandom(4);self.s.sendall(head+mask+bytes(b^mask[i%4] for i,b in enumerate(chunk)))
 def until(self,predicate):
  for _ in range(100):
   value=self.read()
   if predicate(value):return value
  raise AssertionError('Expected frame missing')
 def close(self):self.s.close()

class Full(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.stack=contextlib.ExitStack();cls.addClassCleanup(cls.stack.close)
  cls.output=Path(cls.stack.enter_context(tempfile.TemporaryDirectory(prefix='mojo-full-')))
  cls.db,cls.runtime,_=cls.stack.enter_context(local.server('mojo',cls.output,cache=False))
  cls.labels=json.loads((local.SEED/'labels.json').read_text());cls.cookie=local.login(cls.labels)
  cls.uid=cls.labels['users.david'];cls.rid=cls.labels['rooms.watercooler']
 def request(self,path,method='GET',fields=None,cookie=None,body=None,headers=None):
  if fields is not None:body=urllib.parse.urlencode(fields,doseq=True)
  h={'Content-Type':'application/x-www-form-urlencoded'} if fields is not None else {}
  return local.request(path,self.cookie if cookie is None else cookie,method=method,body=body or '',headers=h|(headers or {}))
 def multipart(self,path,fields,files,method='POST'):
  boundary='mojo-test-boundary-'+os.urandom(12).hex();body=b''
  for name,value in fields.items():
   body+=f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
  for name,(filename,kind,data) in files.items():
   body+=f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; filename="{filename}"\r\nContent-Type: {kind}\r\n\r\n'.encode()+data+b'\r\n'
  body+=f'--{boundary}--\r\n'.encode()
  return self.request(path,method,body=body,headers={'Content-Type':f'multipart/form-data; boundary={boundary}'})
 def test_01_assets_exist(self):
  importmap=(Path(__file__).resolve().parents[1]/'assets/importmap.html').read_text()
  for path in set(re.findall(r'/assets/[^"< ]+',importmap)):
   self.assertEqual(self.request(path,cookie='')[0],200,path)
  self.assertEqual(self.request('/assets/../../src/app.mojo',cookie='')[0],404)
 def test_02_binary_attachment_roundtrip_and_ranges(self):
  data=bytes(range(256))*23+b'\x00\xff\xfe binary file\n'
  response=self.multipart(f'/rooms/{self.rid}/messages',{'message[body]':'file regression'},{'message[attachment]':('binary.dat','application/octet-stream',data)})
  self.assertEqual(response[0],200,response[2])
  with local.connection(self.db) as db:
   row=db.execute("SELECT b.id,b.key,b.byte_size,b.checksum FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id WHERE a.record_type='Message' ORDER BY a.id DESC LIMIT 1").fetchone()
   self.assertEqual(row[2],len(data));self.assertEqual(row[3],base64.b64encode(hashlib.md5(data).digest()).decode())
  urls=re.findall(rb'href="(/rails/active_storage/blobs/proxy/[^\"]+)"',response[2]);self.assertTrue(urls,response[2])
  url=urls[0].decode().replace('&amp;','&')
  self.assertEqual(self.request(url,cookie='')[2],data)
  part=self.request(url,cookie='',headers={'Range':'bytes=14-53'})
  self.assertEqual(part[0],206);self.assertEqual(part[2],data[14:54])
  self.assertEqual(self.request(url,cookie='',headers={'Range':'bytes=999999-'})[0],416)
  broken=url.replace('/proxy/','/proxy/x',1)
  self.assertEqual(self.request(broken,cookie='')[0],404)
 def test_03_direct_upload_checksum(self):
  data=b'hello\x00\xff direct upload';checksum=base64.b64encode(hashlib.md5(data).digest()).decode()
  blob={'blob':{'filename':'direct.bin','content_type':'application/octet-stream','byte_size':len(data),'checksum':checksum}}
  res=self.request('/rails/active_storage/direct_uploads','POST',body=json.dumps(blob),headers={'Content-Type':'application/json'})
  self.assertEqual(res[0],200,res[2]);payload=json.loads(res[2]);url=urllib.parse.urlsplit(payload['direct_upload']['url']).path
  self.assertEqual(self.request(url,'PUT',cookie='',body=data,headers={'Content-Type':'application/octet-stream'})[0],401)
  self.assertEqual(self.request(url,'PUT',body=b'wrong',headers={'Content-Type':'application/octet-stream'})[0],422)
  self.assertEqual(self.request(url,'PUT',body=data,headers={'Content-Type':'application/octet-stream'})[0],204)
  res=self.request(f'/rooms/{self.rid}/messages','POST',fields={'message[attachment]':payload['signed_id']})
  self.assertEqual(res[0],200,res[2]);self.assertIn(b'direct.bin',res[2])
 def test_04_avatar_real_decode(self):
  image=(local.VERIFICATION/'test/fixtures/avatar.webp').read_bytes()
  res=self.multipart('/users/me/profile',{'_method':'patch'},{'user[avatar]':('avatar.webp','image/webp',image)})
  self.assertEqual(res[0],303,res[2])
  res=self.request('/users/me/sidebar');url=re.findall(rb'src="(/users/[^\"]+/avatar\?[^\"]*)"',res[2])[-1].decode().replace('&amp;','&')
  self.assertEqual(self.request(url,cookie='')[0],302)
  res=self.request(url);self.assertEqual(res[0],200);self.assertEqual(res[1]['Content-Type'],'image/webp')
  import subprocess
  check=subprocess.run(['ffmpeg','-v','error','-i','pipe:0','-frames:v','1','-f','null','-'],input=res[2],capture_output=True)
  self.assertEqual(check.returncode,0,check.stderr)
 def test_05_direct_room_cannot_be_republished(self):
  res=self.request('/rooms/directs','POST',fields={'user_ids[]':str(self.uid)})
  self.assertEqual(res[0],303);rid=res[1]['Location'].split('/')[-1]
  self.assertEqual(self.request('/rooms/directs/'+rid,'PATCH',fields={'user_ids[]':str(self.labels['users.kevin'])})[0],404)
  self.assertEqual(self.request('/rooms/opens/'+rid,'PATCH',fields={'room[name]':'must stay private'})[0],404)
  with local.connection(self.db) as db:self.assertEqual(db.execute('SELECT type FROM rooms WHERE id=?',(rid,)).fetchone()[0],'Rooms::Direct')
 def test_06_cable_fragmentation_delivery_and_revocation(self):
  res=self.request(f'/rooms/{self.rid}')
  signed=re.search(rb'channel="RoomMessagesChannel"[^>]*signed-stream-name="([^\"]+)"',res[2]).group(1).decode()
  a=WS(self.cookie);b=WS(self.cookie);self.addCleanup(a.close);self.addCleanup(b.close)
  ident=json.dumps({'channel':'RoomMessagesChannel','signed_stream_name':signed},separators=(',',':'))
  for ws in [a,b]:
   ws.send({'command':'subscribe','identifier':ident},fragment=True)
   self.assertEqual(ws.until(lambda x:x.get('type') in ('confirm_subscription','reject_subscription'))['type'],'confirm_subscription')
  marker='real fanout '+os.urandom(8).hex()
  self.assertEqual(self.request(f'/rooms/{self.rid}/messages','POST',fields={'message[body]':marker})[0],200)
  for ws in [a,b]:self.assertIn(marker,ws.until(lambda x:'message' in x and marker in str(x['message']))['message'])
  with local.connection(self.db) as db:
   row=db.execute('SELECT * FROM memberships WHERE room_id=? AND user_id=?',(self.rid,self.uid)).fetchone();columns=[r[1] for r in db.execute('PRAGMA table_info(memberships)')]
   db.execute('DELETE FROM memberships WHERE room_id=? AND user_id=?',(self.rid,self.uid))
  try:
   for ws in [a,b]:self.assertEqual(ws.until(lambda x:x.get('type')=='disconnect')['reason'],'unauthorized')
   c=WS(self.cookie);self.addCleanup(c.close);c.send({'command':'subscribe','identifier':ident})
   self.assertEqual(c.until(lambda x:x.get('type') in ('confirm_subscription','reject_subscription'))['type'],'reject_subscription')
  finally:
   with local.connection(self.db) as db:db.execute('INSERT INTO memberships('+','.join(columns)+') VALUES('+','.join('?' for _ in row)+')',row)
 def test_07_cross_site_mutation_rejected(self):
  res=self.request('/users/me/profile','PATCH',fields={'user[name]':'attacker'},headers={'Origin':'https://attacker.invalid'})
  self.assertEqual(res[0],422)
  with local.connection(self.db) as db:self.assertNotEqual(db.execute('SELECT name FROM users WHERE id=?',(self.uid,)).fetchone()[0],'attacker')

 def test_08_mentions_and_sound(self):
  res=self.request('/autocompletable/users.json?query=David',headers={'Accept':'application/json'})
  self.assertEqual(res[0],200,res[2]);user=json.loads(res[2])[0]
  content='<p>Hello <action-text-attachment sgid="'+user['sgid']+'" content-type="application/vnd.campfire.mention">forged label</action-text-attachment></p>'
  res=self.request(f'/rooms/{self.rid}/messages','POST',fields={'message[body]':content})
  self.assertEqual(res[0],200,res[2]);self.assertIn(b'class="mention"',res[2]);self.assertNotIn(b'forged label',res[2])
  with local.connection(self.db) as db:
   text=db.execute('SELECT body FROM message_search_index ORDER BY rowid DESC LIMIT 1').fetchone()[0]
   self.assertIn('@'+user['name'],text)
  res=self.request(f'/rooms/{self.rid}/messages','POST',fields={'message[body]':'/play bell'})
  self.assertEqual(res[0],200,res[2]);self.assertIn(b'data-controller="sound"',res[2]);self.assertIn(b'.mp3',res[2])
 def test_09_real_internal_webhook_and_bot_reply(self):
  from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
  import threading
  received=[]
  class Handler(BaseHTTPRequestHandler):
   def log_message(self,*args):pass
   def do_POST(self):
    received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
    self.send_response(200);self.send_header('Content-Type','text/plain');self.end_headers();self.wfile.write(b'Local webhook replied')
  server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
  thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();self.addCleanup(server.server_close);self.addCleanup(server.shutdown)
  name='Webhook bot '+os.urandom(4).hex()
  res=self.request('/account/bots','POST',fields={'user[name]':name,'user[webhook_url]':f'http://127.0.0.1:{server.server_port}/hook'})
  self.assertEqual(res[0],303,res[2])
  with local.connection(self.db) as db:bid,key=db.execute('SELECT id,bot_token FROM users WHERE name=?',(name,)).fetchone()
  res=self.request('/rooms/directs','POST',fields={'user_ids[]':bid});self.assertEqual(res[0],303,res[2]);rid=res[1]['Location'].split('/')[-1]
  res=self.request(f'/rooms/{rid}/messages','POST',fields={'message[body]':'Hello webhook'})
  self.assertEqual(res[0],200,res[2])
  until=time.monotonic()+10;reply=None
  while time.monotonic()<until:
   with local.connection(self.db) as db:reply=db.execute('SELECT m.creator_id,idx.body FROM messages m JOIN message_search_index idx ON idx.rowid=m.id WHERE m.room_id=? AND m.creator_id=?',(rid,bid)).fetchone()
   if reply:break
   time.sleep(.05)
  self.assertEqual(reply,(bid,'Local webhook replied'));self.assertEqual(len(received),1)
  self.assertEqual(received[0]['message']['body']['plain'],'Hello webhook')
  self.assertEqual(received[0]['room']['path'],f'/rooms/{rid}/{bid}-{key}/messages')
  res=self.request(f'/rooms/{rid}/{bid}-{key}/messages','POST',cookie='',body='Via the existing bot API',headers={'Content-Type':'text/plain'})
  self.assertEqual(res[0],201,res[2])

 def test_10_bot_pagination_boosts_and_attachments(self):
  with local.connection(self.db) as db:
   bot,key=db.execute("SELECT u.id,u.bot_token FROM users u JOIN memberships m ON m.user_id=u.id WHERE m.room_id=? AND u.role=2 AND u.status=0 LIMIT 1",(self.rid,)).fetchone()
   expected=[r[0] for r in db.execute('SELECT id FROM (SELECT id,created_at FROM messages WHERE room_id=? ORDER BY created_at DESC,id DESC LIMIT 40) ORDER BY created_at,id',(self.rid,))]
  path=f'/rooms/{self.rid}/{bot}-{key}/messages'
  res=self.request(path,cookie='');self.assertEqual(res[0],200,res[2]);rows=json.loads(res[2]);self.assertEqual([x['id'] for x in rows],expected)
  self.assertIn('avatar_url',rows[0]['creator']);self.assertIn('role',rows[0]['creator'])
  self.assertEqual(self.request(path+'?before=999999999',cookie='')[0],404)
  res=self.request(path,'POST',cookie='',body='Bot create, edit and delete',headers={'Content-Type':'text/plain'});self.assertEqual(res[0],201,res[2])
  mid=int(res[1]['Location'].split('/')[-1]);one=path+'/'+str(mid)
  res=self.request(one,'PUT',cookie='',body='Updated by bot',headers={'Content-Type':'text/plain'});self.assertEqual(res[0],200,res[2]);self.assertEqual(json.loads(res[2])['body']['plain_text'],'Updated by bot')
  res=self.request(one+'/boosts','POST',cookie='',body='👍'.encode(),headers={'Content-Type':'text/plain'});self.assertEqual(res[0],201,res[2]);boost=json.loads(res[2]);self.assertEqual(boost['booster']['id'],bot)
  self.assertEqual(self.request(one+'/boosts/'+str(boost['id']),'DELETE',cookie='')[0],204)
  self.assertEqual(self.request(one,'DELETE',cookie='')[0],204)
  res=self.multipart(path,{}, {'attachment':('bot.bin','application/octet-stream',b'Bot binary\x00\xff')});self.assertEqual(res[0],201,res[2])
 def test_11_last_room_and_permalink(self):
  res=self.request(f'/rooms/{self.rid}');self.assertIn('last_room=',res[1].get('Set-Cookie',''))
  res=self.request('/',cookie=self.cookie+f'; last_room={self.rid}');self.assertEqual(res[1]['Location'],f'/rooms/{self.rid}')
  with local.connection(self.db) as db:mid=db.execute('SELECT id FROM messages WHERE room_id=? ORDER BY created_at LIMIT 1',(self.rid,)).fetchone()[0]
  res=self.request(f'/rooms/{self.rid}/@{mid}');self.assertEqual(res[0],200,res[2]);self.assertIn(f'data-message-id="{mid}"'.encode(),res[2])
  self.assertEqual(self.request(f'/rooms/{self.rid}/@999999999')[0],200)
 def test_12_unfurl_private_urls_and_unsafe_embeds(self):
  for url in ['http://127.0.0.1/secret','http://[::1]/secret','http://2130706433/secret','http://169.254.169.254/latest/meta-data/','file:///etc/passwd','https://user:pass@127.0.0.1/']:
   res=self.request('/unfurl_link','POST',fields={'url':url});self.assertEqual(res[0],204,(url,res[2]))
  content='<p>Preview <action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" filename="A &lt;b&gt;title&lt;/b&gt;" caption="Description" href="/account/join_code" url="http://2130706433/account/logo"></action-text-attachment></p>'
  res=self.request(f'/rooms/{self.rid}/messages','POST',fields={'message[body]':content})
  self.assertEqual(res[0],200,res[2]);self.assertIn(b'og-embed__title',res[2]);self.assertNotIn(b'href="/account/join_code"',res[2]);self.assertNotIn(b'2130706433',res[2])
 def test_13_http_chunked_and_continue(self):
  body=urllib.parse.urlencode({'message[body]':'Chunked request ✓'}).encode()
  sock=socket.create_connection(('127.0.0.1',local.PORT),timeout=5);self.addCleanup(sock.close)
  headers=f'POST /rooms/{self.rid}/messages HTTP/1.1\r\nHost: 127.0.0.1:{local.PORT}\r\nCookie: {self.cookie}\r\nContent-Type: application/x-www-form-urlencoded\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n'
  sock.sendall(headers.encode());self.assertEqual(sock.recv(4096),b'HTTP/1.1 100 Continue\r\n\r\n')
  for chunk in [body[:9],body[9:]]:sock.sendall(f'{len(chunk):x}\r\n'.encode()+chunk+b'\r\n')
  sock.sendall(b'0\r\n\r\n');response=b''
  while True:
   data=sock.recv(65536)
   if not data:break
   response+=data
  self.assertTrue(response.startswith(b'HTTP/1.1 200'),response[:500]);self.assertIn('Chunked request ✓'.encode(),response)
 def test_14_video_metadata_poster_and_variant_reuse(self):
  import subprocess
  clip=(local.WORKSPACE/'once-campfire/test/fixtures/files/alpha-centuri.mov').read_bytes()
  res=self.multipart(f'/rooms/{self.rid}/messages',{}, {'message[attachment]':('clip.mov','video/quicktime',clip)})
  self.assertEqual(res[0],200,res[2]);poster=re.search(rb'poster="([^\"]+)"',res[2]).group(1).decode().replace('&amp;','&')
  with local.connection(self.db) as db:
   meta=json.loads(db.execute("SELECT metadata FROM active_storage_blobs WHERE filename='clip.mov' ORDER BY id DESC LIMIT 1").fetchone()[0]);self.assertGreater(meta['width'],0);self.assertGreater(meta['height'],0);self.assertTrue(meta['video'])
  first=self.request(poster,cookie='');self.assertEqual(first[0],200,first[2]);self.assertEqual(first[1]['Content-Type'],'image/webp')
  check=subprocess.run(['ffmpeg','-v','error','-i','pipe:0','-frames:v','1','-f','null','-'],input=first[2],capture_output=True);self.assertEqual(check.returncode,0,check.stderr)
  with local.connection(self.db) as db:count=db.execute('SELECT count(*) FROM active_storage_variant_records').fetchone()[0]
  self.assertEqual(self.request(poster,cookie='')[2],first[2])
  with local.connection(self.db) as db:self.assertEqual(db.execute('SELECT count(*) FROM active_storage_variant_records').fetchone()[0],count)
 def test_15_worker_crash_and_durable_jobs(self):
  import signal
  candidates=[]
  for item in Path('/proc').iterdir():
   if item.name.isdigit():
    try:
     executable=Path(os.readlink(item/'exe'))
     if executable==self.runtime/'app/campfire' or str(self.runtime/'app/campfire').encode() in (item/'cmdline').read_bytes().split(b'\0'):
      parent=int((item/'stat').read_text().split()[3]);candidates.append((int(item.name),parent))
    except (OSError,ValueError):pass
  ids={p for p,_ in candidates};root=next(p for p,parent in candidates if parent not in ids)
  child=next(p for p,parent in candidates if parent==root);os.kill(child,signal.SIGKILL)
  deadline=time.monotonic()+5;replaced=False
  while time.monotonic()<deadline:
   kids=Path(f'/proc/{root}/task/{root}/children').read_text().split()
   if len(kids)==7 and str(child) not in kids:replaced=True;break
   time.sleep(.05)
  self.assertTrue(replaced);self.assertEqual(self.request('/up')[0],200)
  with local.connection(self.db) as db:
   mid=db.execute('SELECT id FROM messages WHERE room_id=? ORDER BY id LIMIT 1',(self.rid,)).fetchone()[0]
   db.execute('INSERT INTO mojo_jobs(message_id,hooks) VALUES(?,0)',(mid,));job=db.execute('SELECT last_insert_rowid()').fetchone()[0]
  deadline=time.monotonic()+5;pending=1
  while time.monotonic()<deadline:
   with local.connection(self.db) as db:pending=db.execute('SELECT count(*) FROM mojo_jobs WHERE id=?',(job,)).fetchone()[0]
   if not pending:break
   time.sleep(.05)
  self.assertEqual(pending,0)
 def test_16_conditional_responses_and_authorization(self):
  res=self.request(f'/rooms/{self.rid}');self.assertEqual(res[0],200);tag=res[1]['ETag']
  again=self.request(f'/rooms/{self.rid}',headers={'If-None-Match':tag});self.assertEqual(again[0],304);self.assertEqual(again[2],b'')
  self.assertEqual(self.request(f'/rooms/{self.rid}',cookie='',headers={'If-None-Match':tag})[0],302)
  asset='/assets/'+json.loads((Path(__file__).resolve().parents[1]/'assets/manifest.json').read_text())['add.svg']['digested_path']
  res=self.request(asset,cookie='');self.assertEqual(res[0],200);self.assertEqual(self.request(asset,cookie='',headers={'If-None-Match':res[1]['ETag']})[0],304)
 def test_17_attachment_cleanup_and_if_range(self):
  data=b'Lifecycle file '+os.urandom(50)
  res=self.multipart(f'/rooms/{self.rid}/messages',{}, {'message[attachment]':('cleanup.bin','application/octet-stream',data)})
  self.assertEqual(res[0],200,res[2]);mid=int(re.search(rb'data-message-id="(\d+)"',res[2]).group(1));url=re.search(rb'href="(/rails/active_storage/blobs/proxy/[^\"]+)"',res[2]).group(1).decode()
  with local.connection(self.db) as db:bid,key=db.execute("SELECT b.id,b.key FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id WHERE a.record_type='Message' AND a.record_id=?",(mid,)).fetchone()
  res=self.request(url,cookie='');self.assertEqual(res[2],data);tag=res[1]['ETag']
  self.assertEqual(self.request(url,cookie='',headers={'If-None-Match':tag})[0],304)
  res=self.request(url,cookie='',headers={'Range':'bytes=1-9','If-Range':'"old"'});self.assertEqual(res[0],200);self.assertEqual(res[2],data)
  res=self.request(url,cookie='',headers={'Range':'bytes=1-9','If-Range':tag});self.assertEqual(res[0],206);self.assertNotIn('Content-Encoding',res[1]);self.assertEqual(res[2],data[1:10])
  self.assertEqual(self.request(f'/rooms/{self.rid}/messages/{mid}','DELETE')[0],200)
  with local.connection(self.db) as db:
   self.assertEqual(db.execute('SELECT count(*) FROM messages WHERE id=?',(mid,)).fetchone()[0],0,'message deletion')
   self.assertEqual(db.execute('SELECT count(*) FROM active_storage_attachments WHERE blob_id=?',(bid,)).fetchone()[0],0,'attachment deletion')
  self.assertEqual(self.request(url,cookie='')[0],404)
  with local.connection(self.db) as db:self.assertEqual(db.execute('SELECT count(*) FROM active_storage_blobs WHERE id=?',(bid,)).fetchone()[0],0)
  self.assertFalse((self.runtime/'files'/key[:2]/key[2:4]/key).exists())

 def test_18_ban_revokes_sessions_and_removes_content(self):
  with local.connection(self.db) as db:code=db.execute('SELECT join_code FROM accounts').fetchone()[0];rid=db.execute("SELECT id FROM rooms WHERE type='Rooms::Open' LIMIT 1").fetchone()[0]
  name='Moderation '+os.urandom(5).hex()
  res=self.request('/join/'+code,'POST',cookie='',fields={'user[name]':name,'user[email_address]':name.replace(' ','')+'@test.invalid','user[password]':'test-password'})
  self.assertEqual(res[0],303,res[2]);cookie=res[1]['Set-Cookie'].split(';',1)[0]
  with local.connection(self.db) as db:
   uid=db.execute('SELECT id FROM users WHERE name=?',(name,)).fetchone()[0]
   db.execute("UPDATE sessions SET ip_address='203.0.113.7' WHERE user_id=?",(uid,))
  ws=WS(cookie);self.addCleanup(ws.close)
  res=self.request(f'/rooms/{rid}/messages','POST',cookie=cookie,fields={'message[body]':'Content to remove '+name})
  self.assertEqual(res[0],200,res[2]);mid=int(re.search(rb'data-message-id="(\d+)"',res[2]).group(1))
  self.assertEqual(self.request(f'/users/{uid}/ban','POST',fields={})[0],303)
  self.assertEqual(ws.until(lambda x:x.get('type')=='disconnect')['reason'],'unauthorized')
  self.assertEqual(self.request('/users/me/profile',cookie=cookie)[0],302)
  deadline=time.monotonic()+5
  while time.monotonic()<deadline:
   with local.connection(self.db) as db:count=db.execute('SELECT count(*) FROM messages WHERE creator_id=?',(uid,)).fetchone()[0]
   if count==0:break
   time.sleep(.03)
  self.assertEqual(count,0)
  with local.connection(self.db) as db:
   self.assertEqual(db.execute('SELECT ip_address FROM bans WHERE user_id=?',(uid,)).fetchall(),[('203.0.113.7',)])
   self.assertEqual(db.execute('SELECT count(*) FROM message_search_index WHERE rowid=?',(mid,)).fetchone()[0],0)
   self.assertEqual(db.execute("SELECT count(*) FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",(mid,)).fetchone()[0],0)
  self.assertIn(('Unban '+name).encode(),self.request(f'/users/{uid}')[2])
  self.assertEqual(self.request(f'/users/{uid}/ban','DELETE')[0],303)
  with local.connection(self.db) as db:self.assertEqual(db.execute('SELECT status FROM users WHERE id=?',(uid,)).fetchone()[0],0)
 def test_19_account_controls_and_authorization(self):
  with local.connection(self.db) as db:
   code,settings=db.execute('SELECT join_code,settings FROM accounts').fetchone();member=self.labels['users.kevin']
   oldrole=db.execute('SELECT role FROM users WHERE id=?',(member,)).fetchone()[0]
   db.execute('UPDATE users SET role=0 WHERE id=?',(member,))
   token='disposable-member-'+os.urandom(8).hex()
   db.execute("INSERT INTO sessions(token,user_id,last_active_at,created_at,updated_at) VALUES(?,?,datetime('now'),datetime('now'),datetime('now'))",(token,member))
  # Reuse the independently implemented Rails cookie signer in the parity gate.
  import parity
  cookie=parity.sign_cookie(token)
  try:
   page=self.request('/account/edit',cookie=cookie)
   self.assertEqual(page[0],200);self.assertIn(code.encode(),page[2]);self.assertNotIn(b'Regenerate join link',page[2])
   for path,fields in [('/account',{'account[name]':'Forbidden'}),('/account/bots',{'user[name]':'Forbidden'}),('/account/join_code',{})]:
    self.assertEqual(self.request(path,'PATCH' if path=='/account' else 'POST',cookie=cookie,fields=fields)[0],403,path)
   self.assertEqual(self.request('/account','PATCH',fields={'account[settings][restrict_room_creation_to_administrators]':'1'})[0],303)
   self.assertEqual(self.request('/rooms/opens/new',cookie=cookie)[0],403)
   self.assertEqual(self.request('/rooms/closeds','POST',cookie=cookie,fields={'room[name]':'Forbidden'})[0],403)
   self.assertEqual(self.request('/account/join_code','POST',fields={})[0],303)
   with local.connection(self.db) as db:self.assertNotEqual(db.execute('SELECT join_code FROM accounts').fetchone()[0],code)
   self.assertEqual(self.request('/join/'+code,cookie='')[0],404)
  finally:
   with local.connection(self.db) as db:
    db.execute('UPDATE accounts SET join_code=?,settings=?',(code,settings));db.execute('UPDATE users SET role=? WHERE id=?',(oldrole,member));db.execute('DELETE FROM sessions WHERE token=?',(token,))
 def test_20_account_user_pagination_visibility(self):
  prefix='Page regression '+os.urandom(4).hex()
  with local.connection(self.db) as db:
   db.executemany("INSERT INTO users(name,role,status,created_at,updated_at) VALUES(?,0,?,datetime('now'),datetime('now'))",[(prefix+f' {i:04}',i%3) for i in range(1530)])
  try:
   for page in [1,2,3]:
    res=self.request('/account/users.turbo_stream?page='+str(page));self.assertEqual(res[0],200)
    with local.connection(self.db) as db:expected=[r[0] for r in db.execute('SELECT name FROM users WHERE role=0 AND status IN (0,2) ORDER BY lower(name),id LIMIT 500 OFFSET ?',((page-1)*500,))]
    import html
    actual=[html.unescape(x.decode()) for x in re.findall(rb'<strong>([^<]*)</strong>',res[2])]
    self.assertEqual(actual,expected)
  finally:
   with local.connection(self.db) as db:db.execute('DELETE FROM users WHERE name LIKE ?',(prefix+'%',))

 def test_21_login_return_target_and_tampering(self):
  path=f'/rooms/{self.rid}?via=bookmark'
  res=self.request(path,cookie='');self.assertEqual(res[0],302)
  saved=res[1]['Set-Cookie'].split(';',1)[0]
  with local.connection(self.db) as db:
   limits=db.execute('SELECT * FROM mojo_login_limits').fetchall()
   email=db.execute('SELECT email_address FROM users WHERE id=?',(self.uid,)).fetchone()[0]
  try:
   res=self.request('/session','POST',cookie=saved,fields={'email_address':email,'password':self.labels['passwords.all']})
   self.assertEqual(res[0],302);self.assertEqual(res[1]['Location'],path)
   res=self.request('/session','POST',cookie=saved+'x',fields={'email_address':email,'password':self.labels['passwords.all']})
   self.assertEqual(res[0],302);self.assertNotIn('//',res[1]['Location']);self.assertNotEqual(res[1]['Location'],path)
  finally:
   with local.connection(self.db) as db:
    db.execute('DELETE FROM mojo_login_limits');db.executemany('INSERT INTO mojo_login_limits VALUES(?,?,?)',limits)
 def test_22_async_room_delete_and_attachment_cleanup(self):
  res=self.request('/rooms/opens','POST',fields={'room[name]':'Deletion regression'});self.assertEqual(res[0],303)
  rid=res[1]['Location'].split('/')[-1]
  res=self.multipart(f'/rooms/{rid}/messages',{'message[body]':'Delete room content'}, {'message[attachment]':('cleanup.bin','application/octet-stream',b'room cleanup')});self.assertEqual(res[0],200)
  with local.connection(self.db) as db:
   mid=db.execute('SELECT id FROM messages WHERE room_id=?',(rid,)).fetchone()[0]
   key=db.execute("SELECT b.key FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id WHERE a.record_type='Message' AND a.record_id=?",(mid,)).fetchone()[0]
  res=self.request('/rooms/opens/'+rid,'DELETE');self.assertIn(res[0],[302,303])
  until=time.monotonic()+5
  while time.monotonic()<until:
   with local.connection(self.db) as db:remaining=db.execute('SELECT count(*) FROM rooms WHERE id=?',(rid,)).fetchone()[0]
   if not remaining:break
   time.sleep(.05)
  self.assertEqual(remaining,0)
  with local.connection(self.db) as db:
   for table,column in [('memberships','room_id'),('messages','room_id'),('message_search_index','rowid')]:self.assertEqual(db.execute('SELECT count(*) FROM '+table+' WHERE '+column+'=?',(mid if column=='rowid' else rid,)).fetchone()[0],0)
  self.assertFalse((self.runtime/'files'/key[:2]/key[2:4]/key).exists())
 def test_23_richtext_editor_and_malformed_stored_message(self):
  import html
  user=json.loads(self.request('/autocompletable/users.json?query=David',headers={'Accept':'application/json'})[2])[0]
  body='<p>Editing <action-text-attachment sgid="'+user['sgid']+'" content-type="text/html" content="&lt;img src=x onerror=alert(1)&gt;"></action-text-attachment></p>'
  res=self.request(f'/rooms/{self.rid}/messages','POST',fields={'message[body]':body});self.assertEqual(res[0],200,res[2])
  with local.connection(self.db) as db:mid=db.execute('SELECT max(id) FROM messages').fetchone()[0]
  edit=self.request(f'/rooms/{self.rid}/messages/{mid}/edit');self.assertEqual(edit[0],200)
  value=html.unescape(re.search(rb'<lexxy-editor[^>]+value="([^"]*)"',edit[2]).group(1).decode())
  self.assertIn('application/vnd.campfire.mention',value);self.assertNotIn('onerror',value);self.assertIn(user['name'],value)
  for broken in ['<b>'*450+'bad'+'</b>'*450,'<p><action-text-attachment></action-text-attachment></p>']:
   with local.connection(self.db) as db:db.execute("UPDATE action_text_rich_texts SET body=? WHERE record_type='Message' AND record_id=?",(broken,mid))
   self.assertEqual(self.request(f'/rooms/{self.rid}')[0],200)
  # Repair the fixture so later background work never encounters corrupt input.
  with local.connection(self.db) as db:db.execute("UPDATE action_text_rich_texts SET body=? WHERE record_type='Message' AND record_id=?",('Repaired editor test',mid))
 def test_24_multiple_byte_ranges_and_redirects(self):
  from email.parser import BytesParser
  from email.policy import default
  data=bytes(range(256))*2
  res=self.multipart(f'/rooms/{self.rid}/messages',{}, {'message[attachment]':('ranges.bin','application/octet-stream',data)});self.assertEqual(res[0],200)
  url=re.findall(rb'href="(/rails/active_storage/blobs/proxy/[^"]+)"',res[2])[0].decode().replace('&amp;','&')
  res=self.request(url,cookie='',headers={'Range':'bytes=0-5,20-23,-3'});self.assertEqual(res[0],206)
  message=BytesParser(policy=default).parsebytes(('Content-Type: '+res[1]['Content-Type']+'\r\n\r\n').encode()+res[2])
  self.assertEqual([p.get_payload(decode=True) for p in message.iter_parts()],[data[:6],data[20:24],data[-3:]])
  self.assertEqual(self.request(url,cookie='',headers={'Range':'bytes=abc-def'})[0],416)
  redir=self.request(url.replace('/proxy/','/redirect/'),cookie='');self.assertEqual(redir[0],302)
  location=redir[1]['Location'];self.assertIn('/rails/active_storage/disk/',location)
  parsed=urllib.parse.urlsplit(location)
  self.assertEqual(self.request(parsed.path+('?' + parsed.query if parsed.query else ''),cookie='')[2],data)
 def test_25_webhook_failure_isolated_and_retried(self):
  from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
  import threading
  hits={'bad':0,'good':0}
  class Handler(BaseHTTPRequestHandler):
   def log_message(self,*args):pass
   def do_POST(self):
    self.rfile.read(int(self.headers['Content-Length']));name=self.path[1:];hits[name]+=1
    code=503 if name=='bad' and hits[name]==1 else 200
    self.send_response(code);self.send_header('Content-Type','text/plain');self.end_headers()
    if code==200:self.wfile.write((name+' isolated reply').encode())
  server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start();self.addCleanup(server.server_close);self.addCleanup(server.shutdown)
  ids=[]
  for kind in ['bad','good']:
   name='Retry '+kind+' '+os.urandom(4).hex()
   self.assertEqual(self.request('/account/bots','POST',fields={'user[name]':name,'user[webhook_url]':f'http://127.0.0.1:{server.server_port}/{kind}'})[0],303)
   with local.connection(self.db) as db:ids.append(db.execute('SELECT id FROM users WHERE name=?',(name,)).fetchone()[0])
  rid=self.request('/rooms/directs','POST',fields={'user_ids[]':ids})[1]['Location'].split('/')[-1]
  self.assertEqual(self.request(f'/rooms/{rid}/messages','POST',fields={'message[body]':'Delivery isolation'})[0],200)
  until=time.monotonic()+3
  while time.monotonic()<until and not hits['good']:time.sleep(.03)
  self.assertEqual(hits['good'],1);self.assertEqual(hits['bad'],1)
  with local.connection(self.db) as db:db.execute("UPDATE mojo_jobs SET available_at=0 WHERE attempts>0 AND failed=0")
  until=time.monotonic()+8;replies=[]
  while time.monotonic()<until:
   with local.connection(self.db) as db:replies=db.execute('SELECT m.creator_id,i.body FROM messages m JOIN message_search_index i ON i.rowid=m.id WHERE m.room_id=? AND m.creator_id IN (?,?)',(rid,*ids)).fetchall()
   if len(replies)==2:break
   time.sleep(.03)
  self.assertEqual(set(replies),{(ids[0],'bad isolated reply'),(ids[1],'good isolated reply')});self.assertEqual(hits,{'bad':2,'good':1})

 def test_26_large_file_streaming_head_ranges_and_keepalive(self):
  size=160*1024*1024;tail=b'end of large imported file'
  res=self.multipart(f'/rooms/{self.rid}/messages',{}, {'message[attachment]':('large.bin','application/octet-stream',b'initial')});self.assertEqual(res[0],200)
  url=re.findall(rb'href="(/rails/active_storage/blobs/proxy/[^\"]+)"',res[2])[0].decode().replace('&amp;','&')
  with local.connection(self.db) as db:bid,key=db.execute("SELECT b.id,b.key FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id WHERE a.record_type='Message' ORDER BY a.id DESC LIMIT 1").fetchone()
  path=self.runtime/'files'/key[:2]/key[2:4]/key
  with path.open('wb') as file:file.seek(size-len(tail));file.write(tail)
  with path.open('rb') as file:digest=hashlib.file_digest(file,'md5').digest()
  with local.connection(self.db) as db:db.execute('UPDATE active_storage_blobs SET byte_size=?,checksum=? WHERE id=?',(size,base64.b64encode(digest).decode(),bid))
  head=self.request(url,'HEAD',cookie='');self.assertEqual(head[0],200);self.assertEqual(int(head[1]['Content-Length']),size);self.assertEqual(head[2],b'')
  self.assertEqual(self.request(url,cookie='',headers={'Range':f'bytes=-{len(tail)}'})[2],tail)
  conn=http.client.HTTPConnection('127.0.0.1',local.PORT,timeout=15);self.addCleanup(conn.close)
  conn.request('GET',url);response=conn.getresponse();self.assertEqual(response.status,200)
  actual=hashlib.md5();received=0
  while chunk:=response.read(65536):actual.update(chunk);received+=len(chunk)
  self.assertEqual(received,size);self.assertEqual(actual.digest(),digest)
  conn.request('GET','/up');response=conn.getresponse();self.assertEqual(response.status,200);response.read()

 def test_27_media_previews_lightbox_and_safe_fallback(self):
  import subprocess
  fixtures=local.WORKSPACE/'once-campfire/test/fixtures/files'
  for name,kind in [('moon.jpg','image/jpeg'),('earth.png','image/png'),('pixel.bmp','image/bmp')]:
   raw=(fixtures/name).read_bytes()
   res=self.multipart(f'/rooms/{self.rid}/messages',{}, {'message[attachment]':(name,kind,raw)});self.assertEqual(res[0],200,res[2])
   if name.endswith('.bmp'):
    self.assertNotIn(b'data-lightbox-target',res[2]);self.assertIn(b'Download pixel.bmp',res[2]);continue
   self.assertIn(b'data-action="lightbox#open"',res[2]);self.assertIn(b'data-lightbox-url-value=',res[2])
   preview=re.search(rb'src="(/rails/active_storage/representations/[^\"]+)"',res[2]).group(1).decode().replace('&amp;','&')
   response=self.request(preview,cookie='');self.assertEqual(response[0],200)
   decode=subprocess.run(['ffmpeg','-v','error','-i','pipe:0','-f','null','-'],input=response[2],capture_output=True);self.assertEqual(decode.returncode,0,decode.stderr)
  objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R >>',b'<< /Length 22 >>\nstream\n0 0 1 rg 0 0 150 100 re f\nendstream']
  # Generate a small independent PDF fixture with a real xref table.
  stream=b'0 0 1 rg 0 0 150 100 re f\n';objects[-1]=b'<< /Length '+str(len(stream)).encode()+b' >>\nstream\n'+stream+b'endstream'
  pdf=b'%PDF-1.4\n';offsets=[]
  for i,obj in enumerate(objects,1):offsets.append(len(pdf));pdf+=f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n'
  xref=len(pdf);pdf+=b'xref\n0 5\n0000000000 65535 f \n'+b''.join(f'{offset:010} 00000 n \n'.encode() for offset in offsets)+f'trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
  res=self.multipart(f'/rooms/{self.rid}/messages',{}, {'message[attachment]':('preview.pdf','application/pdf',pdf)});self.assertEqual(res[0],200,res[2]);self.assertIn(b'data-lightbox-target',res[2])
  url=re.search(rb'src="(/rails/active_storage/representations/[^\"]+)"',res[2]).group(1).decode().replace('&amp;','&')
  preview=self.request(url,cookie='');self.assertEqual(preview[0],200);self.assertTrue(preview[2].startswith(b'\x89PNG'))
  broken=self.multipart(f'/rooms/{self.rid}/messages',{}, {'message[attachment]':('broken.png','image/png',b'\x89PNG\r\n\x1a\ncorrupt')});self.assertEqual(broken[0],200)
  self.assertNotIn(b'data-lightbox-target',broken[2]);self.assertIn(b'Download broken.png',broken[2])

 def test_28_current_user_aliases_and_method_guards(self):
  target=self.labels['users.kevin']
  for suffix in ['profile','sidebar','push_subscriptions']:
   self.assertEqual(self.request(f'/users/{target}/{suffix}')[0],200,suffix)
  marker='Current user route alias'
  self.assertEqual(self.request(f'/users/{target}/profile','PATCH',fields={'user[bio]':marker})[0],303)
  with local.connection(self.db) as db:
   self.assertEqual(db.execute('SELECT bio FROM users WHERE id=?',(self.uid,)).fetchone()[0],marker)
   self.assertNotEqual(db.execute('SELECT bio FROM users WHERE id=?',(target,)).fetchone()[0],marker)
  for path in [f'/rooms/{self.rid}/refresh',f'/rooms/{self.rid}/settings',f'/rooms/{self.rid}/involvement','/users/me/push_subscriptions','/autocompletable/users',f'/users/{target}']:
   self.assertEqual(self.request(path,'DELETE')[0],404,path)
 def test_29_missing_creator_history_remains_visible(self):
  with local.connection(self.db) as db:
   row=db.execute('SELECT id,room_id FROM messages WHERE creator_id NOT IN (SELECT id FROM users) LIMIT 1').fetchone()
   self.assertIsNotNone(row)
  res=self.request(f'/rooms/{row[1]}/messages/{row[0]}')
  self.assertEqual(res[0],200,res[2]);self.assertIn(b'Failed to load message content',res[2])

 def test_30_signed_attachment_update_and_unicode_filename(self):
  first=self.request(f'/rooms/{self.rid}/messages','POST',fields={'message[body]':'keep this body'})
  self.assertEqual(first[0],200)
  with local.connection(self.db) as db:mid=db.execute('SELECT id FROM messages ORDER BY id DESC LIMIT 1').fetchone()[0]
  data=b'updated file bytes';name='Résumé שלום.txt'
  blob={'blob':{'filename':name,'content_type':'text/plain','byte_size':len(data),'checksum':base64.b64encode(hashlib.md5(data).digest()).decode()}}
  created=self.request('/rails/active_storage/direct_uploads','POST',body=json.dumps(blob),headers={'Content-Type':'application/json'})
  self.assertEqual(created[0],200);blob=json.loads(created[2]);url=urllib.parse.urlsplit(blob['direct_upload']['url']).path
  self.assertEqual(self.request(url,'PUT',body=data,headers={'Content-Type':'text/plain'})[0],204)
  updated=self.request(f'/rooms/{self.rid}/messages/{mid}','PATCH',fields={'message[attachment]':blob['signed_id']},headers={'Accept':'application/json'})
  self.assertEqual(updated[0],200,updated[2]);self.assertIn('keep this body',json.loads(updated[2])['body']['plain_text'])
  page=self.request(f'/rooms/{self.rid}/messages/{mid}')
  url=re.search(rb'href="(/rails/active_storage/blobs/proxy/[^"]+)"',page[2]).group(1).decode().replace('&amp;','&')
  downloaded=self.request(url,cookie='');self.assertEqual(downloaded[2],data)
  disposition=downloaded[1]['Content-Disposition'];self.assertTrue(disposition.startswith('attachment;'))
  self.assertIn("filename*=UTF-8''"+urllib.parse.quote(name),disposition)
 def test_31_seek_required_mp4_poster(self):
  import subprocess
  path=self.output/'seek-required.mp4'
  subprocess.run(['ffmpeg','-v','error','-threads','2','-f','lavfi','-i','testsrc2=size=320x240:rate=24','-t','3','-an','-c:v','mpeg4','-q:v','2','-y',str(path)],check=True)
  data=path.read_bytes();self.assertGreater(data.index(b'moov'),data.index(b'mdat'))
  response=self.multipart(f'/rooms/{self.rid}/messages',{'message[body]':'seekable MP4'},{'message[attachment]':('ordinary.mp4','video/mp4',data)})
  self.assertEqual(response[0],200,response[2]);self.assertIn(b'<video',response[2]);self.assertIn(b'poster=',response[2])
  with local.connection(self.db) as db:
   row=db.execute("SELECT b.metadata FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id WHERE a.record_type='Message' AND b.filename='ordinary.mp4' ORDER BY a.id DESC LIMIT 1").fetchone()
   self.assertEqual(json.loads(row[0])['width'],320)

 def test_99_login_limit_shared_across_workers(self):
  statuses=[self.request('/session','POST',cookie='',fields={'email_address':'nobody@invalid.test','password':'incorrect'})[0] for _ in range(12)]
  self.assertEqual(statuses[:9],[401]*9);self.assertEqual(statuses[9:],[429]*3)

if __name__=='__main__':unittest.main(verbosity=2)
