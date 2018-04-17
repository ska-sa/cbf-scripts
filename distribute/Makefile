include ../Makefile.inc

BINDIR = $(EXEPREFIX)/bin

# compiler flags, -Wall is just the right thing to do 
CFLAGS += -Wall

# amount of debugging logic to enable 
#CFLAGS += -DDEBUG=4
#CFLAGS += -DDEBUG

# what compiler to use 
CC = $(CROSS_COMPILE)gcc

EXE = distribute
SRC = $(EXE).c

all: $(EXE)

$(EXE): $(SRC)
	$(CC) $(CFLAGS) -o $@ $^

install: all
	$(INSTALL) -d $(BINDIR)
	$(INSTALL) $(EXE) $(BINDIR)/$(EXE)

clean: 
	$(RM) $(EXE) *.o

