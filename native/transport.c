/* Generic cryptography and restricted HTTP adapters, not Campfire policy. */
#define _GNU_SOURCE
#define OPENSSL_SUPPRESS_DEPRECATED
#include <openssl/ec.h>
#include <openssl/ecdsa.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <curl/curl.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <poll.h>
#include <time.h>
#include <errno.h>

long hmac_sha256_raw(const void *key,long keylen,const void *value,long length,void *out) {
 unsigned size=0;return HMAC(EVP_sha256(),key,keylen,value,length,out,&size)?(long)size:-1;
}
long p256_generate(void *private_key,void *public_key) {
 EC_KEY *key=EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);if(!key)return -1;
 int ok=EC_KEY_generate_key(key);
 if(ok)ok=BN_bn2binpad(EC_KEY_get0_private_key(key),private_key,32)==32 && EC_POINT_point2oct(EC_KEY_get0_group(key),EC_KEY_get0_public_key(key),POINT_CONVERSION_UNCOMPRESSED,public_key,65,NULL)==65;
 EC_KEY_free(key);return ok?0:-1;
}
static EC_KEY *p256_private(const void *raw) {
 EC_KEY *key=EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);BIGNUM *scalar=BN_bin2bn(raw,32,NULL);
 if(!key||!scalar){EC_KEY_free(key);BN_clear_free(scalar);return NULL;}
 const EC_GROUP *group=EC_KEY_get0_group(key);EC_POINT *public=EC_POINT_new(group);BIGNUM *order=BN_new();
 int ok=public&&order&&EC_GROUP_get_order(group,order,NULL)&&!BN_is_zero(scalar)&&BN_cmp(scalar,order)<0&&EC_KEY_set_private_key(key,scalar)&&EC_POINT_mul(group,public,scalar,NULL,NULL,NULL)&&EC_KEY_set_public_key(key,public);
 EC_POINT_free(public);BN_free(order);BN_clear_free(scalar);if(!ok){EC_KEY_free(key);return NULL;}return key;
}
long p256_public(const void *private_key,void *out) {
 EC_KEY *key=p256_private(private_key);if(!key)return -1;
 int n=EC_POINT_point2oct(EC_KEY_get0_group(key),EC_KEY_get0_public_key(key),POINT_CONVERSION_UNCOMPRESSED,out,65,NULL);EC_KEY_free(key);return n==65?0:-1;
}
long p256_ecdh(const void *private_key,const void *public_key,void *out) {
 EC_KEY *key=p256_private(private_key);if(!key)return -1;
 const EC_GROUP *group=EC_KEY_get0_group(key);EC_POINT *point=EC_POINT_new(group);
 int ok=point&&EC_POINT_oct2point(group,point,public_key,65,NULL)&&EC_POINT_is_on_curve(group,point,NULL)&&!EC_POINT_is_at_infinity(group,point);
 int n=ok?ECDH_compute_key(out,32,point,key,NULL):-1;EC_POINT_free(point);EC_KEY_free(key);return n==32?0:-1;
}
long p256_sign(const void *private_key,const void *data,long length,void *out) {
 EC_KEY *key=p256_private(private_key);if(!key)return -1;unsigned char hash[32];SHA256(data,length,hash);
 ECDSA_SIG *sig=ECDSA_do_sign(hash,32,key);int ok=0;
 if(sig){const BIGNUM *r,*s;ECDSA_SIG_get0(sig,&r,&s);ok=BN_bn2binpad(r,out,32)==32&&BN_bn2binpad(s,(unsigned char*)out+32,32)==32;}
 ECDSA_SIG_free(sig);EC_KEY_free(key);return ok?0:-1;
}
long aes128gcm_encrypt(const void *key,const void *iv,const void *plain,long length,void *out) {
 EVP_CIPHER_CTX *ctx=EVP_CIPHER_CTX_new();if(!ctx)return -1;int n=0,final=0;
 int ok=EVP_EncryptInit_ex(ctx,EVP_aes_128_gcm(),NULL,key,iv)&&EVP_EncryptUpdate(ctx,out,&n,plain,length)&&EVP_EncryptFinal_ex(ctx,(unsigned char*)out+n,&final)&&EVP_CIPHER_CTX_ctrl(ctx,EVP_CTRL_GCM_GET_TAG,16,(unsigned char*)out+n+final);
 EVP_CIPHER_CTX_free(ctx);return ok?n+final+16:-1;
}
static int public_ip(const struct sockaddr *addr) {
 if(addr->sa_family==AF_INET){uint32_t n=ntohl(((const struct sockaddr_in*)addr)->sin_addr.s_addr);
  if((n>>24)==0||(n>>24)==10||(n>>24)==127||(n>>22)==(0x64400000>>22)||(n>>16)==0xa9fe||(n>>20)==(0xac100000>>20)||(n>>16)==0xc0a8||(n>>24)>=224)return 0;
  if((n>>24)==192&&((n>>8)==0xc00000||(n>>8)==0xc00002))return 0;
  if((n>>17)==(0xc6120000>>17)||(n>>8)==0xc63364||(n>>8)==0xcb0071)return 0;
  return 1;
 }
 if(addr->sa_family==AF_INET6){const unsigned char *p=((const struct sockaddr_in6*)addr)->sin6_addr.s6_addr;
  if((p[0]&0xe0)!=0x20)return 0;
  if(p[0]==0x20&&p[1]==0x02)return 0;
  if(p[0]==0x20&&p[1]==0x01&&((p[2]==0&&p[3]==0)||(p[2]==0x0d&&p[3]==0xb8)))return 0;
  return 1;
 }return 0;
}
/* Resolve in a short-lived child: libc DNS cannot extend the request deadline. */
static long clock_ms(void) { struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000+t.tv_nsec/1000000; }
struct resolved_addresses { int count; struct sockaddr_storage addresses[32]; };
static int bounded_dns(const char *host,const char *port,struct resolved_addresses *out,long timeout) {
 int fds[2];if(pipe(fds))return -1;pid_t child=fork();
 if(child<0){close(fds[0]);close(fds[1]);return -1;}
 if(!child){close(fds[0]);struct addrinfo hints={.ai_socktype=SOCK_STREAM,.ai_family=AF_UNSPEC},*ips=NULL;struct resolved_addresses result={0};
  if(!getaddrinfo(host,port,&hints,&ips)){
   for(struct addrinfo *ip=ips;ip;ip=ip->ai_next){if(result.count==32){result.count=0;break;}if(ip->ai_addrlen<=sizeof(struct sockaddr_storage))memcpy(&result.addresses[result.count++],ip->ai_addr,ip->ai_addrlen);}
  }if(ips)freeaddrinfo(ips);size_t sent=0;while(sent<sizeof result){ssize_t n=write(fds[1],(char*)&result+sent,sizeof result-sent);if(n<=0)break;sent+=n;}close(fds[1]);_exit(0);
 }
 close(fds[1]);size_t received=0;long until=clock_ms()+timeout;
 while(received<sizeof *out){long left=until-clock_ms();if(left<=0)break;struct pollfd fd={.fd=fds[0],.events=POLLIN};if(poll(&fd,1,(int)left)<=0)break;ssize_t n=read(fds[0],(char*)out+received,sizeof *out-received);if(n<=0)break;received+=n;}
 close(fds[0]);if(received!=sizeof *out)kill(child,SIGKILL);while(waitpid(child,NULL,0)<0&&errno==EINTR){}return received==sizeof *out&&out->count>0?0:-1;
}
static long restricted_resolve(CURLU *url,char *rule,size_t capacity,long allow_private,long timeout) {
 char *host=NULL,*port=NULL,*scheme=NULL,*user=NULL,*password=NULL;long rc=-2;
 if(curl_url_get(url,CURLUPART_HOST,&host,0)||curl_url_get(url,CURLUPART_PORT,&port,CURLU_DEFAULT_PORT)||curl_url_get(url,CURLUPART_SCHEME,&scheme,0))goto done;
 curl_url_get(url,CURLUPART_USER,&user,0);curl_url_get(url,CURLUPART_PASSWORD,&password,0);
 if((user&&*user)||(password&&*password)||strlen(host)>253||(strcmp(scheme,"http")&&strcmp(scheme,"https")))goto done;
 char lookup[256];snprintf(lookup,sizeof lookup,"%s",host);
 if(lookup[0]=='['){memmove(lookup,lookup+1,strlen(lookup));char *end=strchr(lookup,']');if(end)*end=0;}
 if(strchr(lookup,'%'))goto done;
 struct resolved_addresses ips;if(bounded_dns(lookup,port,&ips,timeout<2000?timeout:2000)){rc=-4;goto done;}
 for(int i=0;i<ips.count;i++)if(!allow_private&&!public_ip((struct sockaddr*)&ips.addresses[i]))goto done;
 struct sockaddr_storage *first=&ips.addresses[0];char address[INET6_ADDRSTRLEN];const void *binary=first->ss_family==AF_INET?(const void*)&((struct sockaddr_in*)first)->sin_addr:(const void*)&((struct sockaddr_in6*)first)->sin6_addr;
 if(!inet_ntop(first->ss_family,binary,address,sizeof address))goto done;
 int n=snprintf(rule,capacity,"%s:%s:%s%s%s",host,port,first->ss_family==AF_INET6?"[":"",address,first->ss_family==AF_INET6?"]":"");
 if(n<0||(size_t)n>=capacity)goto done;rc=0;
 done:curl_free(host);curl_free(port);curl_free(scheme);curl_free(user);curl_free(password);return rc;
}
long url_component(const char *url,long component,char *output,long capacity) {
 CURLU *p=curl_url();char *value=NULL;long rc=-1;
 if(p&&!curl_url_set(p,CURLUPART_URL,url,0)&&!curl_url_get(p,component==0?CURLUPART_HOST:component==1?CURLUPART_SCHEME:CURLUPART_PATH,&value,0)&&strlen(value)<(size_t)capacity){strcpy(output,value);rc=strlen(value);}
 curl_free(value);curl_url_cleanup(p);return rc;
}
long net_validate(const char *url) {
 CURLU *parsed=curl_url();if(!parsed)return -1;char rule[600];long rc=-2;
 if(!curl_url_set(parsed,CURLUPART_URL,url,0))rc=restricted_resolve(parsed,rule,sizeof rule,0,2000);
 curl_url_cleanup(parsed);return rc;
}
struct response_buffer {char *bytes;long used,capacity,allocated;};
static size_t receive_body(char *ptr,size_t size,size_t count,void *context) {
 struct response_buffer *b=context;if(size&&count>SIZE_MAX/size)return 0;size_t n=size*count;if(n>(size_t)(b->capacity-b->used))return 0;
 if(b->used+(long)n>b->allocated){long next=b->allocated?b->allocated*2:4096;if(next<b->used+(long)n)next=b->used+(long)n;if(next>b->capacity)next=b->capacity;void *p=realloc(b->bytes,(size_t)next);if(!p)return 0;b->bytes=p;b->allocated=next;}
 if(n)memcpy(b->bytes+b->used,ptr,n);b->used+=n;return n;
}
long net_request(const char *url,const char *method,const char *header_lines,const void *body,long length,void **output,long capacity,long *received,long allow_private,char *content_type,char *location,long timeout) {
 struct response_buffer buffer={NULL,0,capacity,0};*output=NULL;*received=0;
 long started=clock_ms();
 CURLU *parsed=curl_url();CURL *curl=NULL;struct curl_slist *resolved=NULL,*headers=NULL;char rule[600];long status=-2;
 if(!parsed||curl_url_set(parsed,CURLUPART_URL,url,0))goto done;
 status=restricted_resolve(parsed,rule,sizeof rule,allow_private,timeout);if(status)goto done;
 curl=curl_easy_init();if(!curl){status=-1;goto done;}
 resolved=curl_slist_append(NULL,rule);char *copy=strdup(header_lines),*save=NULL;
 for(char *line=strtok_r(copy,"\n",&save);line;line=strtok_r(NULL,"\n",&save)){
  if(strchr(line,'\r')){free(copy);goto done;}headers=curl_slist_append(headers,line);
 }free(copy);
 curl_easy_setopt(curl,CURLOPT_URL,url);curl_easy_setopt(curl,CURLOPT_RESOLVE,resolved);
 curl_easy_setopt(curl,CURLOPT_PROXY,"");curl_easy_setopt(curl,CURLOPT_PROTOCOLS_STR,"http,https");
 const char *ca_bundle=getenv("CAMPFIRE_CA_BUNDLE");
 if(ca_bundle&&*ca_bundle)curl_easy_setopt(curl,CURLOPT_CAINFO,ca_bundle);
 long remaining=timeout-(clock_ms()-started);if(remaining<=0){status=-3;goto done;}
 curl_easy_setopt(curl,CURLOPT_FOLLOWLOCATION,0L);curl_easy_setopt(curl,CURLOPT_CONNECTTIMEOUT_MS,remaining<7000?remaining:7000);curl_easy_setopt(curl,CURLOPT_TIMEOUT_MS,remaining);curl_easy_setopt(curl,CURLOPT_NOSIGNAL,1L);
 curl_easy_setopt(curl,CURLOPT_WRITEFUNCTION,receive_body);curl_easy_setopt(curl,CURLOPT_WRITEDATA,&buffer);curl_easy_setopt(curl,CURLOPT_HTTPHEADER,headers);
 if(!strcmp(method,"HEAD"))curl_easy_setopt(curl,CURLOPT_NOBODY,1L);
 curl_easy_setopt(curl,CURLOPT_CUSTOMREQUEST,method);curl_easy_setopt(curl,CURLOPT_ACCEPT_ENCODING,"");
 if(length>=0){curl_easy_setopt(curl,CURLOPT_POSTFIELDS,body);curl_easy_setopt(curl,CURLOPT_POSTFIELDSIZE_LARGE,(curl_off_t)length);}
 CURLcode result=curl_easy_perform(curl);*received=buffer.used;status=-1;
 if(result==CURLE_OK){curl_easy_getinfo(curl,CURLINFO_RESPONSE_CODE,&status);char *type=NULL;curl_easy_getinfo(curl,CURLINFO_CONTENT_TYPE,&type);if(type)snprintf(content_type,256,"%s",type);char *redirect=NULL;curl_easy_getinfo(curl,CURLINFO_REDIRECT_URL,&redirect);if(redirect&&strlen(redirect)<8192)strcpy(location,redirect);}
 if(result==CURLE_OPERATION_TIMEDOUT)status=-3;
 done:*output=buffer.bytes;*received=buffer.used;curl_easy_cleanup(curl);curl_slist_free_all(resolved);curl_slist_free_all(headers);curl_url_cleanup(parsed);return status;
}
long p256_validate_public(const void *public_key) {
 EC_GROUP *group=EC_GROUP_new_by_curve_name(NID_X9_62_prime256v1);if(!group)return 0;EC_POINT *point=EC_POINT_new(group);
 int ok=point&&EC_POINT_oct2point(group,point,public_key,65,NULL)&&EC_POINT_is_on_curve(group,point,NULL)&&!EC_POINT_is_at_infinity(group,point);
 EC_POINT_free(point);EC_GROUP_free(group);return ok;
}
