# $Id: Makefile,v 1.3 2001/11/21 00:49:34 dbrownell Exp $
#
# This Makefile is in the Public Domain.
#


DOCTITLE="SAX: Simple API for XML"

SOURCES		:= $(shell find src/org -name '*.java' -print)
PACKAGE_INFO	:= $(shell find src/org -name '*.html' -print)
ALL_SRC		:= $(PACKAGE_INFO) $(SOURCES)

all: sax.jar javadoc

sax.jar:	$(SOURCES)
ifneq ($(findstring 1.1, $(JDK)),1.1)
	mkdir -p classes
	javac -d classes $(SOURCES)
	cd classes; jar cf ../sax.jar org
else
	@echo "SAX needs JDK 1.2 features to compile."
	@echo "However, it works with JDK 1.1 runtime environments."
	@exit 1
endif

#
# Javadoc
#
#	    -overview doc/overview.html

javadoc:	$(ALL_SRC) # doc/overview.html
ifneq ($(findstring 1.1, $(JDK)),1.1)
	mkdir -p apidoc
	javadoc -d apidoc \
	    -J-Xmx64M -J-Xms64M \
	    -windowtitle $(DOCTITLE) \
	    -nodeprecatedlist -use \
	    -bottom "<em>SAX is in the PUBLIC DOMAIN.</em> \
		<br>See <a href="http://www.saxproject.org"> \
		http://www.saxproject.org</a> for information and source \
		code.  <br>This documentation was derived from that\
		source code on `date "+%e-%b-%Y"`.\
		" \
	    -classpath "$(CPATH)$(SEP)src" \
	    org.xml.sax org.xml.sax.helpers org.xml.sax.ext
else
	@echo "Requires JDK 1.2 (or later) javadoc."
	@exit 1
endif

#
# Release Engineering:  "full" release has source, jarfile, javadoc.
#

# override in environment, with "make -e"
DIST_DIR =	sax2dev

EXTRA		:= README Makefile COPYING ChangeLog

sax2dist.jar: sax.jar javadoc $(EXTRA) $(ALL_SRC)
	mkdir -p $(DIST_DIR)
	for F in $(EXTRA) $(ALL_SRC) ;\
	do \
	    mkdir -p `dirname $(DIST_DIR)/$$F` ;\
	    cp $$F $(DIST_DIR)/$$F ;\
	done
	cp -r apidoc sax.jar $(DIST_DIR)
	# jar cMf sax2dist.jar $(DIST_DIR)
	zip -qr9 sax2dist.jar $(DIST_DIR)
	rm -rf $(DIST_DIR)

#
# housekeeping
#
clean:
	rm -rf classes *.jar apidoc
	find . '(' -name '*~' -o -name '.#*' ')' -exec rm -f '{}' ';'
