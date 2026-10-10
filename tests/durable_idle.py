#!/usr/bin/env python3
"""Idle durable C pools must never compete for SQLite's single writer lock."""
import os,tempfile,time,unittest
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'bench'))
import local,durable

class IdleWorkers(unittest.TestCase):
    def test_empty_worker_pools_do_not_claim_a_writer(self):
        os.environ.update(durable.ENV)
        with tempfile.TemporaryDirectory(prefix='c-durable-idle-') as directory:
            with local.server('c',Path(directory),cache=False,verify_log=True) as (database,_,_):
                with local.connection(database) as db:
                    self.assertEqual(db.execute('SELECT count(*) FROM campfire_jobs').fetchone()[0],0)
                    db.execute('BEGIN IMMEDIATE')
                    # Longer than C's 10s durable busy timeout. A write-polling idle pool
                    # would emit a durable claim failure and fail the log gate.
                    time.sleep(10.5)
                    db.rollback()
                self.assertEqual(local.request('/up')[0],200)
        print('PASS: empty C worker pools remain read-only across a 10.5s writer lock',flush=True)

if __name__=='__main__':unittest.main(verbosity=2)
