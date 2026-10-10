from byte_buffer import Bytes
from database import Database
from http import Request
from text import params, decode
from body_stream import read_slice


struct Upload(Copyable, Movable):
    var filename: String
    var content_type: String
    var data: Bytes
    var fd: Int
    var offset: Int
    var size: Int
    var prepared_key: String

    def __init__(out self, filename: String, content_type: String, data: Bytes, fd: Int = -1, offset: Int = 0, size: Int = 0):
        self.prepared_key = ""
        self.filename = filename
        self.content_type = content_type
        self.data = data
        self.fd = fd
        self.offset = offset
        self.size = size if fd>=0 else data.byte_length()


struct Form(Copyable, Movable):
    var fields: Dict[String, String]
    var files: Dict[String, Upload]
    # Server-only preflight results; request field names cannot set these.
    var password_digest: String
    var endpoint_validated: Bool
    var direct_info: List[String]

    def __init__(out self):
        self.fields = Dict[String,String]()
        self.files = Dict[String,Upload]()
        self.password_digest = ""
        self.endpoint_validated = False
        self.direct_info = List[String]()


def disposition(value: String, key: String) -> String:
    for item in value.split(";"):
        var pair = item.strip().split("=",maxsplit=1)
        if len(pair)==2 and String(pair[0])==key:
            var result = String(pair[1])
            if result.byte_length()>=2 and result.startswith('"') and result.endswith('"'):
                return String(result[byte=1:result.byte_length()-1])
            return result
    return ""


def parse(mut db: Database, req: Request) raises -> Form:
    var form = Form()
    var kind = req.header("content-type")
    if kind.startswith("multipart/form-data") and req.body_fd>=0:
        form = parse_spooled(req)
    elif kind.startswith("multipart/form-data"):
        var boundary = disposition(kind,"boundary")
        if boundary == "" or boundary.byte_length()>70 or "\r" in boundary or "\n" in boundary:
            raise Error("HTTP 400: Invalid multipart boundary")
        var delimiter = "--"+boundary
        var parts = req.body.split(delimiter)
        if len(parts)>128:
            raise Error("HTTP 400: Too many multipart fields")
        for i in range(1,len(parts)-1):
            var part = parts[i].copy()
            if not part.startswith("\r\n") or not part.endswith("\r\n"):
                raise Error("HTTP 400: Malformed multipart body")
            var end = part.find("\r\n\r\n")
            if end<0 or end>16384:
                raise Error("HTTP 400: Malformed multipart headers")
            var head = part.slice(2,end).text()
            var body = Bytes(part.as_bytes()[end+4:part.byte_length()-2])
            var name = String()
            var filename = String()
            var content_type = String("application/octet-stream")
            for line in head.split("\r\n"):
                var bits = line.split(":",maxsplit=1)
                if len(bits)!=2:
                    raise Error("HTTP 400: Invalid multipart header")
                if String(bits[0]).lower()=="content-disposition":
                    name = disposition(String(bits[1]),"name")
                    filename = disposition(String(bits[1]),"filename")
                elif String(bits[0]).lower()=="content-type":
                    content_type = String(bits[1].strip())
            if name == "":
                raise Error("HTTP 400: Missing multipart field name")
            if filename != "":
                form.files[name] = Upload(filename,content_type,body)
            elif name.endswith("[]"):
                form.fields[name] = form.fields.get(name,"")+","+body.text()
            else:
                form.fields[name] = body.text()
    elif kind.startswith("application/json"):
        if db.scalar("SELECT json_valid(?)",[req.body.text()])!="1" or db.scalar("SELECT json_type(?)",[req.body.text()])!="object":
            raise Error("HTTP 400: Invalid JSON object")
        var rows = db.rows("SELECT id,coalesce(parent,-1),coalesce(key,''),coalesce(cast(atom AS TEXT),''),type FROM json_tree(?) ORDER BY id",[req.body.text()])
        var paths = Dict[String,String]()
        for row in rows:
            var parent = paths.get(row[1],"")
            var key = row[2] if parent=="" else parent+"["+row[2]+"]"
            paths[row[0]] = key
            if row[4]!="object" and row[4]!="array" and row[4]!="null":
                form.fields[key] = row[3]
    elif kind.startswith("application/x-www-form-urlencoded") or req.body == "":
        form.fields = params(req.body.text())
        var ids = String()
        for pair in req.body.text().split("&"):
            var bits = pair.split("=",maxsplit=1)
            if len(bits)==2 and decode(String(bits[0]))=="user_ids[]":
                ids += ","+decode(String(bits[1]))
        if ids != "":
            form.fields["user_ids[]"] = ids
    else:
        raise Error("HTTP 400: Unsupported content type")
    for value in form.fields.values():
        try:
            _ = String(from_utf8=value.as_bytes())
        except:
            raise Error("HTTP 400: Invalid UTF-8 text field")
        if "\x00" in value:
            raise Error("HTTP 400: NUL is not valid in text fields")
    return form^


