import native_boundary as native
from byte_buffer import Bytes

# Action Cable protocol, channel authorization and presence policy in Mojo.
from database import Database
from crypto import Signer, json_string, base64, unbase64
from http import Request
from runtime import digest
import pubsub


def frame(payload: Bytes, opcode: Int = 1) -> Bytes:
    var bytes = List[UInt8]()
    bytes.append(UInt8(128 + opcode))
    var size = payload.byte_length()
    if size < 126:
        bytes.append(UInt8(size))
    elif size < 65536:
        bytes.append(126)
        bytes.append(UInt8(size >> 8))
        bytes.append(UInt8(size & 255))
    else:
        bytes.append(127)
        for shift in range(7, -1, -1):
            bytes.append(UInt8((size >> (shift * 8)) & 255))
    for b in payload.as_bytes():
        bytes.append(b)
    return Bytes(Span(bytes)[: len(bytes)])


def upgrade(req: Request) raises -> Bytes:
    if (
        req.method != "GET"
        or req.header("sec-websocket-version") != "13"
        or "upgrade" not in req.header("connection").lower()
    ):
        raise Error("Invalid WebSocket handshake")
    var origin = req.header("origin")
    if origin != "" and origin != req.origin():
        raise Error("WebSocket origin mismatch")
    if unbase64(req.header("sec-websocket-key")).byte_length() != 16:
        raise Error("Invalid WebSocket key")
    var protocol = String()
    if req.header("sec-websocket-protocol") != "":
        if (
            ",actioncable-v1-json,"
            not in ","
            + req.header("sec-websocket-protocol").replace(" ", "")
            + ","
        ):
            raise Error("Unsupported WebSocket subprotocol")
        protocol = "Sec-WebSocket-Protocol: actioncable-v1-json\r\n"
    return (
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
        + base64(
            digest(
                req.header("sec-websocket-key")
                + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
                False,
            )
        )
        + "\r\n"
        + protocol
        + "\r\n"
        + frame('{"type":"welcome"}')
    )


def field(mut db: Database, value: String, name: String) raises -> String:
    return db.scalar(
        "SELECT coalesce(json_extract(?,?), '')", [value, "$." + name]
    )


@fieldwise_init
struct Subscription(Copyable, Movable):
    var stream: String
    var room_id: String
    var channel: String
    var present: Bool


