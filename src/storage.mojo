import native_boundary as native
from byte_buffer import Bytes
# Active Storage-compatible records, signed URLs, disk layout and image variants.
from std.os import getenv
from database import Database
from crypto import Signer, base64, json_string, url_encode
from http import Request, Response, html, validator
from parameters import Upload, Form
from body_stream import read_slice
from runtime import read_file, digest
import media
import templates
import marshal
from file_transfer import FileTransfer, Segment
from text import token, escape, params, decode


def root() -> String:
    return getenv("STORAGE_PATH","storage/files")


def relative(key: String) raises -> String:
    if key.byte_length()<4 or key.byte_length()>128:
        raise Error("Invalid storage key")
    for c in key.as_bytes():
        if not ((c>=48 and c<=57) or (c>=65 and c<=90) or (c>=97 and c<=122) or c==45 or c==95):
            raise Error("Invalid storage key")
    return String(key[byte=:2])+"/"+String(key[byte=2:4])+"/"+key


def checksum(data: Bytes) raises -> String:
    var result = List[UInt8](length=16,fill=0)
    if native.crypto_md5(data.as_bytes(), data.byte_length(), result)!=16:
        raise Error("Checksum failed")
    return base64(Bytes(Span(result)[:16]))


def safe_filename(var name: String) -> String:
    name = name.replace("\\","/")
    var pieces = name.split("/")
    var result = String(pieces[len(pieces)-1])
    result = result.replace("\r","_").replace("\n","_").replace('"',"_").replace("\x00","_")
    return result if result!="" else "file"


def store_bytes(mut db: Database, key: String, data: Bytes) raises:
    var rel = relative(key)
    var directory = root()+"/"+String(rel[byte=:5])
    if native.fs_mkdirs(directory)!=0:
        raise Error("Cannot create storage directory")
    var path = root()+"/"+rel
    if native.fs_write_new(path, data.as_bytes(), data.byte_length())!=0:
        raise Error("Cannot save upload")
    db.pending_files.append(path)


def identify(data: Bytes) raises -> String:
    var detected = List[UInt8](length=256,fill=0)
    var n = native.mime_detect(data.as_bytes(), data.byte_length(), detected, len(detected))
    if n>0:
        var kind = String(from_utf8=Span(detected)[:n])
        if kind!="application/octet-stream":
            return kind
    var b = data.as_bytes()
    if len(b)>=8 and b[0]==137 and b[1]==80 and b[2]==78 and b[3]==71:
        return "image/png"
    if len(b)>=3 and b[0]==255 and b[1]==216 and b[2]==255:
        return "image/jpeg"
    if data.startswith("GIF87a") or data.startswith("GIF89a"):
        return "image/gif"
    if len(b)>=12 and data.startswith("RIFF") and Bytes(b[8:12])=="WEBP":
        return "image/webp"
    if data.startswith("%PDF-"):
        return "application/pdf"
    if len(b)>=12 and Bytes(b[4:8])=="ftyp":
        return "video/mp4"
    if data.startswith("ID3"):
        return "audio/mpeg"
    if len(b)>=4 and b[0]==26 and b[1]==69 and b[2]==223 and b[3]==163:
        return "video/webm"
    if len(b)>=2 and b[0]==255 and (Int(b[1])&224)==224:
        return "audio/mpeg"
    if data.startswith("BM"):
        return "image/bmp"
    if data.startswith("OggS"):
        return "audio/ogg"
    if len(b)>=12 and data.startswith("RIFF") and Bytes(b[8:12])=="WAVE":
        return "audio/wav"
    return "application/octet-stream"


def metadata(mut db: Database, data: Bytes, kind: String) raises -> String:
    var meta = String('{"identified":true,"analyzed":true}')
    if kind.startswith("image/") or kind=="application/pdf":
        var dims = List[Int](length=2,fill=0)
        if native.image_dimensions(data.as_bytes(), data.byte_length(), dims)==0:
            meta = '{"identified":true,"analyzed":true,"width":'+String(dims[0])+',"height":'+String(dims[1])+'}'
    elif kind.startswith("video/") or kind.startswith("audio/"):
        try:
            meta = media.metadata(db,data,kind)
        except:
            pass
    return meta^


def blob_info(mut db: Database, blob: String) raises -> List[String]:
    if blob.startswith("prepared:"):
        return db.prepared_blobs[String(blob[byte=9:])].copy()
    var rows = db.rows("SELECT key,filename,content_type,metadata,byte_size,checksum FROM active_storage_blobs WHERE id=?",[blob])
    if len(rows)==0:
        raise Error("Missing stored object")
    return rows[0].copy()


def persist_prepared(mut db: Database, key: String) raises -> String:
    if db.preparing_media:
        return "prepared:"+key
    var existing = db.scalar("SELECT id FROM active_storage_blobs WHERE key=?",[key])
    if existing!="":
        return existing
    var row = db.prepared_blobs[key].copy()
    _ = db.rows("INSERT INTO active_storage_blobs(key,filename,content_type,metadata,byte_size,checksum,created_at,service_name) VALUES(?,?,?,?,?,?,strftime('%Y-%m-%d %H:%M:%f','now'),'local')",row)
    return db.last_id()


