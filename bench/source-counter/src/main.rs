use std::{env,fs};
use syn::{visit::{self,Visit},spanned::Spanned};
use quote::ToTokens;
#[derive(Default)]
struct Strip { ranges: Vec<(usize,usize)> }
fn test(attrs:&[syn::Attribute])->bool { attrs.iter().any(|a| a.path().is_ident("cfg") && {let t=a.meta.to_token_stream().to_string(); t=="cfg (test)" || t.contains("\"test-support\"")}) }
impl<'a> Visit<'a> for Strip {
 fn visit_item(&mut self,item:&'a syn::Item) {
  let attrs = match item {
   syn::Item::Const(i)=>&i.attrs,syn::Item::Enum(i)=>&i.attrs,syn::Item::ExternCrate(i)=>&i.attrs,
   syn::Item::Fn(i)=>&i.attrs,syn::Item::ForeignMod(i)=>&i.attrs,syn::Item::Impl(i)=>&i.attrs,
   syn::Item::Macro(i)=>&i.attrs,syn::Item::Mod(i)=>&i.attrs,syn::Item::Static(i)=>&i.attrs,
   syn::Item::Struct(i)=>&i.attrs,syn::Item::Trait(i)=>&i.attrs,syn::Item::TraitAlias(i)=>&i.attrs,
   syn::Item::Type(i)=>&i.attrs,syn::Item::Union(i)=>&i.attrs,syn::Item::Use(i)=>&i.attrs,_=>return
  };
  if test(attrs){let s=item.span();self.ranges.push((s.start().line,s.end().line));}else{visit::visit_item(self,item)}
 }
 fn visit_impl_item(&mut self,item:&'a syn::ImplItem){
  let attrs=match item {syn::ImplItem::Const(i)=>&i.attrs,syn::ImplItem::Fn(i)=>&i.attrs,syn::ImplItem::Type(i)=>&i.attrs,syn::ImplItem::Macro(i)=>&i.attrs,_=>return};
  if test(attrs){let s=item.span();self.ranges.push((s.start().line,s.end().line));}else{visit::visit_impl_item(self,item)}
 }
}
fn main(){let args:Vec<_>=env::args().collect();for path in &args[1..]{let text=fs::read_to_string(path).unwrap();let tree=syn::parse_file(&text).unwrap();let mut strip=Strip::default();strip.visit_file(&tree);let result=text.lines().enumerate().map(|(i,l)|if strip.ranges.iter().any(|(a,b)|i+1>=*a&&i+1<=*b){""}else{l}).collect::<Vec<_>>().join("\n");fs::write(path,result+"\n").unwrap();}}
