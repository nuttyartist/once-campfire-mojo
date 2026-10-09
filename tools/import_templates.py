#!/usr/bin/env python3
"""Port the MIT-licensed Rust/Rails markup to the Mojo template input format.

Run with the upstream Rust checkout as argv[1]. The output is vendored so normal
builds do not need any other Campfire implementation. Expressions are replaced
by named, runtime view-model values supplied by views.mojo; never by responses.
"""
import re,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
UP=Path(sys.argv[1])/'crates/views/templates'

def read(path):
 s=(UP/path).read_text()
 s=re.sub(r'{#.*?#}', '', s, flags=re.S)
 return s

def expr(s,mapping):
 for old,new in mapping.items(): s=s.replace(old,new)
 return s

def write(name,s):
 s=re.sub(r'{{\s*ctx.asset\("([^"]+)"\)\s*}}', r'{{ asset:\1 }}',s)
 s=re.sub(r'{{\s*ctx.url\("([^"]+)"\)\s*}}',r'{{ base_url }}\1',s)
 (ROOT/'templates'/f'{name}.html').write_text(s.strip()+'\n')

def inc(s,path,repl): return s.replace('{% include "'+path+'" %}',repl)
def loop(s,pattern,repl): return re.sub(r'{%-? for '+pattern+r' %}.*?{%-? endfor %}',repl,s,flags=re.S)

msgmap={
 'message.dom_id("")':'dom_id', 'message.dom_id("edit")':'edit_dom',
 'message.dom_id("boosting")':'boosting_dom','message.dom_id("new_boost")':'new_boost_dom',
 'message.dom_id("boosts")':'boosts_dom','message.dom_id("presentation")':'presentation_dom',
 'message.creator.id':'creator_id','message.creator.title':'creator_title',
 'message.creator.path()':'creator_path','message.creator.avatar_url':'creator_avatar',
 'message.creator.name':'creator_name','message.at_path()':'at_path',
 'message.created_at_epoch()':'created_epoch','message.updated_at_epoch()':'updated_epoch',
 'message.created_at_iso()':'created_iso','message.all_emoji':'all_emoji',
 'message.id':'id','message.room_name':'room_name','message.boosts_path()':'boosts_path',
 'message.new_boost_path()':'new_boost_path','message.edit_path()':'edit_path',
 'attachment.download_path':'download_path','attachment.blob_path':'blob_path','attachment.filename':'filename'
}
s=read('messages/_message.html')
s=re.sub(r'{%- if message.is_unrenderable\(\) %}.*?{%- else %}', '',s,flags=re.S)
s=s.rsplit('{%- endif %}',1)[0]
s=inc(s,'messages/_actions.html','{{ actions|safe }}')
s=inc(s,'messages/_presentation.html',read('messages/_presentation.html'))
s=inc(s,'messages/boosts/_boosts.html','{{ boosts|safe }}')
s=s.replace('crate::messages::presentation::message_presentation(ctx, message)|safe','presentation|safe')
write('message',expr(s,msgmap))
s=read('messages/_actions.html')
reaction=re.search(r'{%- for \(character, title\).*?%}(.*?){%- endfor %}',s,re.S)[1]
write('reaction',expr(reaction,msgmap))
s=loop(s,r'\(character, title\) in crate::messages::REACTIONS','{{ reactions|safe }}')
s=s.replace('if let Some(attachment) = message.attachment()','if has_attachment')
write('actions',expr(s,msgmap))
s=read('messages/boosts/_boosts.html')
s=loop(s,'boost in message.boosts','{{ boost_items|safe }}')
write('boosts',expr(s,msgmap))
s=read('messages/boosts/_boost.html')
s=expr(s,{'boost.dom_id()':'dom_id','boost.booster.id':'creator_id','boost.booster.title':'creator_title','boost.booster.path()':'creator_path','boost.booster.avatar_url':'creator_avatar','boost.booster.name':'creator_name','boost.content':'content','boost.all_emoji':'all_emoji','boost.path()':'path'})
write('boost',s)
s=read('messages/_template.html')
s=expr(s,{'user.id':'creator_id','user.title':'creator_title','user.path()':'creator_path','user.avatar_url':'creator_avatar','user.name':'creator_name'})
write('message_template',s)

