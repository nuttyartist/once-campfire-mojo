#!/usr/bin/env python3
"""Differential gates for the five measured workloads, against live Rust and C.

Generates fresh responses from live databases. Stored response captures are
receipts only and are never input to the Mojo build or application.
"""
import base64,contextlib,hashlib,hmac,json,os,re,sys,tempfile,time,urllib.parse
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'bench'))
import local
from dom_compare import differences, DOM

OUT=Path(os.environ.get('PARITY_RESULTS',str(local.MOJO/'bench/results/parity-gate')))
LABELS=json.loads((local.SEED/'labels.json').read_text())
SCENARIOS={
 'room':f'/rooms/{LABELS["rooms.watercooler"]}',
 'messages':f'/rooms/{LABELS["rooms.watercooler"]}/messages?before={LABELS["messages.busy_060"]}',
 'sidebar':'/users/me/sidebar', 'search':'/searches?q=coffee',
}

def normalized_times(value):
 if isinstance(value,str):
  value=re.sub(time.strftime('%Y-%m-%d',time.gmtime())+r'[ T]\d\d:\d\d:\d\d(?:\.\d+)?Z?', '<WRITE_TIME>',value)
  value=re.sub(r'(?<="|:)17\d{11}(?="|,|})','<EPOCH>',value)
  return value
 if isinstance(value,list):return [normalized_times(v) for v in value]
 if isinstance(value,dict):return {k:normalized_times(v) for k,v in value.items()}
 return value

def drain():
 deadline=time.monotonic()+30
 while True:
  status,_,raw,_=local.request('/_bench/stats')
  assert status==200
  stats=json.loads(raw)
  if stats['queued']==stats['completed']:
   assert stats['errors']==stats['queue_full']==stats['unsupported_deliveries']==0,stats
   return stats
  assert time.monotonic()<deadline,stats
  time.sleep(.02)

def sign_cookie(token, purpose='cookie.session_token',expiry=None):
 key=hashlib.pbkdf2_hmac('sha256',local.fixture_env()['SECRET_KEY_BASE'].encode(),b'signed cookie',1000,64)
 payload={'_rails':{'message':base64.b64encode(json.dumps(token).encode()).decode(),'exp':expiry,'pur':purpose}}
 encoded=base64.b64encode(json.dumps(payload,separators=(',',':')).encode())
 wire=encoded+b'--'+hmac.new(key,encoded,'sha1').hexdigest().encode()
 return 'session_token='+urllib.parse.quote_plus(wire)

def validate_cookie(cookie):
 value=urllib.parse.unquote_plus(cookie.split('session_token=',1)[1].split(';',1)[0])
 encoded,mac=value.rsplit('--',1)
 key=hashlib.pbkdf2_hmac('sha256',local.fixture_env()['SECRET_KEY_BASE'].encode(),b'signed cookie',1000,64)
 assert hmac.compare_digest(mac,hmac.new(key,encoded.encode(),'sha1').hexdigest())
 envelope=json.loads(base64.b64decode(encoded))['_rails']
 assert envelope['pur']=='cookie.session_token'
 token=json.loads(base64.b64decode(envelope['message']))
 assert re.fullmatch('[1-9A-HJ-NP-Za-km-z]{24}',token),token
 return token

def compare_legacy_identity(html, ids, app):
 # Check each live database identity before adapting only the old client-ID DOM
 # convention. Security/optimistic behavior is independently tested in Chromium.
 for item in DOM(html).items:
  if item[0]!='start':continue
  attrs=dict(item[2])
  mid=attrs.get('data-message-id')
  if not mid:continue
  assert mid in ids,(app,'unknown record ID',mid)
  expected='message_'+(mid if app=='mojo' else ids[mid])
  assert attrs.get('id')==expected,(app,'incorrect DOM identity',mid,attrs)
  if app=='mojo':assert attrs.get('data-client-message-id')==ids[mid]
 if app!='mojo':return html
 for mid,cid in ids.items():
  for prefix in ['message_','edit_message_','presentation_message_','boosts_message_','new_boost_message_','boosting_message_']:
   for attribute in ['id','data-turbo-frame','target']:
    html=html.replace(attribute+'="'+prefix+mid+'"',attribute+'="'+prefix+cid+'"')
  html=html.replace('data-client-message-id="'+cid+'"','')
 html=html.replace('data-pending-message="true"','').replace('data-client-message-id="$clientMessageId$"','')
 return html


