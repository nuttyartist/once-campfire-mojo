#!/usr/bin/env python3
"""A stalled decoder leaves the SQL writer free; Cable must retain its frames."""
import json, os, re, subprocess, tempfile, threading, time, unittest
from pathlib import Path
from unittest.mock import patch
import full
from full import local, WS
from network_failures import eventually

class MixedWorkloads(unittest.TestCase):
    def test_upload_and_cold_variant_leave_writer_and_cable_available(self):
        with tempfile.TemporaryDirectory(prefix='mojo-mixed-') as temp:
            root=Path(temp); entered=root/'decoder-entered'; library=root/'faults.so'
            subprocess.run(['clang','-shared','-fPIC',str(Path(__file__).with_name('network_faults.c')),'-o',str(library),'-ldl'],check=True)
            with patch.dict(os.environ,{'LD_PRELOAD':str(library),'CAMPFIRE_TEST_MEDIA_ENTERED':str(entered)}), local.server('mojo',root/'logs',cache=False) as (database,runtime,_):
                labels=json.loads((local.SEED/'labels.json').read_text())
                helper=full.Full('test_04_avatar_real_decode');helper.cookie=local.login(labels);helper.rid=labels['rooms.watercooler']
                page=helper.request(f'/rooms/{helper.rid}')[2]
                signed=re.search(rb'channel="RoomMessagesChannel"[^>]*signed-stream-name="([^\"]+)"',page).group(1).decode()
                ws=WS(helper.cookie);self.addCleanup(ws.close)
                ident=json.dumps({'channel':'RoomMessagesChannel','signed_stream_name':signed},separators=(',',':'))
                ws.send({'command':'subscribe','identifier':ident})
                self.assertEqual(ws.until(lambda x:x.get('type') in ('confirm_subscription','reject_subscription'))['type'],'confirm_subscription')
                image=(local.VERIFICATION/'test/fixtures/avatar.webp').read_bytes()
                def run_while_writing(operation,expected):
                    entered.unlink(missing_ok=True)
                    replies=[]; errors=[]
                    def execute():
                        try: replies.append(operation())
                        except Exception as error: errors.append(repr(error))
                    thread=threading.Thread(target=execute);thread.start()
                    eventually(entered.exists,'decoder did not enter the fault window')
                    started=time.monotonic();marker='Concurrent writer '+os.urandom(8).hex()
                    reply=helper.request(f'/rooms/{helper.rid}/messages','POST',fields={'message[body]':marker})
                    self.assertEqual(reply[0],200,reply[2])
                    self.assertLess(time.monotonic()-started,1.5,'writer waited for the three-second decoder stall')
                    thread.join(12);self.assertFalse(thread.is_alive());self.assertFalse(errors,errors)
                    # A socket assigned to the decoding HTTP worker resumes when
                    # that worker returns to its event loop; its frames survive.
                    self.assertIn(marker,ws.until(lambda x:'message' in x and marker in str(x['message']))['message'])
                    self.assertEqual(replies[0][0],expected,replies[0][2])
                    return replies[0]
                upload=run_while_writing(lambda:helper.multipart(f'/rooms/{helper.rid}/messages',{}, {'message[attachment]':('mixed.webp','image/webp',image)}),200)
                mid=re.search(rb'data-message-id="(\d+)"',upload[2]).group(1).decode()
                url=re.search(rb'src="(/rails/active_storage/representations/[^\"]+)"',upload[2]).group(1).decode().replace('&amp;','&')
                with local.connection(database) as db:
                    blob=db.execute("SELECT blob_id FROM active_storage_attachments WHERE record_type='Message' AND record_id=?",(mid,)).fetchone()[0]
                    variants=[row[0] for row in db.execute('SELECT id FROM active_storage_variant_records WHERE blob_id=?',(blob,))]
                    self.assertTrue(variants,'upload did not persist its prepared thumbnail')
                    for variant in variants:
                        db.execute("DELETE FROM active_storage_attachments WHERE record_type='ActiveStorage::VariantRecord' AND record_id=?",(variant,))
                    db.execute('DELETE FROM active_storage_variant_records WHERE blob_id=?',(blob,))
                variant=run_while_writing(lambda:helper.request(url),200)
                self.assertEqual(variant[1]['Content-Type'],'image/webp')
                # The preflight files have been admitted atomically with the message.
                with local.connection(database) as db:
                    self.assertEqual(db.execute('PRAGMA integrity_check').fetchone(),('ok',))
                    self.assertEqual(db.execute('SELECT count(*) FROM active_storage_variant_records WHERE blob_id=?',(blob,)).fetchone()[0],1)

    def test_failed_admission_rolls_back_prepared_objects_and_records(self):
        with tempfile.TemporaryDirectory(prefix='mojo-media-rollback-') as temp, local.server('mojo',Path(temp),cache=False) as (database,runtime,_):
            labels=json.loads((local.SEED/'labels.json').read_text())
            helper=full.Full('test_04_avatar_real_decode');helper.cookie=local.login(labels);helper.rid=labels['rooms.watercooler']
            before={str(path.relative_to(runtime/'files')) for path in (runtime/'files').rglob('*') if path.is_file()}
            with local.connection(database) as db:
                counts=[db.execute('SELECT count(*) FROM '+table).fetchone()[0] for table in ['messages','active_storage_blobs','active_storage_variant_records','mojo_jobs']]
                db.execute("CREATE TRIGGER reject_variant BEFORE INSERT ON active_storage_variant_records BEGIN SELECT RAISE(ABORT,'injected admission failure'); END")
            image=(local.VERIFICATION/'test/fixtures/avatar.webp').read_bytes()
            response=helper.multipart(f'/rooms/{helper.rid}/messages',{}, {'message[attachment]':('rolled-back.webp','image/webp',image)})
            self.assertEqual(response[0],500,response[2])
            with local.connection(database) as db:
                self.assertEqual([db.execute('SELECT count(*) FROM '+table).fetchone()[0] for table in ['messages','active_storage_blobs','active_storage_variant_records','mojo_jobs']],counts)
            self.assertEqual({str(path.relative_to(runtime/'files')) for path in (runtime/'files').rglob('*') if path.is_file()},before)

if __name__=='__main__':unittest.main(verbosity=2)