def upload(mut db: Database, file: Upload) raises -> String:
    if file.prepared_key!="":
        return persist_prepared(db,file.prepared_key)
    if file.fd>=0:
        return upload_spooled(db,file)
    var key = token()
    var kind = identify(file.data)
    var meta = metadata(db,file.data,kind)
    store_bytes(db,key,file.data)
    db.prepared_blobs[key] = List[String]([key,safe_filename(file.filename),kind,meta,String(file.data.byte_length()),checksum(file.data)])
    return persist_prepared(db,key)


def checksum_fd(fd: Int, offset: Int, size: Int) raises -> String:
    var bytes = List[UInt8](length=16,fill=0)
    if native.fs_md5_range(fd, offset, size, bytes)!=16:
        raise Error("Upload checksum failed")
    return base64(Bytes(Span(bytes)[:16]))


def store_spooled(mut db: Database, key: String, file: Upload) raises:
    var rel = relative(key)
    var directory = root()+"/"+String(rel[byte=:5])
    if native.fs_mkdirs(directory)!=0:
        raise Error("Cannot create storage directory")
    var path = root()+"/"+rel
    if native.fs_copy_range_new(file.fd, file.offset, file.size, path)!=0:
        raise Error("Cannot save upload")
    db.pending_files.append(path)


def metadata_file(mut db: Database, key: String, kind: String) raises -> String:
    var path = root()+"/"+relative(key)
    var meta = String('{"identified":true,"analyzed":true}')
    if kind.startswith("image/") or kind=="application/pdf":
        var dims = List[Int](length=2,fill=0)
        if native.image_dimensions_path(path, dims)==0:
            meta = '{"identified":true,"analyzed":true,"width":'+String(dims[0])+',"height":'+String(dims[1])+'}'
    elif kind.startswith("video/") or kind.startswith("audio/"):
        var rel = relative(key)
        var base = root()
        var fd = native.fs_open_beneath(base, rel)
        if fd<0:
            raise Error("Cannot open media")
        try:
            meta = media.metadata(db,"",kind,fd)
        except:
            pass
        _ = native.os_close(fd)
    return meta^


def upload_spooled(mut db: Database, file: Upload) raises -> String:
    var key = token()
    var kind = identify(read_slice(file.fd,file.offset,min(file.size,65536)))
    var digest = checksum_fd(file.fd,file.offset,file.size)
    store_spooled(db,key,file)
    var meta = metadata_file(db,key,kind)
    db.prepared_blobs[key] = List[String]([key,safe_filename(file.filename),kind,meta,String(file.size),digest])
    return persist_prepared(db,key)


def open_blob(key: String) raises -> Int:
    var base = root()
    var rel = relative(key)
    var fd = native.fs_open_beneath(base, rel)
    if fd<0:
        raise Error("Missing stored upload")
    return fd


def verify_file(mut db: Database, blob: String) raises:
    var row = db.rows("SELECT key,byte_size FROM active_storage_blobs WHERE id=?",[blob])[0].copy()
    var fd = open_blob(row[0])
    var size = native.fs_size(fd)
    _ = native.os_close(fd)
    if size!=Int(row[1]):
        raise Error("Incomplete stored upload")


def attach(mut db: Database, blob: String, record: String, id: String, name: String) raises:
    if db.scalar("SELECT blob_id FROM active_storage_attachments WHERE record_type=? AND record_id=? AND name=?",[record,id,name])==blob:
        return
    detach(db,record,id,name)
    _ = db.rows("INSERT INTO active_storage_attachments(name,record_type,record_id,blob_id,created_at) VALUES(?,?,?,?,strftime('%Y-%m-%d %H:%M:%f','now'))",[name,record,id,blob])


def signed_id(mut signer: Signer, id: String) raises -> String:
    return signer.envelope("ActiveStorage",id,"blob_id")


def blob_path(mut signer: Signer, id: String, filename: String) raises -> String:
    return "/rails/active_storage/blobs/proxy/"+url_encode(signed_id(signer,id))+"/"+url_encode(safe_filename(filename))


