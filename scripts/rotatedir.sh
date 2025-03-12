#!/usr/bin/env bash
# vim: ft=sh ts=4 sw=4 noet
#
# Backup (rotate) a given directory.

set -euo pipefail

function die {
	echo >&2 "$@"
	exit 1
}

function usage {
	die "Usage: $(basename "$0") {directory} [directory ...]"
}

function main {
	[[ $# -ge 1 ]] || usage
	local d ts
	ts=$(date '+%Y%m%d%H%M%S')
	for d in "$@"; do
		[[ ! -d $d ]] || mv "$d" "$d-$ts"
		mkdir "$d"
	done
}

main "$@"
