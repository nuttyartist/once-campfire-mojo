# Account, session, profile and administrator policies from the Rails controllers.
from std.ffi import external_call
from database import Database
from crypto import Signer, session_token, json_string, base64
from http import Request, Response, html
from parameters import Form
from text import escape, token, positive
from runtime import password_hash
import ui
import views
import pubsub
import storage


def stamp(mut db: Database) raises -> String:
    return db.scalar("SELECT strftime('%Y-%m-%d %H:%M:%f','now')")


def start_session(mut db: Database, mut signer: Signer, uid: String, req: Request) raises -> Response:
    var tok = session_token()
    var now = stamp(db)
    _ = db.rows("INSERT INTO sessions(token,user_id,last_active_at,created_at,updated_at,ip_address,user_agent) VALUES(?,?,?,?,?,?,?)",[tok,uid,now,now,now,req.peer,req.header("user-agent")])
    var expiry = db.scalar("SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now','+20 years')")
    return html("",303,"Location: /\r\nSet-Cookie: session_token="+signer.cookie(tok,expiry)+"; Path=/; HttpOnly; SameSite=Lax; Max-Age=631152000"+("; Secure" if req.origin().startswith("https://") else "")+"\r\n")


def signup(mut db: Database, mut signer: Signer, req: Request, f: Form, first: Bool) raises -> Response:
    if first and db.scalar("SELECT 1 FROM accounts LIMIT 1") == "1":
        return ui.redirect("/")
    if not first:
        var code = String(req.path[byte=6:])
        if db.scalar("SELECT 1 FROM accounts WHERE join_code=?",[code]) != "1":
            return html("Invitation not found",404)
    if req.method == "GET":
        return ui.page(db,signer,"",req,"Set up Campfire" if first else "Join Campfire",ui.form(req.path,ui.input("user[name]","","Name")+ui.input("user[email_address]","","Email address","email")+ui.input("user[password]","","Password","password"),"post","Save"))
    if req.method != "POST":
        return html("Not found",404)
    var name = String(f.fields.get("user[name]","").strip())
    var email = f.fields.get("user[email_address]","").strip().lower()
    if name == "" or email == "" or "@" not in email:
        return html("Name and email address are required",422)
    if db.scalar("SELECT 1 FROM users WHERE email_address=?",[email]) == "1":
        return ui.redirect("/session/new")
    var digest = password_hash(f.fields.get("user[password]",""))
    var now = stamp(db)
    if first:
        _ = db.rows("INSERT INTO accounts(name,join_code,created_at,updated_at,settings) VALUES('Campfire',?,?,?,'{}')",[session_token(),now,now])
    _ = db.rows("INSERT INTO users(name,email_address,password_digest,role,status,created_at,updated_at) VALUES(?,?,?,?,0,?,?)",[name,email,digest,"1" if first else "0",now,now])
    var uid = db.last_id()
    if first:
        _ = db.rows("INSERT INTO rooms(name,type,creator_id,created_at,updated_at) VALUES('All Talk','Rooms::Open',?,?,?)",[uid,now,now])
    _ = db.rows("INSERT OR IGNORE INTO memberships(room_id,user_id,created_at,updated_at) SELECT id,?,?,? FROM rooms WHERE type='Rooms::Open'",[uid,now,now])
    storage.profile_upload(db,f,uid)
    return start_session(db,signer,uid,req)


def transfer(mut db: Database, mut signer: Signer, req: Request) raises -> Response:
    var wire = String(req.path[byte=19:])
    if req.method == "GET":
        var v = views.context(db,signer,"",req,"Sign in")
        v["content"] = '<form method="post" action="'+escape(req.path)+'" data-controller="auto-submit"><input type="hidden" name="_method" value="put"><button type="submit">Sign in</button></form>'
        return html(views.layout(v,req))
    if req.method == "PUT" or req.method == "PATCH":
        var uid = signer.verify(db,"active_record/signed_id",wire,"user/transfer")
        if uid != "" and db.scalar("SELECT 1 FROM users WHERE id=? AND status=0 AND NOT EXISTS(SELECT 1 FROM bans WHERE user_id=users.id)",[uid]) == "1":
            return start_session(db,signer,uid,req)
        return html("Invalid or expired transfer",400)
    return html("Not found",404)


