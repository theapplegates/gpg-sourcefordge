# vim: ts=4 sw=4 noet ft=bash
# shellcheck shell=bash disable=2034
#
# Configuration file. Sourced by other BASH scripts.

# Architecture-specific flags to extend CFLAGS/CXXFLAGS/LDFLAGS

# Development build (minimal optimisation)
ARM_FLAGS+=" -O0"
X86_FLAGS+=" -O0"

# Disable tests and documentation for a faster build
GNUPG_CFOPTS=(--disable-doc --disable-tests)

# Mark disk image as a developer build
DMG_NAME_INFIX="-dev"
