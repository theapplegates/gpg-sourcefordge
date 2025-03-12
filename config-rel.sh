# vim: ts=4 sw=4 noet ft=bash
# shellcheck shell=bash disable=2034
#
# Configuration file. Sourced by other BASH scripts.

# Architecture-specific flags to extend CFLAGS/CXXFLAGS/LDFLAGS

# Release build (full optimisation)
ARM_FLAGS+=" -Ofast"
X86_FLAGS+=" -Ofast"
