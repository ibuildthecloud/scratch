#!/bin/sh
# bench.sh N: the numbers in protocols/render.md § Latency.
#
# Runs big.rc (N rows plus a counter) under uitree-remote, lets a primary
# toy renderer click the counter 20 times once the tree is built, and
# meanwhile hot-attaches a mirror that takes the snapshot and leaves.
# Needs `zig build remote -Dh9=true` in core/ and $H9ROOT (or h9's
# built-in root with rc, awk and dc in it).
set -e
N=${1:-10}
here=$(cd "$(dirname "$0")" && pwd)
bin=$here/../../core/zig-out/bin/uitree-remote
sock=${TMPDIR:-/tmp}/uitree-render-$$.sock
log=${TMPDIR:-/tmp}/uitree-render-$$.log
cd "$here"
"$bin" -R "unix!$sock" rc big.rc "$N" 2>"$log" &
core=$!
trap 'kill $core 2>/dev/null; rm -f "$sock" "$log" "$log.p"' EXIT
while [ ! -S "$sock" ]; do sleep 0.1; done
python3 -u render.py "unix!$sock" --wait "win/main/rows/r$((N-1))/b" --bench 20 >"$log.p" 2>&1 &
p=$!
until grep -q '^tree:' "$log.p" 2>/dev/null; do sleep 0.2; done
python3 -u render.py "unix!$sock" --name mirror1 --role mirror --once
wait $p
cat "$log.p"
