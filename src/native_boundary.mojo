# The only Mojo module permitted to use FFI or raw pointers.
# Buffers are borrowed only for a synchronous call; C must not retain them.
# Every pointer is derived here from a live owner, with capacity checks.
from std.ffi import external_call
from byte_buffer import Bytes


def terminated(data: List[UInt8]) raises -> String:
    for i in range(len(data)):
        if data[i] == 0:
            return String(from_utf8=Span(data)[:i])
    raise Error("Native text is missing its terminator")



def os_fork() -> Int:
    return external_call["os_fork", Int]()


def os_now_ms() -> Int:
    return external_call["os_now_ms", Int]()


def os_running() -> Int:
    return external_call["os_running", Int]()


def os_accept(value: Int) -> Int:
    return external_call["os_accept", Int](value)


def os_close(value: Int) -> Int:
    return external_call["os_close", Int](value)


def os_wait_child() -> Int:
    return external_call["os_wait_child", Int]()


def os_listen(value: Int) -> Int:
    return external_call["os_listen", Int](value)


def os_signals() -> Int:
    return external_call["os_signals", Int]()


def bus_sequence() -> Int:
    return external_call["bus_sequence", Int]()


def bus_init() -> Int:
    return external_call["bus_init", Int]()


def work_init() -> Int:
    return external_call["work_init", Int]()


def fs_temp() -> Int:
    return external_call["fs_temp", Int]()


def os_sleep_ms(value: Int):
    external_call["os_sleep_ms", NoneType](value)


def os_child_exit(value: Int):
    external_call["os_child_exit", NoneType](value)


def os_kill(pid: Int, signal: Int):
    external_call["os_kill", NoneType](pid, signal)


def os_lock_file(var value: String) -> Int:
    if "\x00" in value:
        return -1
    return external_call["os_lock_file", Int](value.as_c_string_span())


def fs_mkdirs(var value: String) -> Int:
    if "\x00" in value:
        return -1
    return external_call["fs_mkdirs", Int](value.as_c_string_span())


def fs_unlink(var value: String) -> Int:
    if "\x00" in value:
        return -1
    return external_call["fs_unlink", Int](value.as_c_string_span())


def net_validate(var value: String) -> Int:
    if "\x00" in value:
        return -1
    return external_call["net_validate", Int](value.as_c_string_span())


def valid_ip(var value: String) -> Int:
    if "\x00" in value:
        return -1
    return external_call["valid_ip", Int](value.as_c_string_span())


def unicode_word(var value: String) -> Int:
    if "\x00" in value:
        return -1
    return external_call["unicode_word", Int](value.as_c_string_span())


def crypto_password(var password: String, var digest: String) -> Int:
    if "\x00" in password or "\x00" in digest:
        return 0
    return external_call["crypto_password", Int](password.as_c_string_span(), digest.as_c_string_span())


def crypto_equal(var a: String, var b: String) -> Int:
    if "\x00" in a or "\x00" in b:
        return 0
    return external_call["crypto_equal", Int](a.as_c_string_span(), b.as_c_string_span())


def fs_open_beneath(var root: String, var path: String) -> Int:
    if "\x00" in root or "\x00" in path:
        return -1
    return external_call["fs_open_beneath", Int](root.as_c_string_span(), path.as_c_string_span())


def fs_size(fd: Int) -> Int:
    return external_call["fs_size", Int](fd)


def fs_copy_range_new(fd: Int, offset: Int, length: Int, var path: String) -> Int:
    if "\x00" in path or offset < 0 or length < 0 or offset > 9223372036854775807-length:
        return -1
    return external_call["fs_copy_range_new", Int](fd, offset, length, path.as_c_string_span())


def fs_md5_range(fd: Int, offset: Int, length: Int, mut output: List[UInt8]) -> Int:
    if offset < 0 or length < 0 or offset > 9223372036854775807-length or len(output) < 16:
        return -1
    return external_call["fs_md5_range", Int](fd, offset, length, output.unsafe_ptr())


def os_recv(fd: Int, mut output: List[UInt8], count: Int) -> Int:
    if count < 0 or count > len(output):
        return -1
    var result = external_call["os_recv", Int](fd, output.unsafe_ptr(), count)
    return -1 if result > count else result


def os_send(fd: Int, source: Span[UInt8, _], count: Int) -> Int:
    if count < 0 or count > len(source):
        return -1
    var result = external_call["os_send", Int](fd, source.unsafe_ptr(), count)
    return -1 if result > count else result


