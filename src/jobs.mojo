# Durable notification and bot webhook delivery. Routing and payload policy live in Mojo.
from std.ffi import external_call
from std.os import getenv
from database import Database
from crypto import json_string, base64, Signer
import richtext
import pubsub
import webpush
import network
import views
import message_actions
import storage
from parameters import Upload
from text import token


def count(index: Int, delta: Int = 1):
    _ = external_call["metric_add", Int](index, delta)


def trace(kind: String, value: String) raises:
    var path = getenv("MOJO_AUDIT_PATH", "")
    if path == "":
        return
    var line = '{"kind":' + json_string(kind) + ',"value":' + value + "}\n"
    if (
        external_call["file_append", Int](
            path.as_c_string_span(),
            line.as_bytes().unsafe_ptr(),
            line.byte_length(),
        )
        != 0
    ):
        raise Error("Audit write failed")


def stats() -> String:
    var names = List[String](
        [
            "queued",
            "completed",
            "notifications",
            "rejected_endpoints",
            "broadcasts",
            "unread_broadcasts",
            "errors",
            "queue_full",
            "webhook_candidates",
            "unsupported_deliveries",
        ]
    )
    var items = List[String]()
    for i in range(len(names)):
        items.append(
            '"' + names[i] + '":' + String(external_call["metric_get", Int](i))
        )
    return "{" + ",".join(items) + "}"


def push_endpoint_permitted(endpoint: String) -> Bool:
    var pieces = endpoint.split("://", maxsplit=1)
    if len(pieces) != 2 or String(pieces[0]).lower() != "https":
        return False
    var rest = String(pieces[1])
    var authority = String(rest.split("/")[0])
    var unquery = String(authority.split("?")[0])
    var unfragment = String(unquery.split("#")[0])
    authority = unfragment^
    var bits = authority.split(":")
    if len(bits) > 2 or (len(bits) == 2 and String(bits[1]) != "443"):
        return False
    var host = String(bits[0]).lower()
    for domain in [
        "jmt17.google.com",
        "fcm.googleapis.com",
        "updates.push.services.mozilla.com",
        "web.push.apple.com",
        "notify.windows.com",
    ]:
        if host == domain or host.endswith("." + domain):
            return True
    return False


def truncate_json(s: String, limit: Int) -> String:
    var out = String()
    var used = 0
    for cp in s.codepoints():
        var c = String(cp)
        var size = json_string(c).byte_length() - 2
        if used + size > limit - 3:
            if json_string(s).byte_length() - 2 <= limit:
                return s
            return out + "…"
        used += size
        out += c
    return out^


