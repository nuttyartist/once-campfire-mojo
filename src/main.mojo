from std.ffi import external_call
from std.os import getenv
from app import App
from http import parse_headers, html


@fieldwise_init
struct Connection(Copyable, Movable):
    var fd: Int
    var incoming: String
    var outgoing: String
    var sent: Int
    var touched: Int
    var close_after: Bool

    def close(mut self):
        _ = external_call["os_close", Int](self.fd)
        self.fd = -1
        self.incoming = ""
        self.outgoing = ""

    def dispatch(mut self, mut app: App) raises:
        var end = self.incoming.find("\r\n\r\n")
        if end < 0:
            if self.incoming.byte_length() > 32768:
                self.close()
            return
        var req = parse_headers(String(self.incoming[byte=:end]))
        var size = 0
        var cl = req.header("content-length")
        if cl != "":
            if cl.byte_length() > 8:
                raise Error("Invalid Content-Length")
            for digit in cl.as_bytes():
                if digit < 48 or digit > 57:
                    raise Error("Invalid Content-Length")
            size = Int(cl)
        if size < 0 or size > 1048576:
            self.outgoing = html("Body too large", 413).pack(False)
            self.close_after = True
            return
        if self.incoming.byte_length() < end + 4 + size:
            return
        req.body = String(
            from_utf8=self.incoming.as_bytes()[end + 4 : end + 4 + size]
        )
        var remaining = String(
            unsafe_from_utf8=self.incoming.as_bytes()[end + 4 + size :]
        )
        self.incoming = remaining^
        self.close_after = req.header("connection").lower() == "close"
        try:
            self.outgoing = app.handle(req)
        except e:
            print("Request failed:", e)
            self.outgoing = html("Request could not be processed", 400).pack(
                False
            )
        self.sent = 0


def serve(listener: Int, db_path: String, cache_limit: Int) raises:
    var app = App(db_path, cache_limit)
    var connections = List[Connection]()
    var buffer = List[UInt8](length=65536, fill=0)
    while True:
        var fds = List[Int]([listener])
        var writes = List[Int]([0])
        for conn in connections:
            fds.append(conn.fd)
            writes.append(1 if conn.outgoing != "" else 0)
        var ready = List[Int](length=len(fds), fill=0)
        _ = external_call["os_poll", Int](
            fds.unsafe_ptr(), writes.unsafe_ptr(), ready.unsafe_ptr(), len(fds)
        )
        var now = external_call["os_now_ms", Int]()
        if ready[0] != 0:
            var fd = external_call["os_accept", Int](listener)
            while fd >= 0:
                var slot = -1
                for i in range(len(connections)):
                    if connections[i].fd < 0:
                        slot = i
                        break
                var conn = Connection(fd, "", "", 0, now, False)
                if slot >= 0:
                    connections[slot] = conn^
                elif len(connections) < 1024:
                    connections.append(conn^)
                else:
                    _ = external_call["os_close", Int](fd)
                fd = external_call["os_accept", Int](listener)
        for i in range(len(ready) - 1):
            if connections[i].fd < 0:
                continue
            if now - connections[i].touched > 30000:
                connections[i].close()
                continue
            if ready[i + 1] == 0:
                continue
            if ready[i + 1] & (8 | 16 | 32):
                connections[i].close()
                continue
            if connections[i].outgoing == "":
                var n = external_call["os_recv", Int](
                    connections[i].fd, buffer.unsafe_ptr(), len(buffer)
                )
                if n == -2:
                    continue
                if n <= 0:
                    connections[i].close()
                    continue
                connections[i].touched = now
                connections[i].incoming += String(
                    unsafe_from_utf8=Span(
                        unsafe_ptr=buffer.unsafe_ptr(), length=n
                    )
                )
                try:
                    connections[i].dispatch(app)
                except:
                    connections[i].outgoing = html(
                        "Malformed request", 400
                    ).pack(False)
                    connections[i].close_after = True
                if connections[i].incoming.byte_length() > 1081344:
                    connections[i].close()
            if connections[i].fd >= 0 and connections[i].outgoing != "":
                var fd = connections[i].fd
                var offset = connections[i].sent
                var body = connections[i].outgoing.as_bytes()
                var n = external_call["os_send", Int](
                    fd,
                    body.unsafe_ptr().unsafe_offset(offset),
                    len(body) - offset,
                )
                if n == -2:
                    continue
                if n <= 0:
                    connections[i].close()
                    continue
                connections[i].touched = now
                connections[i].sent += n
                if connections[i].sent == connections[i].outgoing.byte_length():
                    connections[i].outgoing = ""
                    connections[i].sent = 0
                    if connections[i].close_after:
                        connections[i].close()
                    elif connections[i].incoming != "":
                        try:
                            connections[i].dispatch(app)
                        except:
                            connections[i].close()


def initialize_db(path: String) raises:
    var app = App(path, 0)


def main() raises:
    var port = Int(getenv("PORT", "3000"))
    var workers = Int(getenv("MOJO_WORKERS", "4"))
    var cache_mb = Int(getenv("CAMPFIRE_RESPONSE_CACHE_MB", "64"))
    var path = getenv("DATABASE_PATH", "storage/production.sqlite3")
    if (
        port < 1024
        or port > 65535
        or workers < 1
        or workers > 32
        or cache_mb < 0
        or cache_mb > 1024
    ):
        raise Error("Invalid server configuration")
    # Complete schema setup before forking; connections are opened per worker.
    initialize_db(path)
    var listener = external_call["os_listen", Int](port)
    if listener < 0:
        raise Error("Cannot bind loopback listener")
    print("Campfire Mojo listening on 127.0.0.1:", port, "workers:", workers)
    for _ in range(workers - 1):
        var child = external_call["os_fork", Int]()
        if child == 0:
            break
        if child < 0:
            raise Error("fork failed")
    serve(listener, path, cache_mb * 1024 * 1024 // workers)