def bytes_response(body: Bytes, kind: String, filename: String, req: Request, force_download: Bool = False) raises -> Response:
    var extra = "Accept-Ranges: bytes\r\nContent-Disposition: "+("attachment" if force_download or kind not in ["image/webp","image/avif","image/png","image/gif","image/jpeg","image/tiff","image/bmp","image/vnd.adobe.photoshop","image/vnd.microsoft.icon","application/pdf"] else "inline")+'; filename="'+safe_filename(filename)+'"\r\n'
    var tag = validator(body)
    extra += "ETag: "+tag+"\r\nCache-Control: public, max-age=300\r\n"
    if req.header("if-none-match")==tag or req.header("if-none-match")=="W/"+tag or req.header("if-none-match")=="*":
        return Response(304,"",kind,extra)
    var range = req.header("range")
    if req.header("if-range")!="" and req.header("if-range")!=tag:
        range = ""
    if range.startswith("bytes="):
        var total = body.byte_length()
        var pieces = String(range[byte=6:]).split(",")
        var spans = List[Tuple[Int,Int]]()
        if len(pieces)>16:
            return Response(416,"",kind,"Content-Range: bytes */"+String(total)+"\r\n")
        try:
            for piece in pieces:
                var bits = String(piece.strip()).split("-",maxsplit=1)
                if len(bits)!=2 or (String(bits[0])=="" and String(bits[1])==""):
                    raise Error("Malformed range")
                for bit in bits:
                    for c in bit.as_bytes():
                        if c<48 or c>57:
                            raise Error("Malformed range")
                var start = Int(bits[0]) if String(bits[0])!="" else max(0,total-Int(bits[1]))
                var end = Int(bits[1]) if String(bits[1])!="" and String(bits[0])!="" else total-1
                end = min(end,total-1)
                if start>=0 and start<total and end>=start:
                    spans.append((start,end))
        except:
            return Response(416,"",kind,"Content-Range: bytes */"+String(total)+"\r\n")
        if len(spans)==0:
            return Response(416,"",kind,"Content-Range: bytes */"+String(total)+"\r\n")
        if len(spans)==1:
            var start = spans[0][0]
            var end = spans[0][1]
            return Response(206,Bytes(body.as_bytes()[start:end+1]),kind,extra+"Content-Range: bytes "+String(start)+"-"+String(end)+"/"+String(total)+"\r\n")
        var boundary = "campfire-"+token()
        var multipart = Bytes()
        for span in spans:
            multipart += "--"+boundary+"\r\nContent-Type: "+kind+"\r\nContent-Range: bytes "+String(span[0])+"-"+String(span[1])+"/"+String(total)+"\r\n\r\n"+Bytes(body.as_bytes()[span[0]:span[1]+1])+"\r\n"
        multipart += "--"+boundary+"--\r\n"
        return Response(206,multipart,"multipart/byteranges; boundary="+boundary,extra)
    return Response(200,body,kind,extra)


def download(mut db: Database, blob: String, req: Request) raises -> Response:
    var rows = db.rows("SELECT key,filename,coalesce(content_type,'application/octet-stream'),byte_size,coalesce(checksum,'') FROM active_storage_blobs WHERE id=?",[blob])
    if len(rows)==0:
        return html("File not found",404)
    var row = rows[0].copy()
    var folder = root()
    var path = relative(row[0])
    var fd = native.fs_open_beneath(folder, path)
    if fd<0:
        return html("File not found",404)
    var transfer = FileTransfer()
    transfer.fd = fd
    try:
        var total = native.fs_size(fd)
        if total<0 or String(total)!=row[3]:
            raise Error("Storage file size differs from its record")
        var kind = row[2]
        if kind in ["text/html","image/svg+xml","application/postscript","application/x-shockwave-flash","text/xml","application/xml","application/xhtml+xml","application/mathml+xml","text/cache-manifest"]:
            kind = "application/octet-stream"
        var force = params(req.query).get("disposition","")=="attachment" or kind not in ["image/webp","image/avif","image/png","image/gif","image/jpeg","image/tiff","image/bmp","image/vnd.adobe.photoshop","image/vnd.microsoft.icon","application/pdf"]
        var filename = safe_filename(row[1])
        var fallback = String()
        for cp in filename.codepoints():
            var letter = String(cp)
            fallback += letter if letter.byte_length()==1 and Int(letter.as_bytes()[0])>=32 and Int(letter.as_bytes()[0])<127 else "_"
        var tag = validator(row[0]+":"+row[3]+":"+row[4])
        var extra = "Accept-Ranges: bytes\r\nContent-Disposition: "+("attachment" if force else "inline")+'; filename="'+fallback+'"; filename*=UTF-8'+"''"+url_encode(filename).replace("+","%20")+'\r\nETag: '+tag+"\r\nCache-Control: public, max-age=300\r\n"
        if req.header("if-none-match")==tag or req.header("if-none-match")=="W/"+tag or req.header("if-none-match")=="*":
            transfer.close()
            return Response(304,"",kind,extra)
        var range = req.header("range")
        if req.header("if-range")!="" and req.header("if-range")!=tag:
            range = ""
        var spans = List[Tuple[Int,Int]]()
        var partial = range.startswith("bytes=")
        if partial:
            var pieces = String(range[byte=6:]).split(",")
            try:
                if len(pieces)>16:
                    raise Error("Too many ranges")
                for piece in pieces:
                    var bits = String(piece.strip()).split("-",maxsplit=1)
                    if len(bits)!=2 or (String(bits[0])=="" and String(bits[1])==""):
                        raise Error("Malformed range")
                    for bit in bits:
                        if bit.byte_length()>18:
                            raise Error("Range too large")
                        for c in bit.as_bytes():
                            if c<48 or c>57:
                                raise Error("Malformed range")
                    var start = Int(bits[0]) if String(bits[0])!="" else max(0,total-Int(bits[1]))
                    var end = Int(bits[1]) if String(bits[1])!="" and String(bits[0])!="" else total-1
                    end = min(end,total-1)
                    if start>=0 and start<total and end>=start:
                        spans.append((start,end))
            except:
                spans.clear()
            if len(spans)==0:
                transfer.close()
                return Response(416,"",kind,"Content-Range: bytes */"+String(total)+"\r\n")
        else:
            spans.append((0,total-1))
        var length = 0
        if len(spans)==1:
            length = spans[0][1]-spans[0][0]+1
            transfer.parts.append(Segment("",spans[0][0],length))
            if partial:
                extra += "Content-Range: bytes "+String(spans[0][0])+"-"+String(spans[0][1])+"/"+String(total)+"\r\n"
        else:
            var boundary = "campfire-"+token()
            for span in spans:
                var prefix = ("\r\n" if length>0 else "")+"--"+boundary+"\r\nContent-Type: "+kind+"\r\nContent-Range: bytes "+String(span[0])+"-"+String(span[1])+"/"+String(total)+"\r\n\r\n"
                var size = span[1]-span[0]+1
                length += prefix.byte_length()+size
                transfer.parts.append(Segment(prefix,span[0],size))
            var tail = "\r\n--"+boundary+"--\r\n"
            length += tail.byte_length()
            transfer.parts.append(Segment(tail,0,0))
            kind = "multipart/byteranges; boundary="+boundary
        db.pending_download.close()
        db.pending_download = transfer^
        return Response(206 if partial else 200,"",kind,extra,length)
    except e:
        transfer.close()
        raise e^


