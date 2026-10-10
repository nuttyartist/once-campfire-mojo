import native_boundary as native
from database import Database
from crypto import json_string
from http import Response, html
import network
import richtext


def collect(node: Int, mut values: Dict[String,String], depth: Int = 0) raises:
    if depth>128:
        raise Error("Metadata nesting too deep")
    var current = node
    while current!=0:
        if native.dom_name(current)=="meta":
            var attrs = richtext.attributes(current)
            var name = attrs.get("property",attrs.get("name",""))
            if name in ["og:title","og:url","og:image","og:description"] and attrs.get("content","")!="":
                values[String(name[byte=3:])] = attrs["content"]
        collect(native.dom_child(current),values,depth+1)
        current = native.dom_next(current)


def document(var source: String) raises -> Dict[String,String]:
    var doc = native.dom_parse(source.as_bytes(), source.byte_length())
    if doc==0:
        raise Error("Invalid HTML document")
    try:
        var values = Dict[String,String]()
        collect(native.dom_root(doc),values)
        native.dom_free(doc)
        return values^
    except e:
        native.dom_free(doc)
        raise e^


def fetch(var url: String, method: String, deadline: Int) raises -> network.Reply:
    for _ in range(10):
        var remaining = deadline-native.os_now_ms()
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
    var deadline = native.os_now_ms()+10000
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
    var values = document(response.body.text())
    var title = richtext.convert(values.get("title",""),True)
    var description = richtext.convert(values.get("description",""),True)
    if title=="" or description=="":
        return html("",204)
    var canonical = values.get("url","")
    if canonical=="" or native.os_now_ms()>=deadline or not network.validate(canonical):
        canonical = url
    var image = values.get("image","")
    if image!="":
        var check = fetch(image,"HEAD",deadline)
        if check.status!=200 or check.content_type.lower() not in ["image/jpeg","image/png","image/gif","image/webp"]:
            image = ""
    if native.os_now_ms()>deadline:
        return html("",204)
    return Response(200,'{"title":'+json_string(title)+',"url":'+json_string(canonical)+',"image":'+(json_string(image) if image!="" else String("null"))+',"description":'+json_string(description)+'}',"application/json","")
