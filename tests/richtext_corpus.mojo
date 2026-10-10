from database import Database
from crypto import Signer, json_string
from runtime import read_file
import schema
import richtext
from std.os import getenv


def main() raises:
    var db = Database(":memory:")
    schema.initialize(db)
    var signer = Signer()
    var corpus = read_file(getenv("RICHTEXT_CORPUS_DIR","tests/corpus"),"expected.json",16777216).text()
    var replacements = Dict[String,String]()
    var users = db.rows("SELECT json_extract(value,'$.id'),json_extract(value,'$.name'),json_extract(value,'$.avatar_path'),json_extract(value,'$.attachable_sgid'),json_extract(value,'$.title') FROM json_each(?,'$.users')",[corpus])
    for user in users:
        _ = db.rows("INSERT INTO users(id,name,created_at,updated_at) VALUES(?,?,'2024-01-02 03:04:05','2024-01-02 03:04:05')",[user[0],user[1]])
        if user[4].startswith(user[1]+" – "):
            _ = db.rows("UPDATE users SET bio=? WHERE id=?",[String(user[4][byte=user[1].byte_length()+5:]),user[0]])
        replacements[user[2]] = signer.avatar(user[0],"20240102030405")
    var signed = db.rows("SELECT json_extract(value,'$.sgid'),json_extract(value,'$.model'),json_extract(value,'$.id') FROM json_each(?,'$.signed')",[corpus])
    for item in signed:
        replacements[item[0]] = signer.envelope("signed_global_ids",json_string("gid://campfire/"+item[1]+"/"+item[2]+"?expires_in"),"attachable","",True)
    for user in users:
        replacements[user[3]] = signer.envelope("signed_global_ids",json_string("gid://campfire/User/"+user[0]+"?expires_in"),"attachable","",True)
    var cases = db.rows("SELECT value,json_extract(value,'$.name'),json_extract(value,'$.body'),json_extract(value,'$.host') FROM json_each(?,'$.cases')",[corpus])
    for item in cases:
        var source = item[2]
        var expected = item[0]
        for key in replacements.keys():
            source = source.replace(key,replacements[key])
            # JSON strings contain quotes but signatures/paths do not.
            expected = expected.replace(key,replacements[key])
        db.request_host = item[3]
        var result = String()
        try:
            result = '{"ok":'+json_string(richtext.resolved(db,signer,source,True))+'}'
        except e:
            result = '{"error":'+json_string(String(e))+'}'
        var rendered = String()
        try:
            rendered = '{"ok":'+json_string('<div class="lexxy-content">\n  '+richtext.resolved(db,signer,source)+'\n</div>\n')+'}'
        except e:
            rendered = '{"error":'+json_string(String(e))+'}'
        var mentions = String()
        try:
            mentions = '{"ok":['+",".join(richtext.mention_ids(db,signer,source))+']}'
        except e:
            mentions = '{"error":'+json_string(String(e))+'}'
        var body_html = String()
        try:
            body_html = '{"ok":'+json_string(richtext.body_html(db,signer,source))+'}'
        except e:
            body_html = '{"error":'+json_string(String(e))+'}'
        var edited = String()
        try:
            edited = '{"ok":'+json_string(richtext.editable(db,signer,source))+'}'
        except e:
            edited = '{"error":'+json_string(String(e))+'}'
        print('{"case":'+expected+',"actual_plain":'+result+',"actual_html":'+rendered+',"actual_mentions":'+mentions+',"actual_editable":'+edited+',"actual_body_html":'+body_html+'}')
    for item in db.rows("SELECT value,json_extract(value,'$.value'),json_extract(value,'$.host') FROM json_each(?,'$.web_urls')",[corpus]):
        var result = String()
        try:
            var url = richtext.web_url(item[1],item[2])
            result = '{"ok":'+(json_string(url) if url!="" else "null")+'}'
        except e:
            result = '{"error":'+json_string(String(e))+'}'
        print('{"web_url":'+item[0]+',"actual":'+result+'}')
