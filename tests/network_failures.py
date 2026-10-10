#!/usr/bin/env python3
"""HTTPS CSRF matrix, real encrypted push retries, and mixed-workload lock test.

A test-only interposer redirects one resolved public address to a local TLS
receiver. The production endpoint allowlist, DNS guard, certificate checks,
VAPID, encryption, durable worker and retry logic all remain active.
"""
import base64
import ctypes
import ctypes.util
import hashlib
import hmac
import json
import os
import re
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from full import local
from push_receiver import b64, decode, pem, expand, der_integer

HOST = "audit-provider.fcm.googleapis.com"


def decrypt_and_verify(root, private, peer, auth, encrypted, authorization):
    token, vapid_public = authorization.removeprefix("vapid t=").split(", k=")
    first, second, signature = token.split(".")
    claims = json.loads(decode(second))
    assert claims["aud"] == "https://" + HOST
    assert time.time() < claims["exp"] < time.time() + 86401
    public = root / "verify.pem"
    public.write_bytes(pem(decode(vapid_public)))
    sig = decode(signature)
    der = der_integer(sig[:32]) + der_integer(sig[32:])
    (root / "signature").write_bytes(b"\x30" + bytes([len(der)]) + der)
    (root / "jwt").write_bytes((first + "." + second).encode())
    subprocess.check_output(["openssl", "dgst", "-sha256", "-verify", str(public), "-signature", str(root / "signature"), str(root / "jwt")], stderr=subprocess.PIPE)
    assert encrypted[20] == 65
    salt, sender, ciphertext = encrypted[:16], encrypted[21:86], encrypted[86:]
    (root / "sender.pem").write_bytes(pem(sender))
    shared = subprocess.check_output(["openssl", "pkeyutl", "-derive", "-inkey", str(private), "-peerkey", str(root / "sender.pem")], stderr=subprocess.PIPE)
    ikm = expand(hmac.new(auth, shared, hashlib.sha256).digest(), b"WebPush: info\0" + peer + sender, 32)
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    key = expand(prk, b"Content-Encoding: aes128gcm\0", 16)
    nonce = expand(prk, b"Content-Encoding: nonce\0", 12)
    lib = ctypes.CDLL(ctypes.util.find_library("crypto"))
    ptr, integer = ctypes.c_void_p, ctypes.c_int
    for name, args, result in [
        ("EVP_CIPHER_CTX_new", [], ptr), ("EVP_aes_128_gcm", [], ptr),
        ("EVP_DecryptInit_ex", [ptr, ptr, ptr, ptr, ptr], integer),
        ("EVP_DecryptUpdate", [ptr, ptr, ctypes.POINTER(integer), ptr, integer], integer),
        ("EVP_CIPHER_CTX_ctrl", [ptr, integer, integer, ptr], integer),
        ("EVP_DecryptFinal_ex", [ptr, ptr, ctypes.POINTER(integer)], integer),
        ("EVP_CIPHER_CTX_free", [ptr], None),
    ]:
        function = getattr(lib, name)
        function.argtypes, function.restype = args, result
    context = lib.EVP_CIPHER_CTX_new()
    output, length, final = ctypes.create_string_buffer(len(ciphertext)), integer(), integer()
    try:
        assert lib.EVP_DecryptInit_ex(context, lib.EVP_aes_128_gcm(), None, key, nonce) == 1
        assert lib.EVP_DecryptUpdate(context, output, ctypes.byref(length), ciphertext[:-16], len(ciphertext) - 16) == 1
        assert lib.EVP_CIPHER_CTX_ctrl(context, 0x11, 16, ciphertext[-16:]) == 1
        assert lib.EVP_DecryptFinal_ex(context, ctypes.byref(output, length.value), ctypes.byref(final)) == 1
        payload = output.raw[:length.value + final.value].rstrip(b"\0")
        assert payload.endswith(b"\x02")
        return json.loads(payload[:-1])
    finally:
        lib.EVP_CIPHER_CTX_free(context)


def request(path, cookie="", fields=None, headers=None):
    return local.request(path, cookie, "POST" if fields is not None else "GET",
                         urllib.parse.urlencode(fields) if fields is not None else "",
                         {"Content-Type": "application/x-www-form-urlencoded", "Sec-Fetch-Site": "same-origin"} | (headers or {}))