def os_poll(fds: List[Int], writes: List[Int], mut ready: List[Int], count: Int) -> Int:
    if count < 0 or count > 1025 or count > len(fds) or count > len(writes) or count > len(ready):
        return -1
    return external_call["os_poll", Int](fds.unsafe_ptr(), writes.unsafe_ptr(), ready.unsafe_ptr(), count)


def peer_address(fd: Int, mut output: List[UInt8], capacity: Int) -> Int:
    if capacity <= 0 or capacity > len(output):
        return -1
    return external_call["peer_address", Int](fd, output.unsafe_ptr(), capacity)


def crypto_random(mut output: List[UInt8], count: Int) -> Int:
    if count < 0 or count > len(output) or count > 2147483647:
        return -1
    return external_call["crypto_random", Int](output.unsafe_ptr(), count)


def gzip_encode(source: Span[UInt8, _], count: Int, mut output: List[UInt8], capacity: Int) -> Int:
    if count < 0 or count > len(source) or count > 2147483647 or capacity < 0 or capacity > len(output) or capacity > 2147483647:
        return -1
    var result = external_call["gzip_encode", Int](source.unsafe_ptr(), count, output.unsafe_ptr(), capacity)
    return -1 if result > capacity else result


def base64_encode(source: Span[UInt8, _], count: Int, mut output: List[UInt8]) -> Int:
    if count < 0 or count > len(source) or count > 1610612733 or len(output) < (count+2)//3*4+1:
        return -1
    var result = external_call["base64_encode", Int](source.unsafe_ptr(), count, output.unsafe_ptr())
    return -1 if result > len(output) else result


def base64_decode(source: Span[UInt8, _], count: Int, mut output: List[UInt8]) -> Int:
    if count < 0 or count > len(source) or count > 2147483647 or count%4 != 0 or len(output) < count//4*3:
        return -1
    var result = external_call["base64_decode", Int](source.unsafe_ptr(), count, output.unsafe_ptr())
    return -1 if result > len(output) else result


def crypto_hash(source: Span[UInt8, _], count: Int, sha256: Int, mut output: List[UInt8]) -> Int:
    if count < 0 or count > len(source) or len(output) < 32:
        return -1
    var result = external_call["crypto_hash", Int](source.unsafe_ptr(), count, sha256, output.unsafe_ptr())
    return -1 if result > len(output) else result


def crypto_md5(source: Span[UInt8, _], count: Int, mut output: List[UInt8]) -> Int:
    if count < 0 or count > len(source) or len(output) < 16:
        return -1
    var result = external_call["crypto_md5", Int](source.unsafe_ptr(), count, output.unsafe_ptr())
    return -1 if result > len(output) else result


def crypto_derive(var secret: String, var salt: String, mut output: List[UInt8]) -> Int:
    if "\x00" in secret or "\x00" in salt or len(output) < 129 or secret.byte_length() > 2147483647 or salt.byte_length() > 2147483647:
        return -1
    return external_call["crypto_derive", Int](secret.as_c_string_span(), salt.as_c_string_span(), output.unsafe_ptr())


def crypto_hmac(var key: String, source: Span[UInt8, _], count: Int, sha256: Int, mut output: List[UInt8]) -> Int:
    if "\x00" in key or count < 0 or count > len(source) or len(output) < 65:
        return -1
    return external_call["crypto_hmac", Int](key.as_c_string_span(), source.unsafe_ptr(), count, sha256, output.unsafe_ptr())


def password_hash(var password: String, mut output: List[UInt8]) -> Int:
    if "\x00" in password or len(output) < 61:
        return -1
    return external_call["password_hash", Int](password.as_c_string_span(), output.unsafe_ptr())


def hmac_sha256_raw(key: Span[UInt8, _], keylen: Int, source: Span[UInt8, _], count: Int, mut output: List[UInt8]) -> Int:
    if keylen < 0 or keylen > len(key) or keylen > 2147483647 or count < 0 or count > len(source) or len(output) < 32:
        return -1
    var result = external_call["hmac_sha256_raw", Int](key.unsafe_ptr(), keylen, source.unsafe_ptr(), count, output.unsafe_ptr())
    return -1 if result > len(output) else result


def p256_generate(mut private: List[UInt8], mut public: List[UInt8]) -> Int:
    if len(private) < 32 or len(public) < 65:
        return -1
    return external_call["p256_generate", Int](private.unsafe_ptr(), public.unsafe_ptr())


