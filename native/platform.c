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
