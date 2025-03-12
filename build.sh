#!/usr/bin/env bash
# vim: ts=4 sw=4 noet ft=bash
# shellcheck disable=2155
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

set -uo pipefail

function die {
	echo >&2 "$@"
	exit 1
}

function usage {
	die "Usage: $(basename "$0") {arm64 | x86_64} {configfile} [step]"
}

if [ $# -lt 2 ]; then
	usage
elif [ $# -ge 3 ]; then
	step=$3
else
	step=0
fi

. ./common.sh || die "Error sourcing ./common.sh"
. "$2" || die "Error sourcing $2"

declare -r ARCH="$1"
case "$ARCH" in
arm64)
	ABITYPE=""
	GPGOSX_CFLAGS="$ARM_FLAGS"
	HOSTTYPE=aarch64-apple-darwin
	export SDKROOT="$ARM_SDKROOT"
	;;
x86_64)
	ABITYPE="-m64"
	GPGOSX_CFLAGS="$X86_FLAGS"
	HOSTTYPE=x86_64-apple-darwin
	export SDKROOT="$X86_SDKROOT"
	;;
clean)
	# Pseudo-architecture, cleanup work directory.
	rm -fr "${GPGOSX_WORKDIR:?}" "${GPGOSX_WORKDIR:?}".{bak,tar}
	echo "Cleanup complete, exiting."
	exit 0
	;;
*)
	usage
	;;
esac
declare -r ABI=64
declare -r GPGOSX_BUILDDIR="$GPGOSX_WORKDIR/$ARCH-build"
declare -r GPGOSX_DISTDIR="$GPGOSX_WORKDIR/$ARCH-dist"
declare -r GPGOSX_PATCHESDIR="$GPGOSX_PROJECTDIR/patches"
declare -r GPGOSX_RELDIR="$GPGOSX_WORKDIR/$ARCH-rel"

# shellcheck disable=2016
type -p pkg-config || die 'Cannot find pkg-config in $PATH'

function build_log {
	echo >>"$GPGOSX_LOGDIR/build.log" "$(date): $ARCH" "$@"
}

function check_access {
	local dir=$1
	[[ -d $dir ]] || die "Missing directory $dir"
	mktemp -qu "$dir/XXXX" || die "$dir is not writable for user $(whoami)"
}

check_access "$GPGOSX_INSTALLDIR"
_mkdir "$GPGOSX_WORKDIR"

function libs_list {
	grep -E '^[a-z]+:/' "$GPGOSX_PROJECTDIR/libraries"
}

function lib_url {
	echo "$1" | cut -d '|' -f 1
}

function lib_checksum {
	echo "$1" | cut -d '|' -f 2
}

function lib_tarball {
	local tball line=$1
	tball=$(echo "$line" | cut -d '|' -f 3)
	[[ -n $tball ]] || tball=$(basename "$(lib_url "$line")")
	echo "$tball"
}

function download {
	local url=$1 dst=$2
	echo "Download $url"
	curl --fail --location --silent --show-error --output "$dst" "$url" ||
		die "Failed to download $url"
}

function verify_sig {
	local sig=$1 file=$2
	if [[ -n $GPGOSX_EXISTING_BINARY ]]; then
		"$GPGOSX_EXISTING_BINARY" --verify "$sig" "$file" || die "$file failed signature check"
	fi
}

function download_libs {
	local chk dst l sha sig url
	[[ -d $GPGOSX_DOWNLOADDIR ]] || die "Missing directory $GPGOSX_DOWNLOADDIR"
	for l in $(libs_list); do
		url=$(lib_url "$l")
		chk=$(lib_checksum "$l")
		dst="$GPGOSX_DOWNLOADDIR/$(lib_tarball "$l")"
		[[ -f $dst ]] || download "$url" "$dst"
		if [[ $chk == sig ]]; then
			sig="$dst.sig"
			[[ -f $sig ]] || download "$url.sig" "$sig"
			verify_sig "$sig" "$dst"
		else
			sha=$(shasum -a 256 -b "$dst" | awk '{print $1}')
			[[ $sha == "$chk" ]] || die "$dst: SHA checksum mismatch"
		fi
	done
}

