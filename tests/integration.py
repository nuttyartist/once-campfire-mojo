#!/usr/bin/env python3
"""Behavioral tests against the compiled server and real canonical SQLite fixture."""
import concurrent.futures
import contextlib
import http.client
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import sys
import tempfile
import unittest
import urllib.parse

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bench"))
import local


class Integration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.stack = contextlib.ExitStack()
        cls.addClassCleanup(cls.stack.close)
        cls.output = Path(cls.stack.enter_context(tempfile.TemporaryDirectory(prefix="mojo-tests-")))
        cls.db, _, _ = cls.stack.enter_context(local.server("mojo", cls.output))
        cls.labels = json.loads((local.SEED / "labels.json").read_text())
        cls.cookie = local.login(cls.labels)
        cls.room = cls.labels["rooms.watercooler"]
        cls.write_room = cls.labels["rooms.hq"]
        cls.user = cls.labels["users.david"]

    def get(self, path=None, cookie=None, **kwargs):
        return local.request(path or f"/rooms/{self.room}", self.cookie if cookie is None else cookie, **kwargs)

    def post(self, text, headers=None, room=None):
        return self.get(f"/rooms/{room or self.write_room}/messages", method="POST",
                        body=urllib.parse.urlencode({"message[body]": text}),
                        headers={"Content-Type":"application/x-www-form-urlencoded","Sec-Fetch-Site":"same-origin",**(headers or {})})

    def test_01_upstream_read_contracts(self):
        files, paths, _ = local.contracts(self.db,self.labels,self.cookie,self.output/"contracts")
        for route,path in paths.items():
            with self.subTest(route=route):
                result = local.loadgen("http","--base",local.BASE,"--cookie",self.cookie,"--path",path,
                                      "--validate",files[route],"--conc","16","--duration","1")
                local.check_sample(result)

    def test_02_authentication_required(self):
        for cookie in ["", "session_token=" + "0"*64, self.cookie + "tampered"]:
            self.assertEqual(self.get(cookie=cookie)[0],302)
        body = urllib.parse.urlencode({"email_address":self.labels["emails.david"],"password":"incorrect"})
        self.assertEqual(local.request("/session",method="POST",body=body,
                         headers={"Content-Type":"application/x-www-form-urlencoded"})[0],401)

    def test_03_revoked_membership_and_search(self):
        self.assertEqual(self.get()[0],200)
        with local.connection(self.db) as db:
            row = db.execute("SELECT * FROM memberships WHERE room_id=? AND user_id=?",(self.room,self.user)).fetchone()
            columns = [r[1] for r in db.execute("PRAGMA table_info(memberships)")]
            db.execute("DELETE FROM memberships WHERE room_id=? AND user_id=?",(self.room,self.user))
        try:
            for _ in range(12):
                self.assertEqual(self.get()[0],404)
            status,_,body,_ = self.get("/searches?q=coffee")
            self.assertEqual(status,200)
            with local.connection(self.db) as db:
                private_ids = {r[0] for r in db.execute("SELECT id FROM messages WHERE room_id=?",(self.room,))}
            self.assertFalse(private_ids.intersection(map(int,re.findall(rb'data-message-id="(\d+)"',body))))
            self.assertEqual(self.post("denied",room=self.room)[0],404)
        finally:
            with local.connection(self.db) as db:
                db.execute(f"INSERT INTO memberships({','.join(columns)}) VALUES({','.join('?' for _ in columns)})",row)

    def test_04_user_deactivation_invalidates_cached_pages(self):
        self.assertEqual(self.get()[0],200)
        with local.connection(self.db) as db:
            db.execute("UPDATE users SET status=1 WHERE id=?",(self.user,))
        try:
            for _ in range(12):
                self.assertEqual(self.get()[0],302)
            self.assertEqual(self.post("denied")[0],401)
        finally:
            with local.connection(self.db) as db:
                db.execute("UPDATE users SET status=0 WHERE id=?",(self.user,))

    def test_05_external_body_edit_invalidates_every_worker(self):
        self.assertEqual(self.get()[0],200)
        with local.connection(self.db) as db:
            mid = db.execute("SELECT id FROM messages WHERE room_id=? ORDER BY created_at DESC LIMIT 1",(self.room,)).fetchone()[0]
            old = db.execute("SELECT body FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",(mid,)).fetchone()[0]
            db.execute("UPDATE action_text_rich_texts SET body='<div>externally changed cache marker</div>' WHERE record_type='Message' AND record_id=?",(mid,))
        try:
            for _ in range(16):
                self.assertIn(b"externally changed cache marker",self.get()[2])
        finally:
            with local.connection(self.db) as db:
                db.execute("UPDATE action_text_rich_texts SET body=? WHERE record_type='Message' AND record_id=?",(old,mid))

    def test_06_csrf_and_content_type(self):
        self.assertEqual(self.post("denied",{"Sec-Fetch-Site":"cross-site"})[0],422)
        self.assertEqual(self.post("denied",{"Origin":"http://unrelated.invalid"})[0],422)
        self.assertEqual(self.post("denied",{"Content-Type":"application/json"})[0],422)

    def test_07_unicode_escaping_and_persistence(self):
        value = "שלום café 🔥 <script>alert('x')</script> & coffee"
        status,_,body,_ = self.post(value)
        self.assertEqual(status,200)
        self.assertNotIn(b"<script>",body)
        self.assertIn("שלום café 🔥".encode(),body)
        self.assertIn(b"&amp;",body)
        mid = int(re.search(rb'data-message-id="(\d+)"',body)[1])
        with local.connection(self.db) as db:
            record = db.execute("SELECT room_id,creator_id FROM messages WHERE id=?",(mid,)).fetchone()
            self.assertEqual(record,(self.write_room,self.user))
            text = db.execute("SELECT body FROM message_search_index WHERE rowid=?",(mid,)).fetchone()[0]
            self.assertIn("שלום café 🔥",text)

    def test_08_concurrent_writes_are_atomic(self):
        count = 64
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            responses = list(pool.map(lambda i:self.post(f"parallel message token {i}"),range(count)))
        ids = []
        for i,(status,_,body,_) in enumerate(responses):
            self.assertEqual(status,200)
            self.assertIn(f"parallel message token {i}".encode(),body)
            ids.append(int(re.search(rb'data-message-id="(\d+)"',body)[1]))
        self.assertEqual(len(set(ids)),count)
        with local.connection(self.db) as db:
            for i,mid in enumerate(ids):
                self.assertEqual(db.execute("SELECT body FROM message_search_index WHERE rowid=?",(mid,)).fetchone()[0],f"parallel message token {i}")
                self.assertIn(f"parallel message token {i}",db.execute("SELECT body FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",(mid,)).fetchone()[0])
            self.assertEqual(db.execute("PRAGMA integrity_check").fetchone(),("ok",))

    def test_09_validation_and_sql_boundaries(self):
        self.assertEqual(self.post("")[0],422)
        self.assertEqual(self.post("x"*65537)[0],422)
        self.assertEqual(self.get("/rooms/1%20OR%201=1")[0],400)
        self.assertEqual(self.get(f"/rooms/{self.room}/messages?before=-1")[0],400)
        self.assertEqual(self.get("/searches?q=NOT")[0],200)
        self.assertEqual(self.get("/searches?q=%27%20OR%201%3D1")[0],200)
        self.assertEqual(self.get("/searches?q=%ZZ")[0],400)

    def test_10_http_framing(self):
        cases = [
            (b"GET /up HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n",400),
            (b"POST /session HTTP/1.1\r\nHost: localhost\r\nContent-Length: 9999999\r\n\r\n",413),
            (b"POST /session HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n",400),
        ]
        for raw,status in cases:
            with socket.create_connection(("127.0.0.1",local.PORT),timeout=10) as sock:
                sock.sendall(raw)
                response = sock.recv(4096)
                self.assertIn(f"HTTP/1.1 {status} ".encode(),response)
        conn = http.client.HTTPConnection("127.0.0.1",local.PORT)
        try:
            for _ in range(10):
                conn.request("GET","/up")
                response=conn.getresponse()
                self.assertEqual(response.status,200)
                self.assertIn(b"background-color: green",response.read())
        finally:
            conn.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
