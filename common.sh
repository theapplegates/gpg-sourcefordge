#!/usr/bin/env bash
# vim: ts=4 sw=4 noet ft=bash
# shellcheck disable=2034
#
# This file is part of GnuPG for OS X.
#
# GnuPG for OS X is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# GnuPG for OS X is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with GnuPG for OS X. If not, see https://www.gnu.org/licenses/ .

function _die {
	echo >&2 "$@"
	exit 1
}

function stepfail {
	_die "Error in step" "$@"
}

function _title {
	echo "***" "$@"
}

function _mkdir {
	local d
	for d in "$@"; do
		[[ -d $d ]] || mkdir -p "$d" || _die "Cannot mkdir $d"
	done
}

function rmkdir {
	local d
	for d in "$@"; do
		[[ ! -e $d ]] || rm -fr "$d" || _die "Cannot delete $d"
		_mkdir "$d"
	done
}

function backup_dir {
	local step=$1 dir=$2 tar=$3
	echo "Backing up $dir to $tar"
	tar -C "$dir" -cf "$tar" --exclude '*build' --exclude '*.tar' . || stepfail "$step"
}

function restore_dir {
	local step=$1 dir=$2 tar=$3
	echo "Restoring $dir from $tar"
	rm -fr "${dir:?}/*" || stepfail "$step"
	tar -C "$dir" -xf "$tar" || stepfail "$step"
}

declare -r GPGOSX_LIBID_PREFIX="gnupg-${GNUPG_VERSION:0:3}"
declare -r GPGOSX_INSTALLDIR="/usr/local/$GPGOSX_LIBID_PREFIX"
# shellcheck disable=2155
declare -r GPGOSX_PROJECTDIR="$(pwd -P)"
declare -r GPGOSX_LOGDIR="$GPGOSX_PROJECTDIR/logs"

declare -r GNUPG_TARBALL="gnupg-$GNUPG_VERSION.tar.bz2"
declare -r GNUPG_TARBALL_URL="https://gnupg.org/ftp/gcrypt/gnupg/$GNUPG_TARBALL"

# Remove this statement when building on macOS 10.x
export MACOSX_DEPLOYMENT_TARGET="11.0"

# SDK location and flags (ARM)
ARM_SDKROOT=$(xcrun --show-sdk-path)
ARM_FLAGS="-isysroot $ARM_SDKROOT -mmacosx-version-min=11.0"

# SDK location and flags (Intel)
X86_SDKROOT=$ARM_SDKROOT
X86_FLAGS="-isysroot $X86_SDKROOT -mmacosx-version-min=10.12"

# Additional options to configure GnuPG
GNUPG_CFOPTS=('')

# String to insert in the resulting disk image name
DMG_NAME_INFIX=

# Use all available CPU cores for builds
NCPU=$(sysctl hw.logicalcpu | awk '{print $2}')

# OpenPGP signing key used to sign disk image
DMG_SIGNING_KEY=EAB0FE4FF793D9E7028EC8E2FD56297D9833FF7F

# Developer certificate used to sign installer package
PKG_SIGNING_CERT=

# Delay before retrying automatically after a build error
WAIT_AFTER_ERR=5

# For systems without existing GnuPG binary, set to "":
#GPGOSX_EXISTING_BINARY=gpg
GPGOSX_EXISTING_BINARY=""
