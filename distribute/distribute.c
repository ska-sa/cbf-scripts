#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <errno.h>
#include <sysexits.h>

struct distribute_state{
  unsigned int *d_bin_vector;
  unsigned int **d_bin_shadow;
  unsigned int d_bin_count;
  char *d_bin_name;

  unsigned int *d_item_vector;
  unsigned int **d_item_shadow;
  unsigned int d_item_count;
  char *d_item_name;

  unsigned int *d_allocation;
  char *d_assigned_name;

  unsigned int d_verbose;
};

int compare(const void *a, const void *b)
{
  unsigned int **ia, **ib;

  ia = a;
  ib = b;

  return (**ia) - (**ib);
}

unsigned int **make_sorted_shadow(unsigned int *vector, unsigned int count)
{
  unsigned int **shadow, i;

  shadow = malloc(sizeof(unsigned int *) * count);
  if(shadow == NULL){
    return NULL;
  }

  for(i = 0; i < count; i++){
    shadow[i] = &vector[i];
  }

  qsort(shadow, count, sizeof(unsigned int *), &compare);

  return shadow;
}

void clear_allocation(unsigned int *vector, unsigned int bins, unsigned int items)
{
  unsigned int i, count;

  count = bins * items;

  for(i = 0; i < count; i++){
    vector[i] = 0;
  }
}

unsigned int *make_allocation(unsigned int bins, unsigned int items){
  unsigned int *tmp, count;

  count = bins * items;

  tmp = malloc(sizeof(unsigned int) * count);
  if(tmp == NULL){
    return NULL;
  }

  clear_allocation(tmp, bins, items);

  return tmp;
}

unsigned int *add_to_vector(unsigned int *vector, char *value, unsigned int count)
{
  unsigned int *tmp;
  unsigned long v;
  char *end;

  v = strtoul(value, &end, 10);

  if(end[0] != '\0'){
    fprintf(stderr, "unable to convert %s to a valid natural number\n", value);
    return NULL;
  }

#if 0
  if(v <= 0){
    fprintf(stderr, "ignoring entries with zero count\n");
    return vector;
  }
#endif

  tmp = realloc(vector, sizeof(unsigned int) * (count + 1));
  if(tmp == NULL){
    return NULL;
  }

  tmp[count] = v;

  return tmp;
}

void dump_state(struct distribute_state *ds, FILE *fp)
{
  unsigned int i;

  fprintf(fp, "given  items:");
  for(i = 0; i < ds->d_item_count; i++){
    fprintf(fp, " %u", ds->d_item_vector[i]);
  }
  fprintf(fp, "\n");

  fprintf(fp, "sorted items:");
  for(i = 0; i < ds->d_item_count; i++){
    fprintf(fp, " %u", *(ds->d_item_shadow[i]));
  }
  fprintf(fp, "\n");

  fprintf(fp, "given  bins:");
  for(i = 0; i < ds->d_bin_count; i++){
    fprintf(fp, " %u", ds->d_bin_vector[i]);
  }
  fprintf(fp, "\n");

  fprintf(fp, "sorted bins:");
  for(i = 0; i < ds->d_bin_count; i++){
    fprintf(fp, " %u", *(ds->d_bin_shadow[i]));
  }
  fprintf(fp, "\n");

}

/**********************************************************************/

int strategy_single(struct distribute_state *ds)
{
  unsigned int i, pos;
  unsigned int total;

  clear_allocation(ds->d_allocation, ds->d_bin_count, ds->d_item_count);

  total = 0;

  for(i = 0; i < ds->d_item_count; i++){
    total += ds->d_item_vector[i];
  }

  if(ds->d_verbose){
    fprintf(stderr, "have %u items in total\n", total);
  }

  i = ds->d_bin_count;
  while((i > 0) && ((*(ds->d_bin_shadow[i - 1]) >= total))){
    i--;
  }

  if(i == ds->d_bin_count){
    if(ds->d_verbose){
      fprintf(stderr, "single failed: largest bin has %u slots which is smaller than item total %u\n", *(ds->d_bin_shadow[i - 1]), total);
    }
    return 1;
  }

  pos = ds->d_bin_shadow[i] - &(ds->d_bin_vector[0]); /* WARNING: excessive pointer arithmetic */
  if(ds->d_verbose){
    fprintf(stderr, "found bin at %u (order %u) which can hold all %u items\n", pos, i, total);
  }

  for(i = 0; i < ds->d_item_count; i++){
    ds->d_allocation[(pos * ds->d_item_count) + i] = ds->d_item_vector[i];
  }

  return 0;
}