roommap={
 'show.room.id':'room_id','show.room.dom_id("messages")':'messages_dom',
 'ctx.url(h::routes::room_messages(room_id).as_str())':'messages_url',
 'ctx.url(h::routes::room_refresh(room_id).as_str())':'refresh_path',
 'self.loaded_at()':'loaded_at','show.messages_stream_name':'messages_stream',
 'show.invitation':'invitation','show.join_code.clone()':'join_code',
 'room.id':'room_id','room.is_direct()':'direct','room.display_name':'room_name',
 'room.edit_path()':'room_edit_path','room.noun()':'room_noun',
 'ctx.account.has_logo':'has_logo','h::account_logo_tag(ctx, None)':'account_logo|safe',
 'room.dom_id("involvement")':'involvement_dom',
 'h::routes::user_push_subscriptions()':'push_path',
 'h::routes::room_involvement(room_id)':'involvement_path',
 'h::routes::searches()':'searches_path','h::routes::room_messages(room_id)':'messages_path',
 'crate::rooms::mention_prompt_src(*room_id)':'mention_path',
}
s=read('rooms/show.html')
for block in ['head','content']:
 t=re.search(r'{%- block '+block+r' %}(.*?){%- endblock %}',s,re.S)[1]
 t=re.sub(r'{%- let .*? %}', '',t)
 t=inc(t,'messages/_template.html','{{ message_template|safe }}')
 t=inc(t,'rooms/show/_invitation.html','{{ invitation_html|safe }}')
 t=loop(t,'message in show.messages','{{ messages|safe }}')
 write('room_'+block,expr(t,roommap))
write('room_composer',expr(read('rooms/show/_composer.html'),roommap))
write('room_nav',expr(inc(read('rooms/show/_nav.html'),'rooms/involvements/_bell.html','{{ bell|safe }}'),roommap))
s=read('rooms/involvements/_bell.html')
for path,key in [('pwa/_browser_settings.html','browser_settings'),('pwa/_system_settings.html','system_settings'),('pwa/_install_instructions.html','install_instructions')]:
 s=inc(s,path,'{{ '+key+'|safe }}')
write('bell',expr(s,roommap))

# Image helpers are static attribute builders; preserve their attribute order.
def images(s):
 def sub(m):
  name,opts=m.groups(); attrs=[]
  for method,args in re.findall(r'\.(\w+)\(([^)]*)\)',opts):
   values=re.findall(r'"([^"]*)"|\b(\d+)\b|\b(true|false)\b',args)
   a=[next(x for x in v if x) for v in values]
   if method in ('aria_hidden',): attrs += [('aria-hidden','true')]
   elif method=='aria': attrs += [('aria-'+a[0],a[1])]
   elif method=='size': attrs += [('width',a[0]),('height',a[0])]
   elif method in ('alt','class','style'): attrs += [(method,a[0])]
   elif method=='attr': attrs += [(a[0],a[1])]
   else: raise ValueError((method,args))
  # Rails image_tag writes source before width/height but after other opts.
  attrs=[x for x in attrs if x[0] not in ('width','height')]+[('src','{{ asset:'+name+' }}')]+[x for x in attrs if x[0] in ('width','height')]
  return '<img'+''.join(' '+k+'="'+v+'"' for k,v in attrs)+' />'
 return re.sub(r'{{\s*h::image_tag\(ctx, "([^"]+)", h::attrs\(\)(.*?)\)\s*}}',sub,s)
