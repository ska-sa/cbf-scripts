#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>

#include <ncurses.h>
#include <netc.h>
#include <katcp.h>
#include <katcl.h>
#include <katpriv.h>

#define DAY  86400
#define SCALE 1000

struct ct_row{
  int c_level;
  unsigned long c_time;
  char *c_module;
  char *c_message;

  struct ct_row *c_next;
  struct ct_row *c_same;
  unsigned int c_refs;
};

unsigned int PREFIX = 8;

static volatile int ct_finished = 0;
unsigned long ct_allocated = 0;
time_t ct_base = 0;

struct ct_row *ct_vector[KATCP_MAX_LEVELS] = { NULL, NULL, NULL, NULL, NULL, NULL, NULL } ;
struct ct_row *ct_recent = NULL;

int ct_map[KATCP_MAX_LEVELS];

/************************************************************/

int ct_color_setup()
{
  unsigned int c;

  start_color();
  if(has_colors()){
    c = 0;

    if(init_pair(++c, COLOR_BLUE, COLOR_BLACK) == ERR){
      fprintf(stderr, "init pair for %d failed\n", c);
      return -1;
    }
    ct_map[KATCP_LEVEL_TRACE] = A_DIM | COLOR_PAIR(c);

    if(init_pair(++c, COLOR_WHITE, COLOR_BLACK) == ERR){
      fprintf(stderr, "init pair for %d failed\n", c);
      return -1;
    }
    ct_map[KATCP_LEVEL_DEBUG] = A_DIM | COLOR_PAIR(c);
    ct_map[KATCP_LEVEL_INFO] = A_NORMAL | COLOR_PAIR(c);

    if(init_pair(++c, COLOR_YELLOW, COLOR_BLACK) == ERR){
      fprintf(stderr, "init pair for %d failed\n", c);
      return -1;
    }
    ct_map[KATCP_LEVEL_WARN] = A_BOLD | COLOR_PAIR(c);

    if(init_pair(++c, COLOR_RED, COLOR_BLACK) == ERR){
      fprintf(stderr, "init pair for %d failed\n", c);
      return -1;
    }
    ct_map[KATCP_LEVEL_ERROR] = A_BOLD | COLOR_PAIR(c);
    ct_map[KATCP_LEVEL_FATAL] = A_BLINK | A_BOLD | COLOR_PAIR(c);

  } else {
    ct_map[KATCP_LEVEL_TRACE] = A_DIM;
    ct_map[KATCP_LEVEL_DEBUG] = A_DIM;
    ct_map[KATCP_LEVEL_INFO]  = A_NORMAL;
    ct_map[KATCP_LEVEL_WARN]  = A_ITALIC;
    ct_map[KATCP_LEVEL_ERROR] = A_BOLD;
    ct_map[KATCP_LEVEL_FATAL] = A_BLINK | A_BOLD;
  }

  return 0;
}

int recheck_time()
{
  struct tm *tp;
  time_t now;

  time(&now);

  tp = localtime(&now);
  if(tp == NULL){
    fprintf(stderr, "unable to exact localtime fields\n");
    return -1;
  }

  tp->tm_sec = 0;
  tp->tm_min = 0;
  tp->tm_hour = 0;

  ct_base = mktime(tp);

  if(ct_base % DAY){
    fprintf(stderr, "odd - my day starts with a remainder of %lu\n", ct_base % DAY);
  }

  return 0;
}

/**********************************************************/

struct ct_row *make_row(struct katcl_parse *px)
{
  char *inform, *level, *msg, *mod, *ptr, *end;
  int code;
  unsigned int i, j;
  struct ct_row *cr;
  unsigned long full, fraction, reduced;

  if(get_count_parse_katcl(px) < 5){
    return NULL;
  }

  inform = get_string_parse_katcl(px, 0);
  if(inform == NULL){
    return NULL;
  }
  if(strcmp(inform, "#log")){
    return NULL;
  }

  level = get_string_parse_katcl(px, 1);
  if(level == NULL){
    return NULL;
  }

  code = log_to_code_katcl(level);
  if(code < 0){
    return NULL;
  }

  ptr = get_string_parse_katcl(px, 2);
  if(ptr == NULL){
    return NULL;
  }

