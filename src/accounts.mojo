# Account, session, profile and administrator policies from the Rails controllers.
from std.ffi import external_call
from database import Database
from crypto import Signer, session_token, json_string, base64, url_encode
from text import decode
from http import Request, Response, html
from parameters import Form
from text import escape, token, positive, params
import templates
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
    return html("",303,"Location: "+post_login(db,signer,req)+"\r\n"+consume_return(db,signer,req)+"Set-Cookie: mojo_return_to=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0\r\nSet-Cookie: session_token="+signer.cookie(tok,expiry)+"; Path=/; HttpOnly; SameSite=Lax; Max-Age=631152000"+("; Secure" if req.origin().startswith("https://") else "")+"\r\n")


def signup(mut db: Database, mut signer: Signer, req: Request, f: Form, first: Bool) raises -> Response:
    if first and db.scalar("SELECT 1 FROM accounts LIMIT 1") == "1":
        return ui.redirect("/")
    if not first:
        var code = String(req.path[byte=6:])
        if db.scalar("SELECT 1 FROM accounts WHERE join_code=?",[code]) != "1":
            return html("Invitation not found",404)
    if req.method == "GET":
        var title = "Set up Campfire" if first else "Join Campfire"
        var v = views.context(db,signer,"",req,title)
        var fields = ui.avatar_upload("user[avatar]",templates.asset("default-avatar.svg"),"Add your avatar")+ui.field("user[name]","","Name","person","text",'required autofocus autocomplete="name"')+ui.field("user[email_address]","","Email address","email","email",'required autocomplete="username"')+ui.field("user[password]","","Password","password","password",'required maxlength="72" autocomplete="new-password"')
        v["content"] = '<div class="center max-width"><section class="nametag u-relative"><div class="flex justify-center align-center pad-block"><img class="nametag__lanyard" aria-hidden="true" src="'+templates.asset("lanyard.svg")+'"></div><div class="nametag__inner flex flex-column gap"><h1 class="txt-large txt-align-center">'+title+'</h1>'+ui.form(req.path,fields,"post","Save")+'</div></section></div>'
        return html(views.layout(v,req))
    if req.method != "POST":
        return html("Not found",404)
    var name = String(f.fields.get("user[name]","").strip())
    var email = f.fields.get("user[email_address]","")
    if name == "" or email == "" or "@" not in email:
        return html("Name and email address are required",422)
    if db.scalar("SELECT 1 FROM users WHERE email_address=?",[email]) == "1":
        return ui.redirect("/session/new")
    var digest = f.password_digest
    if digest=="":
        return html("Password is required",422)
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
        return html("",303,"Location: /session/new\r\nSet-Cookie: _campfire_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0\r\nSet-Cookie: session_token=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0\r\n")
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
                _ = db.rows("UPDATE users SET password_digest=?,updated_at=? WHERE id=?",[f.password_digest,now,uid])
            return ui.redirect(path)
        if verb!="GET":
            return html("Not found",404)
        var u = db.rows("SELECT name,coalesce(email_address,''),coalesce(bio,''),strftime('%Y%m%d%H%M%S',updated_at) FROM users WHERE id=?",[uid])[0].copy()
        var v = views.context(db,signer,uid,req,u[0])
        var fields = ui.avatar_upload("user[avatar]",signer.avatar(uid,u[3]),"Upload avatar")+ui.field("user[name]",u[0],"Enter your name","person","text",'required autocomplete="name"')+ui.field("user[email_address]",u[1],"Enter your email address","email","email",'autocomplete="username"')+ui.field("user[password]","","Change password","password","password",'maxlength="72" autocomplete="new-password"')+ui.textarea("user[bio]",u[2],"A few words about yourself…")
        var url = req.origin()+"/session/transfers/"+signer.signed_id(db,uid,"user/transfer",4)
        var transfer_html = '<fieldset><legend>'+ui.icon("laptop",36)+ui.icon("transfer",36)+ui.icon("mobile-phone",36)+'</legend><label class="for-screen-reader" for="session_transfer_url">Use this link to login automatically on another device</label><input class="input" id="session_transfer_url" readonly value="'+escape(url)+'">'+ui.share_link(url)+'</fieldset>'
        var content = templates.install_instructions(v)+ui.form(path,fields,"patch")
        if db.scalar("SELECT 1 FROM active_storage_attachments WHERE record_type='User' AND record_id=? AND name='avatar'",[uid])=="1":
            content += ui.form("/users/"+uid+"/avatar","","delete","Delete avatar")
        content += '<div class="margin-block pad-inline pad-block fill-shade border-radius"><menu class="flex flex-column gap margin-none pad">'
        for room in db.rows("SELECT r.id,coalesce(r.name,''),r.type,m.involvement FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? ORDER BY (r.type='Rooms::Direct'),lower(r.name),r.id",[uid]):
            var name = room[1]
            if room[2]=="Rooms::Direct":
                name = db.scalar("SELECT group_concat(name,', ') FROM (SELECT u.name FROM users u JOIN memberships m ON m.user_id=u.id WHERE m.room_id=? AND (u.id<>? OR (SELECT count(*) FROM memberships WHERE room_id=?)=1) ORDER BY lower(u.name))",[room[0],uid,room[0]])
            content += '<li class="flex align-center gap margin-none min-width membership-item"><a class="overflow-ellipsis txt-primary txt-undecorated" href="/rooms/'+room[0]+'"><strong>'+escape(name)+'</strong></a><hr class="separator" aria-hidden="true"><turbo-frame id="involvement_'+room[2].replace("::","_").lower()+'_'+room[0]+'"><a href="/rooms/'+room[0]+'/involvement">Notifications: '+room[3]+'</a></turbo-frame></li>'
        content += '</menu></div><a href="/users/me/push_subscriptions">Manage push subscriptions</a>'+transfer_html
        v["content"] = '<section class="panel flex flex-column gap" style="view-transition-name: avatar-'+uid+'">'+content+'</section>'
        v["nav"] = '<a class="btn" href="/">'+ui.icon("arrow-left")+'<span class="for-screen-reader">Back to Campfire</span></a>'+ui.form("/session",'<input type="hidden" name="push_subscription_endpoint" data-sessions-target="pushSubscriptionEndpoint">',"delete","Log out").replace('<form ', '<form data-controller="sessions" ').replace('type="submit" class=', 'type="submit" data-action="sessions#logout:prevent" class=')
        return html(views.layout(v,req))
    if path=="/account/users" or path=="/account/users.turbo_stream":
        if verb!="GET":
            return html("Not found",404)
        var page = max(1,min(100000,Int(params(req.query).get("page","1"))))
        var rows = member_rows(db,is_admin,page)
        var body = ui.stream("replace","next_page_container",user_list(db,signer,rows,uid,is_admin))
        if len(rows)==500:
            body += ui.stream("append","account_users",next_members_page(page+1))
        return Response(200,body,"text/vnd.turbo-stream.html; charset=utf-8","")
    if path == "/account/edit" or path == "/account":
        if verb == "PATCH" or verb == "PUT":
            if not is_admin:
                return html("Forbidden",403)
            var name = f.fields.get("account[name]",db.scalar("SELECT name FROM accounts LIMIT 1"))
            if String(name.strip())=="":
                return html("Name is required",422)
            storage.profile_upload(db,f,db.scalar("SELECT id FROM accounts LIMIT 1"),True)
            _ = db.rows("UPDATE accounts SET name=?,updated_at=?",[name,now])
            var restricted = f.fields.get("account[settings][restrict_room_creation_to_administrators]","")
            if restricted != "":
                _ = db.rows("UPDATE accounts SET settings=json_set(coalesce(settings,'{}'),'$.restrict_room_creation_to_administrators',json(?))",["true" if restricted=="1" or restricted=="true" else "false"])
            return ui.redirect("/account/edit")
        if verb!="GET":
            return html("Not found",404)
        var row = db.rows("SELECT name,join_code,coalesce(json_extract(settings,'$.restrict_room_creation_to_administrators'),0) FROM accounts LIMIT 1")[0].copy()
        var content = String()
        if is_admin:
            content = ui.form("/account",ui.avatar_upload("account[logo]","/account/logo","Upload logo")+ui.field("account[name]",row[0],"Name this account","person","text",'required'),"patch")
            if db.scalar("SELECT 1 FROM active_storage_attachments WHERE record_type='Account' AND name='logo' LIMIT 1")=="1":
                content += ui.form("/account/logo","","delete","Delete logo")
            content += ui.form("/account",'<input type="hidden" name="account[settings][restrict_room_creation_to_administrators]" value="0"><label class="flex align-center gap"><input type="checkbox" name="account[settings][restrict_room_creation_to_administrators]" value="1"'+(' checked' if row[2]=="1" else '')+'>Must be admin to create new rooms</label>',"patch","Save room permissions")
            content += '<div class="flex align-center gap"><a class="btn" href="/account/bots">'+ui.icon("bot")+'<span>Set up chat bots</span></a><a class="btn" href="/account/custom_styles/edit">'+ui.icon("art")+'<span>Custom styles</span></a></div>'
        else:
            content += '<img src="/account/logo" alt="Account logo" width="48" height="48"><h1>'+escape(row[0])+'</h1>'
        var invite = req.origin()+"/join/"+row[1]
        content += '<div class="margin-block pad-inline pad-block fill-shade border-radius"><label class="flex flex-column gap"><strong>Share to invite more people</strong><input class="input" id="invite_url" readonly value="'+escape(invite)+'"></label>'+ui.share_link(invite,True)
        if is_admin:
            content += ui.form("/account/join_code","","post","Regenerate join link")
        content += '<hr class="separator full-width"><menu class="flex flex-column gap margin-none pad"><turbo-frame id="account_users">'
        content += user_list(db,signer,db.rows("SELECT id,name,role,status,strftime('%Y%m%d%H%M%S',updated_at) FROM users WHERE role=1 AND (status=0 OR (?='1' AND status=2)) ORDER BY lower(name),id",["1" if is_admin else "0"]),uid,is_admin)
        var members = member_rows(db,is_admin,1)
        content += user_list(db,signer,members,uid,is_admin)
        if len(members)==500:
            content += next_members_page(2)
        content += '</turbo-frame></menu></div>'
        return ui.page(db,signer,uid,req,"Account",content)
    if path=="/account/logo" and verb=="DELETE":
        if not is_admin:
            return html("Forbidden",403)
        storage.detach(db,"Account",db.scalar("SELECT id FROM accounts LIMIT 1"),"logo")
        return ui.redirect("/account/edit")
    if path.startswith("/users/") and path.endswith("/avatar") and verb=="DELETE":
        storage.detach(db,"User",uid,"avatar")
        return ui.redirect("/users/me/profile")
    if path.startswith("/account/users/"):
        if not is_admin:
            return html("Forbidden",403)
        var user_id = String(positive(String(path[byte=15:])))
        if db.scalar("SELECT 1 FROM users WHERE id=? AND status=0",[user_id])!="1":
            return html("Not found",404)
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
        if verb!="GET":
            return html("Not found",404)
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
            storage.profile_upload(db,f,bid)
            if "user[webhook_url]" in f.fields:
                _ = db.rows("DELETE FROM webhooks WHERE user_id=?",[bid])
                var url = f.fields["user[webhook_url]"]
                if url!="":
                    _ = db.rows("INSERT INTO webhooks(user_id,url,created_at,updated_at) VALUES(?,?,?,?)",[bid,url,now,now])
            return ui.redirect("/account/bots")
        if verb!="GET":
            return html("Not found",404)
        if path.endswith("/new") or path.endswith("/edit"):
            var name = db.scalar("SELECT name FROM users WHERE id=?",[bid])
            var avatar = signer.avatar(bid,db.scalar("SELECT strftime('%Y%m%d%H%M%S',updated_at) FROM users WHERE id=?",[bid])) if bid!="" else templates.asset("default-bot-avatar.svg")
            var fields = ui.avatar_upload("user[avatar]",avatar,"Upload bot avatar")+ui.field("user[name]",name,"Name the bot","bot","text","required")+ui.field("user[webhook_url]",db.scalar("SELECT url FROM webhooks WHERE user_id=?",[bid]),"Webhook URL","web","url")
            return ui.page(db,signer,uid,req,"Chat bot",ui.form("/account/bots"+("/"+bid if bid!="" else ""),fields,"patch" if bid!="" else "post"))
        var bots = db.rows("SELECT id,name,bot_token FROM users WHERE role=2 AND status=0 ORDER BY lower(name)")
        var body = String('<a href="/account/bots/new">Add a bot</a>')
        var rid = db.scalar("SELECT id FROM rooms WHERE type='Rooms::Open' ORDER BY id LIMIT 1")
        for bot in bots:
            body += '<a href="/account/bots/'+bot[0]+'/edit">Edit '+escape(bot[1])+'</a>'+ui.input("command","curl -d 'Hello' "+req.origin()+"/rooms/"+rid+"/"+bot[0]+"-"+bot[2]+"/messages","curl command for posting messages")+ui.form("/account/bots/"+bot[0]+"/key","","patch","Regenerate bot key")+ui.form("/account/bots/"+bot[0],"","delete","Delete "+bot[1])
        return ui.page(db,signer,uid,req,"Chat bots",body)
    var segments = path.split("/")
    if len(segments)>=3 and String(segments[1])=="users" and String(segments[2])!="me":
        var target = String(segments[2])
        if len(segments)==3 and verb=="GET":
            var users = db.rows("SELECT name,coalesce(bio,''),role FROM users WHERE id=?",[target])
            if len(users)==0:
                return html("User not found",404)
            var v = Dict[String,String]()
            views.set_user(db,signer,v,target)
            var body = '<img class="avatar" src="'+escape(v["creator_avatar"])+'"><p>'+escape(users[0][1])+'</p>'
            body += ui.form("/rooms/directs",'<input type="hidden" name="user_ids[]" value="'+target+'">',"post","Ping "+users[0][0])
            if is_admin:
                var url = req.origin()+"/session/transfers/"+signer.signed_id(db,target,"user/transfer",4)
                body += ui.input("transfer",url,"Account recovery link")+ui.share_link(url)
                var banned = db.scalar("SELECT status FROM users WHERE id=?",[target])=="2"
                body += ui.form("/users/"+target+"/ban","","delete" if banned else "post","Unban "+users[0][0] if banned else "Ban "+users[0][0])
            return ui.page(db,signer,uid,req,users[0][0],body)
        if len(segments)==4 and String(segments[3])=="ban":
            if not is_admin:
                return html("Forbidden",403)
            if db.scalar("SELECT 1 FROM users WHERE id=?",[target])!="1":
                return html("User not found",404)
            if verb=="POST":
                _ = db.rows("DELETE FROM bans WHERE user_id=?",[target])
                _ = db.rows("INSERT INTO mojo_jobs(message_id,kind) VALUES(?,'remove_banned_content')",[target])
                _ = db.rows("INSERT INTO bans(user_id,ip_address,created_at,updated_at) SELECT DISTINCT user_id,ip_address,?,? FROM sessions WHERE user_id=? AND trim(coalesce(ip_address,''))<>''",[now,now,target])
                _ = db.rows("UPDATE users SET status=2,updated_at=? WHERE id=?",[now,target])
                _ = db.rows("DELETE FROM sessions WHERE user_id=?",[target])
            elif verb=="DELETE":
                _ = db.rows("DELETE FROM bans WHERE user_id=?",[target])
                _ = db.rows("UPDATE users SET status=0,updated_at=? WHERE id=?",[now,target])
            else:
                return html("Not found",404)
            return ui.redirect("/users/"+target)
    return html("",0)


