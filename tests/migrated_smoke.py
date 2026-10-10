#!/usr/bin/env python3
"""Live acceptance after an actual Disk import/restore into the production image."""
import gzip,http.client,json,re,sys,time,urllib.parse
from pathlib import Path
base=urllib.parse.urlsplit(sys.argv[1]);seed=Path(sys.argv[2]);labels=json.loads((seed/'labels.json').read_text())
def request(path,method='GET',body=None,cookie=''):
 c=http.client.HTTPConnection(base.hostname,base.port,timeout=20)
 try:
  c.request(method,path,body,{'Cookie':cookie,'Sec-Fetch-Site':'same-origin','Content-Type':'application/x-www-form-urlencoded'})
  r=c.getresponse();data=r.read();return r.status,r.getheaders(),data
 finally:c.close()
for i in range(120):
 try:
  if request('/up')[0]==200:break
 except OSError:pass
 time.sleep(.25)
else:raise AssertionError('Imported server did not start')
status,headers,body=request('/session','POST',urllib.parse.urlencode({'email_address':labels['emails.david'],'password':labels['passwords.all']}))
assert status==302,status
cookie='; '.join(v.split(';')[0] for k,v in headers if k.lower()=='set-cookie')
for path,needle in [(f'/rooms/{labels["rooms.watercooler"]}',b'message-area'),('/searches?q=coffee',b'coffee'),('/users/me/profile',labels['emails.david'].encode())]:
 status,_,body=request(path,cookie=cookie);assert status==200,(path,status);assert needle in body,(path,needle)
status,_,html=request(f'/rooms/{labels["rooms.watercooler"]}',cookie=cookie)
paths=re.findall(rb'src="(/users/[^" ]+/avatar[^" ]*)"',html)
assert paths
status,headers,data=request(paths[0].decode().replace('&amp;','&'),cookie=cookie)
assert status==200 and data,(status,len(data))
print('PASS: packaged imported/restored database, existing bcrypt credentials, history, search, profile and avatar')
