from database import Database
from crypto import Signer, base64
from runtime import read_file, digest
import marshal
import opengraph


def main() raises:
    var db = Database(":memory:")
    if db.scalar("SELECT CASE WHEN ?='' AND ?='value' AND ?='' THEN 'ok' ELSE 'bad' END",["","value",""])!="ok":
        raise Error("Empty SQL string binding differs from NULL")
    var vectors = read_file("/workspace/once-campfire-rust/vectors","storage.json")
    var rows = db.rows("SELECT json_extract(value,'$.decoded_inspect'),json_extract(value,'$.key'),json_extract(value,'$.decoded_digest') FROM json_each(?,'$.variations')",[vectors])
    # Independently generated Ruby Marshal vectors. Use the serialized verifier
    # data rather than hardcoding our own transformation output as expectations.
    from crypto import unbase64
    for row in rows:
        var signed = row[1].split("--",maxsplit=1)
        var envelope = unbase64(String(signed[0]))
        var source = db.scalar("SELECT json_extract(?,'$._rails.data')",[envelope])
        if source=="":
            source = unbase64(db.scalar("SELECT json_extract(?,'$._rails.message')",[envelope]))
        var actual = base64(digest(marshal.dump(db,source),False))
        if actual!=row[2]:
            raise Error("Ruby variant digest differs: "+row[0]+" actual="+actual+" expected="+row[2])
    var meta = opengraph.document('<html><head><meta property="og:title" content="A &amp; B"><meta name="og:description" content="Description"><meta property="og:title" content="Last wins"></head></html>')
    if meta.get("title","")!="Last wins" or meta.get("description","")!="Description":
        raise Error("OpenGraph metadata differs")
    var rails = read_file("/workspace/once-campfire-rust/vectors","rails_compat.json")
    var signer = Signer(db.scalar("SELECT json_extract(?,'$.secret_key_base')",[rails]))
    for row in db.rows("SELECT json_extract(value,'$.case'),json_extract(value,'$.sgid'),json_extract(value,'$.purpose'),json_extract(value,'$.now'),json_extract(value,'$.expected') FROM json_each(?,'$.sgids.verify')",[rails]):
        signer.clock = row[3]
        if signer.verify(db,"signed_global_ids",row[1],row[2],False)!=row[4]:
            raise Error("Rails SGID verification differs: "+row[0])
    for row in db.rows("SELECT json_extract(value,'$.case'),json_extract(value,'$.name'),json_extract(value,'$.message'),json_extract(value,'$.purpose'),json_extract(value,'$.now'),json_extract(value,'$.expected_json') FROM json_each(?,'$.app_verifiers.verify')",[rails]):
        signer.clock = row[4]
        var expected = db.scalar("SELECT json_extract(?,'$')",[row[5]]) if row[5]!="" else String()
        if signer.verify(db,row[1],row[2],row[3],False)!=expected:
            raise Error("Rails app verifier differs: "+row[0])
    for row in db.rows("SELECT json_extract(value,'$.case'),json_extract(value,'$.model'),json_extract(value,'$.signed_id'),coalesce(json_extract(value,'$.purpose'),''),json_extract(value,'$.now'),json_extract(value,'$.expected') FROM json_each(?,'$.signed_ids.verify')",[rails]):
        signer.clock = row[4]
        var purpose = row[1].lower()+("/"+row[3] if row[3]!="" else "")
        if signer.verify(db,"active_record/signed_id",row[2],purpose)!=row[5]:
            raise Error("Rails signed ID differs: "+row[0])
    print("PASS: Ruby variant digests, 70 Rails signature/purpose/expiry vectors, and HTML5 OpenGraph metadata")
