from std.ffi import external_call


def escape(s: String) -> String:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&#39;")
    )


def unescape(s: String) -> String:
    return (
        s.replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", '"')
        .replace("&#39;", "'")
        .replace("&amp;", "&")
    )


def hex_digit(c: UInt8) raises -> Int:
    var n = Int(c)
    if n >= 48 and n <= 57:
        return n - 48
    if n >= 65 and n <= 70:
        return n - 55
    if n >= 97 and n <= 102:
        return n - 87
    raise Error("Invalid percent escape")


def decode(s: String) raises -> String:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        if b[i] == 37:
            if i + 2 >= len(b):
                raise Error("Truncated percent escape")
            out.append(UInt8(hex_digit(b[i + 1]) * 16 + hex_digit(b[i + 2])))
            i += 3
        else:
            out.append(UInt8(32) if b[i] == 43 else b[i])
            i += 1
    for c in out:
        if c == 0:
            raise Error("NUL is not valid in a form value")
    return String(from_utf8=Span(unsafe_ptr=out.unsafe_ptr(), length=len(out)))


def params(s: String) raises -> Dict[String, String]:
    var result = Dict[String, String]()
    for part in s.split("&"):
        var bits = part.split("=", maxsplit=1)
        if len(bits) == 2:
            result[decode(String(bits[0]))] = decode(String(bits[1]))
    return result^


def positive(s: String) raises -> Int:
    if s.byte_length() == 0 or s.byte_length() > 18:
        raise Error("Invalid ID")
    for c in s.as_bytes():
        if c < 48 or c > 57:
            raise Error("Invalid ID")
    var n = Int(s)
    if n <= 0:
        raise Error("Invalid ID")
    return n


def token() raises -> String:
    var buf = List[UInt8](length=32, fill=0)
    if external_call["crypto_random", Int](buf.unsafe_ptr(), 32) != 0:
        raise Error("Secure randomness failed")
    var digits = String("0123456789abcdef")
    var out = List[UInt8]()
    for c in buf:
        out.append(digits.as_bytes()[Int(c) // 16])
        out.append(digits.as_bytes()[Int(c) % 16])
    return String(from_utf8=Span(unsafe_ptr=out.unsafe_ptr(), length=len(out)))


def plain_text(html: String) -> String:
    # The initial port supports text messages. Formatting is flattened safely.
    var out = String()
    var inside = False
    for ch in html.codepoints():
        if String(ch) == "<":
            inside = True
        elif String(ch) == ">":
            inside = False
        elif not inside:
            out += String(ch)
    return unescape(out)


def search_query(value: String) -> String:
    var result = String()
    for point in value.codepoints():
        var ch = String(point)
        result += ch if external_call["unicode_word",Int](ch.as_c_string_span())==1 else " "
    return result^