def p256_public(private: Span[UInt8, _], mut output: List[UInt8]) -> Int:
    if len(private) != 32 or len(output) < 65:
        return -1
    return external_call["p256_public", Int](private.unsafe_ptr(), output.unsafe_ptr())


def p256_ecdh(private: Span[UInt8, _], public: Span[UInt8, _], mut output: List[UInt8]) -> Int:
    if len(private) != 32 or len(public) != 65 or len(output) < 32:
        return -1
    return external_call["p256_ecdh", Int](private.unsafe_ptr(), public.unsafe_ptr(), output.unsafe_ptr())


def p256_sign(private: Span[UInt8, _], source: Span[UInt8, _], count: Int, mut output: List[UInt8]) -> Int:
    if len(private) != 32 or count < 0 or count > len(source) or len(output) < 64:
        return -1
    return external_call["p256_sign", Int](private.unsafe_ptr(), source.unsafe_ptr(), count, output.unsafe_ptr())


def p256_validate_public(public: Span[UInt8, _]) -> Int:
    if len(public) != 65:
        return -1
    return external_call["p256_validate_public", Int](public.unsafe_ptr())


def aes128gcm_encrypt(key: Span[UInt8, _], nonce: Span[UInt8, _], source: Span[UInt8, _], count: Int, mut output: List[UInt8]) -> Int:
    if len(key) != 16 or len(nonce) != 12 or count < 0 or count > len(source) or count > 2147483631 or len(output) < count+16:
        return -1
    var result = external_call["aes128gcm_encrypt", Int](key.unsafe_ptr(), nonce.unsafe_ptr(), source.unsafe_ptr(), count, output.unsafe_ptr())
    return -1 if result > len(output) else result


def bus_publish(source: Span[UInt8, _], count: Int) -> Int:
    if count < 0 or count > len(source) or count > 1048576:
        return -1
    return external_call["bus_publish", Int](source.unsafe_ptr(), count)


def bus_resync():
    external_call["bus_resync", NoneType]()


def bus_read(sequence: Int, mut output: List[UInt8], capacity: Int) -> Int:
    if sequence<0 or capacity < 0 or capacity > len(output):
        return -1
    var result = external_call["bus_read", Int](sequence, output.unsafe_ptr(), capacity)
    return -1 if result > capacity else result


def metric_get(index: Int) -> Int:
    if index < 0 or index >= 16:
        return -1
    return external_call["metric_get", Int](index)


def metric_add(index: Int, delta: Int) -> Int:
    if index < 0 or index >= 16:
        return -1
    return external_call["metric_add", Int](index, delta)


def file_append(var path: String, source: Span[UInt8, _], count: Int) -> Int:
    if "\x00" in path or count < 0 or count > len(source):
        return -1
    return external_call["file_append", Int](path.as_c_string_span(), source.unsafe_ptr(), count)


def fs_write_new(var path: String, source: Span[UInt8, _], count: Int) -> Int:
    if "\x00" in path or count < 0 or count > len(source):
        return -1
    return external_call["fs_write_new", Int](path.as_c_string_span(), source.unsafe_ptr(), count)


def fs_append(fd: Int, source: Span[UInt8, _], count: Int) -> Int:
    if count < 0 or count > len(source):
        return -1
    return external_call["fs_append", Int](fd, source.unsafe_ptr(), count)


def crc32_bytes(source: Span[UInt8, _], count: Int) -> Int:
    if count < 0 or count > len(source) or count > 4294967295:
        return -1
    return external_call["crc32_bytes", Int](source.unsafe_ptr(), count)


def mime_detect(source: Span[UInt8, _], count: Int, mut output: List[UInt8], capacity: Int) -> Int:
    if count < 0 or count > len(source) or capacity < 0 or capacity > len(output):
        return -1
    var result = external_call["mime_detect", Int](source.unsafe_ptr(), count, output.unsafe_ptr(), capacity)
    return -1 if result > capacity else result


def image_dimensions(source: Span[UInt8, _], count: Int, mut dimensions: List[Int]) -> Int:
    if count < 0 or count > len(source) or len(dimensions) < 2:
        return -1
    return external_call["image_dimensions", Int](source.unsafe_ptr(), count, dimensions.unsafe_ptr())


def image_dimensions_path(var path: String, mut dimensions: List[Int]) -> Int:
    if "\x00" in path or len(dimensions) < 2:
        return -1
    return external_call["image_dimensions_path", Int](path.as_c_string_span(), dimensions.unsafe_ptr())


