#!/bin/bash
# linuxroot.sh [DIR]: make the Alpine root the sed/PostScript/COBOL/jq
# examples run on: ghostscript, gnucobol (with gcc and musl-dev for cobc),
# jq and GNU sed, from Alpine edge (gnucobol is only in edge/testing).
# Uses apk.static on the host, so it needs no Alpine and no root inside h9.
set -e
GPUIFS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
DIR=${1:-$GPUIFS_DIR/third_party/hyper9/.local/linux/edge-tools}
E=https://dl-cdn.alpinelinux.org/alpine/edge
T=$(mktemp -d)
v=$(curl -sL $E/main/x86_64/APKINDEX.tar.gz | tar xzO APKINDEX | awk '/^P:apk-tools-static$/{f=1} f&&/^V:/{print substr($0,3); exit}')
curl -sL $E/main/x86_64/apk-tools-static-$v.apk | tar xz -C $T 2>/dev/null
mkdir -p "$DIR"
$T/sbin/apk.static --root "$DIR" --initdb --allow-untrusted --no-cache \
	-X $E/main -X $E/community -X $E/testing \
	add alpine-base ghostscript jq gnucobol gcc musl-dev sed
rm -rf $T
echo "$DIR"
