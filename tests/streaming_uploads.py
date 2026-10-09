#!/usr/bin/env python3
"""Bounded-memory multipart uploads, binary framing and direct upload acceptance."""
import base64,contextlib,hashlib,http.client,json,os,re,socket,sys,tempfile,time,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'bench'))
import local
import unittest.mock

class StreamingUploads(unittest.TestCase):
 def test_streaming_multipart_and_direct(self):
  with tempfile.TemporaryDirectory() as out,local.server('mojo',Path(os.environ.get('STREAM_RESULTS',out)),cache=False,verify_log=True) as (db,runtime,_):
   labels=json.loads((local.SEED/'labels.json').read_text());cookie=local.login(labels);room=labels['rooms.watercooler']
   boundary='campfire-stream-boundary'
   # Embedded false boundaries and invalid UTF-8 at transport splits must survive.
   pattern=(b'\x80\xff\0binary\r\n--'+boundary.encode()+b'not-a-delimiter\r\n')*1600
   pattern=pattern[:65536]
   def pieces(size):
    left=size
    while left:
     value=pattern[:min(left,len(pattern))];left-=len(value);yield value
   def digest(size,algorithm):
    h=hashlib.new(algorithm)
    for part in pieces(size):h.update(part)
    return h.digest()
   def maxrss():
    values=[]
    for p in Path('/proc').glob('[0-9]*'):
     try:
      if os.readlink(p/'exe')==str(runtime/'app/campfire'):
       values.append(int(re.search(r'VmHWM:\s+(\d+)',(p/'status').read_text())[1])*1024)
     except (OSError,TypeError):pass
    return sum(values)
   before=maxrss();receipts=[]
   for chunked,size in [(False,128*1024**2+71),(True,512*1024**2+71)]:
    name=f'large-{chunked}.bin'
    head=f'--{boundary}\r\nContent-Disposition: form-data; name="message[attachment]"; filename="{name}"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode()
    tail=f'\r\n--{boundary}--\r\n'.encode()
    def body():
     yield head
     yield from pieces(size)
     yield tail
    headers={'Cookie':cookie,'Content-Type':f'multipart/form-data; boundary={boundary}'}
    if not chunked:headers['Content-Length']=str(len(head)+size+len(tail))
    conn=http.client.HTTPConnection('127.0.0.1',local.PORT,timeout=120)
    conn.request('POST',f'/rooms/{room}/messages',body(),headers,encode_chunked=chunked)
    reply=conn.getresponse();html=reply.read();self.assertEqual(reply.status,200,html[:300]);conn.close()
    expected=base64.b64encode(digest(size,'md5')).decode()
    with local.connection(db) as sql:
     row=sql.execute('SELECT key,byte_size,checksum FROM active_storage_blobs WHERE filename=?',(name,)).fetchone()
     self.assertEqual(row[1:],(size,expected))
    url=re.search(rb'href="(/rails/active_storage/blobs/proxy/[^\"]+)"',html)[1].decode().replace('&amp;','&')
    conn=http.client.HTTPConnection('127.0.0.1',local.PORT,timeout=120);conn.request('GET',url,headers={'Cookie':cookie});reply=conn.getresponse();self.assertEqual(reply.status,200)
    h=hashlib.sha256();length=0
    while part:=reply.read(65536):h.update(part);length+=len(part)
    conn.close();self.assertEqual(length,size);self.assertEqual(h.digest(),digest(size,'sha256'))
    receipts.append({'bytes':size,'chunked':chunked,'checksum_and_download':True})
   growth=maxrss()-before
   self.assertLess(growth,128*1024**2,{'rss_growth':growth})
   # Direct signed uploads also work above the former 64 MiB limit.
   size=80*1024**2+19;expected=base64.b64encode(digest(size,'md5')).decode()
   status,_,raw,_=local.request('/rails/active_storage/direct_uploads',cookie,'POST',json.dumps({'blob':{'filename':'large-direct.bin','content_type':'application/octet-stream','byte_size':size,'checksum':expected}}),{'Content-Type':'application/json'})
   self.assertEqual(status,200,raw);blob=json.loads(raw)
   import urllib.parse
   path=urllib.parse.urlsplit(blob['direct_upload']['url']).path
   conn=http.client.HTTPConnection('127.0.0.1',local.PORT,timeout=120)
   conn.request('PUT',path,pieces(size),{'Cookie':cookie,'Content-Length':str(size),'Content-Type':'application/octet-stream'})
   response=conn.getresponse();self.assertEqual(response.status,204,response.read());conn.close()
   receipts.append({'bytes':size,'direct_upload':True})
   # Reject oversized framing before accepting/spooling its payload.
   conn=http.client.HTTPConnection('127.0.0.1',local.PORT)
   conn.putrequest('POST',f'/rooms/{room}/messages');conn.putheader('Content-Length',str(10*1024**3+1));conn.putheader('Content-Type',f'multipart/form-data; boundary={boundary}');conn.endheaders()
   response=conn.getresponse();self.assertEqual(response.status,413);response.read();conn.close()
   print(json.dumps({'uploads':receipts,'worker_peak_rss_growth_bytes':growth,'oversize_rejected':True}),flush=True)

 def test_exact_limit_chunked_rejection_and_disconnect_cleanup(self):
  with unittest.mock.patch.dict(os.environ,{'MULTIPART_BYTESIZE_LIMIT':'65536'}),tempfile.TemporaryDirectory() as out,local.server('mojo',Path(out),cache=False) as (db,runtime,_):
   labels=json.loads((local.SEED/'labels.json').read_text());cookie=local.login(labels);room=labels['rooms.watercooler']
   head=b'--edge\r\nContent-Disposition: form-data; name="message[attachment]"; filename="edge.bin"\r\n\r\n';tail=b'\r\n--edge--\r\n'
   body=head+b'x'*(65536-len(head)-len(tail))+tail
   headers={'Cookie':cookie,'Content-Type':'multipart/form-data; boundary=edge'}
   conn=http.client.HTTPConnection('127.0.0.1',local.PORT);conn.request('POST',f'/rooms/{room}/messages',body,headers);res=conn.getresponse();self.assertEqual(res.status,200,res.read());conn.close()
   conn=http.client.HTTPConnection('127.0.0.1',local.PORT);conn.request('POST',f'/rooms/{room}/messages',iter([body,b'x']),headers,encode_chunked=True);res=conn.getresponse();self.assertEqual(res.status,413,res.read());conn.close()
   connection=socket.create_connection(('127.0.0.1',local.PORT));connection.sendall(f'POST /rooms/{room}/messages HTTP/1.1\r\nHost: 127.0.0.1:{local.PORT}\r\nContent-Type: multipart/form-data; boundary=edge\r\nContent-Length: 65536\r\n\r\n'.encode()+head+b'aborted');connection.close();time.sleep(.1)
   for p in Path('/proc').glob('[0-9]*'):
    try:
     if os.readlink(p/'exe')==str(runtime/'app/campfire'):
      self.assertFalse(any('campfire-upload-' in os.readlink(fd) for fd in (p/'fd').iterdir()))
    except OSError:pass

if __name__=='__main__':unittest.main(verbosity=2)
