import native_boundary as native
from database import Database
from crypto import Signer, json_string, url_encode, unbase64
from http import Request, Response, html
from parameters import Form
from text import escape, params, search_query
import accounts
import rooms
import message_actions
import ui
import runtime
import jobs
import storage
import opengraph
import webpush
import network
import templates
from text import token
from std.os import getenv


def route(
    mut db: Database, mut signer: Signer, req: Request, uid: String, f: Form
) raises -> Response:
    if req.path == "/unfurl_link" and req.method == "POST":
        return preview(f)
    var response = accounts.route(db, signer, req, uid, f)
    if response.status != 0:
        return response^
    response = rooms.route(db, signer, req, uid, f)
    if response.status != 0:
        return response^
    response = message_actions.route(db, signer, req, uid, f)
    if response.status != 0:
        return response^
    if req.path == "/searches" and req.method == "POST":
        var query = search_query(f.fields.get("q", ""))
        if String(query.strip()) != "":
            var now = accounts.stamp(db)
            _ = db.rows(
                "DELETE FROM searches WHERE user_id=? AND query=?", [uid, query]
            )
            _ = db.rows(
                "INSERT INTO searches(user_id,query,created_at,updated_at) VALUES(?,?,?,?)",
                [uid, query, now, now],
            )
            _ = db.rows(
                "DELETE FROM searches WHERE user_id=? AND id NOT IN (SELECT id FROM searches WHERE user_id=? ORDER BY updated_at DESC,id DESC LIMIT 10)",
                [uid, uid],
            )
        return ui.redirect("/searches?q=" + url_encode(query))
    if req.path == "/searches/clear" and req.method == "DELETE":
        _ = db.rows("DELETE FROM searches WHERE user_id=?", [uid])
        return ui.redirect("/searches")
    if req.path.startswith("/users/me/push_subscriptions"):
        var parts = req.path.split("/")
        if (
            len(parts) == 6
            and String(parts[5]) == "test_notifications"
            and req.method == "POST"
        ):
            var sub = db.rows(
                "SELECT id,endpoint,p256dh_key,auth_key FROM push_subscriptions WHERE id=? AND user_id=?",
                [String(parts[4]), uid],
            )
            if len(sub) == 0:
                return html("Not found", 404)
            webpush.deliver(
                db,
                sub[0][0],
                sub[0][1],
                sub[0][2],
                sub[0][3],
                '{"title":"Campfire Test","options":{"body":'
                + json_string(token())
                + ',"icon":"/account/logo","data":{"path":'
                + json_string(req.origin() + "/users/me/push_subscriptions")
                + "}}}",
            )
            return ui.redirect("/users/me/push_subscriptions")
        if req.method == "POST" and len(parts) == 4:
            if not f.endpoint_validated:
                return html("Invalid push subscription", 422)
            var endpoint = f.fields.get("push_subscription[endpoint]", "")
            var key = f.fields.get("push_subscription[p256dh_key]", "")
            var auth = f.fields.get("push_subscription[auth_key]", "")
            var now = accounts.stamp(db)
            var id = db.scalar(
                "SELECT id FROM push_subscriptions WHERE user_id=? AND endpoint=? AND p256dh_key=? AND auth_key=?",
                [uid, endpoint, key, auth],
            )
            if id == "":
                _ = db.rows(
                    "INSERT INTO push_subscriptions(user_id,endpoint,p256dh_key,auth_key,user_agent,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",
                    [
                        uid,
                        endpoint,
                        key,
                        auth,
                        req.header("user-agent"),
                        now,
                        now,
                    ],
                )
            else:
                _ = db.rows(
                    "UPDATE push_subscriptions SET updated_at=? WHERE id=?",
                    [now, id],
                )
            return html("")
        if req.method == "DELETE":
            var segments = req.path.split("/")
            if len(segments) != 5:
                return html("Not found", 404)
            _ = db.rows(
                "DELETE FROM push_subscriptions WHERE id=? AND user_id=?",
                [String(segments[4]), uid],
            )
            return ui.redirect("/users/me/push_subscriptions")
        if req.method != "GET" or len(parts) != 4:
            return html("Not found", 404)
        var subscriptions = db.rows(
            "SELECT id,endpoint FROM push_subscriptions WHERE user_id=?", [uid]
        )
        var body = String()
        for sub in subscriptions:
            body += (
                '<li class="membership-item flex flex-column gap"><p>'
                + escape(sub[1])
                + "</p>"
                + ui.form(
                    "/users/me/push_subscriptions/"
                    + sub[0]
                    + "/test_notifications",
                    "",
                    "post",
                    "Send test notification",
                )
                + ui.form(
                    "/users/me/push_subscriptions/" + sub[0],
                    "",
                    "delete",
                    "Delete subscription",
                )
                + "</li>"
            )
        return ui.page(
            db,
            signer,
            uid,
            req,
            "Push notification subscriptions",
            '<ul id="push_subscriptions">' + body + "</ul>",
        )
    return html("", 0)


