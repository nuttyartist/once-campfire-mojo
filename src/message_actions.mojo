from database import Database
from crypto import Signer, json_string
from http import Request, Response, html
from parameters import Form
from text import escape, positive, params, token
from accounts import stamp
import views
import templates
import richtext
import pubsub
import ui
import storage

comptime COLUMNS = "SELECT m.id,m.client_message_id,m.created_at,m.creator_id,u.name,m.room_id,coalesce(r.name,'Direct message'),coalesce(rt.body,idx.body,'') FROM messages m JOIN users u ON u.id=m.creator_id JOIN rooms r ON r.id=m.room_id LEFT JOIN message_search_index idx ON idx.rowid=m.id LEFT JOIN action_text_rich_texts rt ON rt.record_id=m.id AND rt.record_type='Message' AND rt.name='body' "


def wire_user(mut db: Database, mut signer: Signer, uid: String, req: Request) raises -> String:
    var user = db.rows("SELECT name,role,strftime('%Y%m%d%H%M%S',updated_at) FROM users WHERE id=?",[uid])[0].copy()
    var role = "administrator" if user[1]=="1" else "bot" if user[1]=="2" else "member"
    return '{"id":'+uid+',"name":'+json_string(user[0])+',"role":'+json_string(role)+',"avatar_url":'+json_string(req.origin()+signer.avatar(uid,user[2]))+'}'


def wire_message(mut db: Database, mut signer: Signer, row: List[String], req: Request) raises -> String:
    return '{"id":'+row[0]+',"created_at":'+json_string(row[2].replace(" ","T")+"Z")+',"body":{"plain_text":'+json_string(richtext.resolved(db,signer,row[7],True))+',"html":'+json_string('<div class="lexxy-content">'+richtext.resolved(db,signer,row[7])+'</div>')+'},"creator":'+wire_user(db,signer,row[3],req)+',"room":{"id":'+row[5]+'},"url":'+json_string(req.origin()+"/rooms/"+row[5]+"/messages/"+row[0])+'}'


def wire_boost(mut db: Database, mut signer: Signer, bid: String, req: Request) raises -> String:
    var row = db.rows("SELECT b.content,b.created_at,b.booster_id,b.message_id,m.room_id FROM boosts b JOIN messages m ON m.id=b.message_id WHERE b.id=?",[bid])[0].copy()
    return '{"id":'+bid+',"content":'+json_string(row[0])+',"created_at":'+json_string(row[1].replace(" ","T")+"Z")+',"booster":'+wire_user(db,signer,row[2],req)+',"message":{"id":'+row[3]+',"url":'+json_string(req.origin()+"/rooms/"+row[4]+"/messages/"+row[3])+'}}'


def render_boost(mut db: Database, mut signer: Signer, bid: String) raises -> String:
    var b = db.rows("SELECT booster_id,content,message_id FROM boosts WHERE id=?",[bid])[0].copy()
    var v = Dict[String,String]()
    views.set_user(db,signer,v,b[0])
    v["dom_id"] = "boost_"+bid
    v["content"] = b[1]
    v["all_emoji"] = "1" if views.emoji(b[1]) else "0"
    v["path"] = "/messages/"+b[2]+"/boosts/"+bid
    return templates.boost(v)


