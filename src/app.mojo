from std.ffi import external_call
from database import Database
from http import Request, Response, html
from text import params, positive, token, plain_text, escape
import views
import jobs
import richtext
from crypto import Signer, session_token
from std.os import getenv

comptime MESSAGE_COLUMNS = (
    "SELECT"
    " m.id,m.client_message_id,m.created_at,m.creator_id,u.name,m.room_id,coalesce(r.name,'Direct"
    " message'),coalesce(rt.body,idx.body,'') FROM messages m JOIN users u ON"
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

    def __init__(out self, path: String, cache_limit: Int) raises:
        self.db = Database(path)
        self.signer = Signer()
        self.cache = Dict[String, String]()
        self.cache_bytes = 0
        self.cache_limit = cache_limit
        self.version = ""
        self.expires = 0
        self.login_attempts = 0
        self.login_window = 0
        _ = self.db.rows(
            "CREATE INDEX IF NOT EXISTS"
            " index_messages_on_room_id_and_created_at ON"
            " messages(room_id,created_at)"
        )
        var columns = self.db.rows("PRAGMA table_info(rooms)")
        var has_count = False
        for column in columns:
            if column[1] == "messages_count":
                has_count = True
        if not has_count:
            _ = self.db.rows(
                "ALTER TABLE rooms ADD COLUMN messages_count INTEGER NOT NULL"
                " DEFAULT 0"
            )
            _ = self.db.rows(
                "UPDATE rooms SET messages_count=(SELECT COUNT(*) FROM messages"
                " WHERE room_id=rooms.id)"
            )

    def invalidate(mut self):
        self.cache.clear()
        self.cache_bytes = 0

    def handle(mut self, req: Request) raises -> String:
        if (
            req.method != "GET"
            and req.method != "HEAD"
            and req.method != "POST"
        ):
            return html("Method not supported", 400).pack(False)
        if req.method == "POST":
            var site = req.header("sec-fetch-site")
            if site != "" and site != "same-origin" and site != "same-site":
                return html("Cross-site request rejected", 422).pack(False)
            var origin = req.header("origin")
            if origin != "" and origin != "http://" + req.header("host"):
                return html("Origin rejected", 422).pack(False)
            if not req.header("content-type").startswith(
                "application/x-www-form-urlencoded"
            ):
                return html(
                    "Only form-encoded text messages are supported", 422
                ).pack(False)
        if (
            req.path == "/_bench/stats"
            and getenv("MOJO_BENCH_DIAGNOSTICS", "") == "1"
        ):
            return Response(200, jobs.stats(), "application/json", "").pack(
                False
            )
        if req.path == "/up":
            return html(
                '<html><body style="background-color: green"></body></html>'
            ).pack(False)
        if req.path == "/assets/campfire.css":
            return Response(
                200,
                (
                    "body{font:16px system-ui;max-width:1000px;margin:2rem"
                    " auto;padding:0"
                    " 1rem;background:#f5f3ee;color:#222}header{display:flex;justify-content:space-between}article{background:white;padding:1rem;margin:1rem"
                    " 0;border-radius:8px}h2,time{font-size:.75rem;color:#666}textarea{width:95%;min-height:5rem}label{display:block;margin:1rem"
                    " 0}a{color:#92511d}"
                ),
                "text/css",
                "",
            ).pack(req.gzip())
        if req.path == "/session/new" and req.method == "GET":
            return html(views.login()).pack(req.gzip())
        if req.path == "/session" and req.method == "POST":
            return self.login(req).pack(req.gzip())
        if req.method == "POST":
            return self.post(req).pack(req.gzip())
        # One SQLite snapshot covers authentication, permission checks, and data.
        _ = self.db.rows("BEGIN")
        try:
            var wire = self.read(req)
            _ = self.db.rows("COMMIT")
            return wire^
        except e:
            _ = self.db.rows("ROLLBACK")
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
                " ON u.id=s.user_id WHERE s.token=? AND u.status=0 AND NOT"
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
                    " %H:%M:%f','now'),user_agent=?,ip_address='127.0.0.1'"
                    " WHERE id=?"
                ),
                [req.header("user-agent"), rows[0][1]],
            )
        return rows[0][0]

    def login(mut self, req: Request) raises -> Response:
        var now = external_call["os_now_ms", Int]()
        if now - self.login_window > 180000:
            self.login_attempts = 0
            self.login_window = now
        self.login_attempts += 1
        if self.login_attempts > 40:
            return html("Too many login attempts", 429)
        var fields = params(req.body)
        var rows = self.db.rows(
            (
                "SELECT id,password_digest FROM users WHERE email_address=? AND"
                " status=0 AND NOT EXISTS(SELECT 1 FROM bans WHERE"
                " user_id=users.id)"
            ),
            [fields.get("email_address", "").strip().lower()],
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
                " VALUES(?,?,?,?,?,'127.0.0.1',?)"
            ),
            [tok, rows[0][0], stamp, stamp, stamp, req.header("user-agent")],
        )
        var expiry = self.db.scalar(
            "SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now','+20 years')"
        )
        self.invalidate()
        return html(
            "",
            302,
            "Location: /\r\nSet-Cookie: session_token="
            + self.signer.cookie(tok, expiry)
            + "; Path=/; HttpOnly; SameSite=Lax; Max-Age=631152000\r\n",
        )

    def read(mut self, req: Request) raises -> String:
        var uid = self.user(req)
        if uid == "":
            return html("", 302, "Location: /session/new\r\n").pack(False)
        if req.path == "/":
            var rid = self.db.scalar(
                (
                    "SELECT room_id FROM memberships WHERE user_id=? ORDER BY"
                    " room_id LIMIT 1"
                ),
                [uid],
            )
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
            + req.cookie("last_room_visited")
        )
        if key in self.cache:
            return self.cache[key]
        var result: Response
        if req.path == "/users/me/sidebar":
            result = html(views.sidebar(self.db, self.signer, uid, req))
        elif req.path == "/searches":
            var fields = params(req.query)
            var query = String(fields.get("q", "").strip())
            var matches = List[List[String]]()
            if query != "":
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
            or (len(segments) == 4 and String(segments[3]) == "messages")
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
            var rows = self.db.rows(
                "SELECT * FROM ("
                + MESSAGE_COLUMNS
                + query_filter
                + "ORDER BY m.created_at "
                + direction
                + ",m.id "
                + direction
                + " LIMIT 40) ORDER BY 3,1",
                args,
            )
            if len(segments) == 4:
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
                    "Set-Cookie: last_room_visited="
                    + rid
                    + "; Path=/; SameSite=Lax\r\n",
                )
        else:
            return html("Not found", 404).pack(False)
        var wire = result.pack(req.gzip())
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

    def post(mut self, req: Request) raises -> Response:
        var segments = req.path.split("/")
        if (
            len(segments) != 4
            or String(segments[1]) != "rooms"
            or String(segments[3]) != "messages"
        ):
            return html("Not found", 404)
        var rid = String(positive(String(segments[2])))
        var fields = params(req.body)
        var raw_body = fields.get("message[body]", "")
        var text = richtext.convert(raw_body, True)
        var canonical = richtext.convert(raw_body)
        if text.strip() == "" or text.byte_length() > 65536:
            return html("Text message must contain 1–65536 bytes", 422)
        var client_id = fields.get("message[client_message_id]", "")
        if client_id == "":
            client_id = token()
        if client_id.byte_length() > 128:
            return html("Client ID too long", 422)
        _ = self.db.rows("BEGIN IMMEDIATE")
        try:
            var uid = self.user(req)
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
            _ = self.db.rows(
                (
                    "INSERT INTO"
                    " action_text_rich_texts(name,body,record_type,record_id,created_at,updated_at)"
                    " VALUES('body',?,'Message',?,?,?)"
                ),
                [canonical, mid, now, now],
            )
            _ = self.db.rows(
                "INSERT INTO message_search_index(rowid,body) VALUES(?,?)",
                [mid, text],
            )
            _ = self.db.rows(
                (
                    "UPDATE rooms SET"
                    " updated_at=?,messages_count=messages_count+1 WHERE id=?"
                ),
                [now, rid],
            )
            _ = self.db.rows(
                (
                    "UPDATE memberships SET unread_at=?,updated_at=? WHERE"
                    " room_id=? AND user_id<>? AND involvement<>'invisible' AND"
                    " (connected_at IS NULL OR connected_at <"
                    " datetime('now','-60 seconds'))"
                ),
                [now, now, rid, uid],
            )
            _ = self.db.rows("COMMIT")
            if external_call["work_push", Int](Int(mid)) != 0:
                jobs.count(7)
                raise Error("Background queue full")
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
            self.invalidate()
            return Response(
                200, body, "text/vnd.turbo-stream.html; charset=utf-8", ""
            )
        except e:
            try:
                _ = self.db.rows("ROLLBACK")
            except:
                pass
            raise e^
