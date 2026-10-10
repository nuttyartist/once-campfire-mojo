from byte_buffer import Bytes

# Data-only Ruby Marshal 4.8 encoder for Active Storage variant digests.
# It never deserializes Ruby objects or runs Ruby code.
from database import Database


def octet(value: Int) -> Bytes:
    var b = UInt8(value & 255)
    return Bytes([b])


def long(var n: Int) raises -> Bytes:
    if n == 0:
        return "\x00"
    if n > 0 and n < 123:
        return octet(n + 5)
    if n < 0 and n > -124:
        return octet(n - 5)
    var bytes = Bytes()
    for _ in range(8):
        bytes += octet(n)
        n >>= 8
        if n == 0 or n == -1:
            return (
                octet(bytes.byte_length() if n == 0 else -bytes.byte_length())
                + bytes
            )
    raise Error("Marshal integer out of range")


def symbol(name: String, mut symbols: List[String]) raises -> Bytes:
    for i in range(len(symbols)):
        if symbols[i] == name:
            return ";" + long(i)
    symbols.append(name)
    return ":" + long(name.byte_length()) + name


def encode(
    mut db: Database,
    json: String,
    mut symbols: List[String],
    symbol_strings: Bool,
    depth: Int = 0,
) raises -> Bytes:
    if depth > 32:
        raise Error("Variation nesting too deep")
    var row = db.rows("SELECT json_type(?),json_extract(?,'$')", [json, json])[
        0
    ].copy()
    var kind = row[0]
    if kind == "null":
        return "0"
    if kind == "true":
        return "T"
    if kind == "false":
        return "F"
    if kind == "integer":
        var n = Int(row[1])
        if n >= -1073741824 and n < 1073741824:
            return "i" + long(n)
        var bytes = Bytes()
        var magnitude = UInt64(-(n + 1)) + 1 if n < 0 else UInt64(n)
        while magnitude > 0:
            bytes += octet(Int(magnitude & 255))
            magnitude >>= 8
        if bytes.byte_length() % 2:
            bytes += "\x00"
        return (
            "l"
            + ("-" if n < 0 else "+")
            + long(bytes.byte_length() // 2)
            + bytes
        )
    if kind == "text":
        if symbol_strings:
            return symbol(row[1], symbols)
        return (
            'I"'
            + long(row[1].byte_length())
            + row[1]
            + long(1)
            + symbol("E", symbols)
            + "T"
        )
    if kind != "array" and kind != "object":
        raise Error("Unsupported variation value")
    var values = db.rows(
        "SELECT key,CASE WHEN type='text' THEN json_quote(value) WHEN type='null' THEN 'null' WHEN type='true' THEN 'true' WHEN type='false' THEN 'false' ELSE value END FROM json_each(?)",
        [json],
    )
    var out = ("[" if kind == "array" else "{") + long(len(values))
    for item in values:
        if kind == "object":
            out += symbol(item[0], symbols)
        out += encode(db, item[1], symbols, symbol_strings, depth + 1)
    return out^


def dump(
    mut db: Database, json: String, symbol_strings: Bool = False
) raises -> Bytes:
    var symbols = List[String]()
    return "\x04\x08" + encode(db, json, symbols, symbol_strings)


def load_string(data: Bytes) raises -> String:
    # Rails 7 GlobalIDs used a Marshal String. Never instantiate a Ruby object.
    var bytes = data.as_bytes()
    if len(bytes) < 4 or bytes[0] != 4 or bytes[1] != 8:
        raise Error("Invalid legacy string")
    var at = 2
    if bytes[at] == 73:
        at += 1
    if at >= len(bytes) or bytes[at] != 34:
        raise Error("Legacy object is not a string")
    at += 1
    if at >= len(bytes):
        raise Error("Truncated legacy string")
    var first = Int(bytes[at])
    at += 1
    var size = first - 5 if first >= 5 and first <= 127 else 0
    if first >= 1 and first <= 4:
        if at + first > len(bytes):
            raise Error("Truncated legacy length")
        for i in range(first):
            size |= Int(bytes[at + i]) << (8 * i)
        at += first
    elif first > 127:
        raise Error("Negative legacy string length")
    if size < 0 or size > len(bytes) - at:
        raise Error("Truncated legacy string data")
    return String(from_utf8=bytes[at : at + size])
