# Owned binary data. Text decoding is always explicit and validates UTF-8.
struct Bytes(Copyable, ImplicitlyCopyable, Movable, Sized):
    var data: List[UInt8]

    def __init__(out self):
        self.data = List[UInt8]()

    def __init__(out self, *, copy: Self):
        self.data = copy.data.copy()

    @implicit
    def __init__(out self, text: String):
        self.data = List[UInt8]()
        self.data.extend(text.as_bytes())

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    def __init__[origin: Origin](out self, data: Span[UInt8, origin]):
        self.data = List[UInt8]()
        self.data.extend(data)

    def byte_length(self) -> Int:
        return len(self.data)

    def __len__(self) -> Int:
        return len(self.data)

    def as_bytes(self) -> Span[UInt8, origin_of(self.data)]:
        return Span(self.data)

    def text(self) raises -> String:
        try:
            return String(from_utf8=self.as_bytes())
        except:
            raise Error("Invalid UTF-8")

    def slice(self, start: Int = 0, end: Int = -1) raises -> Self:
        var stop = len(self.data) if end == -1 else end
        if start < 0 or stop < start or stop > len(self.data):
            raise Error("Invalid byte range")
        return Self(self.as_bytes()[start:stop])

    def __add__(self, other: Self) -> Self:
        var result = self.copy()
        result += other
        return result^

    def __radd__(self, other: String) -> Self:
        return Self(other) + self

    def __iadd__(mut self, other: Self):
        self.data.extend(other.as_bytes())

    def __eq__(self, other: Self) -> Bool:
        if len(self.data) != len(other.data):
            return False
        for i in range(len(self.data)):
            if self.data[i] != other.data[i]:
                return False
        return True

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def startswith(self, needle: Self) -> Bool:
        if len(needle) > len(self):
            return False
        for i in range(len(needle)):
            if self.data[i] != needle.data[i]:
                return False
        return True

    def endswith(self, needle: Self) -> Bool:
        if len(needle) > len(self):
            return False
        for i in range(len(needle)):
            if self.data[len(self) - len(needle) + i] != needle.data[i]:
                return False
        return True

    def find(self, needle: Self, start: Int = 0) -> Int:
        if start < 0 or start > len(self):
            return -1
        for i in range(start, len(self) - len(needle) + 1):
            var matches = True
            for j in range(len(needle)):
                if self.data[i + j] != needle.data[j]:
                    matches = False
                    break
            if matches:
                return i
        return -1

    def split(self, needle: Self, maxsplit: Int = -1) raises -> List[Self]:
        if len(needle) == 0:
            raise Error("Empty byte separator")
        var result = List[Self]()
        var start = 0
        while maxsplit < 0 or len(result) < maxsplit:
            var end = self.find(needle, start)
            if end < 0:
                break
            result.append(self.slice(start, end))
            start = end + len(needle)
        result.append(self.slice(start))
        return result^
