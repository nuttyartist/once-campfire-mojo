# View models and rendering ported from the Rails/Rust message, room, sidebar and
# search presenters. HTML templates compile to Mojo; all record values are live.
from std.os import getenv
from database import Database
from crypto import Signer, base64, url_encode
from http import Request
from text import escape
import templates as t
import richtext
import storage
import sounds


def set_user(
    mut db: Database,
    mut signer: Signer,
    mut v: Dict[String, String],
    uid: String,
) raises:
    var users = db.rows(
        (
            "SELECT"
            " name,coalesce(bio,''),strftime('%Y%m%d%H%M%S',updated_at),role"
            " FROM users WHERE id=?"
        ),
        [uid],
    )
    if len(users) == 0:
        raise Error("User not found")
    var u = users[0].copy()
    v["creator_id"] = uid
    v["creator_name"] = u[0]
    v["creator_title"] = u[0] + (
        " – " + u[1] if String(u[1].strip()) != "" else ""
    )
    v["creator_path"] = "/users/" + uid
    v["creator_avatar"] = signer.avatar(uid, u[2])
    v["admin"] = "1" if u[3] == "1" else "0"


def emoji(s: String) -> Bool:
    if s == "":
        return False
    for c in s.codepoints():
        var value = String(c)
        if value.strip() == "":
            continue
        # Emoji symbols, variation selectors, modifiers and joined sequences.
        var b = value.as_bytes()
        if len(b) < 3:
            return False
        if len(b) == 3 and not (b[0] == 226 or b[0] == 239):
            return False
    return True


def message(mut db: Database, mut signer: Signer, row: List[String]) raises -> String:
    try:
        return render_message(db,signer,row)
    except e:
        print("Could not render message",row[0],String(e))
        return '<div class="message message--formatted message--failed center"><div class="message__body"><div class="message__body-content txt-align-center">Failed to load message content</div></div></div>'


def render_message(
    mut db: Database, mut signer: Signer, row: List[String]
) raises -> String:
    var v = Dict[String, String]()
    set_user(db, signer, v, row[3])
    v["id"] = row[0]
    v["room_name"] = row[6]
    v["client_id"] = row[1]
    v["dom_id"] = "message_" + row[0]
    for prefix in ["edit", "boosting", "new_boost", "boosts", "presentation"]:
        v[prefix + "_dom"] = prefix + "_message_" + row[0]
    v["created_iso"] = db.scalar(
        "SELECT strftime('%Y-%m-%dT%H:%M:%SZ',?)", [row[2]]
    )
    v["created_epoch"] = db.scalar(
        "SELECT CAST(round((julianday(?)-2440587.5)*86400000) AS INTEGER)",
        [row[2]],
    )
    v["updated_epoch"] = db.scalar(
        (
            "SELECT CAST(round((julianday(updated_at)-2440587.5)*86400000) AS"
            " INTEGER) FROM messages WHERE id=?"
        ),
        [row[0]],
    )
    v["at_path"] = "/rooms/" + row[5] + "/@" + row[0]
    v["edit_path"] = "/rooms/" + row[5] + "/messages/" + row[0] + "/edit"
    v["boosts_path"] = "/messages/" + row[0] + "/boosts"
    v["new_boost_path"] = v["boosts_path"] + "/new"
    v["all_emoji"] = "1" if emoji(richtext.convert(row[7], True)) else "0"
    try:
        v["presentation"] = storage.presentation(db,signer,row[0])
        if v["presentation"] == "":
            var plain = richtext.resolved(db,signer,row[7],True)
            if plain.startswith("/play "):
                v["presentation"] = sounds.presentation(String(plain[byte=6:]))
            if v["presentation"] == "":
                v["presentation"] = '<div class="lexxy-content">\n  '+richtext.resolved(db,signer,row[7])+"\n</div>\n"
    except e:
        print("Could not render message presentation",row[0],String(e))
        v["presentation"] = ""
    var reactions = List[String](["👍", "👏", "👋", "💪", "❤️", "😂", "🎉", "🔥"])
    var titles = List[String](
        [
            "Thumbs up",
            "Clapping",
            "Waving hand",
            "Muscle",
            "Red heart",
            "Face with tears of joy",
            "Party popper",
            "Fire",
        ]
    )
    var buttons = String()
    for i in range(len(reactions)):
        v["character"] = reactions[i]
        v["title"] = titles[i]
        buttons += t.reaction(v)
    var attachment = db.rows("SELECT b.id,b.filename FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id WHERE a.record_type='Message' AND a.name='attachment' AND a.record_id=?",[row[0]])
    v["has_attachment"] = "1" if len(attachment)>0 else "0"
    if len(attachment)>0:
        v["blob_path"] = storage.blob_path(signer,attachment[0][0],attachment[0][1])
        v["download_path"] = v["blob_path"]+"?disposition=attachment"
        v["filename"] = attachment[0][1]
    v["reactions"] = buttons^
    v["actions"] = t.actions(v)
    var boosts = db.rows(
        (
            "SELECT id,booster_id,content FROM boosts WHERE message_id=? ORDER"
            " BY created_at"
        ),
        [row[0]],
    )
    var boost_html = String()
    for b in boosts:
        var bv = Dict[String, String]()
        set_user(db, signer, bv, b[1])
        bv["dom_id"] = "boost_" + b[0]
        bv["content"] = b[2]
        bv["all_emoji"] = "1" if emoji(b[2]) else "0"
        bv["path"] = "/messages/" + row[0] + "/boosts/" + b[0]
        boost_html += t.boost(bv)
    v["boost_items"] = boost_html^
    v["boosts"] = t.boosts(v)
    return t.message(v)


