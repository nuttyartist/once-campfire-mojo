/* Generic runtime adapters. Application policy and protocols live in Mojo. */
#define _GNU_SOURCE
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <crypt.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

long crypto_hash(const void *data, long n, long sha256, void *out) {
  unsigned size;
  return EVP_Digest(data, n, out, &size, sha256 ? EVP_sha256() : EVP_sha1(), NULL) ? size : -1;
}
long password_hash(const char *password, char *out) {
  char entropy[16], salt[CRYPT_GENSALT_OUTPUT_SIZE];
  struct crypt_data data = {0};
  if (RAND_bytes((void *)entropy, sizeof entropy) != 1 ||
      !crypt_gensalt_rn("$2b$", 12, entropy, sizeof entropy, salt, sizeof salt)) return -1;
  char *value = crypt_r(password, salt, &data);
  if (!value || strlen(value) != 60) return -1;
  memcpy(out, value, 61); return 0;
}
long fs_mkdirs(const char *path) {
  char *p = strdup(path); if (!p) return -1;
  for (char *c=p+1; *c; c++) if (*c=='/') {
    *c=0; if (mkdir(p,0700) && errno!=EEXIST) { free(p);return -1; } *c='/';
  }
  int rc=mkdir(p,0700); free(p); return rc && errno!=EEXIST ? -1 : 0;
}
/* Open relative to a trusted directory, rejecting symlinks in every component. */
long fs_open_beneath(const char *root, const char *relative) {
  if (!*relative || *relative=='/') return -1;
  int directory=open(root,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
  if (directory<0) return -1;
  char *copy=strdup(relative), *save=NULL, *part=strtok_r(copy,"/",&save);
  while (part) {
    if (!strcmp(part,".") || !strcmp(part,"..")) { close(directory);free(copy);return -1; }
    char *next=strtok_r(NULL,"/",&save);
    int fd=openat(directory,part,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|(next?O_DIRECTORY:0));
    close(directory);directory=fd;
    if (fd<0) break;
    part=next;
  }
  free(copy);return directory;
}
long fs_size(long fd) { struct stat st; return fstat(fd,&st) || !S_ISREG(st.st_mode) ? -1 : st.st_size; }
long fs_read(long fd, void *out, long size, long offset) { return pread(fd,out,size,offset); }

/* Bounded process-shared pub/sub log. Lagging consumers detect overwrite and
   reconnect; they never silently skip delivery. No channel policy lives here. */
#define BUS_SLOTS 64
#define BUS_BYTES (1024*1024)
struct event { long sequence, length; char bytes[BUS_BYTES]; };
static struct bus { pthread_mutex_t mutex; long sequence; struct event events[BUS_SLOTS]; } *bus;
long bus_init(void) {
  bus=mmap(NULL,sizeof(*bus),PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANONYMOUS,-1,0);
  if (bus==MAP_FAILED) return -1;
  pthread_mutexattr_t attr; pthread_mutexattr_init(&attr);
  pthread_mutexattr_setpshared(&attr,PTHREAD_PROCESS_SHARED);
  int rc=pthread_mutex_init(&bus->mutex,&attr);pthread_mutexattr_destroy(&attr);return rc;
}
long bus_sequence(void) {
  pthread_mutex_lock(&bus->mutex);long n=bus->sequence;pthread_mutex_unlock(&bus->mutex);return n;
}
long bus_publish(const void *bytes, long length) {
  if (length<0 || length>BUS_BYTES) return -1;
  pthread_mutex_lock(&bus->mutex);
  long seq=++bus->sequence;struct event *e=&bus->events[seq%BUS_SLOTS];
  memcpy(e->bytes,bytes,length);e->length=length;e->sequence=seq;
  pthread_mutex_unlock(&bus->mutex);return seq;
}
long bus_read(long seq, void *bytes, long capacity) {
  pthread_mutex_lock(&bus->mutex);
  struct event *e=&bus->events[seq%BUS_SLOTS];long n=e->length;
  if(seq>bus->sequence)n=0;
  else if(e->sequence!=seq || n>capacity)n=-1;
  else memcpy(bytes,e->bytes,n);
  pthread_mutex_unlock(&bus->mutex);return n;
}

#include "../vendor/qrcodegen/qrcodegen.h"
long qr_encode(const char *text, void *output) {
 uint8_t temporary[qrcodegen_BUFFER_LEN_MAX];
 return qrcodegen_encodeText(text,temporary,output,qrcodegen_Ecc_LOW,qrcodegen_VERSION_MIN,qrcodegen_VERSION_MAX,qrcodegen_Mask_AUTO,true) ? qrcodegen_getSize(output) : -1;
}
long qr_module(const void *qr,long x,long y) { return qrcodegen_getModule(qr,x,y); }

long crypto_md5(const void *data,long length,void *out) {
  unsigned n; return EVP_Digest(data,length,out,&n,EVP_md5(),NULL)?n:-1;
}
long fs_write_new(const char *path,const void *bytes,long size) {
  int fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0600);
  if(fd<0)return -1;
  long offset=0;while(offset<size){ssize_t n=write(fd,(const char*)bytes+offset,size-offset);if(n<0&&errno==EINTR)continue;if(n<=0){close(fd);unlink(path);return -1;}offset+=n;}
  if(fsync(fd)){close(fd);unlink(path);return -1;}return close(fd);
}
long fs_unlink(const char *path) { return unlink(path); }

#include <vips/vips.h>
static void image_initialize(void) {
  static int started=0;
  if(!started){vips_init("campfire-mojo");vips_cache_set_max_mem(64*1024*1024);vips_cache_set_max(32);vips_concurrency_set(2);started=1;}
}
long image_dimensions(const void *bytes,long length,long *dimensions) {
  image_initialize();
  VipsImage *im=vips_image_new_from_buffer(bytes,length,"",NULL);
  if(!im){vips_error_clear();return -1;}
  dimensions[0]=vips_image_get_width(im);dimensions[1]=vips_image_get_height(im);
  g_object_unref(im);return 0;
}
long image_thumbnail(const void *bytes,long length,long width,long height,long crop,void **out,long *size) {
  image_initialize();long dims[2];
  if(width<1||height<1||width>4096||height>4096||image_dimensions(bytes,length,dims)||dims[0]<1||dims[1]<1||dims[0]>250000000/dims[1])return -1;
  VipsImage *thumb=NULL;size_t n=0;
  if(vips_thumbnail_buffer((void*)bytes,length,&thumb,width,"height",(int)height,"crop",crop?VIPS_INTERESTING_CENTRE:VIPS_INTERESTING_NONE,"size",VIPS_SIZE_DOWN,NULL)){vips_error_clear();return -1;}
  int rc=vips_webpsave_buffer(thumb,out,&n,NULL);g_object_unref(thumb);
  if(rc){vips_error_clear();return -1;}*size=(long)n;return 0;
}
void buffer_free(void *p) { g_free(p); }