function download_gnupg {
	local sig tball
	tball="$GPGOSX_DOWNLOADDIR/"$(basename "$GNUPG_TARBALL_URL")
	if [[ $GNUPG_VERSION == nightly ]]; then
		[[ -f $tball ]] || die "Missing file $tball"
	else
		[[ -f $tball ]] || download "$GNUPG_TARBALL_URL" "$tball"
		sig="$tball.sig"
		[[ -f $sig ]] || download "$GNUPG_TARBALL_URL.sig" "$sig"
		verify_sig "$sig" "$tball"
	fi
}

_title "$0 START"
build_log "$0 START"
[[ $step -le 1 ]] && download_libs
[[ $step -le 3 ]] && download_gnupg
[[ $step -le 5 ]] && rmkdir "$GPGOSX_BUILDDIR" "$GPGOSX_DISTDIR"
cd "$GPGOSX_BUILDDIR" || die

function build_lib {
	local cstep=$1 lib=$2 extra_cflags=
	local cfenv cfopts jobs libname srcdir
	libname=${lib/-[0-9]*/}
	_title "Build $lib"
	case "$libname" in
	gettext)
		srcdir="$GPGOSX_BUILDDIR/$lib/gettext-runtime"
		;;
	libassuan)
		extra_cflags=" -std=gnu89"
		srcdir="$GPGOSX_BUILDDIR/$lib"
		;;
	*)
		srcdir="$GPGOSX_BUILDDIR/$lib"
		;;
	esac
	pushd "$srcdir" || die
	[[ -f configure ]] || ./autogen.sh || die "Autogen failed (cstep $cstep)"

	jobs=$NCPU
	cfenv=(
		ABI="$ABI"
		CFLAGS="-arch $ARCH $ABITYPE $GPGOSX_CFLAGS$extra_cflags"
		CPPFLAGS="-arch $ARCH -I$GPGOSX_DISTDIR/include $GPGOSX_CFLAGS$extra_cflags"
		CXXFLAGS="-arch $ARCH $GPGOSX_CFLAGS$extra_cflags"
		GPG_ERROR_CONFIG="$GPGOSX_DISTDIR/bin/gpgrt-config --libdir=$GPGOSX_DISTDIR/lib gpg-error"
		LDFLAGS="-arch $ARCH -L$GPGOSX_DISTDIR/lib"
		OBJCFLAGS="-arch $ARCH $GPGOSX_CFLAGS$extra_cflags"
		PKG_CONFIG_PATH="$GPGOSX_DISTDIR/lib/pkgconfig"
	)
	cfopts=(--host="$HOSTTYPE" --prefix="$GPGOSX_DISTDIR" --disable-doc)
	case "$libname" in
	gettext)
		cfopts+=(--without-emacs)
		;;
	gpgme)
		cfopts+=(--disable-gpg-test)
		;;
	libgcrypt | libiconv)
		[[ $ARCH == arm64 ]] && cfopts+=(--disable-asm)
		;;
	esac

	build_log "Configure $lib"
	env "${cfenv[@]}" ./configure "${cfopts[@]}" || die "Failed to configure $lib (cstep $cstep)"
	build_log "Build $lib"
	make -j"$jobs" || die "Failed to build $lib (cstep $cstep)"
	make install || die "Failed to install $lib (cstep $cstep)"
	popd || die
}