def messages(
    mut db: Database, mut signer: Signer, rows: List[List[String]]
) raises -> String:
    var out = String()
    for row in rows:
        out += "\n" + message(db, signer, row)
    return out^


def context(
    mut db: Database,
    mut signer: Signer,
    uid: String,
    req: Request,
    title: String,
    classes: String = "",
) raises -> Dict[String, String]:
    var v = Dict[String, String]()
    if uid != "":
        set_user(db, signer, v, uid)
    v["session_flash"] = ""
    var session = signer.decrypt_cookie(db,req.cookie("_campfire_session"))
    if session!="":
        for item in db.rows("SELECT key,value FROM json_each(?,'$.flash.flashes')",[session]):
            if item[0] in ["notice","alert"]:
                v["session_flash"] += '<p role="status" class="flash '+escape(item[0])+'">'+escape(item[1])+'</p>'
    v["title_tag"] = "<title>" + escape(title) + "</title>"
    v["user_meta"] = (
        '<meta name="current-user-id" content="'
        + uid
        + '" /><meta name="current-user-name" content="'
        + escape(v.get("creator_name", ""))
        + '" />' if uid
        != "" else ""
    )
    v["cable_meta"] = '<meta name="action-cable-url" content="/cable">'
    v["vapid_meta"] = (
        '<meta name="vapid-public-key" content="'
        + escape(getenv("VAPID_PUBLIC_KEY", ""))
        + '">'
    )
    v["prefetch_meta"] = '<meta name="turbo-prefetch" content="true">'
    v["manifest_tag"] = '<link rel="manifest" href="/webmanifest.json">'
    var accounts = db.rows(
        "SELECT"
        " strftime('%Y%m%d%H%M%S',updated_at),coalesce(custom_styles,''),coalesce(settings,'{}'),join_code,id"
        " FROM accounts ORDER BY id LIMIT 1"
    )
    var logo = String("/account/logo")
    if len(accounts) > 0:
        logo += "?v=" + accounts[0][0]
        v["join_code"] = accounts[0][3]
        v["has_logo"] = (
            "1" if db.scalar(
                (
                    "SELECT 1 FROM active_storage_attachments WHERE"
                    " record_type='Account' AND record_id=? AND name='logo'"
                    " LIMIT 1"
                ),
                [accounts[0][4]],
            )
            == "1" else "0"
        )
        if accounts[0][1] != "":
            v["custom_styles"] = (
                '<style data-turbo-track="reload">'
                + accounts[0][1]
                + "</style>"
            )
        var restricted = db.scalar(
            (
                "SELECT"
                " coalesce(json_extract(?,'$.restrict_room_creation_to_administrators'),0)"
            ),
            [accounts[0][2]],
        )
        v["can_create_rooms"] = (
            "1" if v.get("admin", "") == "1" or restricted != "1" else "0"
        )
    v["icon_tag"] = (
        '<link rel="icon" href="' + escape(logo) + '" type="image/png">'
    )
    v["apple_icon_tag"] = (
        '<link rel="apple-touch-icon" href="' + escape(logo) + '">'
    )
    v["account_logo"] = (
        '<figure class="account-logo avatar "><img alt="Account logo" src="'
        + escape(logo)
        + '" width="300" height="300" /></figure>'
    )
    v["stylesheets"] = t.stylesheets()
    v["importmap"] = t.importmap()
    v["body_classes"] = (
        classes
        + (" admin" if v.get("admin", "") == "1" else "")
        + (" account-has-logo" if v.get("has_logo", "") == "1" else "")
    )
    var body_classes = String(v["body_classes"].strip())
    v["body_classes"] = body_classes^
    v["lightbox"] = t.lightbox(v)
    var ua = req.header("user-agent").lower()
    for b in ["firefox", "chrome", "safari", "edge", "android", "windows"]:
        v[b] = "1" if b in ua else "0"
    if "edg/" in ua:
        v["edge"] = "1"
    if v["chrome"] == "1":
        v["safari"] = "0"
    v["ios"] = "1" if "iphone" in ua or "ipad" in ua else "0"
    v["desktop"] = "1" if v["ios"] == "0" and v["android"] == "0" else "0"
    v["browser"] = "Mozilla"
    for b in ["Safari", "Chrome", "Firefox", "Edge"]:
        if v[b.lower()] == "1":
            v["browser"] = b
    v["operating_system"] = ""
    if "mac" in ua:
        v["operating_system"] = "macOS"
    if v["windows"] == "1":
        v["operating_system"] = "Windows"
    if v["android"] == "1":
        v["operating_system"] = "Android"
    if v["ios"] == "1":
        v["operating_system"] = "iOS"
    v["searches_path"] = "/searches"
    v["base_url"] = req.origin()
    return v^


