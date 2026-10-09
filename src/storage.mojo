# Active Storage-compatible records, signed URLs, disk layout and image variants.
from std.ffi import external_call
from std.os import getenv
from database import Database
from crypto import Signer, base64, json_string, url_encode
from http import Request, Response, html
from parameters import Upload, Form
from runtime import read_file
from text import token, escape, params, decode


def root() -> String:
    return getenv("STORAGE_PATH","storage/files")


def relative(key: String) raises -> String:
    if key.byte_length()<4 or key.byte_length()>128:
        raise Error("Invalid storage key")
    for c in key.as_bytes():
        if not ((c>=48 and c<=57) or (c>=65 and c<=90) or (c>=97 and c<=122)):
            raise Error("Invalid storage key")
    return String(key[byte=:2])+"/"+String(key[byte=2:4])+"/"+key


def checksum(data: String) raises -> String:
    var result = List[UInt8](length=16,fill=0)
    if external_call["crypto_md5",Int](data.as_bytes().unsafe_ptr(),data.byte_length(),result.unsafe_ptr())!=16:
        raise Error("Checksum failed")
    return base64(String(unsafe_from_utf8=Span(unsafe_ptr=result.unsafe_ptr(),length=16)))


def safe_filename(var name: String) -> String:
    name = name.replace("\\","/")
    var pieces = name.split("/")
    var result = String(pieces[len(pieces)-1])
    result = result.replace("\r","_").replace("\n","_").replace('"',"_").replace("\x00","_")
    return result if result!="" else "file"


def store_bytes(mut db: Database, key: String, data: String) raises:
    var rel = relative(key)
    var directory = root()+"/"+String(rel[byte=:5])
    if external_call["fs_mkdirs",Int](directory.as_c_string_span())!=0:
        raise Error("Cannot create storage directory")
    var path = root()+"/"+rel
    if external_call["fs_write_new",Int](path.as_c_string_span(),data.as_bytes().unsafe_ptr(),data.byte_length())!=0:
        raise Error("Cannot save upload")
    db.pending_files.append(path)


def identify(data: String) -> String:
    var b = data.as_bytes()
    if len(b)>=8 and b[0]==137 and b[1]==80 and b[2]==78 and b[3]==71:
        return "image/png"
    if len(b)>=3 and b[0]==255 and b[1]==216 and b[2]==255:
        return "image/jpeg"
    if data.startswith("GIF87a") or data.startswith("GIF89a"):
        return "image/gif"
    if len(b)>=12 and data.startswith("RIFF") and String(unsafe_from_utf8=b[8:12])=="WEBP":
        return "image/webp"
    if data.startswith("%PDF-"):
        return "application/pdf"
    if len(b)>=12 and String(unsafe_from_utf8=b[4:8])=="ftyp":
        return "video/mp4"
    if data.startswith("ID3"):
        return "audio/mpeg"
    if data.startswith("OggS"):
        return "audio/ogg"
    if len(b)>=12 and data.startswith("RIFF") and String(unsafe_from_utf8=b[8:12])=="WAVE":
        return "audio/wav"
    return "application/octet-stream"


def upload(mut db: Database, file: Upload) raises -> String:
    var key = token()
    var now = db.scalar("SELECT strftime('%Y-%m-%d %H:%M:%f','now')")
    var kind = identify(file.data)
    var meta = String('{"identified":true,"analyzed":true}')
    if kind.startswith("image/"):
        var dims = List[Int](length=2,fill=0)
        if external_call["image_dimensions",Int](file.data.as_bytes().unsafe_ptr(),file.data.byte_length(),dims.unsafe_ptr())==0:
            meta = '{"identified":true,"analyzed":true,"width":'+String(dims[0])+',"height":'+String(dims[1])+'}'
    store_bytes(db,key,file.data)
    _ = db.rows("INSERT INTO active_storage_blobs(key,filename,content_type,metadata,byte_size,checksum,created_at,service_name) VALUES(?,?,?,?,?,?,?,'local')",[key,safe_filename(file.filename),kind,meta,String(file.data.byte_length()),checksum(file.data),now])
    return db.last_id()


def attach(mut db: Database, blob: String, record: String, id: String, name: String) raises:
    _ = db.rows("DELETE FROM active_storage_attachments WHERE record_type=? AND record_id=? AND name=?",[record,id,name])
    _ = db.rows("INSERT INTO active_storage_attachments(name,record_type,record_id,blob_id,created_at) VALUES(?,?,?,?,strftime('%Y-%m-%d %H:%M:%f','now'))",[name,record,id,blob])


