#!/usr/bin/env python3
"""Wait for browser-created durable jobs before removing its disposable volume.

Executed by Python inside the production container; no application code changes.
"""
import os
import sqlite3
import time

with sqlite3.connect('file:' + os.environ['DATABASE_PATH'] + '?mode=ro', uri=True) as db:
    deadline = time.monotonic() + 180
    while True:
        jobs = db.execute('SELECT failed,error,attempts FROM mojo_jobs').fetchall()
        if any(failed or error is not None or attempts > 1 for failed, error, attempts in jobs):
            raise RuntimeError('Browser run has failed or retried jobs')
        if not jobs:
            print('PASS: browser durable jobs drained with no failures')
            break
        if time.monotonic() > deadline:
            raise RuntimeError('Browser durable jobs did not drain')
        time.sleep(.05)
