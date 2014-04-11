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

BUILDVERSION=$(shell git describe --always --tags --dirty 2> /dev/null || echo unknown)

all:

clean:

install: all
	$(INSTALL) -d $(INITDIR)
	$(INSTALL) $(INITSCRIPT) $(INITDIR)/$(basename $(INITSCRIPT))

	$(INSTALL) -d $(LOGROTATEDIR)
	$(INSTALL) $(LOGROTATE) $(LOGROTATEDIR)/$(basename $(LOGROTATE))

	$(INSTALL) -d $(CONFIGDIR)
	-if $(TEST) -f $(CONFIGDIR)/$(CONFIG) ; then echo -e '\n**** not overwriting already installed config file ****\n' ; $(DIFF) $(CONFIG) $(CONFIGDIR)/$(CONFIG) ; echo '\n**** new build $(BUILDVERSION) ****\n' ; else $(SED) -e 's/device_build=.*/device_build=$(BUILDVERSION)/' $(CONFIG) > $(CONFIGDIR)/$(CONFIG) ; fi