def deactivate(mut db: Database, uid: String, banned: Bool = False) raises:
    _ = db.rows("DELETE FROM memberships WHERE user_id=? AND room_id IN (SELECT id FROM rooms WHERE type<>'Rooms::Direct')",[uid])
    for table in ["push_subscriptions","searches","sessions"]:
        _ = db.rows("DELETE FROM "+table+" WHERE user_id=?",[uid])
    _ = db.rows("UPDATE users SET status=?,email_address=replace(email_address,'@',?),updated_at=? WHERE id=?",["2" if banned else "1","-deactivated-"+token()+"@",stamp(db),uid])


def route(mut db: Database, mut signer: Signer, req: Request, uid: String, f: Form) raises -> Response:
    var is_admin = db.scalar("SELECT role FROM users WHERE id=?",[uid]) == "1"
    var path = req.path
    var verb = req.method
    var now = stamp(db)
    if path == "/session" and verb == "DELETE":
        var tok = signer.verify_cookie(db,req.cookie("session_token"))
        _ = db.rows("DELETE FROM sessions WHERE user_id=? AND token=?",[uid,tok])
        _ = db.rows("DELETE FROM push_subscriptions WHERE user_id=? AND endpoint=?",[uid,f.fields.get("push_subscription_endpoint","")])
        return html("",303,"Location: /session/new\r\nSet-Cookie: session_token=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0\r\n")
    if path == "/users/me/profile":
        if verb == "PATCH" or verb == "PUT":
            storage.profile_upload(db,f,uid)
            for column in ["name","email_address","bio"]:
                if "user["+column+"]" in f.fields:
                    var value = f.fields["user["+column+"]"]
                    if column == "name" and String(value.strip()) == "":
                        return html("Name is required",422)
                    _ = db.rows("UPDATE users SET "+column+"=?,updated_at=? WHERE id=?",[value,now,uid])
            var password = f.fields.get("user[password]","")
            if password != "":
                _ = db.rows("UPDATE users SET password_digest=?,updated_at=? WHERE id=?",[password_hash(password),now,uid])
            return ui.redirect(path)
        var u = db.rows("SELECT name,coalesce(email_address,''),coalesce(bio,'') FROM users WHERE id=?",[uid])[0].copy()
        var fields = ui.input("user[avatar]","","Upload avatar","file")+ui.input("user[name]",u[0],"Name")+ui.input("user[email_address]",u[1],"Email address","email")+ui.input("user[password]","","Change password","password")+ui.textarea("user[bio]",u[2],"Bio")
        var url = req.origin()+"/session/transfers/"+signer.signed_id(db,uid,"user/transfer",4)
        var transfer_html = '<label>Use this link to login automatically on another device<input class="input" id="session_transfer_url" readonly value="'+escape(url)+'"></label><a href="/qr_code/'+base64(url,True,False)+'">Show auto-login QR code</a>'
        return ui.page(db,signer,uid,req,u[0],ui.form(path,fields,"patch")+transfer_html+ui.form("/session","","delete","Log out"))
    if path == "/account/edit" or path == "/account":
        if verb == "PATCH" or verb == "PUT":
            if not is_admin:
                return html("Forbidden",403)
            var name = f.fields.get("account[name]","")
            if String(name.strip())=="":
                return html("Name is required",422)
            storage.profile_upload(db,f,db.scalar("SELECT id FROM accounts LIMIT 1"),True)
            _ = db.rows("UPDATE accounts SET name=?,updated_at=?",[name,now])
            var restricted = f.fields.get("account[settings][restrict_room_creation_to_administrators]","")
            if restricted != "":
                _ = db.rows("UPDATE accounts SET settings=json_set(coalesce(settings,'{}'),'$.restrict_room_creation_to_administrators',json(?))",["true" if restricted=="1" or restricted=="true" else "false"])
            return ui.redirect("/account/edit")
        var rows = db.rows("SELECT name,join_code FROM accounts LIMIT 1")
        var content = String()
        if is_admin:
            content = ui.form("/account",ui.input("account[name]",rows[0][0],"Campfire name")+ui.input("account[logo]","","Upload logo","file"),"patch")
            content += '<a href="/account/bots">Set up chat bots</a><a href="/account/custom_styles/edit">Custom styles</a><label>Invitation link<input class="input" id="invite_url" readonly value="http://'+escape(req.header("host"))+"/join/"+escape(rows[0][1])+'"></label>'
        var users = db.rows("SELECT id,name,role,status FROM users WHERE role<>2 AND (status=0 OR ?='1') ORDER BY lower(name)",["1" if is_admin else "0"])
        for user in users:
            content += '<a href="/users/'+user[0]+'">'+escape(user[1])+'</a>'
            if is_admin:
                content += ui.form("/account/users/"+user[0],'<select name="user[role]"><option value="member">Member</option><option value="administrator"'+(' selected' if user[2]=="1" else '')+'>Administrator</option></select>',"patch","Change role")
                content += ui.form("/account/users/"+user[0],"","delete","Deactivate "+user[1])
        return ui.page(db,signer,uid,req,"Account",content)
    if path=="/account/logo" and verb=="DELETE":
        if not is_admin:
            return html("Forbidden",403)
        _ = db.rows("DELETE FROM active_storage_attachments WHERE record_type='Account' AND name='logo'")
        return ui.redirect("/account/edit")
    if path=="/users/me/avatar" and verb=="DELETE":
        _ = db.rows("DELETE FROM active_storage_attachments WHERE record_type='User' AND name='avatar' AND record_id=?",[uid])
        return ui.redirect("/users/me/profile")
    if path.startswith("/account/users/"):
        if not is_admin:
            return html("Forbidden",403)
        var user_id = String(positive(String(path[byte=15:])))
        if verb == "DELETE":
            deactivate(db,user_id)
        elif verb == "PATCH" or verb == "PUT":
            _ = db.rows("UPDATE users SET role=?,updated_at=? WHERE id=? AND status=0",["1" if f.fields.get("user[role]","")=="administrator" else "0",now,user_id])
        else:
            return html("Not found",404)
        return ui.redirect("/account/edit")
    if path == "/account/join_code" and verb == "POST":
        if not is_admin:
            return html("Forbidden",403)
        _ = db.rows("UPDATE accounts SET join_code=?,updated_at=?",[session_token(),now])
        return ui.redirect("/account/edit")
    if path.startswith("/account/custom_styles"):
        if not is_admin:
            return html("Forbidden",403)
        if verb == "PATCH" or verb == "PUT":
            _ = db.rows("UPDATE accounts SET custom_styles=?,updated_at=?",[f.fields.get("account[custom_styles]",""),now])
            return ui.redirect("/account/custom_styles/edit")
        return ui.page(db,signer,uid,req,"Custom styles",ui.form("/account/custom_styles",ui.textarea("account[custom_styles]",db.scalar("SELECT coalesce(custom_styles,'') FROM accounts LIMIT 1"),"Custom CSS"),"patch"))
    if path.startswith("/account/bots"):
        if not is_admin:
            return html("Forbidden",403)
        var segments = path.split("/")
        var bid = String()
        if len(segments)>3 and String(segments[3])!="new":
            bid = String(positive(String(segments[3])))
            if db.scalar("SELECT 1 FROM users WHERE id=? AND role=2 AND status=0",[bid])!="1":
                return html("Bot not found",404)
        if verb == "DELETE" and bid != "":
            deactivate(db,bid)
            return ui.redirect("/account/bots")
        if (verb == "PATCH" or verb == "PUT") and path.endswith("/key") and bid != "":
            _ = db.rows("UPDATE users SET bot_token=?,updated_at=? WHERE id=?",[session_token(),now,bid])
            return ui.redirect("/account/bots")
        if verb == "POST" or verb == "PATCH" or verb == "PUT":
            var name = f.fields.get("user[name]","")
            if String(name.strip())=="":
                return html("Name is required",422)
            if bid == "":
                _ = db.rows("INSERT INTO users(name,role,status,bot_token,created_at,updated_at) VALUES(?,2,0,?,?,?)",[name,session_token(),now,now])
                bid = db.last_id()
                _ = db.rows("INSERT OR IGNORE INTO memberships(room_id,user_id,created_at,updated_at) SELECT id,?,?,? FROM rooms WHERE type='Rooms::Open'",[bid,now,now])
            else:
                _ = db.rows("UPDATE users SET name=?,updated_at=? WHERE id=?",[name,now,bid])
            if "user[webhook_url]" in f.fields:
                _ = db.rows("DELETE FROM webhooks WHERE user_id=?",[bid])
                var url = f.fields["user[webhook_url]"]
                if url!="":
                    _ = db.rows("INSERT INTO webhooks(user_id,url,created_at,updated_at) VALUES(?,?,?,?)",[bid,url,now,now])
            return ui.redirect("/account/bots")
        if path.endswith("/new") or path.endswith("/edit"):
            var name = db.scalar("SELECT name FROM users WHERE id=?",[bid])
            var fields = ui.input("user[name]",name,"Name the bot")+ui.input("user[webhook_url]",db.scalar("SELECT url FROM webhooks WHERE user_id=?",[bid]),"Webhook URL")
            return ui.page(db,signer,uid,req,"Chat bot",ui.form("/account/bots"+("/"+bid if bid!="" else ""),fields,"patch" if bid!="" else "post"))
        var bots = db.rows("SELECT id,name,bot_token FROM users WHERE role=2 AND status=0 ORDER BY lower(name)")
        var body = String('<a href="/account/bots/new">Add a bot</a>')
        var rid = db.scalar("SELECT id FROM rooms WHERE type='Rooms::Open' ORDER BY id LIMIT 1")
        for bot in bots:
            body += '<a href="/account/bots/'+bot[0]+'/edit">Edit '+escape(bot[1])+'</a>'+ui.input("command","curl -d 'Hello' http://"+req.header("host")+"/rooms/"+rid+"/"+bot[0]+"-"+bot[2]+"/messages","curl command for posting messages")
        return ui.page(db,signer,uid,req,"Chat bots",body)
    var segments = path.split("/")
    if len(segments)>=3 and String(segments[1])=="users" and String(segments[2])!="me":
        var target = String(segments[2])
        if len(segments)==3:
            var users = db.rows("SELECT name,coalesce(bio,''),role FROM users WHERE id=?",[target])
            if len(users)==0:
                return html("User not found",404)
            var v = Dict[String,String]()
            views.set_user(db,signer,v,target)
            var body = '<img class="avatar" src="'+escape(v["creator_avatar"])+'"><p>'+escape(users[0][1])+'</p>'
            body += ui.form("/rooms/directs",'<input type="hidden" name="user_ids[]" value="'+target+'">',"post","Ping "+users[0][0])
            if is_admin:
                var url = req.origin()+"/session/transfers/"+signer.signed_id(db,target,"user/transfer",4)
                body += ui.input("transfer",url,"Account recovery link")
            return ui.page(db,signer,uid,req,users[0][0],body)
        if len(segments)==4 and String(segments[3])=="ban":
            if not is_admin:
                return html("Forbidden",403)
            if verb=="POST":
                _ = db.rows("INSERT INTO bans(user_id,ip_address,created_at,updated_at) SELECT user_id,coalesce(ip_address,''),?,? FROM sessions WHERE user_id=?",[now,now,target])
                _ = db.rows("UPDATE users SET status=2,updated_at=? WHERE id=?",[now,target])
                _ = db.rows("DELETE FROM sessions WHERE user_id=?",[target])
            elif verb=="DELETE":
                _ = db.rows("DELETE FROM bans WHERE user_id=?",[target])
                _ = db.rows("UPDATE users SET status=0,updated_at=? WHERE id=?",[now,target])
            else:
                return html("Not found",404)
            return ui.redirect("/users/"+target)
    return html("",0)