def signed_id(mut signer: Signer, id: String) raises -> String:
    return signer.envelope("ActiveStorage",id,"blob_id")


def blob_path(mut signer: Signer, id: String, filename: String) raises -> String:
    return "/rails/active_storage/blobs/proxy/"+url_encode(signed_id(signer,id))+"/"+url_encode(safe_filename(filename))


def bytes_response(body: String, kind: String, filename: String, req: Request, force_download: Bool = False) raises -> Response:
    var extra = "Accept-Ranges: bytes\r\nContent-Disposition: "+("attachment" if force_download or kind=="application/octet-stream" else "inline")+'; filename="'+safe_filename(filename)+'"\r\n'
    var range = req.header("range")
    if range.startswith("bytes="):
        var bits = String(range[byte=6:]).split("-",maxsplit=1)
        var total = body.byte_length()
        if len(bits)!=2 or "," in range:
            return Response(416,"",kind,"Content-Range: bytes */"+String(total)+"\r\n")
        var start = Int(bits[0]) if String(bits[0])!="" else max(0,total-Int(bits[1]))
        var end = Int(bits[1]) if String(bits[1])!="" and String(bits[0])!="" else total-1
        end = min(end,total-1)
        if start<0 or start>=total or end<start:
            return Response(416,"",kind,"Content-Range: bytes */"+String(total)+"\r\n")
        return Response(206,String(unsafe_from_utf8=body.as_bytes()[start:end+1]),kind,extra+"Content-Range: bytes "+String(start)+"-"+String(end)+"/"+String(total)+"\r\n")
    return Response(200,body,kind,extra)


def download(mut db: Database, blob: String, req: Request) raises -> Response:
    var rows = db.rows("SELECT key,filename,coalesce(content_type,'application/octet-stream') FROM active_storage_blobs WHERE id=?",[blob])
    if len(rows)==0:
        return html("File not found",404)
    var row = rows[0].copy()
    var body = read_file(root(),relative(row[0]),134217728)
    var kind = row[2]
    if kind=="text/html" or kind=="image/svg+xml" or kind.endswith("xml"):
        kind = "application/octet-stream"
    return bytes_response(body,kind,row[1],req,params(req.query).get("disposition","")=="attachment")


def image(mut db: Database, blob: String, req: Request, width: Int, height: Int, crop: Bool = False) raises -> Response:
    var row = db.rows("SELECT key,filename,content_type FROM active_storage_blobs WHERE id=?",[blob])
    if len(row)==0:
        return html("Image not found",404)
    var source = read_file(root(),relative(row[0][0]))
    if not identify(source).startswith("image/"):
        return html("Not a supported image",422)
    var address = 0
    var size = 0
    if external_call["image_thumbnail",Int](source.as_bytes().unsafe_ptr(),source.byte_length(),width,height,Int(crop),Pointer(to=address),Pointer(to=size))!=0:
        return html("Cannot decode image",422)
    var output = Pointer[UInt8,MutUntrackedOrigin](unsafe_from_address=address)
    var body = String(unsafe_from_utf8=Span(unsafe_ptr=output,length=size))
    external_call["buffer_free",NoneType](output)
    return bytes_response(body,"image/webp",safe_filename(row[0][1])+".webp",req)


def presentation(mut db: Database, mut signer: Signer, mid: String) raises -> String:
    var rows = db.rows("SELECT b.id,b.filename,b.content_type,b.byte_size FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id WHERE a.record_type='Message' AND a.record_id=? AND a.name='attachment' LIMIT 1",[mid])
    if len(rows)==0:
        return ""
    var b = rows[0].copy()
    var url = blob_path(signer,b[0],b[1])
    if b[2].startswith("image/") and b[2]!="image/svg+xml":
        return '<figure class="attachment attachment--preview"><a href="'+escape(url)+'"><img src="'+escape(url)+'" alt="'+escape(b[1])+'" loading="lazy" style="max-width:100%;max-height:800px"></a><figcaption>'+escape(b[1])+'</figcaption></figure>'
    if b[2].startswith("video/"):
        return '<video controls preload="metadata" src="'+escape(url)+'"></video><a href="'+escape(url)+'">'+escape(b[1])+'</a>'
    if b[2].startswith("audio/"):
        return '<audio controls src="'+escape(url)+'"></audio><a href="'+escape(url)+'">'+escape(b[1])+'</a>'
    return '<figure class="attachment"><a download href="'+escape(url)+'">'+escape(b[1])+'</a><figcaption>'+b[3]+' bytes</figcaption></figure>'


