#!/usr/bin/env python3
"""Posting dispatch and idle-worker regressions against a disposable real server."""
import json
import re
import time
import unittest

import byte_http
import full
from full import local


class PostingOptimizations(unittest.TestCase):
    setUpClass = classmethod(full.Full.setUpClass.__func__)
    request = full.Full.request
    multipart = full.Full.multipart
    processes = byte_http.ByteHTTP.processes

    def test_01_idle_workers_do_not_request_a_write_lock(self):
        before = self.processes()
        with local.connection(self.db) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM mojo_jobs').fetchone()[0], 0)
            db.execute('BEGIN IMMEDIATE')
            # Exceed the ten-second busy timeout. Write-polling workers used to
            # time out and restart even though there was no job to claim.
            time.sleep(10.5)
            self.assertEqual(self.request('/up')[0], 200)
            db.rollback()
        self.assertEqual(before, self.processes())
        local.validate_server_log(self.runtime / 'server.log')

    def test_02_post_dispatch_preserves_security_and_method_guards(self):
        path = f'/rooms/{self.rid}/messages'
        with local.connection(self.db) as db:
            before = db.execute('SELECT count(*) FROM messages').fetchone()
        for headers in [{'Sec-Fetch-Site': 'cross-site'}, {'Origin': 'https://foreign.invalid'}]:
            self.assertEqual(self.request(path, 'POST', {'message[body]': 'forged'}, headers=headers)[0], 422)
        self.assertEqual(self.request(path, 'POST', {'message[body]': 'anonymous'}, cookie='')[0], 401)
        self.assertEqual(self.request(path, 'POST', {'_method': 'delete', 'message[body]': 'not a create'})[0], 404)
        with local.connection(self.db) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM messages').fetchone(), before)
            membership = db.execute('SELECT * FROM memberships WHERE room_id=? AND user_id=?', (self.rid, self.uid)).fetchone()
            columns = [row[1] for row in db.execute('PRAGMA table_info(memberships)')]
            db.execute('DELETE FROM memberships WHERE room_id=? AND user_id=?', (self.rid, self.uid))
        try:
            self.assertEqual(self.request(path, 'POST', {'message[body]': 'not a member'})[0], 404)
        finally:
            with local.connection(self.db) as db:
                db.execute('INSERT INTO memberships('+','.join(columns)+') VALUES('+','.join('?' for _ in membership)+')', membership)

    def test_03_parsed_forms_preserve_unicode_and_client_identity(self):
        path = f'/rooms/{self.rid}/messages'
        for encoding in ['form', 'json', 'multipart']:
            text = f'{encoding}: café שלום 🔥 & + ='
            fields = {'message[body]': text, 'message[client_message_id]': encoding + '-client'}
            if encoding == 'json':
                response = self.request(path, 'POST', body=json.dumps({'message': {'body': text, 'client_message_id': encoding+'-client'}}), headers={'Content-Type': 'application/json'})
            elif encoding == 'multipart':
                response = self.multipart(path, fields, {})
            else:
                response = self.request(path, 'POST', fields)
            self.assertEqual(response[0], 200, response[2])
            mid = re.search(rb'data-message-id="(\d+)"', response[2]).group(1).decode()
            with local.connection(self.db) as db:
                self.assertEqual(db.execute('SELECT client_message_id FROM messages WHERE id=?', (mid,)).fetchone()[0], encoding+'-client')
                self.assertEqual(db.execute('SELECT body FROM message_search_index WHERE rowid=?', (mid,)).fetchone()[0], text)

    def test_04_queue_queries_use_the_ready_index_without_sorting(self):
        source = (local.MOJO / 'src/jobs.mojo').read_text()
        queries = re.findall(r'"((?:SELECT 1 FROM mojo_jobs INDEXED BY|UPDATE mojo_jobs SET lease_until=unixepoch\(\)\+600,attempts=attempts\+1)[^"\n]+)"', source)
        self.assertEqual(len(queries), 2)
        with local.connection(self.db) as db:
            for sql in queries:
                plan = [row[3] for row in db.execute('EXPLAIN QUERY PLAN '+sql)]
                self.assertTrue(any('mojo_jobs_ready' in row for row in plan), plan)
                self.assertFalse(any('TEMP B-TREE' in row for row in plan), plan)


if __name__ == '__main__':
    unittest.main(verbosity=2)