for part in ['browser_settings','system_settings','install_instructions']:
 s=images(read('pwa/_'+part+'.html'))
 s=s.replace('h::capitalize(ctx.platform.browser.as_str())','browser').replace('ctx.platform.operating_system','operating_system')
 s=re.sub(r'ctx.platform\.(\w+)',r'\1',s)
 # Convert elif to nested if for compiler simplicity.
 stack=[]; tokens=re.split(r'({%.*?%})',s,flags=re.S); out=''
 for t in tokens:
  if t.startswith('{% if '): stack.append(0)
  elif t.startswith('{% elif '): stack[-1]+=1; t=t.replace('{% elif ','{% else %}{% if ')
  elif t=='{% endif %}': t += '{% endif %}'*stack.pop()
  out+=t
 write(part,out)
write('lightbox',images(read('layouts/_lightbox.html')))

s=read('layouts/application.html')
s=re.sub(r'{% let notice.*?{% endif %}\s*<main', '<main',s,flags=re.S)
for block in ['head','nav','content','footer','sidebar']:
 s=re.sub(r'{% block '+block+r' %}.*?{% endblock %}', '{{ '+block+'|safe }}',s,flags=re.S)
s=inc(s,'layouts/_lightbox.html','{{ lightbox|safe }}')
s=images(s)
s=expr(s,{
 'h::page_title_tag(self.page_title().as_deref())':'title_tag|safe',
 'h::current_user_meta_tags(ctx)':'user_meta|safe',
 'h::script_aware_action_cable_meta_tag(ctx)':'cable_meta|safe',
 'h::builder_tag("meta", h::attrs().name("vapid-public-key").attr_opt("content", ctx.vapid_public_key.as_deref()))':'vapid_meta|safe',
 'h::builder_tag("meta", h::attrs().name("turbo-prefetch").attr("content", "true"))':'prefetch_meta|safe',
 'h::builder_tag("link", h::attrs().attr("rel", "manifest").attr("href", "/webmanifest.json"))':'manifest_tag|safe',
 'h::builder_tag("link", h::attrs().attr("rel", "icon").attr("href", ctx.account.logo_url.as_str()).type_("image/png"))':'icon_tag|safe',
 'h::builder_tag("link", h::attrs().attr("rel", "apple-touch-icon").attr("href", ctx.account.logo_url.as_str()))':'apple_icon_tag|safe',
 'h::raw(ctx.stylesheet_tags)':'stylesheets|safe','h::custom_styles_tag(ctx)':'custom_styles|safe',
 'h::raw(ctx.importmap_tags)':'importmap|safe','h::body_classes(ctx, self.body_class())':'body_classes',
})
write('layout',s)

s=read('searches/index.html')
for block in ['nav','sidebar','content','footer']:
 t=re.search(r'{%- block '+block+r' %}(.*?){%- endblock %}',s,re.S)[1]
 t=inc(t,'searches/_recents.html','{{ recents|safe }}')
 t=loop(t,'message in index.messages','{{ messages|safe }}')
 t=t.replace('if let Some(query) = index.query','if has_query').replace('if let Some(q) = index.q','if has_query')
 t=expr(t,{'index.messages.len()':'count','h::routes::room(index.return_to_room_id)':'return_path','h::routes::searches()':'searches_path'})
 write('search_'+block,t)
s=read('searches/_recents.html')
link=re.search(r'{%- for search .*?%}(.*?){%- endfor %}',s,re.S)[1]
write('recent_link',link.replace('crate::searches::search_path(search)','path'))
s=loop(s,'search in index.recent_searches','{{ links|safe }}').replace('!index.recent_searches.is_empty()','has_recents').replace('ctx.url(h::routes::clear_searches().as_str())','clear_path')
write('recents',s)

