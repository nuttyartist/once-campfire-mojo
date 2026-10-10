/* Test-only DNS/connect interposer. Never linked into the application. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int getaddrinfo(const char *node,const char *service,const struct addrinfo *hints,struct addrinfo **res) {
  static int (*real)(const char*,const char*,const struct addrinfo*,struct addrinfo**);
  if(!real)real=dlsym(RTLD_NEXT,"getaddrinfo");
  if(node&&!strcmp(node,"audit-provider.fcm.googleapis.com")) {
    const char *path=getenv("CAMPFIRE_TEST_NET_STATE");
    FILE *f=path?fopen(path,"r"):NULL;int state=f?fgetc(f):'d';if(f)fclose(f);
    if(state=='d')return EAI_AGAIN;
    return real("93.184.216.34",service,hints,res);
  }
  if(node&&!strcmp(node,"audit-slow.example.com")) {
    const char *path=getenv("CAMPFIRE_TEST_DNS_ENTERED");
    FILE *f=path?fopen(path,"w"):NULL;if(f){fputs("entered",f);fclose(f);}
    sleep(4);return EAI_AGAIN;
  }
  return real(node,service,hints,res);
}

int connect(int fd,const struct sockaddr *address,socklen_t size) {
  static int (*real)(int,const struct sockaddr*,socklen_t);
  if(!real)real=dlsym(RTLD_NEXT,"connect");
  if(address->sa_family==AF_INET) {
    const struct sockaddr_in *in=(const struct sockaddr_in*)address;
    const char *port=getenv("CAMPFIRE_TEST_PROVIDER_PORT");
    if(port&&in->sin_addr.s_addr==inet_addr("93.184.216.34")&&in->sin_port==htons(443)) {
      struct sockaddr_in local=*in;local.sin_addr.s_addr=htonl(INADDR_LOOPBACK);local.sin_port=htons(atoi(port));
      return real(fd,(const struct sockaddr*)&local,sizeof local);
    }
  }
  return real(fd,address,size);
}

int unlink(const char *path) {
  static int (*real)(const char*);
  if(!real)real=dlsym(RTLD_NEXT,"unlink");
  const char *state=getenv("CAMPFIRE_TEST_UNLINK_STATE"),*root=getenv("STORAGE_PATH");
  if(state&&root&&!strncmp(path,root,strlen(root))&&path[strlen(root)]=='/') {
    FILE *f=fopen(state,"r");int mode=f?fgetc(f):0;if(f)fclose(f);
    if(mode=='d'){errno=EACCES;return -1;}
  }
  return real(path);
}

/* Hold one decoder call, without changing its result, to expose writer locks. */
int vips_image_get_width(void *image) {
  static int (*real)(void*);
  if(!real)real=dlsym(RTLD_NEXT,"vips_image_get_width");
  const char *path=getenv("CAMPFIRE_TEST_MEDIA_ENTERED");
  if(path) {
    FILE *f=fopen(path,"wx");
    if(f){fputs("entered",f);fclose(f);sleep(3);}
  }
  return real(image);
}
