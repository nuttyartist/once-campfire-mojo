from std.ffi import external_call
from database import Database
from http import Request, Response, html, conditional
from text import params, positive, token, plain_text, escape, search_query
import views
import jobs
import richtext
import schema
import runtime
import controllers
import parameters
import accounts
import pubsub
import ui
import message_actions
import storage
from crypto import Signer, session_token, url_encode
from std.os import getenv

comptime MESSAGE_COLUMNS = (
    "SELECT"
    " m.id,m.client_message_id,m.created_at,m.creator_id,u.name,m.room_id,coalesce(r.name,'Direct"
    " message'),coalesce(rt.body,idx.body,'') FROM messages m LEFT JOIN users u ON"
    " u.id=m.creator_id JOIN rooms r ON r.id=m.room_id LEFT JOIN"
    " message_search_index idx ON idx.rowid=m.id LEFT JOIN"
    " action_text_rich_texts rt ON rt.record_id=m.id AND"
    " rt.record_type='Message' AND rt.name='body' "
)


struct App(Movable):
    var db: Database
    var signer: Signer
    var cache: Dict[String, String]
    var cache_bytes: Int
    var cache_limit: Int
    var version: String
    var expires: Int
    var login_attempts: Int
    var login_window: Int

    def __init__(out self, path: String, cache_limit: Int, initialize_schema: Bool = True) raises:
        self.db = Database(path)
        if initialize_schema:
            schema.initialize(self.db)
        self.signer = Signer()
        self.cache = Dict[String, String]()
        self.cache_bytes = 0
        self.cache_limit = cache_limit
        self.version = ""
        self.expires = 0
        self.login_attempts = 0
        self.login_window = 0

    def invalidate(mut self):
        self.cache.clear()
        self.cache_bytes = 0

    def handle(mut self, req: Request) raises -> String:
        var result: String
        try:
            result = self.handle_request(req.copy())
            storage.discard_prepared(self.db)
        except e:
            storage.discard_prepared(self.db)
            raise e^
        # Consume a migrated flash only when HTML has actually displayed it.
        if req.method=="GET" and req.cookie("_campfire_session")!="" and result.startswith("HTTP/1.1 200") and "Content-Type: text/html" in String(result.split("\r\n\r\n",maxsplit=1)[0]):
            var session = accounts.read_session(self.db,self.signer,req)
            if self.db.scalar("SELECT json_type(?,'$.flash')",[session])!="":
                session = self.db.scalar("SELECT json_remove(?,'$.flash')",[session])
                var end = result.find("\r\n")
                result = String(result[byte=:end+2])+accounts.session_header(self.db,self.signer,req,session)+String(result[byte=end+2:])
        return result^

    def handle_request(mut self, var req: Request) raises -> String:
        self.db.request_host = req.header("host")
        if req.method not in ["GET", "HEAD"] and self.db.scalar("SELECT 1 FROM bans WHERE ip_address=? LIMIT 1",[req.peer])=="1":
            return html("Too many requests",429).pack(False)
        if req.method == "HEAD":
            req.method = "GET"
        if req.path.startswith("/assets/") and req.method=="GET":
            return runtime.asset(req).pack(req.gzip())
        if req.path == "/up":
            return html('<html><body style="background-color: green"></body></html>').pack(False)
        if req.path == "/_bench/stats" and getenv("MOJO_BENCH_DIAGNOSTICS", "") == "1":
            return Response(200,jobs.stats(),"application/json","").pack(False)
        # Rails scopes these resources to Current.user, regardless of the URL id.
        var user_path = req.path.split("/")
        if len(user_path)>=4 and String(user_path[1])=="users" and String(user_path[3]) in ["profile","sidebar","push_subscriptions"]:
            req.path = "/users/me/"+"/".join(user_path[3:])
        var segments = req.path.split("/")
        if len(segments)>=5 and String(segments[1])=="rooms" and String(segments[4])=="messages":
            return self.bot(req.copy()).pack(req.gzip())
        var form = parameters.Form()
        if req.method != "GET":
            var site = req.header("sec-fetch-site")
            if site not in ["same-origin", "same-site"] and (site != "" or req.origin().startswith("https://")):
                return html("Cross-site request rejected",422).pack(False)
            var origin = req.header("origin")
            if origin != "" and origin != req.origin():
                return html("Origin rejected",422).pack(False)
            if not (req.method=="PUT" and req.path.startswith("/rails/active_storage/disk/")):
                form = parameters.parse(self.db,req)
            if req.method=="POST" and "_method" in form.fields:
                var override = form.fields["_method"].upper()
                if override=="PATCH" or override=="PUT" or override=="DELETE":
                    req.method = override
        if req.method!="GET" and req.method!="POST" and req.method!="PATCH" and req.method!="PUT" and req.method!="DELETE":
            return html("Method not supported",405).pack(False)
        if req.path=="/unfurl_link" and req.method=="POST":
            if self.user(req)=="":
                return accounts.request_login(self.db,self.signer,req).pack(False)
            return controllers.preview(form).pack(req.gzip())
        # Slow cryptography and remote validation do not own the SQLite writer.
        # Authorization and uniqueness are checked again in the write transaction.
        var preflight_uid = self.user(req) if req.method!="GET" else String()
        if req.method=="POST" and (req.path=="/first_run" or req.path.startswith("/join/")):
            var allowed = self.db.scalar("SELECT 1 FROM accounts LIMIT 1")!="1" if req.path=="/first_run" else self.db.scalar("SELECT 1 FROM accounts WHERE join_code=?",[String(req.path[byte=6:])])=="1"
            if allowed and form.fields.get("user[password]","")!="":
                form.password_digest = runtime.password_hash(form.fields.get("user[password]",""))
        if preflight_uid!="" and req.path=="/users/me/profile" and req.method in ["PATCH","PUT"] and form.fields.get("user[password]","")!="":
            form.password_digest = runtime.password_hash(form.fields.get("user[password]",""))
        if preflight_uid!="" and req.path=="/users/me/push_subscriptions" and req.method=="POST":
            form.endpoint_validated = controllers.valid_subscription(form)
        if preflight_uid!="" and req.path.startswith("/users/me/push_subscriptions/") and req.path.endswith("/test_notifications") and req.method=="POST":
            return controllers.route(self.db,self.signer,req,preflight_uid,form).pack(req.gzip())
        if req.method=="PUT" and req.path.startswith("/rails/active_storage/disk/"):
            var prepared = storage.preflight_direct(self.db,self.signer,req,preflight_uid,form)
            if prepared.status!=0:
                return prepared.pack(False)
        if req.method=="GET" and (req.path.startswith("/rails/active_storage/representations/") or req.path.endswith("/avatar") or req.path=="/account/logo"):
            storage.preflight_get(self.db,self.signer,req,self.user(req)!="")
        elif req.method!="GET" and (preflight_uid!="" or form.password_digest!=""):
            # New message creation prepares its separately parsed form in post().
            if not (len(segments)==4 and String(segments[1])=="rooms" and String(segments[3])=="messages" and req.method=="POST"):
                storage.preflight_form(self.db,self.signer,form)
        var mutation = req.method != "GET"
        _ = self.db.rows("BEGIN IMMEDIATE" if mutation or req.path.startswith("/rails/active_storage/") or req.path.endswith("/avatar") or req.path=="/account/logo" else "BEGIN")
        try:
            var result = html("",0)
            if req.path.startswith("/rails/active_storage/"):
                var storage_uid = self.user(req) if mutation else String()
                result = storage.route(self.db,self.signer,req,storage_uid,form)
            if result.status==0 and req.path.startswith("/users/") and req.path.endswith("/avatar") and req.method=="GET" and self.user(req)=="":
                result = accounts.request_login(self.db,self.signer,req)
            if result.status==0 and req.path.startswith("/join/") and self.user(req)!="":
                result = ui.redirect("/",302)
            if result.status==0:
                result = controllers.public(self.db,self.signer,req,form)
            if result.status!=0:
                if result.status>=400:
                    _ = self.db.rows("ROLLBACK")
                    storage.rollback(self.db)
                else:
                    _ = self.db.rows("COMMIT")
                    storage.commit(self.db)
                self.invalidate()
                return result.pack(req.gzip())
            if req.path=="/session/new" and req.method=="GET":
                _ = self.db.rows("COMMIT")
                if self.db.scalar("SELECT 1 FROM users LIMIT 1")!="1":
                    return ui.redirect("/first_run").pack(False)
                return html(views.login()).pack(req.gzip())
            if req.path=="/session" and req.method=="POST":
                _ = self.db.rows("COMMIT")
                return self.login(req).pack(req.gzip())
            # Preserve the read-workload snapshot/cache path and the write transaction.
            if (req.path=="/" or req.path=="/users/me/sidebar" or req.path=="/searches" or (len(segments)>=3 and String(segments[1])=="rooms" and String(segments[2])!="opens" and String(segments[2])!="closeds" and String(segments[2])!="directs" and (len(segments)==3 or (len(segments)==4 and (String(segments[3])=="messages" or String(segments[3]).startswith("@")))))) and req.method=="GET":
                var wire = self.read(req)
                _ = self.db.rows("COMMIT")
                return wire^
            if len(segments)==4 and String(segments[1])=="rooms" and String(segments[3])=="messages" and req.method=="POST":
                _ = self.db.rows("COMMIT")
                return self.post(req).pack(req.gzip())
            var uid = self.user(req)
            if uid=="":
                _ = self.db.rows("ROLLBACK")
                return accounts.request_login(self.db,self.signer,req).pack(False)
            result = controllers.route(self.db,self.signer,req,uid,form)
            if result.status==0:
                result = html("Not found",404)
            if result.status>=400:
                _ = self.db.rows("ROLLBACK")
                self.db.pending_events.clear()
                storage.rollback(self.db)
            else:
                if mutation and (req.path.startswith("/rooms/") or req.path.startswith("/account/")):
                    pubsub.refresh_sidebars(self.db,self.signer,req)
                _ = self.db.rows("COMMIT")
                storage.commit(self.db)
                pubsub.flush(self.db)
                if mutation:
                    self.invalidate()
            return result.pack(req.gzip())
        except e:
            self.db.pending_events.clear()
            try:
                _ = self.db.rows("ROLLBACK")
            except:
                pass
            storage.rollback(self.db)
            raise e^

    def bot(mut self, var req: Request) raises -> Response:
        var original_path = req.path
        var segments = original_path.split("/")
        if len(segments)<5 or len(segments)>8:
            return html("Not found",404)
        var rid = String(positive(String(segments[2])))
        var bot_key = String(segments[3]).split("-",maxsplit=1)
        if len(bot_key)!=2:
            return html("Not found",404)
        var uid = self.db.scalar("SELECT u.id FROM users u JOIN memberships mm ON mm.user_id=u.id WHERE u.id=? AND u.bot_token=? AND u.role=2 AND u.status=0 AND NOT EXISTS(SELECT 1 FROM bans WHERE user_id=u.id) AND mm.room_id=?",[String(bot_key[0]),String(bot_key[1]),rid])
        if uid=="":
            return html("Not found",404)
        if req.method=="GET" and len(segments)==5:
            var query = params(req.query)
            var direction = String("DESC")
            var where = String("WHERE m.room_id=? ")
            var args = List[String]([rid])
            var after = "after" in query
            if "before" in query or after:
                var anchor = query.get("after" if after else "before","")
                if self.db.scalar("SELECT id FROM messages WHERE id=? AND room_id=?",[anchor,rid])=="":
                    return html("Not found",404)
                where += "AND m.created_at "+(">" if after else "<")+" (SELECT created_at FROM messages WHERE id=?) "
                args.append(anchor)
                direction = "ASC" if after else "DESC"
            var rows = self.db.rows("SELECT * FROM ("+message_actions.COLUMNS+where+" ORDER BY m.created_at "+direction+",m.id "+direction+" LIMIT 40) ORDER BY 3,1",args)
            var entries = List[String]()
            for row in rows:
                entries.append(message_actions.wire_message(self.db,self.signer,row,req))
            var headers = "X-Total-Count: "+self.db.scalar("SELECT messages_count FROM rooms WHERE id=?",[rid])+"\r\n"
            if len(rows)>0:
                var anchor = rows[len(rows)-1 if after else 0][0]
                if self.db.scalar("SELECT 1 FROM messages WHERE room_id=? AND created_at "+(">" if after else "<")+" (SELECT created_at FROM messages WHERE id=?) LIMIT 1",[rid,anchor])=="1":
                    headers += "Link: <"+req.origin()+original_path+"?"+("after" if after else "before")+"="+anchor+'>; rel="next"\r\n'
            return Response(200,"["+",".join(entries)+"]","application/json",headers)
        var boost = len(segments)>=7 and String(segments[6])=="boosts"
        var raw = req.body
        req.path = "/rooms/"+rid+"/messages"
        var mid = String()
        if len(segments)>5:
            mid = String(positive(String(segments[5])))
            if self.db.scalar("SELECT id FROM messages WHERE id=? AND room_id=?",[mid,rid])=="":
                return html("Not found",404)
            req.path += "/"+mid
        var form = parameters.Form()
        if boost:
            if req.method=="POST" and String(raw.strip())=="":
                return html("Boost is empty",422)
            req.path = "/messages/"+mid+"/boosts"
            if len(segments)==8:
                req.path += "/"+String(positive(String(segments[7])))
            form.fields["boost[content]"] = raw
        elif req.header("content-type").startswith("multipart/form-data"):
            form = parameters.parse(self.db,req)
            if "attachment" in form.files:
                form.files["message[attachment]"] = form.files["attachment"].copy()
            if "attachment" in form.fields:
                form.fields["message[attachment]"] = form.fields["attachment"]
        else:
            req.body = "message[body]="+url_encode(raw)
            req.headers["content-type"] = "application/x-www-form-urlencoded"
            form.fields["message[body]"] = raw
        if req.method=="POST" and len(segments)==5:
            var cid = token()
            var response = self.post(req.copy(),uid,cid)
            if response.status==200:
                return html("",201,"Location: "+req.origin()+"/rooms/"+rid+"/messages/"+self.db.scalar("SELECT id FROM messages WHERE creator_id=? AND client_message_id=?",[uid,cid])+"\r\n")
            return response^
        if req.method not in ["PATCH","PUT","DELETE"] and not (boost and req.method=="POST" and len(segments)==7):
            return html("Not found",404)
        storage.preflight_form(self.db,self.signer,form)
        _ = self.db.rows("BEGIN IMMEDIATE")
        try:
            var result = message_actions.route(self.db,self.signer,req,uid,form)
            if result.status>=400 or result.status==0:
                _ = self.db.rows("ROLLBACK")
                storage.rollback(self.db)
                self.db.pending_events.clear()
                return result^
            var bid = self.db.last_id()
            _ = self.db.rows("COMMIT")
            storage.commit(self.db)
            pubsub.flush(self.db)
            self.invalidate()
            if req.method=="DELETE":
                return html("",204)
            if boost:
                return Response(201,message_actions.wire_boost(self.db,self.signer,bid,req),"application/json","")
            var row = self.db.rows(message_actions.COLUMNS+"WHERE m.id=?",[mid])[0].copy()
            return Response(200,message_actions.wire_message(self.db,self.signer,row,req),"application/json","")
        except e:
            _ = self.db.rows("ROLLBACK")
            storage.rollback(self.db)
            self.db.pending_events.clear()
            raise e^

    def user(mut self, req: Request) raises -> String:
        var tok = self.signer.verify_cookie(
            self.db, req.cookie("session_token")
        )
        if tok == "":
            return ""
        var rows = self.db.rows(
            (
                "SELECT u.id,s.id,s.last_active_at FROM sessions s JOIN users u"
                " ON u.id=s.user_id WHERE s.token=? AND u.status=0 AND u.role<>2 AND NOT"
                " EXISTS(SELECT 1 FROM bans b WHERE b.user_id=u.id)"
            ),
            [tok],
        )
        if len(rows) == 0:
            return ""
        # Same one-hour activity refresh as the upstream ports.
        if (
            self.db.scalar(
                "SELECT julianday(?)<julianday('now','-1 hour')", [rows[0][2]]
            )
            == "1"
        ):
            _ = self.db.rows(
                (
                    "UPDATE sessions SET last_active_at=strftime('%Y-%m-%d"
                    " %H:%M:%f','now'),updated_at=strftime('%Y-%m-%d"
                    " %H:%M:%f','now'),user_agent=?,ip_address=?"
                    " WHERE id=?"
                ),
                [req.header("user-agent"),req.peer, rows[0][1]],
            )
        return rows[0][0]

    def login(mut self, req: Request) raises -> Response:
        var attempts = self.db.scalar("INSERT INTO mojo_login_limits(ip,started,attempts) VALUES(?,unixepoch(),1) ON CONFLICT(ip) DO UPDATE SET attempts=CASE WHEN started<unixepoch()-180 THEN 1 ELSE attempts+1 END,started=CASE WHEN started<unixepoch()-180 THEN unixepoch() ELSE started END RETURNING attempts",[req.peer])
        _ = self.db.rows("DELETE FROM mojo_login_limits WHERE started<unixepoch()-180")
        if Int(attempts)>10:
            return html("Too many login attempts",429,"Retry-After: 180\r\n")
        var parsed = parameters.parse(self.db,req)
        var fields = parsed.fields.copy()
        var rows = self.db.rows(
            (
                "SELECT id,password_digest FROM users WHERE email_address=? AND"
                " status=0 AND NOT EXISTS(SELECT 1 FROM bans WHERE"
                " user_id=users.id)"
            ),
            [fields.get("email_address", "")],
        )
        var password = fields.get("password", "")
        var digest = String(
            "$2b$12$LQv3c1yqBWVHxkd0LHAkCOY5PuKOm8rUn40bmw8Khkw0lX./LZEGq"
        )
        if len(rows) > 0:
            digest = rows[0][1]
        var valid = external_call["crypto_password", Int](
            password.as_c_string_span(), digest.as_c_string_span()
        )
        if valid != 1 or len(rows) == 0:
            return html(views.login(), 401)
        var tok = session_token()
        var stamp = self.db.scalar("SELECT strftime('%Y-%m-%d %H:%M:%f','now')")
        _ = self.db.rows(
            (
                "INSERT INTO"
                " sessions(token,user_id,last_active_at,created_at,updated_at,ip_address,user_agent)"
                " VALUES(?,?,?,?,?,?,?)"
            ),
            [tok, rows[0][0], stamp, stamp, stamp, req.peer, req.header("user-agent")],
        )
        var expiry = self.db.scalar(
            "SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now','+20 years')"
        )
        self.invalidate()
        return html(
            "",
            302,
            "Location: "+accounts.post_login(self.db,self.signer,req)+"\r\n"+accounts.consume_return(self.db,self.signer,req)+"Set-Cookie: mojo_return_to=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0\r\nSet-Cookie: session_token="
            + self.signer.cookie(tok, expiry)
            + "; Path=/; HttpOnly; SameSite=Lax; Max-Age=631152000"+("; Secure" if req.origin().startswith("https://") else "")+"\r\n",
        )

    def read(mut self, req: Request) raises -> String:
        var uid = self.user(req)
        if uid == "":
            return accounts.request_login(self.db,self.signer,req).pack(False)
        if req.path == "/":
            var rid = self.db.scalar("SELECT room_id FROM memberships WHERE user_id=? AND room_id=?",[uid,req.cookie("last_room") if req.cookie("last_room")!="" else req.cookie("last_room_visited")])
            if rid=="":
                rid = self.db.scalar("SELECT room_id FROM memberships WHERE user_id=? ORDER BY room_id LIMIT 1",[uid])
            if rid=="":
                return ui.page(self.db,self.signer,uid,req,"Welcome to Campfire",'<p>You have no rooms yet.</p><a href="/rooms/opens/new">Create a room</a><a href="/rooms/directs/new">Start a direct message</a>').pack(req.gzip())
            return html("", 302, "Location: /rooms/" + rid + "\r\n").pack(False)
        var segments = req.path.split("/")
        var room_info = List[List[String]]()
        var rid = String()
        if len(segments) >= 3 and String(segments[1]) == "rooms":
            rid = String(positive(String(segments[2])))
            room_info = self.db.rows(
                (
                    "SELECT coalesce(r.name,'Direct message'),r.type FROM rooms"
                    " r JOIN memberships mm ON mm.room_id=r.id WHERE r.id=? AND"
                    " mm.user_id=?"
                ),
                [rid, uid],
            )
            if len(room_info) == 0:
                return html("Room not found", 404).pack(False)
        var generation = self.db.scalar("PRAGMA data_version")
        var now = external_call["os_now_ms", Int]()
        if self.version != generation or now > self.expires:
            self.invalidate()
            self.version = generation
            self.expires = now + 15000
        var key = (
            uid
            + ":"
            + req.target
            + ":"
            + String(req.gzip())
            + ":"
            + req.header("host")
            + ":"
            + req.header("user-agent")
            + ":"
            + req.header("turbo-frame")
            + ":"
            + req.cookie("last_room_visited")+req.cookie("last_room")+req.header("if-none-match")+req.cookie("_campfire_session")
        )
        if key in self.cache:
            return self.cache[key]
        var result: Response
        if req.path == "/users/me/sidebar":
            result = html(views.sidebar(self.db, self.signer, uid, req))
        elif req.path == "/searches":
            var fields = params(req.query)
            var query = search_query(fields.get("q", ""))
            var matches = List[List[String]]()
            if String(query.strip()) != "":
                var terms = List[String]()
                for word in query.split():
                    terms.append('"' + String(word).replace('"', '""') + '"')
                var literal = " AND ".join(terms)
                matches = self.db.rows(
                    "SELECT * FROM ("
                    + MESSAGE_COLUMNS
                    + "JOIN memberships mm ON mm.room_id=m.room_id WHERE"
                    " mm.user_id=? AND m.id IN (SELECT rowid FROM"
                    " message_search_index WHERE body MATCH ?) ORDER BY m.id"
                    " DESC LIMIT 100) ORDER BY 1",
                    [uid, literal],
                )
            result = html(
                views.search(self.db, self.signer, uid, req, query, matches)
            )
        elif rid != "" and (
            len(segments) == 3
            or (len(segments) == 4 and (String(segments[3]) == "messages" or String(segments[3]).startswith("@")))
        ):
            var values = params(req.query)
            var query_filter = String("WHERE m.room_id=? ")
            var args = List[String]([rid])
            var direction = String("DESC")
            if "before" in values or "after" in values:
                var before = "before" in values
                var anchor = String(
                    positive(values.get("before" if before else "after", ""))
                )
                if (
                    self.db.scalar(
                        "SELECT id FROM messages WHERE id=? AND room_id=?",
                        [anchor, rid],
                    )
                    == ""
                ):
                    return html("Message not found", 404).pack(False)
                query_filter += (
                    "AND m.created_at "
                    + ("<" if before else ">")
                    + " (SELECT created_at FROM messages WHERE id=?) "
                )
                args.append(anchor)
                direction = "DESC" if before else "ASC"
            var at_message = len(segments)==4 and String(segments[3]).startswith("@")
            if at_message:
                var anchor = String(String(segments[3])[byte=1:])
                if self.db.scalar("SELECT id FROM messages WHERE id=? AND room_id=?",[anchor,rid])!="":
                    query_filter += "AND m.id IN (SELECT id FROM (SELECT id FROM messages WHERE room_id=? AND created_at<(SELECT created_at FROM messages WHERE id=?) ORDER BY created_at DESC LIMIT 40) UNION ALL SELECT ? UNION ALL SELECT id FROM (SELECT id FROM messages WHERE room_id=? AND created_at>(SELECT created_at FROM messages WHERE id=?) ORDER BY created_at LIMIT 40)) "
                    args.append(rid)
                    args.append(anchor)
                    args.append(anchor)
                    args.append(rid)
                    args.append(anchor)
                    direction = "ASC"
            var rows = self.db.rows(
                "SELECT * FROM ("
                + MESSAGE_COLUMNS
                + query_filter
                + "ORDER BY m.created_at "
                + direction
                + ",m.id "
                + direction
                + (" LIMIT 81) ORDER BY 3,1" if at_message and direction=="ASC" else " LIMIT 40) ORDER BY 3,1"),
                args,
            )
            if len(segments) == 4 and not at_message:
                result = html(
                    views.messages(self.db, self.signer, rows),
                    204 if len(rows) == 0 else 200,
                )
            else:
                var kind = room_info[0][1].replace("::", "_").lower()
                result = html(
                    views.room(
                        self.db,
                        self.signer,
                        uid,
                        req,
                        room_info[0][0],
                        rid,
                        kind,
                        rows,
                    ),
                    200,
                    "Set-Cookie: last_room="
                    + rid
                    + "; Path=/; SameSite=Lax\r\n",
                )
        else:
            return html("Not found", 404).pack(False)
        var wire = conditional(result^,req).pack(req.gzip())
        if (
            self.cache_limit > 0
            and wire.byte_length() + key.byte_length() < self.cache_limit
        ):
            if (
                self.cache_bytes + wire.byte_length() + key.byte_length()
                > self.cache_limit
            ):
                self.invalidate()
            self.cache_bytes += wire.byte_length() + key.byte_length()
            self.cache[key] = wire
        return wire^

    def post(mut self, req: Request, uid_override: String = "", cid_override: String = "") raises -> Response:
        var segments = req.path.split("/")
        if (
            len(segments) != 4
            or String(segments[1]) != "rooms"
            or String(segments[3]) != "messages"
        ):
            return html("Not found", 404)
        var rid = String(positive(String(segments[2])))
        var parsed = parameters.parse(self.db,req)
        if uid_override!="":
            if "attachment" in parsed.files:
                parsed.files["message[attachment]"] = parsed.files["attachment"].copy()
            if "attachment" in parsed.fields:
                parsed.fields["message[attachment]"] = parsed.fields["attachment"]
        var fields = parsed.fields.copy()
        var raw_body = fields.get("message[body]", "")
        var text = richtext.resolved(self.db,self.signer,raw_body,True)
        var canonical = richtext.canonical(self.db,raw_body)
        var has_file = "message[attachment]" in parsed.files or fields.get("message[attachment]","") != ""
        if (text.strip() == "" and not has_file) or text.byte_length() > 65536:
            return html("Text message must contain 1–65536 bytes", 422)
        var client_id = cid_override if cid_override!="" else fields.get("message[client_message_id]", "")
        if client_id == "":
            client_id = token()
        if client_id.byte_length() > 128:
            return html("Client ID too long", 422)
        if has_file:
            var uid = uid_override if uid_override!="" else self.user(req)
            if uid=="":
                return html("Unauthorized",401)
            if self.db.scalar("SELECT 1 FROM memberships WHERE room_id=? AND user_id=?",[rid,uid])!="1":
                return html("Room not found",404)
            storage.preflight_form(self.db,self.signer,parsed)
        _ = self.db.rows("BEGIN IMMEDIATE")
        try:
            var uid = uid_override if uid_override != "" else self.user(req)
            if uid == "":
                _ = self.db.rows("ROLLBACK")
                return html("Unauthorized", 401)
            var rooms = self.db.rows(
                (
                    "SELECT r.type FROM rooms r JOIN memberships mm ON"
                    " mm.room_id=r.id WHERE r.id=? AND mm.user_id=?"
                ),
                [rid, uid],
            )
            if len(rooms) == 0:
                _ = self.db.rows("ROLLBACK")
                return html("Room not found", 404)
            var now = self.db.scalar(
                "SELECT strftime('%Y-%m-%d %H:%M:%f','now')"
            )
            _ = self.db.rows(
                (
                    "INSERT INTO"
                    " messages(client_message_id,created_at,creator_id,room_id,updated_at)"
                    " VALUES(?,?,?,?,?)"
                ),
                [client_id, now, uid, rid, now],
            )
            var mid = self.db.last_id()
            if has_file:
                var blob: String
                if "message[attachment]" in parsed.files:
                    blob = storage.upload(self.db,parsed.files["message[attachment]"])
                else:
                    blob = self.signer.verify(self.db,"ActiveStorage",fields.get("message[attachment]",""),"blob_id",False)
                if blob=="" or self.db.scalar("SELECT 1 FROM active_storage_blobs WHERE id=?",[blob])!="1":
                    raise Error("Invalid attachment")
                storage.verify_file(self.db,blob)
                storage.attach(self.db,blob,"Message",mid,"attachment")
                storage.prepare(self.db,blob)
                if text.strip()=="":
                    text = self.db.scalar("SELECT filename FROM active_storage_blobs WHERE id=?",[blob])
            _ = self.db.rows(
                (
                    "INSERT INTO"
                    " action_text_rich_texts(name,body,record_type,record_id,created_at,updated_at)"
                    " VALUES('body',?,'Message',?,?,?)"
                ),
                [canonical, mid, now, now],
            )
            richtext.sync_embeds(self.db,self.signer,self.db.last_id(),canonical)
            _ = self.db.rows(
                "INSERT INTO message_search_index(rowid,body) VALUES(?,?)",
                [mid, text],
            )
            _ = self.db.rows(
                (
                    "UPDATE rooms SET"
                    " updated_at=? WHERE id=?"
                ),
                [now, rid],
            )
            _ = self.db.rows(
                (
                    "UPDATE memberships SET unread_at=?,updated_at=? WHERE"
                    " room_id=? AND user_id<>? AND involvement<>'invisible' AND"
                    " (connected_at IS NULL OR connected_at <"
                    " datetime('now','-60 seconds'))"
                    " AND (unread_at IS NULL OR (SELECT type FROM rooms WHERE id=room_id)='Rooms::Direct')"
                ),
                [now, now, rid, uid],
            )
            jobs.enqueue(self.db,mid)
            var rows = self.db.rows(MESSAGE_COLUMNS + "WHERE m.id=?", [mid])
            var body = (
                '<turbo-stream action="append" target="messages_'
                + rooms[0][0].replace("::", "_").lower()
                + "_"
                + rid
                + '"><template>'
                + views.message(self.db, self.signer, rows[0])
                + "</template></turbo-stream>"
            )
            jobs.broadcast(self.db, rid, rooms[0][0], mid, body)
            jobs.webhook_candidates(
                self.db, rid, uid, rooms[0][0] == "Rooms::Direct"
            )
            _ = self.db.rows("COMMIT")
            storage.commit(self.db)
            pubsub.flush(self.db)
            jobs.count(0)
            self.invalidate()
            return Response(
                200, body, "text/vnd.turbo-stream.html; charset=utf-8", ""
            )
        except e:
            self.db.pending_events.clear()
            try:
                _ = self.db.rows("ROLLBACK")
            except:
                pass
            storage.rollback(self.db)
            raise e^
