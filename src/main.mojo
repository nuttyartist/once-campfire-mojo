import native_boundary as native
from byte_buffer import Bytes
from std.os import getenv
from std.sys import argv
from build_info import VERSION, REVISION
from app import App
import jobs
import cable
from file_transfer import FileTransfer
from body_stream import BodyStream
from http import parse_headers, html, chunked


@fieldwise_init
struct Connection(Copyable, Movable):
    var fd: Int
    var incoming: Bytes
    var outgoing: Bytes
    var sent: Int
    var touched: Int
    var close_after: Bool
    var continued: Bool
    var started: Int
    var websocket: cable.Cable
    var download: FileTransfer
    var upload: BodyStream

    def close(mut self):
        self.upload.close()
        self.download.close()
        _ = native.os_close(self.fd)
        self.fd = -1
        self.incoming = ""
        self.outgoing = ""

    def dispatch(mut self, mut app: App) raises:
        if self.started == 0:
            self.started = native.os_now_ms()
        var end = self.incoming.find("\r\n\r\n")
        if end < 0:
            if self.incoming.byte_length() > 32768:
                self.close()
            return
        if end > 32768:
            raise Error("Request headers too large")
        var req = parse_headers(self.incoming.slice(0, end).text())
        var address = List[UInt8](length=64, fill=0)
        if native.peer_address(self.fd, address, len(address)) == 0:
            req.peer = native.terminated(address)
        var proxy = getenv("TRUSTED_PROXY_IP", "")
        if proxy != "" and req.peer == proxy:
            var forwarded = String(
                req.header("x-forwarded-for").split(",")[0]
            ).strip()
            var text = String(forwarded)
            if native.valid_ip(text) == 1:
                req.peer = text
        var size = 0
        var cl = req.header("content-length")
        if cl != "":
            if cl.byte_length() > 18:
                raise Error("Invalid Content-Length")
            for digit in cl.as_bytes():
                if digit < 48 or digit > 57:
                    raise Error("Invalid Content-Length")
            size = Int(cl)
        var spool = req.header("content-type").startswith(
            "multipart/form-data"
        ) or (
            req.method == "PUT"
            and req.path.startswith("/rails/active_storage/disk/")
        )
        var limit = Int(
            getenv("MULTIPART_BYTESIZE_LIMIT", "10737418240")
        ) if spool else 67108864
        if size < 0 or size > limit:
            self.outgoing = html("Body too large", 413).pack(False)
            self.close_after = True
            return
        var consumed = end + 4 + size
        var complete = self.incoming.byte_length() >= consumed
        if spool:
            var received = self.upload.feed(
                Bytes(self.incoming.as_bytes()[end + 4 :]),
                size,
                req.header("transfer-encoding") != "",
            )
            complete = received[1]
            consumed = end + 4 + received[0]
            req.body_fd = self.upload.fd
            req.body_size = self.upload.size
            if not complete:
                self.incoming = Bytes(
                    self.incoming.as_bytes()[: end + 4]
                ) + Bytes(self.incoming.as_bytes()[consumed:])
        elif req.header("transfer-encoding") != "":
            var decoded = chunked(Bytes(self.incoming.as_bytes()[end + 4 :]))
            complete = decoded[1] > 0
            consumed = end + 4 + decoded[1]
            req.body = decoded[0]
        elif complete:
            req.body = Bytes(self.incoming.as_bytes()[end + 4 : consumed])
        if not complete:
            var expect = req.header("expect").lower()
            if expect != "" and expect != "100-continue":
                self.outgoing = html("Expectation failed", 417).pack(False)
                self.close_after = True
            elif expect == "100-continue" and not self.continued:
                self.outgoing = "HTTP/1.1 100 Continue\r\n\r\n"
                self.continued = True
            return
        var remaining = Bytes(self.incoming.as_bytes()[consumed:])
        self.incoming = remaining^
        self.continued = False
        self.started = 0
        if (
            req.path == "/cable"
            and req.header("upgrade").lower() == "websocket"
        ):
            var uid = app.user(req)
            if uid == "":
                self.outgoing = html("Unauthorized", 401).pack(False)
                self.close_after = True
            else:
                self.outgoing = cable.upgrade(req)
                self.websocket.start(
                    uid,
                    app.signer.verify_cookie(
                        app.db, req.cookie("session_token")
                    ),
                )
            self.sent = 0
            return
        self.close_after = req.header("connection").lower() == "close"
        app.db.pending_download.close()
        try:
            self.outgoing = app.handle(req.copy())
            self.download = app.db.pending_download^
            app.db.pending_download = FileTransfer()
            if req.method == "HEAD":
                self.download.close()
                var header_end = self.outgoing.find("\r\n\r\n")
                var head = self.outgoing.slice(0, header_end + 4)
                self.outgoing = head^
        except e:
            app.db.pending_download.close()
            self.download.close()
            var reason = String(e)
            if reason.startswith("HTTP 400: "):
                self.outgoing = html("Malformed request parameters", 400).pack(
                    False
                )
            elif reason.startswith("HTTP 422: "):
                self.outgoing = html(String(reason[byte=10:]), 422).pack(False)
            elif reason in [
                "Invalid UTF-8",
                "Invalid ID",
                "Truncated percent escape",
                "Invalid percent escape",
                "NUL is not valid in a form value",
            ]:
                self.outgoing = html("Malformed request", 400).pack(False)
            elif reason in [
                "Invalid attachment",
                "Invalid image",
                "Incomplete stored upload",
                "Cannot decode image",
                "Cannot preview media",
            ]:
                self.outgoing = html(reason, 422).pack(False)
            else:
                print("Request failed:", req.method, req.path, e)
                self.outgoing = html("Internal server error", 500).pack(False)
        self.upload.close()
        self.sent = 0


