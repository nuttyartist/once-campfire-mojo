from std.ffi import external_call
from std.os import getenv
from http import Request, Response, html, conditional


def digest(data: String, sha256: Bool = True) raises -> String:
    var buf = List[UInt8](length=32, fill=0)
    var n = external_call["crypto_hash", Int](data.as_bytes().unsafe_ptr(), data.byte_length(), Int(sha256), buf.unsafe_ptr())
    if n < 0:
        raise Error("Digest failed")
    return String(unsafe_from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(), length=n))


def password_hash(var password: String) raises -> String:
    if password.byte_length() == 0 or password.byte_length() > 72 or "\x00" in password:
        raise Error("Password must contain 1–72 bytes")
    var buf = List[UInt8](length=61, fill=0)
    if external_call["password_hash", Int](password.as_c_string_span(), buf.unsafe_ptr()) != 0:
        raise Error("Password hashing failed")
    return String(unsafe_from_utf8_ptr=buf.unsafe_ptr())


def read_file(var root: String, var path: String, limit: Int = 67108864) raises -> String:
    var fd = external_call["fs_open_beneath", Int](root.as_c_string_span(), path.as_c_string_span())
    if fd < 0:
        raise Error("File not found")
    try:
        var size = external_call["fs_size", Int](fd)
        if size < 0 or size > limit:
            raise Error("File too large")
        var bytes = List[UInt8](length=size, fill=0)
        var offset = 0
        while offset < size:
            var n = external_call["fs_read", Int](fd, bytes.unsafe_ptr().unsafe_offset(offset), size-offset, offset)
            if n <= 0:
                raise Error("File read failed")
            offset += n
        _ = external_call["os_close", Int](fd)
        return String(unsafe_from_utf8=Span(unsafe_ptr=bytes.unsafe_ptr(), length=size))
    except e:
        _ = external_call["os_close", Int](fd)
        raise e^


def mime(path: String) -> String:
    var types: Dict[String,String] = {"css":"text/css; charset=utf-8", "js":"text/javascript; charset=utf-8", "json":"application/json", "svg":"image/svg+xml", "png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "webp":"image/webp", "gif":"image/gif", "ico":"image/x-icon", "woff2":"font/woff2", "woff":"font/woff", "mp3":"audio/mpeg", "mp4":"video/mp4", "ogg":"audio/ogg", "wav":"audio/wav", "pdf":"application/pdf"}
    var parts = path.split(".")
    return types.get(String(parts[len(parts)-1]).lower(), "application/octet-stream")


def asset(req: Request) raises -> Response:
    var relative = String(req.path[byte=1:])
    if "%" in relative or "\\" in relative or "\x00" in relative:
        return html("Not found", 404)
    try:
        var body = read_file(getenv("PUBLIC_PATH", "public"), relative)
        return conditional(Response(200,body,mime(relative),""),req,"public, max-age=300")
    except:
        return html("Not found", 404)
