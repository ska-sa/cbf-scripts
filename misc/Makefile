include ../Makefile.inc

# startup routines
INITDIR = $(CONFPREFIX)/init.d
INITSCRIPT = cmc.initscript

# log rotation
LOGROTATEDIR = $(CONFPREFIX)/logrotate.d
LOGROTATE = cmc.logrotate

# configuration
CONFIGDIR = $(CONFPREFIX)
CONFIG = cmc.conf

all:

clean:

install: all
	$(INSTALL) -d $(INITDIR)
	$(INSTALL) $(INITSCRIPT) $(INITDIR)/$(basename $(INITSCRIPT))

	$(INSTALL) -d $(LOGROTATEDIR)
	$(INSTALL) $(LOGROTATE) $(LOGROTATEDIR)/$(basename $(LOGROTATE))

	$(INSTALL) -d $(CONFIGDIR)
	$(INSTALL) $(CONFIG) $(CONFIGDIR)/$(CONFIG)
