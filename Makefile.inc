APIVER=cbf-1.h
GITVER = $(shell git describe --always --tags --dirty 2> /dev/null || echo unknown)

# install location
EXEPREFIX=/usr/local
CONFPREFIX=/etc

# where to find the KATCP library (change this in case katcp isn't included locally)
KATCP ?= ../katcp/katcp

# compiler flags, -Wall is just the right thing to do 
CFLAGS += -Wall
CFLAGS += -O2

# amount of debugging logic to enable 
#CFLAGS += -DDEBUG=4
#CFLAGS += -DDEBUG
CFLAGS += -ggdb

# what compiler to use 
CC = $(CROSS_COMPILE)gcc


INSTALL = install
RM = rm -f
AR = ar
ECHO = echo

DIFF = diff -ub
TEST = test
SED  = sed

.PHONY: all clean install
