#!/usr/bin/env python3
"""Offline operations only; the HTTP/chat application runs in compiled Mojo."""
import argparse,base64,contextlib,fcntl,hashlib,json,os,re,secrets,shlex,shutil,sqlite3,subprocess,tempfile
from pathlib import Path

SCHEMA = json.loads(Path(__file__).with_name('schema_contract.json').read_text())

def sync_directory(path):
    fd=os.open(path,os.O_RDONLY|os.O_DIRECTORY)
    try:os.fsync(fd)
    finally:os.close(fd)

def sync_tree(folder):
    for path in folder.rglob('*'):
        if path.is_symlink():raise SystemExit('Symlinks are not permitted in application data.')
        if path.is_file():
            with path.open('rb') as stream:os.fsync(stream.fileno())
    for path in sorted((p for p in folder.rglob('*') if p.is_dir()),key=lambda p:len(p.parts),reverse=True):sync_directory(path)
    sync_directory(folder)

def validate_schema(db,allow_upgrade=True):
    tables={row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if 'schema_migrations' in tables:
        version=db.execute("SELECT coalesce(max(version),'0') FROM schema_migrations").fetchone()[0]
        if version>SCHEMA['maximum_rails_version']:raise SystemExit('Unsupported newer Rails schema; upgrade Mojo first.')
    for table,columns in SCHEMA['tables'].items():
        present={row[1] for row in db.execute('PRAGMA table_info('+table+')')}
        missing=set(columns)-present
        if allow_upgrade:missing-=set(SCHEMA['upgradable_columns'].get(table,[]))
        if missing:raise SystemExit('Unsupported Campfire schema: missing '+table+'.'+sorted(missing)[0]+'. Upgrade the source with Rails first.')

def migrate_database(db):
    validate_schema(db)
    db.execute('BEGIN IMMEDIATE')
    try:
        columns={row[1] for row in db.execute('PRAGMA table_info(rooms)')}
        if 'messages_count' not in columns:db.execute('ALTER TABLE rooms ADD COLUMN messages_count INTEGER NOT NULL DEFAULT 0')
        db.execute('UPDATE rooms SET messages_count=(SELECT count(*) FROM messages WHERE room_id=rooms.id)')
        for name,sql in SCHEMA['message_count_triggers'].items():
            db.execute('DROP TRIGGER IF EXISTS '+name)
            db.execute('CREATE TRIGGER '+name+' '+sql)
        for column in ['created_at','updated_at']:db.execute('CREATE INDEX IF NOT EXISTS index_messages_on_room_id_and_'+column+' ON messages(room_id,'+column+')')
        db.execute('CREATE TABLE IF NOT EXISTS schema_migrations(version VARCHAR NOT NULL PRIMARY KEY)')
        db.executemany('INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)',[(v,) for v in SCHEMA['versions']])
        validate_schema(db,False)
        db.commit()
    except BaseException:
        db.rollback()
        raise

def collect_garbage(data):
    # Stop/exclude the server: an in-flight upload may not have its blob row yet.
    with stopped(data),connect(data/'production.sqlite3') as db:
        validate_schema(db)
        files=data/'files'
        manifest(files)
        keys={row[0] for row in db.execute('SELECT key FROM active_storage_blobs')}
        db.execute("CREATE TABLE IF NOT EXISTS mojo_file_purges(key TEXT PRIMARY KEY,attempts INTEGER NOT NULL DEFAULT 0,available_at INTEGER NOT NULL DEFAULT (unixepoch()),error TEXT)")
        for path in files.rglob('*'):
            key=path.name
            if path.is_file() and re.fullmatch('[A-Za-z0-9_-]{4,128}',key) and path.relative_to(files)==Path(key[:2])/key[2:4]/key and key not in keys:
                db.execute('INSERT OR IGNORE INTO mojo_file_purges(key) VALUES(?)',(key,))
        db.commit()
        removed=0
        for key, in db.execute('SELECT key FROM mojo_file_purges').fetchall():
            if key in keys:raise SystemExit('A purge key is still referenced; refusing to delete it.')
            if not re.fullmatch('[A-Za-z0-9_-]{4,128}',key):raise SystemExit('Invalid cleanup key.')
            path=files/key[:2]/key[2:4]/key
            path.unlink(missing_ok=True)
            if path.parent.exists():sync_directory(path.parent)
            db.execute('DELETE FROM mojo_file_purges WHERE key=?',(key,));db.commit();removed+=1
        return removed


@contextlib.contextmanager
def connect(*args,**kwargs):
    with contextlib.closing(sqlite3.connect(*args,**kwargs)) as db:
        with db:yield db

@contextlib.contextmanager
def stopped(data):
    with (data/'production.sqlite3.mojo.lock').open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise SystemExit('Stop Campfire before this operation so the database and attachments stay consistent.')
        yield

def private_write(path,text):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as out:
        out.write(text);out.flush();os.fsync(out.fileno())
    sync_directory(path.parent)

def init(data):
    data.mkdir(parents=True,exist_ok=True,mode=0o700)
    config=data/'config.env'
    if config.exists():return
    with tempfile.TemporaryDirectory(prefix='campfire-keys-') as temp:
        pem=Path(temp)/'vapid.pem'
        subprocess.run(['openssl','ecparam','-name','prime256v1','-genkey','-noout','-out',str(pem)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        dump=subprocess.run(['openssl','ec','-in',str(pem),'-text','-noout'],check=True,capture_output=True,text=True).stdout
        def key_between(start,end):
            value=dump.split(start,1)[1].split(end,1)[0]
            return base64.urlsafe_b64encode(bytes.fromhex(re.sub(r'[^0-9a-f]','',value))).decode().rstrip('=')
        values={
            'SECRET_KEY_BASE':os.environ.get('SECRET_KEY_BASE') or secrets.token_hex(64),
            'VAPID_PRIVATE_KEY':os.environ.get('VAPID_PRIVATE_KEY') or key_between('priv:','pub:'),
            'VAPID_PUBLIC_KEY':os.environ.get('VAPID_PUBLIC_KEY') or key_between('pub:','ASN1 OID:'),
            'VAPID_SUBJECT':os.environ.get('VAPID_SUBJECT','mailto:admin@example.invalid'),
        }
        if bool(os.environ.get('VAPID_PRIVATE_KEY'))!=bool(os.environ.get('VAPID_PUBLIC_KEY')):
            raise SystemExit('Supply both VAPID keys together, or neither.')
        if len(values['SECRET_KEY_BASE'])<32:raise SystemExit('SECRET_KEY_BASE must have at least 32 bytes.')
        private_write(config,''.join(k+'='+shlex.quote(v)+'\n' for k,v in values.items()))

def manifest(folder):
    values={}
    for path in sorted(folder.rglob('*')):
        if path.is_symlink():raise SystemExit('Symlinks are not permitted in an archive.')
        if path.is_file() and path.name!='backup.json':
            with path.open('rb') as stream:values[str(path.relative_to(folder))]=hashlib.file_digest(stream,'sha256').hexdigest()
    return values

def backup(data,destination):
    if destination.exists():raise SystemExit('Backup destination already exists.')
    with stopped(data):
        destination.mkdir(parents=True,mode=0o700)
        try:
            with connect(data/'production.sqlite3') as source,connect(destination/'production.sqlite3') as target:
                source.backup(target)
                if target.execute('PRAGMA integrity_check').fetchone()[0]!='ok':raise SystemExit('Database integrity check failed.')
            shutil.copy2(data/'config.env',destination/'config.env')
            if (data/'import.json').exists():shutil.copy2(data/'import.json',destination/'import.json')
            if (data/'files').exists():shutil.copytree(data/'files',destination/'files')
            private_write(destination/'backup.json',json.dumps({'format':1,'sha256':manifest(destination)},indent=2)+'\n')
            sync_tree(destination)
            sync_directory(destination.parent)
        except BaseException:
            shutil.rmtree(destination)
            raise

def restore(source,data):
    if data.exists() and any(data.iterdir()):raise SystemExit('Restore requires an empty destination; existing data will not be overwritten.')
    record=json.loads((source/'backup.json').read_text())
    if record.get('format')!=1 or record.get('sha256')!=manifest(source):raise SystemExit('Backup verification failed.')
    data.parent.mkdir(parents=True,exist_ok=True)
    temporary=Path(tempfile.mkdtemp(prefix='.campfire-restore-',dir=data.parent))
    try:
        shutil.copytree(source,temporary,dirs_exist_ok=True,ignore=shutil.ignore_patterns('backup.json'))
        with connect(temporary/'production.sqlite3') as db:
            if db.execute('PRAGMA integrity_check').fetchone()[0]!='ok':raise SystemExit('Restored database failed its integrity check.')
        sync_tree(temporary)
        if data.exists():data.rmdir()
        temporary.rename(data)
        sync_directory(data.parent)
    finally:
        if temporary.exists():shutil.rmtree(temporary)


def verify_database(db,files=None,allow_existing_orphans=False):
    foreign=db.execute('PRAGMA foreign_key_check').fetchall()
    if db.execute('PRAGMA integrity_check').fetchall()!=[('ok',)] or (foreign and not allow_existing_orphans):
        raise SystemExit('Database integrity check failed.')
    validate_schema(db)
    if files is None:return
    for key,size,checksum,service,attached in db.execute('SELECT b.key,b.byte_size,b.checksum,b.service_name,EXISTS(SELECT 1 FROM active_storage_attachments a WHERE a.blob_id=b.id) FROM active_storage_blobs b'):
        if service!='local':raise SystemExit('Import supports the original local Disk service; export remote objects to local storage first.')
        if not re.fullmatch('[A-Za-z0-9_-]{4,128}',key):raise SystemExit('Invalid Active Storage object key.')
        path=files/key[:2]/key[2:4]/key
        # An uncompleted direct upload may have a database row but no file yet.
        if not path.exists() and not attached:continue
        if not path.is_file() or path.is_symlink() or path.stat().st_size!=size:raise SystemExit('An attachment is missing or its size does not match the database.')
        if checksum:
            with path.open('rb') as stream:actual=base64.b64encode(hashlib.file_digest(stream,'md5').digest()).decode()
            if actual!=checksum:raise SystemExit('An attachment checksum does not match the database.')

def source_state(database):
    state={}
    for path in [database,Path(str(database)+'-wal')]:
        if path.exists():
            with path.open('rb') as stream:state[path.name]=hashlib.file_digest(stream,'sha256').hexdigest()
        else:state[path.name]=None
    return state

def import_rails(source,files,data,config=None,allow_existing_orphans=False):
    """Copy a stopped Rails/C/Rust installation; never migrate the source in place."""
    if data.exists():raise SystemExit('Import requires a new destination; existing data will not be overwritten.')
    if not source.is_file() or not files.is_dir():raise SystemExit('Supply an existing database and local Disk storage directory.')
    if data==files or files in data.parents or data in files.parents:raise SystemExit('Import destination must be separate from the source storage.')
    keys={k:os.environ[k] for k in ['SECRET_KEY_BASE','VAPID_PRIVATE_KEY','VAPID_PUBLIC_KEY','VAPID_SUBJECT'] if k in os.environ}
    if config:
        for line in config.read_text().splitlines():
            if not line.strip() or line.lstrip().startswith('#'):continue
            name,separator,value=line.partition('=')
            if not separator or name not in {'SECRET_KEY_BASE','VAPID_PRIVATE_KEY','VAPID_PUBLIC_KEY','VAPID_SUBJECT'}:raise SystemExit('Key file must contain only supported KEY=value assignments.')
            parsed=shlex.split(value)
            if len(parsed)!=1:raise SystemExit('Invalid key file assignment.')
            keys[name]=parsed[0]
    if len(keys.get('SECRET_KEY_BASE',''))<32:raise SystemExit('Import requires the original SECRET_KEY_BASE to preserve sessions and signed attachments.')
    data.parent.mkdir(parents=True,exist_ok=True)
    temporary=Path(tempfile.mkdtemp(prefix='.campfire-import-',dir=data.parent))
    try:
        # Snapshot the stopped source with plain reads, including its committed
        # WAL. SQLite may need writable -shm even for mode=ro; it must only create
        # those files beside our private copy, never in the original directory.
        version=source_state(source)
        snapshot=temporary/'.source'
        snapshot.mkdir()
        copied=snapshot/source.name
        shutil.copyfile(source,copied)
        wal=Path(str(source)+'-wal')
        if wal.exists():shutil.copyfile(wal,Path(str(copied)+'-wal'))
        with connect(copied) as original:
            verify_database(original,allow_existing_orphans=allow_existing_orphans)
            source_orphans=original.execute('PRAGMA foreign_key_check').fetchall()
            subscriptions=original.execute('SELECT count(*) FROM push_subscriptions').fetchone()[0]
            if subscriptions and not (keys.get('VAPID_PRIVATE_KEY') and keys.get('VAPID_PUBLIC_KEY')):
                raise SystemExit('Existing push subscriptions require both original VAPID keys.')
            manifest(files) # Reject links, including a directory symlink.
            with connect(temporary/'production.sqlite3') as target:original.backup(target)
            shutil.copytree(files,temporary/'files')
            with connect(temporary/'production.sqlite3') as target:
                migrate_database(target)
                verify_database(target,temporary/'files',allow_existing_orphans)
                if target.execute('PRAGMA foreign_key_check').fetchall()!=source_orphans:
                    raise SystemExit('Foreign key state changed during import.')
                counts={table:target.execute('SELECT count(*) FROM '+table).fetchone()[0] for table in ['users','rooms','messages','active_storage_blobs']}
            if source_state(source)!=version:
                raise SystemExit('Source database changed during import. Stop all source writers and retry.')
        shutil.rmtree(snapshot)
        previous=os.environ.copy()
        try:
            os.environ.update(keys)
            init(temporary)
        finally:
            os.environ.clear();os.environ.update(previous)
        private_write(temporary/'import.json',json.dumps({'format':1,'source_database_sha256':hashlib.sha256((temporary/'production.sqlite3').read_bytes()).hexdigest(),'counts':counts,'preserved_source_foreign_key_violations':source_orphans},indent=2)+'\n')
        if data.exists():raise SystemExit('Import destination appeared during copying; refusing to overwrite it.')
        sync_tree(temporary)
        temporary.rename(data)
        sync_directory(data.parent)
        if source_orphans:print('Preserved existing foreign-key violations:',len(source_orphans),'; details are recorded in import.json.')
    finally:
        if temporary.exists():shutil.rmtree(temporary)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['init','backup','restore','import-rails','check','retry-jobs','gc-files'])
    parser.add_argument('--data',type=Path,default=Path(os.environ.get('CAMPFIRE_DATA','storage')))
    parser.add_argument('--destination',type=Path);parser.add_argument('--source',type=Path)
    parser.add_argument('--files',type=Path,help='Original Rails storage/files directory for import-rails')
    parser.add_argument('--config-env',type=Path,help='Original signing and VAPID keys, as KEY=value assignments')
    parser.add_argument('--allow-existing-orphans',action='store_true',help='Preserve and report existing foreign-key violations during import instead of rejecting the source')
    args=parser.parse_args();data=args.data.resolve()
    if args.command=='init':init(data)
    elif args.command=='backup':
        if not args.destination:parser.error('--destination is required')
        backup(data,args.destination.resolve())
    elif args.command=='restore':
        if not args.source:parser.error('--source is required')
        restore(args.source.resolve(),data)
    elif args.command=='import-rails':
        if not args.source or not args.files:parser.error('--source (database) and --files (Disk root) are required')
        import_rails(args.source.resolve(),args.files.resolve(),data,args.config_env,args.allow_existing_orphans)
    elif args.command=='gc-files':print('Recovered orphan/deferred files:',collect_garbage(data))
    elif args.command=='check':
        with connect(data/'production.sqlite3') as db:
            result=db.execute('PRAGMA integrity_check').fetchall();foreign=db.execute('PRAGMA foreign_key_check').fetchall()
            imported=data/'import.json'
            allowed={tuple(row) for row in json.loads(imported.read_text()).get('preserved_source_foreign_key_violations',[])} if imported.exists() else set()
            if result!=[('ok',)] or not set(foreign)<=allowed:raise SystemExit('Database integrity check failed or new foreign-key violations appeared.')
            if foreign:print('Previously accepted source foreign-key violations:',len(foreign))
            validate_schema(db,False)
            print('Database integrity and schema: ok')
            tables={r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if 'mojo_jobs' in tables:print('Queued / failed jobs:',db.execute('SELECT count(*),coalesce(sum(failed),0) FROM mojo_jobs').fetchone())
            if 'mojo_file_purges' in tables:print('Deferred file deletions:',db.execute('SELECT count(*) FROM mojo_file_purges').fetchone()[0])
    elif args.command=='retry-jobs':
        with stopped(data),connect(data/'production.sqlite3') as db:
            db.execute('UPDATE mojo_jobs SET failed=0,attempts=0,lease_until=0,available_at=unixepoch(),error=NULL WHERE failed=1')
    if args.command!='check':print(args.command+' completed')

if __name__=='__main__':main()
