from std.ffi import external_call
from database import c_text
from text import escape

comptime TAGS = (
    " a abbr b blockquote br caption cite code col colgroup dd del details div"
    " dl dt em figcaption figure h1 h2 h3 h4 h5 h6 hr i img ins kbd li mark ol"
    " p pre q rp rt ruby s samp small span strong sub summary sup table tbody"
    " td th thead time tr u ul var "
)
comptime ATTRS = (
    " alt class colspan datetime dir height href lang name rel rowspan scope"
    " src start target title type width "
)


def safe_url(s: String) -> Bool:
    var lower = (
        s.lower()
        .replace("\n", "")
        .replace("\r", "")
        .replace("\t", "")
        .replace(" ", "")
    )
    if ":" not in lower:
        return True
    return (
        lower.startswith("https:")
        or lower.startswith("http:")
        or lower.startswith("mailto:")
        or lower.startswith("tel:")
    )


def autolink(s: String) -> String:
    var out = String()
    var rest = s
    while True:
        var at = rest.find("http://")
        var secure = rest.find("https://")
        if at < 0 or (secure >= 0 and secure < at):
            at = secure
        if at < 0:
            return out + escape(rest)
        out += escape(String(rest[byte=:at]))
        var tail = String(rest[byte=at:])
        rest = tail^
        var end = 0
        for ch in rest.as_bytes():
            if (
                ch == 32
                or ch == 10
                or ch == 13
                or ch == 9
                or ch == 60
                or ch == 62
                or ch == 34
            ):
                break
            end += 1
        while end > 0 and (
            rest.as_bytes()[end - 1] == 46
            or rest.as_bytes()[end - 1] == 44
            or rest.as_bytes()[end - 1] == 33
            or rest.as_bytes()[end - 1] == 41
        ):
            end -= 1
        if end == 0:
            return out + escape(rest)
        var url = String(rest[byte=:end])
        out += (
            '<a href="'
            + escape(url)
            + '" target="_blank" rel="noopener noreferrer">'
            + escape(url)
            + "</a>"
        )
        var tail2 = String(rest[byte=end:])
        rest = tail2^


def walk(node: Int, plain: Bool, link: Bool, depth: Int) raises -> String:
    if depth > 128:
        raise Error("Rich text nesting too deep")
    var out = String()
    var current = node
    while current != 0:
        var kind = external_call["dom_type", Int](current)
        var name = c_text["dom_name"](current)
        if kind == 3:
            var value = c_text["dom_text"](current)
            out += value if plain else (
                autolink(value) if not link else escape(value)
            )
        elif (
            kind == 1
            and name != "script"
            and name != "style"
            and name != "iframe"
            and name != "object"
        ):
            var child = external_call["dom_child", Int](current)
            var inside = walk(
                child,
                plain,
                link or name == "a" or name == "pre" or name == "code",
                depth + 1,
            )
            if plain:
                out += inside
                if name == "br":
                    out += "\n"
                elif (
                    name == "div"
                    or name == "p"
                    or name == "li"
                    or name == "blockquote"
                    or name == "tr"
                ):
                    out += "\n\n"
            elif " " + name + " " in TAGS:
                out += "<" + name
                var attr = external_call["dom_attrs", Int](current)
                while attr != 0:
                    var key = c_text["dom_attr_name"](attr)
                    var value = c_text["dom_attr_text"](attr)
                    if " " + key + " " in ATTRS:
                        if (key != "href" and key != "src") or safe_url(value):
                            out += " " + key + '="' + escape(value) + '"'
                    attr = external_call["dom_attr_next", Int](attr)
                out += ">" + inside
                if (
                    name != "br"
                    and name != "hr"
                    and name != "img"
                    and name != "col"
                ):
                    out += "</" + name + ">"
            else:
                out += inside
        current = external_call["dom_next", Int](current)
    return out^


def convert(var source: String, plain: Bool = False) raises -> String:
    source = (
        "<!doctype html><html><body>"
        + String(source.strip())
        + "</body></html>"
    )
    var doc = external_call["dom_parse", Int](
        source.as_c_string_span(), source.byte_length()
    )
    if doc == 0:
        raise Error("Could not parse rich text")
    try:
        var root = external_call["dom_root", Int](doc)
        var value = walk(root, plain, False, 0)
        external_call["dom_free", NoneType](doc)
        return String(value.strip()) if plain else value^
    except e:
        external_call["dom_free", NoneType](doc)
        raise e^


def presentation(source: String) raises -> String:
    return '<div class="lexxy-content">\n  ' + convert(source) + "\n</div>\n"
