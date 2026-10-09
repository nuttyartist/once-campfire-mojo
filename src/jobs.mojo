# The five-workload notification path: room payload, recipients, badges, endpoint
# guard. Permitted public delivery is deliberately rejected as outside this port;
# the benchmark gate requires the same blocked local destinations in all apps.
from std.ffi import external_call
from std.os import getenv
from database import Database
from crypto import json_string, base64
import richtext


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


def process(mut db: Database, mid: String) raises:
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
    var title = row[4] if row[2] == "Rooms::Direct" else row[3]
    var body = richtext.convert(row[5], True)
    if row[2] != "Rooms::Direct":
        body = row[4] + ": " + body
    title = truncate_json(title, 256)
    body = truncate_json(body, 3072)
    var subscriptions = db.rows(
        (
            "SELECT ps.id,ps.user_id,coalesce(ps.endpoint,'') FROM"
            " push_subscriptions ps JOIN users u ON u.id=ps.user_id JOIN"
            " memberships mm ON mm.user_id=u.id WHERE mm.room_id=? AND"
            " mm.user_id<>? AND mm.involvement='everything' AND"
            " (mm.connected_at IS NULL OR mm.connected_at<datetime('now','-60"
            " seconds')) ORDER BY ps.id"
        ),
        [row[0], row[1]],
    )
    # Text benchmark messages have no Action Text mention attachments. Fail closed
    # if a scenario starts exercising that unsupported notification branch.
    if "action-text-attachment" in row[5]:
        raise Error("Mention notification parity is not yet supported")
    for sub in subscriptions:
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
        if not push_endpoint_permitted(sub[2]):
            count(3)
        else:
            count(9)
            raise Error(
                "Public push transport is outside the measured workload scope"
            )


def run(path: String) raises:
    var db = Database(path)
    while True:
        var mid = external_call["work_pop", Int]()
        if mid < 0:
            raise Error("Background queue failed")
        try:
            process(db, String(mid))
        except e:
            count(6)
            print("Background job failed:", e)
        count(1)


def broadcast(
    mut db: Database, room_id: String, kind: String, mid: String, body: String
) raises:
    # Prepare the same append and per-member unread broadcasts. There are no
    # Action Cable subscribers in this HTTP benchmark (asserted by its harness).
    var stream = (
        base64("gid://campfire/" + kind + "/" + room_id, True, False)
        + ":messages"
    )
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
    var memberships = db.rows(
        "SELECT user_id FROM memberships WHERE room_id=?", [room_id]
    )
    for member in memberships:
        var name = "user_" + member[0] + "_unreads"
        var unread = '{"roomId":' + room_id + "}"
        count(5)
        trace(
            "broadcast",
            '{"message_id":'
            + mid
            + ',"stream":'
            + json_string(name)
            + ',"payload":'
            + unread
            + "}",
        )


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
        if len(bots) > 0:
            raise Error(
                "Bot webhook delivery is outside the text benchmark scope"
            )
