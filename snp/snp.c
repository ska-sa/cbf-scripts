#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

#include <sys/socket.h>

#include <netinet/in.h>

#include <arpa/inet.h>

void usage(char *name)
{
  printf("extract network prefix from host and mask\n");
  printf("usage: %s address/mask\n", name);
}

int main(int argc, char **argv)
{
  int i, j, c;
  int quiet;
  char *host, *mask, *app, *ptr;
  
  uint32_t h, m, n, v;
  struct in_addr addr;


  host = NULL;
  mask = NULL;

  quiet = 0;

  i = j = 1;
  app = argv[0];

  while (i < argc) {
    if (argv[i][0] == '-') {
      c = argv[i][j];
      switch (c) {

        case 'h' :
          usage(app);
          return 0;

#if 0
        case 'l' :
        case 's' :

          j++;
          if (argv[i][j] == '\0') {
            j = 0;
            i++;
          }

          if (i >= argc) {
            return EX_USAGE;
          }

          switch(c){
            case 's' :
            case 'l' :
              break;
          }

          i++;
          j = 1;
          break;
#endif

        case 'q' :
          quiet = 1;
          i++;
          break;

        case '-' :
          j++;
          break;
        case '\0':
          j = 1;
          i++;
          break;
        default:
          fprintf(stderr, "%s: unknown option -%c\n", app, argv[i][j]);
          return 2;
      }
    } else {

      if(host == NULL){
        host = argv[i];
        mask = strchr(host, '/');
        if(mask != NULL){
          mask[0] = '\0';
          mask++;
        }
      } else if(mask == NULL){
        mask = argv[i];
      } else {
        fprintf(stderr, "%s: encountered %s after finding host and mask\n", app, argv[i]);
        return 2;
      }

      i++;
    }
  }

  if((host == NULL) || (mask == NULL)){
    fprintf(stderr, "%s: need a host and mask\n", app);
    usage(app);
    return 2;
  }

#ifdef DEBUG
  fprintf(stderr, "have host=%s, mask=%s\n", host, mask);
#endif

  v = inet_addr(host);
  if(v == (-1)){
    fprintf(stderr, "%s: unable to convert %s to host address\n", app, host);
    return 2;
  }
  h = ntohl(v);

  if(strchr(mask, '.')){
    v = inet_network(mask);
    if(v == (-1)){
      fprintf(stderr, "%s: unable to convert %s to network address\n", app, mask);
      return 2;
    }
#if 0
    m = ntohl(v); /* nope, inet_network is host byte order - wouldya believe it */
#endif
    m = v;
  } else {
    v = atoi(mask);
    if(v <= 0 || (v >= 32)){
      fprintf(stderr, "%s: unreasonable network size /%d\n", app, v);
      return 2;
    }
    m = (0xffffffff << (32 - v));
  }

  n = h & m;

#ifdef DEBUG
  fprintf(stderr, "host=0x%08x, mask=0x%08x, net=0x%08x\n", h, m, n);
#endif

  addr.s_addr = htonl(n);

  ptr = inet_ntoa(addr);
  if(ptr == NULL){
    return 2;
  }

  printf("%s\n", ptr);

  return 0;
}