function apply_patch {
	local patch pname=$1 dir=$2
	shift 2
	patch="$GPGOSX_PATCHESDIR/$pname.patch"
	if [[ -f $patch ]]; then
		[[ $dir == . ]] || pushd "$dir" || die
		build_log "Apply $(basename "$patch")"
		patch -p1 <"$patch" || die "Failed to apply $patch"
		if [[ $pname =~ ^libgcrypt ]]; then
			# Force invocation of autogen
			rm -fv configure
		fi
		[[ $dir == . ]] || popd || die
	fi
}

function build_libs {
	local step=$1 cstep lib line star tar tball
	cstep="$step"
	star="$GPGOSX_BUILDDIR-step$step.tar"
	[[ ! -d $star ]] || restore_dir "$step" "$GPGOSX_BUILDDIR" "$star"
	cd "$GPGOSX_BUILDDIR" || die "Cannot cd into $GPGOSX_BUILDDIR"
	for line in $(libs_list); do
		if [[ $step -le $cstep ]]; then
			tball=$(lib_tarball "$line")
			tar="$GPGOSX_DOWNLOADDIR/$tball"
			tar -xf "$tar" || die "Failed to extract $tar (cstep $cstep)"
			lib=${tball/.tar.*/}
			apply_patch "$lib" "$GPGOSX_BUILDDIR/$lib"
			build_lib "$cstep" "$lib"
		fi
		cstep=$((cstep + 1))
	done
	[[ -d $star ]] || backup_dir "$step" "$GPGOSX_BUILDDIR" "$star"
}

export PATH="$GPGOSX_DISTDIR/bin:$GPGOSX_DISTDIR/lib:$PATH"

[[ $step -le 10 ]] && build_libs 10

function unpack_gnupg {
	local step=$1
	build_log "Extract $GNUPG_TARBALL"
	tar -C "$GPGOSX_BUILDDIR" -xf "$GPGOSX_DOWNLOADDIR/$GNUPG_TARBALL" || stepfail "$step"
}

[[ $step -le 40 ]] && unpack_gnupg 40
cd "$GPGOSX_BUILDDIR/gnupg-$GNUPG_VERSION" || die
apply_patch "gnupg-$GNUPG_VERSION" .

function config_gnupg {
	_title "Configure GnuPG"
	build_log "Configure GnuPG"
	local cfenv cfopts step=$1 prefix=$2
	cfopts=(
		--host="$HOSTTYPE"
		--localstatedir=/var
		--prefix="$prefix"
		--sysconfdir="$prefix/etc"
		--with-agent-pgm="$prefix/bin/gpg-agent"
		--with-dirmngr-ldap-pgm="$prefix/libexec/dirmngr_ldap"
		--with-dirmngr-pgm="$prefix/bin/dirmngr"
		--with-ksba-prefix="$GPGOSX_DISTDIR"
		--with-libassuan-prefix="$GPGOSX_DISTDIR"
		--with-libgcrypt-prefix="$GPGOSX_DISTDIR"
		--with-libgpg-error-prefix="$GPGOSX_DISTDIR"
		--with-libiconv-prefix="$GPGOSX_DISTDIR"
		--with-libintl-prefix="$GPGOSX_DISTDIR"
		--with-npth-prefix="$GPGOSX_DISTDIR"
		--with-ntbtls-prefix="$GPGOSX_DISTDIR"
		--with-pinentry-pgm="$prefix/bin/pinentry"
		--with-protect-tool-pgm="$prefix/libexec/gpg-protect-tool"
		--with-readline="$GPGOSX_DISTDIR"
		--with-scdaemon-pgm="$prefix/libexec/scdaemon"
	)
	if [[ ! -f configure ]]; then
		env GETTEXT_PREFIX="$GPGOSX_DISTDIR/bin/" ./autogen.sh --force || stepfail "$step/a"
		cfopts+=(--disable-tests --disable-doc --enable-maintainer-mode)
	fi
	[[ $ARCH == arm64 ]] || cfopts+=(--disable-doc)
	#extra_cflags=" -std=gnu89"
	extra_cflags=""
	cfenv=(
		ABI="$ABI"
		CFLAGS="-arch $ARCH $ABITYPE $GPGOSX_CFLAGS$extra_cflags"
		CPPFLAGS="-arch $ARCH -I$GPGOSX_DISTDIR/include $GPGOSX_CFLAGS$extra_cflags"
		CXXFLAGS="-arch $ARCH $GPGOSX_CFLAGS$extra_cflags"
		LDFLAGS="-arch $ARCH -L$GPGOSX_DISTDIR/lib"
		PKG_CONFIG_PATH="$GPGOSX_DISTDIR/lib/pkgconfig"
	)
	env "${cfenv[@]}" ./configure "${cfopts[@]}" "${GNUPG_CFOPTS[@]}" || stepfail "$step/b"
}

