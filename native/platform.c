// Generic OS/library ABI adapters. No Campfire routes, SQL, or view logic.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <crypt.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <openssl/rand.h>
#include <poll.h>
#include <signal.h>
#include <sqlite3.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>
#include <zlib.h>
#include <limits.h>

long os_listen(long port) {
  signal(SIGPIPE, SIG_IGN);
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0),
      one = 1;
  if (fd < 0)
    return -1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  struct sockaddr_in a = {.sin_family = AF_INET,
                          .sin_port = htons((uint16_t)port)};
  const char *bind_address=getenv("BIND_ADDRESS");
  if (!bind_address) bind_address="127.0.0.1";
  if (inet_pton(AF_INET,bind_address,&a.sin_addr)!=1) { close(fd); return -1; }
  if (bind(fd, (void *)&a, sizeof(a)) || listen(fd, 256)) {
    close(fd);
    return -1;
  }
  return fd;
}
long os_accept(long fd) {
  int c = accept4((int)fd, 0, 0, SOCK_NONBLOCK | SOCK_CLOEXEC), one = 1;
  if (c >= 0)
    setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  return c;
}
long os_close(long fd) { return close((int)fd); }
long os_recv(long fd, void *buf, long n) {
  ssize_t r = recv((int)fd, buf, (size_t)n, 0);
  return r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
             ? -2
             : r;
}
long os_send(long fd, const void *buf, long n) {
  ssize_t r = send((int)fd, buf, (size_t)n, MSG_NOSIGNAL);
  return r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
             ? -2
             : r;
}
long os_poll(const long *fds, const long *write_flags, long *ready, long n) {
  struct pollfd p[1025];
  if (n > 1025)
    return -1;
  for (long i = 0; i < n; i++)
    p[i] = (struct pollfd){.fd = (int)fds[i],
                           .events = write_flags[i] ? POLLOUT : POLLIN};
  int rc = poll(p, (nfds_t)n, 50);
  for (long i = 0; i < n; i++)
    ready[i] = p[i].revents;
  return rc;
}
long os_fork(void) { return fork(); }
/* After Mojo worker-local cleanup, avoid tearing down the inherited parent
   compiler runtime/thread pool in the forked child. */
_Noreturn void os_child_exit(long status) { _exit((int)status); }
long os_now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
long crypto_random(void *p, long n) {
  return RAND_bytes(p, (int)n) == 1 ? 0 : -1;
}
long crypto_password(const char *password, const char *digest) {
  struct crypt_data data = {0};
  char *result = crypt_r(password, digest, &data);
  return result && strlen(result) == strlen(digest) &&
         CRYPTO_memcmp(result, digest, strlen(digest)) == 0;
}
long gzip_encode(const void *src, long n, void *dst, long cap) {
  z_stream s = {0};
  if (deflateInit2(&s, 6, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY) != Z_OK)
    return -1;
  s.next_in = (void *)src;
  s.avail_in = (uInt)n;
  s.next_out = dst;
  s.avail_out = (uInt)cap;
  int rc = deflate(&s, Z_FINISH);
  long out = (long)s.total_out;
  deflateEnd(&s);
  return rc == Z_STREAM_END ? out : -1;
}
long sql_open(const char *path) {
  sqlite3 *db = 0;
  if (sqlite3_open_v2(path, &db,
                      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE |
                          SQLITE_OPEN_NOMUTEX,
                      0) != SQLITE_OK) {
    sqlite3_close(db);
    return 0;
  }
  sqlite3_busy_timeout(db, 10000);
  return (long)(intptr_t)db;
}
long sql_close(long db) { return sqlite3_close((sqlite3 *)(intptr_t)db); }
long sql_prepare(long db, const char *sql) {
  sqlite3_stmt *s = 0;
  if (sqlite3_prepare_v2((sqlite3 *)(intptr_t)db, sql, -1, &s, 0) != SQLITE_OK)
    return 0;
  return (long)(intptr_t)s;
}
const char *sql_error(long db) {
  return sqlite3_errmsg((sqlite3 *)(intptr_t)db);
}
long sql_bind(long s, long i, const char *text) {
  return sqlite3_bind_text((sqlite3_stmt *)(intptr_t)s, (int)i, text ? text : "", -1,
                           SQLITE_TRANSIENT);
}
long sql_bind_n(long s, long i, const char *text, long n) {
  return sqlite3_bind_text((sqlite3_stmt *)(intptr_t)s,(int)i,text ? text : "",(int)n,SQLITE_TRANSIENT);
}
long sql_bytes(long s,long i) { return sqlite3_column_bytes((sqlite3_stmt *)(intptr_t)s,(int)i); }
long sql_step(long s) { return sqlite3_step((sqlite3_stmt *)(intptr_t)s); }
long sql_reset(long s) {
  sqlite3_clear_bindings((sqlite3_stmt *)(intptr_t)s);
  return sqlite3_reset((sqlite3_stmt *)(intptr_t)s);
}
long sql_finalize(long s) {
  return sqlite3_finalize((sqlite3_stmt *)(intptr_t)s);
}
long sql_columns(long s) {
  return sqlite3_column_count((sqlite3_stmt *)(intptr_t)s);
}
const char *sql_column(long s, long i) {
  const char *p =
      (void *)sqlite3_column_text((sqlite3_stmt *)(intptr_t)s, (int)i);
  return p ? p : "";
}
long sql_last_id(long db) {
  return sqlite3_last_insert_rowid((sqlite3 *)(intptr_t)db);
}