def layout(v: Dict[String, String], req: Request) raises -> String:
    if req.header("turbo-frame") != "":
        return (
            "<html>\n  <head>\n    "
            + v.get("head", "")
            + "\n  </head>\n  <body>\n    "
            + v.get("content", "")
            + "\n  </body>\n</html>\n"
        )
    return t.layout(v)


def frame_open(src: String = "") -> String:
    return (
        '<turbo-frame data-turbo-permanent="true" data-controller="rooms-list'
        ' read-rooms turbo-frame" data-rooms-list-unread-class="unread"'
        ' data-action="presence:present@window->rooms-list#read'
        " read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded"
        ' refresh-room:visible@window->turbo-frame#reload" id="user_sidebar"'
        + (' src="' + escape(src) + '"' if src != "" else "")
        + ' target="_top">'
    )


def room(
    mut db: Database,
    mut signer: Signer,
    uid: String,
    req: Request,
    var name: String,
    rid: String,
    kind: String,
    rows: List[List[String]],
) raises -> String:
    if kind=="rooms_direct":
        var members = db.rows("SELECT u.name FROM users u JOIN memberships mm ON mm.user_id=u.id WHERE mm.room_id=? AND u.id<>? ORDER BY u.name",[rid,uid])
        var names = List[String]()
        for member in members:
            names.append(member[0])
        name = db.scalar("SELECT name FROM users WHERE id=?",[uid])
        if len(names)==1:
            name = names[0]
        elif len(names)==2:
            name = names[0]+" and "+names[1]
        elif len(names)>2:
            name = ", ".join(names[:len(names)-1])+", and "+names[len(names)-1]
    var v = context(db, signer, uid, req, name, "sidebar")
    v["room_id"] = rid
    v["room_name"] = name
    v["direct"] = "1" if kind == "rooms_direct" else "0"
    v["room_noun"] = "Ping" if kind == "rooms_direct" else "room"
    v["messages_dom"] = "messages_" + kind + "_" + rid
    v["involvement_dom"] = "involvement_" + kind + "_" + rid
    v["messages_path"] = "/rooms/" + rid + "/messages"
    v["messages_url"] = req.origin() + v["messages_path"]
    v["refresh_path"] = (
        req.origin() + "/rooms/" + rid + "/refresh"
    )
    v["room_edit_path"] = (
        "/rooms/" + kind.replace("rooms_", "") + "s/" + rid + "/edit"
    )
    v["involvement_path"] = "/rooms/" + rid + "/involvement"
    v["push_path"] = "/users/me/push_subscriptions"
    v["mention_path"] = "/autocompletable/users?room_id=" + rid
    v["loaded_at"] = db.scalar(
        (
            "SELECT CAST(round((julianday(updated_at)-2440587.5)*86400000) AS"
            " INTEGER) FROM rooms WHERE id=?"
        ),
        [rid],
    )
    var model = String("Rooms::Open")
    if kind == "rooms_closed":
        model = "Rooms::Closed"
    elif kind == "rooms_direct":
        model = "Rooms::Direct"
    v["messages_stream"] = signer.stream(
        base64("gid://campfire/" + model + "/" + rid, True, False) + ":messages"
    )
    v["message_template"] = t.message_template(v)
    v["messages"] = messages(db, signer, rows)
    v["browser_settings"] = t.browser_settings(v)
    v["system_settings"] = t.system_settings(v)
    v["install_instructions"] = t.install_instructions(v)
    v["bell"] = t.bell(v)
    v["nav"] = t.room_nav(v)
    v["head"] = t.room_head(v)
    v["content"] = t.room_content(v)
    v["footer"] = t.room_composer(v)
    v["sidebar"] = frame_open("/users/me/sidebar") + "</turbo-frame>"
    return layout(v, req)


