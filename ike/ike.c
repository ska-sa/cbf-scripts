#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fcntl.h>
#include <unistd.h>

#include <errno.h>

#define STATE_FAIL   (-1)
#define STATE_OK       0

#define STATE_COMMENT  1
#define STATE_KEY      2
#define STATE_VALUE    3
#define STATE_SECTION  4
#define STATE_START    5

#define FLAG_PERMIT_EMPTY  0x1

#define FLAG_FUSSY     0x2      /* parse things strictly */
#define FLAG_ONLY      0x4      /* only output the value field */
#define FLAG_SKIP      0x8      /* do not show the section */

/********************************/

#define SF_TRIM       0x4
#define SF_DYNAMIC    0x2
#define SF_ERROR      0x1

#define SF_INCREMENT  64

#define DEBUG

struct stringfy{
  char *s_ptr;
  unsigned int s_size;
  unsigned int s_used;
  unsigned int s_flags;
};

void clear_stringfy(struct stringfy *sx)
{
  sx->s_used = 0;
  sx->s_flags &= ~SF_ERROR;
}

struct stringfy *init_stringfy(struct stringfy *s, unsigned int flags)
{
  struct stringfy *sx;
  
  if(s == NULL){
    sx = malloc(sizeof(struct stringfy));
    if(sx == NULL){
      return NULL;
    }
    sx->s_flags = SF_DYNAMIC;
  } else {
    sx = s;
    sx->s_flags = 0;
  }

  sx->s_flags |= flags & (SF_TRIM);

  sx->s_ptr = NULL;
  sx->s_size = 0;
  sx->s_used = 0;

  return sx;
}

void release_stringfy(struct stringfy *sx)
{
  if(sx == NULL){
    return;
  }

  if(sx->s_ptr){
    free(sx->s_ptr);
    sx->s_ptr = NULL;
  }

  sx->s_used = 0;
  sx->s_size = 0;

  if(sx->s_flags & SF_DYNAMIC){
    sx->s_flags = 0;
    free(sx);
  }
}

int append_stringfy(struct stringfy *sx, int c)
{
  char *ptr;

  if(sx->s_used >= sx->s_size){
    ptr = realloc(sx->s_ptr, sx->s_used + SF_INCREMENT); 
    if(ptr == NULL){
      sx->s_flags |= SF_ERROR;
      return -1;
    }
    sx->s_ptr = ptr;
  }

  sx->s_ptr[sx->s_used] = c;

  if(sx->s_flags & SF_TRIM){
    if((sx->s_used > 0) || ((c != ' ') && (c != '\t'))){
      sx->s_used++;
    }
  } else {
    sx->s_used++;
  }

  return 0;
}

static void trim_stringfy(struct stringfy *sx)
{
  int i;

  if((sx->s_flags & SF_TRIM) == 0){
    return;
  }

  for(i = sx->s_used - 1; i >= 0; i--){
    switch(sx->s_ptr[i]){
      case ' '  :
      case '\t' : 
        break;
      default :
        sx->s_used = i + 1;
        return;
    }
  }

  sx->s_used = 0;
}

char *ptr_stringfy(struct stringfy *sx)
{
  char *ptr;

  if(sx->s_flags & SF_ERROR){
    return NULL;
  }

  trim_stringfy(sx);

  if(sx->s_used >= sx->s_size){
    ptr = realloc(sx->s_ptr, sx->s_used + SF_INCREMENT); 
    if(ptr == NULL){
      sx->s_flags |= SF_ERROR;
      return NULL;
    }
    sx->s_ptr = ptr;
  }

  sx->s_ptr[sx->s_used] = '\0';

  return sx->s_ptr;
}

int len_stringfy(struct stringfy *sx)
{
  if(sx->s_flags & SF_ERROR){
    return -1;
  }

  trim_stringfy(sx);

  return sx->s_used;
}

/***************************************************************************************/

int show(FILE *out, char *section, char *key, struct stringfy *ss, struct stringfy *sk, struct stringfy *sv, unsigned int flags)
{
  int lx;
  char *ptr;

  if(len_stringfy(sk) <= 0){
    return -1;
  }

  lx = len_stringfy(sv);
  if(lx <= 0){
    if(lx < 0){
      return -1;
    } else {
      return 0;
    }
  }

  lx = len_stringfy(ss);
  if(lx < 0){
    return -1;
  }

  if(section){
    ptr = ptr_stringfy(ss);
    if(ptr != NULL){
      if(strcmp(ptr, section)){
#ifdef DEBUG
        fprintf(stderr, "%s != %s, dropping section\n", ptr, section);
#endif      
        return 0;
      }
    }
  }

  if(key){
    ptr = ptr_stringfy(sk);
    if(ptr == NULL){
      return -1;
    }
    if(strcmp(ptr, key)){
#ifdef DEBUG
      fprintf(stderr, "%s != %s, dropping key\n", ptr, key);
#endif      
      return 0;
    }
  }

  if(flags & FLAG_ONLY){
    fprintf(out, "%s\n", ptr_stringfy(sv));
  } else {
    if(lx > 0){
      fprintf(out, "%s.", ptr_stringfy(ss));
    }
    fprintf(out, "%s=%s\n", ptr_stringfy(sk), ptr_stringfy(sv));
  }

  return 0;
}