def buffered_bytes(connections: List[Connection]) -> Int:
    var total = 0
    for conn in connections:
        total += conn.incoming.byte_length() + conn.outgoing.byte_length()
    return total


def serve(listener: Int, db_path: String, cache_limit: Int) raises:
    var app = App(db_path, cache_limit, False)
    var connections = List[Connection]()
    var buffer = List[UInt8](length=65536, fill=0)
    while native.os_running():
        var fds = List[Int]([listener])
        var writes = List[Int]([0])
        for conn in connections:
            fds.append(conn.fd)
            writes.append(
                1 if conn.outgoing != "" or conn.download.fd >= 0 else 0
            )
        var ready = List[Int](length=len(fds), fill=0)
        _ = native.os_poll(fds, writes, ready, len(fds))
        var now = native.os_now_ms()
        if ready[0] != 0:
            var fd = native.os_accept(listener)
            while fd >= 0:
                var slot = -1
                for i in range(len(connections)):
                    if connections[i].fd < 0:
                        slot = i
                        break
                var conn = Connection(
                    fd,
                    "",
                    "",
                    0,
                    now,
                    False,
                    False,
                    0,
                    cable.Cable(),
                    FileTransfer(),
                    BodyStream(),
                )
                if slot >= 0:
                    connections[slot] = conn^
                elif len(connections) < 1024:
                    connections.append(conn^)
                else:
                    _ = native.os_close(fd)
                fd = native.os_accept(listener)
        for i in range(len(ready) - 1):
            if connections[i].fd < 0:
                continue
            if connections[i].websocket.uid != "":
                try:
                    connections[i].outgoing += connections[i].websocket.events(
                        app.db
                    )
                    if connections[i].websocket.closed:
                        connections[i].close_after = True
                    if connections[i].outgoing.byte_length() > 4194304:
                        raise Error("Slow WebSocket consumer")
                except:
                    connections[i].websocket.finish(app.db)
                    connections[i].close()
                    continue
            if now - connections[i].touched > 30000 or (
                connections[i].websocket.uid == ""
                and connections[i].started > 0
                and now - connections[i].started
                > (1800000 if connections[i].upload.fd >= 0 else 30000)
            ):
                connections[i].websocket.finish(app.db)
                connections[i].close()
                continue
            if (
                ready[i + 1] == 0
                and connections[i].outgoing == ""
                and connections[i].download.fd < 0
            ):
                continue
            if ready[i + 1] & (8 | 16 | 32):
                connections[i].websocket.finish(app.db)
                connections[i].close()
                continue
            if (
                connections[i].outgoing == ""
                and connections[i].download.fd >= 0
            ):
                try:
                    connections[i].outgoing = connections[i].download.next()
                    connections[i].sent = 0
                    if connections[i].outgoing == "":
                        if connections[i].close_after:
                            connections[i].close()
                            continue
                        if connections[i].incoming != "":
                            connections[i].dispatch(app)
                            continue
                except:
                    connections[i].close()
                    continue
            if connections[i].outgoing == "":
                var n = native.os_recv(connections[i].fd, buffer, len(buffer))
                if n == -2:
                    continue
                if n <= 0:
                    connections[i].websocket.finish(app.db)
                    connections[i].close()
                    continue
                if buffered_bytes(connections) + n > 134217728:
                    connections[i].websocket.finish(app.db)
                    connections[i].close()
                    continue
                connections[i].touched = now
                connections[i].incoming += Bytes(Span(buffer)[:n])
                try:
                    if connections[i].websocket.uid != "":
                        connections[i].outgoing += connections[
                            i
                        ].websocket.receive(
                            app.db, app.signer, connections[i].incoming
                        )
                        connections[i].close_after = connections[
                            i
                        ].websocket.closed
                    else:
                        connections[i].dispatch(app)
                except e:
                    if connections[i].websocket.uid != "":
                        connections[i].websocket.finish(app.db)
                        connections[i].outgoing = cable.frame(
                            Bytes([3, 234]), 8
                        )
                    else:
                        connections[i].outgoing = html(
                            "Body too large", 413
                        ).pack(False) if String(
                            e
                        ) == "Upload body too large" else html(
                            "Malformed request", 400
                        ).pack(
                            False
                        )
                    connections[i].close_after = True
                if connections[i].incoming.byte_length() > 67141632:
                    connections[i].close()
            if connections[i].fd >= 0 and connections[i].outgoing != "":
                if buffered_bytes(connections) > 134217728:
                    connections[i].websocket.finish(app.db)
                    connections[i].close()
                    continue
                var fd = connections[i].fd
                var offset = connections[i].sent
                var body = connections[i].outgoing.as_bytes()
                var n = native.os_send(fd, body[offset:], len(body) - offset)
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
                    if connections[i].download.fd >= 0:
                        continue
                    if connections[i].close_after:
                        connections[i].websocket.finish(app.db)
                        connections[i].close()
                    elif connections[i].incoming != "":
                        try:
                            if connections[i].websocket.uid != "":
                                connections[i].outgoing = connections[
                                    i
                                ].websocket.receive(
                                    app.db, app.signer, connections[i].incoming
                                )
                                connections[i].close_after = connections[
                                    i
                                ].websocket.closed
                            else:
                                connections[i].dispatch(app)
                        except:
                            connections[i].close()

    for i in range(len(connections)):
        if connections[i].fd >= 0:
            connections[i].websocket.finish(app.db)
            connections[i].close()