def member_rows(mut db: Database, admin: Bool, page: Int) raises -> List[List[String]]:
    return db.rows("SELECT id,name,role,status,strftime('%Y%m%d%H%M%S',updated_at) FROM users WHERE role=0 AND (status=0 OR (?='1' AND status=2)) ORDER BY lower(name),id LIMIT 500 OFFSET ?",["1" if admin else "0",String((page-1)*500)])


def next_members_page(page: Int) -> String:
    return '<turbo-frame id="next_page_container" loading="lazy" src="/account/users.turbo_stream?page='+String(page)+'" class="flex center"><div class="spinner center"></div></turbo-frame>'


def user_list(mut db: Database, mut signer: Signer, rows: List[List[String]], uid: String, admin: Bool) raises -> String:
    var content = String()
    for user in rows:
        content += '<li class="flex align-center gap margin-none '+('banned' if user[3]=="2" else '')+'"><figure class="avatar flex-item-no-shrink" style="--avatar-size:3.75ch"><a href="/users/'+user[0]+'" data-turbo-frame="_top"><img loading="lazy" src="'+escape(signer.avatar(user[0],user[4]))+'" alt="'+escape(user[1])+'"></a></figure><a class="min-width overflow-ellipsis" href="/users/'+user[0]+'" data-turbo-frame="_top"><strong>'+escape(user[1])+'</strong></a><hr class="separator">'
        if admin and user[3]=="0" and user[0]!=uid:
            content += ui.form("/account/users/"+user[0],'<label class="for-screen-reader" for="role_user_'+user[0]+'">Role of '+escape(user[1])+'</label><select id="role_user_'+user[0]+'" name="user[role]"><option value="member">Member</option><option value="administrator"'+(' selected' if user[2]=="1" else '')+'>Administrator</option></select>',"patch","Change role")+ui.form("/account/users/"+user[0],"","delete","Delete "+user[1])
        elif user[0]==uid:
            content += '<a class="btn" href="/users/me/profile" data-turbo-frame="_top">My settings</a>'
        content += '</li>'
    return content^


