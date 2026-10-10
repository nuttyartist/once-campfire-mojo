# Built-in sound definitions from Rails app/models/sound.rb.
import templates
from text import escape


def presentation(name: String) raises -> String:
    if name == "56k":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("56k.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/56k.webp")
            + '" width="79" height="33">'
            + "</div>"
        )
    if name == "bell":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("bell.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "🔔"
            + "</div>"
        )
    if name == "bezos":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("bezos.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "😆💭"
            + "</div>"
        )
    if name == "bueller":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("bueller.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "anyone?"
            + "</div>"
        )
    if name == "butts":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("butts.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "👐 🚬"
            + "</div>"
        )
    if name == "clowntown":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("clowntown.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/clowntown.webp")
            + '" width="210" height="150">'
            + "</div>"
        )
    if name == "cottoneyejoe":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("cottoneyejoe.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "🎶🙉🎶 "
            + "</div>"
        )
    if name == "crickets":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("crickets.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "hears crickets chirping"
            + "</div>"
        )
    if name == "curb":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("curb.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/curb.webp")
            + '" width="150" height="101">'
            + "</div>"
        )
    if name == "dadgummit":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("dadgummit.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "dad gummit!! 🎣"
            + "</div>"
        )
    if name == "dangerzone":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("dangerzone.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/dangerzone.webp")
            + '" width="157" height="32">'
            + "</div>"
        )
    if name == "danielsan":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("danielsan.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "🎆 🏆 🎆"
            + "</div>"
        )
    if name == "deeper":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("deeper.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/top.webp")
            + '" width="188" height="80">'
            + "</div>"
        )
    if name == "ballmer":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("ballmer.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "developers!"
            + "</div>"
        )
    if name == "donotwant":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("donotwant.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/donotwant.webp")
            + '" width="150" height="150">'
            + "</div>"
        )
    if name == "drama":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("drama.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/drama.webp")
            + '" width="300" height="16">'
            + "</div>"
        )
    if name == "flawless":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("flawless.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "#flawless"
            + "</div>"
        )
    if name == "glados":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("glados.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "🤖💢"
            + "</div>"
        )
    if name == "gogogo":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("gogogo.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "Go, go, go!"
            + "</div>"
        )
    if name == "greatjob":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("greatjob.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/greatjob.webp")
            + '" width="79" height="16">'
            + "</div>"
        )
    if name == "greyjoy":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("greyjoy.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "😖🎺"
            + "</div>"
        )
    if name == "guarantee":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("guarantee.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "guarantees it 👌"
            + "</div>"
        )
    if name == "heygirl":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("heygirl.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "✨💁✨"
            + "</div>"
        )
    if name == "honk":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("honk.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "HONK"
            + "</div>"
        )
    if name == "horn":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("horn.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "🐶 ✂️ 🐱"
            + "</div>"
        )
    if name == "horror":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("horror.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "💀 💀 💀 💀 💀 💀 💀"
            + "</div>"
        )
    if name == "inconceivable":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("inconceivable.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "doesn't think it means what you think it means…"
            + "</div>"
        )
    if name == "letitgo":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("letitgo.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "❄️👩❄️⛄️❄️"
            + "</div>"
        )
    if name == "live":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("live.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "is DOING IT LIVE"
            + "</div>"
        )
    if name == "loggins":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("loggins.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/loggins.webp")
            + '" width="200" height="151">'
            + "</div>"
        )
    if name == "makeitso":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("makeitso.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "make it so 👉"
            + "</div>"
        )
    if name == "noooo":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("noooo.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "👸💀😒"
            + "</div>"
        )
    if name == "nyan":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("nyan.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/nyan.webp")
            + '" width="36" height="15">'
            + "</div>"
        )
    if name == "ohmy":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("ohmy.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "raises an eyebrow 😏"
            + "</div>"
        )
    if name == "ohyeah":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("ohyeah.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "isn't playing by the rules"
            + "</div>"
        )
    if name == "pushit":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("pushit.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/pushit.webp")
            + '" width="104" height="15">'
            + "</div>"
        )
    if name == "rimshot":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("rimshot.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "plays a rimshot"
            + "</div>"
        )
    if name == "rollout":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("rollout.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "is rolling out 🚗"
            + "</div>"
        )
    if name == "rumble":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("rumble.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/rumble.webp")
            + '" width="220" height="150">'
            + "</div>"
        )
    if name == "sax":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("sax.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "🌇🎷🎶"
            + "</div>"
        )
    if name == "secret":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("secret.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "found a secret area 🔑"
            + "</div>"
        )
    if name == "sexyback":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("sexyback.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "🔞"
            + "</div>"
        )
    if name == "story":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("story.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "and now you know…"
            + "</div>"
        )
    if name == "tada":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("tada.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "plays a fanfare 🎏"
            + "</div>"
        )
    if name == "tmyk":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("tmyk.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "✨ ⭐️ The More You Know ✨ ⭐️"
            + "</div>"
        )
    if name == "totes":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("totes.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "😁👍"
            + "</div>"
        )
    if name == "trololo":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("trololo.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "трололо"
            + "</div>"
        )
    if name == "trombone":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("trombone.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "plays a sad trombone"
            + "</div>"
        )
    if name == "unix":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("unix.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "knows this 💻"
            + "</div>"
        )
    if name == "vuvuzela":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("vuvuzela.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "======<() ~ ♪ ~♫"
            + "</div>"
        )
    if name == "what":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("what.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/what.webp")
            + '" width="100" height="131">'
            + "</div>"
        )
    if name == "whoomp":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("whoomp.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "👏‼️😎"
            + "</div>"
        )
    if name == "wups":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("wups.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "wups!"
            + "</div>"
        )
    if name == "yay":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("yay.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/yay.webp")
            + '" width="103" height="50">'
            + "</div>"
        )
    if name == "yeah":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("yeah.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + '<img class="align--middle" src="'
            + templates.asset("sounds/yeah.webp")
            + '" width="104" height="15">'
            + "</div>"
        )
    if name == "yodel":
        return (
            '<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="'
            + templates.asset("yodel.mp3")
            + '"><button class="btn btn--plain" data-action="sound#play">🔊</button>'
            + "📣🗻🙉"
            + "</div>"
        )
    return ""