def url_component(var url: String, part: Int, mut output: List[UInt8], capacity: Int) -> Int:
    if "\x00" in url or capacity <= 0 or capacity > len(output):
        return -1
    var result = external_call["url_component", Int](url.as_c_string_span(), part, output.unsafe_ptr(), capacity)
    return -1 if result > capacity else result


def regex_find(var pattern: String, text: Span[UInt8, _], count: Int, start: Int, mut span: List[Int]) -> Int:
    if "\x00" in pattern or count < 0 or count > len(text) or start < 0 or start > count or len(span) < 2:
        return -1
    return external_call["regex_find", Int](pattern.as_c_string_span(), text.unsafe_ptr(), count, start, span.unsafe_ptr())


def qr_encode(var text: String, mut output: List[UInt8]) -> Int:
    if "\x00" in text or len(output) < 3918:
        return -1
    return external_call["qr_encode", Int](text.as_c_string_span(), output.unsafe_ptr())


def qr_module(data: Span[UInt8, _], x: Int, y: Int) -> Int:
    if len(data) < 3918 or Int(data[0])<21 or Int(data[0])>177 or Int(data[0])%4!=1 or x < 0 or y < 0 or x >= Int(data[0]) or y >= Int(data[0]):
        return 0
    return external_call["qr_module", Int](data.unsafe_ptr(), x, y)


def dom_child(handle: Int) -> Int:
    return external_call["dom_child", Int](handle)


def dom_next(handle: Int) -> Int:
    return external_call["dom_next", Int](handle)


def dom_type(handle: Int) -> Int:
    return external_call["dom_type", Int](handle)


def dom_foreign(handle: Int) -> Int:
    return external_call["dom_foreign", Int](handle)


def dom_root(handle: Int) -> Int:
    return external_call["dom_root", Int](handle)


def dom_attrs(handle: Int) -> Int:
    return external_call["dom_attrs", Int](handle)


def dom_attr_next(handle: Int) -> Int:
    return external_call["dom_attr_next", Int](handle)


def dom_clear_node(handle: Int):
    external_call["dom_clear_node", NoneType](handle)


def dom_remove(handle: Int):
    external_call["dom_remove", NoneType](handle)


def dom_free(handle: Int):
    external_call["dom_free", NoneType](handle)


def dom_set_name(handle: Int, var name: String):
    if "\x00" in name:
        return
    external_call["dom_set_name", NoneType](handle, name.as_c_string_span())


def dom_set_attr(handle: Int, var name: String, var value: String):
    if "\x00" in name or "\x00" in value:
        return
    external_call["dom_set_attr", NoneType](handle, name.as_c_string_span(), value.as_c_string_span())


def dom_replace_text(handle: Int, var value: String) -> Int:
    if "\x00" in value:
        return -1
    return external_call["dom_replace_text", Int](handle, value.as_c_string_span())


def dom_parse(text: Span[UInt8, _], count: Int) -> Int:
    if count < 0 or count > len(text):
        return 0
    return external_call["dom_parse", Int](text.unsafe_ptr(), count)


def dom_parse_fragment(text: Span[UInt8, _], count: Int) -> Int:
    if count < 0 or count > len(text):
        return 0
    return external_call["dom_parse_fragment", Int](text.unsafe_ptr(), count)


def dom_inner_html(handle: Int, text: Span[UInt8, _], count: Int) -> Int:
    if count < 0 or count > len(text):
        return -1
    return external_call["dom_inner_html", Int](handle, text.unsafe_ptr(), count)


def dom_replace_html(handle: Int, text: Span[UInt8, _], count: Int) -> Int:
    if count < 0 or count > len(text):
        return -1
    return external_call["dom_replace_html", Int](handle, text.unsafe_ptr(), count)


def fs_read(fd: Int, mut output: List[UInt8], count: Int, offset: Int, buffer_offset: Int = 0) -> Int:
    if offset < 0 or count<0 or offset>9223372036854775807-count or buffer_offset < 0 or buffer_offset > len(output) or count < 0 or count > len(output)-buffer_offset:
        return -1
    var n = external_call["fs_read",Int](fd, output.unsafe_ptr().unsafe_offset(buffer_offset), count, offset)
    return -1 if n > count else n