int strategy_binned(struct distribute_state *ds)
{
  unsigned int i, j, pos, loc;

  clear_allocation(ds->d_allocation, ds->d_bin_count, ds->d_item_count);

  i = 0;
  j = 0;

  while(i < ds->d_item_count){
    if(*(ds->d_bin_shadow[j]) >= *(ds->d_item_shadow[i])){
      pos = ds->d_bin_shadow[j] - &(ds->d_bin_vector[0]); /* WARNING: excessive pointer arithmetic */
      loc = ds->d_item_shadow[i] - &(ds->d_item_vector[0]);
      ds->d_allocation[(pos * ds->d_item_count) + loc] = *(ds->d_item_shadow[i]);
      i++;
    }

    j++;
    if(j >= ds->d_bin_count){
      if(i < ds->d_item_count){
        if(ds->d_verbose){
          fprintf(stderr, "binned failed: no further bins available but still have %d items types to allocate\n", ds->d_item_count - i);
        }
        return 1;
      }
    }
  }

  return 0;
}

int strategy_disjoint(struct distribute_state *ds)
{
  unsigned int i, j, pos, loc, actual;

  i = 0;
  j = 0;

  actual = *(ds->d_item_shadow[i]);

  while(i < ds->d_item_count){

    pos = ds->d_bin_shadow[j] - &(ds->d_bin_vector[0]); /* WARNING: excessive pointer arithmetic */
    loc = ds->d_item_shadow[i] - &(ds->d_item_vector[0]);

#if 0
    if(*(ds->d_bin_shadow[j]) >= *(ds->d_item_shadow[i])){
      ds->d_allocation[(pos * ds->d_item_count) + loc] = *(ds->d_item_shadow[i]);
      i++;
    }
#endif

    if(*(ds->d_bin_shadow[j]) >= actual){
      ds->d_allocation[(pos * ds->d_item_count) + loc] = actual;
      if(ds->d_verbose > 2){
        fprintf(stderr, "check[%d]: can allocate all %d remaining to bin %d\n", j, actual, pos);
      }
      i++;
      if(i < ds->d_item_count){
        actual = *(ds->d_item_shadow[i]);
      }
    } else {
      ds->d_allocation[(pos * ds->d_item_count) + loc] = *(ds->d_bin_shadow[j]);
      if(ds->d_verbose > 2){
        fprintf(stderr, "check[%d]: can allocate %d of %d to bin %d\n", j, *(ds->d_bin_shadow[j]), actual, pos);
      }
      actual -= *(ds->d_bin_shadow[j]);
    }

    j++;
    if(j >= ds->d_bin_count){
      if(i < ds->d_item_count){
        if(ds->d_verbose){
          fprintf(stderr, "disjoint failed: no further bins available but still have %d items types to allocate\n", ds->d_item_count - i);
        }
        return 1;
      }
    }
  }

  return 0;
}

#define STRATEGIES 3

struct strategy_option{
  char *s_name;
  int (*s_call)(struct distribute_state *);
  char *s_description;
};

struct strategy_option strategy_table[STRATEGIES + 1] = {
  { "single",   &strategy_single,   "attempt to fit all items into the smallest bin" },
  { "binned",   &strategy_binned,   "attempt to distribute each different types into its own bin" },
  { "disjoint", &strategy_disjoint, "attempt to distribute so that no bin contains more than one type" },
  { NULL, NULL, NULL }
};

int find_strategy(char *name)
{
  int i;

  for(i = 0; strategy_table[i].s_name && strcmp(strategy_table[i].s_name, name); i++);

  if(strategy_table[i].s_name == NULL){
    return -1;
  }

  return i;
}

int run_strategy(struct distribute_state *ds, unsigned int strategy)
{
  if(strategy >= STRATEGIES){
    fprintf(stderr, "invalid strategy number %u\n", strategy);
    return -1;
  }

  if(ds->d_verbose > 1){
    fprintf(stderr, "running strategy number %u\n", strategy);
  }

  return (*(strategy_table[strategy].s_call))(ds);
}


/**********************************************************************/

