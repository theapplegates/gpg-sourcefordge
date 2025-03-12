# vim: ts=4 sw=4 noet

### Start of configurable settings, see "make help" output.

CONFIG		?= you_forgot_to_specify_CONFIG
CONFIGSH	?= $(PWD)/config-$(CONFIG).sh
DOWNLOADDIR	?= $(PWD)/download
PWD			?= $(shell pwd -P)
STEP		?= 1
VERSION		?= 2.5.5
WORKDIR		?= /tmp/gpgosx-build-$(VERSION)

### End of configurable settings.

ENV		= env GNUPG_VERSION='$(VERSION)' GPGOSX_WORKDIR='$(WORKDIR)' GPGOSX_DOWNLOADDIR='$(DOWNLOADDIR)' time -h
BUILD	= $(ENV) bash ./build.sh 2>&1
PACKAGE	= $(ENV) bash ./package.sh 2>&1

define usage

The following 'make' targets are available:

  all     All steps (full build and package).
  arm     Build for ARM CPUs only.
  build   Build for all supported architectures.
  clean   Cleanup build artifacts.
  fmt     Auto-format shell scripts.
  help    Print this information.
  intel   Build for Intel CPUs only.
  lclean  Cleanup log directories.
  lrot    Rotate log directory.
  pkg     Create distribution package.
  schk    Shellcheck scripts.

Variables can be passed via the command line, for example:

  make CONFIG=dev intel
  make CONFIG=dev VERSION=$(VERSION) WORKDIR=$(WORKDIR) arm
  make CONFIG=rel clean all

Use absolute directory paths only, or the build process will fail.
Quote as necessary. See Makefile for a list of settings which can
be overridden.

endef

.PHONY:	all arm build clean fmt help intel lclean lrot pkg prep schk

help:
	$(info $(usage))
	@exit 0

clean:	lrot
	$(BUILD) clean $(CONFIGSH)

prep:
	[ -d logs ] || mkdir logs

lclean:
	rm -fr logs-*

lrot:
	scripts/rotatedir.sh logs

arm:	prep
	$(BUILD) arm64 $(CONFIGSH) $(STEP) | tee logs/$@-$(VERSION).log

intel:	prep
	$(BUILD) x86_64 $(CONFIGSH) $(STEP) | tee logs/$@-$(VERSION).log

build:	intel arm

pkg:	prep
	$(PACKAGE) $(CONFIGSH) $(STEP) | tee logs/$@-$(VERSION).log

all:	build pkg

fmt:
	shfmt -s -w -ln bash *.sh scripts/{install-sh,rotate}*
	shfmt -s -w -ln posix pkg-scripts/*

schk:
	shellcheck -s bash -x {build,package}.sh scripts/{install-sh,rotate}*
	shellcheck -s bash -e 2034 {common,config}*.sh
	shellcheck -s sh pkg-scripts/*

