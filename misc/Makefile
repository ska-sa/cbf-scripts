include ../Makefile.inc

# startup routines
INITDIR = $(CONFPREFIX)/init.d
INITSCRIPT = $(wildcard *mc.initscript)

# log rotation
LOGROTATEDIR = $(CONFPREFIX)/logrotate.d
LOGROTATE = $(wildcard *mc.logrotate)

# configuration
CONFIGDIR = $(CONFPREFIX)
CONFIG = $(wildcard *mc.conf)

INITSRC = $(shell if test -f $(CONFIGDIR)/$(CONFIG) ; then echo $(CONFIGDIR)/$(CONFIG) ; else echo $(CONFIG) ; fi)
INITTMP = $(CONFIG)-tmp

all:
	$(SED) -e 's/^device_build=.*/device_build=$(GITVER)/' \
	       -e 's/^device_api=.*/device_api=$(APIVER)/'     \
	       $(INITSRC) > $(INITTMP)
	@echo -e '\n****************************************\n' 
	-$(DIFF) $(INITTMP) $(CONFIG) 
	@echo -e '\n****************************************\n' 

clean:
	$(RM) $(INITTMP)

install: all
	$(INSTALL) -d $(INITDIR)
	$(INSTALL) $(INITSCRIPT) $(INITDIR)/$(basename $(INITSCRIPT))

	$(INSTALL) -d $(LOGROTATEDIR)
	$(INSTALL) $(LOGROTATE) $(LOGROTATEDIR)/$(basename $(LOGROTATE))

	$(INSTALL) -d $(CONFIGDIR)
	$(INSTALL) $(INITTMP) $(CONFIGDIR)/$(CONFIG)
