import native_boundary as native
from byte_buffer import Bytes
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


def base64(s: Bytes, url: Bool = False, padding: Bool = True) raises -> String:
    var buf = List[UInt8](length=(s.byte_length() + 2) // 3 * 4 + 1, fill=0)
    var n = native.base64_encode(s.as_bytes(), s.byte_length(), buf)
    if n < 0:
        raise Error("Base64 encoding failed")
    var out = String(from_utf8=Span(buf)[:n])
    if url:
        out = out.replace("+", "-").replace("/", "_")
    if not padding:
        out = out.replace("=", "")
    return out^


def unbase64(var s: String) raises -> Bytes:
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
    var n = native.base64_decode(s.as_bytes(), s.byte_length(), buf)
    if n < 0:
        raise Error("Invalid base64")
    return Bytes(Span(buf)[:n])


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
            out += String(chr(Int(c)))
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
        native.crypto_equal(a, b)
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
                native.crypto_derive(self.secret, salt, buf)
                != 0
            ):
                raise Error("PBKDF2 failed")
            self.keys[salt] = native.terminated(buf)
        return self.keys[salt]

    def mac(
        mut self, salt: String, data: String, sha256: Bool
    ) raises -> String:
        var key = self.key(salt)
        var buf = List[UInt8](length=65, fill=0)
        if (
            native.crypto_hmac(key, data.as_bytes(), data.byte_length(), Int(sha256), buf)
            != 0
        ):
            raise Error("HMAC failed")
        return native.terminated(buf)

    def sign(
        mut self,
        salt: String,
        payload: Bytes,
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

    def encrypted_cookie(mut self, data: String, expiry: String, name: String = "_campfire_session") raises -> String:
        var payload = '{"_rails":{"message":'+json_string(base64(data))+',"exp":'+json_string(expiry)+',"pur":'+json_string("cookie."+name)+'}}'
        if payload.byte_length()>2800:
            raise Error("HTTP 422: Session cookie exceeds browser limit")
        var key = self.key("authenticated encrypted cookie")
        var nonce = List[UInt8](length=12,fill=0)
        if native.crypto_random(nonce, 12)!=0:
            raise Error("Cookie random generator failed")
        var result = native.cookie_encrypt(key,Bytes(Span(nonce)),payload)
        return url_encode(base64(result[0])+"--"+base64(Bytes(Span(nonce)))+"--"+base64(result[1]))

    def decrypt_cookie(mut self, mut db: Database, wire: String, name: String = "_campfire_session") raises -> String:
        if wire=="" or wire.byte_length()>8192:
            return ""
        try:
            var parts = decode(wire).split("--")
            if len(parts)!=3:
                return ""
            var body = unbase64(String(parts[0]))
            var nonce = unbase64(String(parts[1]))
            var tag = unbase64(String(parts[2]))
            if nonce.byte_length()!=12 or tag.byte_length()!=16:
                return ""
            var key = self.key("authenticated encrypted cookie")
            var data = native.cookie_decrypt(key,nonce,body,tag).text()
            if db.scalar("SELECT json_valid(?)",[data])!="1":
                return ""
            if db.scalar("SELECT json_type(?,'$._rails')",[data])!="":
                if db.scalar("SELECT coalesce(json_extract(?,'$._rails.pur'),'')",[data])!="cookie."+name:
                    return ""
                if db.scalar("SELECT CASE WHEN json_extract(?,'$._rails.exp') IS NULL THEN 1 WHEN julianday(json_extract(?,'$._rails.exp'))>julianday(?) THEN 1 ELSE 0 END",[data,data,self.clock])!="1":
                    return ""
                data = unbase64(db.scalar("SELECT json_extract(?,'$._rails.message')",[data])).text()
            if db.scalar("SELECT json_valid(?)",[data])!="1":
                return ""
            return data^
        except:
            return ""

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
            for byte in wire.as_bytes():
                if byte>=128 or byte==0:
                    return ""
            var offset = wire.byte_length() - (66 if sha256 else 42)
            if offset <= 0 or String(wire[byte=offset:offset+2]) != "--":
                if sha256 and salt=="active_record/signed_id":
                    return self.verify(db,salt,wire,purpose,False)
                return ""
            var encoded = String(wire[byte=:offset])
            if not secure_equal(self.mac(salt, encoded, sha256), String(wire[byte=offset+2:])):
                return ""
            var payload = unbase64(encoded).text()
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
            return db.scalar("SELECT json_extract(?,'$')", [data.text()])
        except:
            return ""

    def verify_cookie(
        mut self, mut db: Database, wire: String
    ) raises -> String:
        if wire.byte_length() > 4096:
            return ""
        try:
            var raw = decode(wire)
            for byte in raw.as_bytes():
                if byte>=128 or byte==0:
                    return ""
            var pos = raw.byte_length() - 42
            if pos <= 0 or String(raw[byte = pos : pos + 2]) != "--":
                return ""
            var encoded = String(raw[byte=:pos])
            if not secure_equal(
                self.mac("signed cookie", encoded, False),
                String(raw[byte = pos + 2 :]),
            ):
                return ""
            var payload = unbase64(encoded).text()
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
                ).text()
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
        if native.crypto_random(random, 32) != 0:
            raise Error("Randomness failed")
        for b in random:
            if b < 232 and len(out) < 24:
                out.append(alphabet.as_bytes()[Int(b) % 58])
    return String(from_utf8=Span(out)[:len(out)])