def capture(app,imported_session=None):
 dest=OUT/app;dest.mkdir(parents=True,exist_ok=True)
 audit=dest/'events.jsonl'
 if audit.exists():audit.unlink()
 if app=='mojo':os.environ['MOJO_AUDIT_PATH']=str(audit)
 else:os.environ.pop('MOJO_AUDIT_PATH',None)
 responses={};state={}
 with local.server(app,dest) as (db,_,_):
  cookie=local.login(LABELS)
  token=validate_cookie(cookie)
  with local.connection(db) as conn:
   row=conn.execute('SELECT * FROM sessions WHERE token=?',(token,)).fetchone()
   fields=[r[1] for r in conn.execute('pragma table_info(sessions)')]
   exported=dict(zip(fields,row))
   exported.pop('id')
  if imported_session:
   session,foreign_cookie=imported_session
   with local.connection(db) as conn:
    conn.execute('INSERT INTO sessions('+','.join(session)+') VALUES('+','.join('?' for _ in session)+')',list(session.values()))
   assert local.request(SCENARIOS['room'],foreign_cookie)[0]==200,(app,'foreign cookie failed')
  for name,path in SCENARIOS.items():
   status,headers,body,wire=local.request(path,cookie)
   assert status==200,(app,name,status,body[:300])
   responses[name]=body.decode()
   (dest/f'{name}.html').write_bytes(body)
  for name in ['room','sidebar','search']:
   status,_,body,_=local.request(SCENARIOS[name],cookie,headers={'Turbo-Frame':'user_sidebar'})
   assert status==200
   responses[name+'_frame']=body.decode()
  # Changes bypass application models to prove invalidation and live rendering.
  with local.connection(db) as conn:
   mid=conn.execute('select id from messages where room_id=? order by created_at desc limit 1',(LABELS['rooms.watercooler'],)).fetchone()[0]
   conn.execute("UPDATE users SET name='David & Friends',bio='Bio <safe>' WHERE id=?",(LABELS['users.david'],))
   conn.execute("UPDATE action_text_rich_texts SET body=? WHERE record_type='Message' AND record_id=?",('<p>Changed coffee &amp; tea <strong>bold</strong> <em>italic</em></p>',mid))
   conn.execute("INSERT INTO boosts(booster_id,content,created_at,message_id,updated_at) VALUES(?,?,'2026-10-01 00:00:00',?,'2026-10-01 00:00:00')",(LABELS['users.david'],'🔥',mid))
  status,_,body,_=local.request(SCENARIOS['room'],cookie)
  assert status==200
  responses['mutated_room']=body.decode()
  (dest/'mutated_room.html').write_bytes(body)
  # Restore creator identity so write payload/side-effect comparisons stay simple.
  with local.connection(db) as conn:conn.execute("UPDATE users SET name='David',bio=NULL WHERE id=?",(LABELS['users.david'],))
  text='Parity coffee & café <strong>bold</strong>'
  body=urllib.parse.urlencode({'message[body]':text,'message[client_message_id]':'mojo-parity-fixed-client'})
  status,headers,html,_=local.request(f'/rooms/{LABELS["rooms.hq"]}/messages',cookie,'POST',body,{'Content-Type':'application/x-www-form-urlencoded','Accept':'text/vnd.turbo-stream.html','Sec-Fetch-Site':'same-origin'})
  assert status==200,(app,status,html)
  assert {k.lower():v for k,v in headers.items()}['content-type'].startswith('text/vnd.turbo-stream.html')
  responses['post']=normalized_times(html.decode())
  if app=='mojo':
   stats=drain()
   assert stats['queued']==stats['completed']==1,stats
   assert stats['notifications']==stats['rejected_endpoints']==3,stats
   with local.connection(db) as conn:members=conn.execute("select count(*) from memberships where room_id=? AND (unread_at IS NOT NULL OR connected_at>datetime('now','-60 seconds'))",(LABELS['rooms.hq'],)).fetchone()[0]
   # The current Rails checkout filters unread recipients and adds timestamps;
   # Rust's pinned older reference sends to every member. Verify current Rails policy.
   assert stats['broadcasts']==1 and stats['unread_broadcasts']==members,stats
   state['jobs']=stats
   for forged in [sign_cookie(token,'cookie.different'),sign_cookie(token,expiry='2000-01-01T00:00:00.000Z'),cookie+'tamper']:
    assert local.request(SCENARIOS['room'],forged)[0]==302
   # Shared-table deletion must revoke an otherwise valid signed cookie on cache hits.
   with local.connection(db) as conn:conn.execute('DELETE FROM sessions WHERE token=?',(token,))
   for _ in range(8):assert local.request(SCENARIOS['room'],cookie)[0]==302
  else:time.sleep(.3)
  with local.connection(db) as conn:
   mid=conn.execute("SELECT id FROM messages WHERE client_message_id='mojo-parity-fixed-client'").fetchone()[0]
   state['database']={table:conn.execute('SELECT * FROM '+table+' WHERE '+clause+' ORDER BY 1',args).fetchall() for table,clause,args in [
    ('messages','id=?',(mid,)),('action_text_rich_texts',"record_id=? AND record_type='Message'",(mid,)),('message_search_index','rowid=?',(mid,)),('memberships','room_id=?',(LABELS['rooms.hq'],))]}
   state['database']=normalized_times(json.loads(json.dumps(state['database'])))
   assert conn.execute('pragma integrity_check').fetchone()==('ok',)
   state['push_subscriptions']=conn.execute('select count(*) from push_subscriptions').fetchone()[0]
  with local.connection(db) as conn:
   identities={str(mid):cid for mid,cid in conn.execute('SELECT id,client_message_id FROM messages')}
  responses={name:compare_legacy_identity(html,identities,app) for name,html in responses.items()}
  local.write_json(dest/'state.json',state)
 return responses,state,(exported,cookie)

