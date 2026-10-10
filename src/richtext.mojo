import native_boundary as native
from byte_buffer import Bytes
from database import Database
from crypto import Signer, json_string, unbase64, url_encode
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


def uri_unescape(source: String) -> String:
    var value = (
        source.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", '"')
        .replace("&apos;", "'")
    )
    var out = String()
    var offset = 0
    while offset < value.byte_length():
        var found = regex("(?i)&#(?:x[0-9a-f]+|[0-9]+);?", value, offset)
        if found[0] < 0:
            break
        out += String(value[byte = offset : found[0]])
        var raw = (
            String(value[byte = found[0] + 2 : found[1]])
            .lower()
            .replace(";", "")
        )
        var hexadecimal = raw.startswith("x")
        var number: UInt32 = 0
        for c in raw.as_bytes():
            if c == 120:
                continue
            number = number * UInt32(16 if hexadecimal else 10) + UInt32(
                Int(c) - 48 if c <= 57 else Int(c) - 87
            )
            if number > 1114111:
                break
        if (
            number > 0
            and number <= 1114111
            and not (number >= 55296 and number <= 57343)
        ):
            out += String(chr(Int(number)))
        offset = found[1]
    return out + String(value[byte=offset:])


def safe_url(source: String) -> Bool:
    var value = (
        uri_unescape(source)
        .replace("&Tab;", "")
        .replace("&NewLine;", "")
        .replace("&colon;", ":")
    )
    var cleaned = String()
    for cp in value.codepoints():
        var c = String(cp)
        if regex("[`\\x00-\\x20\\x7f-\\x{101}]", c)[0] < 0:
            cleaned += c
    var lower = cleaned.lower()
    var found = regex(
        "^[a-z][a-z0-9+.-]*(?=:|&#0*58|&#x0*3a|%3a|&#37;3a)", lower
    )
    if found[0] < 0:
        return True
    var scheme = String(lower[byte = : found[1]])
    if scheme not in [
        "afs",
        "aim",
        "callto",
        "data",
        "ed2k",
        "fax",
        "ftp",
        "gopher",
        "http",
        "https",
        "irc",
        "line",
        "mailto",
        "modem",
        "news",
        "nntp",
        "rsync",
        "rtsp",
        "sftp",
        "sms",
        "ssh",
        "tag",
        "tel",
        "telnet",
        "urn",
        "webcal",
        "xmpp",
    ]:
        return False
    if scheme == "data":
        if "," not in lower or not lower.startswith("data:"):
            return False
        var media = String(String(lower[byte=5:]).split(",")[0]).split(";")[0]
        return String(media) in [
            "image/gif",
            "image/jpeg",
            "image/png",
            "text/css",
            "text/plain",
            "",
        ]
    return True


def uri_escape(value: String) -> String:
    var out = String()
    for cp in value.codepoints():
        var c = String(cp)
        if c == " ":
            out += "%20"
        elif c == '"':
            out += "%22"
        elif regex("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f]", c)[0] < 0:
            out += c
    return out^


def regex(pattern: String, text: String, start: Int = 0) -> Tuple[Int, Int]:
    var pat = pattern.copy()
    var span = List[Int](length=2, fill=-1)
    var found = native.regex_find(
        pat, text.as_bytes(), text.byte_length(), start, span
    )
    return (span[0], span[1]) if found == 1 else (-1, -1)


def autolink(s: String) -> String:
    var urls = String(
        '(?:(?i:(?:ed2k|ftp|http|https|irc|mailto|news|gopher|nntp|telnet|webcal|xmpp|callto|feed|svn|urn|aim|rsync|tag|ssh|sftp|rtsp|afs|file):)//|(?i:www)\\.[a-zA-Z0-9_])[^ \\t\\r\\n\\x0B\\x0C<\\x{A0}"]+'
    )
    var emails = String(
        "(?<![a-zA-Z0-9_.!#$%&'*/=?^`{|}~+-])[a-zA-Z0-9_.!#$%+-]\\.?[a-zA-Z0-9_.!#$%&'*/=?^`{|}~+-]*@[a-zA-Z0-9_-]+(?:\\.[a-zA-Z0-9_-]+)+"
    )
    var out = String()
    var offset = 0
    while offset < s.byte_length():
        var url = regex(urls, s, offset)
        var email = regex(emails, s, offset)
        var mail = email[0] >= 0 and (url[0] < 0 or email[0] < url[0])
        var found = email if mail else url
        if found[0] < 0:
            break
        out += escape(String(s[byte = offset : found[0]]))
        var value = String(s[byte = found[0] : found[1]])
        var suffix = String()
        if not mail:
            var chars = List[String]()
            for cp in value.codepoints():
                chars.append(String(cp))
            while len(chars) > 0:
                var last = chars[len(chars) - 1]
                if last in ["/", "-", "=", ";"] or regex("\\w", last)[0] >= 0:
                    break
                var opening = (
                    "(" if last
                    == ")" else "[" if last
                    == "]" else "{" if last
                    == "}" else ""
                )
                if opening != "":
                    var balance = 0
                    for c in chars:
                        balance += Int(c == opening) - Int(c == last)
                    if balance == 0:
                        break
                suffix = chars.pop() + suffix
            value = "".join(chars)
        var href = "mailto:" + url_encode(value).replace(
            "%40", "@"
        ) if mail else (
            "http://" + value if value.lower().startswith("www.") else value
        )
        out += (
            '<a target="_blank" href="'
            + escape(href)
            + '">'
            + escape(value)
            + "</a>"
            + escape(suffix)
        )
        offset = found[1]
    return out + escape(String(s[byte=offset:]))


