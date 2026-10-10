#!/usr/bin/env python3
"""All durable comparison writers tolerate the same bounded external lock."""
import concurrent.futures, json, os, sys, tempfile, threading, time, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'bench'))
import local as b
import durable


class Contention(unittest.TestCase):
    def test_post_waits_for_lock_and_completes_all_jobs(self):
        os.environ.update(durable.ENV)
        labels = json.loads((b.SEED / 'labels.json').read_text())
        room = int(labels['rooms.hq'])
        evidence = []
        for app in os.environ.get('CONTENTION_APPS', 'rust,c,mojo').split(','):
            with self.subTest(app=app), tempfile.TemporaryDirectory() as out:
                dest = Path(os.environ.get('CONTENTION_RESULTS', out)) / app
                with b.server(app, dest, cache=False, verify_log=True) as (db, _, _):
                    cookie = b.login(labels)
                    with b.connection(db) as c:
                        baseline = {r[0] for r in c.execute('SELECT id FROM messages WHERE room_id=?', (room,))}
                        subscriptions = {r[0] for r in c.execute("SELECT ps.id FROM push_subscriptions ps JOIN memberships mm ON mm.user_id=ps.user_id WHERE mm.room_id=? AND mm.user_id<>? AND mm.involvement='everything'", (room, labels['users.david']))}
                    entered = threading.Event()
                    def post():
                        entered.set()
                        return b.request(f'/rooms/{room}/messages', cookie, 'POST',
                                         'message[body]=bounded+writer+contention&message[client_message_id]=bounded-contention',
                                         {'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'text/vnd.turbo-stream.html'})
                    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                        with b.connection(db) as lock:
                            lock.execute('BEGIN IMMEDIATE')
                            started = time.monotonic()
                            pending = pool.submit(post)
                            self.assertTrue(entered.wait(2))
                            # Six seconds exceeds the old C (1s) and Rust (5s)
                            # budgets, but remains below the shared 10s budget.
                            time.sleep(6)
                            completed_while_locked = pending.done()
                        response = pending.result(timeout=15)
                        elapsed = time.monotonic() - started
                    self.assertEqual(response[0], 200, (app, response[0], response[2][:150]))
                    self.assertFalse(completed_while_locked, app)
                    self.assertLess(elapsed, 12)
                    ids = durable.new_ids(db, room, baseline)
                    self.assertEqual(len(ids), 1)
                    receipt = durable.drain(db, app, ids, subscriptions)
                    with b.connection(db) as c:
                        self.assertEqual(c.execute('PRAGMA integrity_check').fetchone(), ('ok',))
                        self.assertEqual(c.execute('SELECT count(*) FROM messages WHERE id NOT IN (SELECT rowid FROM message_search_index)').fetchone(), (0,))
                    evidence.append({'app': app, 'held_seconds': 6, 'elapsed_seconds': elapsed, 'completed': receipt})
        if os.environ.get('CONTENTION_RESULTS'):
            b.write_json(Path(os.environ['CONTENTION_RESULTS']) / 'contention.json', evidence)
        print(json.dumps(evidence), flush=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
