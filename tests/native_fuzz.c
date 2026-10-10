/* Test-only libFuzzer harness: untrusted HTML/URL/base64 crosses these C ABIs. */
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
extern long dom_parse_fragment(const char *,long),dom_root(long),dom_child(long),dom_next(long),dom_type(long);
extern void dom_free(long),dom_remove(long),dom_set_attr(long,const char *,const char *),dom_clear_node(long);
extern long dom_inner_html(long,const char *,long),dom_replace_text(long,const char *),dom_attrs(long),dom_attr_next(long);
extern long base64_encode(const void *,long,void *),base64_decode(const unsigned char *,long,void *);
extern long url_component(const char *,long,char *,long),unicode_word(const char *),p256_validate_public(const void *);
int LLVMFuzzerTestOneInput(const uint8_t *data,size_t size) {
 if(size>32768)return 0;
 char *text=malloc(size+1),*encoded=malloc(4*(size+2)/3+8),*decoded=malloc(size+8);
 assert(text&&encoded&&decoded);memcpy(text,data,size);text[size]=0;
 long n=base64_encode(data,(long)size,encoded);
 long m=base64_decode((unsigned char *)encoded,n,decoded);
 assert(m==(long)size&&!memcmp(decoded,data,size));
 (void)base64_decode(data,(long)size,decoded);
 char url[8192];for(long part=0;part<3;part++)(void)url_component(text,part,url,sizeof url);
 (void)unicode_word(text);
 if(size>=65)(void)p256_validate_public(data);
 long doc=dom_parse_fragment(text,(long)size);
 if(doc){long root=dom_root(doc);if(root){
  dom_set_attr(root,"test","safe");long attr=dom_attrs(root);
  dom_set_attr(root,"test","changed");assert(dom_attr_next(attr)==0);
  (void)dom_inner_html(root,text,(long)size);long child=dom_child(root);
  if(child){(void)dom_type(child);(void)dom_next(child);(void)dom_replace_text(child,"replacement");assert(dom_type(child)==0);dom_remove(child);}
  child=dom_child(root);dom_clear_node(root);assert(dom_type(child)==0);
 }dom_free(doc);dom_free(doc);assert(dom_root(doc)==0);assert(dom_type(root)==0);}
 assert(dom_type(INT64_MAX)==0);dom_remove(INT64_MAX);dom_free(INT64_MAX);
 free(text);free(encoded);free(decoded);return 0;
}