/* Generic OpenSSL and encoding ABI, with all Rails policy in Mojo. */
#include <openssl/evp.h>
#include <openssl/hmac.h>
static void hex_bytes(const unsigned char *p, int n, char *out) {
  static const char digits[] = "0123456789abcdef";
  for (int i=0;i<n;i++) { out[2*i]=digits[p[i]>>4]; out[2*i+1]=digits[p[i]&15]; }
  out[2*n]=0;
}
static int unhex(const char *p, unsigned char *out, int capacity) {
  int n=(int)strlen(p); if (n%2 || n/2>capacity) return -1;
  for (int i=0;i<n/2;i++) {
    unsigned v; if (sscanf(p+2*i,"%2x",&v)!=1) return -1; out[i]=(unsigned char)v;
  }
  return n/2;
}
long crypto_derive(const char *secret, const char *salt, char *out) {
  unsigned char key[64];
  if (!PKCS5_PBKDF2_HMAC(secret,(int)strlen(secret),(const unsigned char*)salt,(int)strlen(salt),1000,EVP_sha256(),64,key)) return -1;
  hex_bytes(key,64,out); OPENSSL_cleanse(key,64); return 0;
}
long crypto_hmac(const char *keyhex, const void *data, long n, long sha256, char *out) {
  unsigned char key[64], digest[EVP_MAX_MD_SIZE]; unsigned len=0;
  int k=unhex(keyhex,key,64); if(k<0)return -1;
  if(!HMAC(sha256?EVP_sha256():EVP_sha1(),key,k,data,(size_t)n,digest,&len))return -1;
  hex_bytes(digest,(int)len,out); OPENSSL_cleanse(key,64);return 0;
}
long crypto_equal(const char *a, const char *b) {
  size_t n=strlen(a);return n==strlen(b) && CRYPTO_memcmp(a,b,n)==0;
}
long base64_encode(const void *p,long n,void *out) { return EVP_EncodeBlock(out,p,(int)n); }
long base64_decode(const unsigned char *p,long n,void *out) {
  int size=EVP_DecodeBlock(out,p,(int)n); if(size<0)return -1;
  if(n && p[n-1]=='=')size--; if(n>1 && p[n-2]=='=')size--;return size;
}

/* Read-only libxml2 DOM traversal. Sanitizing/rendering policy lives in Mojo. */
#include <libxml/HTMLparser.h>
#include "../vendor/gumbo/src/nokogiri_gumbo.h"
/* Normalize an HTML5 parse tree into the existing traversal ABI. libxml2 is
   only the node container here; Gumbo decides all HTML parsing semantics. */