struct Cable(Copyable, Movable):
    var uid: String
    var token: String
    var subscriptions: Dict[String, Subscription]
    var sequence: Int
    var last_ping: Int
    var fragments: Bytes
    var fragmented: Bool
    var closed: Bool

    def __init__(out self):
        self.uid = ""
        self.token = ""
        self.subscriptions = Dict[String, Subscription]()
        self.sequence = 0
        self.last_ping = 0
        self.fragments = ""
        self.fragmented = False
        self.closed = False

    def start(mut self, uid: String, token: String):
        self.uid = uid
        self.token = token
        self.sequence = native.bus_sequence()
        self.last_ping = native.os_now_ms()

    def absent(self, mut db: Database, sub: Subscription) raises:
        if sub.channel == "PresenceChannel" and sub.present:
            _ = db.rows(
                "UPDATE memberships SET connections=max(0,connections-1),connected_at=CASE WHEN connections<=1 THEN NULL ELSE connected_at END WHERE room_id=? AND user_id=?",
                [sub.room_id, self.uid],
            )

    def finish(mut self, mut db: Database) raises:
        for sub in self.subscriptions.values():
            self.absent(db, sub)
        self.subscriptions.clear()
        self.closed = True

    def command(
        mut self, mut db: Database, mut signer: Signer, value: String
    ) raises -> Bytes:
        if db.scalar("SELECT json_valid(?)", [value]) != "1":
            raise Error("Invalid Cable JSON")
        var command = field(db, value, "command")
        var ident = field(db, value, "identifier")
        if db.scalar("SELECT json_valid(?)", [ident]) != "1":
            raise Error("Invalid Cable identifier")
        var channel = field(db, ident, "channel")
        if command == "unsubscribe":
            if ident in self.subscriptions:
                self.absent(db, self.subscriptions[ident])
                _ = self.subscriptions.pop(ident)
            return ""
        if command == "subscribe":
            if ident in self.subscriptions:
                return ""
            if len(self.subscriptions) >= 64:
                raise Error("Too many subscriptions")
            var stream = String()
            var rid = String()
            if (
                channel == "RoomMessagesChannel"
                or channel == "Turbo::StreamsChannel"
            ):
                stream = signer.verify(
                    db,
                    "turbo/signed_stream_verifier_key",
                    field(db, ident, "signed_stream_name"),
                )
                var bits = stream.split(":", maxsplit=1)
                if len(bits) == 2 and String(bits[1]) == "messages":
                    if channel == "RoomMessagesChannel":
                        var gid = unbase64(String(bits[0])).text()
                        var parts = gid.split("/")
                        if (
                            len(parts) == 5
                            and String(parts[0]) == "gid:"
                            and String(parts[2]) == "campfire"
                        ):
                            rid = String(parts[4])
                            if db.scalar(
                                "SELECT type FROM rooms WHERE id=?", [rid]
                            ) != String(parts[3]):
                                rid = ""
                    if rid == "":
                        stream = ""
                elif channel == "RoomMessagesChannel":
                    stream = ""
                elif (
                    stream != "rooms"
                    and stream
                    != base64("gid://campfire/User/" + self.uid, True, False)
                    + ":rooms"
                ):
                    stream = ""
            elif channel == "ReadRoomsChannel":
                stream = "user_" + self.uid + "_reads"
            elif channel == "UnreadRoomsChannel":
                stream = "user_" + self.uid + "_unreads"
            elif channel == "HeartbeatChannel":
                stream = "heartbeat_" + self.uid
            elif (
                channel == "PresenceChannel"
                or channel == "TypingNotificationsChannel"
                or channel == "RoomChannel"
            ):
                rid = field(db, ident, "room_id")
                stream = channel + ":" + rid
            if (
                rid != ""
                and db.scalar(
                    "SELECT 1 FROM memberships WHERE room_id=? AND user_id=?",
                    [rid, self.uid],
                )
                != "1"
            ):
                stream = ""
            if stream == "":
                return frame(
                    '{"identifier":'
                    + json_string(ident)
                    + ',"type":"reject_subscription"}'
                )
            self.subscriptions[ident] = Subscription(
                stream, rid, channel, channel == "PresenceChannel"
            )
            if channel == "PresenceChannel":
                self.present(db, rid, True)
            return frame(
                '{"identifier":'
                + json_string(ident)
                + ',"type":"confirm_subscription"}'
            )
        if command == "message" and ident in self.subscriptions:
            var data = field(db, value, "data")
            if db.scalar("SELECT json_valid(?)", [data]) != "1":
                raise Error("Invalid Cable action")
            var action = field(db, data, "action")
            var sub = self.subscriptions[ident].copy()
            if sub.channel == "PresenceChannel":
                if action == "present":
                    self.present(db, sub.room_id, not sub.present)
                    self.subscriptions[ident].present = True
                elif action == "refresh" and sub.present:
                    _ = db.rows(
                        "UPDATE memberships SET connected_at=strftime('%Y-%m-%d %H:%M:%f','now') WHERE room_id=? AND user_id=?",
                        [sub.room_id, self.uid],
                    )
                elif action == "absent":
                    self.absent(db, sub)
                    self.subscriptions[ident].present = False
            elif sub.channel == "TypingNotificationsChannel" and (
                action == "start" or action == "stop"
            ):
                var name = db.scalar(
                    "SELECT name FROM users WHERE id=?", [self.uid]
                )
                pubsub.publish(
                    sub.stream,
                    '{"action":'
                    + json_string(action)
                    + ',"user":{"id":'
                    + self.uid
                    + ',"name":'
                    + json_string(name)
                    + "}}",
                )
        return ""

    def present(
        mut self, mut db: Database, rid: String, increment: Bool
    ) raises:
        _ = db.rows(
            "UPDATE memberships SET connections=CASE WHEN connected_at>datetime('now','-60 seconds') THEN max(1,connections+?) ELSE 1 END, connected_at=strftime('%Y-%m-%d %H:%M:%f','now'),unread_at=NULL WHERE room_id=? AND user_id=?",
            ["1" if increment else "0", rid, self.uid],
        )
        pubsub.publish(
            "user_" + self.uid + "_reads",
            '{"room_id":'
            + rid
            + ',"at":'
            + db.scalar("SELECT (julianday('now')-2440587.5)*86400")
            + "}",
        )

    def receive(
        mut self, mut db: Database, mut signer: Signer, mut incoming: Bytes
    ) raises -> Bytes:
        var out = Bytes()
        while incoming.byte_length() >= 2:
            var b = incoming.as_bytes()
            var opcode = Int(b[0]) & 15
            var final = (Int(b[0]) & 128) != 0
            var size = Int(b[1]) & 127
            var head = 2
            if Int(b[0]) & 112 or not (Int(b[1]) & 128):
                raise Error("Invalid WebSocket frame")
            if size == 126:
                if len(b) < 4:
                    break
                size = Int(b[2]) * 256 + Int(b[3])
                head = 4
                if size < 126:
                    raise Error("Non-minimal frame size")
            elif size == 127:
                if len(b) < 10:
                    break
                size = 0
                for i in range(2, 10):
                    if size > 1048576:
                        raise Error("WebSocket frame too large")
                    size = size * 256 + Int(b[i])
                head = 10
                if size < 65536:
                    raise Error("Non-minimal frame size")
            if size > 1048576 or (opcode >= 8 and (size > 125 or not final)):
                raise Error("WebSocket frame too large")
            if len(b) < head + 4 + size:
                break
            var decoded = List[UInt8](length=size, fill=0)
            for i in range(size):
                decoded[i] = b[head + 4 + i] ^ b[head + (i % 4)]
            var payload = Bytes(Span(decoded)[:size])
            var rest = Bytes(incoming.as_bytes()[head + 4 + size :])
            incoming = rest^
            if opcode == 8:
                if size == 1:
                    raise Error("Invalid close frame")
                if size >= 2:
                    var code = Int(decoded[0]) * 256 + Int(decoded[1])
                    if (
                        code < 1000
                        or code >= 5000
                        or code in [1004, 1005, 1006, 1015]
                        or (code >= 1016 and code < 3000)
                    ):
                        raise Error("Invalid close status")
                    var reason = String(from_utf8=Span(decoded)[2:])
                self.finish(db)
                return out + frame(payload, 8)
            if opcode == 9:
                out += frame(payload, 10)
                continue
            if opcode == 10:
                continue
            if opcode != 0 and opcode != 1:
                raise Error("Only text WebSocket messages are supported")
            if (opcode == 0 and not self.fragmented) or (
                opcode == 1 and self.fragmented
            ):
                raise Error("Invalid fragmented message")
            self.fragments += payload
            if self.fragments.byte_length() > 1048576:
                raise Error("Cable message too large")
            self.fragmented = not final
            if final:
                var valid = String(from_utf8=self.fragments.as_bytes())
                out += self.command(db, signer, valid)
                self.fragments = ""
        return out^

    def events(mut self, mut db: Database) raises -> Bytes:
        if self.closed:
            return ""
        if (
            db.scalar(
                "SELECT 1 FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token=? AND u.id=? AND u.status=0 AND NOT EXISTS(SELECT 1 FROM bans WHERE user_id=u.id)",
                [self.token, self.uid],
            )
            != "1"
        ):
            self.finish(db)
            return frame(
                '{"type":"disconnect","reason":"unauthorized","reconnect":false}'
            ) + frame("", 8)
        for sub in self.subscriptions.values():
            if (
                sub.room_id != ""
                and db.scalar(
                    "SELECT 1 FROM memberships WHERE room_id=? AND user_id=?",
                    [sub.room_id, self.uid],
                )
                != "1"
            ):
                self.finish(db)
                return frame(
                    '{"type":"disconnect","reason":"unauthorized","reconnect":true}'
                ) + frame("", 8)
        var out = Bytes()
        var latest = native.bus_sequence()
        if latest > self.sequence:
            var buffer = List[UInt8](length=1048576, fill=0)
            while self.sequence < latest:
                self.sequence += 1
                var n = native.bus_read(self.sequence, buffer, len(buffer))
                if n < 0:
                    raise Error("Slow subscriber exceeded broadcast log")
                if n == 0:
                    break
                var value = String(from_utf8=Span(buffer)[:n])
                var bits = value.split("\n", maxsplit=1)
                for ident in self.subscriptions.keys():
                    if self.subscriptions[ident].stream == String(bits[0]):
                        out += frame(
                            '{"identifier":'
                            + json_string(ident)
                            + ',"message":'
                            + String(bits[1])
                            + "}"
                        )
        var now = native.os_now_ms()
        if now - self.last_ping >= 3000:
            out += frame(
                '{"type":"ping","message":'
                + db.scalar("SELECT unixepoch()")
                + "}"
            )
            self.last_ping = now
        return out^