def initialize_db(path: String) raises:
    var app = App(path, 0)
    _ = app.db.rows("UPDATE mojo_jobs SET lease_until=0")


def main() raises:
    var args = argv()
    if len(args) > 1:
        if len(args) == 2 and args[1] == "--version":
            print("Campfire Mojo", VERSION, "(" + REVISION + ")")
            return
        if len(args) == 2 and args[1] in ["--help", "-h"]:
            print("usage: campfire [--version | --help]")
            print(
                "Run the server with environment settings documented in docs/configuration.md."
            )
            return
        raise Error("Unknown arguments; use --help")
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
    var parent = String(
        path[byte = : path.byte_length() - parts[len(parts) - 1].byte_length()]
    )
    if parent != "":
        if native.fs_mkdirs(parent) != 0:
            raise Error("Cannot create database directory")
    var lock_path = path + ".mojo.lock"
    var lock = native.os_lock_file(lock_path)
    if lock < 0:
        raise Error("Another Mojo server is using this database")
    initialize_db(path)
    if (
        native.bus_init() != 0
        or native.work_init() != 0
        or native.os_signals() != 0
    ):
        raise Error("Cannot initialize runtime")
    var concurrency = Int(getenv("JOB_CONCURRENCY", "3"))
    if concurrency < 1 or concurrency > 32:
        raise Error("JOB_CONCURRENCY must be 1–32")
    var listener = native.os_listen(port)
    if listener < 0:
        raise Error("Cannot bind listener")
    print(
        "Campfire Mojo listening on",
        getenv("BIND_ADDRESS", "127.0.0.1"),
        port,
        "HTTP workers:",
        workers,
        "job workers:",
        concurrency,
    )
    var children = List[Int](length=workers + concurrency, fill=0)
    for i in range(len(children)):
        var pid = native.os_fork()
        if pid == 0:
            try:
                if i < workers:
                    serve(listener, path, cache_mb * 1024 * 1024 // workers)
                else:
                    _ = native.os_close(listener)
                    jobs.run(path)
            except e:
                print("Worker failed:", e)
                native.os_child_exit(1)
            native.os_child_exit(0)
            return
        if pid < 0:
            for child in children:
                if child > 0:
                    native.os_kill(child, 15)
            raise Error("Cannot fork worker")
        children[i] = pid
    var failures = 0
    var window = native.os_now_ms()
    while native.os_running():
        var dead = native.os_wait_child()
        if dead == 0:
            native.os_sleep_ms(100)
            continue
        var now = native.os_now_ms()
        if now - window > 60000:
            failures = 0
            window = now
        failures += 1
        print("Worker exited unexpectedly:", dead)
        if failures > 5:
            break
        for i in range(len(children)):
            if children[i] == dead:
                children[i] = 0
                var pid = native.os_fork()
                if pid == 0:
                    try:
                        if i < workers:
                            serve(
                                listener,
                                path,
                                cache_mb * 1024 * 1024 // workers,
                            )
                        else:
                            _ = native.os_close(listener)
                            jobs.run(path)
                    except e:
                        print("Worker failed:", e)
                        native.os_child_exit(1)
                    native.os_child_exit(0)
                    return
                if pid < 0:
                    failures = 6
                else:
                    children[i] = pid
                break
    _ = native.os_close(listener)
    for child in children:
        if child > 0:
            native.os_kill(child, 15)
    var deadline = native.os_now_ms() + 20000
    while native.os_now_ms() < deadline:
        var dead = native.os_wait_child()
        for i in range(len(children)):
            if children[i] == dead:
                children[i] = 0
        var active = False
        for child in children:
            if child > 0:
                active = True
        if not active:
            break
        native.os_sleep_ms(50)
    for child in children:
        if child > 0:
            native.os_kill(child, 9)
    _ = native.os_close(lock)
    if failures > 5:
        raise Error("Worker restart limit exceeded")
