#!/usr/bin/env python3
import base64,hashlib,importlib.util,json,os,sqlite3,tempfile,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('manage',Path(__file__).resolve().parents[1]/'tools/manage.py');manage=importlib.util.module_from_spec(spec);spec.loader.exec_module(manage)
class Operations(unittest.TestCase):
 def test_import_preserves_wal_objects_keys_and_source(self):
  with tempfile.TemporaryDirectory() as temporary:
   root=Path(temporary);source=root/'rails.sqlite3';files=root/'files';files.mkdir()
   config=root/'original.env';config.write_text('SECRET_KEY_BASE='+repr('disposable-original-key-'*4)+'\nVAPID_PRIVATE_KEY=original-private\nVAPID_PUBLIC_KEY=original-public\n')
   raw=b'imported binary attachment\x00\xff';key='abcdef123456';path=files/'ab/cd'/key;path.parent.mkdir(parents=True);path.write_bytes(raw)
   with manage.connect(source) as db:
    db.execute('PRAGMA journal_mode=WAL')
    for name in ['accounts','users','rooms','memberships','messages','sessions','action_text_rich_texts','message_search_index','push_subscriptions']:
     db.execute('CREATE TABLE '+name+' (id INTEGER PRIMARY KEY, body TEXT)')
    db.execute('CREATE TABLE active_storage_blobs(id INTEGER PRIMARY KEY,key TEXT,byte_size INTEGER,checksum TEXT,service_name TEXT)')
    db.execute('CREATE TABLE active_storage_attachments(blob_id INTEGER)')
    db.execute('INSERT INTO active_storage_blobs VALUES(1,?,?,?,?)',(key,len(raw),base64.b64encode(hashlib.md5(raw).digest()).decode(),'local'))
    db.execute('INSERT INTO active_storage_attachments VALUES(1)');db.execute('INSERT INTO messages VALUES(1,?)',('From Rails ✓',));db.commit()
    before=manage.manifest(files)
    manage.import_rails(source,files,root/'imported',config)
    self.assertEqual(manage.manifest(files),before)
    self.assertEqual((root/'imported/files/ab/cd'/key).read_bytes(),raw)
    self.assertIn('original-private',(root/'imported/config.env').read_text())
    with manage.connect(root/'imported/production.sqlite3') as imported:self.assertEqual(imported.execute('SELECT body FROM messages').fetchone()[0],'From Rails ✓')
    self.assertEqual(db.execute('SELECT count(*) FROM messages').fetchone()[0],1)
    self.assertEqual(json.loads((root/'imported/import.json').read_text())['counts']['messages'],1)
    with self.assertRaises(SystemExit):manage.import_rails(source,files,root/'imported',config)
    path.write_bytes(b'corrupted')
    with self.assertRaises(SystemExit):manage.import_rails(source,files,root/'bad',config)
    self.assertFalse((root/'bad').exists());self.assertFalse(list(root.glob('.campfire-import-*')))
    path.write_bytes(raw);(files/'link').symlink_to(path)
    with self.assertRaises(SystemExit):manage.import_rails(source,files,root/'linked',config)
    self.assertFalse((root/'linked').exists())
 def test_backup_restore_and_exclusion(self):
  with tempfile.TemporaryDirectory() as temporary:
   root=Path(temporary);data=root/'data';manage.init(data)
   original=(data/'config.env').read_bytes();manage.init(data);self.assertEqual((data/'config.env').read_bytes(),original)
   self.assertEqual((data/'config.env').stat().st_mode&0o777,0o600)
   with manage.connect(data/'production.sqlite3') as db:
    db.execute('PRAGMA journal_mode=WAL');db.execute('CREATE TABLE messages (id INTEGER PRIMARY KEY, body TEXT)');db.execute('INSERT INTO messages VALUES (1,?)',('Preserved chat ✓',))
   (data/'files/ab/cd').mkdir(parents=True);(data/'files/ab/cd/abcdef').write_bytes(bytes(range(256)))
   with manage.stopped(data):
    with self.assertRaises(SystemExit):manage.backup(data,root/'blocked')
   manage.backup(data,root/'backup');manage.restore(root/'backup',root/'restored')
   with manage.connect(root/'restored/production.sqlite3') as db:self.assertEqual(db.execute('SELECT body FROM messages').fetchone()[0],'Preserved chat ✓')
   self.assertEqual((root/'restored/config.env').read_bytes(),original);self.assertEqual((root/'restored/files/ab/cd/abcdef').read_bytes(),bytes(range(256)))
   (root/'backup/files/ab/cd/abcdef').write_bytes(b'corruption')
   with self.assertRaises(SystemExit):manage.restore(root/'backup',root/'bad')
   with self.assertRaises(SystemExit):manage.restore(root/'backup',root/'restored')
if __name__=='__main__':unittest.main(verbosity=2)
