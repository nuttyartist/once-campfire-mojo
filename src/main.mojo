from std.ffi import external_call
from std.os import getenv
from app import App
import jobs
import cable
from http import parse_headers, html, chunked


@fieldwise_init
struct Connection(Copyable, Movable):
    var fd: Int
    var incoming: String
    var outgoing: String
    var sent: Int
    var touched: Int
    var close_after: Bool
    var continued: Bool
    var started: Int
    var websocket: cable.Cable

    def close(mut self):
        _ = external_call["os_close", Int](self.fd)
        self.fd = -1
        self.incoming = ""
        self.outgoing = ""

    def dispatch(mut self, mut app: App) raises:
        if self.started==0:
            self.started = external_call["os_now_ms",Int]()
        var end = self.incoming.find("\r\n\r\n")
        if end < 0:
            if self.incoming.byte_length() > 32768:
                self.close()
            return
        var req = parse_headers(String(self.incoming[byte=:end]))
        var address = List[UInt8](length=64,fill=0)
        if external_call["peer_address",Int](self.fd,address.unsafe_ptr(),len(address))==0:
            req.peer = String(unsafe_from_utf8_ptr=address.unsafe_ptr())
        var proxy = getenv("TRUSTED_PROXY_IP","")
        if proxy!="" and req.peer==proxy:
            var forwarded = String(req.header("x-forwarded-for").split(",")[0]).strip()
            var text = String(forwarded)
            if external_call["valid_ip",Int](text.as_c_string_span())==1:
                req.peer = text
        var size = 0
        var cl = req.header("content-length")
        if cl != "":
            if cl.byte_length() > 8:
                raise Error("Invalid Content-Length")
            for digit in cl.as_bytes():
                if digit < 48 or digit > 57:
                    raise Error("Invalid Content-Length")
            size = Int(cl)
        if size < 0 or size > 67108864:
            self.outgoing = html("Body too large", 413).pack(False)
            self.close_after = True
            return
        var consumed = end+4+size
        var complete = self.incoming.byte_length()>=consumed
        if req.header("transfer-encoding")!="":
            var decoded = chunked(String(unsafe_from_utf8=self.incoming.as_bytes()[end+4:]))
            complete = decoded[1]>0
            consumed = end+4+decoded[1]
            req.body = decoded[0]
        elif complete:
            req.body = String(unsafe_from_utf8=self.incoming.as_bytes()[end+4:consumed])
        if not complete:
            var expect = req.header("expect").lower()
            if expect!="" and expect!="100-continue":
                self.outgoing = html("Expectation failed",417).pack(False)
                self.close_after = True
            elif expect=="100-continue" and not self.continued:
                self.outgoing = "HTTP/1.1 100 Continue\r\n\r\n"
                self.continued = True
            return
        var remaining = String(unsafe_from_utf8=self.incoming.as_bytes()[consumed:])
        self.incoming = remaining^
        self.continued = False
        self.started = 0
        if req.path == "/cable" and req.header("upgrade").lower() == "websocket":
            var uid = app.user(req)
            if uid == "":
                self.outgoing = html("Unauthorized", 401).pack(False)
                self.close_after = True
            else:
                self.outgoing = cable.upgrade(req)
                self.websocket.start(uid, app.signer.verify_cookie(app.db, req.cookie("session_token")))
            self.sent = 0
            return
        self.close_after = req.header("connection").lower() == "close"
        try:
            self.outgoing = app.handle(req.copy())
            if req.method == "HEAD":
                var header_end = self.outgoing.find("\r\n\r\n")
                var head = String(self.outgoing[byte = : header_end + 4])
                self.outgoing = head^
        except e:
            print("Request failed:", e)
            self.outgoing = html("Request could not be processed", 400).pack(
                False
            )
        self.sent = 0


def buffered_bytes(connections: List[Connection]) -> Int:
    var total = 0
    for conn in connections:
        total += conn.incoming.byte_length()+conn.outgoing.byte_length()
    return total