  full = strtoull(ptr, &end, 10);
  switch(end[0]){
    case '.'  :
      fraction = 0;
      j = 1;
      for(i = 0; i < 3; i++){
        fraction *= 10;
        switch(end[j]){
          case '0' :
          case '1' :
          case '2' :
          case '3' :
          case '4' :
          case '5' :
          case '6' :
          case '7' :
          case '8' :
          case '9' :
            fraction += end[j] - '0';
            j++;
            break;
        };
      }
      break;
    case '\0' :
      fraction = 0;
      break;
    default :
      fprintf(stderr, "malformed timestamp %s\n", ptr);
      return NULL;
  }
  if(full < ct_base){
    fprintf(stderr, "timestamp %s in distant past\n", ptr);
    return NULL;
  }
  reduced = full - ct_base;
  if(reduced >= DAY){
    recheck_time();
    if(full < ct_base){
      /* major time warp - do we give up ? */
      fprintf(stderr, "encountered timewarp while processing %s\n", ptr);
      return NULL;
    }
    reduced = full - ct_base;
  }

  mod = copy_string_parse_katcl(px, 3);
  msg = copy_string_parse_katcl(px, 4);

  if((msg == NULL) || (mod == NULL)){
    fprintf(stderr, "no module or message to log\n");
    return NULL;
  }

  cr = malloc(sizeof(struct ct_row));
  if(cr == NULL){
    free(msg);
    free(mod);
    return NULL;
  }

  cr->c_level = code;
#if 0
  cr->c_time  = (reduced * SCALE) + fraction;
#endif
  cr->c_time  = reduced;

  cr->c_module  = mod;
  cr->c_message = msg;

  cr->c_refs = 0;
  cr->c_same = NULL;
  cr->c_next = NULL;

  ct_allocated++;

#ifdef DEBUG
  if(ct_allocated > 10000){
    fprintf(stderr, "eek, %lu messages in flight\n", ct_allocated);
  }
#endif

  return cr;
}

void destroy_row(struct ct_row *cr)
{
  if(cr == NULL){
    return;
  }

  ct_allocated--;

  if(cr->c_module){
    free(cr->c_module);
    cr->c_module = NULL;
  }

  if(cr->c_message){
    free(cr->c_message);
    cr->c_message = NULL;
  }

#ifdef DEBUG
  fprintf(stderr, "destroyed row %p\n", cr);
#endif

  free(cr);
}

int show_row(struct ct_row *ct, struct ct_row *pt, unsigned int pos)
{
  int common, i, j, len, dot;

  move(pos, 0);

  len = strlen(ct->c_module);
  common = 0;
  dot = 0;

  if(pt){
    common = len;
    for(i = 0; i < len; i++){
      if(ct->c_module[i] != pt->c_module[i]){
        common = i;
        break;
      } else if(ct->c_module[i] == '.'){
        dot = i;
      }
    }
  }

  if(common < len){ /* a difference */
    if(common > (dot + PREFIX)){ /* in a weird place */
      dot = common;
      for(i = 0; i < (PREFIX / 2); i++){
        switch(ct->c_module[common - i]){
          case '-' :
          case '_' : 
          case ':' :
            dot = common - i;
            break;
        }
      }
    }

#ifdef DEBUG
  fprintf(stderr, "%s vs %p %u/%u/%u\n", ct->c_module, pt, dot, common, len);
#endif

    for(i = 0; i < PREFIX; i++){
      if(dot < common){
        addch(ct->c_module[dot++] | A_DIM);
      } else if(dot < len){
        addch(ct->c_module[dot++] | A_BOLD);
      } else {
        addch(' ');
      }
    }

  } else { /* everything in common */

    i = 0;
    if(pt && (pt->c_time != ct->c_time)){
      attrset(A_REVERSE);
      printw("%02u:%02u:%02u", ct->c_time / 3600, (ct->c_time / 60) % 60, ct->c_time % 60);
      attrset(A_NORMAL);
      i = 8;
    } 

    while(i < PREFIX){
      addch(' ');
      i++;
    }
  }

  addch(' ');

  len = strlen(ct->c_message);
  if(len > (COLS - (PREFIX + 1))){
    len = (COLS - (PREFIX + 1));
  }

  for(j = 0; j < len; j++){
    addch(ct->c_message[j] | ct_map[ct->c_level]);
  }

  clrtoeol();

#if 0
  attrset(ct_map[ct->c_level]);
#if 1
  mvprintw(pos, 0, "%s", ct->c_message);
#else
  mvaddchstr(pos, 0, ct->c_message);
#endif
  clrtoeol();
#endif

  return 0;
}

/************************************************************/

