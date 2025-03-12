About
=====

This set of scripts is used to compile GnuPG 2.4.x and 2.5.x plus all of its
components for macOS (formerly known as OS X). It downloads all required files,
creates an installer package, and bundles the result in a disk image which can
be used for distribution.

Prerequisites
=============

- macOS version 10.12 or newer
- Xcode version 5.0 or newer
- pkg-config executable in your PATH

Configuration
=============

You can modify settings in config-dev.sh (development build) and config-rel.sh
(release build) and by passing variables to the "make" command (see Makefile).