static xmlNodePtr html5_node(const GumboNode *node) {
 if(node->type==GUMBO_NODE_COMMENT)return xmlNewComment((const xmlChar*)node->v.text.text);
 if(node->type==GUMBO_NODE_TEXT || node->type==GUMBO_NODE_WHITESPACE || node->type==GUMBO_NODE_CDATA)return xmlNewText((const xmlChar*)node->v.text.text);
 if(node->type!=GUMBO_NODE_ELEMENT && node->type!=GUMBO_NODE_TEMPLATE)return NULL;
 const GumboElement *e=&node->v.element;
 const char *name=gumbo_normalized_tagname(e->tag);char *allocated=NULL;
 if(!*name){GumboStringPiece tag=e->original_tag;gumbo_tag_from_original_text(&tag);allocated=strndup(tag.data,tag.length);name=allocated;}
 xmlNodePtr result=xmlNewNode(NULL,(const xmlChar*)name);free(allocated);
 if(!result)return NULL;result->_private=(void*)(uintptr_t)e->tag_namespace;
 for(unsigned i=0;i<e->attributes.length;i++){const GumboAttribute *a=e->attributes.data[i];char key[512];const char *prefix=a->attr_namespace==GUMBO_ATTR_NAMESPACE_XLINK?"xlink:":a->attr_namespace==GUMBO_ATTR_NAMESPACE_XML?"xml:":a->attr_namespace==GUMBO_ATTR_NAMESPACE_XMLNS?"xmlns:":"";snprintf(key,sizeof key,"%s%s",prefix,a->name);xmlNewProp(result,(const xmlChar*)key,(const xmlChar*)a->value);}
 for(unsigned i=0;i<e->children.length;i++){xmlNodePtr child=html5_node(e->children.data[i]);if(child)xmlAddChild(result,child);}
 return result;
}
static long rawdom_parse_impl(const char *html, long n, int fragment) {
 GumboOptions options=kGumboDefaultOptions;options.max_tree_depth=401;options.max_attributes=400;options.max_errors=0;
 if(fragment)options.fragment_context="body";
 GumboOutput *parsed=gumbo_parse_with_options(&options,html,n);
 if(!parsed)return 0;
 if(parsed->status!=GUMBO_STATUS_OK){gumbo_destroy_output(parsed);return 0;}
 xmlDocPtr doc=xmlNewDoc((const xmlChar*)"1.0");
 xmlDocSetRootElement(doc,html5_node(parsed->root));
 gumbo_destroy_output(parsed);return (long)(intptr_t)doc;
}
static long rawdom_parse(const char *html,long n) { return rawdom_parse_impl(html,n,0); }
static long rawdom_parse_fragment(const char *html,long n) { return rawdom_parse_impl(html,n,1); }
static void rawdom_set_name(long node,const char *name) { xmlNodeSetName((xmlNodePtr)(intptr_t)node,(const xmlChar*)name); }
static void rawdom_set_attr(long node,const char *key,const char *value) { xmlSetProp((xmlNodePtr)(intptr_t)node,(const xmlChar*)key,(const xmlChar*)value); }
static void rawdom_clear_node(long address) { xmlNodePtr node=(void*)(intptr_t)address;xmlFreeNodeList(node->children);node->children=NULL;node->last=NULL;xmlFreePropList(node->properties);node->properties=NULL; }
static void rawdom_free(long doc) { xmlFreeDoc((xmlDocPtr)(intptr_t)doc); }
static long rawdom_root(long doc) { return (long)(intptr_t)xmlDocGetRootElement((xmlDocPtr)(intptr_t)doc); }
static long rawdom_child(long node) { return (long)(intptr_t)((xmlNodePtr)(intptr_t)node)->children; }
static long rawdom_next(long node) { return (long)(intptr_t)((xmlNodePtr)(intptr_t)node)->next; }
static long rawdom_foreign(long node) { return ((xmlNodePtr)(intptr_t)node)->_private!=NULL; }
static long rawdom_type(long node) { return ((xmlNodePtr)(intptr_t)node)->type; }
static const char *rawdom_name(long node) { const char *p=(const char*)((xmlNodePtr)(intptr_t)node)->name;return p?p:""; }
static const char *rawdom_text(long node) { const char *p=(const char*)((xmlNodePtr)(intptr_t)node)->content;return p?p:""; }
static long rawdom_attrs(long node) { return (long)(intptr_t)((xmlNodePtr)(intptr_t)node)->properties; }
static long rawdom_attr_next(long attr) { return (long)(intptr_t)((xmlAttrPtr)(intptr_t)attr)->next; }
static const char *rawdom_attr_name(long attr) { return (const char*)((xmlAttrPtr)(intptr_t)attr)->name; }
static const char *rawdom_attr_text(long attr) { xmlNodePtr n=((xmlAttrPtr)(intptr_t)attr)->children;return n&&n->content?(const char*)n->content:""; }

