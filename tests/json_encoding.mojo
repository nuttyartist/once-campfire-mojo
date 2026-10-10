from crypto import json_string
from database import Database
from runtime import read_file

def main() raises:
    var db = Database(":memory:")
    var source = read_file("build","json-strings.json",4194304).text()
    for row in db.rows("SELECT value FROM json_each(?)",[source]):
        print(json_string(row[0]))