def request_login(mut db: Database, mut signer: Signer, req: Request) raises -> Response:
    var target = req.target
    if target.byte_length()>2048:
        target = "/"
    var session = read_session(db,signer,req)
    session = db.scalar("SELECT json_set(?,'$.return_to_after_authenticating',?)",[session,req.origin()+target])
    return html("",302,"Location: /session/new\r\n"+session_header(db,signer,req,session))


def post_login(mut db: Database, mut signer: Signer, req: Request) raises -> String:
    var path = db.scalar("SELECT coalesce(json_extract(?,'$.return_to_after_authenticating'),'')",[read_session(db,signer,req)])
    if path.startswith(req.origin()+"/"):
        var relative_path = String(path[byte=req.origin().byte_length():])
        path = relative_path^
    if path=="":
        path = signer.verify(db,"signed cookie",decode(req.cookie("mojo_return_to")),"cookie.mojo_return_to",False)
    if not path.startswith("/") or path.startswith("//") or "\\" in path or "\r" in path or "\n" in path or path.startswith("/session"):
        return "/"
    return path


def read_session(mut db: Database, mut signer: Signer, req: Request) raises -> String:
    var session = signer.decrypt_cookie(db,req.cookie("_campfire_session"))
    if session=="" or db.scalar("SELECT json_type(?)",[session])!="object":
        return '{"session_id":'+json_string(session_token())+'}'
    return session^


def session_header(mut db: Database, mut signer: Signer, req: Request, session: String) raises -> String:
    var expiry = db.scalar("SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now','+20 years')")
    return "Set-Cookie: _campfire_session="+signer.encrypted_cookie(session,expiry)+"; Path=/; HttpOnly; SameSite=Lax; Max-Age=631152000"+("; Secure" if req.origin().startswith("https://") else "")+"\r\n"


def consume_return(mut db: Database, mut signer: Signer, req: Request) raises -> String:
    return session_header(db,signer,req,db.scalar("SELECT json_remove(?,'$.return_to_after_authenticating')",[read_session(db,signer,req)]))