def cookie_encrypt(var key: String, nonce: Bytes, plain: Bytes) raises -> Tuple[Bytes,Bytes]:
    if "\x00" in key or key.byte_length()!=128 or len(nonce)!=12 or len(plain)>8192:
        raise Error("Invalid cookie encryption parameters")
    var output = List[UInt8](length=len(plain)+16,fill=0)
    var tag = List[UInt8](length=16,fill=0)
    var n = external_call["cookie_cipher",Int](key.as_c_string_span(),nonce.as_bytes().unsafe_ptr(),plain.as_bytes().unsafe_ptr(),len(plain),output.unsafe_ptr(),tag.unsafe_ptr(),0)
    if n<0 or n>len(output):
        raise Error("Cookie encryption failed")
    return (Bytes(Span(output)[:n]),Bytes(tag^))


def cookie_decrypt(var key: String, nonce: Bytes, cipher: Bytes, tag: Bytes) raises -> Bytes:
    if "\x00" in key or key.byte_length()!=128 or len(nonce)!=12 or len(tag)!=16 or len(cipher)>8192:
        raise Error("Invalid cookie decryption parameters")
    var output = List[UInt8](length=len(cipher)+16,fill=0)
    var n = external_call["cookie_cipher",Int](key.as_c_string_span(),nonce.as_bytes().unsafe_ptr(),cipher.as_bytes().unsafe_ptr(),len(cipher),output.unsafe_ptr(),tag.as_bytes().unsafe_ptr(),1)
    if n<0 or n>len(output):
        raise Error("Cookie authentication failed")
    return Bytes(Span(output)[:n])


def process_capture(var executable: String, args: List[String], source: Bytes, capacity: Int, timeout: Int, seekable: Bool, source_fd: Int) raises -> Bytes:
    if "\x00" in executable or capacity<0 or capacity>67108864 or timeout<=0 or source_fd < -1 or source_fd > 2147483647:
        raise Error("Invalid media process parameters")
    for arg in args:
        if "\x00" in arg:
            raise Error("NUL in media process argument")
    var wire = "\x00".join(args)+"\x00"
    var output = List[UInt8](length=capacity,fill=0)
    var size = 0
    if external_call["process_capture",Int](executable.as_c_string_span(),wire.as_bytes().unsafe_ptr(),wire.byte_length(),source.as_bytes().unsafe_ptr(),len(source),output.unsafe_ptr(),capacity,timeout,Pointer(to=size),-source_fd-1 if source_fd>=0 else Int(seekable))!=0 or size<0 or size>capacity:
        raise Error("Media processor could not read the file")
    return Bytes(Span(output)[:size])


def net_request(var url: String, var method: String, var headers: String, body: Bytes, allow_private: Bool, timeout: Int, capacity: Int) raises -> Tuple[Int,Bytes,String,String]:
    if "\x00" in url or "\x00" in method or "\x00" in headers or capacity<0 or capacity>100_000_000 or timeout<=0:
        raise Error("Invalid network parameters")
    var address = 0
    var count = 0
    var location = List[UInt8](length=8192,fill=0)
    var kind = List[UInt8](length=256,fill=0)
    var status = external_call["net_request",Int](url.as_c_string_span(),method.as_c_string_span(),headers.as_c_string_span(),body.as_bytes().unsafe_ptr(),len(body) if method!="GET" else -1,Pointer(to=address),capacity,Pointer(to=count),Int(allow_private),kind.unsafe_ptr(),location.unsafe_ptr(),timeout)
    var ptr = Pointer[UInt8,MutUntrackedOrigin](unsafe_from_address=address)
    try:
        if count<0 or count>capacity or (count>0 and address==0):
            raise Error("Invalid native network buffer")
        var data = Bytes(Span(unsafe_ptr=ptr,length=count)) if count>0 else Bytes()
        var content_type = terminated(kind)
        var redirect = terminated(location)
        external_call["free",NoneType](ptr)
        return (status,data^,content_type^,redirect^)
    except e:
        external_call["free",NoneType](ptr)
        raise e^


def image_transform_path(var path: String, width: Int, height: Int, crop: Bool, var format: String) raises -> Bytes:
    if "\x00" in path or "\x00" in format or width<1 or height<1 or width>16384 or height>16384:
        raise Error("Invalid image transform parameters")
    var address = 0
    var size = 0
    var status = external_call["image_transform_path",Int](path.as_c_string_span(),width,height,Int(crop),format.as_c_string_span(),Pointer(to=address),Pointer(to=size))
    var ptr = Pointer[UInt8,MutUntrackedOrigin](unsafe_from_address=address)
    try:
        if status!=0 or size<0 or size>100_000_000 or (size>0 and address==0):
            raise Error("Cannot decode image")
        var data = Bytes(Span(unsafe_ptr=ptr,length=size)) if size>0 else Bytes()
        external_call["buffer_free",NoneType](ptr)
        return data^
    except e:
        external_call["buffer_free",NoneType](ptr)
        raise e^


