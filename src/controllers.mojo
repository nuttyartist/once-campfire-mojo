from std.ffi import external_call
from database import Database
from crypto import Signer, json_string, url_encode, unbase64
from http import Request, Response, html
from parameters import Form
from text import escape, params
import accounts
import rooms
import message_actions
import ui
import runtime
import jobs
import storage
import opengraph
import webpush
import network


def route(mut db: Database, mut signer: Signer, req: Request, uid: String, f: Form) raises -> Response:
    if req.path=="/unfurl_link" and req.method=="POST":
        return opengraph.unfurl(f.fields.get("url",""))
    var response = accounts.route(db,signer,req,uid,f)
    if response.status != 0:
        return response^
    response = rooms.route(db,signer,req,uid,f)
    if response.status != 0:
        return response^
    response = message_actions.route(db,signer,req,uid,f)
    if response.status != 0:
        return response^
    if req.path=="/searches" and req.method=="POST":
        var query = f.fields.get("q","")
        if String(query.strip())!="":
            var now = accounts.stamp(db)
            _ = db.rows("DELETE FROM searches WHERE user_id=? AND query=?",[uid,query])
            _ = db.rows("INSERT INTO searches(user_id,query,created_at,updated_at) VALUES(?,?,?,?)",[uid,query,now,now])
        return ui.redirect("/searches?q="+url_encode(query))
    if req.path=="/searches/clear" and req.method=="DELETE":
        _ = db.rows("DELETE FROM searches WHERE user_id=?",[uid])
        return ui.redirect("/searches")
    if req.path.startswith("/users/me/push_subscriptions"):
        var parts = req.path.split("/")
        if len(parts)==6 and String(parts[5])=="test_notifications" and req.method=="POST":
            var sub = db.rows("SELECT id,endpoint,p256dh_key,auth_key FROM push_subscriptions WHERE id=? AND user_id=?",[String(parts[4]),uid])
            if len(sub)==0:
                return html("Not found",404)
            webpush.deliver(db,sub[0][0],sub[0][1],sub[0][2],sub[0][3],'{"title":"Campfire Test","body":'+json_string(accounts.stamp(db))+',"path":'+json_string(req.origin()+"/users/me/push_subscriptions")+'}')
            return ui.redirect("/users/me/push_subscriptions")
        if req.method=="POST":
            var endpoint = f.fields.get("push_subscription[endpoint]","")
            if not jobs.push_endpoint_permitted(endpoint):
                return html("Invalid push endpoint",422)
            var key = f.fields.get("push_subscription[p256dh_key]","")
            var auth = f.fields.get("push_subscription[auth_key]","")
            if unbase64(key).byte_length()!=65 or unbase64(auth).byte_length()!=16 or not network.validate(endpoint):
                return html("Invalid push subscription",422)
            var now = accounts.stamp(db)
            var id = db.scalar("SELECT id FROM push_subscriptions WHERE user_id=? AND endpoint=? AND p256dh_key=? AND auth_key=?",[uid,endpoint,key,auth])
            if id=="":
                _ = db.rows("INSERT INTO push_subscriptions(user_id,endpoint,p256dh_key,auth_key,user_agent,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",[uid,endpoint,key,auth,req.header("user-agent"),now,now])
            else:
                _ = db.rows("UPDATE push_subscriptions SET updated_at=? WHERE id=?",[now,id])
            return html("")
        if req.method=="DELETE":
            var segments = req.path.split("/")
            if len(segments)!=5:
                return html("Not found",404)
            _ = db.rows("DELETE FROM push_subscriptions WHERE id=? AND user_id=?",[String(segments[4]),uid])
            return ui.redirect("/users/me/push_subscriptions")
        var subscriptions = db.rows("SELECT id,endpoint FROM push_subscriptions WHERE user_id=?",[uid])
        var body = String()
        for sub in subscriptions:
            body += ui.form("/users/me/push_subscriptions/"+sub[0],escape(sub[1]),"delete","Remove subscription")
        return ui.page(db,signer,uid,req,"Push subscriptions",body)
    return html("",0)


def public(mut db: Database, mut signer: Signer, req: Request, f: Form) raises -> Response:
    if req.path=="/first_run" or req.path.startswith("/join/"):
        return accounts.signup(db,signer,req,f,req.path=="/first_run")
    if req.path.startswith("/session/transfers/"):
        return accounts.transfer(db,signer,req)
    if req.path.startswith("/qr_code/"):
        var text = unbase64(String(req.path[byte=9:]))
        var qr = List[UInt8](length=3918,fill=0)
        var size = external_call["qr_encode",Int](text.as_c_string_span(),qr.unsafe_ptr())
        if size<0:
            return html("Invalid QR content",400)
        var paths = String()
        for y in range(size):
            for x in range(size):
                if external_call["qr_module",Int](qr.unsafe_ptr(),x,y):
                    paths += "M"+String(x+4)+" "+String(y+4)+"h1v1h-1z "
        return Response(200,'<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 '+String(size+8)+' '+String(size+8)+'"><rect width="100%" height="100%" fill="white"/><path d="'+paths+'" fill="black"/></svg>',"image/svg+xml","")
    if req.path=="/webmanifest" or req.path=="/webmanifest.json":
        var name = db.scalar("SELECT name FROM accounts LIMIT 1")
        return Response(200,'{"name":'+json_string(name)+',"short_name":'+json_string(name)+',"start_url":"/","display":"standalone","icons":[{"src":"/account/logo","sizes":"any","type":"image/svg+xml"}]}',"application/manifest+json","")
    if req.path=="/service-worker" or req.path=="/service-worker.js":
        return Response(200,runtime.read_file("public","service-worker.js"),"text/javascript; charset=utf-8","Service-Worker-Allowed: /\r\n")
    if req.path=="/account/logo" and req.method=="GET":
        var blob = db.scalar("SELECT blob_id FROM active_storage_attachments WHERE record_type='Account' AND name='logo' LIMIT 1")
        if blob!="":
            return storage.image(db,blob,req,512,512,True)
        return Response(200,'<svg xmlns="http://www.w3.org/2000/svg" width="300" height="300" viewBox="0 0 300 300"><rect width="300" height="300" rx="50" fill="#f77f32"/><text x="150" y="205" text-anchor="middle" font-size="170" fill="white">C</text></svg>',"image/svg+xml","")
    var segments = req.path.split("/")
    if len(segments)==4 and String(segments[1])=="users" and String(segments[3])=="avatar" and req.method=="GET":
        var uid = signer.verify(db,"active_record/signed_id",String(segments[2]),"user/avatar")
        var name = db.scalar("SELECT name FROM users WHERE id=?",[uid])
        if name=="":
            return html("Avatar not found",404)
        var blob = db.scalar("SELECT blob_id FROM active_storage_attachments WHERE record_type='User' AND name='avatar' AND record_id=? LIMIT 1",[uid])
        if blob!="":
            return storage.image(db,blob,req,300,300,True)
        var initials = String()
        for part in name.split():
            for c in String(part).codepoints():
                initials += String(c).upper()
                break
        return Response(200,'<svg xmlns="http://www.w3.org/2000/svg" width="300" height="300" viewBox="0 0 300 300"><rect width="300" height="300" rx="30" fill="#eee"/><text x="150" y="180" text-anchor="middle" font-family="sans-serif" font-size="100">'+escape(initials)+'</text></svg>',"image/svg+xml","")
    return html("",0)
