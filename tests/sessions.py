#!/usr/bin/env python3
"""Rails session migration over HTTP, with independent OpenSSL cookie encoding."""
import base64,ctypes,ctypes.util,datetime,hashlib,json,os,unittest,urllib.parse
import full
import http.client,gzip
from full import local

def cipher(value, nonce, tag=None):
    lib=ctypes.CDLL(ctypes.util.find_library('crypto'));ptr=ctypes.c_void_p;integer=ctypes.c_int
    decrypt=tag is not None;mode='Decrypt' if decrypt else 'Encrypt'
    signatures=[('EVP_CIPHER_CTX_new',[],ptr),('EVP_aes_256_gcm',[],ptr),('EVP_CIPHER_CTX_free',[ptr],None),('EVP_CIPHER_CTX_ctrl',[ptr,integer,integer,ptr],integer),
      ('EVP_'+mode+'Init_ex',[ptr,ptr,ptr,ptr,ptr],integer),('EVP_'+mode+'Update',[ptr,ptr,ctypes.POINTER(integer),ptr,integer],integer),('EVP_'+mode+'Final_ex',[ptr,ptr,ctypes.POINTER(integer)],integer)]
    for name,args,result in signatures:
        f=getattr(lib,name);f.argtypes=args;f.restype=result
    key=hashlib.pbkdf2_hmac('sha256',local.fixture_env()['SECRET_KEY_BASE'].encode(),b'authenticated encrypted cookie',1000,32)
    ctx=lib.EVP_CIPHER_CTX_new();out=ctypes.create_string_buffer(len(value)+16);n=integer();end=integer();auth=ctypes.create_string_buffer(tag or bytes(16),16)
    try:
        assert getattr(lib,'EVP_'+mode+'Init_ex')(ctx,lib.EVP_aes_256_gcm(),None,key,nonce)==1
        assert getattr(lib,'EVP_'+mode+'Update')(ctx,out,ctypes.byref(n),value,len(value))==1
        if decrypt:assert lib.EVP_CIPHER_CTX_ctrl(ctx,0x11,16,auth)==1
        assert getattr(lib,'EVP_'+mode+'Final_ex')(ctx,ctypes.byref(out,n.value),ctypes.byref(end))==1
        if not decrypt:assert lib.EVP_CIPHER_CTX_ctrl(ctx,0x10,16,auth)==1
        return out.raw[:n.value+end.value],auth.raw
    finally:lib.EVP_CIPHER_CTX_free(ctx)

def encode(data,purpose='cookie._campfire_session',expiry='2046-01-01T00:00:00.000Z'):
    meta={'_rails':{'message':base64.b64encode(json.dumps(data).encode()).decode(),'exp':expiry,'pur':purpose}}
    nonce=os.urandom(12);body,tag=cipher(json.dumps(meta).encode(),nonce)
    return '_campfire_session='+urllib.parse.quote_plus('--'.join(base64.b64encode(v).decode() for v in [body,nonce,tag]))

def decode(cookie):
    value=urllib.parse.unquote_plus(cookie.split('=',1)[1].split(';')[0])
    body,nonce,tag=[base64.b64decode(p) for p in value.split('--')]
    raw,_=cipher(body,nonce,tag);meta=json.loads(raw)['_rails'];assert meta['pur']=='cookie._campfire_session'
    return json.loads(base64.b64decode(meta['message']))

class Sessions(unittest.TestCase):
    setUpClass=classmethod(full.Full.setUpClass.__func__)
    def request(self,path,method='GET',fields=None,cookie=None):
        conn=http.client.HTTPConnection('127.0.0.1',local.PORT)
        try:
            body=urllib.parse.urlencode(fields) if fields is not None else None
            conn.request(method,path,body,{'Cookie':self.cookie if cookie is None else cookie,'Content-Type':'application/x-www-form-urlencoded','Sec-Fetch-Site':'same-origin'})
            response=conn.getresponse();headers=response.getheaders();data=response.read()
            return response.status,dict(headers),data,headers
        finally:conn.close()
    def test_rails_return_cookie_is_consumed_and_other_state_preserved(self):
        fields={'email_address':self.labels['emails.david'],'password':self.labels['passwords.all']}
        target=f'/rooms/{self.rid}?source=migration'
        cookie=encode({'session_id':'independent-Rails-session','return_to_after_authenticating':local.BASE+target,'retained':'yes'})
        response=self.request('/session','POST',fields,cookie)
        self.assertEqual(response[0],302);self.assertEqual(response[1]['Location'],target)
        new_cookie=next(value for key,value in response[3] if key.lower()=='set-cookie' and value.startswith('_campfire_session='))
        state=decode(new_cookie);self.assertEqual(state['retained'],'yes');self.assertNotIn('return_to_after_authenticating',state)
        for bad in [encode({'return_to_after_authenticating':'https://evil.test/'}),encode({'return_to_after_authenticating':target},purpose='cookie.other'),encode({'return_to_after_authenticating':target},expiry='2000-01-01T00:00:00.000Z'),cookie+'tamper']:
            self.assertEqual(self.request('/session','POST',fields,bad)[1]['Location'],'/')
    def test_flash_escapes_displays_once_and_does_not_leak_through_cache(self):
        cookie='; '.join(x for x in self.cookie.split(';') if not x.strip().startswith('_campfire_session='))+'; '+encode({'session_id':'flash','flash':{'discard':[],'flashes':{'notice':'Migrated <script>unsafe</script>'}},'retained':'yes'})
        response=self.request(f'/rooms/{self.rid}',cookie=cookie)
        self.assertEqual(response[0],200);self.assertTrue(b'Migrated &lt;script&gt;unsafe&lt;/script&gt;' in response[2],'Escaped flash was not rendered');self.assertNotIn(b'<script>unsafe',response[2])
        changed=next(value for key,value in response[3] if key.lower()=='set-cookie' and value.startswith('_campfire_session='))
        self.assertNotIn('flash',decode(changed));self.assertEqual(decode(changed)['retained'],'yes')
        after=self.request(f'/rooms/{self.rid}',cookie='; '.join(x for x in self.cookie.split(';') if not x.strip().startswith('_campfire_session='))+'; '+changed.split(';')[0])
        self.assertNotIn(b'Migrated &lt;script&gt;',after[2])

if __name__=='__main__':unittest.main(verbosity=2)
