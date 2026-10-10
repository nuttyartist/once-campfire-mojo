#!/usr/bin/env python3
"""Crash-safe file cleanup, current Rails counter triggers and schema rejection."""
import contextlib
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import full
from full import local
from network_failures import eventually

spec = importlib.util.spec_from_file_location("manage", local.MOJO / "tools/manage.py")
manage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manage)


@contextlib.contextmanager
def restarted(runtime, logfile, updates=None):
    """Kill/restart exactly the process group serving this disposable database."""
    binary = runtime / "app/campfire"
    parents = []
    for entry in Path("/proc").glob("[0-9]*"):
        try:
            pid = int(entry.name)
            if (os.readlink(entry / "exe") == str(binary) or str(binary).encode() in (entry / "cmdline").read_bytes().split(b"\0")) and os.getpgid(pid) == pid:
                parents.append(pid)
        except (OSError, ValueError):
            pass
    assert len(parents) == 1, parents
    pid = parents[0]
    env = dict(item.decode().split("=", 1) for item in Path(f"/proc/{pid}/environ").read_bytes().split(b"\0") if item)
    for key, value in (updates or {}).items():
        if value is None: env.pop(key, None)
        else: env[key] = value
    os.killpg(pid, signal.SIGKILL)
    time.sleep(.1)
    with logfile.open("w") as log:
        process = subprocess.Popen([str(binary)], cwd=binary.parent, env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            def ready():
                assert process.poll() is None, logfile.read_text()[-2000:]
                try:
                    return local.request("/up")[0] == 200
                except OSError:
                    return False
            eventually(ready, "restarted server did not become ready")
            yield
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()


class StorageRecovery(unittest.TestCase):
    def test_failed_unlink_survives_process_crash(self):
        with tempfile.TemporaryDirectory(prefix="mojo-purge-") as temp:
            root = Path(temp)
            library = root / "faults.so"
            subprocess.run(["clang", "-shared", "-fPIC", str(Path(__file__).with_name("network_faults.c")), "-o", str(library), "-ldl"], check=True)
            state = root / "unlink-state"
            state.write_text("deny")
            with patch.dict(os.environ, {"LD_PRELOAD": str(library), "CAMPFIRE_TEST_UNLINK_STATE": str(state)}), local.server("mojo", root / "logs", cache=False) as (database, runtime, _):
                helper = full.Full("test_17_attachment_cleanup_and_if_range")
                helper.cookie = local.login(json.loads((local.SEED / "labels.json").read_text()))
                helper.rid = json.loads((local.SEED / "labels.json").read_text())["rooms.watercooler"]
                response = helper.multipart(f"/rooms/{helper.rid}/messages", {}, {"message[attachment]": ("recovery.bin", "application/octet-stream", b"recover this deletion")})
                self.assertEqual(response[0], 200)
                mid = re.search(rb'data-message-id="(\d+)"', response[2]).group(1).decode()
                with local.connection(database) as db:
                    key = db.execute("SELECT b.key FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id WHERE a.record_type='Message' AND a.record_id=?", (mid,)).fetchone()[0]
                path = runtime / "files" / key[:2] / key[2:4] / key
                self.assertTrue(path.is_file())
                self.assertEqual(helper.request(f"/rooms/{helper.rid}/messages/{mid}", "DELETE")[0], 200)
                with local.connection(database) as db:
                    self.assertEqual(db.execute("SELECT count(*) FROM messages WHERE id=?", (mid,)).fetchone()[0], 0)
                    self.assertGreaterEqual(db.execute("SELECT attempts FROM mojo_file_purges WHERE key=?", (key,)).fetchone()[0], 1)
                self.assertTrue(path.exists(), "fault injection did not block unlink")
                with restarted(runtime, root / "restart.log"):
                    self.assertTrue(path.exists())
                    state.write_text("allow")
                    with local.connection(database) as db:
                        db.execute("UPDATE mojo_file_purges SET available_at=0")
                    # Unlink happens before directory fsync and the SQL completion
                    # commit. Observing the absent file alone races that commit.
                    def cleanup_completed():
                        with local.connection(database) as db:
                            pending = db.execute("SELECT count(*) FROM mojo_file_purges WHERE key=?", (key,)).fetchone()[0]
                        return not path.exists() and pending == 0
                    eventually(cleanup_completed, "committed cleanup did not resume")
                    with local.connection(database) as db:
                        self.assertEqual(db.execute("SELECT count(*) FROM mojo_file_purges WHERE key=?", (key,)).fetchone()[0], 0)
                        self.assertEqual(db.execute("PRAGMA integrity_check").fetchone(), ("ok",))

    def test_room_and_banned_history_jobs_resume_after_crash(self):
        with tempfile.TemporaryDirectory(prefix="mojo-history-recovery-") as temp:
            root=Path(temp)
            with patch.dict(os.environ,{"CAMPFIRE_JOBS_PAUSED":"1","CAMPFIRE_JOB_RECEIPTS":"1"}), local.server("mojo",root/"logs",cache=False) as (database,runtime,_):
                labels=json.loads((local.SEED/"labels.json").read_text())
                helper=full.Full("test_22_async_room_delete_and_attachment_cleanup")
                helper.cookie=local.login(labels)
                response=helper.request('/rooms/opens','POST',fields={'room[name]':'Crash-recovered room'})
                self.assertEqual(response[0],303)
                rid=response[1]['Location'].split('/')[-1]
                response=helper.multipart(f'/rooms/{rid}/messages',{}, {'message[attachment]':('recover-room.bin','application/octet-stream',b'durable room file')})
                self.assertEqual(response[0],200)
                with local.connection(database) as db:
                    key=db.execute("SELECT b.key FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id JOIN messages m ON m.id=a.record_id WHERE a.record_type='Message' AND m.room_id=?",(rid,)).fetchone()[0]
                    self.assertGreater(db.execute('SELECT count(*) FROM messages WHERE creator_id=?',(labels['users.kevin'],)).fetchone()[0],0)
                self.assertIn(helper.request('/rooms/opens/'+rid,'DELETE')[0],(302,303))
                self.assertEqual(helper.request(f"/users/{labels['users.kevin']}/ban",'POST',fields={})[0],303)
                with local.connection(database) as db:
                    kinds={row[0] for row in db.execute('SELECT kind FROM mojo_jobs')}
                    self.assertTrue({'remove_room','remove_banned_content'}<=kinds)
                path=runtime/'files'/key[:2]/key[2:4]/key
                self.assertTrue(path.exists())
                with restarted(runtime,root/'first-restart.log',{'CAMPFIRE_JOBS_PAUSED':None}):
                    def complete():
                        with local.connection(database) as db:
                            return db.execute('SELECT count(*) FROM mojo_jobs').fetchone()[0]==0
                    eventually(complete,'history jobs did not resume',seconds=20)
                    self.assertFalse(path.exists())
                    with local.connection(database) as db:
                        self.assertEqual(db.execute('SELECT count(*) FROM rooms WHERE id=?',(rid,)).fetchone()[0],0)
                        self.assertEqual(db.execute('SELECT count(*) FROM messages WHERE creator_id=? OR room_id=?',(labels['users.kevin'],rid)).fetchone()[0],0)
                        receipts=db.execute('SELECT message_id,kind FROM campfire_completed_jobs ORDER BY 1,2').fetchall()
                        self.assertIn((int(rid),'remove_room'),receipts)
                        self.assertIn((int(labels['users.kevin']),'remove_banned_content'),receipts)
                        self.assertEqual(db.execute('PRAGMA integrity_check').fetchone(),('ok',))
                    with restarted(runtime,root/'second-restart.log'):
                        time.sleep(.2)
                        with local.connection(database) as db:
                            self.assertEqual(db.execute('SELECT message_id,kind FROM campfire_completed_jobs ORDER BY 1,2').fetchall(),receipts)

    def test_current_rails_counters_cover_foreign_sql_and_restart(self):
        with tempfile.TemporaryDirectory(prefix="mojo-counts-") as temp, local.server("mojo", Path(temp), cache=False) as (database, runtime, _):
            labels = json.loads((local.SEED / "labels.json").read_text())
            cookie = local.login(labels)
            first, second = labels["rooms.watercooler"], labels["rooms.hq"]
            with local.connection(database) as db:
                db.execute("PRAGMA recursive_triggers=ON")
                uid = labels["users.david"]
                mid = db.execute("INSERT INTO messages(client_message_id,creator_id,room_id,created_at,updated_at) VALUES('foreign-sql',?,?,datetime('now'),datetime('now')) RETURNING id", (uid, first)).fetchone()[0]
                for room in [first, second]:
                    self.assertEqual(db.execute("SELECT messages_count FROM rooms WHERE id=?", (room,)).fetchone(), db.execute("SELECT count(*) FROM messages WHERE room_id=?", (room,)).fetchone())
                db.execute("UPDATE messages SET room_id=? WHERE id=?", (second, mid))
                for room in [first, second]:
                    self.assertEqual(db.execute("SELECT messages_count FROM rooms WHERE id=?", (room,)).fetchone(), db.execute("SELECT count(*) FROM messages WHERE room_id=?", (room,)).fetchone())
                db.execute("DELETE FROM messages WHERE id=?", (mid,))
            with restarted(runtime, Path(temp) / "restart.log"):
                response = local.request(f"/rooms/{first}/messages", cookie, "POST", "message%5Bbody%5D=Exactly+one+new+message", {"Content-Type": "application/x-www-form-urlencoded"})
                self.assertEqual(response[0], 200)
                with local.connection(database) as db:
                    self.assertEqual(db.execute("SELECT count(*) FROM rooms r WHERE messages_count<>(SELECT count(*) FROM messages m WHERE m.room_id=r.id)").fetchone()[0], 0)

    def test_import_rejects_partial_or_future_schemas_without_writing_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.db"
            with local.connection(source) as db:
                db.execute("CREATE TABLE users(id INTEGER PRIMARY KEY)")
            before = source.read_bytes()
            with local.connection(source) as db, self.assertRaisesRegex(SystemExit, "Unsupported Campfire schema"):
                manage.validate_schema(db)
            self.assertEqual(source.read_bytes(), before)
            with local.connection(source) as db:
                db.execute("CREATE TABLE schema_migrations(version TEXT)")
                db.execute("INSERT INTO schema_migrations VALUES('29990101000000')")
            with local.connection(source) as db, self.assertRaisesRegex(SystemExit, "newer Rails schema"):
                manage.migrate_database(db)
            with local.connection(source) as db:
                self.assertEqual(db.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()[0], 2)

    def test_offline_gc_keeps_referenced_objects_and_rejects_live_server(self):
        with tempfile.TemporaryDirectory() as temp:
            data = Path(temp) / "data"
            data.mkdir()
            with local.connection(local.SEED / "db/production.sqlite3") as original, local.connection(data / "production.sqlite3") as db:
                original.backup(db)
            shutil.copytree(local.SEED / "storage", data / "files")
            before = manage.manifest(data / "files")
            key = "orphanCreatedBeforeSqlCommit"
            path = data / "files" / key[:2] / key[2:4] / key
            path.parent.mkdir(parents=True)
            path.write_bytes(b"unreferenced crash residue")
            with manage.stopped(data), self.assertRaises(SystemExit):
                manage.collect_garbage(data)
            self.assertEqual(manage.collect_garbage(data), 1)
            self.assertEqual(manage.manifest(data / "files"), before)
            self.assertEqual(manage.collect_garbage(data), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
