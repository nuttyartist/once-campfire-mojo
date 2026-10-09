from database import Database
from http import Request
from text import params, decode


@fieldwise_init
struct Upload(Copyable, Movable):
    var filename: String
    var content_type: String
    var data: String


struct Form(Copyable, Movable):
    var fields: Dict[String, String]
    var files: Dict[String, Upload]

    def __init__(out self):
        self.fields = Dict[String,String]()
        self.files = Dict[String,Upload]()


def disposition(value: String, key: String) -> String:
    for item in value.split(";"):
        var pair = item.strip().split("=",maxsplit=1)
        if len(pair)==2 and String(pair[0])==key:
            var result = String(pair[1])
            if result.startswith('"') and result.endswith('"'):
                return String(result[byte=1:result.byte_length()-1])
            return result
    return ""


def parse(mut db: Database, req: Request) raises -> Form:
    var form = Form()
    var kind = req.header("content-type")
    if kind.startswith("multipart/form-data"):
        var boundary = disposition(kind,"boundary")
        if boundary == "" or boundary.byte_length()>70 or "\r" in boundary or "\n" in boundary:
            raise Error("Invalid multipart boundary")
        var delimiter = "--"+boundary
        var parts = req.body.split(delimiter)
        if len(parts)>128:
            raise Error("Too many multipart fields")
        for i in range(1,len(parts)-1):
            var part = String(parts[i])
            if not part.startswith("\r\n") or not part.endswith("\r\n"):
                raise Error("Malformed multipart body")
            var end = part.find("\r\n\r\n")
            if end<0 or end>16384:
                raise Error("Malformed multipart headers")
            var head = String(part[byte=2:end])
            var body = String(unsafe_from_utf8=part.as_bytes()[end+4:part.byte_length()-2])
            var name = String()
            var filename = String()
            var content_type = String("application/octet-stream")
            for line in head.split("\r\n"):
                var bits = line.split(":",maxsplit=1)
                if len(bits)!=2:
                    raise Error("Invalid multipart header")
                if String(bits[0]).lower()=="content-disposition":
                    name = disposition(String(bits[1]),"name")
                    filename = disposition(String(bits[1]),"filename")
                elif String(bits[0]).lower()=="content-type":
                    content_type = String(bits[1].strip())
            if name == "":
                raise Error("Missing multipart field name")
            if filename != "":
                form.files[name] = Upload(filename,content_type,body)
            elif name.endswith("[]"):
                form.fields[name] = form.fields.get(name,"")+","+body
            else:
                form.fields[name] = body
    elif kind.startswith("application/json"):
        if db.scalar("SELECT json_valid(?)",[req.body])!="1" or db.scalar("SELECT json_type(?)",[req.body])!="object":
            raise Error("Invalid JSON object")
        var rows = db.rows("SELECT id,coalesce(parent,-1),coalesce(key,''),coalesce(cast(atom AS TEXT),''),type FROM json_tree(?) ORDER BY id",[req.body])
        var paths = Dict[String,String]()
        for row in rows:
            var parent = paths.get(row[1],"")
            var key = row[2] if parent=="" else parent+"["+row[2]+"]"
            paths[row[0]] = key
            if row[4]!="object" and row[4]!="array" and row[4]!="null":
                form.fields[key] = row[3]
    elif kind.startswith("application/x-www-form-urlencoded") or req.body == "":
        form.fields = params(req.body)
        var ids = String()
        for pair in req.body.split("&"):
            var bits = pair.split("=",maxsplit=1)
            if len(bits)==2 and decode(String(bits[0]))=="user_ids[]":
                ids += ","+decode(String(bits[1]))
        if ids != "":
            form.fields["user_ids[]"] = ids
    else:
        raise Error("Unsupported content type")
    for value in form.fields.values():
        _ = String(from_utf8=value.as_bytes())
        if "\x00" in value:
            raise Error("NUL is not valid in text fields")
    return form^
