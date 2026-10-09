# RFC 8291 payload encryption and RFC 8292 VAPID, composed in Mojo.
from std.ffi import external_call
from std.os import getenv
from database import Database
from crypto import base64, unbase64, json_string
import network


def random_bytes(n: Int) raises -> String:
    var buf = List[UInt8](length=n,fill=0)
    if external_call["crypto_random",Int](buf.unsafe_ptr(),n)!=0:
        raise Error("Randomness failed")
    return String(unsafe_from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(),length=n))


def hmac(key: String, value: String) raises -> String:
    var buf = List[UInt8](length=32,fill=0)
    if external_call["hmac_sha256_raw",Int](key.as_bytes().unsafe_ptr(),key.byte_length(),value.as_bytes().unsafe_ptr(),value.byte_length(),buf.unsafe_ptr())!=32:
        raise Error("HMAC failed")
    return String(unsafe_from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(),length=32))


def expand(prk: String, info: String, size: Int) raises -> String:
    var value = hmac(prk,info+"\x01")
    return String(unsafe_from_utf8=value.as_bytes()[:size])


def encrypt_with(private: String, public: String, peer: String, auth: String, salt: String, payload: String) raises -> String:
    if private.byte_length()!=32 or public.byte_length()!=65 or peer.byte_length()!=65 or auth.byte_length()!=16 or salt.byte_length()!=16 or payload.byte_length()>4078:
        raise Error("Invalid push key or payload size")
    var shared = List[UInt8](length=32,fill=0)
    if external_call["p256_ecdh",Int](private.as_bytes().unsafe_ptr(),peer.as_bytes().unsafe_ptr(),shared.unsafe_ptr())!=0:
        raise Error("Invalid subscriber public key")
    var secret = String(unsafe_from_utf8=Span(unsafe_ptr=shared.unsafe_ptr(),length=32))
    var ikm = expand(hmac(auth,secret),"WebPush: info\x00"+peer+public,32)
    var prk = hmac(salt,ikm)
    var key = expand(prk,"Content-Encoding: aes128gcm\x00",16)
    var nonce = expand(prk,"Content-Encoding: nonce\x00",12)
    var padded = payload+"\x02"
    var encrypted = List[UInt8](length=padded.byte_length()+16,fill=0)
    var n = external_call["aes128gcm_encrypt",Int](key.as_bytes().unsafe_ptr(),nonce.as_bytes().unsafe_ptr(),padded.as_bytes().unsafe_ptr(),padded.byte_length(),encrypted.unsafe_ptr())
    if n<0:
        raise Error("Encryption failed")
    return salt+"\x00\x00\x10\x00\x41"+public+String(unsafe_from_utf8=Span(unsafe_ptr=encrypted.unsafe_ptr(),length=n))


def encrypt(peer: String, auth: String, payload: String) raises -> String:
    var private = List[UInt8](length=32,fill=0)
    var public = List[UInt8](length=65,fill=0)
    if external_call["p256_generate",Int](private.unsafe_ptr(),public.unsafe_ptr())!=0:
        raise Error("Push key generation failed")
    return encrypt_with(String(unsafe_from_utf8=Span(unsafe_ptr=private.unsafe_ptr(),length=32)),String(unsafe_from_utf8=Span(unsafe_ptr=public.unsafe_ptr(),length=65)),unbase64(peer),unbase64(auth),random_bytes(16),payload)


def authorization(audience: String, now: Int) raises -> String:
    var private = unbase64(getenv("VAPID_PRIVATE_KEY",""))
    var subject = getenv("VAPID_SUBJECT","mailto:admin@example.invalid")
    if private.byte_length()!=32:
        raise Error("VAPID_PRIVATE_KEY must be a base64 P-256 private key")
    var pub = List[UInt8](length=65,fill=0)
    if external_call["p256_public",Int](private.as_bytes().unsafe_ptr(),pub.unsafe_ptr())!=0:
        raise Error("Invalid VAPID key")
    var public = String(unsafe_from_utf8=Span(unsafe_ptr=pub.unsafe_ptr(),length=65))
    var message = base64('{"typ":"JWT","alg":"ES256"}',True,False)+"."+base64('{"aud":'+json_string(audience)+',"exp":'+String(now+43200)+',"sub":'+json_string(subject)+'}',True,False)
    var signature = List[UInt8](length=64,fill=0)
    if external_call["p256_sign",Int](private.as_bytes().unsafe_ptr(),message.as_bytes().unsafe_ptr(),message.byte_length(),signature.unsafe_ptr())!=0:
        raise Error("VAPID signing failed")
    return "vapid t="+message+"."+base64(String(unsafe_from_utf8=Span(unsafe_ptr=signature.unsafe_ptr(),length=64)),True,False)+", k="+base64(public,True,False)


def deliver(mut db: Database, id: String, endpoint: String, peer: String, auth: String, payload: String) raises:
    var pieces = endpoint.split("/",maxsplit=3)
    if len(pieces)<3:
        raise Error("Invalid push endpoint")
    var audience = String(pieces[0])+"//"+String(pieces[2])
    var body = encrypt(peer,auth,payload)
    var header = "Content-Type: application/octet-stream\nContent-Encoding: aes128gcm\nTTL: 2419200\nUrgency: high\nAuthorization: "+authorization(audience,Int(db.scalar("SELECT unixepoch()")))
    var result = network.request(endpoint,"POST",header,body)
    if result.status==404 or result.status==410:
        _ = db.rows("DELETE FROM push_subscriptions WHERE id=?",[id])
    elif result.status==-2:
        return
    elif result.status<200 or result.status>=300:
        raise Error("Push delivery failed with status "+String(result.status))
