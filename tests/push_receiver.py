#!/usr/bin/env python3
"""Independent receiver: OpenSSL CLI ECDH/ES256, Python HKDF, EVP AES-GCM."""
import base64,ctypes,ctypes.util,hashlib,hmac,json,os,struct,subprocess,tempfile
from pathlib import Path

def b64(raw):return base64.urlsafe_b64encode(raw).decode().rstrip('=')
def decode(text):return base64.urlsafe_b64decode(text+'='*(-len(text)%4))
def pem(public):return b'-----BEGIN PUBLIC KEY-----\n'+base64.encodebytes(bytes.fromhex('3059301306072a8648ce3d020106082a8648ce3d030107034200')+public)+b'-----END PUBLIC KEY-----\n'
def cmd(args):return subprocess.check_output(args,stderr=subprocess.PIPE)
def expand(prk,info,length):return hmac.new(prk,info+b'\x01',hashlib.sha256).digest()[:length]
def der_integer(raw):
 raw=raw.lstrip(b'\0') or b'\0'
 if raw[0]&128:raw=b'\0'+raw
 return b'\x02'+bytes([len(raw)])+raw

def main():
 with tempfile.TemporaryDirectory(prefix='mojo-push-receiver-') as temp:
  root=Path(temp);private=root/'private.pem';cmd(['openssl','ecparam','-name','prime256v1','-genkey','-noout','-out',str(private)])
  der=cmd(['openssl','ec','-in',str(private),'-outform','DER']);peer=cmd(['openssl','pkey','-in',str(private),'-pubout','-outform','DER'])[-65:]
  # ECPrivateKey DER: version, 32-byte scalar, curve and public point.
  scalar=der[7:39];assert len(scalar)==32 and der[5:7]==b'\x04\x20'
  auth=os.urandom(16)
  env=os.environ|{'TEST_PEER':b64(peer),'TEST_AUTH':b64(auth),'VAPID_PRIVATE_KEY':b64(scalar),'VAPID_SUBJECT':'mailto:test@example.invalid'}
  wire=json.loads(subprocess.check_output([str(Path(__file__).resolve().parents[1]/'build/push-fixture')],env=env))
  header=wire['authorization'];token,public=header.removeprefix('vapid t=').split(', k=');first,second,signature=token.split('.')
  claims=json.loads(decode(second));assert claims=={'aud':'https://push.example.test','exp':1700043200,'sub':'mailto:test@example.invalid'}
  assert json.loads(decode(first))=={'typ':'JWT','alg':'ES256'}
  vapid=root/'vapid.pem';vapid.write_bytes(pem(decode(public)));sig=decode(signature);encoded=der_integer(sig[:32])+der_integer(sig[32:]);(root/'sig').write_bytes(b'\x30'+bytes([len(encoded)])+encoded);(root/'jwt').write_bytes((first+'.'+second).encode())
  cmd(['openssl','dgst','-sha256','-verify',str(vapid),'-signature',str(root/'sig'),str(root/'jwt')])
  encrypted=base64.b64decode(wire['encrypted']);salt=encrypted[:16];record_size=struct.unpack('!I',encrypted[16:20])[0];assert encrypted[20]==65 and record_size>=len(encrypted)-86
  sender=encrypted[21:86];ciphertext=encrypted[86:];(root/'sender.pem').write_bytes(pem(sender))
  shared=cmd(['openssl','pkeyutl','-derive','-inkey',str(private),'-peerkey',str(root/'sender.pem')])
  ikm=expand(hmac.new(auth,shared,hashlib.sha256).digest(),b'WebPush: info\0'+peer+sender,32);prk=hmac.new(salt,ikm,hashlib.sha256).digest();key=expand(prk,b'Content-Encoding: aes128gcm\0',16);nonce=expand(prk,b'Content-Encoding: nonce\0',12)
  lib=ctypes.CDLL(ctypes.util.find_library('crypto'));ptr=ctypes.c_void_p;integer=ctypes.c_int
  for name,args,result in [('EVP_CIPHER_CTX_new',[],ptr),('EVP_aes_128_gcm',[],ptr),('EVP_DecryptInit_ex',[ptr,ptr,ptr,ptr,ptr],integer),('EVP_DecryptUpdate',[ptr,ptr,ctypes.POINTER(integer),ptr,integer],integer),('EVP_CIPHER_CTX_ctrl',[ptr,integer,integer,ptr],integer),('EVP_DecryptFinal_ex',[ptr,ptr,ctypes.POINTER(integer)],integer),('EVP_CIPHER_CTX_free',[ptr],None)]:
   function=getattr(lib,name);function.argtypes=args;function.restype=result
  context=lib.EVP_CIPHER_CTX_new();output=ctypes.create_string_buffer(len(ciphertext));length=integer();final=integer()
  try:
   assert lib.EVP_DecryptInit_ex(context,lib.EVP_aes_128_gcm(),None,key,nonce)==1
   assert lib.EVP_DecryptUpdate(context,output,ctypes.byref(length),ciphertext[:-16],len(ciphertext)-16)==1
   assert lib.EVP_CIPHER_CTX_ctrl(context,0x11,16,ciphertext[-16:])==1
   assert lib.EVP_DecryptFinal_ex(context,ctypes.byref(output,length.value),ctypes.byref(final))==1
   payload=output.raw[:length.value+final.value].rstrip(b'\0');assert payload.endswith(b'\x02');assert payload[:-1]=='Campfire push ✓'.encode()
  finally:lib.EVP_CIPHER_CTX_free(context)
 print('PASS: independently verified VAPID signature, claims and decrypted Web Push payload')
if __name__=='__main__':main()