def search(
    mut db: Database,
    mut signer: Signer,
    uid: String,
    req: Request,
    query: String,
    rows: List[List[String]],
) raises -> String:
    var v = context(db, signer, uid, req, "Search", "sidebar searches")
    v["query"] = query
    v["q"] = query
    v["has_query"] = "1" if String(query.strip()) != "" else "0"
    v["count"] = String(len(rows))
    v["messages"] = messages(db, signer, rows)
    var recents = db.rows(
        "SELECT query FROM searches WHERE user_id=? ORDER BY updated_at DESC",
        [uid],
    )
    var links = String()
    for row in recents:
        var item = Dict[String, String]()
        item["search"] = row[0]
        item["path"] = "/searches?q=" + url_encode(row[0])
        links += t.recent_link(item)
    v["links"] = links^
    v["has_recents"] = "1" if len(recents) > 0 else "0"
    v["clear_path"] = req.origin() + "/searches/clear"
    v["recents"] = t.recents(v)
    var rid = req.cookie("last_room_visited")
    if (
        db.scalar(
            "SELECT room_id FROM memberships WHERE room_id=? AND user_id=?",
            [rid, uid],
        )
        == ""
    ):
        rid = db.scalar(
            (
                "SELECT room_id FROM memberships JOIN rooms ON rooms.id=room_id"
                " WHERE user_id=? ORDER BY rooms.created_at LIMIT 1"
            ),
            [uid],
        )
    v["return_path"] = "/rooms/" + rid
    v["nav"] = t.search_nav(v)
    v["sidebar"] = t.search_sidebar(v)
    v["content"] = t.search_content(v)
    v["footer"] = t.search_footer(v)
    return layout(v, req)


def first_name(name: String) -> String:
    var names = name.split()
    return String(names[0]) if len(names) > 0 else ""


