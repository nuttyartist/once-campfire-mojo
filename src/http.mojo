import native_boundary as native
from byte_buffer import Bytes
from text import decode
from crypto import base64
from std.os import getenv


@fieldwise_init
struct Request(Copyable, Movable):
    var method: String
    var target: String
    var path: String
    var query: String
    var headers: Dict[String, String]
    var body: Bytes
    var peer: String
    var body_fd: Int
    var body_size: Int

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
    if "host" not in headers or ("transfer-encoding" in headers and (headers["transfer-encoding"].lower()!="chunked" or "content-length" in headers)):
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
        String(first[0]), target^, String(path_query[0]), query^, headers^, "", "127.0.0.1", -1, 0
    )


struct Response(Copyable, Movable):
    var status: Int
    var body: Bytes
    var content_type: String
    var extra: String
    var content_length: Int

    def __init__(out self, status: Int, body: Bytes, content_type: String, extra: String, content_length: Int = -1):
        self.status = status
        self.body = body
        self.content_type = content_type
        self.extra = extra
        self.content_length = content_length

    def pack(self, gzip: Bool) raises -> Bytes:
        var body = self.body
        var encoding = String()
        if gzip and self.content_length<0 and self.status==200 and body.byte_length()>128 and (self.content_type.startswith("text/") or "json" in self.content_type or "xml" in self.content_type):
            var buf = List[UInt8](
                length=body.byte_length() + body.byte_length() // 100 + 128,
                fill=0,
            )
            var n = native.gzip_encode(body.as_bytes(), body.byte_length(), buf, len(buf))
            if n < 0:
                raise Error("gzip failed")
            body = Bytes(Span(buf)[:n]
            )
            encoding = "Content-Encoding: gzip\r\n"
        var reason = String("OK")
        if self.status == 201:
            reason = "Created"
        elif self.status == 206:
            reason = "Partial Content"
        elif self.status == 304:
            reason = "Not Modified"
        elif self.status == 405:
            reason = "Method Not Allowed"
        elif self.status == 416:
            reason = "Range Not Satisfiable"
        elif self.status == 417:
            reason = "Expectation Failed"
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
            + ("\r\nContent-Length: "+String(self.content_length if self.content_length>=0 else body.byte_length()) if self.status!=204 and self.status!=304 else "")
            + "\r\nVary: Accept-Encoding\r\n"
            + ("Cache-Control: no-store\r\n" if "Cache-Control:" not in self.extra else "")
            + "X-Content-Type-Options: nosniff\r\nX-Frame-Options: SAMEORIGIN\r\nReferrer-Policy: strict-origin-when-cross-origin\r\nX-XSS-Protection: 0\r\nX-Permitted-Cross-Domain-Policies: none\r\n"
            + encoding
            + self.extra
            + "\r\n"
            + body
        )


def html(body: String, status: Int = 200, extra: String = "") -> Response:
    return Response(status, body, "text/html; charset=utf-8", extra)


def chunked(source: Bytes) raises -> Tuple[Bytes,Int]:
    var body = Bytes()
    var offset = 0
    while True:
        var tail = Bytes(source.as_bytes()[offset:])
        var end = tail.find("\r\n")
        if end<0:
            if tail.byte_length()>8192:
                raise Error("Chunk line too large")
            return ("",0)
        if end>8192:
            raise Error("Chunk line too large")
        var line = tail.slice(0,end).text()
        var fields = line.split(";",maxsplit=1)
        var raw = String(fields[0])
        if raw=="" or raw.byte_length()>8:
            raise Error("Invalid chunk size")
        var size = 0
        for c in raw.lower().as_bytes():
            var digit = Int(c)-48 if c>=48 and c<=57 else Int(c)-87 if c>=97 and c<=102 else -1
            if digit<0:
                raise Error("Invalid chunk size")
            size = size*16+digit
        if body.byte_length()+size>67108864:
            raise Error("Body too large")
        offset += end+2
        if size==0:
            var rest = Bytes(source.as_bytes()[offset:])
            if rest.startswith("\r\n"):
                return (body^,offset+2)
            var finish = rest.find("\r\n\r\n")
            if finish<0:
                if rest.byte_length()>32768:
                    raise Error("Trailers too large")
                return ("",0)
            if finish>32768:
                raise Error("Trailers too large")
            var trailers = parse_headers("GET / HTTP/1.1\r\nHost: "+getenv("PUBLIC_ORIGIN","http://localhost").replace("http://","").replace("https://","")+"\r\n"+rest.slice(0,finish).text())
            for forbidden in ["content-length","transfer-encoding","authorization","cookie"]:
                if trailers.header(forbidden)!="":
                    raise Error("Forbidden trailer")
            return (body^,offset+finish+4)
        if source.byte_length()<offset+size+2:
            return ("",0)
        if source.as_bytes()[offset+size]!=13 or source.as_bytes()[offset+size+1]!=10:
            raise Error("Invalid chunk delimiter")
        body += Bytes(source.as_bytes()[offset:offset+size])
        offset += size+2


def validator(data: Bytes) raises -> String:
    var hash = List[UInt8](length=32,fill=0)
    if native.crypto_hash(data.as_bytes(), data.byte_length(), 1, hash)!=32:
        raise Error("Cannot hash response")
    return '"'+base64(Bytes(Span(hash)[:32]),True,False)+'"'


def conditional(var response: Response, req: Request, policy: String = "private, no-cache") raises -> Response:
    if response.status!=200:
        return response^
    var tag = validator(response.body+("gzip" if req.gzip() else "identity"))
    response.extra += "ETag: "+tag+"\r\nCache-Control: "+policy+"\r\n"
    for candidate in req.header("if-none-match").split(","):
        var value = String(candidate.strip())
        if value=="*" or value==tag or value=="W/"+tag:
            response.status = 304
            response.body = ""
            break
    return response^