def variant(mut db: Database, blob: String, transformations: String, symbols: Bool = False) raises -> String:
    var hash = base64(digest(marshal.dump(db,transformations,symbols),False))
    var prior = db.scalar("SELECT a.blob_id FROM active_storage_variant_records v JOIN active_storage_attachments a ON a.record_type='ActiveStorage::VariantRecord' AND a.record_id=v.id AND a.name='image' WHERE v.blob_id=? AND v.variation_digest=?",[blob,hash])
    if prior!="":
        return prior
    var row = List[List[String]]([blob_info(db,blob)])
    var plan = row[0][0]+":"+hash
    if plan in db.prepared_variants:
        var key = db.prepared_variants[plan]
        if key=="":
            raise Error("Cannot decode image")
        var result = persist_prepared(db,key)
        if not db.preparing_media:
            _ = db.rows("INSERT INTO active_storage_variant_records(blob_id,variation_digest) VALUES(?,?)",[blob,hash])
            attach(db,result,"ActiveStorage::VariantRecord",db.last_id(),"image")
        return result^
    if not db.preparing_media:
        raise Error("Image preparation must precede the write transaction")
    db.prepared_variants[plan] = ""
    var values = db.rows("SELECT key FROM json_each(?)",[transformations])
    for item in values:
        if item[0] not in ["format","resize_to_limit","resize_to_fill","resize_to_fit"]:
            raise Error("Unsupported image transformation")
    var format = db.scalar("SELECT coalesce(json_extract(?,'$.format'),'png')",[transformations])
    if format not in ["png","jpg","jpeg","webp","gif"]:
        raise Error("Unsupported image format")
    var dimensions = db.rows("SELECT coalesce(json_extract(?,'$.resize_to_limit'),json_extract(?,'$.resize_to_fill'),json_extract(?,'$.resize_to_fit'),'[1200,800]')",[transformations,transformations,transformations])[0][0]
    var width = Int(db.scalar("SELECT json_extract(?,'$[0]')",[dimensions]))
    var height = Int(db.scalar("SELECT json_extract(?,'$[1]')",[dimensions]))
    if width<1 or height<1 or width>4096 or height>4096:
        raise Error("Invalid variant dimensions")
    var source_path = root()+"/"+relative(row[0][0])
    var crop = db.scalar("SELECT json_type(?,'$.resize_to_fill')",[transformations])=="array"
    var body = native.image_transform_path(source_path,width,height,crop,format)
    var file = Upload(safe_filename(row[0][1])+"."+format,"image/"+format,body)
    var result = upload(db,file)
    db.prepared_variants[plan] = String(result[byte=9:])
    return result^