void ct_trim_next(struct ct_row *ct)
{
  struct ct_row *nt, *pt;

  if(ct == NULL){
    return;
  }

  nt = ct->c_next;
  ct->c_next = NULL;

  while(nt != NULL){
    pt = nt;

    nt = nt->c_next;
    pt->c_next = NULL;

    if(pt->c_refs){
      pt->c_refs--;
    } else {
      fprintf(stderr, "empty entry\n");
      abort();
    }
    if(pt->c_refs <= 0){
      if(pt->c_same){
        fprintf(stderr, "same link still valid\n");
        abort();
      }
      destroy_row(pt);
    }
  }
}

void ct_trim_same(struct ct_row *ct)
{
  struct ct_row *nt, *pt;

  if(ct == NULL){
    return;
  }

  nt = ct->c_same;
  ct->c_same = NULL;

  while(nt != NULL){
    pt = nt;

    nt = nt->c_same;
    pt->c_same = NULL;

    if(pt->c_refs){
      pt->c_refs--;
    } else {
      fprintf(stderr, "empty entry\n");
      abort();
    }
    if(pt->c_refs <= 0){
      if(pt->c_next){
        fprintf(stderr, "same link still valid\n");
        abort();
      }
      destroy_row(pt);
    }
  }
}

int ct_redraw()
{
  int i;
  struct ct_row *r, *p;

  p = NULL;
  r = ct_recent;
  for(i = 0; i < LINES; i++){
    if(r == NULL){
      refresh();
      return 0;
    }

    show_row(r, p, i);
    p = r;
    r = r->c_next;
  }

  ct_trim_next(r);

  refresh();
  return 0;
}

void handle_end(int sig)
{
  ct_finished = 1;
}

void usage(char *name)
{
  printf("usage: %s servername:port\n", name);
}

int main(int argc, char **argv)
{
  struct katcl_line *l;
  struct katcl_parse *px;
  struct ct_row *cr;

  int fd, c, i, j;
  int result, update;
  char *server;
#if 0
  char *cmd;
  SCREEN *sc;
#endif
  WINDOW *rt;

  server = getenv("KATCP_SERVER");
  if(server == NULL){
    server = "localhost";
  }

  i = 1;
  j = 1;
  while (i < argc) {
    if (argv[i][0] == '-') {
      c = argv[i][j];
      switch (c) {
        case 'h' :
          usage(argv[0]);
          return 0;
        case '-' :
          j++;
          break;
        case '\0':
          j = 1;
          i++;
          break;
        default:
          fprintf(stderr, "%s: unknown option -%c\n", argv[0], argv[i][j]);
          return 2;
      }
    } else {
      server = argv[i];
      i++;
    }
  }

  fprintf(stderr, "*** still a prototype - crashy and unfriendly\n");
  sleep(2);

  fd = net_connect(server, 0, 0);
  if(fd < 0){
    fprintf(stderr, "unable to connect to %s\n", server);
    return 2;
  }

  l = create_katcl(fd);
  if(l == NULL){
    fprintf(stderr, "unable to set up line state for %s\n", server);
    return 2;
  }

  if(recheck_time() < 0){
    fprintf(stderr, "unable to check time\n");
    return 2;
  }

  signal(SIGINT, &handle_end);

#if 0
  sc = newterm(NULL, stdout, stdin);
  if(sc == NULL){
    fprintf(stderr, "unable to set up terminal screen\n");
    return 2;
  }
#endif
  rt = initscr();
  if(rt == NULL){
    fprintf(stderr, "unable to set up terminal screen\n");
    return 2;
  }
  leaveok(rt, TRUE);

  if(ct_color_setup() < 0){
    fprintf(stderr, "we don't appear to have colors\n");
    ct_finished = (-1);
  }

  curs_set(0);
  nonl();
#if 0
  cbreak();
#endif
  noecho();
  erase();

  update = 0;

  while(!ct_finished){
    result = read_katcl(l);
    if(result){
      ct_finished = result;
      break;
    }

    while((result = parse_katcl(l)) > 0){
      px = ready_katcl(l);
      if(px){
        cr = make_row(px);
        if(cr){
          cr->c_next = ct_recent;
          ct_recent = cr;
          cr->c_refs++;

#if 0
          /* LATER */
          cr->c_same = ct_vector[cr->c_level];
          ct_vector[cr->c_level] = cr;
          cr->c_refs++;
#endif

          update = 1;
        }
        clear_katcl(l);
      }
    }

    if(result < 0){
      ct_finished = result;
    }

    if(update){
      ct_redraw();
      update = 0;
    }
  }

  echo();
  curs_set(1);

  endwin();

#if 0
  delscreen(sc);
#endif

  destroy_katcl(l, 1);

  return ct_finished;
}