def dom_name(handle: Int) raises -> String:
    var ptr = external_call["dom_name",Pointer[UInt8,MutUntrackedOrigin]](handle)
    # Native API guarantees a non-null NUL-terminated pointer for valid and stale IDs.
    var size = external_call["strlen",Int](ptr)
    return String(from_utf8=Span(unsafe_ptr=ptr,length=size))


def dom_text(handle: Int) raises -> String:
    var ptr = external_call["dom_text",Pointer[UInt8,MutUntrackedOrigin]](handle)
    # Native API guarantees a non-null NUL-terminated pointer for valid and stale IDs.
    var size = external_call["strlen",Int](ptr)
    return String(from_utf8=Span(unsafe_ptr=ptr,length=size))


def dom_attr_name(handle: Int) raises -> String:
    var ptr = external_call["dom_attr_name",Pointer[UInt8,MutUntrackedOrigin]](handle)
    # Native API guarantees a non-null NUL-terminated pointer for valid and stale IDs.
    var size = external_call["strlen",Int](ptr)
    return String(from_utf8=Span(unsafe_ptr=ptr,length=size))


def dom_attr_text(handle: Int) raises -> String:
    var ptr = external_call["dom_attr_text",Pointer[UInt8,MutUntrackedOrigin]](handle)
    # Native API guarantees a non-null NUL-terminated pointer for valid and stale IDs.
    var size = external_call["strlen",Int](ptr)
    return String(from_utf8=Span(unsafe_ptr=ptr,length=size))


struct SqlConnection(Movable):
    var _handle: Int
    var _statements: Dict[String,Int]

    def __init__(out self, var path: String) raises:
        if "\x00" in path:
            raise Error("NUL in database path")
        self._handle = external_call["sql_open",Int](path.as_c_string_span())
        self._statements = Dict[String,Int]()
        if self._handle==0:
            raise Error("Cannot open database")

    def __deinit__(deinit self):
        for stmt in self._statements.values():
            _ = external_call["sql_finalize",Int](stmt)
        _ = external_call["sql_close",Int](self._handle)

    def error(self) raises -> String:
        var ptr = external_call["sql_error",Pointer[UInt8,MutUntrackedOrigin]](self._handle)
        var size = external_call["strlen",Int](ptr)
        return String(from_utf8=Span(unsafe_ptr=ptr,length=size))

    def last_id(self) -> Int:
        return external_call["sql_last_id",Int](self._handle)

    def rows(
        mut self, var sql: String, args: List[String] = List[String]()
    ) raises -> List[List[String]]:
        if "\x00" in sql:
            raise Error("NUL in SQL statement")
        var stmt: Int
        if sql in self._statements:
            stmt = self._statements[sql]
        else:
            stmt = external_call["sql_prepare", Int](
                self._handle, sql.as_c_string_span()
            )
            if stmt == 0:
                raise Error(self.error())
            self._statements[sql] = stmt
        _ = external_call["sql_reset",Int](stmt)
        try:
            for i in range(len(args)):
                var arg = args[i]
                if (
                    external_call["sql_bind_n", Int](
                        stmt, i + 1, arg.as_bytes().unsafe_ptr(), arg.byte_length()
                    )
                    != 0
                ):
                    raise Error("SQL bind failed")
            var result = List[List[String]]()
            var cols = external_call["sql_columns", Int](stmt)
            var status = external_call["sql_step", Int](stmt)
            while status == 100:
                var row = List[String]()
                for i in range(cols):
                    var p = external_call[
                        "sql_column", Pointer[UInt8, MutUntrackedOrigin]
                    ](stmt, i)
                    row.append(String(from_utf8=Span(unsafe_ptr=p,length=external_call["sql_bytes",Int](stmt,i))))
                result.append(row^)
                status = external_call["sql_step", Int](stmt)
            _ = external_call["sql_reset", Int](stmt)
            if status != 101:
                raise Error(self.error())
            return result^

        except e:
            _ = external_call["sql_reset",Int](stmt)
            raise e^
