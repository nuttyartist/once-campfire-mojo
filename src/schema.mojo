# Schema DDL from the Rails-compatible shared database (no seed data).
from database import Database
import schema_contract

def initialize(mut db: Database) raises:
    # Refuse unsupported source shapes before creating tables or changing rows.
    schema_contract.validate(db)
    _ = db.rows("BEGIN IMMEDIATE")
    try:
        migrate(db)
        schema_contract.validate(db,False)
        _ = db.rows("COMMIT")
    except e:
        _ = db.rows("ROLLBACK")
        raise e^


def migrate(mut db: Database) raises:
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"accounts\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"created_at\" datetime(6) NOT NULL, \"custom_styles\" text, \"join_code\" varchar NOT NULL, \"name\" varchar NOT NULL, \"settings\" json, \"singleton_guard\" integer DEFAULT 0 NOT NULL, \"updated_at\" datetime(6) NOT NULL)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"action_text_rich_texts\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"body\" text, \"created_at\" datetime(6) NOT NULL, \"name\" varchar NOT NULL, \"record_id\" bigint NOT NULL, \"record_type\" varchar NOT NULL, \"updated_at\" datetime(6) NOT NULL)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"active_storage_blobs\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"byte_size\" bigint NOT NULL, \"checksum\" varchar, \"content_type\" varchar, \"created_at\" datetime(6) NOT NULL, \"filename\" varchar NOT NULL, \"key\" varchar NOT NULL, \"metadata\" text, \"service_name\" varchar NOT NULL)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"memberships\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"connected_at\" datetime(6), \"connections\" integer DEFAULT 0 NOT NULL, \"created_at\" datetime(6) NOT NULL, \"involvement\" varchar DEFAULT 'mentions', \"room_id\" integer NOT NULL, \"unread_at\" datetime(6), \"updated_at\" datetime(6) NOT NULL, \"user_id\" integer NOT NULL)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"rooms\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"created_at\" datetime(6) NOT NULL, \"creator_id\" bigint NOT NULL, \"name\" varchar, \"type\" varchar NOT NULL, \"updated_at\" datetime(6) NOT NULL)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"users\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"bio\" text, \"bot_token\" varchar, \"created_at\" datetime(6) NOT NULL, \"email_address\" varchar, \"name\" varchar NOT NULL, \"password_digest\" varchar, \"role\" integer DEFAULT 0 NOT NULL, \"status\" integer DEFAULT 0 NOT NULL, \"updated_at\" datetime(6) NOT NULL)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"active_storage_attachments\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"blob_id\" bigint NOT NULL, \"created_at\" datetime(6) NOT NULL, \"name\" varchar NOT NULL, \"record_id\" bigint NOT NULL, \"record_type\" varchar NOT NULL, CONSTRAINT \"fk_rails_c3b3935057\"\nFOREIGN KEY (\"blob_id\")\n  REFERENCES \"active_storage_blobs\" (\"id\")\n)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"active_storage_variant_records\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"blob_id\" bigint NOT NULL, \"variation_digest\" varchar NOT NULL, CONSTRAINT \"fk_rails_993965df05\"\nFOREIGN KEY (\"blob_id\")\n  REFERENCES \"active_storage_blobs\" (\"id\")\n)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"bans\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"created_at\" datetime(6) NOT NULL, \"ip_address\" varchar NOT NULL, \"updated_at\" datetime(6) NOT NULL, \"user_id\" integer NOT NULL, CONSTRAINT \"fk_rails_070022cd76\"\nFOREIGN KEY (\"user_id\")\n  REFERENCES \"users\" (\"id\")\n)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"boosts\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"booster_id\" integer NOT NULL, \"content\" varchar(16) NOT NULL, \"created_at\" datetime(6) NOT NULL, \"message_id\" integer NOT NULL, \"updated_at\" datetime(6) NOT NULL, CONSTRAINT \"fk_rails_3539c52d73\"\nFOREIGN KEY (\"message_id\")\n  REFERENCES \"messages\" (\"id\")\n)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"messages\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"client_message_id\" varchar NOT NULL, \"created_at\" datetime(6) NOT NULL, \"creator_id\" integer NOT NULL, \"room_id\" integer NOT NULL, \"updated_at\" datetime(6) NOT NULL, CONSTRAINT \"fk_rails_a8db0fb63a\"\nFOREIGN KEY (\"room_id\")\n  REFERENCES \"rooms\" (\"id\")\n, CONSTRAINT \"fk_rails_761a2f12b3\"\nFOREIGN KEY (\"creator_id\")\n  REFERENCES \"users\" (\"id\")\n)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"push_subscriptions\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"auth_key\" varchar, \"created_at\" datetime(6) NOT NULL, \"endpoint\" varchar, \"p256dh_key\" varchar, \"updated_at\" datetime(6) NOT NULL, \"user_agent\" varchar, \"user_id\" integer NOT NULL, CONSTRAINT \"fk_rails_43d43720fc\"\nFOREIGN KEY (\"user_id\")\n  REFERENCES \"users\" (\"id\")\n)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"searches\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"created_at\" datetime(6) NOT NULL, \"query\" varchar NOT NULL, \"updated_at\" datetime(6) NOT NULL, \"user_id\" integer NOT NULL, CONSTRAINT \"fk_rails_e192b86393\"\nFOREIGN KEY (\"user_id\")\n  REFERENCES \"users\" (\"id\")\n)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"sessions\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"created_at\" datetime(6) NOT NULL, \"ip_address\" varchar, \"last_active_at\" datetime(6) NOT NULL, \"token\" varchar NOT NULL, \"updated_at\" datetime(6) NOT NULL, \"user_agent\" varchar, \"user_id\" integer NOT NULL, CONSTRAINT \"fk_rails_758836b4f0\"\nFOREIGN KEY (\"user_id\")\n  REFERENCES \"users\" (\"id\")\n)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"webhooks\" (\"id\" integer PRIMARY KEY AUTOINCREMENT NOT NULL, \"created_at\" datetime(6) NOT NULL, \"updated_at\" datetime(6) NOT NULL, \"url\" varchar, \"user_id\" integer NOT NULL, CONSTRAINT \"fk_rails_51bf96d3bc\"\nFOREIGN KEY (\"user_id\")\n  REFERENCES \"users\" (\"id\")\n)")
    _ = db.rows("CREATE VIRTUAL TABLE IF NOT EXISTS message_search_index USING fts5 (body, tokenize=porter)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"schema_migrations\" (\"version\" varchar NOT NULL PRIMARY KEY)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS \"ar_internal_metadata\" (\"key\" varchar NOT NULL PRIMARY KEY, \"value\" varchar, \"created_at\" datetime(6) NOT NULL, \"updated_at\" datetime(6) NOT NULL)")
    _ = db.rows("CREATE UNIQUE INDEX IF NOT EXISTS \"index_accounts_on_singleton_guard\" ON \"accounts\" (\"singleton_guard\")")
    _ = db.rows("CREATE UNIQUE INDEX IF NOT EXISTS \"index_action_text_rich_texts_uniqueness\" ON \"action_text_rich_texts\" (\"record_type\", \"record_id\", \"name\")")
    _ = db.rows("CREATE UNIQUE INDEX IF NOT EXISTS \"index_active_storage_blobs_on_key\" ON \"active_storage_blobs\" (\"key\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"index_memberships_on_room_id_and_created_at\" ON \"memberships\" (\"room_id\", \"created_at\")")
    _ = db.rows("CREATE UNIQUE INDEX IF NOT EXISTS \"index_memberships_on_room_id_and_user_id\" ON \"memberships\" (\"room_id\", \"user_id\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"index_memberships_on_room_id\" ON \"memberships\" (\"room_id\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"index_memberships_on_user_id\" ON \"memberships\" (\"user_id\")")
    _ = db.rows("CREATE UNIQUE INDEX IF NOT EXISTS \"index_users_on_bot_token\" ON \"users\" (\"bot_token\")")
    _ = db.rows("CREATE UNIQUE INDEX IF NOT EXISTS \"index_users_on_email_address\" ON \"users\" (\"email_address\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"index_active_storage_attachments_on_blob_id\" ON \"active_storage_attachments\" (\"blob_id\")")
    _ = db.rows("CREATE UNIQUE INDEX IF NOT EXISTS \"index_active_storage_attachments_uniqueness\" ON \"active_storage_attachments\" (\"record_type\", \"record_id\", \"name\", \"blob_id\")")
    _ = db.rows("CREATE UNIQUE INDEX IF NOT EXISTS \"index_active_storage_variant_records_uniqueness\" ON \"active_storage_variant_records\" (\"blob_id\", \"variation_digest\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"index_bans_on_ip_address\" ON \"bans\" (\"ip_address\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"index_bans_on_user_id\" ON \"bans\" (\"user_id\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"index_boosts_on_booster_id\" ON \"boosts\" (\"booster_id\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"index_boosts_on_message_id\" ON \"boosts\" (\"message_id\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"index_messages_on_creator_id\" ON \"messages\" (\"creator_id\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"index_messages_on_room_id\" ON \"messages\" (\"room_id\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"idx_on_endpoint_p256dh_key_auth_key_7553014576\" ON \"push_subscriptions\" (\"endpoint\", \"p256dh_key\", \"auth_key\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"index_push_subscriptions_on_user_id\" ON \"push_subscriptions\" (\"user_id\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"index_searches_on_user_id\" ON \"searches\" (\"user_id\")")
    _ = db.rows("CREATE UNIQUE INDEX IF NOT EXISTS \"index_sessions_on_token\" ON \"sessions\" (\"token\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"index_sessions_on_user_id\" ON \"sessions\" (\"user_id\")")
    _ = db.rows("CREATE INDEX IF NOT EXISTS \"index_webhooks_on_user_id\" ON \"webhooks\" (\"user_id\")")
    _ = db.rows("CREATE TABLE IF NOT EXISTS mojo_login_limits (ip TEXT PRIMARY KEY, started INTEGER NOT NULL, attempts INTEGER NOT NULL)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS mojo_jobs (id INTEGER PRIMARY KEY AUTOINCREMENT, message_id INTEGER NOT NULL, hooks INTEGER NOT NULL DEFAULT 1, kind TEXT NOT NULL DEFAULT 'message', attempts INTEGER NOT NULL DEFAULT 0, available_at INTEGER NOT NULL DEFAULT (unixepoch()), lease_until INTEGER NOT NULL DEFAULT 0, error TEXT, failed INTEGER NOT NULL DEFAULT 0)")
    _ = db.rows("CREATE TABLE IF NOT EXISTS campfire_completed_jobs(message_id INTEGER NOT NULL,kind TEXT NOT NULL,PRIMARY KEY(message_id,kind))")
    _ = db.rows("CREATE TABLE IF NOT EXISTS campfire_delivery_receipts(message_id INTEGER NOT NULL,target_id INTEGER NOT NULL,kind TEXT NOT NULL,PRIMARY KEY(message_id,target_id,kind))")
    _ = db.rows("CREATE INDEX IF NOT EXISTS mojo_jobs_available ON mojo_jobs(failed,available_at,lease_until)")
    _ = db.rows("CREATE INDEX IF NOT EXISTS mojo_jobs_ready ON mojo_jobs(id) WHERE failed=0")
    _ = db.rows("CREATE TABLE IF NOT EXISTS mojo_deliveries (message_id INTEGER NOT NULL, kind TEXT NOT NULL, target_id INTEGER NOT NULL, PRIMARY KEY(message_id,kind,target_id))")
    _ = db.rows("CREATE TABLE IF NOT EXISTS mojo_file_purges (key TEXT PRIMARY KEY, attempts INTEGER NOT NULL DEFAULT 0, available_at INTEGER NOT NULL DEFAULT (unixepoch()), error TEXT)")
    var has_kind = False
    for column in db.rows("PRAGMA table_info(mojo_jobs)"):
        if column[1]=="kind":
            has_kind = True
    if not has_kind:
        _ = db.rows("ALTER TABLE mojo_jobs ADD COLUMN kind TEXT NOT NULL DEFAULT 'message'")

    var has_count = False
    for column in db.rows("PRAGMA table_info(rooms)"):
        if column[1]=="messages_count":
            has_count = True
    if not has_count:
        _ = db.rows("ALTER TABLE rooms ADD COLUMN messages_count INTEGER NOT NULL DEFAULT 0")
    _ = db.rows("CREATE INDEX IF NOT EXISTS index_messages_on_room_id_and_created_at ON messages(room_id,created_at)")
    _ = db.rows("CREATE INDEX IF NOT EXISTS index_messages_on_room_id_and_updated_at ON messages(room_id,updated_at)")
    # Match Room::MessagesCount, including bulk/foreign SQL, without callbacks.
    _ = db.rows("UPDATE rooms SET messages_count=(SELECT count(*) FROM messages WHERE room_id=rooms.id)")
    _ = db.rows("DROP TRIGGER IF EXISTS messages_ai_rooms_messages_count")
    _ = db.rows("CREATE TRIGGER messages_ai_rooms_messages_count AFTER INSERT ON messages BEGIN UPDATE rooms SET messages_count=messages_count+1 WHERE id=NEW.room_id; END")
    _ = db.rows("DROP TRIGGER IF EXISTS messages_ad_rooms_messages_count")
    _ = db.rows("CREATE TRIGGER messages_ad_rooms_messages_count AFTER DELETE ON messages BEGIN UPDATE rooms SET messages_count=messages_count-1 WHERE id=OLD.room_id; END")
    _ = db.rows("DROP TRIGGER IF EXISTS messages_au_rooms_messages_count")
    _ = db.rows("CREATE TRIGGER messages_au_rooms_messages_count AFTER UPDATE OF room_id ON messages WHEN OLD.room_id IS NOT NEW.room_id BEGIN UPDATE rooms SET messages_count=messages_count-1 WHERE id=OLD.room_id; UPDATE rooms SET messages_count=messages_count+1 WHERE id=NEW.room_id; END")
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20231215043540"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20231220143106"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20240110071740"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20240115124901"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20240130003150"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20240130213001"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20240131105830"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20240209110503"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20250825100957"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20250825100958"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20250825100959"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20251126092013"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20251126115722"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20251126130131"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20251212154340"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20261004225000"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20261005022000"])
    _ = db.rows("INSERT OR IGNORE INTO schema_migrations(version) VALUES(?)",["20261007190000"])
    _ = db.rows("CREATE TABLE IF NOT EXISTS mojo_schema_migrations(version INTEGER PRIMARY KEY)")
    _ = db.rows("INSERT OR IGNORE INTO mojo_schema_migrations(version) VALUES(1),(2)")