def walk(
    node: Int,
    plain: Bool,
    link: Bool,
    depth: Int,
    preserve_style: Bool = False,
    final: Bool = False,
) raises -> String:
    if depth > 512:
        raise Error("Rich text nesting too deep")
    var out = String()
    var current = node
    while current != 0:
        var kind = native.dom_type(current)
        var name = native.dom_name(current)
        if kind == 3:
            var value = native.dom_text(current)
            out += value if plain else (
                autolink(value) if not link else text_html(value)
            )
        elif (
            kind == 1
            and name != "script"
            and name != "style"
            and name != "iframe"
            and name != "object"
        ):
            var child = native.dom_child(current)
            var inside = walk(
                child,
                plain,
                link or name == "a",
                depth + 1,
                preserve_style,
                final,
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
            elif " " + name + " " in (FINAL_TAGS if final else TAGS):
                out += "<" + name
                var attr = native.dom_attrs(current)
                var escaped_urls = False
                while attr != 0:
                    var key = native.dom_attr_name(attr)
                    var value = native.dom_attr_text(attr)
                    if key == "style" and not final:
                        escaped_urls = True
                        var style = sanitize_style(value)
                        if preserve_style and style != "":
                            out += ' style="' + escape(style) + '"'
                    elif " " + key + " " in (FINAL_ATTRS if final else ATTRS):
                        var uri = key in [
                            "action",
                            "cite",
                            "href",
                            "longdesc",
                            "poster",
                            "preload",
                            "src",
                            "xlink:href",
                            "xml:base",
                        ]
                        var encode_uri = key in ["href", "action", "src"]
                        if encode_uri and escaped_urls:
                            value = uri_escape(value)
                        if (not uri or safe_url(value)) and (
                            key != "src" or String(value.strip()) != ""
                        ):
                            if encode_uri:
                                value = uri_escape(value)
                            out += " " + key + '="' + escape(value) + '"'
                            escaped_urls = True
                    attr = native.dom_attr_next(attr)
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
        current = native.dom_next(current)
    return out^


def convert(
    var source: String, plain: Bool = False, preserve_style: Bool = False
) raises -> String:
    source = ruby_strip(source)
    var doc = native.dom_parse_fragment(source.as_bytes(), source.byte_length())
    if doc == 0:
        raise Error("Could not parse rich text")
    try:
        var root = native.dom_root(doc)
        var value = plain_nodes(root) if plain else walk(
            root, False, False, 0, preserve_style
        )
        native.dom_free(doc)
        return chomp(value) if plain else value^
    except e:
        native.dom_free(doc)
        raise e^


def presentation(source: String) raises -> String:
    return '<div class="lexxy-content">\n  ' + convert(source) + "\n</div>\n"


def attributes(node: Int) raises -> Dict[String, String]:
    var out = Dict[String, String]()
    var attr = native.dom_attrs(node)
    while attr != 0:
        out[native.dom_attr_name(attr)] = native.dom_attr_text(attr)
        attr = native.dom_attr_next(attr)
    return out^


def web_url(value: String, host: String) raises -> String:
    # Match Ruby URI's syntax without a fetch or libcurl's URL normalization.
    for c in value.as_bytes():
        if c <= 32 or c >= 127:
            return ""
    var path = String(value.split("?")[0])
    if regex('[<>`"]', path)[0] >= 0:
        return ""
    var query = (
        String(value.split("?", maxsplit=1)[1]) if "?" in value else String()
    )
    if (
        "\\" in value
        or regex("%(?![0-9a-fA-F]{2})", path)[0] >= 0
        or regex("%[^0-9a-fA-F][^0-9a-fA-F]", query)[0] >= 0
        or regex("#.*#", value)[0] >= 0
    ):
        return ""
    if value.startswith("mailto:") and "@" not in value:
        raise Error("Invalid mailto URL")
    var parts = value.split("://", maxsplit=1)
    if len(parts) != 2 or String(parts[0]).lower() not in ["http", "https"]:
        return ""
    var authority = String(
        String(String(parts[1]).split("/")[0]).split("?")[0]
    ).split("#")[0]
    var auth = String(authority)
    var users = auth.split("@")
    var without_user = String(users[len(users) - 1])
    auth = without_user^
    var name = String()
    if auth.startswith("["):
        var end = auth.find("]")
        if end < 0:
            return ""
        name = String(auth[byte = : end + 1])
        var port = String(auth[byte = end + 1 :])
        if port != "" and regex("^:[0-9]*$", port)[0] < 0:
            return ""
    else:
        var pieces = auth.split(":")
        if len(pieces) > 2 or (
            len(pieces) == 2 and regex("^[0-9]*$", String(pieces[1]))[0] < 0
        ):
            return ""
        name = String(pieces[0])
    if name == "" or "%" in name or "." not in name:
        return ""
    var trimmed = name.rstrip(".")
    if trimmed == "":
        raise Error("Invalid domain name")
    var labels = trimmed.split(".")
    var ending = String(labels[len(labels) - 1]).lower()
    if regex("[a-z]", ending)[0] < 0 or ending.startswith("0x"):
        return ""
    var canonical = name.lower()
    if canonical.endswith("."):
        var shortened = String(canonical[byte = : canonical.byte_length() - 1])
        canonical = shortened^
    var request_host = String(host.split(":")[0]).lower()
    if request_host.endswith("."):
        var shortened = String(
            request_host[byte = : request_host.byte_length() - 1]
        )
        request_host = shortened^
    return "" if canonical == request_host else value


def embed_content(
    node: Int, mut attrs: Dict[String, String], depth: Int = 0
) raises:
    if depth > 512:
        raise Error("Embed nesting too deep")
    var current = node
    while current != 0:
        var values = attributes(current)
        var cls = values.get("class", "")
        if "og-embed__title" in cls:
            attrs["filename"] = String(
                walk(native.dom_child(current), True, False, 0).strip()
            )
            var link = descendant(native.dom_child(current), "a")
            if link != 0:
                attrs["filename"] = String(
                    walk(native.dom_child(link), True, False, 0).strip()
                )
                attrs["href"] = attributes(link).get("href", "")
        if "og-embed__description" in cls:
            attrs["caption"] = String(
                walk(native.dom_child(current), True, False, 0).strip()
            )
        if "og-embed__image" in cls:
            var img = descendant(native.dom_child(current), "img")
            if img != 0:
                attrs["url"] = attributes(img).get("src", "")
        embed_content(native.dom_child(current), attrs, depth + 1)
        current = native.dom_next(current)


def shortened(value: String, count: Int) -> String:
    var chars = List[String]()
    for c in value.codepoints():
        chars.append(String(c))
    return "".join(chars[: count - 1]) + "…" if len(chars) > count else value


def embed(var attrs: Dict[String, String], host: String) raises -> String:
    if String(attrs.get("filename", "").strip()) == "":
        var content = attrs.get("content", "")
        attrs = Dict[String, String]()
        var doc = native.dom_parse_fragment(
            content.as_bytes(), content.byte_length()
        )
        if doc != 0:
            try:
                embed_content(native.dom_root(doc), attrs)
                native.dom_free(doc)
            except e:
                native.dom_free(doc)
                raise e^
    var href = web_url(attrs.get("href", ""), host)
    var image = web_url(attrs.get("url", ""), host)
    var title = escape(shortened(attrs.get("filename", ""), 280))
    if href != "":
        title = (
            '<a href="'
            + escape(href)
            + '" rel="noreferrer" target="_blank">'
            + title
            + "</a>"
        )
    return (
        '<figure class="attachment attachment--content attachment--og"><div class="og-embed gap'
        + (
            " og-embed--twitter-avatar" if image.startswith(
                "https://pbs.twimg.com/profile_images"
            ) else " "
        )
        + '"><div class="og-embed__content"><div class="og-embed__title">'
        + title
        + '</div><div class="og-embed__description">'
        + escape(shortened(attrs.get("caption", ""), 560))
        + "</div></div>"
        + (
            '<div class="og-embed__image"><img src="'
            + escape(image)
            + '" class="image center" alt=""></div>' if image
            != "" else ""
        )
        + "</div></figure>"
    )


def resolve(
    mut db: Database,
    mut signer: Signer,
    node: Int,
    plain: Bool,
    mut mentions: List[String],
    depth: Int = 0,
    attachment_depth: Int = 0,
    wrap: Bool = False,
) raises:
    if depth > 512:
        raise Error("Attachment nesting too deep")
    var current = node
    while current != 0:
        var next = native.dom_next(current)
        if native.dom_name(current) == "action-text-attachment":
            var attrs = attributes(current)
            if wrap and "content" in attrs:
                var cleaned = action_sanitize(attrs["content"])
                if String(cleaned.strip()) == "":
                    _ = attrs.pop("content")
                else:
                    attrs["content"] = cleaned^
            var has_attachment_attribute = False
            var escaped_attributes = False
            for key in attrs.keys():
                if key in [
                    "sgid",
                    "content-type",
                    "url",
                    "href",
                    "filename",
                    "filesize",
                    "width",
                    "height",
                    "previewable",
                    "presentation",
                    "caption",
                    "content",
                ]:
                    if key != "href" or safe_url(
                        uri_escape(attrs[key]) if escaped_attributes else attrs[
                            key
                        ]
                    ):
                        has_attachment_attribute = True
                if " " + key + " " in ATTRS or key == "style":
                    escaped_attributes = True
            if wrap:
                for key in [
                    "sgid",
                    "content-type",
                    "url",
                    "href",
                    "filename",
                    "filesize",
                    "width",
                    "height",
                    "previewable",
                    "presentation",
                    "caption",
                    "content",
                ]:
                    if key in attrs:
                        has_attachment_attribute = True
            if not plain and not has_attachment_attribute:
                raise Error("Attachment is missing its attributes")
            var sgid = attrs.get("sgid", "")
            var verified = signer.verify(
                db, "signed_global_ids", sgid, "attachable", False
            )
            var gid = verified
            if gid == "" and sgid != "":
                gid = display_user_gid(db, sgid)
            var replacement = String("☒")
            if (
                regex(
                    "application/vnd.actiontext.opengraph-embed",
                    attrs.get("content-type", ""),
                )[0]
                >= 0
            ):
                var preview_attrs = attrs.copy()
                if not wrap and "href" in preview_attrs:
                    preview_attrs["href"] = uri_escape(preview_attrs["href"])
                var preview = embed(
                    preview_attrs^,
                    db.request_host if db.request_host
                    != "" else network.component(getenv("PUBLIC_ORIGIN", "")),
                )
                replacement = "" if plain else preview^
            elif gid.startswith("gid://campfire/User/"):
                var uid = String(String(gid[byte=20:]).split("?")[0])
                var rows = db.rows(
                    "SELECT name,strftime('%Y%m%d%H%M%S',updated_at),coalesce(bio,'') FROM users WHERE id=?",
                    [uid],
                )
                if len(rows) > 0:
                    if verified != "" and uid not in mentions:
                        mentions.append(uid)
                    if wrap:
                        attrs[
                            "content-type"
                        ] = "application/vnd.campfire.mention"
                    replacement = "@" + rows[0][0]
                    if plain:
                        replacement = content_plain(replacement)
                    if not plain:
                        replacement = (
                            '<span class="mention" sgid="'
                            + escape(
                                signer.envelope(
                                    "signed_global_ids",
                                    json_string(
                                        "gid://campfire/User/"
                                        + uid
                                        + "?expires_in"
                                    ),
                                    "attachable",
                                    "",
                                    True,
                                ) if wrap else sgid
                            )
                            + '"><a title="'
                            + escape(
                                rows[0][0]
                                + (
                                    " – " + rows[0][2] if rows[0][2]
                                    != "" else ""
                                )
                            )
                            + '" class="btn avatar" href="/users/'
                            + uid
                            + '"><img src="'
                            + escape(signer.avatar(uid, rows[0][1]))
                            + '" width="48" height="48"></a> '
                            + escape(rows[0][0])
                            + "</span>"
                        )
            elif gid.startswith("gid://campfire/ActiveStorage::Blob/"):
                var bid = String(String(gid[byte=35:]).split("?")[0])
                var rows = db.rows(
                    "SELECT filename,content_type FROM active_storage_blobs WHERE id=?",
                    [bid],
                )
                if len(rows) > 0:
                    replacement = rows[0][0]
                    if not plain:
                        var path = storage.blob_path(signer, bid, rows[0][0])
                        replacement = (
                            '<a href="'
                            + escape(path)
                            + '">'
                            + escape(rows[0][0])
                            + "</a>"
                        )
                        if (
                            rows[0][1].startswith("image/")
                            and rows[0][1] != "image/svg+xml"
                        ):
                            replacement = (
                                '<img src="'
                                + escape(path)
                                + '" alt="'
                                + escape(rows[0][0])
                                + '">'
                            )
            elif (
                "html" in attrs.get("content-type", "")
                and String(attrs.get("content", "").strip()) != ""
            ):
                var content = attrs["content"]
                if plain:
                    replacement = content_plain(content)
                    if (
                        replacement == ""
                        and String(action_sanitize(content).strip()) == ""
                    ):
                        replacement = "☒"
                elif attachment_depth < 8:
                    var sanitized = sanitize_content(content)
                    replacement = (
                        body_inner(
                            db, signer, sanitized, attachment_depth + 1
                        ) if wrap else resolved(
                            db,
                            signer,
                            sanitized,
                            False,
                            True,
                            attachment_depth + 1,
                        )
                    ) if sanitized != "" else "☒"
                else:
                    replacement = ""
                if not plain and replacement != "☒":
                    replacement = (
                        '<figure class="attachment attachment--content">'
                        + replacement
                        + "</figure>"
                    )
            elif (
                "url" in attrs
                and (
                    attrs.get("url", "").startswith("//")
                    or regex(
                        "(?i)^[-a-z]+://|^(?:cid|data):", attrs.get("url", "")
                    )[0]
                    >= 0
                )
                and (
                    attrs.get("content-type", "").startswith("image/")
                    or attrs.get("content-type", "") == "image"
                )
            ):
                var caption = attrs.get("caption", "")
                replacement = (
                    "[" + (caption if caption != "" else "Image") + "]"
                )
                if not plain:
                    var url = attrs["url"]
                    if (
                        not url.startswith("/")
                        and "://" not in url
                        and not url.startswith("data:")
                        and not url.startswith("cid:")
                    ):
                        raise Error("Unknown image asset")
                    var dimensions = String()
                    for key in ["width", "height"]:
                        if key in attrs:
                            dimensions += (
                                " " + key + '="' + escape(attrs[key]) + '"'
                            )
                    replacement = (
                        '<figure class="attachment attachment--preview">\n  <img'
                        + dimensions
                        + ' src="'
                        + escape(url)
                        + '">\n'
                        + (
                            '    <figcaption class="attachment__caption">\n      '
                            + escape(caption)
                            + "\n    </figcaption>\n" if caption
                            != "" else ""
                        )
                        + "</figure>"
                    )
            elif "url" in attrs and (
                attrs.get("content-type", "").startswith("video/")
                or attrs.get("content-type", "") == "video"
            ):
                var caption = attrs.get("caption", "")
                replacement = (
                    "["
                    + (
                        caption if caption
                        != "" else attrs.get("filename", "Video")
                    )
                    + "]" if plain else '<figure class="attachment attachment--preview"><video controls src="'
                    + escape(attrs["url"])
                    + '"></video>'
                    + (
                        "<figcaption>"
                        + escape(caption)
                        + "</figcaption>" if caption
                        != "" else ""
                    )
                    + "</figure>"
                )
                if wrap:
                    var dimensions = String()
                    for key in ["width", "height"]:
                        if key in attrs:
                            dimensions += (
                                " " + key + '="' + escape(attrs[key]) + '"'
                            )
                    replacement = (
                        '<figure class="attachment attachment--preview attachment--video"><video controls="controls"'
                        + dimensions
                        + '><source src="'
                        + escape(attrs["url"])
                        + '"></video>'
                        + (
                            '<figcaption class="attachment__caption">'
                            + escape(caption)
                            + "</figcaption>" if caption
                            != "" else ""
                        )
                        + "</figure>"
                    )
            if wrap:
                var full = String("<action-text-attachment")
                var count = 0
                for key in [
                    "sgid",
                    "content-type",
                    "url",
                    "href",
                    "filename",
                    "filesize",
                    "width",
                    "height",
                    "previewable",
                    "presentation",
                    "caption",
                    "content",
                ]:
                    if key in attrs:
                        full += " " + key + '="' + escape(attrs[key]) + '"'
                        count += 1
                if count == 0:
                    raise Error("Attachment is missing its attributes")
                replacement = (
                    full + ">" + replacement + "</action-text-attachment>"
                )
            if plain:
                _ = native.dom_replace_text(current, replacement)
            else:
                _ = native.dom_replace_html(
                    current, replacement.as_bytes(), replacement.byte_length()
                )
        else:
            resolve(
                db,
                signer,
                native.dom_child(current),
                plain,
                mentions,
                depth + 1,
                attachment_depth,
                wrap,
            )
        current = next


def resolved(
    mut db: Database,
    mut signer: Signer,
    var source: String,
    plain: Bool = False,
    preserve_style: Bool = False,
    attachment_depth: Int = 0,
) raises -> String:
    if (
        plain
        and "action-text-attachment" not in source
        and "data-trix-attachment" not in source
    ):
        return convert(source, True)
    source = ruby_strip(source)
    var doc = native.dom_parse_fragment(source.as_bytes(), source.byte_length())
    if doc == 0:
        raise Error("Cannot parse attachments")
    try:
        var root = native.dom_root(doc)
        if not plain:
            if not preserve_style:
                remove_solo_link(db, signer, root, source)
                prune_tags(root)
            galleries(root)
        var mentions = List[String]()
        resolve(db, signer, root, plain, mentions, 0, attachment_depth)
        var value = plain_nodes(root) if plain else walk(
            root, False, True, 0, preserve_style
        )
        var result = chomp(value) if plain else final_html(
            value
        ) if not preserve_style else value
        native.dom_free(doc)
        return result^
    except e:
        native.dom_free(doc)
        raise e^


def mention_ids(
    mut db: Database, mut signer: Signer, var source: String
) raises -> List[String]:
    var ids = List[String]()
    if "<" not in source:
        return ids^
    var doc = native.dom_parse_fragment(source.as_bytes(), source.byte_length())
    if doc == 0:
        raise Error("Cannot parse mentions")
    try:
        verified_mentions(db, signer, native.dom_root(doc), ids)
        native.dom_free(doc)
        return ids^
    except e:
        native.dom_free(doc)
        raise e^


def verified_mentions(
    mut db: Database,
    mut signer: Signer,
    node: Int,
    mut ids: List[String],
    depth: Int = 0,
) raises:
    if depth > 512:
        raise Error("Mention nesting too deep")
    var current = node
    while current != 0:
        if native.dom_name(current) == "action-text-attachment":
            var gid = signer.verify(
                db,
                "signed_global_ids",
                attributes(current).get("sgid", ""),
                "attachable",
                False,
            )
            if gid.startswith("gid://campfire/User/"):
                var uid = String(String(gid[byte=20:]).split("?")[0])
                if (
                    uid not in ids
                    and db.scalar("SELECT 1 FROM users WHERE id=?", [uid])
                    == "1"
                ):
                    ids.append(uid)
        else:
            verified_mentions(
                db, signer, native.dom_child(current), ids, depth + 1
            )
        current = native.dom_next(current)


def editable_nodes(
    mut db: Database, mut signer: Signer, node: Int, depth: Int = 0
) raises:
    if depth > 512:
        raise Error("Editor nesting too deep")
    var current = node
    while current != 0:
        var next = native.dom_next(current)
        if native.dom_name(current) == "action-text-attachment":
            var attrs = attributes(current)
            var content = String()
            var content_type = String()
            if (
                regex(
                    "application/vnd.actiontext.opengraph-embed",
                    attrs.get("content-type", ""),
                )[0]
                >= 0
            ):
                content = embed(attrs.copy(), db.request_host).replace(
                    ' rel="noreferrer" target="_blank"', ""
                )
                content_type = "application/vnd.actiontext.opengraph-embed"
            else:
                var sgid = attrs.get("sgid", "")
                var gid = signer.verify(
                    db, "signed_global_ids", sgid, "attachable", False
                )
                if gid == "" and sgid != "":
                    gid = display_user_gid(db, sgid)
                if gid.startswith("gid://campfire/User/"):
                    var uid = String(String(gid[byte=20:]).split("?")[0])
                    var users = db.rows(
                        "SELECT name,coalesce(bio,''),strftime('%Y%m%d%H%M%S',updated_at) FROM users WHERE id=?",
                        [uid],
                    )
                    if len(users) > 0:
                        var user = users[0].copy()
                        var fresh = signer.envelope(
                            "signed_global_ids",
                            json_string(
                                "gid://campfire/User/" + uid + "?expires_in"
                            ),
                            "attachable",
                            "",
                            True,
                        )
                        content = (
                            '<span class="mention" sgid="'
                            + escape(fresh)
                            + '"><a title="'
                            + escape(
                                user[0]
                                + (" – " + user[1] if user[1] != "" else "")
                            )
                            + '" class="btn avatar" data-turbo-frame="_top" href="/users/'
                            + uid
                            + '"><img aria-hidden="true" src="'
                            + escape(signer.avatar(uid, user[2]))
                            + '" width="48" height="48" /></a> '
                            + escape(user[0])
                            + "</span>"
                        )
                        content_type = "application/vnd.campfire.mention"
            if content_type == "":
                # Rails cannot edit these custom attachment types. Missing records,
                # like the Rust port, are omitted so the surrounding text survives.
                if (
                    "html" in attrs.get("content-type", "")
                    and String(attrs.get("content", "").strip()) != ""
                ) or (
                    "url" in attrs
                    and (
                        attrs.get("content-type", "").startswith("image")
                        or attrs.get("content-type", "").startswith("video")
                    )
                ):
                    raise Error("Unsupported editable attachment type")
                native.dom_remove(current)
            else:
                # Current Action Text rebuilds attachment nodes from its public
                # attribute set and discards stale nested editor markup.
                native.dom_clear_node(current)
                for field in [
                    "sgid",
                    "content-type",
                    "url",
                    "href",
                    "filename",
                    "filesize",
                    "width",
                    "height",
                    "previewable",
                    "presentation",
                    "caption",
                ]:
                    if field in attrs:
                        var value = attrs[field]
                        var attribute_name = field.copy()
                        native.dom_set_attr(current, attribute_name, value)
                var key = String("content-type")
                native.dom_set_attr(current, key, content_type)
                key = "content"
                native.dom_set_attr(current, key, content)
        else:
            editable_nodes(db, signer, native.dom_child(current), depth + 1)
        current = next


def editor_html(
    node: Int, depth: Int = 0, raw_text: Bool = False
) raises -> String:
    # Editor values are data, escaped into an HTML attribute by the caller.
    # Preserve Lexxy/Trix metadata here; presentation sanitization happens on read.
    if depth > 512:
        raise Error("Editor nesting too deep")
    var out = String()
    var current = node
    while current != 0:
        var kind = native.dom_type(current)
        if kind == 3:
            out += native.dom_text(current) if raw_text else text_html(
                native.dom_text(current)
            )
        elif kind == 8:
            out += "<!--" + native.dom_text(current) + "-->"
        elif kind == 1:
            var name = native.dom_name(current)
            out += "<" + name
            var attr = native.dom_attrs(current)
            while attr != 0:
                out += (
                    " "
                    + native.dom_attr_name(attr)
                    + '="'
                    + escape(native.dom_attr_text(attr))
                    + '"'
                )
                attr = native.dom_attr_next(attr)
            out += ">" + editor_html(
                native.dom_child(current),
                depth + 1,
                native.dom_foreign(current) == 0
                and name
                in [
                    "script",
                    "style",
                    "xmp",
                    "iframe",
                    "noembed",
                    "noframes",
                    "plaintext",
                    "noscript",
                ],
            )
            if name not in [
                "area",
                "base",
                "br",
                "col",
                "embed",
                "hr",
                "img",
                "input",
                "link",
                "meta",
                "param",
                "source",
                "track",
                "wbr",
            ]:
                out += "</" + name + ">"
        current = native.dom_next(current)
    return out^


def editable(
    mut db: Database, mut signer: Signer, var source: String
) raises -> String:
    source = ruby_strip(source)
    var doc = native.dom_parse_fragment(source.as_bytes(), source.byte_length())
    if doc == 0:
        raise Error("Cannot parse editable message")
    try:
        var root = native.dom_root(doc)
        editable_nodes(db, signer, root)
        var serialized = editor_html(native.dom_child(root))
        var second = native.dom_parse_fragment(
            serialized.as_bytes(), serialized.byte_length()
        )
        if second == 0:
            raise Error("Cannot parse rebuilt editor value")
        var result = editor_html(native.dom_child(native.dom_root(second)))
        native.dom_free(second)
        native.dom_free(doc)
        return result^
    except e:
        native.dom_free(doc)
        raise e^


def embedded_ids(
    mut db: Database,
    mut signer: Signer,
    node: Int,
    mut ids: List[String],
    depth: Int = 0,
) raises:
    if depth > 512:
        raise Error("Attachment nesting too deep")
    var current = node
    while current != 0:
        if native.dom_name(current) == "action-text-attachment":
            var gid = signer.verify(
                db,
                "signed_global_ids",
                attributes(current).get("sgid", ""),
                "attachable",
                False,
            )
            if gid.startswith("gid://campfire/ActiveStorage::Blob/"):
                var bid = String(String(gid[byte=35:]).split("?")[0])
                if (
                    bid not in ids
                    and db.scalar(
                        "SELECT 1 FROM active_storage_blobs WHERE id=?", [bid]
                    )
                    == "1"
                ):
                    ids.append(bid)
        embedded_ids(db, signer, native.dom_child(current), ids, depth + 1)
        current = native.dom_next(current)


def sync_embeds(
    mut db: Database, mut signer: Signer, id: String, var source: String
) raises:
    var ids = List[String]()
    if "action-text-attachment" in source:
        var doc = native.dom_parse_fragment(
            source.as_bytes(), source.byte_length()
        )
        if doc == 0:
            raise Error("Cannot parse attachments")
        try:
            embedded_ids(db, signer, native.dom_root(doc), ids)
            native.dom_free(doc)
        except e:
            native.dom_free(doc)
            raise e^
    var old = db.rows(
        "SELECT blob_id FROM active_storage_attachments WHERE record_type='ActionText::RichText' AND record_id=? AND name='embeds'",
        [id],
    )
    _ = db.rows(
        "DELETE FROM active_storage_attachments WHERE record_type='ActionText::RichText' AND record_id=? AND name='embeds'",
        [id],
    )
    for blob in ids:
        _ = db.rows(
            "INSERT INTO active_storage_attachments(name,record_type,record_id,blob_id,created_at) VALUES('embeds','ActionText::RichText',?,?,strftime('%Y-%m-%d %H:%M:%f','now'))",
            [id, blob],
        )
    for blob in old:
        storage.purge(db, blob[0])


# ActionText::PlainTextConversion; this also feeds FTS, notifications and bots.
def chomp(value: String) -> String:
    var end = value.byte_length()
    var b = value.as_bytes()
    while end > 0 and (b[end - 1] == 10 or b[end - 1] == 13):
        end -= 1
    return String(value[byte=:end])


def ruby_strip(value: String) -> String:
    var b = value.as_bytes()
    var start = 0
    var end = len(b)
    while start < end and Int(b[start]) in [0, 9, 10, 11, 12, 13, 32]:
        start += 1
    while end > start and Int(b[end - 1]) in [0, 9, 10, 11, 12, 13, 32]:
        end -= 1
    return String(value[byte=start:end])


def plain_nodes(
    node: Int, lists: Int = 0, ordered: Bool = False, depth: Int = 0
) raises -> String:
    if depth > 512:
        raise Error("Rich text nesting too deep")
    var out = String()
    var current = node
    var index = 0
    while current != 0:
        var name = native.dom_name(current)
        var kind = native.dom_type(current)
        if kind == 3:
            out += chomp(native.dom_text(current))
        elif kind == 1 and name not in ["script", "style", "unsupported"]:
            index += 1
            var is_list = name == "ul" or name == "ol"
            var inside = plain_nodes(
                native.dom_child(current),
                lists + Int(is_list),
                name == "ol" if is_list else ordered,
                depth + 1,
            )
            if name == "br":
                out += "\n"
            elif name in ["h1", "h2", "h3", "h4", "h5", "h6", "p"] or is_list:
                out += (
                    ("\n" if is_list and lists > 0 else "")
                    + chomp(inside)
                    + "\n\n"
                )
            elif name == "div":
                out += chomp(inside) + "\n"
            elif name == "figcaption":
                out += "[" + chomp(inside) + "]"
            elif name == "li":
                var indentation = String()
                for _ in range(max(0, lists - 1)):
                    indentation += "  "
                out += (
                    indentation
                    + (String(index) + "." if ordered else "•")
                    + " "
                    + chomp(inside)
                    + "\n"
                )
            elif name == "blockquote":
                var text = chomp(inside) + "\n\n"
                var trimmed = ruby_strip(text)
                if trimmed == "":
                    out += "“”"
                else:
                    var at = text.find(trimmed)
                    out += (
                        String(text[byte=:at])
                        + "“"
                        + trimmed
                        + "”"
                        + String(text[byte = at + trimmed.byte_length() :])
                    )
            else:
                out += inside
        current = native.dom_next(current)
    return out^


def normalize_legacy(mut db: Database, node: Int, depth: Int = 0) raises:
    if depth > 512:
        raise Error("Rich text nesting too deep")
    var current = node
    while current != 0:
        var next = native.dom_next(current)
        if native.dom_type(current) == 1:
            var attrs = attributes(current)
            if "data-trix-attachment" in attrs:
                var mapped = Dict[String, String]()
                for key in ["data-trix-attachment", "data-trix-attributes"]:
                    var data = attrs.get(key, "")
                    if db.scalar("SELECT json_valid(?,6)", [data]) != "1":
                        continue
                    var kind = db.scalar("SELECT json_type(?)", [data])
                    if kind == "null" or kind == "false":
                        continue
                    if kind != "object":
                        raise Error("Invalid legacy attachment object")
                    for attr in db.rows(
                        "SELECT key,CASE WHEN type IN ('true','false') THEN type ELSE coalesce(cast(value AS TEXT),'') END FROM json_each(?)",
                        [data],
                    ):
                        var name = (
                            "content-type" if attr[0]
                            == "contentType" else attr[0]
                        )
                        if name in [
                            "sgid",
                            "content-type",
                            "url",
                            "href",
                            "filename",
                            "filesize",
                            "width",
                            "height",
                            "previewable",
                            "content",
                            "caption",
                            "presentation",
                        ]:
                            mapped[name] = attr[1]
                if len(mapped) == 0:
                    native.dom_remove(current)
                    current = next
                    continue
                if mapped.get("sgid", "") != "":
                    _ = display_user_gid(db, mapped["sgid"])
                native.dom_clear_node(current)
                var tag = String("action-text-attachment")
                native.dom_set_name(current, tag)
                for key in mapped.keys():
                    var value = mapped[key]
                    var name = key.copy()
                    native.dom_set_attr(current, name, value)
            else:
                normalize_legacy(db, native.dom_child(current), depth + 1)
        current = next


def canonical(mut db: Database, var source: String) raises -> String:
    if "data-trix-attachment" not in source:
        return convert(source, False, True)
    source = ruby_strip(source)
    var doc = native.dom_parse_fragment(source.as_bytes(), source.byte_length())
    if doc == 0:
        raise Error("Cannot parse rich text")
    try:
        var root = native.dom_root(doc)
        var result = walk(root, False, True, 0, True)
        native.dom_free(doc)
        return result^
    except e:
        native.dom_free(doc)
        raise e^


def display_user_gid(mut db: Database, sgid: String) raises -> String:
    # Rails deliberately permits old User mentions after SECRET_KEY_BASE rotation.
    # This fallback only changes display; delivery still requires a verified SGID.
    if sgid == "" or sgid.replace("--", "") == "":
        return ""
    var encoded = String(sgid.split("--")[0])
    var payload = unbase64(encoded).text()
    if db.scalar("SELECT json_valid(?)", [payload]) != "1":
        raise Error("Invalid mention encoding")
    if db.scalar("SELECT json_type(?)", [payload]) != "object":
        raise Error("Invalid mention envelope")
    var gid = String()
    if db.scalar("SELECT json_type(?,'$._rails.data')", [payload]) == "text":
        gid = db.scalar("SELECT json_extract(?,'$._rails.data')", [payload])
    elif (
        db.scalar("SELECT json_type(?,'$._rails.message')", [payload]) == "text"
    ):
        var bytes = unbase64(
            db.scalar("SELECT json_extract(?,'$._rails.message')", [payload])
        )
        var at = bytes.find("gid://campfire/User/")
        if at >= 0:
            var end = at + 20
            while (
                end < bytes.byte_length()
                and bytes.as_bytes()[end] >= 48
                and bytes.as_bytes()[end] <= 57
            ):
                end += 1
            gid = bytes.slice(at, end).text()
    if gid.startswith("gid://"):
        var pieces = gid.split("/")
        if len(pieces) >= 5 and String(pieces[3]) == "User":
            var id = String(String(pieces[4]).split("?")[0])
            if id != "":
                for c in id.as_bytes():
                    if c < 48 or c > 57:
                        return ""
                return "gid://campfire/User/" + id
    return ""


def unwrap_content_scripts(node: Int, depth: Int = 0) raises:
    if depth > 512:
        raise Error("Content nesting too deep")
    var current = node
    while current != 0:
        var name = native.dom_name(current)
        if name == "script" or name == "style":
            var span = String("unwrap")
            native.dom_set_name(current, span)
        unwrap_content_scripts(native.dom_child(current), depth + 1)
        current = native.dom_next(current)


def content_plain(var source: String) raises -> String:
    var doc = native.dom_parse_fragment(source.as_bytes(), source.byte_length())
    if doc == 0:
        raise Error("Cannot parse attachment content")
    try:
        var root = native.dom_root(doc)
        unwrap_content_scripts(root)
        var value = chomp(plain_nodes(root))
        native.dom_free(doc)
        return value^
    except e:
        native.dom_free(doc)
        raise e^


def plain_color(var value: String) -> Bool:
    value = String(value.strip()).lower()
    if value == "":
        return False
    var chars = value.as_bytes()
    var letters = True
    for c in chars:
        if c < 97 or c > 122:
            letters = False
    if letters:
        return True
    if chars[0] == 35 and len(chars) >= 4 and len(chars) <= 9:
        for i in range(1, len(chars)):
            var c = chars[i]
            if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
                return False
        return True
    if value.startswith("var(") and value.endswith(")"):
        var name = String(value[byte = 4 : value.byte_length() - 1].strip())
        if not name.startswith("--") or name.byte_length() < 3:
            return False
        for c in name.as_bytes():
            if not (
                (c >= 97 and c <= 122)
                or (c >= 48 and c <= 57)
                or Int(c) in [45, 95]
            ):
                return False
        return True
    for prefix in ["rgb(", "rgba(", "hsl(", "hsla("]:
        if value.startswith(prefix) and value.endswith(")"):
            var inner = String(
                value[byte = prefix.byte_length() : value.byte_length() - 1]
            )
            for c in inner.as_bytes():
                if not (
                    (c >= 97 and c <= 122)
                    or (c >= 48 and c <= 57)
                    or Int(c) in [9, 10, 12, 13, 32, 44, 46, 37, 47, 43, 45]
                ):
                    return False
            return True
    return False


def sanitize_style(value: String) -> String:
    var accepted = String()
    var rejected = False
    for declaration in value.split(";"):
        if String(declaration.strip()) == "":
            continue
        var pair = declaration.split(":", maxsplit=1)
        if len(pair) == 2:
            var key = String(pair[0].strip()).lower()
            var color = String(pair[1].strip())
            if (key == "color" or key == "background-color") and plain_color(
                color
            ):
                accepted += key + ": " + color + ";"
                continue
        rejected = True
    return value if not rejected and accepted != "" else accepted


comptime FINAL_TAGS = " a abbr acronym address b big blockquote br cite code dd del dfn div dl dt em h1 h2 h3 h4 h5 h6 hr i img ins kbd li mark ol p pre s samp small span strong sub sup table tbody td tfoot th thead time tr tt u ul var "
comptime FINAL_ATTRS = " abbr alt cite class datetime height href lang src title width xml:lang data-language "
comptime INPUT_TAGS = " a abbr acronym address b big blockquote br cite code dd del dfn div dl dt em h1 h2 h3 h4 h5 h6 hr i ins kbd li mark ol p pre s samp small span strong sub sup table tbody td tfoot th thead time tr tt u ul var action-text-attachment figure figcaption "


def prune_tags(node: Int, depth: Int = 0) raises:
    if depth > 512:
        raise Error("Rich text nesting too deep")
    var current = node
    while current != 0:
        var next = native.dom_next(current)
        var name = native.dom_name(current)
        if (
            native.dom_type(current) == 1
            and name != "html"
            and " " + name + " " not in INPUT_TAGS
        ):
            native.dom_remove(current)
        else:
            prune_tags(native.dom_child(current), depth + 1)
        current = next


def final_html(var source: String) raises -> String:
    source = '<div class="lexxy-content">' + source + "</div>"
    var doc = native.dom_parse_fragment(source.as_bytes(), source.byte_length())
    if doc == 0:
        raise Error("Cannot parse rendered rich text")
    try:
        var root = native.dom_child(native.dom_root(doc))
        var result = walk(native.dom_child(root), False, True, 0, False, True)
        result = autolink_html(result)
        native.dom_free(doc)
        return result^
    except e:
        native.dom_free(doc)
        raise e^


def sanitize_content(var source: String) raises -> String:
    var doc = native.dom_parse_fragment(source.as_bytes(), source.byte_length())
    if doc == 0:
        raise Error("Cannot parse content")
    try:
        var root = native.dom_root(doc)
        unwrap_content_scripts(root)
        var result = walk(root, False, True, 0, True)
        native.dom_free(doc)
        return result^
    except e:
        native.dom_free(doc)
        raise e^


def galleries(node: Int, depth: Int = 0) raises:
    if depth > 512:
        raise Error("Gallery nesting too deep")
    var current = node
    while current != 0:
        var child = native.dom_child(current)
        if native.dom_name(current) == "div":
            var count = 0
            var eligible = True
            var c = child
            while c != 0:
                if (
                    native.dom_name(c) == "action-text-attachment"
                    and attributes(c).get("presentation", "") == "gallery"
                ):
                    count += 1
                elif (
                    native.dom_type(c) != 3
                    or native.dom_text(c).replace(" ", "").replace("\n", "")
                    != ""
                ):
                    eligible = False
                c = native.dom_next(c)
            if eligible and count >= 2:
                var key = String("class")
                var value = "attachment-gallery attachment-gallery--" + String(
                    count
                )
                native.dom_set_attr(current, key, value)
        galleries(child, depth + 1)
        current = native.dom_next(current)


def og_nodes(node: Int, mut nodes: List[Int], depth: Int = 0) raises:
    if depth > 512:
        raise Error("Embed nesting too deep")
    var current = node
    while current != 0:
        if native.dom_name(
            current
        ) == "action-text-attachment" and "application/vnd.actiontext.opengraph-embed" in attributes(
            current
        ).get(
            "content-type", ""
        ):
            nodes.append(current)
        else:
            og_nodes(native.dom_child(current), nodes, depth + 1)
        current = native.dom_next(current)


def normalize_tweet(value: String) raises -> String:
    var host = network.component(value).lower()
    if host != "x.com" and host != "twitter.com":
        return value
    return String(value.split("?")[0]).replace("://x.com/", "://twitter.com/")


def remove_solo_link(
    mut db: Database, mut signer: Signer, root: Int, source: String
) raises:
    var nodes = List[Int]()
    og_nodes(root, nodes)
    if len(nodes) != 1:
        return
    var attrs = attributes(nodes[0])
    if attrs.get("href", "") == "":
        var content = attrs.get("content", "")
        var doc = native.dom_parse_fragment(
            content.as_bytes(), content.byte_length()
        )
        if doc != 0:
            try:
                embed_content(native.dom_root(doc), attrs)
                native.dom_free(doc)
            except e:
                native.dom_free(doc)
                raise e^
    var href = attrs.get("href", "")
    if href == "" or normalize_tweet(href) != normalize_tweet(
        resolved(db, signer, source, True)
    ):
        return
    var attachment = String("<action-text-attachment")
    for key in attrs.keys():
        attachment += " " + key + '="' + escape(attrs[key]) + '"'
    attachment += "></action-text-attachment>"
    remove_solo_nodes(root, attachment)


def remove_solo_nodes(node: Int, attachment: String, depth: Int = 0) raises:
    if depth > 512:
        raise Error("Embed nesting too deep")
    var current = node
    while current != 0:
        var next = native.dom_next(current)
        var name = native.dom_name(current)
        if name == "div":
            _ = native.dom_inner_html(
                current, attachment.as_bytes(), attachment.byte_length()
            )
        elif name == "p":
            var nodes = List[Int]()
            og_nodes(native.dom_child(current), nodes)
            if len(nodes) == 0:
                native.dom_remove(current)
        else:
            remove_solo_nodes(native.dom_child(current), attachment, depth + 1)
        current = next


struct LinkScan(Movable):
    var position: Int
    var tag: Bool
    var anchor: Bool
    var newline_in_tag: Bool

    def __init__(out self):
        self.position = 0
        self.tag = False
        self.anchor = False
        self.newline_in_tag = False

    def linked(mut self, source: String, start: Int, end: Int) -> Bool:
        var b = source.as_bytes()
        while self.position < start:
            var i = self.position
            if b[i] == 60:
                self.tag = True
                if (
                    i + 2 < len(b)
                    and b[i + 1] == 97
                    and Int(b[i + 2]) in [9, 10, 12, 13, 32, 62]
                ):
                    self.anchor = True
                elif (
                    i + 3 < len(b)
                    and b[i + 1] == 47
                    and b[i + 2] == 97
                    and b[i + 3] == 62
                ):
                    self.anchor = False
            elif b[i] == 62:
                self.tag = False
            elif b[i] == 10 and self.tag:
                self.newline_in_tag = True
            self.position += 1
        return (
            self.tag
            or self.anchor
            or (
                self.newline_in_tag and String(source[byte=end:]).find(">") >= 0
            )
        )


def text_html(value: String) -> String:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\u00a0", "&nbsp;")
    )


