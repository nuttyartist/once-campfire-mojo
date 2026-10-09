from std.ffi import external_call
from database import Database, c_text
from crypto import json_string
from http import Response, html
import network
import richtext


def collect(node: Int, mut values: Dict[String,String], depth: Int = 0) raises:
    if depth>128:
        raise Error("Metadata nesting too deep")
    var current = node
    while current!=0:
        if c_text["dom_name"](current)=="meta":
            var attrs = richtext.attributes(current)
            var name = attrs.get("property",attrs.get("name",""))
            if name in ["og:title","og:url","og:image","og:description"] and attrs.get("content","")!="":
                values[String(name[byte=3:])] = attrs["content"]
        collect(external_call["dom_child",Int](current),values,depth+1)
        current = external_call["dom_next",Int](current)


def document(var source: String) raises -> Dict[String,String]:
    var doc = external_call["dom_parse",Int](source.as_c_string_span(),source.byte_length())
    if doc==0:
        raise Error("Invalid HTML document")
    try:
        var values = Dict[String,String]()
        collect(external_call["dom_root",Int](doc),values)
        external_call["dom_free",NoneType](doc)
        return values^
    except e:
        external_call["dom_free",NoneType](doc)
        raise e^


def fetch(var url: String, method: String, deadline: Int) raises -> network.Reply:
    for _ in range(10):
        var remaining = deadline-external_call["os_now_ms",Int]()
        if remaining<=0:
            return network.Reply(-3,"","","")
        var result = network.request(url,method,"User-Agent: Campfire link preview", "",False,remaining,5242880)
        if result.status>=300 and result.status<400 and result.location!="":
            url = result.location
        else:
            return result^
    return network.Reply(-3,"","","")


def unfurl(url: String) raises -> Response:
    if url=="":
        return html("URL required",400)
    var deadline = external_call["os_now_ms",Int]()+10000
    var path = network.component(url,2).lower()
    for extension in ["zip","tar","gz","bz2","xz","rar","7z","dmg","exe","msi","pkg","deb","iso","jpg","jpeg","png","gif","bmp","mp4","mov","avi","mkv","wmv","flv","heic","heif","mp3","wav","ogg","aac","wma","webm","ogv","mpg","mpeg"]:
        if path.endswith("."+extension):
            return html("",204)
    var target = url
    var host = network.component(url).lower()
    if host in ["twitter.com","www.twitter.com","x.com","www.x.com"] and path!="/":
        target = url.replace(host,"fxtwitter.com")
    var response = fetch(target,"GET",deadline)
    if response.status!=200 or String(response.content_type.split(";")[0]).lower()!="text/html":
        return html("",204)
    var values = document(response.body)
    var title = richtext.convert(values.get("title",""),True)
    var description = richtext.convert(values.get("description",""),True)
    if title=="" or description=="":
        return html("",204)
    var canonical = values.get("url","")
    if canonical=="" or external_call["os_now_ms",Int]()>=deadline or not network.validate(canonical):
        canonical = url
    var image = values.get("image","")
    if image!="":
        var check = fetch(image,"HEAD",deadline)
        if check.status!=200 or check.content_type.lower() not in ["image/jpeg","image/png","image/gif","image/webp"]:
            image = ""
    if external_call["os_now_ms",Int]()>deadline:
        return html("",204)
    return Response(200,'{"title":'+json_string(title)+',"url":'+json_string(canonical)+',"image":'+(json_string(image) if image!="" else String("null"))+',"description":'+json_string(description)+'}',"application/json","")
