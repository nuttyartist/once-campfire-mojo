# A connection-owned, bounded file response. Application/storage policy is elsewhere.
from std.ffi import external_call


@fieldwise_init
struct Segment(Copyable, Movable):
    var prefix: String
    var offset: Int
    var length: Int


struct FileTransfer(Copyable, Movable):
    # Ownership moves from Database.pending_download to the serving connection.
    # Copies are only used for metadata inspection; close() is explicit at each
    # connection/error boundary, as it is for the socket descriptor itself.
    var fd: Int
    var parts: List[Segment]
    var part: Int

    def __init__(out self):
        self.fd = -1
        self.parts = List[Segment]()
        self.part = 0

    def close(mut self):
        if self.fd>=0:
            _ = external_call["os_close",Int](self.fd)
        self.fd = -1
        self.parts.clear()
        self.part = 0

    def next(mut self) raises -> String:
        while self.fd>=0 and self.part<len(self.parts):
            if self.parts[self.part].prefix!="":
                var prefix = self.parts[self.part].prefix.copy()
                self.parts[self.part].prefix = ""
                return prefix^
            var length = min(65536,self.parts[self.part].length)
            if length==0:
                self.part += 1
                continue
            var bytes = List[UInt8](length=length,fill=0)
            var read = external_call["fs_read",Int](self.fd,bytes.unsafe_ptr(),length,self.parts[self.part].offset)
            if read<=0:
                self.close()
                raise Error("File changed during download")
            self.parts[self.part].offset += read
            self.parts[self.part].length -= read
            return String(unsafe_from_utf8=Span(unsafe_ptr=bytes.unsafe_ptr(),length=read))
        self.close()
        return ""