# Sidebar filter blocks lower to the same tags. Collections are rendered in Mojo.
s=read('users/sidebars/show.html')
s=s.replace('{% extends "layouts/application.html" %}','').replace('{% block content %}{% filter sidebar_turbo_frame_tag %}','{{ frame_open|safe }}').replace('{% endfilter %}{% endblock %}','</turbo-frame>')
s=loop(s,'membership in direct_memberships','{{ directs|safe }}')
s=loop(s,'user in direct_placeholder_users','{{ placeholders|safe }}')
s=loop(s,'room in other_memberships','{{ shared|safe }}')
s=expr(s,{'h::turbo_stream_from(rooms_stream.as_str())':'rooms_stream_tag|safe','h::turbo_stream_from(user_rooms_stream.as_str())':'user_stream_tag|safe'})
links={
 'h::routes::new_rooms_direct(), h::attrs().class("direct direct__new").data("turbo_frame", "_self")':'class="direct direct__new" data-turbo-frame="_self" href="/rooms/directs/new"',
 'h::routes::new_rooms_open(), h::attrs().class("rooms__new-btn btn room align-center gap txt-reversed").aria("label", "New Chat Room")':'class="rooms__new-btn btn room align-center gap txt-reversed" aria-label="New Chat Room" href="/rooms/opens/new"',
 'h::routes::user_profile(), h::attrs().class("btn avatar flex-item-no-shrink sidebar__tool")':'class="btn avatar flex-item-no-shrink sidebar__tool" href="/users/me/profile"',
 'h::routes::edit_account(), h::attrs().class("btn align-center gap txt-reversed sidebar__tool")':'class="btn align-center gap txt-reversed sidebar__tool" href="/account/edit"'
}
for call,attrs in links.items(): s=s.replace('{% filter link_to('+call+') %}', '<a '+attrs+'>')
s=s.replace('{% endfilter %}','</a>')
s=s.replace('{{ h::image_tag(ctx, current_user.avatar_path.as_str(), h::attrs().size(48).aria_hidden().style("view-transition-name: avatar-" ~ current_user.id)) }}','<img aria-hidden="true" style="view-transition-name: avatar-{{ creator_id }}" src="{{ creator_avatar }}" width="48" height="48" />')
write('sidebar',images(s))
s=read('users/sidebars/rooms/_shared.html')
s=re.sub(r'{% filter link_to_room.*?%}', '<a id="{{ dom_id }}" data-sorted-list-name="{{ name }}" style="--column-gap: 0.5em" class="{{ classes }}" data-rooms-list-target="room" data-badge-dot-target="unread" data-sorted-list-target="item" data-room-id="{{ room_id }}" href="/rooms/{{ room_id }}">',s)
s=s.replace('room.name','name').replace('{% endfilter %}','</a>')
write('shared_room',s)
s=read('users/sidebars/rooms/_direct.html')
s=re.sub(r'{% filter link_to_room.*?%}', '<a class="{{ classes }}" id="{{ dom_id }}" data-sorted-list-number="{{ epoch }}" data-rooms-list-target="room" data-badge-dot-target="unread" data-sorted-list-target="item" data-room-id="{{ room_id }}" href="/rooms/{{ room_id }}">',s)
s=loop(s,r'member in membership.members.iter\(\).take\(4\)','{{ avatars|safe }}')
s=s.replace('membership.members.len() > 1','group').replace('membership.member_initials()','initials').replace('membership.members[0].first_name()','first_name').replace('{% endfilter %}','</a>')
s=s.replace('{{ h::image_tag(ctx, membership.members[0].avatar_path.as_str(), h::attrs().size(48).aria_hidden()) }}','<img aria-hidden="true" src="{{ avatar }}" width="48" height="48" />')
write('direct_room',s)
s=read('users/sidebars/rooms/_direct_placeholder.html')
s=re.sub(r'{% filter button_to.*?%}', '<form class="button_to" method="post" action="/rooms/directs?user_ids%5B%5D={{ id }}"><button class="direct borderless fill-transparent unpad" type="submit">',s)
s=s.replace('{% endfilter %}','</button></form>').replace('user.first_name()','first_name')
s=s.replace('{{ h::image_tag(ctx, user.avatar_path.as_str(), h::attrs().aria_hidden()) }}','<img aria-hidden="true" src="{{ avatar }}" />')
write('direct_placeholder',s)
