from std.ffi import external_call
from database import Database
from crypto import json_string


def run(var executable: String, args: List[String], source: String, capacity: Int, timeout: Int = 10000, seekable: Bool = False, source_fd: Int = -1) raises -> String:
    var wire = "\x00".join(args)+"\x00"
    var out = List[UInt8](length=capacity,fill=0)
    var size = 0
    if external_call["process_capture",Int](executable.as_c_string_span(),wire.as_bytes().unsafe_ptr(),wire.byte_length(),source.as_bytes().unsafe_ptr(),source.byte_length(),out.unsafe_ptr(),capacity,timeout,Pointer(to=size),-source_fd-1 if source_fd>=0 else Int(seekable))!=0:
        raise Error("Media processor could not read the file")
    return String(unsafe_from_utf8=Span(unsafe_ptr=out.unsafe_ptr(),length=size))


def demuxer(kind: String) -> String:
    if kind=="video/mp4" or kind=="video/quicktime":
        return "mov"
    if kind=="video/webm" or kind=="video/x-matroska":
        return "matroska"
    if kind=="audio/mpeg":
        return "mp3"
    if kind=="audio/ogg" or kind=="video/ogg":
        return "ogg"
    if kind=="audio/wav":
        return "wav"
    return ""


def metadata(mut db: Database, data: String, kind: String, source_fd: Int = -1) raises -> String:
    var format = demuxer(kind)
    if format=="":
        return '{"identified":true,"analyzed":true}'
    var json = run("/usr/bin/ffprobe",["-v","error","-protocol_whitelist","file","-f",format,"-i","/proc/self/fd/0","-show_streams","-show_format","-of","json"],data,1048576,10000,True,source_fd)
    if db.scalar("SELECT json_valid(?)",[json])!="1":
        raise Error("Invalid media analysis")
    var video = db.scalar("SELECT value FROM json_each(?,'$.streams') WHERE json_extract(value,'$.codec_type')='video' LIMIT 1",[json])
    var audio = db.scalar("SELECT value FROM json_each(?,'$.streams') WHERE json_extract(value,'$.codec_type')='audio' LIMIT 1",[json])
    var out = '{"identified":true,"analyzed":true,"video":'+("true" if video!="" else "false")+',"audio":'+("true" if audio!="" else "false")
    var duration = db.scalar("SELECT coalesce(json_extract(?,'$.format.duration'),'')",[json])
    if duration!="":
        out += ',"duration":'+String(Float64(duration))
    if video!="":
        for key in ["width","height"]:
            var value = db.scalar("SELECT coalesce(json_extract(?,?),0)",[video,"$."+key])
            out += ','+json_string(key)+':'+String(Int(value))
        var ratio = db.scalar("SELECT coalesce(json_extract(?,'$.display_aspect_ratio'),'')",[video])
        var parts = ratio.split(":")
        if len(parts)==2 and String(parts[1])!="0":
            out += ',"display_aspect_ratio":'+String(Float64(parts[0])/Float64(parts[1]))
    return out+"}"


def poster(data: String, kind: String, source_fd: Int = -1) raises -> String:
    var format = demuxer(kind)
    if format=="":
        raise Error("Unsupported video")
    return run("/usr/bin/ffmpeg",["-v","error","-threads","2","-protocol_whitelist","file","-f",format,"-i","/proc/self/fd/0","-map","0:v:0","-frames:v","1","-vf","select=eq(n\\,0)+eq(key\\,1)+gt(scene\\,0.015),loop=loop=-1:size=2,trim=start_frame=1","-threads","2","-f","image2pipe","-vcodec","mjpeg","pipe:1"],data,8388608,10000,True,source_fd)


def pdf_preview(data: String, source_fd: Int = -1) raises -> String:
    return run("/usr/bin/pdftoppm",["-f","1","-singlefile","-scale-to","1200","-png","-"],data,8388608,10000,False,source_fd)
