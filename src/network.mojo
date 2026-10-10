import native_boundary as native
from byte_buffer import Bytes


@fieldwise_init
struct Reply(Copyable, Movable):
    var status: Int
    var body: Bytes
    var content_type: String
    var location: String


def validate(var url: String) -> Bool:
    return native.net_validate(url) == 0


def request(
    var url: String,
    var method: String,
    var headers: String,
    body: Bytes = "",
    allow_private: Bool = False,
    timeout: Int = 15000,
    capacity: Int = 1048576,
) raises -> Reply:
    var result = native.net_request(
        url, method, headers, body, allow_private, timeout, capacity
    )
    return Reply(result[0], result[1], result[2], result[3])


def component(var url: String, part: Int = 0) raises -> String:
    var out = List[UInt8](length=8192, fill=0)
    var n = native.url_component(url, part, out, len(out))
    return String(from_utf8=Span(out)[:n]) if n >= 0 else String()
