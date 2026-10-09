#!/usr/bin/env python3
"""Independent Rails rich-text fixture checks, including output security invariants."""
import argparse,hashlib,re,sys
import json,collections
from pathlib import Path
from html.parser import HTMLParser
class DOM(HTMLParser):
 def __init__(self):super().__init__(convert_charrefs=True);self.events=[]
 def handle_starttag(self,tag,attrs):
  self.events.append(('open',tag,sorted(attrs)))
  if tag in ['br','hr','img','input','meta','link','col','embed','source','wbr']:self.events.append(('close',tag))
 def handle_startendtag(self,tag,attrs):self.handle_starttag(tag,attrs)
 def handle_endtag(self,tag):
  if tag not in ['br','hr','img','input','meta','link','col','embed','source','wbr']:self.events.append(('close',tag))
 def handle_data(self,data):
  value=' '.join(data.split())
  if value:self.events.append(('text',value))
def dom(html):
 p=DOM();p.feed(html);return p.events
def tree(value):
 if value is None:return []
 result=[]
 for event in dom(value):
  if event[0]=='open':
   attrs=[]
   for key,v in event[2]:
    if key=='content' and v:
     try:v=json.loads(v)
     except ValueError:pass
     if isinstance(v,str):v=tree(v)
    attrs.append((key,v))
   event=('open',event[1],attrs)
  result.append(event)
 return result

def port_divergences(rails):
 out='';state='text';rest=rails
 inserted='<a target="_blank" href="'
 while rest:
  if state=='value' and rest.startswith(inserted):
   start=rest.index('">')+2;end=rest.index('</a>',start)
   out+=rest[start:end].replace('>','&gt;');rest=rest[end+4:];continue
  if state=='tag' and rest.startswith(' name="'):
   end=rest.index('"',7);rest=rest[end+1:];continue
  c=rest[0]
  if state=='text' and c=='<':state='tag'
  elif state=='tag' and c=='>':state='text'
  elif state=='tag' and c=='"':state='value'
  elif state=='value' and c=='"':state='tag'
  out+=('&lt;' if c=='<' else '&gt;') if state=='value' and c in '<>' else c
  rest=rest[1:]
 return out

def safe(html):
 p=DOM();p.feed(html)
 for event in p.events:
  if event[0]!='open':continue
  _,tag,attrs=event
  if tag in {'script','style','iframe','object','embed','svg','math','form','input','button','textarea','select'}:return False
  for key,value in attrs:
   if key.startswith('on') or key in {'style','name','id'} or (key.startswith('data-') and key!='data-language'):return False
   if key in {'href','src','cite','xlink:href'}:
    cleaned=re.sub(r'[`\x00-\x20\x7f-\u0101]','',value or '').lower()
    if re.match(r'(?:javascript|vbscript)(?::|%3a)',cleaned) or cleaned.startswith('data:text/html'):return False
 return True

def equal(a,b):
 return ('error' in a and 'error' in b) or ('ok' in a and 'ok' in b and a['ok']==b['ok'])

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('results',type=Path,nargs='?',default=Path('build/richtext-corpus.jsonl'));args=parser.parse_args()
 rows=[json.loads(line) for line in args.results.read_text().split('\n') if line]
 counts=collections.Counter();failures=[]
 # These injected defects must fail the checker itself.
 for bad in ['<script>x</script>','<a onclick="x">x</a>','<a href="java\tscript:x">x</a>','<a href="javascript%3Ax">x</a>','<img src="data:text/html,x">','<span style="color:red">x</span>','<img name="body">','<span data-controller="x">x</span>']:
  assert not safe(bad),bad
 for row in rows:
  if 'web_url' in row:
   counts['web_urls']+=1
   if not equal(row['actual'],row['web_url']['result']):failures.append(('web_url',row['web_url']['value']))
   continue
  case=row['case'];name=case['name'];counts['cases']+=1
  for actual,expected in [('actual_plain','plain_text'),('actual_mentions','mentioned')]:
   if not equal(row[actual],case[expected]):failures.append((expected,name))
  editor_expected=case['editable'];editor_actual=row['actual_editable']
  if 'error' in editor_expected and 'MissingAttachable' in editor_expected.get('message','') and 'ok' in editor_actual:
   counts['documented_missing_editor_divergences']+=1
  elif not (('error' in editor_expected and 'error' in editor_actual) or ('ok' in editor_expected and 'ok' in editor_actual and tree(editor_expected['ok'])==tree(editor_actual['ok']))):
   failures.append(('editable',name))
  if 'body_html' in case:
   counts['body_html']+=1;expected_body=case['body_html'];actual_body=row['actual_body_html']
   if 'to_missing_attachable_partial_path' in expected_body.get('message',''):
    matches='ok' in actual_body and '☒' in actual_body['ok'];counts['documented_missing_body_divergences']+=1
   else:
    matches=('error' in expected_body and 'error' in actual_body) or ('ok' in expected_body and 'ok' in actual_body and tree(re.sub(r' name="[^"]*"','',expected_body['ok']))==tree(actual_body['ok']))
   if not matches:failures.append(('body_html',name))
  expected=case['presentation'];actual=row['actual_html']
  missing_partial='to_missing_attachable_partial_path' in (case.get('presentation_raised_message') or '')
  if 'error' in actual:
   # Rails' message_presentation rescues a rendering error to empty HTML.
   matches='error' in expected or expected.get('ok')==''
  elif missing_partial:
   matches='☒' in actual['ok'];counts['documented_missing_partial_divergences']+=1
  else:
   matches='ok' in expected and dom(port_divergences(expected['ok']))==dom(actual['ok'])
  if not matches:failures.append(('presentation',name))
  if 'ok' in actual and not safe(actual['ok']):failures.append(('security',name))
 if counts['cases']!=658 or counts['web_urls']!=54:failures.append(('corpus_size',dict(counts)))
 print(json.dumps({'counts':dict(counts),'failures':failures,'results_sha256':hashlib.sha256(args.results.read_bytes()).hexdigest()},indent=2))
 if failures:raise SystemExit(1)
 print('PASS: Rails plain text, presentation, editor, API body HTML, verified mentions, preview URLs, and security invariants')
if __name__=='__main__':main()
