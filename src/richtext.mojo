from std.ffi import external_call
from database import c_text, Database
from crypto import Signer, json_string
import storage
import network
from std.os import getenv
from text import escape

comptime TAGS = (
    " action-text-attachment acronym address big dfn tfoot tt a abbr b blockquote br caption cite code col colgroup dd del details div"
    " dl dt em figcaption figure h1 h2 h3 h4 h5 h6 hr i img ins kbd li mark ol"
    " p pre q rp rt ruby s samp small span strong sub summary sup table tbody"
    " td th thead time tr u ul var "
)
comptime ATTRS = (
    " alt class colspan datetime dir height href lang rel rowspan scope"
    " src start target title type width sgid content-type url filename filesize previewable presentation caption content data-language "
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


def attributes(node: Int) -> Dict[String,String]:
    var out = Dict[String,String]()
    var attr = external_call["dom_attrs",Int](node)
    while attr!=0:
        out[c_text["dom_attr_name"](attr)] = c_text["dom_attr_text"](attr)
        attr = external_call["dom_attr_next",Int](attr)
    return out^


def web_url(value: String, host: String) -> String:
    var name = network.component(value).lower()
    if network.component(value,1) not in ["http","https"] or name=="" or "%" in name or "\\" in value or "." not in name:
        return ""
    var canonical = name.rstrip(".")
    var labels = canonical.split(".")
    var ending = String(labels[len(labels)-1])
    var letters = False
    for c in ending.as_bytes():
        if c>=97 and c<=122:
            letters = True
    if not letters or ending.startswith("0x") or canonical==String(host.split(":")[0]).lower().rstrip("."):
        return ""
    return value


def embed_content(node: Int, mut attrs: Dict[String,String], depth: Int = 0) raises:
    if depth>128:
        raise Error("Embed nesting too deep")
    var current = node
    while current!=0:
        var values = attributes(current)
        var cls = values.get("class","")
        if "og-embed__title" in cls:
            attrs["filename"] = String(walk(external_call["dom_child",Int](current),True,False,0).strip())
            var link = external_call["dom_child",Int](current)
            while link!=0:
                if c_text["dom_name"](link)=="a":
                    attrs["href"] = attributes(link).get("href","")
                    break
                link = external_call["dom_next",Int](link)
        if "og-embed__description" in cls:
            attrs["caption"] = String(walk(external_call["dom_child",Int](current),True,False,0).strip())
        if "og-embed__image" in cls:
            var img = external_call["dom_child",Int](current)
            while img!=0:
                if c_text["dom_name"](img)=="img":
                    attrs["url"] = attributes(img).get("src","")
                    break
                img = external_call["dom_next",Int](img)
        embed_content(external_call["dom_child",Int](current),attrs,depth+1)
        current = external_call["dom_next",Int](current)


def shortened(value: String, count: Int) -> String:
    var out = String()
    var n = 0
    for c in value.codepoints():
        n += 1
        if n==count:
            return out+"…"
        out += String(c)
    return out^


def embed(var attrs: Dict[String,String], host: String) raises -> String:
    if attrs.get("filename","")=="":
        var content = attrs.get("content","")
        var doc = external_call["dom_parse",Int](content.as_c_string_span(),content.byte_length())
        if doc!=0:
            try:
                embed_content(external_call["dom_root",Int](doc),attrs)
                external_call["dom_free",NoneType](doc)
            except e:
                external_call["dom_free",NoneType](doc)
                raise e^
    var href = web_url(attrs.get("href",""),host)
    var image = web_url(attrs.get("url",""),host)
    var title = escape(shortened(attrs.get("filename",""),280))
    if href!="":
        title = '<a href="'+escape(href)+'" rel="noreferrer" target="_blank">'+title+'</a>'
    return '<figure class="attachment attachment--content attachment--og"><div class="og-embed gap'+(' og-embed--twitter-avatar' if image.startswith("https://pbs.twimg.com/profile_images") else '')+'"><div class="og-embed__content"><div class="og-embed__title">'+title+'</div><div class="og-embed__description">'+escape(shortened(attrs.get("caption",""),560))+'</div></div>'+('<div class="og-embed__image"><img src="'+escape(image)+'" class="image center" alt=""></div>' if image!="" else '')+'</div></figure>'


def resolve(mut db: Database, mut signer: Signer, node: Int, plain: Bool, mut mentions: List[String], depth: Int = 0) raises:
    if depth>128:
        raise Error("Attachment nesting too deep")
    var current = node
    while current!=0:
        var next = external_call["dom_next",Int](current)
        if c_text["dom_name"](current)=="action-text-attachment":
            var attrs = attributes(current)
            var sgid = attrs.get("sgid","")
            var gid = signer.verify(db,"signed_global_ids",sgid,"attachable",False)
            var replacement = String("[Missing attachment]")
            if "application/vnd.actiontext.opengraph-embed" in attrs.get("content-type",""):
                replacement = "" if plain else embed(attrs.copy(),db.request_host if db.request_host!="" else network.component(getenv("PUBLIC_ORIGIN","")))
            elif gid.startswith("gid://campfire/User/"):
                var uid = String(String(gid[byte=20:]).split("?")[0])
                var rows = db.rows("SELECT name,strftime('%Y%m%d%H%M%S',updated_at) FROM users WHERE id=?",[uid])
                if len(rows)>0:
                    if uid not in mentions:
                        mentions.append(uid)
                    replacement = "@"+rows[0][0]
                    if not plain:
                        replacement = '<span class="mention" sgid="'+escape(sgid)+'"><img class="avatar" src="'+escape(signer.avatar(uid,rows[0][1]))+'" width="20" height="20"> '+escape(rows[0][0])+'</span>'
            elif gid.startswith("gid://campfire/ActiveStorage::Blob/"):
                var bid = String(String(gid[byte=35:]).split("?")[0])
                var rows = db.rows("SELECT filename,content_type FROM active_storage_blobs WHERE id=?",[bid])
                if len(rows)>0:
                    replacement = rows[0][0]
                    if not plain:
                        var path = storage.blob_path(signer,bid,rows[0][0])
                        replacement = '<a href="'+escape(path)+'">'+escape(rows[0][0])+'</a>'
                        if rows[0][1].startswith("image/") and rows[0][1]!="image/svg+xml":
                            replacement = '<img src="'+escape(path)+'" alt="'+escape(rows[0][0])+'">'
            if plain:
                _ = external_call["dom_replace_text",Int](current,replacement.as_c_string_span())
            else:
                _ = external_call["dom_replace_html",Int](current,replacement.as_c_string_span(),replacement.byte_length())
        else:
            resolve(db,signer,external_call["dom_child",Int](current),plain,mentions,depth+1)
        current = next


def resolved(mut db: Database, mut signer: Signer, var source: String, plain: Bool = False) raises -> String:
    if "action-text-attachment" not in source:
        return convert(source,plain)
    source = convert(source)
    var doc = external_call["dom_parse",Int](source.as_c_string_span(),source.byte_length())
    if doc==0:
        raise Error("Cannot parse attachments")
    try:
        var root = external_call["dom_root",Int](doc)
        var mentions = List[String]()
        resolve(db,signer,root,plain,mentions)
        var value = walk(root,plain,False,0)
        external_call["dom_free",NoneType](doc)
        return String(value.strip()) if plain else value^
    except e:
        external_call["dom_free",NoneType](doc)
        raise e^


def mention_ids(mut db: Database, mut signer: Signer, var source: String) raises -> List[String]:
    var ids = List[String]()
    if "action-text-attachment" not in source:
        return ids^
    var doc = external_call["dom_parse",Int](source.as_c_string_span(),source.byte_length())
    if doc==0:
        raise Error("Cannot parse mentions")
    try:
        resolve(db,signer,external_call["dom_root",Int](doc),True,ids)
        external_call["dom_free",NoneType](doc)
        return ids^
    except e:
        external_call["dom_free",NoneType](doc)
        raise e^
