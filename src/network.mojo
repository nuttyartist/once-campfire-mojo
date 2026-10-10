from std.ffi import external_call


@fieldwise_init
struct Reply(Copyable, Movable):
    var status: Int
    var body: String
    var content_type: String
    var location: String


def validate(var url: String) -> Bool:
    return external_call["net_validate",Int](url.as_c_string_span())==0


def request(var url: String, var method: String, var headers: String, body: String = "", allow_private: Bool = False, timeout: Int = 15000, capacity: Int = 1048576) raises -> Reply:
    var address = 0
    var count = 0
    var location = List[UInt8](length=8192,fill=0)
    var kind = List[UInt8](length=256,fill=0)
    var status = external_call["net_request",Int](url.as_c_string_span(),method.as_c_string_span(),headers.as_c_string_span(),body.as_bytes().unsafe_ptr(),body.byte_length() if method!="GET" else -1,Pointer(to=address),capacity,Pointer(to=count),Int(allow_private),kind.unsafe_ptr(),location.unsafe_ptr(),timeout)
    var ptr = Pointer[UInt8,MutUntrackedOrigin](unsafe_from_address=address)
    var data = String(unsafe_from_utf8=Span(unsafe_ptr=ptr,length=count)) if count>0 else String()
    external_call["free",NoneType](ptr)
    return Reply(status,data^,String(unsafe_from_utf8_ptr=kind.unsafe_ptr()),String(unsafe_from_utf8_ptr=location.unsafe_ptr()))


def component(var url: String, part: Int = 0) -> String:
    var out = List[UInt8](length=8192,fill=0)
    var n = external_call["url_component",Int](url.as_c_string_span(),part,out.unsafe_ptr(),len(out))
    return String(unsafe_from_utf8=Span(unsafe_ptr=out.unsafe_ptr(),length=n)) if n>=0 else String()