def route(mut db: Database, mut signer: Signer, req: Request, uid: String, f: Form) raises -> Response:
    var parts = req.path.split("/")
    var mid: String
    var rid = String()
    var boost = False
    var edit = False
    var bid = String()
    if len(parts)>=4 and String(parts[1])=="messages" and String(parts[3])=="boosts":
        mid = String(positive(String(parts[2])))
        boost = True
        if len(parts)==5:
            if String(parts[4])=="new":
                edit = True
            else:
                bid = String(positive(String(parts[4])))
    elif len(parts)>=5 and String(parts[1])=="rooms" and String(parts[3])=="messages":
        rid = String(positive(String(parts[2])))
        mid = String(positive(String(parts[4])))
        edit = len(parts)==6 and String(parts[5])=="edit"
        if len(parts)>6:
            return html("Not found",404)
    elif len(parts)==3 and String(parts[1])=="messages":
        mid = String(positive(String(parts[2])))
    elif len(parts)==4 and String(parts[1])=="rooms" and String(parts[3])=="refresh":
        rid = String(positive(String(parts[2])))
        if db.scalar("SELECT 1 FROM memberships WHERE room_id=? AND user_id=?",[rid,uid])!="1":
            return html("Not found",404)
        var since = params(req.query).get("since","0")
        var rows = db.rows(COLUMNS+"WHERE m.room_id=? AND (julianday(m.updated_at)-2440587.5)*86400000>? ORDER BY m.created_at,m.id LIMIT 200",[rid,since])
        var kind = db.scalar("SELECT type FROM rooms WHERE id=?",[rid]).replace("::","_").lower()
        var body = String()
        for row in rows:
            if db.scalar("SELECT (julianday(?)-2440587.5)*86400000>?",[row[2],since])=="1":
                body += ui.stream("append","messages_"+kind+"_"+rid,views.message(db,signer,row))
            else:
                body += ui.stream("replace","message_"+row[1],views.message(db,signer,row))
        return Response(200,body,"text/vnd.turbo-stream.html; charset=utf-8","")
    else:
        return html("",0)
    var rows = db.rows(COLUMNS+"JOIN memberships mm ON mm.room_id=m.room_id WHERE m.id=? AND mm.user_id=?",[mid,uid])
    if len(rows)==0 or (rid!="" and rows[0][5]!=rid):
        return html("Message not found",404)
    var row = rows[0].copy()
    rid = row[5]
    var verb = req.method
    var now = stamp(db)
    if boost:
        if verb=="POST":
            var content = f.fields.get("boost[content]","")
            var count = 0
            for _ in content.codepoints():
                count += 1
            if String(content.strip())=="" or count>16:
                return html("Boost must contain 1–16 characters",422)
            _ = db.rows("INSERT INTO boosts(booster_id,content,message_id,created_at,updated_at) VALUES(?,?,?,?,?)",[uid,content,mid,now,now])
            bid = db.last_id()
            pubsub.room(db,rid,ui.stream("append","boosts_message_"+row[1],render_boost(db,signer,bid)))
            return ui.redirect("/messages/"+mid+"/boosts")
        if verb=="DELETE":
            if db.scalar("SELECT 1 FROM boosts WHERE id=? AND message_id=? AND booster_id=?",[bid,mid,uid])!="1":
                return html("Boost not found",404)
            _ = db.rows("DELETE FROM boosts WHERE id=?",[bid])
            var body = ui.stream("remove","boost_"+bid)
            pubsub.room(db,rid,body)
            return Response(200,body,"text/vnd.turbo-stream.html; charset=utf-8","")
        if edit:
            return html('<turbo-frame id="new_boost_message_'+row[1]+'">'+ui.form("/messages/"+mid+"/boosts",ui.input("boost[content]","","Boost"),"post","Boost")+'</turbo-frame>')
        var boosts = db.rows("SELECT id FROM boosts WHERE message_id=? ORDER BY created_at",[mid])
        var body = String()
        for b in boosts:
            body += render_boost(db,signer,b[0])
        return html('<turbo-frame id="boosts_message_'+row[1]+'">'+body+'</turbo-frame>')
    if (edit or verb!="GET") and row[3]!=uid and db.scalar("SELECT role FROM users WHERE id=?",[uid])!="1":
        return html("Forbidden",403)
    if verb=="GET" and edit:
        var action = "/rooms/"+rid+"/messages/"+mid
        var editor = '<lexxy-editor name="message[body]" value="'+escape(row[7])+'" aria-label="Edit message" class="input lexxy-content" autofocus></lexxy-editor>'
        return html('<turbo-frame id="edit_message_'+row[1]+'">'+ui.form(action,editor,"patch")+ui.form(action,"","delete","Delete message")+'</turbo-frame>')
    if verb=="PATCH" or verb=="PUT":
        var raw = f.fields.get("message[body]","")
        var plain = richtext.resolved(db,signer,raw,True)
        if String(plain.strip())=="" and "message[attachment]" not in f.files and db.scalar("SELECT 1 FROM active_storage_attachments WHERE record_type='Message' AND record_id=? AND name='attachment'",[mid])!="1":
            return html("Message is empty",422)
        if "message[attachment]" in f.files:
            var blob = storage.upload(db,f.files["message[attachment]"])
            storage.attach(db,blob,"Message",mid,"attachment")
        _ = db.rows("UPDATE action_text_rich_texts SET body=?,updated_at=? WHERE record_type='Message' AND record_id=? AND name='body'",[richtext.convert(raw),now,mid])
        _ = db.rows("UPDATE message_search_index SET body=? WHERE rowid=?",[plain,mid])
        _ = db.rows("UPDATE messages SET updated_at=? WHERE id=?",[now,mid])
        _ = db.rows("UPDATE rooms SET updated_at=? WHERE id=?",[now,rid])
        var updated = db.rows(COLUMNS+"WHERE m.id=?",[mid])[0].copy()
        pubsub.room(db,rid,ui.stream("replace","message_"+row[1],views.message(db,signer,updated)))
        return ui.redirect("/rooms/"+rid+"/messages/"+mid)
    if verb=="DELETE":
        _ = db.rows("DELETE FROM boosts WHERE message_id=?",[mid])
        _ = db.rows("DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",[mid])
        _ = db.rows("DELETE FROM message_search_index WHERE rowid=?",[mid])
        _ = db.rows("DELETE FROM messages WHERE id=?",[mid])
        _ = db.rows("UPDATE rooms SET messages_count=max(0,messages_count-1),updated_at=? WHERE id=?",[now,rid])
        var body = ui.stream("remove","message_"+row[1])
        pubsub.room(db,rid,body)
        return Response(200,body,"text/vnd.turbo-stream.html; charset=utf-8","")
    if verb=="GET":
        if "application/json" in req.header("accept"):
            return Response(200,wire_message(db,signer,row,req),"application/json","")
        return html(views.message(db,signer,row))
    return html("Not found",404)
