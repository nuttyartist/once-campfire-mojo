#!/usr/bin/env python3
import base64,hashlib,importlib.util,json,os,shutil,sqlite3,tempfile,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('manage',Path(__file__).resolve().parents[1]/'tools/manage.py');manage=importlib.util.module_from_spec(spec);spec.loader.exec_module(manage)
class Operations(unittest.TestCase):
 def test_import_preserves_wal_objects_keys_and_source(self):
  with tempfile.TemporaryDirectory() as temporary:
   root=Path(temporary);source=root/'rails.sqlite3';files=root/'files';files.mkdir()
   config=root/'original.env';config.write_text('SECRET_KEY_BASE='+repr('disposable-original-key-'*4)+'\nVAPID_PRIVATE_KEY=original-private\nVAPID_PUBLIC_KEY=original-public\n')
   seed=Path(os.environ.get('CAMPFIRE_WORKSPACE','/workspace'))/'once-campfire-verification/fixtures/default'
   shutil.copytree(seed/'storage',files,dirs_exist_ok=True)
   with manage.connect(seed/'db/production.sqlite3') as original,manage.connect(source) as target:original.backup(target)
   raw=b'imported binary attachment\x00\xff';key='abcdef123456';path=files/'ab/cd'/key;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(raw)
   with manage.connect(source) as db:
    db.execute('PRAGMA journal_mode=WAL')
    count=db.execute('SELECT count(*) FROM messages').fetchone()[0]
    mid=db.execute('SELECT id FROM messages LIMIT 1').fetchone()[0]
    blob=db.execute("INSERT INTO active_storage_blobs(key,filename,content_type,metadata,byte_size,checksum,created_at,service_name) VALUES(?,'import.bin','application/octet-stream','{}',?,?,datetime('now'),'local') RETURNING id",(key,len(raw),base64.b64encode(hashlib.md5(raw).digest()).decode())).fetchone()[0]
    db.execute("INSERT INTO active_storage_attachments(name,record_type,record_id,blob_id,created_at) VALUES('attachment','Message',?,?,datetime('now'))",(mid,blob));db.commit()
    before=manage.manifest(files)
    manage.import_rails(source,files,root/'imported',config,allow_existing_orphans=True)
    self.assertEqual(manage.manifest(files),before)
    self.assertEqual((root/'imported/files/ab/cd'/key).read_bytes(),raw)
    self.assertIn('original-private',(root/'imported/config.env').read_text())
    with manage.connect(root/'imported/production.sqlite3') as imported:
     self.assertEqual(imported.execute('SELECT * FROM messages ORDER BY id').fetchall(),db.execute('SELECT * FROM messages ORDER BY id').fetchall())
     self.assertEqual(imported.execute("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'messages_a%_rooms_messages_count'").fetchone()[0],3)
    self.assertEqual(db.execute('SELECT count(*) FROM messages').fetchone()[0],count)
    self.assertEqual(json.loads((root/'imported/import.json').read_text())['counts']['messages'],count)
    manage.backup(root/'imported',root/'copy-backup')
    manage.restore(root/'copy-backup',root/'copy-restored')
    self.assertEqual((root/'copy-restored/import.json').read_bytes(),(root/'imported/import.json').read_bytes())
    with self.assertRaises(SystemExit):manage.import_rails(source,files,root/'imported',config)
    path.write_bytes(b'corrupted')
    with self.assertRaises(SystemExit):manage.import_rails(source,files,root/'bad',config,allow_existing_orphans=True)
    self.assertFalse((root/'bad').exists());self.assertFalse(list(root.glob('.campfire-import-*')))
    path.write_bytes(raw);(files/'link').symlink_to(path)
    with self.assertRaises(SystemExit):manage.import_rails(source,files,root/'linked',config,allow_existing_orphans=True)
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
