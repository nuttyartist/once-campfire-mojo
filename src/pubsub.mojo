from std.ffi import external_call
from crypto import json_string, base64, Signer
from http import Request
import views
import ui
from database import Database


def publish(stream: String, payload: String) raises:
    var data = stream + "\n" + payload
    if external_call["bus_publish", Int](data.as_bytes().unsafe_ptr(), data.byte_length()) < 0:
        raise Error("Broadcast exceeds bounded delivery log")


def room_stream(kind: String, rid: String) raises -> String:
    return base64("gid://campfire/" + kind + "/" + rid, True, False) + ":messages"


def room(mut db: Database, rid: String, html: String) raises:
    var kind = db.scalar("SELECT type FROM rooms WHERE id=?", [rid])
    if kind != "":
        db.pending_events.append(room_stream(kind, rid)+"\n"+json_string(html))


def refresh_sidebars(mut db: Database, mut signer: Signer, req: Request) raises:
    var users = db.rows("SELECT id FROM users WHERE status=0 AND role<>2")
    for user in users:
        var v = views.sidebar_values(db,signer,user[0],req)
        var stream = base64("gid://campfire/User/"+user[0],True,False)+":rooms"
        publish(stream,json_string(ui.stream("update","shared_rooms",v["shared"])+ui.stream("update","direct_rooms",v["directs"])))


def flush(mut db: Database) raises:
    for event in db.pending_events:
        var parts = event.split("\n",maxsplit=1)
        publish(String(parts[0]),String(parts[1]))
    db.pending_events.clear()
