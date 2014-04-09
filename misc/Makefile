include ../Makefile.inc

# startup routines
INITDIR = $(CONFPREFIX)/init.d
INITSCRIPT = $(wildcard *mc.initscript)

# log rotation
LOGROTATEDIR = $(CONFPREFIX)/logrotate.d
LOGROTATE = $(wildcard *mc.initscript)

# configuration
CONFIGDIR = $(CONFPREFIX)
CONFIG = $(wildcard *mc.conf)

all:

clean:

install: all
	$(INSTALL) -d $(INITDIR)
	$(INSTALL) $(INITSCRIPT) $(INITDIR)/$(basename $(INITSCRIPT))

	$(INSTALL) -d $(LOGROTATEDIR)
	$(INSTALL) $(LOGROTATE) $(LOGROTATEDIR)/$(basename $(LOGROTATE))

	$(INSTALL) -d $(CONFIGDIR)
	-if $(TEST) -f $(CONFIGDIR)/$(CONFIG) ; then echo -e '\n**** not overwriting already installed config file ****\n' ; $(DIFF) $(CONFIG) $(CONFIGDIR)/$(CONFIG) ; else $(INSTALL) $(CONFIG) $(CONFIGDIR)/$(CONFIG) ; fi