int rewrite(FILE *in, FILE *out, char *section, char *key, unsigned int flags)
{
  int state;
  int c;
  int unusual, line;

  struct stringfy *ss, *sk, *sv;

  ss = init_stringfy(NULL, SF_TRIM);
  sk = init_stringfy(NULL, SF_TRIM);
  sv = init_stringfy(NULL, SF_TRIM);

  if((ss == NULL) || 
     (sk == NULL) || 
     (sv == NULL)){
    return -1;
  }

  unusual = 0;
  state = STATE_START;

  while(state > 0){
    c = fgetc(in);

    switch(state){
      case STATE_START :
        switch(c){
          case '\r' :
          case '\n' :
          case '\t' :
          case ' '  :
            break;
          case '#'  :
            state = STATE_COMMENT;
            break;
          case '[' :
            clear_stringfy(ss);
            state = STATE_SECTION;
            break;
          default :
            clear_stringfy(sk);
            append_stringfy(sk, c);
            state = STATE_KEY;
            break;
        }
      break;
      case STATE_SECTION :
        switch(c){
          case ']' :
            state = STATE_START;
            break;
          case '#'  :
          case '\n' :
          case '\r' :
            unusual++;
            if(flags & FLAG_FUSSY){
               state = STATE_FAIL;
               break;
            }
          default :
            append_stringfy(ss, c);
            break;
        }
      break;
      case STATE_KEY :
        switch(c){
          case '=' :
            state = STATE_VALUE;
            clear_stringfy(sv);
            break;
          case '#' :
          case '\n' :
          case '\r' :
            unusual++;
            if(flags & FLAG_FUSSY){
               state = STATE_FAIL;
               break;
            }
          default :
            append_stringfy(sk, c);
            break;
        }
      break;
      case STATE_VALUE :
        switch(c){
          case '\n' :
          case '\r' :
            show(out, section, key, ss, sk, sv, flags);
            state = STATE_START;
            break;
          case '#' :
            show(out, section, key, ss, sk, sv, flags);
            state = STATE_COMMENT;
            break;
          default :
            append_stringfy(sv, c);
            break;
        }
      break;
      case STATE_COMMENT : 
        switch(c){
          case '\n' :
            state = STATE_START;
            break;
        }
        break;
    }

    switch(c){
      case EOF :
#ifdef DEBUG
        fprintf(stderr, "saw eof, ending\n");
#endif
        switch(state){
          case STATE_START :
            state = STATE_OK;
            break;
          default :
            state = STATE_FAIL;
            break;
        }
        break;
      case '\n' :
        line++;
        break;
    }

  }

  release_stringfy(ss);
  release_stringfy(sk);
  release_stringfy(sv);

  if(state < 0){
    return -1;
  }

  return 0;
}

void usage(char *app)
{
  printf("%s [-h] [-o] [file]\n", app);
  printf("-h    this help\n");
  printf("-o    only print value\n");
  printf("-r    relaxed - do not fail on poorly formed fields\n");
  printf("-s section   select only fields within the specified section\n");
  printf("-k key       show only fields with the specified key\n");
}

int main(int argc, char **argv)
{
  int i, j, c;
  int verbose, count, only;
  unsigned int flags;
  FILE *fp;
  char *section, *key, *app;

  verbose = 0;
  count = 0;
  app = argv[0];

  section = NULL;
  key = NULL;
  flags = 0;

  flags |= FLAG_FUSSY;

  i = j = 1;
  while (i < argc) {
    if (argv[i][0] == '-') {
      c = argv[i][j];
      switch (c) {

        case 'h' :
          usage(app);
          return 1;
        case 'o' :
          flags |= FLAG_ONLY;
          i++;
          break;
        case 'r' :
          flags &= ~FLAG_FUSSY;
          i++;
          break;
        case 'v' :
          verbose++;
          i++;
          break;
        case 's' :
        case 'k' :

          j++;
          if (argv[i][j] == '\0') {
            j = 0;
            i++;
          }
          if (i >= argc) {
            fprintf(stderr, "%s: argument needs a parameter\n", app);
            return 2;
          }

          switch(c){
            case 's' :
              section = argv[i] + j;
              break;
            case 'k' :
              key = argv[i] + j;
              break;
          }

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
          return 2;
      }
    } else {
      fp = fopen(argv[i], "r");
      if(fp == NULL){
        fprintf(stderr, "unable to open %s: %s\n", argv[i], strerror(errno));
        return 4;
      }

      if(rewrite(fp, stdout, section, key, flags) < 0){
        fclose(fp);
        return 3;
      }

      fclose(fp);

      count++;
      i++;
    }
  }

  if(count == 0){
    if(rewrite(stdin, stdout, section, key, flags) < 0){
      return 3;
    }
  }

  return 0;
}