def route(mut db: Database, mut signer: Signer, req: Request, uid: String, f: Form) raises -> Response:
    var parts = req.path.split("/")
    if req.path=="/rails/active_storage/direct_uploads":
        if uid=="":
            return html("Unauthorized",401)
        if req.method!="POST":
            return html("Not found",404)
        var size = f.fields.get("blob[byte_size]","")
        if size=="" or Int(size)<0 or Int(size)>67108864:
            return html("Invalid upload size",422)
        var key = token()
        var name = safe_filename(f.fields.get("blob[filename]","file"))
        var kind = f.fields.get("blob[content_type]","application/octet-stream")
        var sum = f.fields.get("blob[checksum]","")
        if sum.byte_length()!=24:
            return html("Invalid checksum",422)
        _ = db.rows("INSERT INTO active_storage_blobs(key,filename,content_type,metadata,byte_size,checksum,created_at,service_name) VALUES(?,?,?,'{}',?,?,strftime('%Y-%m-%d %H:%M:%f','now'),'local')",[key,name,kind,size,sum])
        var id = db.last_id()
        var expiry = db.scalar("SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now','+5 minutes')")
        var data = '{"key":'+json_string(key)+',"content_type":'+json_string(kind)+',"content_length":'+size+',"checksum":'+json_string(sum)+',"service_name":"local"}'
        var upload_url = req.origin()+"/rails/active_storage/disk/"+url_encode(signer.envelope("ActiveStorage",data,"blob_token",expiry))
        return Response(200,'{"id":'+id+',"key":'+json_string(key)+',"filename":'+json_string(name)+',"content_type":'+json_string(kind)+',"byte_size":'+size+',"checksum":'+json_string(sum)+',"signed_id":'+json_string(signed_id(signer,id))+',"direct_upload":{"url":'+json_string(upload_url)+',"headers":{"Content-Type":'+json_string(kind)+',"Content-MD5":'+json_string(sum)+'}}}',"application/json","")
    if len(parts)>=6 and String(parts[1])=="rails" and String(parts[2])=="active_storage" and String(parts[3])=="blobs":
        var id = signer.verify(db,"ActiveStorage",decode(String(parts[5])),"blob_id",False)
        if id=="":
            return html("File not found",404)
        return download(db,id,req)
    if len(parts)>=5 and String(parts[3])=="disk":
        var token = decode(String(parts[4]))
        var purpose = "blob_token" if req.method=="PUT" else "blob_key"
        var data = signer.verify(db,"ActiveStorage",token,purpose,False)
        if data=="":
            return html("Not found",404)
        var key = db.scalar("SELECT json_extract(?,'$.key')",[data])
        if db.scalar("SELECT json_extract(?,'$.service_name')",[data])!="local":
            return html("Invalid service",404)
        if req.method=="PUT":
            if uid=="":
                return html("Unauthorized",401)
            var length = db.scalar("SELECT json_extract(?,'$.content_length')",[data])
            var expected = db.scalar("SELECT json_extract(?,'$.checksum')",[data])
            if String(req.body.byte_length())!=length or checksum(req.body)!=expected:
                return html("Upload checksum mismatch",422)
            store_bytes(db,key,req.body)
            return html("",204)
        var blob = db.scalar("SELECT id FROM active_storage_blobs WHERE key=?",[key])
        return download(db,blob,req)
    return html("",0)


def rollback(mut db: Database):
    for file in db.pending_files:
        var name = file.copy()
        _ = external_call["fs_unlink",Int](name.as_c_string_span())
    db.pending_files.clear()


def profile_upload(mut db: Database, f: Form, id: String, account: Bool = False) raises:
    var name = "account[logo]" if account else "user[avatar]"
    if name in f.files:
        var file = f.files[name].copy()
        if not identify(file.data).startswith("image/"):
            raise Error("Upload must be an image")
        var dims = List[Int](length=2,fill=0)
        if external_call["image_dimensions",Int](file.data.as_bytes().unsafe_ptr(),file.data.byte_length(),dims.unsafe_ptr())!=0:
            raise Error("Invalid image")
        var blob = upload(db,file)
        attach(db,blob,"Account" if account else "User",id,"logo" if account else "avatar")
