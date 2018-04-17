#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <errno.h>
#include <sysexits.h>

void usage(char *app)
{
  printf("distribute items of different types into several bins\n");
  printf("%s [-h] [-i items+] [-b bins+] [-s strategy]\n", app);
  printf("-h          this help\n");
  printf("-i count    number of items of a particular type\n");
  printf("-b count    number of slots in the given bin\n");
  printf("-s strategy\n");
}

/* example
 * ./distribute -i 8 8 -b 12 12 8 -s dense
 * 0 0 
 * 1 8
 * 2 8
 */

unsigned int *add_to_vector(unsigned int *vector, char *value, unsigned int size)
{
  unsigned int *tmp;
  unsigned long v;
  char *end;

  v = strtoul(value, &end, 10);

  if(end[0] != '\0'){
    fprintf(stderr, "unable to convert %s to a valid natural number\n", value);
    return NULL;
  }

  tmp = realloc(vector, sizeof(unsigned int) * (size + 1));
  if(tmp == NULL){
    return NULL;
  }

  tmp[size] = v;

  return tmp;
}

#define TAKE_ITEM 0
#define TAKE_BIN  1

int main(int argc, char **argv)
{
  int i, j, c;
  int verbose;
  char *app;
  int flag;

  unsigned int *bins, bin_count;
  unsigned int *items, item_count;
  unsigned int *tmp;

  bins = NULL;
  items = NULL;

  bin_count = 0;
  item_count = 0;

  verbose = 0;
  app = argv[0];

  flag = (-1);

  i = j = 1;
  while (i < argc) {
    if (argv[i][0] == '-') {
      c = argv[i][j];
      switch (c) {

        case 'h' :
          usage(app);
          return 1;
        case 'i' :
          flag = TAKE_ITEM;
          j++;
          if(argv[i][j] != '\0'){
            tmp = add_to_vector(items, argv[i] + j, item_count);
            if(tmp == NULL){
              return EX_USAGE;
            }
            items = tmp;
            item_count++;
          }
          j = 1;
          i++;
          break;
        case 'b' :
          flag = TAKE_BIN;
          j++;
          if(argv[i][j] != '\0'){
            tmp = add_to_vector(bins, argv[i] + j, bin_count);
            if(tmp == NULL){
              return EX_USAGE;
            }
            bins = tmp;
            bin_count++;
          }
          j = 1;
          i++;
          break;
        case 'v' :
          verbose++;
          i++;
          break;
        case 's' :

          j++;
          if (argv[i][j] == '\0') {
            j = 0;
            i++;
          }
          if (i >= argc) {
            fprintf(stderr, "%s: argument needs a parameter\n", app);
            return EX_USAGE;
          }

          printf("using strategy %s\n", argv[i] + j);

          i++;
          j = 1;

        break;
        case '-' :
          j++;
          break;
        case '\0':
          j = 1;
          i++;
          break;
        default:
          fprintf(stderr, "unknown option -%c", c);
          return EX_USAGE;
      }
    } else {
      switch(flag){
        case TAKE_BIN : 
          tmp = add_to_vector(bins, argv[i], bin_count);
          if(tmp == NULL){
            return EX_USAGE;
          }
          bins = tmp;
          bin_count++;
          j = 1;
          break;
        case TAKE_ITEM :
          tmp = add_to_vector(items, argv[i], item_count);
          if(tmp == NULL){
            return EX_USAGE;
          }
          items = tmp;
          item_count++;
          j = 1;
          break;
        default :
          fprintf(stderr, "need to specify -i or -b to start\n");
          return EX_USAGE;
          break;

      }
      i++;
    }
  }

  if((item_count <= 0) || (bin_count <= 0)){
    fprintf(stderr, "nothing to distribute\n");
    return EX_USAGE;
  }

  if(verbose){
    fprintf(stderr, "items:\n");
    for(i = 0; i < item_count; i++){
      fprintf(stderr, "[%u] = %u\n", i, items[i]);
    }
    fprintf(stderr, "bins:\n");
    for(i = 0; i < bin_count; i++){
      fprintf(stderr, "[%u] = %u\n", i, bins[i]);
    }
  }

  /* TODO: now do the allocation */

  return EX_OK;
}