def preview(mut db: Database, blob: String) raises -> String:
    var stored = db.scalar("SELECT blob_id FROM active_storage_attachments WHERE record_type='ActiveStorage::Blob' AND record_id=? AND name='preview_image'",[blob])
    if stored!="":
        return stored
    var row = blob_info(db,blob)
    if row[0] in db.prepared_previews:
        var key = db.prepared_previews[row[0]]
        if key=="":
            raise Error("Cannot preview media")
        var result = persist_prepared(db,key)
        if not db.preparing_media:
            attach(db,result,"ActiveStorage::Blob",blob,"preview_image")
        return result^
    if not db.preparing_media:
        raise Error("Media preparation must precede the write transaction")
    db.prepared_previews[row[0]] = ""
    var pixels = db.rows("SELECT coalesce(json_extract(?,'$.width'),0),coalesce(json_extract(?,'$.height'),0)",[row[3],row[3]])[0].copy()
    if row[2]!="application/pdf" and (Int(pixels[0])<1 or Int(pixels[1])<1 or Int(pixels[0])>250000000//Int(pixels[1])):
        raise Error("Media too large or undecodable")
    var fd = open_blob(row[0])
    var data = Bytes()
    try:
        if row[2].startswith("video/"):
            data = media.poster("",row[2],fd)
        elif row[2]=="application/pdf":
            data = media.pdf_preview("",fd)
    except e:
        _ = native.os_close(fd)
        raise e^
    _ = native.os_close(fd)
    if data!="":
        var pdf = row[2]=="application/pdf"
        stored = upload(db,Upload(row[1]+(".png" if pdf else ".jpg"),"image/png" if pdf else "image/jpeg",data))
        db.prepared_previews[row[0]] = String(stored[byte=9:])
        return stored^

    return blob


def prepare(mut db: Database, blob: String) raises:
    var kind = blob_info(db,blob)[2]
    if variable(kind) or kind.startswith("video/") or kind=="application/pdf":
        try:
            var source = preview(db,blob) if kind.startswith("video/") or kind=="application/pdf" else blob
            var format = "webp" if kind.startswith("video/") else thumbnail_format(kind)
            _ = variant(db,source,'{"format":'+json_string(format)+',"resize_to_limit":[1200,800]}',kind.startswith("video/"))
        except e:
            # Unpreviewable content stays downloadable. Admission/storage errors
            # must still roll back instead of masquerading as decoder failures.
            if not db.preparing_media and String(e) not in ["Cannot decode image","Cannot preview media"]:
                raise Error(String(e))



def preflight_form(mut db: Database, mut signer: Signer, mut form: Form) raises:
    db.preparing_media = True
    try:
        plan_form(db,signer,form)
        db.preparing_media = False
    except e:
        db.preparing_media = False
        raise e^


def plan_form(mut db: Database, mut signer: Signer, mut form: Form) raises:
    for name in ["message[attachment]","user[avatar]","account[logo]"]:
        if name in form.files and form.files[name].prepared_key=="":
            var file = form.files[name].copy()
            var blob = upload(db,file)
            file.prepared_key = String(blob[byte=9:])
            form.files[name] = file^
            if name=="message[attachment]":
                prepare(db,blob)
    var signed = form.fields.get("message[attachment]","")
    if signed!="":
        var blob = signer.verify(db,"ActiveStorage",signed,"blob_id",False)
        if blob!="" and db.scalar("SELECT 1 FROM active_storage_blobs WHERE id=?",[blob])=="1":
            prepare(db,blob)


def preflight_get(mut db: Database, mut signer: Signer, req: Request, authenticated: Bool) raises:
    var parts = req.path.split("/")
    var blob = String()
    var transformations = String()
    var symbols = False
    if req.path=="/account/logo":
        blob = db.scalar("SELECT blob_id FROM active_storage_attachments WHERE record_type='Account' AND name='logo' LIMIT 1")
        var size = "192" if params(req.query).get("size","")=="small" else "512"
        transformations = '{"format":"png","resize_to_limit":['+size+','+size+']}'
        symbols = True
    elif authenticated and len(parts)==4 and String(parts[1])=="users" and String(parts[3])=="avatar":
        var uid = signer.verify(db,"active_record/signed_id",String(parts[2]),"user/avatar")
        blob = db.scalar("SELECT blob_id FROM active_storage_attachments WHERE record_type='User' AND name='avatar' AND record_id=? LIMIT 1",[uid])
        transformations = '{"format":"webp","resize_to_limit":[512,512]}'
        symbols = True
    elif len(parts)>=8 and req.path.startswith("/rails/active_storage/representations/"):
        blob = signer.verify(db,"ActiveStorage",decode(String(parts[5])),"blob_id",False)
        transformations = signer.verify(db,"ActiveStorage",decode(String(parts[6])),"variation",False)
    if blob=="" or transformations=="" or db.scalar("SELECT 1 FROM active_storage_blobs WHERE id=?",[blob])!="1":
        return
    db.preparing_media = True
    try:
        var kind = blob_info(db,blob)[2]
        if kind.startswith("video/") or kind=="application/pdf":
            blob = preview(db,blob)
        _ = variant(db,blob,transformations,symbols)
    except:
        # The route retains its normal invalid/unpreviewable response.
        pass
    db.preparing_media = False


def image(mut db: Database, blob: String, req: Request, width: Int, height: Int, crop: Bool = False, format: String = "webp") raises -> Response:
    try:
        var id = variant(db,blob,'{"format":'+json_string(format)+','+json_string("resize_to_fill" if crop else "resize_to_limit")+':['+String(width)+','+String(height)+']}',True)
        return download(db,id,req)
    except:
        return html("Cannot decode image",422)


def representation_path(mut signer: Signer, id: String, filename: String, format: String) raises -> String:
    var variation = signer.envelope("ActiveStorage",'{"format":'+json_string(format)+',"resize_to_limit":[1200,800]}',"variation")
    return "/rails/active_storage/representations/proxy/"+url_encode(signed_id(signer,id))+"/"+url_encode(variation)+"/"+url_encode(safe_filename(filename))


def variable(kind: String) -> Bool:
    return kind in ["image/png","image/gif","image/jpeg","image/tiff","image/webp","image/avif","image/heic","image/heif"]


def thumbnail_format(kind: String) -> String:
    return "jpg" if kind=="image/jpeg" else "gif" if kind=="image/gif" else "webp" if kind=="image/webp" else "png"


def attachment_icon(name: String, size: Int) raises -> String:
    return '<img class="colorize--black" aria-hidden="true" src="'+templates.asset(name+".svg")+'" width="'+String(size)+'" height="'+String(size)+'">'


def has_thumbnail(mut db: Database, bid: String, format: String) raises -> Bool:
    var transform = '{"format":'+json_string(format)+',"resize_to_limit":[1200,800]}'
    var expected = base64(digest(marshal.dump(db,transform),False))
    var symbolic = base64(digest(marshal.dump(db,transform,True),False))
    return db.scalar("SELECT 1 FROM active_storage_variant_records v JOIN active_storage_attachments a ON a.record_type='ActiveStorage::VariantRecord' AND a.record_id=v.id WHERE v.blob_id=? AND v.variation_digest IN (?,?) LIMIT 1",[bid,expected,symbolic])=="1"


def presentation(mut db: Database, mut signer: Signer, mid: String) raises -> String:
    var rows = db.rows("SELECT b.id,b.filename,b.content_type,b.metadata FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id WHERE a.record_type='Message' AND a.record_id=? AND a.name='attachment' LIMIT 1",[mid])
    if len(rows)==0:
        return ""
    var b = rows[0].copy()
    var url = blob_path(signer,b[0],b[1])
    var download_url = url+"?disposition=attachment"
    var dims = db.rows("SELECT coalesce(json_extract(?,'$.width'),0),coalesce(json_extract(?,'$.height'),0)",[b[3],b[3]])[0].copy()
    var width = Float64(dims[0])
    var height = Float64(dims[1])
    if width>1200 or height>800:
        var scale = min(1200/width,800/height)
        width *= scale
        height *= scale
    var wrapper = '<div class="max-inline-size center '+("flex overflow-clip" if width>0 and height>0 else "overflow-clip")+'"'
    if width>0 and height>0:
        wrapper += ' style="width: '+String(width/2)+'px; aspect-ratio: '+String(width/height)+';"'
    wrapper += ">"
    var source = b[0]
    if b[2].startswith("video/") or b[2]=="application/pdf":
        source = db.scalar("SELECT blob_id FROM active_storage_attachments WHERE record_type='ActiveStorage::Blob' AND record_id=? AND name='preview_image'",[b[0]])
    if b[2].startswith("video/"):
        var poster = representation_path(signer,b[0],b[1],"webp") if source!="" and has_thumbnail(db,source,"webp") else String()
        return wrapper+'<video src="'+escape(url)+'"'+(' poster="'+escape(poster)+'"' if poster!="" else '')+' controls="controls" preload="none" width="100%" height="100%" class="message__attachment"></video></div>'
    if (variable(b[2]) or b[2]=="application/pdf") and source!="" and has_thumbnail(db,source,thumbnail_format(b[2])):
        var dimensions = ' width="'+String(width)+'" height="'+String(height)+'"' if width>0 and height>0 else String()
        return wrapper+'<a class="flex" data-lightbox-target="image" data-action="lightbox#open" data-lightbox-url-value="'+escape(download_url)+'" href="'+escape(url)+'"><img'+dimensions+' class="message__attachment" loading="lazy" src="'+escape(representation_path(signer,b[0],b[1],thumbnail_format(b[2])))+'"></a></div>'
    return '<div class="flex-inline align-center gap-half">'+attachment_icon("common-file-text",22)+'<span>'+escape(b[1])+'</span><a class="btn message__action-btn hide-in-ios-pwa" style="--width: auto;" href="'+escape(download_url)+'">'+attachment_icon("download",20)+'<span class="for-screen-reader">Download '+escape(b[1])+'</span></a><button class="btn message__action-btn" style="--width: auto;" data-controller="web-share" data-action="web-share#share" data-web-share-files-value="'+escape(download_url)+'">'+attachment_icon("share",20)+'<span class="for-screen-reader">Share '+escape(b[1])+'</span></button></div>'


def route(mut db: Database, mut signer: Signer, req: Request, uid: String, f: Form) raises -> Response:
    var parts = req.path.split("/")
    if req.path=="/rails/active_storage/direct_uploads":
        if uid=="":
            return html("Unauthorized",401)
        if req.method!="POST":
            return html("Not found",404)
        var size = f.fields.get("blob[byte_size]","")
        if size=="" or Int(size)<0 or Int(size)>Int(getenv("MULTIPART_BYTESIZE_LIMIT","10737418240")):
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
    if len(parts)>=8 and String(parts[3])=="representations" and req.method=="GET":
        var blob = signer.verify(db,"ActiveStorage",decode(String(parts[5])),"blob_id",False)
        var transformations = signer.verify(db,"ActiveStorage",decode(String(parts[6])),"variation",False)
        if blob=="" or transformations=="":
            return html("Not found",404)
        var kind = db.scalar("SELECT content_type FROM active_storage_blobs WHERE id=?",[blob])
        if kind.startswith("video/") or kind=="application/pdf":
            blob = preview(db,blob)
        return download(db,variant(db,blob,transformations),req)
    if len(parts)>=6 and String(parts[1])=="rails" and String(parts[2])=="active_storage" and String(parts[3])=="blobs":
        if req.method!="GET" or String(parts[4]) not in ["proxy","redirect"]:
            return html("File not found",404)
        var id = signer.verify(db,"ActiveStorage",decode(String(parts[5])),"blob_id",False)
        if id=="":
            return html("File not found",404)
        if String(parts[4])=="redirect":
            var rows = db.rows("SELECT key,filename,content_type FROM active_storage_blobs WHERE id=?",[id])
            if len(rows)==0:
                return html("File not found",404)
            var expiry = db.scalar("SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now','+5 minutes')")
            var data = '{"key":'+json_string(rows[0][0])+',"disposition":'+json_string(params(req.query).get("disposition","inline"))+',"content_type":'+json_string(rows[0][2])+',"service_name":"local"}'
            var url = req.origin()+"/rails/active_storage/disk/"+url_encode(signer.envelope("ActiveStorage",data,"blob_key",expiry))+"/"+url_encode(safe_filename(rows[0][1]))
            return html("",302,"Location: "+url+"\r\nCache-Control: private, max-age=300\r\n")
        return download(db,id,req)
    if len(parts)>=5 and String(parts[3])=="disk":
        if req.method!="GET" and req.method!="PUT":
            return html("Not found",404)
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
            if len(f.direct_info)!=3 or f.direct_info[0]!=key:
                raise Error("Direct upload must be prepared before admission")
            if db.scalar("SELECT 1 FROM active_storage_blobs WHERE key=?",[key])!="1":
                return html("Missing upload",404)
            _ = db.rows("UPDATE active_storage_blobs SET content_type=?,metadata=? WHERE key=?",[f.direct_info[1],f.direct_info[2],key])
            return html("",204)
        var blob = db.scalar("SELECT id FROM active_storage_blobs WHERE key=?",[key])
        var download_req = req.copy()
        if db.scalar("SELECT json_extract(?,'$.disposition')",[data]).startswith("attachment"):
            download_req.query = "disposition=attachment"
        return download(db,blob,download_req)
    return html("",0)


def discard_prepared(mut db: Database):
    for file in db.pending_files:
        var parts = file.split("/")
        var key = String(parts[len(parts)-1])
        try:
            if db.scalar("SELECT 1 FROM active_storage_blobs WHERE key=?",[key])=="1":
                continue
            var name = file.copy()
            _ = native.fs_unlink(name)
        except:
            # Offline gc-files recovers interrupted preparations.
            pass
    db.pending_files.clear()
    db.prepared_blobs.clear()
    db.prepared_variants.clear()
    db.prepared_previews.clear()
    db.preparing_media = False


def rollback(mut db: Database):
    db.pending_download.close()
    db.pending_deletes.clear()
    discard_prepared(db)


def profile_upload(mut db: Database, f: Form, id: String, account: Bool = False) raises:
    var name = "account[logo]" if account else "user[avatar]"
    if name in f.files:
        var file = f.files[name].copy()
        var blob = upload(db,file)
        var row = db.rows("SELECT key,content_type,metadata FROM active_storage_blobs WHERE id=?",[blob])[0].copy()
        if not row[1].startswith("image/") or db.scalar("SELECT json_extract(?,'$.width')",[row[2]])=="":
            raise Error("Invalid image")
        attach(db,blob,"Account" if account else "User",id,"logo" if account else "avatar")


def purge(mut db: Database, blob: String, depth: Int = 0) raises:
    if depth>32:
        raise Error("Attachment cycle")
    if db.scalar("SELECT 1 FROM active_storage_attachments WHERE blob_id=? LIMIT 1",[blob])=="1":
        return
    var key = db.scalar("SELECT key FROM active_storage_blobs WHERE id=?",[blob])
    if key=="":
        return
    var children = db.rows("SELECT blob_id FROM active_storage_attachments WHERE record_type='ActiveStorage::Blob' AND record_id=?",[blob])
    _ = db.rows("DELETE FROM active_storage_attachments WHERE record_type='ActiveStorage::Blob' AND record_id=?",[blob])
    var variants = db.rows("SELECT id FROM active_storage_variant_records WHERE blob_id=?",[blob])
    for v in variants:
        var attached = db.rows("SELECT blob_id FROM active_storage_attachments WHERE record_type='ActiveStorage::VariantRecord' AND record_id=?",[v[0]])
        for a in attached:
            children.append(a.copy())
        _ = db.rows("DELETE FROM active_storage_attachments WHERE record_type='ActiveStorage::VariantRecord' AND record_id=?",[v[0]])
    _ = db.rows("DELETE FROM active_storage_variant_records WHERE blob_id=?",[blob])
    for child in children:
        purge(db,child[0],depth+1)
    _ = db.rows("DELETE FROM active_storage_blobs WHERE id=?",[blob])
    _ = db.rows("INSERT OR IGNORE INTO mojo_file_purges(key) VALUES(?)",[key])
    db.pending_deletes.append(key)


def detach(mut db: Database, record: String, id: String, name: String = "") raises:
    var filter = String("record_type=? AND record_id=?")
    var args = List[String]([record,id])
    if name!="":
        filter += " AND name=?"
        args.append(name)
    var rows = db.rows("SELECT blob_id FROM active_storage_attachments WHERE "+filter,args)
    _ = db.rows("DELETE FROM active_storage_attachments WHERE "+filter,args)
    for row in rows:
        purge(db,row[0])


def remove_message(mut db: Database, mid: String) raises:
    detach(db,"Message",mid)
    var richtexts = db.rows("SELECT id FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",[mid])
    for r in richtexts:
        detach(db,"ActionText::RichText",r[0])


def cleanup_file(mut db: Database, key: String) raises:
    # Imported/recovered databases can reintroduce a key. Never delete live data.
    if db.scalar("SELECT 1 FROM active_storage_blobs WHERE key=?",[key])=="1":
        _ = db.rows("DELETE FROM mojo_file_purges WHERE key=?",[key])
        return
    var path = root()+"/"+relative(key)
    if native.fs_unlink(path)==0:
        _ = db.rows("DELETE FROM mojo_file_purges WHERE key=?",[key])
    else:
        _ = db.rows("UPDATE mojo_file_purges SET attempts=attempts+1,available_at=unixepoch()+min(3600,(attempts+1)*5),error='unlink or directory fsync failed' WHERE key=?",[key])


def retry_cleanup(mut db: Database) raises:
    for row in db.rows("SELECT key FROM mojo_file_purges WHERE available_at<=unixepoch() LIMIT 32"):
        cleanup_file(db,row[0])


def commit(mut db: Database):
    discard_prepared(db)
    for key in db.pending_deletes:
        var copy = key.copy()
        try:
            cleanup_file(db,copy)
        except e:
            # The committed purge row remains for the worker to retry.
            print("Deferred file cleanup:",e)
    db.pending_deletes.clear()


def preflight_direct(mut db: Database, mut signer: Signer, req: Request, uid: String, mut form: Form) raises -> Response:
    if uid=="":
        return html("Unauthorized",401)
    var parts = req.path.split("/")
    if len(parts)<5:
        return html("Not found",404)
    var data = signer.verify(db,"ActiveStorage",decode(String(parts[4])),"blob_token",False)
    if data=="" or db.scalar("SELECT json_extract(?,'$.service_name')",[data])!="local":
        return html("Invalid storage token",404)
    var key = db.scalar("SELECT json_extract(?,'$.key')",[data])
    if db.scalar("SELECT 1 FROM active_storage_blobs WHERE key=?",[key])!="1":
        return html("Missing upload",404)
    var length = db.scalar("SELECT json_extract(?,'$.content_length')",[data])
    var expected = db.scalar("SELECT json_extract(?,'$.checksum')",[data])
    var actual_size = req.body_size if req.body_fd>=0 else req.body.byte_length()
    var actual_checksum = checksum_fd(req.body_fd,0,actual_size) if req.body_fd>=0 else checksum(req.body)
    if String(actual_size)!=length or actual_checksum!=expected:
        return html("Upload checksum mismatch",422)
    var existing = False
    try:
        var fd = open_blob(key)
        try:
            existing = checksum_fd(fd,0,native.fs_size(fd))==expected
        except:
            existing = False
        _ = native.os_close(fd)
    except:
        pass
    if not existing:
        if req.body_fd>=0:
            store_spooled(db,key,Upload("","", "",req.body_fd,0,req.body_size))
        else:
            store_bytes(db,key,req.body)
    var sample = read_slice(req.body_fd,0,min(req.body_size,65536)) if req.body_fd>=0 else req.body
    var kind = identify(sample)
    form.direct_info = List[String]([key,kind,metadata_file(db,key,kind)])
    return html("",0)
