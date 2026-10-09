from std.ffi import external_call
from std.os import getenv
from text import decode
from database import Database
import marshal


def json_string(s: String) -> String:
    # Copy UTF-8 spans intact between ASCII escapes, avoiding a String per character.
    var out = String("\"")
    var start = 0
    var bytes = s.as_bytes()
    var digits = String("0123456789abcdef")
    for i in range(len(bytes)):
        var b = bytes[i]
        var replacement: String
        if b == 34:
            replacement = "\\\""
        elif b == 92:
            replacement = "\\\\"
        elif b == 10:
            replacement = "\\n"
        elif b == 13:
            replacement = "\\r"
        elif b == 9:
            replacement = "\\t"
        elif b < 32:
            replacement = "\\u00" + String(digits[byte=Int(b)//16:Int(b)//16+1]) + String(digits[byte=Int(b)%16:Int(b)%16+1])
        elif b == 60:
            replacement = "\\u003c"
        elif b == 62:
            replacement = "\\u003e"
        elif b == 38:
            replacement = "\\u0026"
        else:
            continue
        out += String(s[byte=start:i])
        out += replacement
        start = i + 1
    out += String(s[byte=start:])
    return out + "\""


def base64(s: String, url: Bool = False, padding: Bool = True) raises -> String:
    var buf = List[UInt8](length=(s.byte_length() + 2) // 3 * 4 + 1, fill=0)
    var n = external_call["base64_encode", Int](
        s.as_bytes().unsafe_ptr(), s.byte_length(), buf.unsafe_ptr()
    )
    if n < 0:
        raise Error("Base64 encoding failed")
    var out = String(from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(), length=n))
    if url:
        out = out.replace("+", "-").replace("/", "_")
    if not padding:
        out = out.replace("=", "")
    return out^


def unbase64(var s: String) raises -> String:
    s = s.replace("-", "+").replace("_", "/")
    while s.byte_length() % 4:
        s += "="
    for c in s.as_bytes():
        if not (
            (c >= 65 and c <= 90)
            or (c >= 97 and c <= 122)
            or (c >= 48 and c <= 57)
            or c == 43
            or c == 47
            or c == 61
        ):
            raise Error("Invalid base64")
    var buf = List[UInt8](length=s.byte_length() + 1, fill=0)
    var n = external_call["base64_decode", Int](
        s.as_bytes().unsafe_ptr(), s.byte_length(), buf.unsafe_ptr()
    )
    if n < 0:
        raise Error("Invalid base64")
    return String(unsafe_from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(), length=n))


def url_encode(s: String) -> String:
    var out = String()
    var digits = String("0123456789ABCDEF")
    for c in s.as_bytes():
        if (
            (c >= 65 and c <= 90)
            or (c >= 97 and c <= 122)
            or (c >= 48 and c <= 57)
            or c == 45
            or c == 46
            or c == 95
            or c == 42
        ):
            out += String(
                unsafe_from_utf8=Span(unsafe_ptr=Pointer(to=c), length=1)
            )
        elif c == 32:
            out += "+"
        else:
            out += (
                "%"
                + String(digits[byte = Int(c) // 16 : Int(c) // 16 + 1])
                + String(digits[byte = Int(c) % 16 : Int(c) % 16 + 1])
            )
    return out^


def secure_equal(var a: String, var b: String) -> Bool:
    return (
        external_call["crypto_equal", Int](
            a.as_c_string_span(), b.as_c_string_span()
        )
        == 1
    )


struct Signer(Movable):
    var keys: Dict[String, String]
    var secret: String
    var clock: String

    def __init__(out self, secret: String = "") raises:
        self.keys = Dict[String, String]()
        self.secret = secret if secret!="" else getenv("SECRET_KEY_BASE", "")
        self.clock = "now"
        if self.secret.byte_length() < 32:
            raise Error("SECRET_KEY_BASE must contain at least 32 bytes")

    def key(mut self, var salt: String) raises -> String:
        if salt not in self.keys:
            var buf = List[UInt8](length=129, fill=0)
            if (
                external_call["crypto_derive", Int](
                    self.secret.as_c_string_span(),
                    salt.as_c_string_span(),
                    buf.unsafe_ptr(),
                )
                != 0
            ):
                raise Error("PBKDF2 failed")
            self.keys[salt] = String(unsafe_from_utf8_ptr=buf.unsafe_ptr())
        return self.keys[salt]

    def mac(
        mut self, salt: String, data: String, sha256: Bool
    ) raises -> String:
        var key = self.key(salt)
        var buf = List[UInt8](length=65, fill=0)
        if (
            external_call["crypto_hmac", Int](
                key.as_c_string_span(),
                data.as_bytes().unsafe_ptr(),
                data.byte_length(),
                Int(sha256),
                buf.unsafe_ptr(),
            )
            != 0
        ):
            raise Error("HMAC failed")
        return String(unsafe_from_utf8_ptr=buf.unsafe_ptr())

    def sign(
        mut self,
        salt: String,
        payload: String,
        sha256: Bool = True,
        url: Bool = False,
    ) raises -> String:
        var encoded = base64(payload, url, not url)
        return encoded + "--" + self.mac(salt, encoded, sha256)

    def stream(mut self, name: String) raises -> String:
        return self.sign("turbo/signed_stream_verifier_key", json_string(name))

    def avatar(mut self, uid: String, version: String) raises -> String:
        var value = self.sign(
            "active_record/signed_id",
            '{"_rails":{"data":' + uid + ',"pur":"user/avatar"}}',
            True,
            True,
        )
        return "/users/" + value + "/avatar?v=" + version

    def cookie(mut self, token: String, expiry: String) raises -> String:
        var payload = (
            '{"_rails":{"message":'
            + json_string(base64(json_string(token)))
            + ',"exp":'
            + json_string(expiry)
            + ',"pur":"cookie.session_token"}}'
        )
        return url_encode(self.sign("signed cookie", payload, False))

    def envelope(mut self, salt: String, data: String, purpose: String, expiry: String = "", url: Bool = False) raises -> String:
        var metadata = '{"_rails":{"data":'+data
        if expiry != "":
            metadata += ',"exp":'+json_string(expiry)
        metadata += ',"pur":'+json_string(purpose)+'}}'
        var encoded = base64(metadata,url,True)
        return encoded+"--"+self.mac(salt,encoded,False)

    def signed_id(mut self, mut db: Database, uid: String, purpose: String, hours: Int = 0) raises -> String:
        var expiry = String()
        if hours > 0:
            expiry = ',"exp":' + json_string(db.scalar("SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now',?)", ["+"+String(hours)+" hours"]))
        return self.sign("active_record/signed_id", '{"_rails":{"data":'+uid+',"pur":'+json_string(purpose)+expiry+'}}', True, True)

    def verify(mut self, mut db: Database, salt: String, wire: String, purpose: String = "", sha256: Bool = True) raises -> String:
        if wire.byte_length() > 16384:
            return ""
        try:
            var offset = wire.byte_length() - (66 if sha256 else 42)
            if offset <= 0 or String(wire[byte=offset:offset+2]) != "--":
                if sha256 and salt=="active_record/signed_id":
                    return self.verify(db,salt,wire,purpose,False)
                return ""
            var encoded = String(wire[byte=:offset])
            if not secure_equal(self.mac(salt, encoded, sha256), String(wire[byte=offset+2:])):
                return ""
            var payload = unbase64(encoded)
            if db.scalar("SELECT json_valid(?)", [payload]) != "1":
                return ""
            if db.scalar("SELECT json_type(?,'$._rails')",[payload])=="":
                if purpose=="":
                    return db.scalar("SELECT json_extract(?,'$')",[payload])
                if salt=="signed_global_ids" and db.scalar("SELECT json_extract(?,'$.purpose')",[payload])==purpose:
                    if db.scalar("SELECT CASE WHEN json_extract(?,'$.expires_at') IS NULL THEN 1 WHEN julianday(json_extract(?,'$.expires_at'))>=julianday(?) THEN 1 ELSE 0 END",[payload,payload,self.clock])=="1":
                        return db.scalar("SELECT json_extract(?,'$.gid')",[payload])
                return ""
            if db.scalar("SELECT json_extract(?,'$._rails.pur')", [payload]) != purpose:
                return ""
            if db.scalar("SELECT CASE WHEN json_extract(?,'$._rails.exp') IS NULL THEN 0 WHEN julianday(json_extract(?,'$._rails.exp')) > julianday(?) THEN 0 ELSE 1 END", [payload,payload,self.clock]) == "1":
                return ""
            if db.scalar("SELECT json_type(?,'$._rails.data')", [payload]) != "":
                return db.scalar("SELECT json_extract(?,'$._rails.data')", [payload])
            var data = unbase64(db.scalar("SELECT json_extract(?,'$._rails.message')", [payload]))
            if not sha256 and data.startswith("\x04\x08"):
                return marshal.load_string(data)
            return db.scalar("SELECT json_extract(?,'$')", [data])
        except:
            return ""

    def verify_cookie(
        mut self, mut db: Database, wire: String
    ) raises -> String:
        if wire.byte_length() > 4096:
            return ""
        try:
            var raw = decode(wire)
            var pos = raw.byte_length() - 42
            if pos <= 0 or String(raw[byte = pos : pos + 2]) != "--":
                return ""
            var encoded = String(raw[byte=:pos])
            if not secure_equal(
                self.mac("signed cookie", encoded, False),
                String(raw[byte = pos + 2 :]),
            ):
                return ""
            var payload = unbase64(encoded)
            if db.scalar("SELECT json_valid(?)", [payload]) != "1":
                return ""
            var purpose = db.scalar(
                "SELECT coalesce(json_extract(?,'$._rails.pur'),'')", [payload]
            )
            var dumped = payload
            if purpose != "" and purpose != "cookie.session_token":
                return ""
            if db.scalar("SELECT json_type(?,'$._rails')", [payload]) != "":
                var expired = db.scalar(
                    (
                        "SELECT CASE WHEN json_extract(?,'$._rails.exp') IS NOT"
                        " NULL AND (julianday(json_extract(?,'$._rails.exp'))"
                        " IS NULL OR"
                        " julianday(json_extract(?,'$._rails.exp'))<=julianday('now'))"
                        " THEN 1 ELSE 0 END"
                    ),
                    [payload, payload, payload],
                )
                if expired == "1":
                    return ""
                dumped = unbase64(
                    db.scalar(
                        "SELECT json_extract(?,'$._rails.message')", [payload]
                    )
                )
            if db.scalar("SELECT json_valid(?)", [dumped]) != "1":
                return ""
            if db.scalar("SELECT json_type(?)", [dumped]) != "text":
                return ""
            return db.scalar("SELECT json_extract(?,'$')", [dumped])
        except:
            return ""


def session_token() raises -> String:
    # has_secure_token uses 24 base58 characters; reject biased random draws.
    var alphabet = String(
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    )
    var out = List[UInt8]()
    while len(out) < 24:
        var random = List[UInt8](length=32, fill=0)
        if external_call["crypto_random", Int](random.unsafe_ptr(), 32) != 0:
            raise Error("Randomness failed")
        for b in random:
            if b < 232 and len(out) < 24:
                out.append(alphabet.as_bytes()[Int(b) % 58])
    return String(from_utf8=Span(unsafe_ptr=out.unsafe_ptr(), length=len(out)))