def autolink_html(source: String) -> String:
    # This is rails_autolink's two-pass algorithm over already sanitized HTML.
    # Attribute brackets are escaped before scanning, avoiding its stored XSS.
    var urls = String(
        '(?:(?i:(?:ed2k|ftp|http|https|irc|mailto|news|gopher|nntp|telnet|webcal|xmpp|callto|feed|svn|urn|aim|rsync|tag|ssh|sftp|rtsp|afs|file):)//|(?i:www)\\.[a-zA-Z0-9_])[^ \\t\\r\\n\\x0B\\x0C<\\x{A0}"]+'
    )
    var emails = String(
        "(?<![a-zA-Z0-9_.!#$%&'*/=?^`{|}~+-])[a-zA-Z0-9_.!#$%+-]\\.?[a-zA-Z0-9_.!#$%&'*/=?^`{|}~+-]*@[a-zA-Z0-9_-]+(?:\\.[a-zA-Z0-9_-]+)+"
    )
    var out = String()
    var copied = 0
    var scanner = LinkScan()
    while copied < source.byte_length():
        var found = regex(urls, source, copied)
        if found[0] < 0:
            break
        out += String(source[byte = copied : found[0]])
        var value = String(source[byte = found[0] : found[1]])
        if scanner.linked(source, found[0], found[1]):
            out += value
        else:
            var suffix = String()
            var chars = List[String]()
            for cp in value.codepoints():
                chars.append(String(cp))
            while len(chars) > 0:
                var last = chars[len(chars) - 1]
                if last in ["/", "-", "=", ";"] or regex("\\w", last)[0] >= 0:
                    break
                var opening = (
                    "(" if last
                    == ")" else "[" if last
                    == "]" else "{" if last
                    == "}" else ""
                )
                if opening != "":
                    var balance = 0
                    for c in chars:
                        balance += Int(c == opening) - Int(c == last)
                    if balance == 0:
                        break
                suffix = chars.pop() + suffix
            value = "".join(chars)
            var trailing = String()
            if value.endswith("&gt;"):
                trailing = "&gt;"
                var shortened = String(value[byte = : value.byte_length() - 4])
                value = shortened^
            var href = (
                "http://" + value if value.lower().startswith("www.") else value
            )
            out += (
                '<a target="_blank" href="'
                + href.replace('"', "&quot;")
                + '">'
                + value
                + "</a>"
                + text_html(suffix)
                + trailing
            )
        copied = found[1]
    out += String(source[byte=copied:])
    var html = out^
    out = ""
    copied = 0
    scanner = LinkScan()
    while copied < html.byte_length():
        var found = regex(emails, html, copied)
        if found[0] < 0:
            break
        out += String(html[byte = copied : found[0]])
        var value = String(html[byte = found[0] : found[1]])
        if scanner.linked(html, found[0], found[1]):
            out += value
        else:
            out += (
                '<a target="_blank" href="mailto:'
                + escape(url_encode(value).replace("%40", "@"))
                + '">'
                + escape(value)
                + "</a>"
            )
        copied = found[1]
    return out + String(html[byte=copied:])