def process(mut db: Database, mid: String, hooks: Bool = True, job_id: String = "") raises:
    var rows = db.rows(
        (
            "SELECT"
            " m.room_id,m.creator_id,r.type,coalesce(r.name,''),u.name,coalesce(rt.body,'')"
            " FROM messages m JOIN rooms r ON r.id=m.room_id JOIN users u ON"
            " u.id=m.creator_id LEFT JOIN action_text_rich_texts rt ON"
            " rt.record_type='Message' AND rt.record_id=m.id AND rt.name='body'"
            " WHERE m.id=?"
        ),
        [mid],
    )
    if len(rows) == 0:
        return
    var row = rows[0].copy()
    if not delivered(db,mid,"unread",row[0]):
        broadcast_unread(db,mid,row[0])
        receipt(db,mid,"unread",row[0])
    var title = row[4] if row[2] == "Rooms::Direct" else row[3]
    var signer = Signer()
    var body = richtext.resolved(db,signer,row[5],True)
    if body=="":
        body = db.scalar("SELECT b.filename FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id WHERE a.record_type='Message' AND a.record_id=? AND a.name='attachment' LIMIT 1",[mid])
    var mention_ids = richtext.mention_ids(db,signer,row[5])
    var mention_json = "["+",".join(mention_ids)+"]"
    if row[2] != "Rooms::Direct":
        body = row[4] + ": " + body
    title = truncate_json(title, 256)
    body = truncate_json(body, 3072)
    var subscriptions = db.rows(
        (
            "SELECT ps.id,ps.user_id,coalesce(ps.endpoint,''),coalesce(ps.p256dh_key,''),coalesce(ps.auth_key,'') FROM"
            " push_subscriptions ps JOIN users u ON u.id=ps.user_id JOIN"
            " memberships mm ON mm.user_id=u.id WHERE mm.room_id=? AND"
            " u.status=0 AND mm.user_id<>? AND (mm.involvement='everything' OR (mm.involvement='mentions' AND mm.user_id IN (SELECT value FROM json_each(?)))) AND"
            " (mm.connected_at IS NULL OR mm.connected_at<datetime('now','-60"
            " seconds')) ORDER BY ps.id"
        ),
        [row[0], row[1],mention_json],
    )
    var failure = String()
    for sub in subscriptions:
        renew(db,job_id)
        var badge = db.scalar(
            (
                "SELECT count(*) FROM memberships WHERE user_id=? AND unread_at"
                " IS NOT NULL"
            ),
            [sub[1]],
        )
        var notification = (
            '{"title":'
            + json_string(title)
            + ',"options":{"body":'
            + json_string(body)
            + ',"icon":"/account/logo","data":{"path":"/rooms/'
            + row[0]
            + '","badge":'
            + badge
            + "}}}"
        )
        if delivered(db,mid,"push",sub[0]):
            continue
        count(2)
        trace(
            "notification",
            '{"message_id":'
            + mid
            + ',"subscription_id":'
            + sub[0]
            + ',"payload":'
            + notification
            + "}",
        )
        try:
            if not push_endpoint_permitted(sub[2]):
                count(3)
            else:
                webpush.deliver(db,sub[0],sub[2],sub[3],sub[4],notification)
            receipt(db,mid,"push",sub[0])
        except e:
            failure = String(e)

    if hooks:
        try:
            deliver_webhooks(db,signer,mid,row,mention_ids,job_id)
        except e:
            failure = String(e)
    if failure!="":
        raise Error(failure)


def enqueue(mut db: Database, mid: String, hooks: Bool = True) raises:
    _ = db.rows("INSERT INTO mojo_jobs(message_id,hooks) VALUES(?,?)",[mid,"1" if hooks else "0"])


def delivered(mut db: Database, mid: String, kind: String, target: String) raises -> Bool:
    return db.scalar("SELECT 1 FROM mojo_deliveries WHERE message_id=? AND kind=? AND target_id=?",[mid,kind,target])=="1"


def receipt(mut db: Database, mid: String, kind: String, target: String) raises:
    _ = db.rows("INSERT OR IGNORE INTO mojo_deliveries(message_id,kind,target_id) VALUES(?,?,?)",[mid,kind,target])


def run(path: String) raises:
    var db = Database(path)
    while external_call["os_running",Int]():
        var rows = db.rows("UPDATE mojo_jobs SET lease_until=unixepoch()+600,attempts=attempts+1 WHERE id=(SELECT id FROM mojo_jobs WHERE failed=0 AND available_at<=unixepoch() AND lease_until<unixepoch() ORDER BY id LIMIT 1) RETURNING id,message_id,hooks,attempts,kind")
        if len(rows)==0:
            external_call["os_sleep_ms",NoneType](50)
            continue
        var job = rows[0].copy()
        try:
            if job[4]=="remove_banned_content":
                remove_history(db,job[1],job[0],False)
            elif job[4]=="remove_room":
                remove_history(db,job[1],job[0],True)
            else:
                process(db,job[1],job[2]=="1",job[0])
            _ = db.rows("BEGIN IMMEDIATE")
            _ = db.rows("DELETE FROM mojo_jobs WHERE id=?",[job[0]])
            if job[4]=="message":
                _ = db.rows("DELETE FROM mojo_deliveries WHERE message_id=? AND NOT EXISTS(SELECT 1 FROM mojo_jobs WHERE message_id=? AND kind='message')",[job[1],job[1]])
            _ = db.rows("COMMIT")
            count(1)
        except e:
            try:
                _ = db.rows("ROLLBACK")
            except:
                pass
            storage.rollback(db)
            db.pending_events.clear()
            count(6)
            print("Background job failed:",e)
            _ = db.rows("UPDATE mojo_jobs SET lease_until=0,available_at=unixepoch()+min(3600,attempts*attempts*5),failed=CASE WHEN attempts>=10 THEN 1 ELSE 0 END,error=? WHERE id=?",[String(e),job[0]])


