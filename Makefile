include Makefile.inc 

###############################################################################

APPS = 
MISC = cmc misc ike

EVERYTHING = $(APPS) $(MISC)

###############################################################################

all: $(patsubst %,%-all,$(EVERYTHING))
clean: $(patsubst %,%-clean,$(EVERYTHING))
install: $(patsubst %,%-install,$(EVERYTHING))

%-all %-clean %-install:
	$(MAKE) -C $(shell echo $@ | cut -f1 -d- ) KATCP=../$(KATCP) $(shell echo $@ | cut -f2 -d-)