def main():
 OUT.mkdir(parents=True,exist_ok=True)
 rust,rs,rust_session=capture('rust')
 mojo,ms,mojo_session=capture('mojo',rust_session)
 c,cs,_=capture('c',mojo_session)
 failures=[]
 upstream_differences=[]
 for app,actual,state in [('mojo',mojo,ms),('c',c,cs)]:
  for name in rust:
   delta=differences(rust[name],actual[name])
   if app=="c" and name in ("sidebar","sidebar_frame") and delta==[("replace",[("text","J, K, and J")],[("text","J+K+J")])]:
    upstream_differences.append({"app":app,"scenario":name,"difference":"C joins the three direct-room initials with +; Rust uses an English sentence."})
   elif delta:failures.append((app,name,delta))
  if state['database']!=rs['database']:failures.append((app,'database',state['database'],rs['database']))
  assert state['push_subscriptions']==rs['push_subscriptions']
 local.write_json(OUT/'comparison.json',{'passed':not failures,'normalization':['HTML whitespace','attribute order','asset fingerprints','write timestamps','verified database ID to legacy client-ID DOM convention; new pending-only attributes'],'failures':failures,'scenarios':list(rust),'mojo_jobs':ms['jobs'],'upstream_differences':upstream_differences})
 if failures:
  for f in failures:print(str(f)[:4000])
  raise AssertionError(f'{len(failures)} parity failures')
 # Verify the notification payload, not just whether a queue counter incremented.
 events=[json.loads(line) for line in (OUT/'mojo/events.jsonl').read_text().splitlines()]
 notifications=[e['value'] for e in events if e['kind']=='notification']
 assert len(notifications)==3
 broadcasts=[e['value'] for e in events if e['kind']=='broadcast']
 stream=base64.urlsafe_b64encode(f'gid://campfire/Rooms::Open/{LABELS["rooms.hq"]}'.encode()).decode().rstrip('=')+':messages'
 append=[e for e in broadcasts if e['stream']==stream]
 assert len(append)==1 and 'mojo-parity-fixed-client' in append[0]['payload']
 assert len(broadcasts)==ms['jobs']['broadcasts']+ms['jobs']['unread_broadcasts']
 assert all(n['payload']['title']=='HQ' and n['payload']['options']['body']=='David: Parity coffee & café bold' for n in notifications)
 assert all(n['payload']['options']['data']['path']==f'/rooms/{LABELS["rooms.hq"]}' for n in notifications)
 print('PASS: nine live DOM scenarios, cross-port signed cookies, database effects, notification payloads, broadcasts, and queue drain')

if __name__=='__main__':main()
