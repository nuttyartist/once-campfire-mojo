import native_boundary as native
from byte_buffer import Bytes

# RFC 8291 payload encryption and RFC 8292 VAPID, composed in Mojo.
from std.os import getenv
from database import Database
from crypto import base64, unbase64, json_string
import network


def random_bytes(n: Int) raises -> Bytes:
    if n < 0 or n > 1048576:
        raise Error("Invalid random buffer size")
    var buf = List[UInt8](length=n, fill=0)
    if native.crypto_random(buf, n) != 0:
        raise Error("Randomness failed")
    return Bytes(Span(buf)[:n])


def hmac(key: Bytes, value: Bytes) raises -> Bytes:
    var buf = List[UInt8](length=32, fill=0)
    if (
        native.hmac_sha256_raw(
            key.as_bytes(),
            key.byte_length(),
            value.as_bytes(),
            value.byte_length(),
            buf,
        )
        != 32
    ):
        raise Error("HMAC failed")
    return Bytes(Span(buf)[:32])


def expand(prk: Bytes, info: Bytes, size: Int) raises -> Bytes:
    if size < 0 or size > 32:
        raise Error("Invalid HKDF expansion size")
    var value = hmac(prk, info + "\x01")
    return Bytes(value.as_bytes()[:size])


def encrypt_with(
    private: Bytes,
    public: Bytes,
    peer: Bytes,
    auth: Bytes,
    salt: Bytes,
    payload: String,
) raises -> Bytes:
    if (
        private.byte_length() != 32
        or public.byte_length() != 65
        or peer.byte_length() != 65
        or auth.byte_length() != 16
        or salt.byte_length() != 16
        or payload.byte_length() > 4078
    ):
        raise Error("Invalid push key or payload size")
    var shared = List[UInt8](length=32, fill=0)
    if native.p256_ecdh(private.as_bytes(), peer.as_bytes(), shared) != 0:
        raise Error("Invalid subscriber public key")
    var secret = Bytes(Span(shared)[:32])
    var ikm = expand(
        hmac(auth, secret), "WebPush: info\x00" + peer + public, 32
    )
    var prk = hmac(salt, ikm)
    var key = expand(prk, "Content-Encoding: aes128gcm\x00", 16)
    var nonce = expand(prk, "Content-Encoding: nonce\x00", 12)
    var padded = payload + "\x02"
    var encrypted = List[UInt8](length=padded.byte_length() + 16, fill=0)
    var n = native.aes128gcm_encrypt(
        key.as_bytes(),
        nonce.as_bytes(),
        padded.as_bytes(),
        padded.byte_length(),
        encrypted,
    )
    if n < 0:
        raise Error("Encryption failed")
    return salt + "\x00\x00\x10\x00\x41" + public + Bytes(Span(encrypted)[:n])


def encrypt(peer: String, auth: String, payload: String) raises -> Bytes:
    var private = List[UInt8](length=32, fill=0)
    var public = List[UInt8](length=65, fill=0)
    if native.p256_generate(private, public) != 0:
        raise Error("Push key generation failed")
    return encrypt_with(
        Bytes(Span(private)[:32]),
        Bytes(Span(public)[:65]),
        unbase64(peer),
        unbase64(auth),
        random_bytes(16),
        payload,
    )


def authorization(audience: String, now: Int) raises -> String:
    var private = unbase64(getenv("VAPID_PRIVATE_KEY", ""))
    var subject = getenv("VAPID_SUBJECT", "mailto:admin@example.invalid")
    if private.byte_length() != 32:
        raise Error("VAPID_PRIVATE_KEY must be a base64 P-256 private key")
    var pub = List[UInt8](length=65, fill=0)
    if native.p256_public(private.as_bytes(), pub) != 0:
        raise Error("Invalid VAPID key")
    var public = Bytes(Span(pub)[:65])
    var message = (
        base64('{"typ":"JWT","alg":"ES256"}', True, False)
        + "."
        + base64(
            '{"aud":'
            + json_string(audience)
            + ',"exp":'
            + String(now + 43200)
            + ',"sub":'
            + json_string(subject)
            + "}",
            True,
            False,
        )
    )
    var signature = List[UInt8](length=64, fill=0)
    if (
        native.p256_sign(
            private.as_bytes(),
            message.as_bytes(),
            message.byte_length(),
            signature,
        )
        != 0
    ):
        raise Error("VAPID signing failed")
    return (
        "vapid t="
        + message
        + "."
        + base64(Bytes(Span(signature)[:64]), True, False)
        + ", k="
        + base64(public, True, False)
    )


def deliver(
    mut db: Database,
    id: String,
    endpoint: String,
    peer: String,
    auth: String,
    payload: String,
) raises:
    var pieces = endpoint.split("/", maxsplit=3)
    if len(pieces) < 3:
        raise Error("Invalid push endpoint")
    var audience = String(pieces[0]) + "//" + String(pieces[2])
    var body = encrypt(peer, auth, payload)
    var header = (
        "Content-Type: application/octet-stream\nContent-Encoding: aes128gcm\nTTL: 2419200\nUrgency: high\nAuthorization: "
        + authorization(audience, Int(db.scalar("SELECT unixepoch()")))
    )
    var result = network.request(endpoint, "POST", header, body)
    if result.status == 404 or result.status == 410:
        _ = db.rows("DELETE FROM push_subscriptions WHERE id=?", [id])
    elif result.status == -2:
        return
    elif result.status < 200 or result.status >= 300:
        raise Error("Push delivery failed with status " + String(result.status))
