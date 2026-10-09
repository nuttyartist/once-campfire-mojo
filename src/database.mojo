from std.ffi import external_call
from std.os import getenv
from file_transfer import FileTransfer


def c_text[callee: StaticString](handle: Int) -> String:
    var p = external_call[callee, Pointer[UInt8, MutUntrackedOrigin]](handle)
    return String(unsafe_from_utf8_ptr=p)


struct Database(Movable):
    var handle: Int
    var request_host: String
    var pending_download: FileTransfer
    var pending_deletes: List[String]
    var pending_files: List[String]
    var pending_events: List[String]
    var statements: Dict[String, Int]

    def __init__(out self, var path: String) raises:
        self.handle = external_call["sql_open", Int](path.as_c_string_span())
        self.request_host = ""
        self.pending_download = FileTransfer()
        self.pending_deletes = List[String]()
        self.pending_files = List[String]()
        self.pending_events = List[String]()
        self.statements = Dict[String, Int]()
        if self.handle == 0:
            raise Error("Cannot open database")
        _ = self.rows("PRAGMA journal_mode=WAL")
        var durability = getenv("CAMPFIRE_SQLITE_SYNCHRONOUS","FULL")
        if durability!="FULL" and durability!="NORMAL":
            raise Error("Invalid CAMPFIRE_SQLITE_SYNCHRONOUS")
        _ = self.rows("PRAGMA synchronous="+durability)
        _ = self.rows("PRAGMA foreign_keys=ON")

    def __deinit__(deinit self):
        if self.pending_download.fd>=0:
            _ = external_call["os_close",Int](self.pending_download.fd)
        for stmt in self.statements.values():
            _ = external_call["sql_finalize", Int](stmt)
        _ = external_call["sql_close", Int](self.handle)

    def rows(
        mut self, var sql: String, args: List[String] = List[String]()
    ) raises -> List[List[String]]:
        var stmt: Int
        if sql in self.statements:
            stmt = self.statements[sql]
        else:
            stmt = external_call["sql_prepare", Int](
                self.handle, sql.as_c_string_span()
            )
            if stmt == 0:
                raise Error(c_text["sql_error"](self.handle))
            self.statements[sql] = stmt
        _ = external_call["sql_reset", Int](stmt)
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
                row.append(String(unsafe_from_utf8=Span(unsafe_ptr=p,length=external_call["sql_bytes",Int](stmt,i))))
            result.append(row^)
            status = external_call["sql_step", Int](stmt)
        _ = external_call["sql_reset", Int](stmt)
        if status != 101:
            raise Error(c_text["sql_error"](self.handle))
        return result^

    def scalar(
        mut self, sql: String, args: List[String] = List[String]()
    ) raises -> String:
        var rows = self.rows(sql, args)
        if len(rows) == 0:
            return ""
        return rows[0][0]

    def last_id(self) -> String:
        return String(external_call["sql_last_id", Int](self.handle))