/* A process-shared bounded integer queue and counters; payload policy is Mojo. */
#include <sys/mman.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdatomic.h>
#define QUEUE_CAP 65536
struct shared_queue {
  pthread_mutex_t lock;
  sem_t ready;
  long head, tail, count, items[QUEUE_CAP];
  _Atomic long metrics[16];
};
static struct shared_queue *queue;
long work_init(void) {
  queue=mmap(NULL,sizeof(*queue),PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANONYMOUS,-1,0);
  if(queue==MAP_FAILED)return -1;
  pthread_mutexattr_t attr;pthread_mutexattr_init(&attr);
  pthread_mutexattr_setpshared(&attr,PTHREAD_PROCESS_SHARED);
  if(pthread_mutex_init(&queue->lock,&attr) || sem_init(&queue->ready,1,0))return -1;
  pthread_mutexattr_destroy(&attr);return 0;
}
long work_push(long value) {
  pthread_mutex_lock(&queue->lock);
  if(queue->count==QUEUE_CAP){pthread_mutex_unlock(&queue->lock);return -1;}
  queue->items[queue->tail]=value;queue->tail=(queue->tail+1)%QUEUE_CAP;queue->count++;
  atomic_fetch_add(&queue->metrics[0],1);
  pthread_mutex_unlock(&queue->lock);sem_post(&queue->ready);return 0;
}
long work_pop(void) {
  while(sem_wait(&queue->ready)<0){if(errno!=EINTR)return -1;}
  pthread_mutex_lock(&queue->lock);long value=queue->items[queue->head];
  queue->head=(queue->head+1)%QUEUE_CAP;queue->count--;
  pthread_mutex_unlock(&queue->lock);return value;
}
long metric_add(long index,long delta) { return !queue || queue==MAP_FAILED || index<0 || index>=16 ? -1 : atomic_fetch_add(&queue->metrics[index],delta); }
long metric_get(long index) { return !queue || queue==MAP_FAILED || index<0 || index>=16 ? -1 : atomic_load(&queue->metrics[index]); }
long file_append(const char *path,const void *value,long length) {
  int fd=open(path,O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC,0600);if(fd<0)return -1;
  long n=write(fd,value,(size_t)length);close(fd);return n==length?0:-1;
}

static long rawdom_replace_text(long address,const char *value) {
 xmlNodePtr node=(void*)(intptr_t)address, replacement=xmlNewText((const xmlChar*)value);
 if(!replacement)return -1;xmlReplaceNode(node,replacement);xmlFreeNode(node);return 0;
}
static xmlNodePtr find_body(xmlNodePtr node) {
 for(;node;node=node->next){if(node->type==XML_ELEMENT_NODE&&!xmlStrcmp(node->name,(const xmlChar*)"body"))return node;xmlNodePtr found=find_body(node->children);if(found)return found;}return NULL;
}
static long rawdom_replace_html(long address,const char *value,long length) {
 xmlNodePtr node=(void*)(intptr_t)address;xmlDocPtr doc=(void*)(intptr_t)rawdom_parse_fragment(value,length);if(!doc)return -1;
 xmlNodePtr body=find_body(xmlDocGetRootElement(doc));if(!body)body=xmlDocGetRootElement(doc);
 if(body)for(xmlNodePtr child=body->children;child;child=child->next)xmlAddPrevSibling(node,xmlDocCopyNode(child,node->doc,1));
 xmlUnlinkNode(node);xmlFreeNode(node);xmlFreeDoc(doc);return 0;
}

