#!/usr/bin/env python3
"""Generate the checked-in schema contract from a pinned original Rails checkout."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("rails", type=Path)
args = parser.parse_args()
revision = subprocess.check_output(["git", "-C", str(args.rails), "rev-parse", "HEAD"], text=True).strip()
source = (args.rails / "db/schema.rb").read_text()
tables = {}
for table, body in re.findall(r'create_table "([^"]+)"[^\n]+\n(.*?)^  end$', source, re.M | re.S):
    tables[table] = ["id"] + re.findall(r'^    t\.(?!index\b)\w+ "([^"]+)"', body, re.M)
tables["message_search_index"] = ["body"]
versions = sorted(path.name.split("_", 1)[0] for path in (args.rails / "db/migrate").glob("*.rb"))
contract = {"rails_revision": revision, "schema_sha256": hashlib.sha256(source.encode()).hexdigest(), "maximum_rails_version": versions[-1], "versions": versions, "tables": tables, "upgradable_columns": {"rooms": ["messages_count"]}}
counter_source = (args.rails / "app/models/room/messages_count.rb").read_text()
names = dict(re.findall(r'(\w+_TRIGGER) = "([^"]+)"', counter_source))
contract["message_count_triggers"] = {
    names[name]: " ".join(body.split())
    for name, body in re.findall(r'CREATE TRIGGER #\{(\w+_TRIGGER)\} (.*?)\n\s*SQL', counter_source, re.S)
}
assert len(contract["message_count_triggers"]) == 3
assert len(tables) == 16, len(tables)
def atomic_write(path, value):
    temporary = path.with_suffix(path.suffix+".tmp")
    temporary.write_text(value)
    temporary.replace(path)
atomic_write(root / "tools/schema_contract.json", json.dumps(contract, indent=2) + "\n")
code = '''# Generated from the original db/schema.rb by tools/update_schema_contract.py.
from database import Database


def validate(mut db: Database, allow_upgrade: Bool = True) raises:
    if db.scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")=="0":
        return
    if db.scalar("SELECT 1 FROM sqlite_master WHERE type='table' AND name='schema_migrations'")=="1":
        var version = db.scalar("SELECT coalesce(max(version),'0') FROM schema_migrations")
        if version>"MAXIMUM":
            raise Error("Unsupported newer Rails schema; upgrade the Mojo application before opening this database")
    var tables = List[Tuple[String,String]]([
TABLES
    ])
    for table in tables:
        var present = Dict[String,Bool]()
        for column in db.rows("PRAGMA table_info("+table[0]+")"):
            present[column[1]] = True
        for column in table[1].split(","):
            var name = String(column)
            if name not in present and not (allow_upgrade and table[0]=="rooms" and name=="messages_count"):
                raise Error("Unsupported Campfire schema: missing "+table[0]+"."+name+"; upgrade the source with Rails first")
'''.replace("MAXIMUM", versions[-1]).replace("TABLES", "\n".join("        (" + json.dumps(table) + "," + json.dumps(",".join(columns)) + ")," for table, columns in tables.items()))
atomic_write(root / "src/schema_contract.mojo", code)