def broadcast(
    mut db: Database, room_id: String, kind: String, mid: String, body: String
) raises:
    # Publish after commit to every authorized Action Cable subscriber.
    var stream = (
        base64("gid://campfire/" + kind + "/" + room_id, True, False)
        + ":messages"
    )
    pubsub.publish(stream, json_string(body))
    count(4)
    trace(
        "broadcast",
        '{"message_id":'
        + mid
        + ',"stream":'
        + json_string(stream)
        + ',"payload":'
        + json_string(body)
        + "}",
    )


def broadcast_unread(mut db: Database, mid: String, room_id: String) raises:
    var at = db.scalar("SELECT (julianday(created_at)-2440587.5)*86400 FROM messages WHERE id=?",[mid])
    var memberships = db.rows("SELECT user_id FROM memberships WHERE room_id=? AND (unread_at IS NOT NULL OR connected_at>datetime('now','-60 seconds'))",[room_id])
    for member in memberships:
        var name = "user_"+member[0]+"_unreads"
        var unread = '{"roomId":'+room_id+',"at":'+at+'}'
        pubsub.publish(name,unread)
        count(5)
        trace("broadcast",'{"message_id":'+mid+',"stream":'+json_string(name)+',"payload":'+unread+'}')


def webhook_candidates(
    mut db: Database, room_id: String, creator_id: String, direct: Bool
) raises:
    if direct:
        var bots = db.rows(
            (
                "SELECT u.id FROM users u JOIN memberships mm ON"
                " mm.user_id=u.id WHERE mm.room_id=? AND u.role=2 AND"
                " u.status=0 AND u.id<>?"
            ),
            [room_id, creator_id],
        )
        count(8, len(bots))
        # Delivery runs in the background worker, after the message commit.


def deliver_webhooks(mut db: Database, mut signer: Signer, mid: String, row: List[String], mentions: List[String], job_id: String = "") raises:
    var bots = db.rows("SELECT u.id,u.name,u.bot_token,w.url FROM users u JOIN webhooks w ON w.user_id=u.id JOIN memberships mm ON mm.user_id=u.id WHERE mm.room_id=? AND u.role=2 AND u.status=0 AND u.id<>? AND (?='Rooms::Direct' OR u.id IN (SELECT value FROM json_each(?)))",[row[0],row[1],row[2],"["+",".join(mentions)+"]"])
    var failure = String()
    for bot in bots:
        try:
            deliver_webhook(db,signer,mid,row,bot,job_id)
        except e:
            failure = String(e)
    if failure!="":
        raise Error(failure)


