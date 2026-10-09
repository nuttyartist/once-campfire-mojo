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
#include <time.h>
#include <unistd.h>
#include <zlib.h>

long os_listen(long port) {
  signal(SIGPIPE, SIG_IGN);
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0),
      one = 1;
  if (fd < 0)
    return -1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  struct sockaddr_in a = {.sin_family = AF_INET,
                          .sin_port = htons((uint16_t)port)};
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
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
  int rc = poll(p, (nfds_t)n, 1000);
  for (long i = 0; i < n; i++)
    ready[i] = p[i].revents;
  return rc;
}
long os_fork(void) { return fork(); }
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
  return sqlite3_bind_text((sqlite3_stmt *)(intptr_t)s, (int)i, text, -1,
                           SQLITE_TRANSIENT);
}
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
long dom_parse(const char *html, long n) {
  return (long)(intptr_t)htmlReadMemory(html,(int)n,NULL,"UTF-8",HTML_PARSE_RECOVER|HTML_PARSE_NONET|HTML_PARSE_NOERROR|HTML_PARSE_NOWARNING);
}
void dom_free(long doc) { xmlFreeDoc((xmlDocPtr)(intptr_t)doc); }
long dom_root(long doc) { return (long)(intptr_t)xmlDocGetRootElement((xmlDocPtr)(intptr_t)doc); }
long dom_child(long node) { return (long)(intptr_t)((xmlNodePtr)(intptr_t)node)->children; }
long dom_next(long node) { return (long)(intptr_t)((xmlNodePtr)(intptr_t)node)->next; }
long dom_type(long node) { return ((xmlNodePtr)(intptr_t)node)->type; }
const char *dom_name(long node) { const char *p=(const char*)((xmlNodePtr)(intptr_t)node)->name;return p?p:""; }
const char *dom_text(long node) { const char *p=(const char*)((xmlNodePtr)(intptr_t)node)->content;return p?p:""; }
long dom_attrs(long node) { return (long)(intptr_t)((xmlNodePtr)(intptr_t)node)->properties; }
long dom_attr_next(long attr) { return (long)(intptr_t)((xmlAttrPtr)(intptr_t)attr)->next; }
const char *dom_attr_name(long attr) { return (const char*)((xmlAttrPtr)(intptr_t)attr)->name; }
const char *dom_attr_text(long attr) { xmlNodePtr n=((xmlAttrPtr)(intptr_t)attr)->children;return n&&n->content?(const char*)n->content:""; }

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
long metric_add(long index,long delta) { return atomic_fetch_add(&queue->metrics[index],delta); }
long metric_get(long index) { return atomic_load(&queue->metrics[index]); }
long file_append(const char *path,const void *value,long length) {
  int fd=open(path,O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC,0600);if(fd<0)return -1;
  long n=write(fd,value,(size_t)length);close(fd);return n==length?0:-1;
}
