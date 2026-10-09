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

comptime COLUMNS = "SELECT m.id,m.client_message_id,m.created_at,m.creator_id,u.name,m.room_id,coalesce(r.name,'Direct message'),coalesce(rt.body,idx.body,'') FROM messages m LEFT JOIN users u ON u.id=m.creator_id JOIN rooms r ON r.id=m.room_id LEFT JOIN message_search_index idx ON idx.rowid=m.id LEFT JOIN action_text_rich_texts rt ON rt.record_id=m.id AND rt.record_type='Message' AND rt.name='body' "


def wire_user(mut db: Database, mut signer: Signer, uid: String, req: Request) raises -> String:
    var user = db.rows("SELECT name,role,strftime('%Y%m%d%H%M%S',updated_at) FROM users WHERE id=?",[uid])[0].copy()
    var role = "administrator" if user[1]=="1" else "bot" if user[1]=="2" else "member"
    return '{"id":'+uid+',"name":'+json_string(user[0])+',"role":'+json_string(role)+',"avatar_url":'+json_string(req.origin()+signer.avatar(uid,user[2]))+'}'


def wire_message(mut db: Database, mut signer: Signer, row: List[String], req: Request) raises -> String:
    return '{"id":'+row[0]+',"created_at":'+json_string(row[2].replace(" ","T")+"Z")+',"body":{"plain_text":'+json_string(richtext.resolved(db,signer,row[7],True))+',"html":'+json_string(richtext.body_html(db,signer,row[7]))+'},"creator":'+wire_user(db,signer,row[3],req)+',"room":{"id":'+row[5]+'},"url":'+json_string(req.origin()+"/rooms/"+row[5]+"/messages/"+row[0])+'}'


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
        if req.method!="GET":
            return html("Not found",404)
        var since = params(req.query).get("since","0")
        var milliseconds = 0
        try:
            milliseconds = Int(since)
        except:
            pass
        var stamp = db.scalar("SELECT strftime('%Y-%m-%d %H:%M:%f',?/1000.0,'unixepoch')",[String(milliseconds)])
        var new = db.rows(COLUMNS+"WHERE m.room_id=? AND m.created_at>? ORDER BY m.created_at,m.id LIMIT 40",[rid,stamp])
        var ids = List[String]()
        for row in new:
            ids.append(row[0])
        var updated = db.rows("SELECT * FROM ("+COLUMNS+"WHERE m.room_id=? AND m.updated_at>? AND m.id NOT IN (SELECT value FROM json_each(?)) ORDER BY +m.created_at DESC,m.id DESC LIMIT 40) ORDER BY 3,1",[rid,stamp,"["+",".join(ids)+"]"])
        var kind = db.scalar("SELECT type FROM rooms WHERE id=?",[rid]).replace("::","_").lower()
        var body = String()
        if len(new)>0:
            body += ui.stream("append","messages_"+kind+"_"+rid,views.messages(db,signer,new))
        for row in updated:
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
            if content.byte_length()>65536:
                return html("Boost is too long",422)
            _ = db.rows("INSERT INTO boosts(booster_id,content,message_id,created_at,updated_at) VALUES(?,?,?,?,?)",[uid,content,mid,now,now])
            bid = db.last_id()
            _ = db.rows("UPDATE messages SET updated_at=? WHERE id=?",[now,mid])
            _ = db.rows("UPDATE rooms SET updated_at=? WHERE id=?",[now,rid])
            pubsub.room(db,rid,ui.stream("append","boosts_message_"+row[1],render_boost(db,signer,bid)))
            return ui.redirect("/messages/"+mid+"/boosts")
        if verb=="DELETE":
            if db.scalar("SELECT 1 FROM boosts WHERE id=? AND message_id=? AND booster_id=?",[bid,mid,uid])!="1":
                return html("Boost not found",404)
            _ = db.rows("DELETE FROM boosts WHERE id=?",[bid])
            _ = db.rows("UPDATE messages SET updated_at=? WHERE id=?",[now,mid])
            _ = db.rows("UPDATE rooms SET updated_at=? WHERE id=?",[now,rid])
            var body = ui.stream("remove","boost_"+bid)
            pubsub.room(db,rid,body)
            return Response(200,body,"text/vnd.turbo-stream.html; charset=utf-8","")
        if verb!="GET":
            return html("Not found",404)
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
        var editor = '<lexxy-editor name="message[body]" value="'+escape(richtext.editable(db,signer,row[7]))+'" aria-label="Edit message" class="input lexxy-content" autofocus></lexxy-editor>'
        return html('<turbo-frame id="edit_message_'+row[1]+'">'+ui.form(action,editor,"patch")+ui.form(action,"","delete","Delete message")+'</turbo-frame>')
    if verb=="PATCH" or verb=="PUT":
        var raw = f.fields.get("message[body]",row[7])
        var plain = richtext.resolved(db,signer,raw,True)
        if String(plain.strip())=="" and "message[attachment]" not in f.files and f.fields.get("message[attachment]","")=="" and db.scalar("SELECT 1 FROM active_storage_attachments WHERE record_type='Message' AND record_id=? AND name='attachment'",[mid])!="1":
            return html("Message is empty",422)
        if "message[attachment]" in f.files:
            var blob = storage.upload(db,f.files["message[attachment]"])
            storage.attach(db,blob,"Message",mid,"attachment")
            storage.prepare(db,blob)
        elif f.fields.get("message[attachment]","")!="":
            var blob = signer.verify(db,"ActiveStorage",f.fields["message[attachment]"],"blob_id",False)
            if blob=="" or db.scalar("SELECT 1 FROM active_storage_blobs WHERE id=?",[blob])!="1":
                return html("Invalid attachment",422)
            storage.attach(db,blob,"Message",mid,"attachment")
            storage.prepare(db,blob)
        _ = db.rows("UPDATE action_text_rich_texts SET body=?,updated_at=? WHERE record_type='Message' AND record_id=? AND name='body'",[richtext.canonical(db,raw),now,mid])
        richtext.sync_embeds(db,signer,db.scalar("SELECT id FROM action_text_rich_texts WHERE record_type='Message' AND record_id=? AND name='body'",[mid]),raw)
        _ = db.rows("UPDATE message_search_index SET body=? WHERE rowid=?",[plain,mid])
        _ = db.rows("UPDATE messages SET updated_at=? WHERE id=?",[now,mid])
        _ = db.rows("UPDATE rooms SET updated_at=? WHERE id=?",[now,rid])
        var updated = db.rows(COLUMNS+"WHERE m.id=?",[mid])[0].copy()
        pubsub.room(db,rid,ui.stream("replace","message_"+row[1],views.message(db,signer,updated)))
        if "application/json" in req.header("accept"):
            return Response(200,wire_message(db,signer,updated,req),"application/json","")
        return ui.redirect("/rooms/"+rid+"/messages/"+mid)
    if verb=="DELETE":
        var body = destroy_message(db,mid)
        return Response(200,body,"text/vnd.turbo-stream.html; charset=utf-8","")
    if verb=="GET":
        if "application/json" in req.header("accept"):
            return Response(200,wire_message(db,signer,row,req),"application/json","")
        return html(views.message(db,signer,row))
    return html("Not found",404)


def destroy_message(mut db: Database, mid: String) raises -> String:
    var rows = db.rows("SELECT room_id,client_message_id FROM messages WHERE id=?",[mid])
    if len(rows)==0:
        return ""
    var row = rows[0].copy()
    storage.remove_message(db,mid)
    _ = db.rows("DELETE FROM boosts WHERE message_id=?",[mid])
    _ = db.rows("DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",[mid])
    _ = db.rows("DELETE FROM message_search_index WHERE rowid=?",[mid])
    _ = db.rows("DELETE FROM messages WHERE id=?",[mid])
    _ = db.rows("DELETE FROM mojo_deliveries WHERE message_id=?",[mid])
    _ = db.rows("DELETE FROM mojo_jobs WHERE message_id=? AND kind='message'",[mid])
    _ = db.rows("UPDATE rooms SET messages_count=max(0,messages_count-1),updated_at=? WHERE id=?",[stamp(db),row[0]])
    var body = ui.stream("remove","message_"+row[1])
    pubsub.room(db,row[0],body)
    return body^
