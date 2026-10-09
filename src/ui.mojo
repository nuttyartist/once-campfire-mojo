from database import Database
from crypto import Signer
from http import Request, Response, html
from text import escape
import views


def redirect(path: String, status: Int = 303) -> Response:
    return html("",status,"Location: "+path+"\r\n")


def input(name: String, value: String = "", label: String = "", kind: String = "text") -> String:
    return '<label class="flex flex-column gap">'+escape(label)+'<input class="input" name="'+escape(name)+'" type="'+escape(kind)+'" value="'+escape(value)+'" aria-label="'+escape(label)+'" placeholder="'+escape(label)+'"></label>'


def textarea(name: String, value: String, label: String) -> String:
    return '<label>'+escape(label)+'<textarea class="input" name="'+escape(name)+'" aria-label="'+escape(label)+'">'+escape(value)+'</textarea></label>'


def form(path: String, body: String, method: String = "post", label: String = "Save changes") -> String:
    var override = String()
    if method != "post":
        override = '<input type="hidden" name="_method" value="'+escape(method)+'">'
    return '<form action="'+escape(path)+'" method="post" enctype="multipart/form-data" class="flex flex-column gap">'+override+body+'<button type="submit" class="btn btn--reversed">'+escape(label)+'</button></form>'


def page(mut db: Database, mut signer: Signer, uid: String, req: Request, title: String, body: String) raises -> Response:
    var v = views.context(db,signer,uid,req,title)
    v["nav"] = '<a class="btn" href="/">Back to Campfire</a>'
    v["content"] = '<section class="panel flex flex-column gap"><h1>'+escape(title)+'</h1>'+body+'</section>'
    return html(views.layout(v,req))


def stream(action: String, target: String, body: String = "") -> String:
    return '<turbo-stream action="'+action+'" target="'+escape(target)+'"><template>'+body+'</template></turbo-stream>'