# A boundary is syntax only at a line start with a valid suffix. Arbitrary binary
# uploads may contain the boundary text; matching it alone would corrupt files.
def next_boundary(fd: Int, offset: Int, size: Int, boundary: String) raises -> Int:
    var needle = "\r\n--"+boundary
    var cursor = offset
    var carry = Bytes()
    while cursor<size:
        var data = carry+read_slice(fd,cursor,min(65536,size-cursor))
        var base = cursor-carry.byte_length()
        cursor += data.byte_length()-carry.byte_length()
        var search = 0
        while search<data.byte_length():
            var rest = Bytes(data.as_bytes()[search:])
            var at = rest.find(needle)
            if at<0:
                break
            at += search
            if at+needle.byte_length()+2<=data.byte_length():
                var suffix = Bytes(data.as_bytes()[at+needle.byte_length():at+needle.byte_length()+2])
                if suffix=="--" or suffix=="\r\n":
                    return base+at
            search = at+1
        var keep = min(data.byte_length(),needle.byte_length()+2)
        carry = Bytes(data.as_bytes()[data.byte_length()-keep:])
    raise Error("HTTP 400: Missing multipart boundary")


def parse_spooled(req: Request) raises -> Form:
    var boundary = disposition(req.header("content-type"),"boundary")
    if boundary=="" or boundary.byte_length()>70 or "\r" in boundary or "\n" in boundary:
        raise Error("HTTP 400: Invalid multipart boundary")
    var first = "--"+boundary
    if req.body_size<first.byte_length()+2 or read_slice(req.body_fd,0,first.byte_length())!=first:
        raise Error("HTTP 400: Invalid multipart preamble")
    var cursor = first.byte_length()
    var form = Form()
    var fields = 0
    var files = 0
    var text_size = 0
    while cursor+2<=req.body_size:
        var suffix = read_slice(req.body_fd,cursor,2)
        if suffix=="--":
            return form^
        if suffix!="\r\n":
            raise Error("HTTP 400: Invalid multipart delimiter")
        cursor += 2
        var headers = read_slice(req.body_fd,cursor,min(16388,req.body_size-cursor))
        var end = headers.find("\r\n\r\n")
        if end<0 or end>16384:
            raise Error("HTTP 400: Invalid multipart headers")
        var name = String()
        var filename = String()
        var kind = String("application/octet-stream")
        for line in headers.slice(0,end).text().split("\r\n"):
            var pair = line.split(":",maxsplit=1)
            if len(pair)!=2:
                raise Error("HTTP 400: Invalid multipart header")
            var header = String(pair[0]).lower()
            if header=="content-disposition":
                name = disposition(String(pair[1]),"name")
                filename = disposition(String(pair[1]),"filename")
            elif header=="content-type":
                kind = String(pair[1].strip())
        if name=="":
            raise Error("HTTP 400: Missing multipart field name")
        cursor += end+4
        var finish = next_boundary(req.body_fd,cursor,req.body_size,boundary)
        var length = finish-cursor
        fields += 1
        if fields>4096:
            raise Error("HTTP 400: Too many multipart fields")
        if filename!="":
            files += 1
            if files>128:
                raise Error("HTTP 400: Too many multipart files")
            form.files[name] = Upload(filename,kind,"",req.body_fd,cursor,length)
        else:
            text_size += length
            if text_size>16777216:
                raise Error("HTTP 400: Multipart text too large")
            var value = read_slice(req.body_fd,cursor,length).text()
            form.fields[name] = form.fields.get(name,"")+","+value if name.endswith("[]") else value
        cursor = finish+4+boundary.byte_length()
    raise Error("HTTP 400: Incomplete multipart body")
