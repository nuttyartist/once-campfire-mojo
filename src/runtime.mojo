import native_boundary as native
from byte_buffer import Bytes
from std.os import getenv
from http import Request, Response, html, conditional


def digest(data: Bytes, sha256: Bool = True) raises -> Bytes:
    var buf = List[UInt8](length=32, fill=0)
    var n = native.crypto_hash(
        data.as_bytes(), data.byte_length(), Int(sha256), buf
    )
    if n < 0:
        raise Error("Digest failed")
    return Bytes(Span(buf)[:n])


def password_hash(var password: String) raises -> String:
    if (
        password.byte_length() == 0
        or password.byte_length() > 72
        or "\x00" in password
    ):
        raise Error("Password must contain 1–72 bytes")
    var buf = List[UInt8](length=61, fill=0)
    if native.password_hash(password, buf) != 0:
        raise Error("Password hashing failed")
    return native.terminated(buf)


def read_file(
    var root: String, var path: String, limit: Int = 67108864
) raises -> Bytes:
    var fd = native.fs_open_beneath(root, path)
    if fd < 0:
        raise Error("File not found")
    try:
        var size = native.fs_size(fd)
        if size < 0 or size > limit:
            raise Error("File too large")
        var bytes = List[UInt8](length=size, fill=0)
        var offset = 0
        while offset < size:
            var n = native.fs_read(fd, bytes, size - offset, offset, offset)
            if n <= 0:
                raise Error("File read failed")
            offset += n
        _ = native.os_close(fd)
        return Bytes(Span(bytes)[:size])
    except e:
        _ = native.os_close(fd)
        raise e^


def mime(path: String) -> String:
    var types: Dict[String, String] = {
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "json": "application/json",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "gif": "image/gif",
        "ico": "image/x-icon",
        "woff2": "font/woff2",
        "woff": "font/woff",
        "mp3": "audio/mpeg",
        "mp4": "video/mp4",
        "ogg": "audio/ogg",
        "wav": "audio/wav",
        "pdf": "application/pdf",
    }
    var parts = path.split(".")
    return types.get(
        String(parts[len(parts) - 1]).lower(), "application/octet-stream"
    )


def asset(req: Request) raises -> Response:
    var relative = String(req.path[byte=1:])
    if "%" in relative or "\\" in relative or "\x00" in relative:
        return html("Not found", 404)
    try:
        var body = read_file(getenv("PUBLIC_PATH", "public"), relative)
        return conditional(
            Response(200, body, mime(relative), ""), req, "public, max-age=300"
        )
    except:
        return html("Not found", 404)