void display_as_shell_array(struct distribute_state *ds, unsigned int format)
{
  unsigned int i, j, shown;

  if(ds->d_assigned_name){
    printf("%s=(", ds->d_assigned_name);
  }

  for(i = 0; i < ds->d_item_count; i++){
    if(i > 0){
      printf(" ");
    }
    printf("\"");
    shown = 0;

    for(j = 0; j < ds->d_bin_count; j++){
      if(ds->d_allocation[(j * ds->d_item_count) + i] > 0){
        if(shown > 0){
          printf(" ");
        } else {
          shown = 1;
        }
        if(ds->d_bin_name){
          printf("%s", ds->d_bin_name);
        }
        printf("%u", j);
      }
    }
    printf("\"");
  }

  if(ds->d_assigned_name){
    printf(")");
  }
  printf("\n");
}

void display_as_matrix(struct distribute_state *ds, unsigned int format)
{
  unsigned int i, j;

  for(i = 0; i < ds->d_bin_count; i++){
    for(j = 0; j < ds->d_item_count; j++){
      if(j > 0){
        printf(" ");
      }
      printf("%u", ds->d_allocation[(i * ds->d_item_count) + j]);
    }
    printf("\n");
  }
}

void display_items(struct distribute_state *ds, unsigned int format)
{
  unsigned int i, j, show;

  for(i = 0; i < ds->d_bin_count; i++){
    show = 0;
    for(j = 0; j < ds->d_item_count; j++){
      if(ds->d_allocation[(i * ds->d_item_count) + j] > 0){
        show++;
      }
    }
    if(show){
      printf("%s %u:", ds->d_bin_name ? ds->d_bin_name : "bin", i);
      for(j = 0; j < ds->d_item_count; j++){
        printf(" %u", ds->d_allocation[(i * ds->d_item_count) + j]);
      }
      printf("\n");
    }
  }
}

void display_as_text(struct distribute_state *ds, unsigned int format)
{
  unsigned int i, j;

  for(i = 0; i < ds->d_bin_count; i++){
    for(j = 0; j < ds->d_item_count; j++){
      if(ds->d_allocation[(i * ds->d_item_count) + j] > 0){
        printf("assign %u of %s %u to %s %u\n", ds->d_allocation[(i * ds->d_item_count) + j], ds->d_item_name ? ds->d_item_name : "item number", j, ds->d_bin_name ? ds->d_bin_name : "bin", i);
      }
    }
  }
}

struct output_format{
  char *o_name;
  void (*o_call)(struct distribute_state *, unsigned int);
};

struct output_format output_table[] = {
  { "matrix", &display_as_matrix },
  { "shell", &display_as_shell_array },
  { "text", &display_as_text },
  { NULL, NULL }
};

void display(struct distribute_state *ds, char *name, unsigned int format)
{
  int i;

  if(name == 0){
    i = 0;
  } else {
    for(i = 0; output_table[i].o_name && strcmp(name, output_table[i].o_name); i++);
    if(output_table[i].o_name == NULL){
      fprintf(stderr, "unknown output format %s - valid options:\n", name);
      for(i = 0; output_table[i].o_name; i++){
        fprintf(stderr, "%s\n", output_table[i].o_name);
      }
      return;
    }
  }

  (*(output_table[i].o_call))(ds, format);
}

/**********************************************************************/

/* example
 * ./distribute -i 8 8 -b 12 12 8 -s dense
 * 0 0
 * 1 8
 * 2 8
 */

void usage(char *app)
{
  unsigned int i;

  printf("distribute items of different types into several bins\n");
  printf("\n");
  printf("%s [-h] [-i items+] [-b bins+] [-n name] [-t name] [-s strategy]\n", app);
  printf("-h          this help\n");
  printf("-i count    number of items of a particular type\n");
  printf("-b count    number of slots in the given bin\n");
  printf("-n name     name given to each bin\n");
  printf("-t name     name given each type type\n");
  printf("-a name     variable used in assignment\n");
  printf("-f name     output format: ");
  for(i = 0; output_table[i].o_name; i++){
    printf(" %s", output_table[i].o_name);
  }
  printf("\n");
  printf("-s name     name of allocation strategy\n");
  printf("\n");
  printf("Available strategies:\n");
  for(i = 0; strategy_table[i].s_name; i++){
    printf(" %s - %s\n", strategy_table[i].s_name, strategy_table[i].s_description);
  }
}

#define TAKE_ITEM 0
#define TAKE_BIN  1

