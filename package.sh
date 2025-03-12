#!/usr/bin/env bash
# vim: ts=4 sw=4 noet ft=bash
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

set -euo pipefail

function die {
	echo >&2 "$@"
	exit 1
}

. ./common.sh || die "Error sourcing ./common.sh"

function usage {
	die "Usage: $(basename "$0") config-file [step]"
}

if [ $# -lt 1 ]; then
	usage
elif [ $# -gt 1 ]; then
	step=$2
else
	step=0
fi

. "$1" || die "Error sourcing $1"

declare -r ARM_RELDIR="$GPGOSX_WORKDIR/arm64-rel"
declare -r INTEL_RELDIR="$GPGOSX_WORKDIR/x86_64-rel"
declare -r UNI_DISTDIR="$GPGOSX_WORKDIR/uni-dist"
declare -r UNI_INSTDIR="$GPGOSX_WORKDIR/uni-inst"
declare -r UNI_RELDIR="$GPGOSX_WORKDIR/uni-rel"
# shellcheck disable=2155
declare -r GPGOSX_PKGVERSION="$GNUPG_VERSION.$(date '+%y%j')"

function prep_workdir {
	# Packaging modifies workdir content. Save workdir if no backup
	# exists yet, otherwise restore workdir from backup.
	local step=$1 src tar
	tar="$GPGOSX_WORKDIR.tar"
	if [[ -f $tar ]]; then
		restore_dir "$step" "$GPGOSX_WORKDIR" "$tar"
	else
		backup_dir "$step" "$GPGOSX_WORKDIR" "$tar"
	fi
}

[[ $step -le 3 ]] && prep_workdir 3
[[ $step -le 5 ]] && rmkdir "$UNI_RELDIR"

cd "$UNI_RELDIR" || die

function prep_reldir {
	local step=$1
	# Create the directory structure and content by means of a tar pipe
	tar -C "$ARM_RELDIR" -cf - . | tar -C "$UNI_RELDIR" -xf - || stepfail "$step"
}

[[ $step -le 10 ]] && prep_reldir 10

function unify_file {
	# Files are unified based on their ARM-build absolute paths.
	local step=$1 armpath=$2 rpath
	# Strip prefix to find the relative file path in the release directory.
	rpath="${armpath/$ARM_RELDIR\//}"
	echo "Unify $rpath"
	rm -f "$rpath"
	if grep -Eq '^#! ?/(bin|usr/bin)/' "$armpath"; then
		# Shell script found. Transform build path references.
		sed -e "s,$ARM_RELDIR,$GPGOSX_INSTALLDIR,g" "$armpath" >"$rpath" || stepfail "$step"
		chmod 0755 "$rpath" || stepfail "$step"
	else
		lipo -create -output "$rpath" "$INTEL_RELDIR/$rpath" "$armpath" || stepfail "$step"
	fi
}

function unify_bins {
	local f files step=$1
	_title "Process executables"
	files=$(find "$ARM_RELDIR/bin" -type f -not -name '*.plist' | sort)
	for f in $files; do
		[[ ! -x $f ]] || unify_file "$step" "$f"
	done
}

function unify_libs {
	local f files step=$1
	_title "Process dynamic libraries"
	files=$(find "$ARM_RELDIR/lib" -depth 1 -name '*.dylib' | sort)
	for f in $files; do
		unify_file "$step" "$f"
	done
}

function unify_libexec {
	local f files step=$1
	_title "Process libexec content"
	files=$(find "$ARM_RELDIR/libexec" -depth 1 -type f | sort)
	for f in $files; do
		unify_file "$step" "$f"
	done
}

function gen_scripts {
	local dst src step=$1 dir=$2
	for src in "$GPGOSX_PROJECTDIR"/pkg-scripts/*; do
		dst="$dir/$(basename "$src")"
		echo "Generate $dst"
		sed -E -e "s,^(GPGOSX_INSTALLDIR=).*,\\1$GPGOSX_INSTALLDIR," "$src" >"$dst" || stepfail "$step"
		chmod 0755 "$dst"
	done
}

function gnupg_package {
	local opts pkg step=$1 dir=$2
	[[ -d $dir ]] || die "Missing directory $dir (step $step)"
	rmkdir "$UNI_DISTDIR"
	pkg="$UNI_DISTDIR/GnuPG.pkg"
	_title "Create $pkg"
	opts=(
		--identifier net.sourceforge.gpgosx
		--install-location "$GPGOSX_INSTALLDIR"
		--root "$UNI_RELDIR"
		--scripts "$dir"
		--version "$GPGOSX_PKGVERSION"
	)
	pkgbuild "${opts[@]}" "$pkg" || die "Failed to build $pkg (step $step)"
}

function installer_package {
	local dis disxml opts pkg step=$1
	disxml="$GPGOSX_PROJECTDIR/pkg-data/distro.xml"
	dis="$UNI_DISTDIR/$(basename "$disxml")"
	pkg="$UNI_INSTDIR/Install.pkg"
	_title "Create $pkg"
	rmkdir "$UNI_INSTDIR"
	sed -e "s,GPGOSX_PKGVERSION,$GPGOSX_PKGVERSION,g" \
		-e "s,GNUPG_VERSION,$GNUPG_VERSION,g" \
		"$disxml" >"$dis" || stepfail "$step"
	opts=(--distribution "$dis" --package-path "$UNI_DISTDIR")
	[[ -z $PKG_SIGNING_CERT ]] || opts+=(--sign "$PKG_SIGNING_CERT")
	productbuild "${opts[@]}" "$pkg" || stepfail "$step"
}

function create_dmg {
	local step=$1 dmg=$2
	_title "Create $dmg"
	rm -f "$dmg"
	install -m 0644 "$GPGOSX_PROJECTDIR"/pkg-docs/* "$UNI_INSTDIR" || stepfail "$step"
	hdiutil create "$dmg" -fs 'HFS+' -srcfolder "$UNI_INSTDIR" -volname "GnuPG $GNUPG_VERSION" || stepfail "$step"
	shasum -a 256 -b "$dmg" >"$dmg.sha256"
}

function sign_dmg {
	local step=$1 dmg=$2 sig
	if [[ -z $DMG_SIGNING_KEY ]]; then
		echo "DMG_SIGNING_KEY is empty, skipping disk image signature."
		return
	fi
	sig="$dmg.sig"
	rm -f "$sig"
	echo "Signing $dmg"
	if [[ -n $GPGOSX_EXISTING_BINARY ]]; then
		"$GPGOSX_EXISTING_BINARY" -u "$DMG_SIGNING_KEY" --detach-sign -o "$sig" "$dmg" || stepfail "$step"
	fi
}

[[ $step -le 20 ]] && unify_bins 20
[[ $step -le 25 ]] && unify_libs 25
[[ $step -le 30 ]] && unify_libexec 30

tdir=$(mktemp -d)
[[ $step -le 40 ]] && gen_scripts 40 "$tdir"
[[ $step -le 50 ]] && gnupg_package 50 "$tdir"
rm -fr "$tdir"
builtin unset tdir

[[ $step -le 60 ]] && installer_package 60

cd "$GPGOSX_WORKDIR" || die
dmg="GnuPG-$GNUPG_VERSION$DMG_NAME_INFIX.dmg"
[[ $step -le 70 ]] && create_dmg 70 "$dmg"
[[ $step -le 75 ]] && sign_dmg 75 "$dmg"

_title "${0} DONE"
echo "Disk image written to $GPGOSX_WORKDIR/$dmg"
builtin unset dmg step
