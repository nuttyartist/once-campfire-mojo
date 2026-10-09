#!/usr/bin/env python3
"""Regression: forked workers must shut down without parent-runtime teardown errors."""
import json,sys,tempfile,time,unittest,urllib.parse
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'bench'))
import local

class Lifecycle(unittest.TestCase):
 def test_shutdown_after_message_and_job_drain(self):
  with tempfile.TemporaryDirectory(prefix='mojo-lifecycle-') as tmp:
   dest=Path(tmp)
   with local.server('mojo',dest,verify_log=True) as (db,runtime,_):
    labels=json.loads((local.SEED/'labels.json').read_text());cookie=local.login(labels)
    for i in range(5):
     status,_,_,_=local.request(f'/rooms/{labels["rooms.hq"]}/messages',cookie,'POST',urllib.parse.urlencode({'message[body]':f'Shutdown regression {i}'}),{'Content-Type':'application/x-www-form-urlencoded'})
     self.assertEqual(status,200)
    deadline=time.monotonic()+5
    while True:
     stats=json.loads(local.request('/_bench/stats')[2])
     if stats['queued']==stats['completed']:break
     self.assertLess(time.monotonic(),deadline,stats);time.sleep(.02)
    self.assertEqual(stats['errors'],0)
    stopped=time.monotonic()
   self.assertLess(time.monotonic()-stopped,3,'graceful shutdown stalled')

if __name__=='__main__':unittest.main(verbosity=2)
