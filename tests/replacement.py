#!/usr/bin/env python3
"""Current-Rails security and behavior regressions found in the replacement audit.

These assertions are intentionally independent of the older Rust/C DOM oracle.
Each server uses a disposable seed copy. No external service receives a request.
"""
import json
import re
import unittest
import urllib.parse

import full
from full import local


class Replacement(unittest.TestCase):
    setUpClass = classmethod(full.Full.setUpClass.__func__)
    request = full.Full.request
    multipart = full.Full.multipart

    def message(self, text, client_id="", cookie=None):
        response = self.request(
            f"/rooms/{self.rid}/messages", "POST",
            fields={"message[body]": text, "message[client_message_id]": client_id},
            cookie=cookie,
        )
        self.assertEqual(response[0], 200, response[2])
        return re.search(rb'data-message-id="(\d+)"', response[2]).group(1).decode(), response[2]

    def test_a1_client_ids_never_address_other_records(self):
        cid = 'same-client-id-"[x]'
        first, first_html = self.message("First independent record", cid)
        second, second_html = self.message("Second independent record", cid)
        self.assertNotEqual(first, second)
        for mid, body in [(first, first_html), (second, second_html)]:
            self.assertIn(f'id="message_{mid}"'.encode(), body)
            for prefix in ["edit", "presentation", "boosts"]:
                self.assertIn(f'id="{prefix}_message_{mid}"'.encode(), body)
            self.assertIn(b'data-client-message-id="same-client-id-&quot;[x]"', body)
            self.assertNotIn(b"data-pending-message", body)
        response = self.request(f"/rooms/{self.rid}/messages/{second}", "PATCH",
                                fields={"message[body]": "Edited second record"})
        self.assertEqual(response[0], 303)
        self.assertIn(b"First independent record", self.request(f"/rooms/{self.rid}/messages/{first}")[2])
        self.assertIn(f'id="edit_message_{second}"'.encode(), self.request(f"/rooms/{self.rid}/messages/{second}/edit")[2])
        self.assertIn(f'id="new_boost_message_{second}"'.encode(), self.request(f"/messages/{second}/boosts/new")[2])
        deleted = self.request(f"/rooms/{self.rid}/messages/{second}", "DELETE")
        self.assertEqual(deleted[0], 200)
        self.assertIn(f'target="message_{second}"'.encode(), deleted[2])
        self.assertNotIn(f'target="message_{first}"'.encode(), deleted[2])
        self.assertEqual(self.request(f"/rooms/{self.rid}/messages/{first}")[0], 200)

    def test_a2_fetch_metadata_http_matrix(self):
        credentials = {"email_address": self.labels["emails.david"], "password": self.labels["passwords.all"]}
        for site in ["cross-site", "none", "garbage"]:
            with self.subTest(site=site), local.connection(self.db) as db:
                before = db.execute("SELECT count(*) FROM sessions").fetchone()
                self.assertEqual(self.request("/session", "POST", credentials, cookie="", headers={"Sec-Fetch-Site": site})[0], 422)
                self.assertEqual(db.execute("SELECT count(*) FROM sessions").fetchone(), before)
                self.assertEqual(self.request("/users/me/profile", "POST", {"_method": "patch", "user[name]": "forged"}, headers={"Sec-Fetch-Site": site})[0], 422)
        for origin in ["null", "https://foreign.invalid"]:
            self.assertEqual(self.request("/users/me/profile", "PATCH", {"user[bio]": "forged"}, headers={"Sec-Fetch-Site": "same-site", "Origin": origin})[0], 422)
        for site in ["same-origin", "same-site", None]:
            headers = {} if site is None else {"Sec-Fetch-Site": site}
            self.assertEqual(self.request("/session", "POST", credentials, cookie="", headers=headers)[0], 302)
        self.assertEqual(self.request("/session/new", headers={"Sec-Fetch-Site": "cross-site"})[0], 200)

    def test_a4_email_identity_roundtrip_preserves_case(self):
        email = "MixedCase@Example.test"
        try:
            self.assertEqual(self.request("/users/me/profile", "PATCH", {"user[email_address]": email})[0], 303)
            exact = self.request("/session", "POST", {"email_address": email, "password": self.labels["passwords.all"]}, cookie="")
            self.assertEqual(exact[0], 302)
            # Rails exact identity semantics avoid merging imported identities.
            for different in [email.lower(), " " + email]:
                self.assertEqual(self.request("/session", "POST", {"email_address": different, "password": self.labels["passwords.all"]}, cookie="")[0], 401)
        finally:
            self.request("/users/me/profile", "PATCH", {"user[email_address]": self.labels["emails.david"]})

    def test_a5_large_broadcast_rejects_before_commit(self):
        markup = '<p title="' + "x" * (1024 * 1024) + '">Short plain text</p>'
        with local.connection(self.db) as db:
            before = {table: db.execute(f"SELECT count(*) FROM {table}").fetchone() for table in ["messages", "action_text_rich_texts", "message_search_index"]}
        response = self.request(f"/rooms/{self.rid}/messages", "POST", {"message[body]": markup, "message[client_message_id]": "oversize-regression"})
        self.assertEqual(response[0], 422, response[2])
        with local.connection(self.db) as db:
            for table, count in before.items():
                self.assertEqual(db.execute(f"SELECT count(*) FROM {table}").fetchone(), count)
            self.assertEqual(db.execute("SELECT count(*) FROM messages WHERE client_message_id='oversize-regression'").fetchone()[0], 0)
        mid, _ = self.message("Unchanged after rejected edit")
        self.assertEqual(self.request(f"/rooms/{self.rid}/messages/{mid}", "PATCH", {"message[body]": markup})[0], 422)
        with local.connection(self.db) as db:
            self.assertEqual(db.execute("SELECT body FROM message_search_index WHERE rowid=?", (mid,)).fetchone()[0], "Unchanged after rejected edit")
        self.message("Posting still works after rollback")

    def test_a7_unicode_and_punctuation_search(self):
        mid, _ = self.message("coffee separate tea café λογος 東京")
        for query in ["coffee/tea", "coffee...tea", "café/東京", "λογος—東京"]:
            with self.subTest(query=query):
                response = self.request("/searches?" + urllib.parse.urlencode({"q": query}))
                self.assertEqual(response[0], 200)
                self.assertIn(f'data-message-id="{mid}"'.encode(), response[2])
        response = self.request("/searches", "POST", {"q": "coffee/tea"})
        self.assertEqual(response[0], 303)
        with local.connection(self.db) as db:
            self.assertEqual(db.execute("SELECT query FROM searches WHERE user_id=? ORDER BY id DESC LIMIT 1", (self.uid,)).fetchone()[0], "coffee tea")
        self.assertEqual(self.request("/searches?q=...%2F")[0], 200)

    def test_a8_attachment_filename_after_replacement_and_body_removal(self):
        response = self.multipart(f"/rooms/{self.rid}/messages", {}, {"message[attachment]": ("first.bin", "application/octet-stream", b"first file")})
        self.assertEqual(response[0], 200)
        mid = re.search(rb'data-message-id="(\d+)"', response[2]).group(1).decode()
        response = self.multipart(f"/rooms/{self.rid}/messages/{mid}", {}, {"message[attachment]": ("replacement.bin", "application/octet-stream", b"second file")}, method="PATCH")
        self.assertEqual(response[0], 303)
        with local.connection(self.db) as db:
            self.assertEqual(db.execute("SELECT body FROM message_search_index WHERE rowid=?", (mid,)).fetchone()[0], "replacement.bin")
        response = self.request(f"/rooms/{self.rid}/messages/{mid}", headers={"Accept": "application/json"})
        self.assertEqual(json.loads(response[2])["body"]["plain_text"], "replacement.bin")
        self.assertEqual(self.request(f"/rooms/{self.rid}/messages/{mid}", "PATCH", {"message[body]": ""})[0], 303)
        self.assertIn(f'data-message-id="{mid}"'.encode(), self.request("/searches?q=replacement")[2])

    def test_a9_bans_exempt_safe_requests(self):
        with local.connection(self.db) as db:
            bid = db.execute("INSERT INTO bans(user_id,ip_address,created_at,updated_at) VALUES(?,'127.0.0.1',datetime('now'),datetime('now')) RETURNING id", (self.labels["users.mallory"],)).fetchone()[0]
        try:
            for path in ["/session/new", "/up", f"/rooms/{self.rid}"]:
                for method in ["GET", "HEAD"]:
                    self.assertEqual(self.request(path, method)[0], 200, (path, method))
            self.assertEqual(self.request("/users/me/profile", "PATCH", {"user[bio]": "blocked"})[0], 429)
        finally:
            with local.connection(self.db) as db:
                db.execute("DELETE FROM bans WHERE id=?", (bid,))

    def test_a10_browser_headers(self):
        for path in ["/session/new", "/users/me/profile", "/missing-page"]:
            headers = {k.lower(): v for k, v in self.request(path)[1].items()}
            self.assertEqual(headers["x-frame-options"], "SAMEORIGIN")
            self.assertEqual(headers["referrer-policy"], "strict-origin-when-cross-origin")
            self.assertEqual(headers["x-content-type-options"], "nosniff")


if __name__ == "__main__":
    unittest.main(verbosity=2)