[[ $step -le 42 ]] && config_gnupg 42 "$GPGOSX_INSTALLDIR"

function tweak_script {
	local src=$1 dst=$2
	sed -e "s,DISTDIR,$GPGOSX_DISTDIR,g" \
		-e "s,INSTALLDIR,$GPGOSX_INSTALLDIR,g" \
		"$src" >"$dst" || return 1
	chmod 0755 "$dst" || return 2
	return 0
}

function tweak_buildaux {
	[[ -d build-aux ]] || return
	pushd build-aux || die
	local ins=install-sh
	echo "Tweaking $ins"
	if [[ ! -e "$ins.orig" ]]; then
		mv -f "$ins" "$ins.orig" || stepfail "43/a"
	fi
	tweak_script "$GPGOSX_PROJECTDIR/scripts/$ins-wrapper" "$ins" || stepfail "43/b"
	popd || die
}

function tweak_makefiles {
	local f wrp tmp=$(mktemp)
	wrp="$GPGOSX_DISTDIR/install-wrapper"
	tweak_script "$GPGOSX_PROJECTDIR/scripts/install-wrapper" "$wrp" || stepfail "44/a"
	find . -name Makefile | while read -r f; do
		echo "Tweaking $f"
		awk <"$f" >"$tmp" -v "w=$wrp" \
			'{ gsub("/usr/bin/install", w); gsub("/usr/local/bin/ginstall", w); print $0; }' ||
			stepfail "44/c"
		cat "$tmp" >"$f" || stepfail "44/d"
	done
	rm "$tmp"
}

[[ $step -le 43 ]] && tweak_buildaux "$GPGOSX_DISTDIR"
[[ $step -le 44 ]] && tweak_makefiles "$GPGOSX_DISTDIR"

function build_gnupg {
	local j="-j$1"
	_title "Build GnuPG ($j)"
	build_log "Build GnuPG ($j)"
	make "$j" || return 1
	return 0
}

if [[ $step -le 45 ]]; then
	if ! build_gnupg "$NCPU"; then
		# Parallel builds sometimes fail.
		date
		echo "Retrying failed build in $WAIT_AFTER_ERR seconds..."
		sleep "$WAIT_AFTER_ERR"
		date
		sync
		sleep 3
		build_gnupg 1 || stepfail 45
	fi
fi

if [[ $step -le 46 ]]; then
	make install || stepfail 46
fi

function adjust_ldpaths {
	local f newp p pl step=$1 dir=$2
	echo "Adjusting ld-paths in $(pwd -P)"
	pushd "$dir" || die "Cannot pushd to $dir"
	find . -type f | while read -r f; do
		[[ -f $f ]] || continue
		echo "Adjusting $f"
		install_name_tool -add_rpath @loader_path/../lib "$f"
		pl=$(otool -L "$f" | grep "$GPGOSX_WORKDIR" | awk '{print $1}')
		for p in $pl; do
			newp="@rpath/$(basename "$p")"
			install_name_tool -change "$p" "$newp" "$f"
		done
	done
	popd || die
}

