from std.ffi import external_call
from text import decode
from std.os import getenv


@fieldwise_init
struct Request(Copyable, Movable):
    var method: String
    var target: String
    var path: String
    var query: String
    var headers: Dict[String, String]
    var body: String
    var peer: String

    def header(self, name: String) -> String:
        return self.headers.get(name, "")

    def origin(self) -> String:
        var configured = getenv("PUBLIC_ORIGIN", "")
        if configured != "":
            return configured
        return "http://"+self.header("host")

    def gzip(self) -> Bool:
        var value = self.header("accept-encoding")
        # Explicitly respect a disabled gzip coding.
        return "gzip" in value and "gzip;q=0" not in value.replace(" ", "")

    def cookie(self, name: String) -> String:
        for item in self.header("cookie").split(";"):
            var pair = item.strip().split("=", maxsplit=1)
            if len(pair) == 2 and String(pair[0]) == name:
                return String(pair[1])
        return ""


def parse_headers(head: String) raises -> Request:
    var lines = head.split("\r\n")
    var first = lines[0].split(" ")
    if len(first) != 3 or String(first[2]) != "HTTP/1.1":
        raise Error("HTTP/1.1 required")
    var target = String(first[1])
    if not target.startswith("/") or target.byte_length() > 8192:
        raise Error("Invalid request target")
    var headers = Dict[String, String]()
    for i in range(1, len(lines)):
        var pair = lines[i].split(":", maxsplit=1)
        if len(pair) != 2:
            raise Error("Invalid header")
        var name = String(pair[0]).lower()
        if name=="":
            raise Error("Empty header name")
        for c in name.as_bytes():
            if not ((c>=97 and c<=122) or (c>=48 and c<=57) or Int(c) in [33,35,36,37,38,39,42,43,45,46,94,95,96,124,126]):
                raise Error("Invalid header name")
        for c in String(pair[1]).as_bytes():
            if c<32 and c!=9 or c==127:
                raise Error("Invalid header value")
        if name in headers:
            raise Error("Duplicate header")
        headers[name] = String(pair[1].strip())
    if "transfer-encoding" in headers or "host" not in headers:
        raise Error("Invalid framing")
    var host = headers["host"]
    if host=="" or "/" in host or "\\" in host or "@" in host or " " in host or "\t" in host:
        raise Error("Invalid Host")
    for c in target.as_bytes():
        if c<33 or c==127:
            raise Error("Invalid target")
    var configured = getenv("PUBLIC_ORIGIN","")
    if configured!="":
        var authority = configured.split("/",maxsplit=3)
        if len(authority)<3 or host.lower()!=String(authority[2]).lower():
            raise Error("Unrecognized Host")
    var path_query = target.split("?", maxsplit=1)
    var query = String(path_query[1]) if len(path_query) == 2 else String()
    return Request(
        String(first[0]), target^, String(path_query[0]), query^, headers^, "", "127.0.0.1"
    )


@fieldwise_init
struct Response(Copyable, Movable):
    var status: Int
    var body: String
    var content_type: String
    var extra: String

    def pack(self, gzip: Bool) raises -> String:
        var body = self.body
        var encoding = String()
        if gzip and body.byte_length() > 128:
            var buf = List[UInt8](
                length=body.byte_length() + body.byte_length() // 100 + 128,
                fill=0,
            )
            var n = external_call["gzip_encode", Int](
                body.as_bytes().unsafe_ptr(),
                body.byte_length(),
                buf.unsafe_ptr(),
                len(buf),
            )
            if n < 0:
                raise Error("gzip failed")
            body = String(
                unsafe_from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(), length=n)
            )
            encoding = "Content-Encoding: gzip\r\n"
        var reason = String("OK")
        if self.status == 201:
            reason = "Created"
        elif self.status == 303:
            reason = "See Other"
        elif self.status == 204:
            reason = "No Content"
        elif self.status == 302:
            reason = "Found"
        elif self.status == 400:
            reason = "Bad Request"
        elif self.status == 401:
            reason = "Unauthorized"
        elif self.status == 403:
            reason = "Forbidden"
        elif self.status == 404:
            reason = "Not Found"
        elif self.status == 413:
            reason = "Payload Too Large"
        elif self.status == 422:
            reason = "Unprocessable Content"
        elif self.status == 429:
            reason = "Too Many Requests"
        elif self.status == 500:
            reason = "Internal Server Error"
        return (
            "HTTP/1.1 "
            + String(self.status)
            + " "
            + reason
            + "\r\nContent-Type: "
            + self.content_type
            + "\r\nContent-Length: "
            + String(body.byte_length())
            + "\r\nVary: Accept-Encoding\r\nCache-Control:"
            " no-store\r\nX-Content-Type-Options: nosniff\r\n"
            + encoding
            + self.extra
            + "\r\n"
            + body
        )


def html(body: String, status: Int = 200, extra: String = "") -> Response:
    return Response(status, body, "text/html; charset=utf-8", extra)