comptime ACTION_TAGS = FINAL_TAGS + " action-text-attachment figure figcaption video audio source embed "
comptime ACTION_ATTRS = FINAL_ATTRS + " sgid content-type url href filename filesize width height previewable presentation caption content controls poster style value start "


def action_style(value: String) -> String:
    var out = String()
    for declaration in value.split(";"):
        var pair = declaration.split(":", maxsplit=1)
        if len(pair) != 2:
            continue
        var key = String(pair[0].strip()).lower()
        var val = String(pair[1].strip())
        if (
            (key == "color" or key == "background-color") and plain_color(val)
        ) or (
            key == "white-space"
            and val
            in [
                "normal",
                "pre",
                "nowrap",
                "pre-wrap",
                "pre-line",
                "break-spaces",
            ]
        ):
            out += key + ":" + val + ";"
    return out^


def action_nodes(node: Int, depth: Int = 0) raises -> String:
    if depth > 512:
        raise Error("Rich text nesting too deep")
    var out = String()
    var current = node
    while current != 0:
        var kind = native.dom_type(current)
        var name = native.dom_name(current)
        if kind == 3:
            out += text_html(native.dom_text(current))
        elif kind == 1 and name not in ["svg", "math"]:
            var inside = action_nodes(native.dom_child(current), depth + 1)
            if " " + name + " " in ACTION_TAGS:
                out += "<" + name
                var attr = native.dom_attrs(current)
                var escaped_urls = False
                while attr != 0:
                    var key = native.dom_attr_name(attr)
                    var value = native.dom_attr_text(attr)
                    if " " + key + " " in ACTION_ATTRS:
                        if key == "style":
                            value = action_style(value)
                            out += ' style="' + escape(value) + '"'
                        else:
                            var uri = key in ["href", "src", "cite", "poster"]
                            if escaped_urls and key in ["href", "src"]:
                                value = uri_escape(value)
                            if (not uri or safe_url(value)) and (
                                key != "src" or String(value.strip()) != ""
                            ):
                                if key in ["href", "src"]:
                                    value = uri_escape(value)
                                out += " " + key + '="' + escape(value) + '"'
                        escaped_urls = True
                    attr = native.dom_attr_next(attr)
                out += ">" + inside
                if name not in ["br", "hr", "img", "source", "embed"]:
                    out += "</" + name + ">"
            else:
                out += inside
        current = native.dom_next(current)
    return out^