def sidebar_values(
    mut db: Database, mut signer: Signer, uid: String, req: Request
) raises -> Dict[String,String]:
    var v = context(db, signer, uid, req, "Campfire")
    var shared = String()
    var directs = String()
    var memberships = db.rows(
        (
            "SELECT"
            " r.id,coalesce(r.name,''),r.type,coalesce(mm.unread_at,''),CAST(round((julianday(r.updated_at)-2440587.5)*86400000)"
            " AS INTEGER) FROM rooms r JOIN memberships mm ON mm.room_id=r.id"
            " WHERE mm.user_id=? AND mm.involvement<>'invisible' ORDER BY CASE"
            " WHEN r.type='Rooms::Direct' THEN r.updated_at END"
            " DESC,lower(r.name)"
        ),
        [uid],
    )
    for row in memberships:
        var item = Dict[String, String]()
        item["room_id"] = row[0]
        item["dom_id"] = (
            "list_" + row[2].replace("::", "_").lower() + "_" + row[0]
        )
        var unread = " unread" if row[3] != "" else ""
        if row[2] != "Rooms::Direct":
            item["classes"] = "align-center gap room btn txt-nowrap" + unread
            item["name"] = row[1]
            shared += t.shared_room(item)
        else:
            item["classes"] = "direct" + unread
            item["epoch"] = row[4]
            var members = db.rows(
                (
                    "SELECT user_id FROM memberships WHERE room_id=? AND"
                    " user_id<>?"
                ),
                [row[0], uid],
            )
            if len(members) == 0:
                members.append(List[String]([uid]))
            item["group"] = "1" if len(members) > 1 else "0"
            var avatars = String()
            var initials = List[String]()
            for i in range(len(members)):
                var user = Dict[String, String]()
                set_user(db, signer, user, members[i][0])
                if i == 0:
                    item["avatar"] = user["creator_avatar"]
                    item["first_name"] = first_name(user["creator_name"])
                if i < 4:
                    avatars += (
                        '<span class="avatar"><img aria-hidden="true" src="'
                        + escape(user["creator_avatar"])
                        + '" width="20" height="20" /></span>'
                    )
                var name = String()
                var parts = user["creator_name"].split()
                for j in range(min(3, len(parts))):
                    for c in String(parts[j]).codepoints():
                        name += String(c).upper()
                        break
                initials.append(name^)
            item["avatars"] = avatars^
            item["initials"] = "+".join(initials)
            if len(initials) > 2:
                var rest = List[String]()
                for j in range(len(initials) - 1):
                    rest.append(initials[j])
                item["initials"] = (
                    ", ".join(rest) + ", and " + initials[len(initials) - 1]
                )
            directs += t.direct_room(item)
    var excluded = db.rows(
        (
            "SELECT DISTINCT user_id FROM memberships WHERE room_id IN (SELECT"
            " r.id FROM rooms r JOIN memberships mm ON mm.room_id=r.id WHERE"
            " mm.user_id=? AND r.type='Rooms::Direct')"
        ),
        [uid],
    )
    var limit = max(0, 20 - len(excluded) - 1)
    var placeholders = db.rows(
        (
            "SELECT id FROM users WHERE status=0 AND id<>? AND id NOT IN"
            " (SELECT user_id FROM memberships WHERE room_id IN (SELECT r.id"
            " FROM rooms r JOIN memberships mm ON mm.room_id=r.id WHERE"
            " mm.user_id=? AND r.type='Rooms::Direct')) ORDER BY created_at"
            " LIMIT ?"
        ),
        [uid, uid, String(limit)],
    )
    var ph = String()
    for row in placeholders:
        var u = Dict[String, String]()
        set_user(db, signer, u, row[0])
        u["id"] = row[0]
        u["first_name"] = first_name(u["creator_name"])
        u["avatar"] = u["creator_avatar"]
        ph += t.direct_placeholder(u)
    v["frame_open"] = frame_open()
    v["rooms_stream_tag"] = (
        '<turbo-cable-stream-source channel="Turbo::StreamsChannel"'
        ' signed-stream-name="'
        + signer.stream("rooms")
        + '"></turbo-cable-stream-source>'
    )
    v["user_stream_tag"] = (
        '<turbo-cable-stream-source channel="Turbo::StreamsChannel"'
        ' signed-stream-name="'
        + signer.stream(
            base64("gid://campfire/User/" + uid, True, False) + ":rooms"
        )
        + '"></turbo-cable-stream-source>'
    )
    v["shared"] = shared^
    v["directs"] = directs^
    v["placeholders"] = ph^
    v["content"] = t.sidebar(v)
    return v^


def sidebar(mut db: Database, mut signer: Signer, uid: String, req: Request) raises -> String:
    var v = sidebar_values(db,signer,uid,req)
    return layout(v,req)


def login() -> String:
    return (
        "<!DOCTYPE html><html><head><title>Sign in</title></head><body><form"
        ' method="post" action="/session"><input type="email"'
        ' name="email_address"><input type="password"'
        ' name="password"><button>Sign in</button></form></body></html>'
    )