if [[ $step -le 46 ]]; then
	# Ensure public read access to all files.
	find "$GPGOSX_DISTDIR" -type f -exec chmod a+r {} +
	cd "$GPGOSX_DISTDIR/bin" || die
	for g in gpg gpgv; do
		if [[ -d $g ]]; then
			mv $g/$g $g.new
			rm -r $g
			mv $g.new $g
		fi
	done
	builtin unset g
fi

[[ $step -le 47 ]] && adjust_ldpaths 47 "$GPGOSX_DISTDIR/bin"
# No more libexec directory in GnuPG 2.5.5 ?
[[ $step -le 48 ]] && adjust_ldpaths 48 "$GPGOSX_DISTDIR/libexec"

function reldir_populate {
	local t step=$1
	_title "Populating $GPGOSX_RELDIR"
	# dist=(
	# 	bin
	# 	lib/*.dylib
	# 	libexec
	# 	share/gnupg
	# 	share/doc
	# 	share/info
	# 	share/locale
	# 	share/man
	# )
	pushd "$GPGOSX_DISTDIR" || die
	_mkdir "$GPGOSX_RELDIR"
	t="$(mktemp).tar"
	tar -cf "$t" --dereference --exclude "bin/*config" bin lib* share || stepfail "$step/d1"
	tar -C "$GPGOSX_RELDIR" -xf "$t" || stepfail "$step/d2"
	rm "${t:?}"
	popd || die
	pushd "$GPGOSX_RELDIR/bin" || stepfail "$step"
	ln -fs gpg gpg2
	install -m 0755 "$GPGOSX_PROJECTDIR/scripts/convert-keyring" . || stepfail "$step/ck"
	popd || die
}

function adjust_lp {
	local p pl step=$1 f=$2 pathseg=$3
	_title "Adjusting $f"
	install_name_tool -add_rpath "@loader_path/$pathseg/lib" "$f"
	pl=$(otool -L "$f" | grep "$GPGOSX_DISTDIR" | awk '{print $1}')
	for p in $pl; do
		newp="@rpath/$(basename "$p")"
		install_name_tool -change "$p" "$newp" "$f"
	done
}

function reldir_dylibs {
	local f step=$1
	pushd "$GPGOSX_RELDIR/lib" || die
	rm -f libgettext*
	find . -type f -name '*.dylib' | while read -r f; do
		adjust_lp "$step" "$f" '..'
	done
	popd || die
}

function reldir_ids {
	local f step=$1
	pushd "$GPGOSX_RELDIR/lib" || die
	find . -name '*.dylib' | while read -r f; do
		if [[ -f $f ]] && [[ ! -L $f ]]; then
			echo "Changing ID of $f"
			install_name_tool -id "$GPGOSX_LIBID_PREFIX/lib/$f" "$f" || stepfail 52
		fi
	done
	popd || die
}

[[ $step -le 50 ]] && reldir_populate 50
[[ $step -le 55 ]] && reldir_dylibs 55
[[ $step -le 60 ]] && reldir_ids 60

function workdir_ref {
	local c f fl=() step=$1 dir=$2 skip_re=$3
	for f in "$dir"/*; do
		if [[ -n $skip_re ]] && [[ $f =~ $skip_re ]]; then
			continue
		fi
		fl+=("$f")
	done
	# Count references to build directory
	c=$(otool -L "${fl[@]}" | grep -c "$GPGOSX_WORKDIR")
	[[ $c -eq 0 ]] || die "Found $c reference(s) to $GPGOSX_WORKDIR (step $step), should be 0."
}

if [[ $step -le 65 ]]; then
	cd "$GPGOSX_RELDIR" || die
	workdir_ref 65 bin 'convert-keyring'
	workdir_ref 66 libexec 'watch-defaultroute'
	workdir_ref 67 lib ''
fi

build_log "$0 END"
_title "$0 END"
echo "$ARCH build results written to $GPGOSX_RELDIR"
builtin unset step
