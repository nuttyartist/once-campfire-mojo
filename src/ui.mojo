from database import Database
from crypto import Signer
from http import Request, Response, html
from text import escape
import views
import templates
from crypto import base64


def redirect(path: String, status: Int = 303) -> Response:
    return html("", status, "Location: " + path + "\r\n")


def input(
    name: String, value: String = "", label: String = "", kind: String = "text"
) -> String:
    return (
        '<label class="flex flex-column gap">'
        + escape(label)
        + '<input class="input" name="'
        + escape(name)
        + '" type="'
        + escape(kind)
        + '" value="'
        + escape(value)
        + '" aria-label="'
        + escape(label)
        + '" placeholder="'
        + escape(label)
        + '"></label>'
    )


def textarea(name: String, value: String, label: String) -> String:
    return (
        "<label>"
        + escape(label)
        + '<textarea class="input" name="'
        + escape(name)
        + '" aria-label="'
        + escape(label)
        + '">'
        + escape(value)
        + "</textarea></label>"
    )


def form(
    path: String,
    body: String,
    method: String = "post",
    label: String = "Save changes",
) -> String:
    var override = String()
    if method != "post":
        override = (
            '<input type="hidden" name="_method" value="'
            + escape(method)
            + '">'
        )
    return (
        '<form action="'
        + escape(path)
        + '" method="post" enctype="multipart/form-data" class="flex flex-column gap">'
        + override
        + body
        + '<button type="submit" class="btn btn--reversed">'
        + escape(label)
        + "</button></form>"
    )


def page(
    mut db: Database,
    mut signer: Signer,
    uid: String,
    req: Request,
    title: String,
    body: String,
) raises -> Response:
    var v = views.context(db, signer, uid, req, title)
    v["nav"] = '<a class="btn" href="/">Back to Campfire</a>'
    v["content"] = (
        '<section class="panel flex flex-column gap"><h1>'
        + escape(title)
        + "</h1>"
        + body
        + "</section>"
    )
    return html(views.layout(v, req))


def stream(action: String, target: String, body: String = "") -> String:
    return (
        '<turbo-stream action="'
        + action
        + '" target="'
        + escape(target)
        + '"><template>'
        + body
        + "</template></turbo-stream>"
    )


def icon(name: String, size: Int = 20) raises -> String:
    return (
        '<img src="'
        + templates.asset(name + ".svg")
        + '" aria-hidden="true" class="colorize--black" width="'
        + String(size)
        + '" height="'
        + String(size)
        + '">'
    )


def share_link(url: String, invite: Bool = False) raises -> String:
    var label = "join link" if invite else "auto-login link"
    return (
        '<div class="flex align-center center gap"><a class="btn" href="/qr_code/'
        + base64(url, True, False)
        + '">'
        + icon("qr-code")
        + '<span class="for-screen-reader">Show '
        + ("join link" if invite else "auto-login")
        + ' QR code</span></a><button class="btn" data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" data-copy-to-clipboard-success-class="btn--success" data-copy-to-clipboard-url-value="'
        + escape(url)
        + '">'
        + icon("copy-paste")
        + '<span class="for-screen-reader">Copy '
        + label
        + '</span></button><button class="btn" data-controller="web-share" data-action="web-share#share" data-web-share-url-value="'
        + escape(url)
        + '" data-web-share-title-value="'
        + ("Link to join Campfire" if invite else "Your sign-in link")
        + '">'
        + icon("share")
        + '<span class="for-screen-reader">Share '
        + label
        + "</span></button></div>"
    )


def field(
    name: String,
    value: String,
    label: String,
    glyph: String,
    kind: String = "text",
    extra: String = "",
) raises -> String:
    var id = name.replace("[", "_").replace("]", "")
    return (
        '<div class="flex align-center gap"><label class="flex align-center gap flex-item-grow input input--actor"><span class="for-screen-reader">'
        + escape(label)
        + '</span><input id="'
        + escape(id)
        + '" class="input txt-large" name="'
        + escape(name)
        + '" type="'
        + escape(kind)
        + '" value="'
        + escape(value)
        + '" placeholder="'
        + escape(label)
        + '" '
        + extra
        + ">"
        + icon(glyph, 24)
        + "</label></div>"
    )


def avatar_upload(name: String, url: String, label: String) raises -> String:
    return (
        '<label class="align-center center avatar__form gap" data-controller="upload-preview"><span class="btn input--file">'
        + icon("camera")
        + '<input class="input" type="file" name="'
        + escape(name)
        + '" accept="image/*" data-upload-preview-target="input" data-action="upload-preview#previewImage"><span class="for-screen-reader">'
        + escape(label)
        + '</span></span><span class="avatar input--file txt-xx-large"><img src="'
        + escape(url)
        + '" width="300" height="300" alt="Avatar" data-upload-preview-target="image"></span></label>'
    )