def serve(listener: Int, db_path: String, cache_limit: Int) raises:
    var app = App(db_path, cache_limit)
    var connections = List[Connection]()
    var buffer = List[UInt8](length=65536, fill=0)
    while external_call["os_running",Int]():
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
                var conn = Connection(fd, "", "", 0, now, False, False, 0, cable.Cable())
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
            if connections[i].websocket.uid != "":
                try:
                    connections[i].outgoing += connections[i].websocket.events(app.db)
                    if connections[i].websocket.closed:
                        connections[i].close_after = True
                    if connections[i].outgoing.byte_length() > 4194304:
                        raise Error("Slow WebSocket consumer")
                except:
                    connections[i].websocket.finish(app.db)
                    connections[i].close()
                    continue
            if now-connections[i].touched>30000 or (connections[i].websocket.uid=="" and connections[i].started>0 and now-connections[i].started>30000):
                connections[i].websocket.finish(app.db)
                connections[i].close()
                continue
            if ready[i + 1] == 0 and connections[i].outgoing == "":
                continue
            if ready[i + 1] & (8 | 16 | 32):
                connections[i].websocket.finish(app.db)
                connections[i].close()
                continue
            if connections[i].outgoing == "":
                var n = external_call["os_recv", Int](
                    connections[i].fd, buffer.unsafe_ptr(), len(buffer)
                )
                if n == -2:
                    continue
                if n <= 0:
                    connections[i].websocket.finish(app.db)
                    connections[i].close()
                    continue
                if buffered_bytes(connections)+n>134217728:
                    connections[i].websocket.finish(app.db)
                    connections[i].close()
                    continue
                connections[i].touched = now
                connections[i].incoming += String(
                    unsafe_from_utf8=Span(
                        unsafe_ptr=buffer.unsafe_ptr(), length=n
                    )
                )
                try:
                    if connections[i].websocket.uid != "":
                        connections[i].outgoing += connections[i].websocket.receive(app.db, app.signer, connections[i].incoming)
                        connections[i].close_after = connections[i].websocket.closed
                    else:
                        connections[i].dispatch(app)
                except:
                    if connections[i].websocket.uid!="":
                        connections[i].websocket.finish(app.db)
                        connections[i].outgoing = cable.frame("\x03\xea",8)
                    else:
                        connections[i].outgoing = html("Malformed request",400).pack(False)
                    connections[i].close_after = True
                if connections[i].incoming.byte_length() > 67141632:
                    connections[i].close()
            if connections[i].fd >= 0 and connections[i].outgoing != "":
                if buffered_bytes(connections)>134217728:
                    connections[i].websocket.finish(app.db)
                    connections[i].close()
                    continue
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
                    connections[i].websocket.finish(app.db)
                    connections[i].close()
                    continue
                connections[i].touched = now
                connections[i].sent += n
                if connections[i].sent == connections[i].outgoing.byte_length():
                    connections[i].outgoing = ""
                    connections[i].sent = 0
                    if connections[i].close_after:
                        connections[i].websocket.finish(app.db)
                        connections[i].close()
                    elif connections[i].incoming != "":
                        try:
                            if connections[i].websocket.uid != "":
                                connections[i].outgoing = connections[i].websocket.receive(app.db, app.signer, connections[i].incoming)
                                connections[i].close_after = connections[i].websocket.closed
                            else:
                                connections[i].dispatch(app)
                        except:
                            connections[i].close()

    for i in range(len(connections)):
        if connections[i].fd>=0:
            connections[i].websocket.finish(app.db)
            connections[i].close()


def initialize_db(path: String) raises:
    var app = App(path, 0)
    _ = app.db.rows("UPDATE mojo_jobs SET lease_until=0")


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
    var parts = path.split("/")
    var parent = String(path[byte=:path.byte_length()-parts[len(parts)-1].byte_length()])
    if parent != "":
        if external_call["fs_mkdirs", Int](parent.as_c_string_span()) != 0:
            raise Error("Cannot create database directory")
    var lock_path = path+".mojo.lock"
    var lock = external_call["os_lock_file",Int](lock_path.as_c_string_span())
    if lock<0:
        raise Error("Another Mojo server is using this database")
    initialize_db(path)
    if external_call["bus_init",Int]()!=0 or external_call["work_init",Int]()!=0 or external_call["os_signals",Int]()!=0:
        raise Error("Cannot initialize runtime")
    var concurrency = Int(getenv("JOB_CONCURRENCY","3"))
    if concurrency<1 or concurrency>32:
        raise Error("JOB_CONCURRENCY must be 1–32")
    var listener = external_call["os_listen",Int](port)
    if listener<0:
        raise Error("Cannot bind listener")
    print("Campfire Mojo listening on",getenv("BIND_ADDRESS","127.0.0.1"),port,"HTTP workers:",workers,"job workers:",concurrency)
    var children = List[Int](length=workers+concurrency,fill=0)
    for i in range(len(children)):
        var pid = external_call["os_fork",Int]()
        if pid==0:
            if i<workers:
                serve(listener,path,cache_mb*1024*1024//workers)
            else:
                _ = external_call["os_close",Int](listener)
                jobs.run(path)
            return
        if pid<0:
            for child in children:
                if child>0:
                    external_call["os_kill",NoneType](child,15)
            raise Error("Cannot fork worker")
        children[i] = pid
    var failures = 0
    var window = external_call["os_now_ms",Int]()
    while external_call["os_running",Int]():
        var dead = external_call["os_wait_child",Int]()
        if dead==0:
            external_call["os_sleep_ms",NoneType](100)
            continue
        var now = external_call["os_now_ms",Int]()
        if now-window>60000:
            failures = 0
            window = now
        failures += 1
        print("Worker exited unexpectedly:",dead)
        if failures>5:
            break
        for i in range(len(children)):
            if children[i]==dead:
                children[i] = 0
                var pid = external_call["os_fork",Int]()
                if pid==0:
                    if i<workers:
                        serve(listener,path,cache_mb*1024*1024//workers)
                    else:
                        _ = external_call["os_close",Int](listener)
                        jobs.run(path)
                    return
                if pid<0:
                    failures = 6
                else:
                    children[i] = pid
                break
    _ = external_call["os_close",Int](listener)
    for child in children:
        if child>0:
            external_call["os_kill",NoneType](child,15)
    var deadline = external_call["os_now_ms",Int]()+20000
    while external_call["os_now_ms",Int]()<deadline:
        var dead = external_call["os_wait_child",Int]()
        for i in range(len(children)):
            if children[i]==dead:
                children[i] = 0
        var active = False
        for child in children:
            if child>0:
                active = True
        if not active:
            break
        external_call["os_sleep_ms",NoneType](50)
    for child in children:
        if child>0:
            external_call["os_kill",NoneType](child,9)
    _ = external_call["os_close",Int](lock)
    if failures>5:
        raise Error("Worker restart limit exceeded")
