# Generated from the original db/schema.rb by tools/update_schema_contract.py.
from database import Database


def validate(mut db: Database, allow_upgrade: Bool = True) raises:
    if db.scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")=="0":
        return
    if db.scalar("SELECT 1 FROM sqlite_master WHERE type='table' AND name='schema_migrations'")=="1":
        var version = db.scalar("SELECT coalesce(max(version),'0') FROM schema_migrations")
        if version>"20261007190000":
            raise Error("Unsupported newer Rails schema; upgrade the Mojo application before opening this database")
    var tables = List[Tuple[String,String]]([
        ("accounts","id,created_at,custom_styles,join_code,name,settings,singleton_guard,updated_at"),
        ("action_text_rich_texts","id,body,created_at,name,record_id,record_type,updated_at"),
        ("active_storage_attachments","id,blob_id,created_at,name,record_id,record_type"),
        ("active_storage_blobs","id,byte_size,checksum,content_type,created_at,filename,key,metadata,service_name"),
        ("active_storage_variant_records","id,blob_id,variation_digest"),
        ("bans","id,created_at,ip_address,updated_at,user_id"),
        ("boosts","id,booster_id,content,created_at,message_id,updated_at"),
        ("memberships","id,connected_at,connections,created_at,involvement,room_id,unread_at,updated_at,user_id"),
        ("messages","id,client_message_id,created_at,creator_id,room_id,updated_at"),
        ("push_subscriptions","id,auth_key,created_at,endpoint,p256dh_key,updated_at,user_agent,user_id"),
        ("rooms","id,created_at,creator_id,name,type,updated_at,messages_count"),
        ("searches","id,created_at,query,updated_at,user_id"),
        ("sessions","id,created_at,ip_address,last_active_at,token,updated_at,user_agent,user_id"),
        ("users","id,bio,bot_token,created_at,email_address,name,password_digest,role,status,updated_at"),
        ("webhooks","id,created_at,updated_at,url,user_id"),
        ("message_search_index","body"),
    ])
    for table in tables:
        var present = Dict[String,Bool]()
        for column in db.rows("PRAGMA table_info("+table[0]+")"):
            present[column[1]] = True
        for column in table[1].split(","):
            var name = String(column)
            if name not in present and not (allow_upgrade and table[0]=="rooms" and name=="messages_count"):
                raise Error("Unsupported Campfire schema: missing "+table[0]+"."+name+"; upgrade the source with Rails first")