def eventually(fn, description, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError(description)


class NetworkFailures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="campfire-network-tests-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        cls.labels = json.loads((local.SEED / "labels.json").read_text())
        subprocess.run(["clang", "-shared", "-fPIC", str(Path(__file__).with_name("network_faults.c")), "-o", str(cls.root / "faults.so"), "-ldl"], check=True)

    def test_https_metadata_matrix(self):
        old = local.BASE
        local.BASE = f"https://127.0.0.1:{local.PORT}"
        self.addCleanup(setattr, local, "BASE", old)
        credentials = {"email_address": self.labels["emails.david"], "password": self.labels["passwords.all"]}
        with local.server("mojo", self.root / "https", cache=False) as (database, _, _):
            for site in [None, "none", "cross-site", "malformed", "same-origin", "same-site"]:
                headers = {"Content-Type": "application/x-www-form-urlencoded", "Origin": local.BASE}
                if site is not None:
                    headers["Sec-Fetch-Site"] = site
                with local.connection(database) as db:
                    before = db.execute("SELECT count(*) FROM sessions").fetchone()[0]
                response = local.request("/session", "", "POST", urllib.parse.urlencode(credentials | {"authenticity_token": "legacy"}), headers)
                allowed = site in ("same-origin", "same-site")
                self.assertEqual(response[0], 302 if allowed else 422, site)
                with local.connection(database) as db:
                    self.assertEqual(db.execute("SELECT count(*) FROM sessions").fetchone()[0], before + int(allowed))

    def test_transient_failures_retry_until_verified_provider_acceptance(self):
        root = self.root / "push"
        root.mkdir()
        private, certificate = root / "key.pem", root / "cert.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-keyout", str(private), "-out", str(certificate), "-days", "1", "-subj", "/CN=" + HOST, "-addext", "subjectAltName=DNS:" + HOST], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        peer = subprocess.check_output(["openssl", "pkey", "-in", str(private), "-pubout", "-outform", "DER"], stderr=subprocess.PIPE)[-65:]
        auth = os.urandom(16)
        received, errors = [], []
        status = [503]

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                try:
                    body = self.rfile.read(int(self.headers["Content-Length"]))
                    received.append(decrypt_and_verify(root, private, peer, auth, body, self.headers["Authorization"]))
                    self.send_response(status[0])
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                except Exception as error:
                    errors.append(repr(error))
                    self.send_error(500)

        receiver = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(certificate, private)
        receiver.socket = tls.wrap_socket(receiver.socket, server_side=True)
        thread = threading.Thread(target=receiver.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(receiver.server_close)
        self.addCleanup(receiver.shutdown)
        state = root / "dns-state"
        state.write_text("dns failure")
        env = {"LD_PRELOAD": str(self.root / "faults.so"), "CAMPFIRE_TEST_NET_STATE": str(state), "CAMPFIRE_TEST_PROVIDER_PORT": str(receiver.server_port), "CAMPFIRE_CA_BUNDLE": str(certificate), "CAMPFIRE_JOB_RECEIPTS": "1"}
        with patch.dict(os.environ, env), local.server("mojo", root / "logs", cache=False) as (database, _, _):
            cookie = local.login(self.labels)
            rid = self.labels["rooms.hq"]
            with local.connection(database) as db:
                db.execute("DELETE FROM push_subscriptions")
                db.execute("INSERT INTO push_subscriptions(id,user_id,endpoint,p256dh_key,auth_key,created_at,updated_at) VALUES(999999,?,?,?,?,datetime('now'),datetime('now'))", (self.labels["users.kevin"], "https://" + HOST + "/push", b64(peer), b64(auth)))
                db.execute("UPDATE memberships SET involvement='everything',connected_at=NULL WHERE room_id=? AND user_id=?", (rid, self.labels["users.kevin"]))
            response = request(f"/rooms/{rid}/messages", cookie, {"message[body]": "Durable encrypted retry regression"})
            self.assertEqual(response[0], 200)
            mid = re.search(rb'data-message-id="(\d+)"', response[2]).group(1).decode()

            def job():
                with local.connection(database) as db:
                    return db.execute("SELECT attempts,error,lease_until FROM mojo_jobs WHERE message_id=?", (mid,)).fetchone()

            for attempt, error in [(1, "-4"), (2, "503"), (3, "429")]:
                eventually(lambda: (row := job()) and row[0] == attempt and error in (row[1] or "") and row[2] == 0, f"retry {attempt} missing: {job()}")
                with local.connection(database) as db:
                    self.assertEqual(db.execute("SELECT count(*) FROM campfire_completed_jobs WHERE message_id=?", (mid,)).fetchone()[0], 0)
                    self.assertEqual(db.execute("SELECT count(*) FROM campfire_delivery_receipts WHERE message_id=?", (mid,)).fetchone()[0], 0)
                state.write_text("send to local provider")
                status[0] = {1: 503, 2: 429, 3: 201}[attempt]
                with local.connection(database) as db:
                    db.execute("UPDATE mojo_jobs SET available_at=0 WHERE message_id=?", (mid,))
            eventually(lambda: job() is None, "successful delivery was not acknowledged")
            self.assertFalse(errors, errors)
            self.assertEqual(len(received), 3)
            self.assertTrue(all(item["options"]["body"] == "David: Durable encrypted retry regression" for item in received))
            with local.connection(database) as db:
                self.assertEqual(db.execute("SELECT count(*) FROM campfire_completed_jobs WHERE message_id=?", (mid,)).fetchone()[0], 1)
                self.assertEqual(db.execute("SELECT count(*) FROM campfire_delivery_receipts WHERE message_id=? AND target_id=999999", (mid,)).fetchone()[0], 1)

    def test_large_webhook_attachment_is_not_truncated(self):
        payload = bytes(range(256)) * 8193
        received = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                self.send_response(200)
                self.send_header('Content-Type','application/octet-stream')
                self.send_header('Content-Length',str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
        receiver=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        threading.Thread(target=receiver.serve_forever,daemon=True).start()
        self.addCleanup(receiver.server_close);self.addCleanup(receiver.shutdown)
        with local.server('mojo',self.root/'large-hook',cache=False) as (database,_,_):
            cookie=local.login(self.labels)
            response=request('/account/bots',cookie,{'user[name]':'Large hook','user[webhook_url]':f'http://127.0.0.1:{receiver.server_port}/hook'})
            self.assertEqual(response[0],303)
            with local.connection(database) as db:
                bid=db.execute("SELECT id FROM users WHERE name='Large hook'").fetchone()[0]
            room=request('/rooms/directs',cookie,{'user_ids[]':bid})[1]['Location']
            self.assertEqual(request(room+'/messages',cookie,{'message[body]':'Large attachment reply'})[0],200)
            def attachment():
                with local.connection(database) as db:
                    return db.execute("SELECT b.key,b.byte_size,b.checksum FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id JOIN messages m ON m.id=a.record_id WHERE a.record_type='Message' AND m.creator_id=?",(bid,)).fetchone()
            key,size,checksum=eventually(attachment,'Large webhook attachment was not stored')
            self.assertEqual(size,len(payload))
            self.assertEqual(checksum,base64.b64encode(hashlib.md5(payload).digest()).decode())
            self.assertEqual(len(received),1)

    def test_slow_preview_does_not_hold_sqlite_writer(self):
        entered = self.root / "dns-entered"
        with patch.dict(os.environ, {"LD_PRELOAD": str(self.root / "faults.so"), "CAMPFIRE_TEST_DNS_ENTERED": str(entered)}), local.server("mojo", self.root / "mixed", cache=False):
            cookie = local.login(self.labels)
            result = []
            thread = threading.Thread(target=lambda: result.append(request("/unfurl_link", cookie, {"url": "http://audit-slow.example.com/page"})[0]))
            thread.start()
            eventually(entered.exists, "slow DNS request never started")
            started = time.monotonic()
            response = request(f'/rooms/{self.labels["rooms.hq"]}/messages', cookie, {"message[body]": "Unrelated concurrent write"})
            elapsed = time.monotonic() - started
            thread.join(timeout=10)
            self.assertEqual(response[0], 200)
            self.assertEqual(result, [204])
            self.assertLess(elapsed, 1.0, f"write waited {elapsed:.3f}s for a two-second DNS timeout")


if __name__ == "__main__":
    unittest.main(verbosity=2)