def public(
    mut db: Database, mut signer: Signer, req: Request, f: Form
) raises -> Response:
    if req.path == "/first_run" or req.path.startswith("/join/"):
        return accounts.signup(db, signer, req, f, req.path == "/first_run")
    if req.path.startswith("/session/transfers/"):
        return accounts.transfer(db, signer, req)
    if req.path.startswith("/qr_code/") and req.method == "GET":
        var text = unbase64(String(req.path[byte=9:])).text()
        var qr = List[UInt8](length=3918, fill=0)
        var size = native.qr_encode(text, qr)
        if size < 0:
            return html("Invalid QR content", 400)
        var paths = String()
        for y in range(size):
            for x in range(size):
                if native.qr_module(Span(qr), x, y):
                    paths += (
                        "M" + String(x + 4) + " " + String(y + 4) + "h1v1h-1z "
                    )
        return Response(
            200,
            '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 '
            + String(size + 8)
            + " "
            + String(size + 8)
            + '"><rect width="100%" height="100%" fill="white"/><path d="'
            + paths
            + '" fill="black"/></svg>',
            "image/svg+xml",
            "",
        )
    if (
        req.path in ["/webmanifest", "/webmanifest.json"]
        and req.method == "GET"
    ):
        var values = Dict[String, String]()
        var name = db.scalar("SELECT name FROM accounts LIMIT 1")
        values["name"] = json_string(name if name != "" else "Campfire")
        var version = db.scalar(
            "SELECT strftime('%Y%m%d%H%M%S',updated_at) FROM accounts LIMIT 1"
        )
        values["logo_path"] = json_string("/account/logo?v=" + version)
        values["logo_path_small"] = json_string(
            "/account/logo?v=" + version + "&size=small"
        )
        for key in ["add", "person"]:
            values[key + "_url"] = json_string(
                req.origin() + templates.asset(key + ".svg")
            )
        for key in ["android-chat", "android-sidebar", "android-dark-mode"]:
            values[key.replace("-", "_") + "_url"] = json_string(
                req.origin() + templates.asset("screenshots/" + key + ".png")
            )
        return Response(
            200, templates.manifest(values), "application/manifest+json", ""
        )
    if (
        req.path in ["/service-worker", "/service-worker.js"]
        and req.method == "GET"
    ):
        return Response(
            200,
            runtime.read_file(
                getenv("PUBLIC_PATH", "public"), "service-worker.js"
            ),
            "text/javascript; charset=utf-8",
            "Service-Worker-Allowed: /\r\n",
        )
    if req.path == "/account/logo" and req.method == "GET":
        var blob = db.scalar(
            "SELECT blob_id FROM active_storage_attachments WHERE record_type='Account' AND name='logo' LIMIT 1"
        )
        if blob != "":
            return storage.image(
                db,
                blob,
                req,
                192 if params(req.query).get("size", "") == "small" else 512,
                192 if params(req.query).get("size", "") == "small" else 512,
                False,
                "png",
            )
        var filename = (
            "logos/app-icon-192.png" if params(req.query).get("size", "")
            == "small" else "logos/app-icon.png"
        )
        var asset = templates.asset(filename)
        return Response(
            200,
            runtime.read_file(
                getenv("PUBLIC_PATH", "public"), String(asset[byte=1:])
            ),
            "image/png",
            "",
        )
    var segments = req.path.split("/")
    if (
        len(segments) == 4
        and String(segments[1]) == "users"
        and String(segments[3]) == "avatar"
        and req.method == "GET"
    ):
        var uid = signer.verify(
            db, "active_record/signed_id", String(segments[2]), "user/avatar"
        )
        var name = db.scalar("SELECT name FROM users WHERE id=?", [uid])
        if name == "":
            return html("Avatar not found", 404)
        var blob = db.scalar(
            "SELECT blob_id FROM active_storage_attachments WHERE record_type='User' AND name='avatar' AND record_id=? LIMIT 1",
            [uid],
        )
        if blob != "":
            return storage.image(db, blob, req, 512, 512, False)
        if db.scalar("SELECT role FROM users WHERE id=?", [uid]) == "2":
            var asset = templates.asset("default-bot-avatar.svg")
            return Response(
                200,
                runtime.read_file(
                    getenv("PUBLIC_PATH", "public"), String(asset[byte=1:])
                ),
                "image/svg+xml",
                "",
            )
        var initials = String()
        var in_word = False
        var count = 0
        for c in name.codepoints():
            var letter = String(c)
            var word = letter.byte_length() == 1 and (
                (letter >= "a" and letter <= "z")
                or (letter >= "A" and letter <= "Z")
                or (letter >= "0" and letter <= "9")
                or letter == "_"
            )
            if word and not in_word:
                initials += letter
                count += 1
            in_word = word
        var colors = [
            "#AF2E1B",
            "#CC6324",
            "#3B4B59",
            "#BFA07A",
            "#ED8008",
            "#ED3F1C",
            "#BF1B1B",
            "#736B1E",
            "#D07B53",
            "#736356",
            "#AD1D1D",
            "#BF7C2A",
            "#C09C6F",
            "#698F9C",
            "#7C956B",
            "#5D618F",
            "#3B3633",
            "#67695E",
        ]
        var index = native.crc32_bytes(uid.as_bytes(), uid.byte_length()) % 18
        var values: Dict[String, String] = {
            "initials": initials,
            "wide": "1" if count >= 3 else "0",
            "color": colors[index],
        }
        return Response(200, templates.avatar(values), "image/svg+xml", "")
    return html("", 0)


def preview(f: Form) raises -> Response:
    return opengraph.unfurl(f.fields.get("url", ""))


def valid_subscription(f: Form) raises -> Bool:
    var endpoint = f.fields.get("push_subscription[endpoint]", "")
    if not jobs.push_endpoint_permitted(endpoint):
        return False
    var key = unbase64(f.fields.get("push_subscription[p256dh_key]", ""))
    var auth = unbase64(f.fields.get("push_subscription[auth_key]", ""))
    return (
        key.byte_length() == 65
        and auth.byte_length() == 16
        and native.p256_validate_public(key.as_bytes()) == 1
        and network.validate(endpoint)
    )
