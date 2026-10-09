from text import escape, plain_text


def page(title: String, body: String) -> String:
    return (
        '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta'
        ' name="viewport" content="width=device-width,initial-scale=1"><title>'
        + escape(title)
        + '</title><link rel="stylesheet"'
        ' href="/assets/campfire.css"></head><body><header><a'
        ' href="/">Campfire • Mojo</a><form action="/searches"><input'
        ' name="q" placeholder="Search'
        ' messages"><button>Search</button></form></header><main>'
        + body
        + "</main></body></html>"
    )


def message(row: List[String]) -> String:
    # id, client_message_id, created_at, creator_id, name, room_id, room_name, plain body
    var link = "/rooms/" + row[5] + "#message_" + escape(row[1])
    return (
        '<div id="message_'
        + escape(row[1])
        + '" class="message" data-message-id="'
        + row[0]
        + '" data-client-message-id="'
        + escape(row[1])
        + '"><turbo-frame id="edit_message_'
        + row[0]
        + '"><h2 class="message__day-separator">'
        + escape(row[2])
        + '</h2><div class="message__body"><div'
        ' class="message__meta"><h3><strong data-reply-target="author">'
        + escape(row[4])
        + '</strong> <a class="message__permalink" href="'
        + link
        + '"><time>'
        + escape(row[2])
        + '</time></a> <span class="message__room">'
        + escape(row[6])
        + '</span></h3></div><div id="presentation_message_'
        + row[0]
        + '" class="message__body-content"><div class="trix-content">'
        + escape(plain_text(row[7])).replace("\n", "<br>")
        + "</div></div></div></turbo-frame></div>"
    )


def messages(rows: List[List[String]]) -> String:
    var out = String()
    for row in rows:
        out += message(row)
    return out^


def room(
    name: String, room_id: String, kind: String, rows: List[List[String]]
) -> String:
    return page(
        name,
        '<nav><a href="/users/me/sidebar">Rooms</a></nav><h1>'
        + escape(name)
        + '</h1><section id="messages_'
        + kind
        + "_"
        + room_id
        + '">'
        + messages(rows)
        + '</section><form method="post" action="/rooms/'
        + room_id
        + '/messages"><textarea name="message[body]"'
        " required></textarea><button>Send</button></form>",
    )


def sidebar(rows: List[List[String]]) -> String:
    var out = String('<h1>Rooms</h1><ul id="shared_rooms">')
    for row in rows:
        out += (
            '<li id="room_'
            + row[0]
            + '"><a href="/rooms/'
            + row[0]
            + '">'
            + escape(row[1])
            + "</a>"
            + (" <span>Unread</span>" if row[2] != "" else "")
            + "</li>"
        )
    return page("Rooms", out + "</ul>")


def login() -> String:
    return page(
        "Sign in",
        (
            '<h1>Sign in</h1><form method="post" action="/session"><label>Email'
            ' <input type="email" name="email_address"'
            ' required></label><label>Password <input type="password"'
            ' name="password" required></label><button>Sign in</button></form>'
        ),
    )
