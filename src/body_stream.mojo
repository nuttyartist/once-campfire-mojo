# Incremental body framing into an anonymous disk file. No body-sized allocations.
from std.ffi import external_call
from std.os import getenv


def read_slice(fd: Int, offset: Int, size: Int) raises -> String:
    var out = List[UInt8](length=size,fill=0)
    var used = 0
    while used<size:
        var n = external_call["fs_read",Int](fd,out.unsafe_ptr().unsafe_offset(used),size-used,offset+used)
        if n<=0:
            raise Error("Cannot read upload")
        used += n
    return String(unsafe_from_utf8=Span(unsafe_ptr=out.unsafe_ptr(),length=size))


struct BodyStream(Copyable, Movable):
    var fd: Int
    var size: Int
    var state: Int
    var remaining: Int

    def __init__(out self):
        self.fd = -1
        self.size = 0
        self.state = 0
        self.remaining = 0

    def close(mut self):
        if self.fd>=0:
            _ = external_call["os_close",Int](self.fd)
        self.fd = -1
        self.size = 0
        self.state = 0
        self.remaining = 0

    def append(mut self, data: String) raises:
        var limit = Int(getenv("MULTIPART_BYTESIZE_LIMIT","10737418240"))
        if limit<0 or self.size+data.byte_length()>limit:
            raise Error("Upload body too large")
        if self.fd<0:
            self.fd = external_call["fs_temp",Int]()
            if self.fd<0:
                raise Error("Cannot spool upload")
        if external_call["fs_append",Int](self.fd,data.as_bytes().unsafe_ptr(),data.byte_length())!=0:
            raise Error("Cannot spool upload")
        self.size += data.byte_length()

    # Returns consumed wire bytes and whether framing is complete.
    def feed(mut self, source: String, length: Int, chunked: Bool) raises -> Tuple[Int,Bool]:
        if not chunked:
            var used = min(source.byte_length(),length-self.size)
            self.append(String(unsafe_from_utf8=source.as_bytes()[:used]))
            return (used,self.size==length)
        var offset = 0
        while True:
            var tail = String(unsafe_from_utf8=source.as_bytes()[offset:])
            if self.state==0:
                var end = tail.find("\r\n")
                if end<0:
                    if tail.byte_length()>8192:
                        raise Error("Chunk line too long")
                    return (offset,False)
                var line = String(tail[byte=:end])
                var raw = String(line.split(";",maxsplit=1)[0]).lower()
                if raw=="" or raw.byte_length()>10:
                    raise Error("Invalid chunk size")
                self.remaining = 0
                for c in raw.as_bytes():
                    var digit = Int(c)-48 if c>=48 and c<=57 else Int(c)-87 if c>=97 and c<=102 else -1
                    if digit<0:
                        raise Error("Invalid chunk size")
                    self.remaining = self.remaining*16+digit
                if self.size+self.remaining>Int(getenv("MULTIPART_BYTESIZE_LIMIT","10737418240")):
                    raise Error("Upload body too large")
                offset += end+2
                self.state = 3 if self.remaining==0 else 1
            elif self.state==1:
                var used = min(self.remaining,tail.byte_length())
                self.append(String(unsafe_from_utf8=tail.as_bytes()[:used]))
                offset += used
                self.remaining -= used
                if self.remaining>0:
                    return (offset,False)
                self.state = 2
            elif self.state==2:
                if tail.byte_length()<2:
                    return (offset,False)
                if not tail.startswith("\r\n"):
                    raise Error("Invalid chunk delimiter")
                offset += 2
                self.state = 0
            else:
                if tail.startswith("\r\n"):
                    self.append("")
                    return (offset+2,True)
                var end = tail.find("\r\n\r\n")
                if end<0:
                    if tail.byte_length()>32768:
                        raise Error("Trailers too long")
                    return (offset,False)
                for line in String(tail[byte=:end]).split("\r\n"):
                    var bits = line.split(":",maxsplit=1)
                    if len(bits)!=2 or String(bits[0]).lower() in ["content-length","transfer-encoding","authorization","cookie"]:
                        raise Error("Invalid trailer")
                self.append("")
                return (offset+end+4,True)
