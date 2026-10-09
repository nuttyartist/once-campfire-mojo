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
  cls.db,_,_=cls.stack.enter_context(local.server('mojo',cls.output,cache=False))
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
  res=self.request(url,cookie='');self.assertEqual(res[0],200);self.assertEqual(res[1]['Content-Type'],'image/webp')
  import subprocess
  check=subprocess.run(['ffmpeg','-v','error','-i','pipe:0','-frames:v','1','-f','null','-'],input=res[2],capture_output=True)
  self.assertEqual(check.returncode,0,check.stderr)
 def test_05_direct_room_cannot_be_republished(self):
  res=self.request('/rooms/directs','POST',fields={'user_ids[]':str(self.uid)})
  self.assertEqual(res[0],303);rid=res[1]['Location'].split('/')[-1]
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

if __name__=='__main__':unittest.main(verbosity=2)
