#!/usr/bin/env python3
"""Certificate-verified HTTPS, session flags, WSS authentication and HTTP/2 ALPN."""
import base64,http.client,secrets,socket,ssl,sys,urllib.parse
port=int(sys.argv[1]);ctx=ssl.create_default_context(cafile=sys.argv[2]);origin=f'https://localhost:{port}'
client=http.client.HTTPSConnection('localhost',port,context=ctx)
body=urllib.parse.urlencode({'user[name]':'TLS acceptance','user[email_address]':'tls@example.invalid','user[password]':secrets.token_urlsafe(24)})
client.request('POST','/first_run',body,{'Content-Type':'application/x-www-form-urlencoded','Origin':origin,'Sec-Fetch-Site':'same-origin'})
response=client.getresponse();response.read();assert response.status==303,response.status
cookie=next(v for k,v in response.getheaders() if k.lower()=='set-cookie' and v.startswith('session_token='))
assert all(flag in cookie for flag in ['; Secure','; HttpOnly','SameSite=Lax'])
with ctx.wrap_socket(socket.create_connection(('localhost',port),timeout=10),server_hostname='localhost') as sock:
 key=base64.b64encode(secrets.token_bytes(16)).decode()
 sock.sendall(f'GET /cable HTTP/1.1\r\nHost: localhost:{port}\r\nOrigin: {origin}\r\nCookie: {cookie.split(";",1)[0]}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: actioncable-v1-json\r\n\r\n'.encode())
 data=b''
 while b'\r\n\r\n' not in data:data+=sock.recv(4096)
 assert data.startswith(b'HTTP/1.1 101'),data[:100]
 while b'welcome' not in data:data+=sock.recv(4096)
ctx.set_alpn_protocols(['h2'])
with ctx.wrap_socket(socket.create_connection(('localhost',port),timeout=10),server_hostname='localhost') as sock:
 assert sock.selected_alpn_protocol()=='h2'
client.close()
print('PASS: verified HTTPS, secure session flags, authenticated WSS and HTTP/2 negotiation')