def action_sanitize(var source: String) raises -> String:
    var doc = native.dom_parse_fragment(source.as_bytes(), source.byte_length())
    if doc == 0:
        raise Error("Cannot parse Action Text HTML")
    try:
        var result = action_nodes(native.dom_root(doc))
        native.dom_free(doc)
        return result^
    except e:
        native.dom_free(doc)
        raise e^


def body_inner(
    mut db: Database, mut signer: Signer, var source: String, depth: Int = 0
) raises -> String:
    source = ruby_strip(source)
    var doc = native.dom_parse_fragment(source.as_bytes(), source.byte_length())
    if doc == 0:
        raise Error("Cannot parse Action Text body")
    try:
        var root = native.dom_root(doc)
        var mentions = List[String]()
        resolve(db, signer, root, False, mentions, 0, depth, True)
        galleries(root)
        var raw = editor_html(native.dom_child(root))
        var result = action_sanitize(raw)
        native.dom_free(doc)
        return result^
    except e:
        native.dom_free(doc)
        raise e^


def body_html(
    mut db: Database, mut signer: Signer, source: String
) raises -> String:
    return (
        '<div class="lexxy-content">\n  '
        + body_inner(db, signer, source)
        + "\n</div>\n"
    )


def descendant(node: Int, name: String, depth: Int = 0) raises -> Int:
    if depth > 512:
        raise Error("Attachment nesting too deep")
    var current = node
    while current != 0:
        if native.dom_name(current) == name:
            return current
        var found = descendant(native.dom_child(current), name, depth + 1)
        if found != 0:
            return found
        current = native.dom_next(current)
    return 0
