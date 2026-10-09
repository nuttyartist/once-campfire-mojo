/* Bounded generic subprocess adapter. Never invokes a shell. */
#define _GNU_SOURCE
#include <unistd.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <sys/mman.h>
#include <poll.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static long now_ms(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000+t.tv_nsec/1000000;}
long process_capture(const char *command,const char *arguments,long args_size,const void *input,long input_size,void *output,long capacity,long timeout,long *output_size,long seekable) {
 if(args_size<1||args_size>65536||timeout<1||timeout>60000)return -1;
 char *args=malloc(args_size+1);if(!args)return -1;memcpy(args,arguments,args_size);args[args_size]=0;
 char *argv[128];int count=1;argv[0]=(char*)command;
 for(long i=0;i<args_size;){if(count>=127){free(args);return -1;}argv[count++]=args+i;long n=strnlen(args+i,args_size-i);i+=n+1;}argv[count]=NULL;
 int in[2]={-1,-1},out[2];
 if(seekable){in[0]=memfd_create("campfire-media",MFD_CLOEXEC);if(in[0]<0){free(args);return -1;}long done=0;while(done<input_size){ssize_t n=write(in[0],(const char*)input+done,input_size-done);if(n<0&&errno==EINTR)continue;if(n<=0){close(in[0]);free(args);return -1;}done+=n;}lseek(in[0],0,SEEK_SET);}
 else if(pipe2(in,O_CLOEXEC)){free(args);return -1;}
 if(pipe2(out,O_CLOEXEC)){close(in[0]);close(in[1]);free(args);return -1;}
 pid_t child=fork();if(child<0){close(in[0]);close(in[1]);close(out[0]);close(out[1]);free(args);return -1;}
 if(!child){setpgid(0,0);dup2(in[0],STDIN_FILENO);dup2(out[1],STDOUT_FILENO);int null=open("/dev/null",O_WRONLY);if(null>=0)dup2(null,STDERR_FILENO);close_range(3,~0U,0);
  struct rlimit memory={2147483648ULL,2147483648ULL},cpu={15,15},files={64,64};setrlimit(RLIMIT_AS,&memory);setrlimit(RLIMIT_CPU,&cpu);setrlimit(RLIMIT_NOFILE,&files);execv(command,argv);_exit(127);
 }
 free(args);setpgid(child,child);close(in[0]);close(out[1]);fcntl(in[1],F_SETFL,O_NONBLOCK);fcntl(out[0],F_SETFL,O_NONBLOCK);
 long sent=0,used=0,deadline=now_ms()+timeout;int result=-1,exited=0,status=0;
 while(now_ms()<deadline){
  if(in[1]>=0&&sent==input_size){close(in[1]);in[1]=-1;}
  struct pollfd fds[2]={{.fd=in[1],.events=POLLOUT},{.fd=out[0],.events=POLLIN}};
  int n=poll(fds,2,50);if(n<0&&errno!=EINTR)break;
  if(in[1]>=0&&(fds[0].revents&POLLOUT)){ssize_t n=write(in[1],(char*)input+sent,input_size-sent);if(n>0)sent+=n;else if(n<0&&errno!=EAGAIN&&errno!=EINTR){close(in[1]);in[1]=-1;}}
  if(in[1]>=0&&(fds[0].revents&(POLLERR|POLLHUP))){close(in[1]);in[1]=-1;}
  if(out[0]>=0&&(fds[1].revents&(POLLIN|POLLHUP|POLLERR))){char extra;ssize_t n=read(out[0],used<capacity?(char*)output+used:&extra,used<capacity?capacity-used:1);if(n>0){if(used+n>capacity)break;used+=n;}else if(!n){close(out[0]);out[0]=-1;}}
  if(!exited){pid_t got=waitpid(child,&status,WNOHANG);if(got==child)exited=1;}
  if(exited&&out[0]<0){result=WIFEXITED(status)&&WEXITSTATUS(status)==0?0:-1;break;}
 }
 if(in[1]>=0)close(in[1]);if(out[0]>=0)close(out[0]);if(!exited){kill(-child,SIGKILL);while(waitpid(child,&status,0)<0&&errno==EINTR){}}
 *output_size=used;return result;
}