long peer_address(long fd,char *out,long capacity) {
 struct sockaddr_storage address;socklen_t n=sizeof address;
 if(getpeername(fd,(struct sockaddr*)&address,&n))return -1;
 const void *src=address.ss_family==AF_INET?(void*)&((struct sockaddr_in*)&address)->sin_addr:(void*)&((struct sockaddr_in6*)&address)->sin6_addr;
 return inet_ntop(address.ss_family,src,out,capacity)?0:-1;
}
long valid_ip(const char *text) { unsigned char bytes[16];return inet_pton(AF_INET,text,bytes)==1||inet_pton(AF_INET6,text,bytes)==1; }
static volatile sig_atomic_t stopping;
static void stop_requested(int sig) { (void)sig;stopping=1; }
long os_signals(void) { struct sigaction a={0};a.sa_handler=stop_requested;sigemptyset(&a.sa_mask);return sigaction(SIGTERM,&a,NULL)||sigaction(SIGINT,&a,NULL); }
long os_running(void) { return !stopping; }
void os_sleep_ms(long ms) { poll(NULL,0,ms); }
long os_wait_child(void) { int status;pid_t p=waitpid(-1,&status,WNOHANG);return p>0?p:0; }
void os_kill(long pid,long sig) { kill(pid,sig); }

long os_lock_file(const char *path) { int fd=open(path,O_RDWR|O_CREAT|O_CLOEXEC,0600);if(fd<0)return -1;if(flock(fd,LOCK_EX|LOCK_NB)){close(fd);return -1;}return fd; }

/* Generic regular expression search; callers own patterns and interpretation. */
#include <glib.h>
long regex_find(const char *pattern,const char *text,long n,long start,long *span) {
 static GHashTable *patterns;
 if(!patterns)patterns=g_hash_table_new_full(g_str_hash,g_str_equal,g_free,(GDestroyNotify)g_regex_unref);
 GRegex *regex=g_hash_table_lookup(patterns,pattern);
 if(!regex){GError *error=NULL;regex=g_regex_new(pattern,G_REGEX_OPTIMIZE,0,&error);if(!regex){if(error)g_error_free(error);return -1;}g_hash_table_insert(patterns,g_strdup(pattern),regex);}
 GMatchInfo *match=NULL;gboolean found=g_regex_match_full(regex,text,n,start,0,&match,NULL);
 if(found){gint a=0,b=0;g_match_info_fetch_pos(match,0,&a,&b);span[0]=a;span[1]=b;}
 if(match)g_match_info_free(match);return found?1:0;
}
static void rawdom_remove(long address) { xmlNodePtr node=(void*)(intptr_t)address;xmlUnlinkNode(node);xmlFreeNode(node); }

static long rawdom_inner_html(long address,const char *value,long length) {
 xmlNodePtr node=(void*)(intptr_t)address;xmlDocPtr doc=(void*)(intptr_t)rawdom_parse_fragment(value,length);if(!doc)return -1;
 xmlFreeNodeList(node->children);node->children=NULL;node->last=NULL;
 xmlNodePtr root=xmlDocGetRootElement(doc);
 for(xmlNodePtr child=root->children;child;child=child->next)xmlAddChild(node,xmlDocCopyNode(child,node->doc,1));
 xmlFreeDoc(doc);return 0;
}

long unicode_word(const char *utf8) {
  gunichar cp=g_utf8_get_char_validated(utf8,-1);
  if(cp==(gunichar)-1||cp==(gunichar)-2)return 0;
  GUnicodeType t=g_unichar_type(cp);
  return g_unichar_isalnum(cp)||t==G_UNICODE_NON_SPACING_MARK||t==G_UNICODE_SPACING_MARK||t==G_UNICODE_ENCLOSING_MARK||t==G_UNICODE_CONNECT_PUNCTUATION;
}

