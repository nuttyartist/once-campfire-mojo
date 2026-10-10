import native_boundary as native
from byte_buffer import Bytes
from std.os import getenv
from file_transfer import FileTransfer


struct Database(Movable):
    var connection: native.SqlConnection
    var request_host: String
    var pending_download: FileTransfer
    var pending_deletes: List[String]
    var pending_files: List[String]
    var pending_events: List[String]
    # Request-owned immutable file plans; SQL admission remains atomic.
    var preparing_media: Bool
    var prepared_blobs: Dict[String, List[String]]
    var prepared_variants: Dict[String, String]
    var prepared_previews: Dict[String, String]

    def __init__(out self, var path: String) raises:
        self.connection = native.SqlConnection(path)
        self.request_host = ""
        self.pending_download = FileTransfer()
        self.pending_deletes = List[String]()
        self.pending_files = List[String]()
        self.pending_events = List[String]()
        self.preparing_media = False
        self.prepared_blobs = Dict[String, List[String]]()
        self.prepared_variants = Dict[String, String]()
        self.prepared_previews = Dict[String, String]()
        _ = self.rows("PRAGMA journal_mode=WAL")
        var durability = getenv("CAMPFIRE_SQLITE_SYNCHRONOUS", "FULL")
        if durability != "FULL" and durability != "NORMAL":
            raise Error("Invalid CAMPFIRE_SQLITE_SYNCHRONOUS")
        _ = self.rows("PRAGMA synchronous=" + durability)
        _ = self.rows("PRAGMA foreign_keys=ON")
        _ = self.rows("PRAGMA recursive_triggers=ON")

    def __deinit__(deinit self):
        if self.pending_download.fd >= 0:
            _ = native.os_close(self.pending_download.fd)

    def rows(
        mut self, sql: String, args: List[String] = List[String]()
    ) raises -> List[List[String]]:
        return self.connection.rows(sql, args)

    def scalar(
        mut self, sql: String, args: List[String] = List[String]()
    ) raises -> String:
        var rows = self.rows(sql, args)
        if len(rows) == 0:
            return ""
        return rows[0][0]

    def last_id(self) -> String:
        return String(self.connection.last_id())
