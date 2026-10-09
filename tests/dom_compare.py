"""Strict structural HTML comparison; mask only known build/platform variation.

Attributes are sorted, HTML whitespace is collapsed, and asset fingerprint
suffixes are normalized (the two upstream builds also use different hashes).
No message content, controls, signed URLs, user or room IDs are masked.
"""
from html.parser import HTMLParser
import re,json,difflib
VOID=set('area base br col embed hr img input link meta param source track wbr'.split())

def norm(s):
 s=re.sub(r'(/assets/[^\s"<>]*?)-[0-9a-f]{8}(?=[.])',r'\1-HASH',s)
 return re.sub(r'\s+',' ',s).strip()

class DOM(HTMLParser):
 def __init__(self,text):
  super().__init__(convert_charrefs=True); self.items=[];self.feed(text)
 def handle_starttag(self,tag,attrs):
  self.items.append(('start',tag,tuple(sorted((k,norm(v or '')) for k,v in attrs))))
 def handle_startendtag(self,tag,attrs):
  self.handle_starttag(tag,attrs)
  if tag not in VOID:self.handle_endtag(tag)
 def handle_endtag(self,tag):
  if tag not in VOID:self.items.append(('end',tag))
 def handle_data(self,s):
  s=norm(s)
  if s:self.items.append(('text',s))

def differences(expected,actual):
 a,b=DOM(expected).items,DOM(actual).items
 return [(kind,a[i:j],b[k:l]) for kind,i,j,k,l in difflib.SequenceMatcher(a=a,b=b,autojunk=False).get_opcodes() if kind!='equal']
if __name__=='__main__':
 import sys
 from pathlib import Path
 root=Path(sys.argv[1]);app=sys.argv[2] if len(sys.argv)>2 else 'mojo'
 for route in ['messages','room','sidebar','search']:
  diff=differences((root/f'rust-{route}.html').read_text(),(root/f'{app}-{route}.html').read_text())
  print(route,len(diff),'differences')
  for d in diff[:15]:print(str(d)[:1800])
