# Binary/text and native-contract regressions. Expected wire encodings are also
# checked independently by Python (gzip, SHA-256, Marshal and base64).
from byte_buffer import Bytes
from crypto import base64, unbase64, secure_equal, Signer
from database import Database
from http import Response, chunked
from body_stream import BodyStream, read_slice
from runtime import digest
from webpush import expand, random_bytes
from parameters import disposition
import native_boundary as native
import cable
import marshal


def require(value: Bool, message: String) raises:
    if not value:
        raise Error(message)


def main() raises:
    var all = List[UInt8]()
    for i in range(256):
        all.append(UInt8(i))
    var binary = Bytes(all^)
    require(unbase64(base64(binary))==binary,"base64 must preserve every byte")
    var copy = binary.copy()
    copy.data[0] = 7
    require(binary.as_bytes()[0]==0,"byte copies must own their storage")
    require(("prefix"+binary+"suffix").slice(6,262)==binary,"binary concatenation")
    for invalid in [Bytes([255]),Bytes([192,128]),Bytes([237,160,128]),Bytes([244,144,128,128]),Bytes([226,130])]:
        var rejected = False
        try:
            _ = invalid.text()
        except:
            rejected = True
        require(rejected,"invalid UTF-8 must be rejected")
    for begin in [-1,257]:
        var rejected = False
        try:
            _ = binary.slice(begin)
        except:
            rejected = True
        require(rejected,"byte slice bounds")
    require(Bytes("שלום 🔥 café").text()=="שלום 🔥 café","valid Unicode roundtrip")
    require(disposition("filename=\"","filename")=="\"","single quote must not create a reversed slice")
    var framed = cable.frame(binary)
    require(framed.as_bytes()[0]==129 and framed.as_bytes()[1]==126 and framed.slice(4)==binary,"binary WebSocket frame")
    var wire = "100\r\n"+binary+"\r\n0\r\n\r\n"
    var decoded = chunked(wire)
    require(decoded[0]==binary and decoded[1]==len(wire),"binary chunk decoder")
    var spool = BodyStream()
    # Feed partial headers and delimiters exactly as a socket might split them.
    var pending = Bytes()
    var complete = False
    for byte in wire.as_bytes():
        pending += Bytes([byte])
        var consumed = spool.feed(pending,0,True)
        pending = pending.slice(consumed[0])
        complete = consumed[1]
    require(complete and read_slice(spool.fd,0,spool.size)==binary,"incremental binary upload")
    spool.close()
    var short = List[UInt8](length=1,fill=173)
    var private = List[UInt8](length=32,fill=1)
    var invalid_key = Bytes([1])
    require(native.p256_public(invalid_key.as_bytes(),short)==-1,"P256 input/output capacity")
    require(native.p256_public(Span(private),short)==-1,"P256 output capacity")
    require(native.crypto_hash(binary.as_bytes(),257,1,short)==-1,"hash length/capacity")
    require(native.base64_encode(binary.as_bytes(),256,short)==-1,"base64 output capacity")
    require(native.fs_read(-1,short,1,0,2)==-1,"file buffer offset")
    require(short[0]==173,"rejected native calls must not modify buffers")
    var qr = List[UInt8](length=3918,fill=255)
    require(native.qr_module(Span(qr),200,200)==0,"forged QR dimensions")
    require(not secure_equal("valid\x00evil","valid"),"NUL must not truncate secure comparison")
    var rejected = False
    try:
        _ = expand(binary,binary,33)
    except:
        rejected = True
    require(rejected,"HKDF bounds")
    rejected = False
    try:
        _ = random_bytes(-1)
    except:
        rejected = True
    require(rejected,"random allocation bounds")
    var db = Database(":memory:")
    var signer = Signer("byte-safety-test-key-00000000000000000000000000")
    # Offsets formerly landed in the middle of a multibyte code point.
    for suffix in [40,41,42,64,65,66]:
        var wire = "é"+String("a"*suffix)
        require(signer.verify(db,"active_record/signed_id",wire)=="","malformed UTF-8 signature boundary")
        require(signer.verify_cookie(db,wire)=="","malformed cookie boundary")
    rejected = False
    try:
        _ = db.rows("SELECT CAST(x'ff' AS TEXT)")
    except:
        rejected = True
    require(rejected,"SQL text decoding must validate UTF-8")
    require(db.scalar("SELECT 42")=="42","SQL connection remains usable after decode error")
    var html = String("<div><span data-test='yes'>hello</span></div>")
    var doc = native.dom_parse_fragment(html.as_bytes(),html.byte_length())
    var root = native.dom_root(doc)
    var child = native.dom_child(root)
    require(child!=0,"DOM test child")
    native.dom_clear_node(root)
    require(native.dom_type(child)==0,"stale child handle")
    native.dom_free(doc)
    native.dom_free(doc)
    require(native.dom_type(root)==0 and native.dom_name(root)=="","stale document handles")
    require(native.dom_type(9223372036854775807)==0,"forged DOM handle")
    print("binary",base64(binary))
    print("digest",base64(digest(binary)))
    print("frame",base64(framed))
    print("gzip",base64(Response(200,binary,"text/plain","").pack(True)))
    print("marshal_min",base64(marshal.dump(db,"-9223372036854775808")))
    print("marshal_utf8",base64(marshal.dump(db,"\"שלום 🔥\"")))
    print("PASS: byte ownership, UTF-8, framing, streaming, crypto bounds, SQL recovery, DOM lifetime")
