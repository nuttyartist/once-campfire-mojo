#!/usr/bin/env python3
"""Binary and UTF-8 regressions over real HTTP/TCP and masked WebSocket frames."""
import base64, http.client, json, os, socket, struct, unittest, urllib.parse
from pathlib import Path
import full
from full import WS, local


class ByteHTTP(unittest.TestCase):
    setUpClass = classmethod(full.Full.setUpClass.__func__)
    request = full.Full.request
    multipart = full.Full.multipart

    def setUp(self):
        self.before = self.processes()

    def tearDown(self):
        self.assertEqual(self.request('/up')[0], 200)
        self.assertEqual(self.before, self.processes(), 'a worker crashed or restarted')

    def processes(self):
        binary = str(self.runtime/'app/campfire').encode()
        result=set()
        for path in Path('/proc').iterdir():
            if path.name.isdigit():
                try:
                    if binary in (path/'cmdline').read_bytes().split(b'\0'):
                        result.add((path.name, (path/'stat').read_text().split()[21]))
                except (FileNotFoundError,ProcessLookupError,PermissionError):
                    pass
        self.assertTrue(result)
        return result

    def test_invalid_utf8_text_bodies(self):
        path=f'/rooms/{self.rid}/messages'
        for invalid in [b'\xff', b'\xc0\x80', b'\xed\xa0\x80', b'\xf4\x90\x80\x80', b'\xe2\x82']:
            for kind, body in [('application/json',b'{"message":{"body":"'+invalid+b'"}}'),
                               ('application/x-www-form-urlencoded',b'message[body]='+invalid),
                               ('application/x-www-form-urlencoded',('message[body]='+''.join(f'%{b:02X}' for b in invalid)).encode())]:
                with self.subTest(invalid=invalid,kind=kind):
                    self.assertEqual(self.request(path,'POST',body=body,headers={'Content-Type':kind})[0],400)

    def test_bad_multibyte_signature_boundaries(self):
        for length in [40,41,42,64,65,66]:
            wire=urllib.parse.quote('é'+'a'*length,safe='')
            self.assertEqual(self.request('/rooms/'+str(self.rid),cookie='session_token='+wire)[0],302)
            # Latin-1 HTTP representation creates a valid UTF-8 multibyte cookie.
            raw=('é'+'a'*length).encode().decode('latin1')
            self.assertEqual(self.request('/rooms/'+str(self.rid),cookie='session_token='+raw)[0],302)

    def test_chunked_text_split_inside_every_codepoint(self):
        payload=json.dumps({'message':{'body':'bytes café שלום 🔥'}},ensure_ascii=False).encode()
        with socket.create_connection(('127.0.0.1',local.PORT),timeout=5) as sock:
            head=(f'POST /rooms/{self.rid}/messages HTTP/1.1\r\nHost: 127.0.0.1:{local.PORT}\r\nCookie: {self.cookie}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n').encode()
            sock.sendall(head+b''.join(b'1\r\n'+bytes([b])+b'\r\n' for b in payload)+b'0\r\n\r\n')
            response=http.client.HTTPResponse(sock);response.begin()
            self.assertEqual(response.status,200)
            self.assertIn('bytes café שלום 🔥'.encode(),response.read())

    def test_binary_multipart_false_delimiters(self):
        boundary='byte-buffer-regression'
        data=bytes(range(256))*3+b'\r\n--'+boundary.encode()+b'NOT-A-BOUNDARY\r\n\xff\x00'
        head=(f'--{boundary}\r\nContent-Disposition: form-data; name="message[attachment]"; filename="byte.bin"\r\nContent-Type: application/octet-stream\r\n\r\n').encode()
        body=head+data+f'\r\n--{boundary}--\r\n'.encode()
        response=self.request(f'/rooms/{self.rid}/messages','POST',body=body,headers={'Content-Type':f'multipart/form-data; boundary={boundary}'})
        self.assertEqual(response[0],200,response[2])
        with local.connection(self.db) as db:
            key,size=db.execute("SELECT key,byte_size FROM active_storage_blobs WHERE filename='byte.bin' ORDER BY id DESC LIMIT 1").fetchone()
        self.assertEqual(size,len(data))
        self.assertEqual((self.runtime/'files'/key[:2]/key[2:4]/key).read_bytes(),data)

    def test_invalid_multipart_text(self):
        boundary='byte-invalid-text'
        body=(f'--{boundary}\r\nContent-Disposition: form-data; name="message[body]"\r\n\r\n').encode()+b'\xff'+f'\r\n--{boundary}--\r\n'.encode()
        self.assertEqual(self.request(f'/rooms/{self.rid}/messages','POST',body=body,headers={'Content-Type':f'multipart/form-data; boundary={boundary}'})[0],400)

    @staticmethod
    def send_frame(ws, payload, opcode=1, final=True):
        mask=b'\xff\x00\x80\x7f'
        count=len(payload)
        head=bytes([(128 if final else 0)|opcode,128|count]) if count<126 else bytes([(128 if final else 0)|opcode,254])+struct.pack('!H',count)
        ws.s.sendall(head+mask+bytes(b^mask[i%4] for i,b in enumerate(payload)))

    def test_websocket_split_utf8_fragments(self):
        ident=json.dumps({'channel':'HeartbeatChannel','extra':'🔥'},ensure_ascii=False,separators=(',',':'))
        payload=json.dumps({'command':'subscribe','identifier':ident},ensure_ascii=False,separators=(',',':')).encode()
        start=payload.index('🔥'.encode())
        for cut in range(start+1,start+4):
            ws=WS(self.cookie)
            try:
                self.send_frame(ws,payload[:cut],final=False)
                # Control frames may interleave fragments and carry arbitrary bytes.
                ping=bytes(range(125))
                self.send_frame(ws,ping,opcode=9)
                a,b=ws.exact(2)
                self.assertEqual((a,b),(0x8a,125));self.assertEqual(ws.exact(b),ping)
                self.send_frame(ws,payload[cut:],opcode=0)
                confirmation=ws.until(lambda x:x.get('type')=='confirm_subscription')
                self.assertEqual(confirmation['identifier'],ident)
            finally: ws.close()

    def test_websocket_invalid_utf8_closes_with_binary_status(self):
        ws=WS(self.cookie)
        try:
            self.send_frame(ws,b'\xff')
            a,b=ws.exact(2)
            self.assertEqual((a,b),(0x88,2))
            self.assertEqual(ws.exact(b),struct.pack('!H',1002))
        finally:ws.close()


if __name__=='__main__':
    unittest.main(verbosity=2)