/* Rails encrypted-cookie primitive; metadata/expiry policy remains in Mojo. */
long cookie_cipher(const char *keyhex,const void *iv,const void *input,long length,void *output,void *tag,long decrypt) {
  unsigned char derived[64];if(unhex(keyhex,derived,64)!=64||length<0||length>8192)return -1;
  EVP_CIPHER_CTX *ctx=EVP_CIPHER_CTX_new();int n=0,final=0,ok=0;
  if(ctx){
    if(decrypt)ok=EVP_DecryptInit_ex(ctx,EVP_aes_256_gcm(),NULL,derived,iv)&&EVP_DecryptUpdate(ctx,output,&n,input,(int)length)&&EVP_CIPHER_CTX_ctrl(ctx,EVP_CTRL_GCM_SET_TAG,16,tag)&&EVP_DecryptFinal_ex(ctx,(unsigned char*)output+n,&final);
    else ok=EVP_EncryptInit_ex(ctx,EVP_aes_256_gcm(),NULL,derived,iv)&&EVP_EncryptUpdate(ctx,output,&n,input,(int)length)&&EVP_EncryptFinal_ex(ctx,(unsigned char*)output+n,&final)&&EVP_CIPHER_CTX_ctrl(ctx,EVP_CTRL_GCM_GET_TAG,16,tag);
  }
  EVP_CIPHER_CTX_free(ctx);OPENSSL_cleanse(derived,sizeof derived);return ok?n+final:-1;
}


/* Opaque, non-reused DOM identifiers. Application integers are never cast to
 * pointers. Deletion invalidates descendants and attributes before libxml frees
 * them, and closing a document invalidates every borrowed handle. Each worker
 * invokes this synchronous API on its single event-loop thread. */