int main(int argc, char **argv)
{
  int i, j, c, s;
  char *app;
  int flag;
  char *output;
  int strategies[STRATEGIES];
  struct distribute_state state, *ds;
  int count;

  unsigned int *tmp;

  ds = &state;

  ds->d_bin_vector = NULL;
  ds->d_bin_shadow = NULL;
  ds->d_bin_count = 0;
  ds->d_bin_name = NULL;

  ds->d_item_vector = NULL;
  ds->d_item_shadow = NULL;
  ds->d_item_count = 0;
  ds->d_item_name = NULL;

  ds->d_allocation = NULL;
  ds->d_assigned_name = NULL;
  ds->d_verbose = 0;

  app = argv[0];

  flag = (-1);
  output = NULL;

  count = 0;

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
            tmp = add_to_vector(ds->d_item_vector, argv[i] + j, ds->d_item_count);
            if(tmp == NULL){
              return EX_USAGE;
            }
            ds->d_item_vector = tmp;
            ds->d_item_count++;
          }
          j = 1;
          i++;
          break;
        case 'b' :
          flag = TAKE_BIN;
          j++;
          if(argv[i][j] != '\0'){
            tmp = add_to_vector(ds->d_bin_vector, argv[i] + j, ds->d_bin_count);
            if(tmp == NULL){
              return EX_USAGE;
            }
            ds->d_bin_vector = tmp;
            ds->d_bin_count++;
          }
          j = 1;
          i++;
          break;
        case 'v' :
          ds->d_verbose++;
          j++;
          break;
        case 'a' :
        case 'f' :
        case 'n' :
        case 's' :
        case 't' :
          j++;
          if (argv[i][j] == '\0') {
            j = 0;
            i++;
          }
          if (i >= argc) {
            fprintf(stderr, "%s: argument needs a parameter\n", app);
            return EX_USAGE;
          }

          switch(c){
            case 'a' :
              ds->d_assigned_name = argv[i] + j;
              break;
            case 'n' :
              ds->d_bin_name = argv[i] + j;
              break;
            case 'f' :
              output = argv[i] + j;
              break;
            case 's' :

              s = find_strategy(argv[i] + j);
              if(s < 0){
                fprintf(stderr, "%s: unknown strategy %s\n", app, argv[i] + j);
                return EX_USAGE;
              }

              if(count >= STRATEGIES){
                fprintf(stderr, "%s: too many strategies specified, consider eliminating repeated ones\n", app);
                return EX_USAGE;
              }

              strategies[count++] = s;
              break;
            case 't' :
              ds->d_item_name = argv[i] + j;
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
          fprintf(stderr, "unknown option -%c\n", c);
          return EX_USAGE;
      }
    } else {
      switch(flag){
        case TAKE_BIN :
          tmp = add_to_vector(ds->d_bin_vector, argv[i], ds->d_bin_count);
          if(tmp == NULL){
            return EX_USAGE;
          }
          ds->d_bin_vector = tmp;
          ds->d_bin_count++;
          j = 1;
          break;
        case TAKE_ITEM :
          tmp = add_to_vector(ds->d_item_vector, argv[i], ds->d_item_count);
          if(tmp == NULL){
            return EX_USAGE;
          }
          ds->d_item_vector = tmp;
          ds->d_item_count++;
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

  if((ds->d_item_count <= 0) || (ds->d_bin_count <= 0)){
    fprintf(stderr, "nothing to distribute\n");
    return EX_USAGE;
  }

  if(count <= 0){
    if(ds->d_verbose){
      fprintf(stderr, "no stategy specified so using default strategy %s\n", strategy_table[0].s_name);
    }
    strategies[0] = 0;
    count = 1;
  }

  if(ds->d_verbose > 3){
    fprintf(stderr, "verbosity level %d\n", ds->d_verbose);
  }

  ds->d_bin_shadow = make_sorted_shadow(ds->d_bin_vector, ds->d_bin_count);
  ds->d_item_shadow = make_sorted_shadow(ds->d_item_vector, ds->d_item_count);

  ds->d_allocation = make_allocation(ds->d_bin_count, ds->d_item_count);

  if((ds->d_bin_shadow == NULL) ||
     (ds->d_allocation == NULL) ||
     (ds->d_bin_shadow == NULL)){
    fprintf(stderr, "unable to allocate variable copies\n");
    return EX_SOFTWARE;
  }

  if(ds->d_verbose){
    dump_state(ds, stderr);
  }

  for(i = 0; (i < count) && run_strategy(ds, strategies[i]); i++);

  if(i >= count){
    if(ds->d_verbose){
      fprintf(stderr, "no solution found using %d %s\n", count, (count == 1) ? "strategy" : "strategies");
    }
    return 1;
  }

  display(ds, output, 0);

  return EX_OK;
}

