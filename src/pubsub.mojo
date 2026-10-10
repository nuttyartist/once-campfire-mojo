import native_boundary as native
from crypto import json_string, base64, Signer
from http import Request
import views
import ui
from database import Database


def publish(stream: String, payload: String) raises:
    var data = stream + "\n" + payload
    if native.bus_publish(data.as_bytes(), data.byte_length()) < 0:
        raise Error("Broadcast exceeds bounded delivery log")


def stage(mut db: Database, stream: String, payload: String) raises:
    var event = stream + "\n" + payload
    if event.byte_length() > 1048576:
        raise Error(
            "HTTP 422: Rendered update exceeds the 1 MiB realtime limit"
        )
    db.pending_events.append(event^)


def room_stream(kind: String, rid: String) raises -> String:
    return (
        base64("gid://campfire/" + kind + "/" + rid, True, False) + ":messages"
    )


def room(mut db: Database, rid: String, html: String) raises:
    var kind = db.scalar("SELECT type FROM rooms WHERE id=?", [rid])
    if kind != "":
        stage(db, room_stream(kind, rid), json_string(html))


def refresh_sidebars(mut db: Database, mut signer: Signer, req: Request) raises:
    var users = db.rows("SELECT id FROM users WHERE status=0 AND role<>2")
    for user in users:
        var v = views.sidebar_values(db, signer, user[0], req)
        var stream = (
            base64("gid://campfire/User/" + user[0], True, False) + ":rooms"
        )
        stage(
            db,
            stream,
            json_string(
                ui.stream("update", "shared_rooms", v["shared"])
                + ui.stream("update", "direct_rooms", v["directs"])
            ),
        )


def flush(mut db: Database):
    for event in db.pending_events:
        if native.bus_publish(event.as_bytes(), event.byte_length()) < 0:
            # stage() checked the bound before commit. If an invariant breaks,
            # force reconnect/refresh instead of returning a false HTTP failure.
            print("Realtime admission invariant failed; reconnecting clients")
            native.bus_resync()
    db.pending_events.clear()