typedef struct { long id; void *pointer; xmlDocPtr owner; int kind; } DomHandle;
static GHashTable *dom_ids, *dom_pointers;
static unsigned long dom_serial;
static DomHandle *dom_get(long id, int kind) {
 if(id<=0 || !dom_ids)return NULL;
 DomHandle *h=g_hash_table_lookup(dom_ids,(void*)(uintptr_t)id);
 return h && h->kind==kind ? h : NULL;
}
static long dom_register(void *pointer,xmlDocPtr owner,int kind) {
 if(!pointer)return 0;
 if(!dom_ids){dom_ids=g_hash_table_new(g_direct_hash,g_direct_equal);dom_pointers=g_hash_table_new(g_direct_hash,g_direct_equal);}
 DomHandle *h=g_hash_table_lookup(dom_pointers,pointer);
 if(h)return h->id;
 if(dom_serial>=(unsigned long)LONG_MAX)return 0;
 h=g_new0(DomHandle,1);h->id=(long)++dom_serial;h->pointer=pointer;h->owner=owner;h->kind=kind;
 g_hash_table_insert(dom_ids,(void*)(uintptr_t)h->id,h);g_hash_table_insert(dom_pointers,pointer,h);return h->id;
}
static void dom_invalidate(void *pointer) {
 if(!pointer || !dom_pointers)return;
 DomHandle *h=g_hash_table_lookup(dom_pointers,pointer);
 if(h){g_hash_table_remove(dom_ids,(void*)(uintptr_t)h->id);g_hash_table_remove(dom_pointers,pointer);g_free(h);}
}
static void dom_invalidate_children(xmlNodePtr node) {
 for(xmlNodePtr child=node->children;child;child=child->next){dom_invalidate_children(child);dom_invalidate(child);}
 for(xmlAttrPtr attr=node->properties;attr;attr=attr->next)dom_invalidate(attr);
}
static long dom_parse_handle(const char *text,long length,int fragment) {
 if(!text || length<0)return 0;
 xmlDocPtr doc=(void*)(intptr_t)(fragment?rawdom_parse_fragment(text,length):rawdom_parse(text,length));
 if(!doc)return 0;
 long id=dom_register(doc,doc,1);if(!id)xmlFreeDoc(doc);return id;
}
long dom_parse(const char *text,long length){return dom_parse_handle(text,length,0);}
long dom_parse_fragment(const char *text,long length){return dom_parse_handle(text,length,1);}
void dom_free(long id) {
 DomHandle *h=dom_get(id,1);if(!h)return;xmlDocPtr doc=h->pointer;
 GHashTableIter it;void *key,*value;g_hash_table_iter_init(&it,dom_ids);
 while(g_hash_table_iter_next(&it,&key,&value)){DomHandle *entry=value;if(entry->owner==doc){g_hash_table_remove(dom_pointers,entry->pointer);g_hash_table_iter_remove(&it);g_free(entry);}}
 rawdom_free((long)(intptr_t)doc);
}
long dom_root(long id){DomHandle *h=dom_get(id,1);return h?dom_register((void*)(intptr_t)rawdom_root((long)(intptr_t)h->pointer),h->owner,2):0;}
long dom_child(long id){DomHandle *h=dom_get(id,2);return h?dom_register((void*)(intptr_t)rawdom_child((long)(intptr_t)h->pointer),h->owner,2):0;}
long dom_next(long id){DomHandle *h=dom_get(id,2);return h?dom_register((void*)(intptr_t)rawdom_next((long)(intptr_t)h->pointer),h->owner,2):0;}
long dom_attrs(long id){DomHandle *h=dom_get(id,2);return h?dom_register((void*)(intptr_t)rawdom_attrs((long)(intptr_t)h->pointer),h->owner,3):0;}
long dom_attr_next(long id){DomHandle *h=dom_get(id,3);return h?dom_register((void*)(intptr_t)rawdom_attr_next((long)(intptr_t)h->pointer),h->owner,3):0;}
long dom_type(long id){DomHandle *h=dom_get(id,2);return h?rawdom_type((long)(intptr_t)h->pointer):0;}
long dom_foreign(long id){DomHandle *h=dom_get(id,2);return h?rawdom_foreign((long)(intptr_t)h->pointer):0;}
const char *dom_name(long id){DomHandle *h=dom_get(id,2);return h?rawdom_name((long)(intptr_t)h->pointer):"";}
const char *dom_text(long id){DomHandle *h=dom_get(id,2);return h?rawdom_text((long)(intptr_t)h->pointer):"";}
const char *dom_attr_name(long id){DomHandle *h=dom_get(id,3);return h?rawdom_attr_name((long)(intptr_t)h->pointer):"";}
const char *dom_attr_text(long id){DomHandle *h=dom_get(id,3);return h?rawdom_attr_text((long)(intptr_t)h->pointer):"";}
void dom_set_name(long id,const char *name){DomHandle *h=dom_get(id,2);if(h)rawdom_set_name((long)(intptr_t)h->pointer,name);}
void dom_set_attr(long id,const char *key,const char *value){DomHandle *h=dom_get(id,2);if(h){xmlNodePtr node=h->pointer;for(xmlAttrPtr a=node->properties;a;a=a->next)dom_invalidate(a);rawdom_set_attr((long)(intptr_t)node,key,value);}}
void dom_clear_node(long id){DomHandle *h=dom_get(id,2);if(h){dom_invalidate_children(h->pointer);rawdom_clear_node((long)(intptr_t)h->pointer);}}
void dom_remove(long id){DomHandle *h=dom_get(id,2);if(h){xmlNodePtr node=h->pointer;dom_invalidate_children(node);dom_invalidate(node);rawdom_remove((long)(intptr_t)node);}}
long dom_replace_text(long id,const char *value){DomHandle *h=dom_get(id,2);if(!h)return -1;xmlNodePtr node=h->pointer;dom_invalidate_children(node);dom_invalidate(node);return rawdom_replace_text((long)(intptr_t)node,value);}
long dom_replace_html(long id,const char *value,long length){DomHandle *h=dom_get(id,2);if(!h || length<0)return -1;xmlNodePtr node=h->pointer;dom_invalidate_children(node);dom_invalidate(node);return rawdom_replace_html((long)(intptr_t)node,value,length);}
long dom_inner_html(long id,const char *value,long length){DomHandle *h=dom_get(id,2);if(!h || length<0)return -1;dom_invalidate_children(h->pointer);return rawdom_inner_html((long)(intptr_t)h->pointer,value,length);}
