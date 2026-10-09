from database import Database
from crypto import Signer, json_string, base64
from http import Request, Response, html
from parameters import Form
from text import escape, positive, params
import templates
import views
import ui
import storage
import pubsub
from accounts import stamp


def may_administer(mut db: Database, uid: String, rid: String) raises -> Bool:
    return db.scalar("SELECT 1 FROM rooms r JOIN memberships mm ON mm.room_id=r.id WHERE r.id=? AND mm.user_id=? AND (r.creator_id=? OR r.type='Rooms::Direct' OR EXISTS(SELECT 1 FROM users WHERE id=? AND role=1))",[rid,uid,uid,uid]) == "1"


def ids(mut db: Database, uid: String, form: Form, include_self: Bool) raises -> List[String]:
    var out = List[String]()
    if include_self:
        out.append(uid)
    for s in form.fields.get("user_ids[]","").split(","):
        var id = String(s)
        if id=="":
            continue
        id = String(positive(id))
        if id not in out and db.scalar("SELECT 1 FROM users WHERE id=? AND status=0",[id]) == "1":
            out.append(id)
    return out^


def route(mut db: Database, mut signer: Signer, req: Request, uid: String, f: Form) raises -> Response:
    var parts = req.path.split("/")
    var verb = req.method
    var now = stamp(db)
    if req.path=="/rooms" and verb=="GET":
        var last = db.scalar("SELECT room_id FROM memberships WHERE user_id=? ORDER BY room_id DESC LIMIT 1",[uid])
        return ui.redirect("/rooms/"+last if last!="" else "/")
    if req.path in ["/autocompletable/users","/autocompletable/users.json"] and verb=="GET":
        var q = params(req.query)
        var rid = q.get("room_id","")
        if rid!="" and db.scalar("SELECT 1 FROM memberships WHERE room_id=? AND user_id=?",[rid,uid])!="1":
            return html("Room not found",404)
        var sql = String("SELECT id,name,strftime('%Y%m%d%H%M%S',updated_at) FROM users WHERE status=0 AND name LIKE ?")
        var args = List[String](["%"+q.get("filter",q.get("query",""))+"%"])
        if rid!="":
            sql += " AND id IN (SELECT user_id FROM memberships WHERE room_id=?)"
            args.append(rid)
        var page = max(1,min(100000,Int(q.get("page","1"))))
        args.append(String((page-1)*20))
        var users = db.rows(sql+" ORDER BY lower(name),id LIMIT 20 OFFSET ?",args)
        var items = List[String]()
        var body = String()
        for user in users:
            var avatar = signer.avatar(user[0],user[2])
            var sgid = signer.envelope("signed_global_ids",json_string("gid://campfire/User/"+user[0]+"?expires_in"),"attachable","",True)
            items.append('{"name":'+json_string(escape(user[1]))+',"value":'+user[0]+',"avatar_url":'+json_string(req.origin()+avatar)+',"sgid":'+json_string(sgid)+'}')
            body += '<lexxy-prompt-item search="'+escape(user[1])+'" sgid="'+escape(sgid)+'"><template type="menu"><span class="autocomplete__item"><img class="avatar" src="'+escape(avatar)+'">'+escape(user[1])+'</span></template><template type="editor"><span class="mention" data-user-id="'+user[0]+'">'+escape(user[1])+'</span></template></lexxy-prompt-item>'
        if "application/json" in req.header("accept") or req.path.endswith(".json"):
            return Response(200,"["+",".join(items)+"]","application/json","")
        return html(body)
    if len(parts)<3 or String(parts[1])!="rooms":
        return html("",0)
    var type_path = String(parts[2])
    if type_path=="opens" or type_path=="closeds" or type_path=="directs":
        var direct = type_path=="directs"
        var rid = String()
        if len(parts)>3 and String(parts[3])!="new":
            rid = String(positive(String(parts[3])))
            var existing = db.scalar("SELECT r.type FROM rooms r JOIN memberships mm ON mm.room_id=r.id WHERE r.id=? AND mm.user_id=?",[rid,uid])
            if existing=="" or (existing=="Rooms::Direct")!=direct:
                return html("Room not found",404)
        var admin = db.scalar("SELECT role FROM users WHERE id=?",[uid])=="1"
        if rid=="" and not direct and not admin and db.scalar("SELECT coalesce(json_extract(settings,'$.restrict_room_creation_to_administrators'),0) FROM accounts LIMIT 1")=="1":
            return html("Forbidden",403)
        if rid!="" and verb!="GET" and not may_administer(db,uid,rid):
            return html("Forbidden",403)
        if verb=="GET":
            if direct and rid=="":
                var v = views.context(db,signer,uid,req,"New Ping")
                v["content"] = templates.direct_new(v)
                return html(views.layout(v,req))
            if len(parts)==4 and String(parts[3])!="new":
                return ui.redirect("/rooms/"+rid)
            if direct and rid!="":
                var body = String('<section class="directs--edit margin-block-end">')
                for member in db.rows("SELECT u.id,u.name,strftime('%Y%m%d%H%M%S',u.updated_at) FROM users u JOIN memberships m ON m.user_id=u.id WHERE m.room_id=? ORDER BY lower(u.name)",[rid]):
                    body += '<div class="member flex flex-column gap fill-shade pad border-radius"><a class="btn avatar" href="/users/'+member[0]+'"><img src="'+escape(signer.avatar(member[0],member[2]))+'" width="48" height="48"></a><strong>'+escape(member[1])+'</strong></div>'
                body += '</section>'+ui.form("/rooms/directs/"+rid,"","delete","Delete Ping")
                return ui.page(db,signer,uid,req,"Ping",body)
            var name = "New room" if rid=="" else db.scalar("SELECT coalesce(name,'') FROM rooms WHERE id=?",[rid])
            var can_edit = rid=="" or may_administer(db,uid,rid)
            var fields = ui.field("room[name]",name,"Name this room","everyone","text","required" if can_edit else "readonly")
            var other = "opens" if type_path=="closeds" else "closeds"
            if can_edit:
                fields += '<a class="btn" data-turbo-action="replace" href="/rooms/'+other+("/"+rid+"/edit" if rid!="" else "/new")+'">'+("Give everyone access to this room" if type_path=="closeds" else "Give only some access to this room")+'</a>'
            fields += '<menu class="flex flex-column gap margin-none pad fill-shade border-radius">'
            if type_path=="opens":
                for user in db.rows("SELECT id,name FROM users WHERE status=0 ORDER BY lower(name)"):
                    fields += '<li class="flex align-center gap"><a href="/users/'+user[0]+'">'+escape(user[1])+'</a></li>' 
            if type_path=="closeds":
                var users = db.rows("SELECT id,name FROM users WHERE status=0 ORDER BY lower(name)")
                for user in users:
                    var checked = db.scalar("SELECT 1 FROM memberships WHERE room_id=? AND user_id=?",[rid,user[0]])=="1" or (rid=="" and user[0]==uid)
                    fields += '<label><input type="checkbox" name="user_ids[]" value="'+user[0]+'"'+(' checked' if checked else '')+(' disabled' if not can_edit else '')+'>'+escape(user[1])+'</label>'
            fields += "</menu>"
            var body = ui.form("/rooms/"+type_path+("/"+rid if rid!="" else ""),fields,"patch" if rid!="" else "post","Save") if can_edit else fields
            if rid!="" and can_edit:
                body += ui.form("/rooms/"+type_path+"/"+rid,"","delete","Delete room")
            return ui.page(db,signer,uid,req,"Room settings",body)
        if verb=="DELETE":
            return destroy(db,rid,uid)
        if verb!="POST" and verb!="PATCH" and verb!="PUT":
            return html("Not found",404)
        if (rid!="" and (direct or verb=="POST")) or (rid=="" and verb!="POST"):
            return html("Not found",404)
        var members = ids(db,uid,f,direct)
        var kind = "Rooms::Direct" if direct else ("Rooms::Open" if type_path=="opens" else "Rooms::Closed")
        var name = f.fields.get("room[name]",f.fields.get("rooms_open[name]",f.fields.get("rooms_closed[name]","")))
        if not direct and String(name.strip())=="":
            return html("Room name is required",422)
        if direct and rid=="":
            var all_ids = ",".join(members)
            rid = db.scalar("SELECT r.id FROM rooms r JOIN memberships mm ON mm.room_id=r.id WHERE r.type='Rooms::Direct' GROUP BY r.id HAVING count(*)=? AND count(CASE WHEN mm.user_id IN (SELECT value FROM json_each(?)) THEN 1 END)=? LIMIT 1",[String(len(members)),"["+all_ids+"]",String(len(members))])
            if rid!="":
                return ui.redirect("/rooms/"+rid)
        if rid=="":
            _ = db.rows("INSERT INTO rooms(name,type,creator_id,created_at,updated_at) VALUES(?,?,?,?,?)",[name,kind,uid,now,now])
            rid = db.last_id()
        else:
            _ = db.rows("UPDATE rooms SET name=?,type=?,updated_at=? WHERE id=?",[name,kind,now,rid])
        if type_path=="opens":
            _ = db.rows("INSERT OR IGNORE INTO memberships(room_id,user_id,created_at,updated_at) SELECT ?,id,?,? FROM users WHERE status=0",[rid,now,now])
        else:
            _ = db.rows("DELETE FROM memberships WHERE room_id=? AND user_id NOT IN (SELECT value FROM json_each(?))",[rid,"["+",".join(members)+"]"])
            for member in members:
                _ = db.rows("INSERT OR IGNORE INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,?,?,?,?)",[rid,member,"everything" if direct else "mentions",now,now])
        return ui.redirect("/rooms/"+rid)
    var rid = String(positive(type_path))
    if len(parts)==3 and verb=="DELETE":
        return destroy(db,rid,uid)
    if db.scalar("SELECT 1 FROM memberships WHERE room_id=? AND user_id=?",[rid,uid])!="1":
        return html("Room not found",404)
    if len(parts)==4 and String(parts[3])=="settings" and verb=="GET":
        var kind = db.scalar("SELECT type FROM rooms WHERE id=?",[rid]).replace("Rooms::","").lower()
        return ui.redirect("/rooms/"+kind+"s/"+rid+"/edit")
    if len(parts)==4 and String(parts[3])=="involvement":
        if verb=="PATCH" or verb=="PUT":
            var value = f.fields.get("involvement","")
            if value!="everything" and value!="mentions" and value!="nothing" and value!="invisible":
                return html("Invalid involvement",422)
            _ = db.rows("UPDATE memberships SET involvement=?,updated_at=? WHERE room_id=? AND user_id=?",[value,now,rid,uid])
            return ui.redirect(req.path)
        if verb!="GET":
            return html("Not found",404)
        var current = db.scalar("SELECT involvement FROM memberships WHERE room_id=? AND user_id=?",[rid,uid])
        var content = String()
        for value in ["everything","mentions","nothing","invisible"]:
            content += '<label><input type="radio" name="involvement" value="'+value+'"'+(' checked' if value==current else '')+'>'+value+'</label>'
        var kind = db.scalar("SELECT type FROM rooms WHERE id=?",[rid]).replace("::","_").lower()
        return html('<turbo-frame id="involvement_'+kind+'_'+rid+'">'+ui.form(req.path,content,"patch")+'</turbo-frame>')
    return html("",0)


def destroy(mut db: Database, rid: String, uid: String) raises -> Response:
    if rid=="" or not may_administer(db,uid,rid):
        return html("Forbidden",403)
    # Revoke access immediately; bounded background transactions remove history.
    _ = db.rows("UPDATE rooms SET type=CASE WHEN type='Rooms::Open' THEN 'Rooms::Closed' ELSE type END WHERE id=?",[rid])
    _ = db.rows("DELETE FROM memberships WHERE room_id=?",[rid])
    _ = db.rows("INSERT INTO mojo_jobs(message_id,kind) VALUES(?,'remove_room')",[rid])
    return ui.redirect("/")