def deliver_webhook(mut db: Database, mut signer: Signer, mid: String, row: List[String], bot: List[String], job_id: String) raises:
    renew(db,job_id)
    if delivered(db,mid,"hook",bot[0]):
        return
    var plain = String(richtext.resolved(db,signer,row[5],True).replace("@"+bot[1],"").strip())
    var payload = '{"user":{"id":'+row[1]+',"name":'+json_string(row[4])+'},"room":{"id":'+row[0]+',"name":'+("null" if row[2]=="Rooms::Direct" else json_string(row[3]))+',"path":'+json_string("/rooms/"+row[0]+"/"+bot[0]+"-"+bot[2]+"/messages")+'},"message":{"id":'+mid+',"body":{"html":'+json_string(richtext.body_html(db,signer,row[5]))+',"plain":'+json_string(plain)+'},"path":'+json_string("/rooms/"+row[0]+"/@"+mid)+'}}'
    var response = network.request(bot[3],"POST","Content-Type: application/json",payload,True,7000)
    var attachment = response.content_type!="" and not response.content_type.startswith("text/html") and not response.content_type.startswith("text/plain")
    if response.status==-3:
        response.body = "Failed to respond within 7 seconds"
    elif response.status<0 or response.status==429 or response.status>=500:
        raise Error("Webhook transport failed; will retry")
    elif response.status!=200:
        receipt(db,mid,"hook",bot[0])
        return
    if response.body=="":
        receipt(db,mid,"hook",bot[0])
        return
    _ = db.rows("BEGIN IMMEDIATE")
    try:
        # Membership can change while the remote endpoint is answering.
        if db.scalar("SELECT 1 FROM memberships WHERE room_id=? AND user_id=?",[row[0],bot[0]])!="1":
            _ = db.rows("ROLLBACK")
            return
        var now = db.scalar("SELECT strftime('%Y-%m-%d %H:%M:%f','now')")
        var cid = token()
        _ = db.rows("INSERT INTO messages(client_message_id,creator_id,room_id,created_at,updated_at) VALUES(?,?,?,?,?)",[cid,bot[0],row[0],now,now])
        var reply_id = db.last_id()
        var body = String()
        var plain = String()
        if attachment:
            var kind = String(response.content_type.split(";")[0])
            var extensions: Dict[String,String] = {"image/png":"png","image/jpeg":"jpg","image/webp":"webp","application/pdf":"pdf","video/mp4":"mp4","audio/mpeg":"mp3"}
            var file = Upload("attachment."+extensions.get(kind,""),kind,response.body)
            var bid = storage.upload(db,file)
            storage.attach(db,bid,"Message",reply_id,"attachment")
            storage.prepare(db,bid)
            plain = file.filename
        else:
            body = richtext.canonical(db,response.body)
            plain = richtext.resolved(db,signer,body,True)
        _ = db.rows("INSERT INTO action_text_rich_texts(name,record_type,record_id,body,created_at,updated_at) VALUES('body','Message',?,?,?,?)",[reply_id,body,now,now])
        richtext.sync_embeds(db,signer,db.last_id(),body)
        _ = db.rows("INSERT INTO message_search_index(rowid,body) VALUES(?,?)",[reply_id,plain])
        _ = db.rows("UPDATE rooms SET updated_at=?,messages_count=messages_count+1 WHERE id=?",[now,row[0]])
        _ = db.rows("UPDATE memberships SET unread_at=?,updated_at=? WHERE room_id=? AND user_id<>? AND involvement<>'invisible' AND (unread_at IS NULL OR (SELECT type FROM rooms WHERE id=room_id)='Rooms::Direct') AND (connected_at IS NULL OR connected_at<datetime('now','-60 seconds'))",[now,now,row[0],bot[0]])
        enqueue(db,reply_id,False)
        receipt(db,mid,"hook",bot[0])
        _ = db.rows("COMMIT")
        storage.commit(db)
        var message = db.rows(message_actions.COLUMNS+"WHERE m.id=?",[reply_id])[0].copy()
        var target = "messages_"+row[2].replace("::","_").lower()+"_"+row[0]
        var html = '<turbo-stream action="append" target="'+target+'"><template>'+views.message(db,signer,message)+'</template></turbo-stream>'
        broadcast(db,row[0],row[2],reply_id,html)
        count(0)
    except e:
        storage.rollback(db)
        try:
            _ = db.rows("ROLLBACK")
        except:
            pass
        raise e^


def remove_history(mut db: Database, subject: String, job_id: String, room: Bool) raises:
    # One short transaction per message permits concurrent chat and resumable work.
    while True:
        _ = db.rows("BEGIN IMMEDIATE")
        renew(db,job_id)
        var mid = db.scalar("SELECT id FROM messages WHERE "+("room_id" if room else "creator_id")+"=? ORDER BY id LIMIT 1",[subject])
        if mid=="":
            if room:
                _ = db.rows("DELETE FROM rooms WHERE id=?",[subject])
            _ = db.rows("COMMIT")
            return
        _ = message_actions.destroy_message(db,mid)
        _ = db.rows("COMMIT")
        storage.commit(db)
        pubsub.flush(db)


def renew(mut db: Database, job_id: String) raises:
    if job_id!="":
        _ = db.rows("UPDATE mojo_jobs SET lease_until=unixepoch()+600 WHERE id=?",[job_id])
