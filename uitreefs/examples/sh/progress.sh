#!/usr/bin/env bash
# progress.sh: a progress window for any long command, driven from the
# host with plan9port's 9p(1) over uitreefs -a. No h9 machine is involved:
# this is the "outside client" mode of DESIGN.md § Running a client in h9.
#
#	./progress.sh 'Building release' make -j8 release
#	./progress.sh -n 120 'Converting photos' ./convert.sh *.heic   # -n: expected lines, for a real bar
#
# The window shows the latest output line, a bar (indeterminate unless -n
# says how many lines to expect), elapsed time, and a Details section with
# the full log. Cancel kills the command. The script exits with its status.
#
# Shows: a host-side client in bash, uitreefs -a unix!path, 9p write/read,
# events read with `read -r name key path`, progress, collapsible, a
# readonly editor as a log, notify on finish, the finished state set in
# one ctl write. Closing the window quits by itself, which ends the event
# stream, and the command is stopped then.   Needs: M3
set -u

expect=0
if [[ ${1:-} == -n ]]; then expect=$2; shift 2; fi
[[ $# -ge 2 ]] || { echo "usage: progress.sh [-n lines] title command [arg...]" >&2; exit 2; }
title=$1; shift

sock=${TMPDIR:-/tmp}/uitreefs-progress.$$
addr="unix!$sock"
log=$(mktemp)
trap 'rm -f "$log" "$sock"' EXIT

uitreefs -t "$title" -a "$addr" &
host=$!
for _ in $(seq 50); do 9p -a "$addr" ls / >/dev/null 2>&1 && break; sleep 0.1; done

put() { printf '%s' "$2" | 9p -a "$addr" write "$1"; }        # one value or one command
q() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }             # Plan 9 quoting

m=win/main
put $m/ctl "set . title=$(q "$title") size=520,200 min=420,180 pos=center"
put $m/tree "div root  : v_flex size_full p=20 gap=10 bg=background
  div head  : h_flex items_center gap=8
    spinner spin  : sm
    text title  text=$(q "$title")  : font_semibold flex_1
    text time  text=0:00  : text_sm text_color=muted_foreground font_family=monospace
  progress bar
  text line  text=Starting…  : text_xs text_color=muted_foreground truncate font_family=monospace
  collapsible more
    button trigger  label=Details  icon=chevron-right  : ghost xs
    div content  : h=200
      editor log  readonly  soft_wrap  : size_full
  div foot  : h_flex justify_end
    button cancel  label=Cancel  tag=cancel  : outline
"
put keys "escape cancel"

# Run the command, its output into the log; a reader updates the window.
start=$SECONDS
"$@" >"$log" 2>&1 &
job=$!

# Events from the host: Cancel (the button or Escape), then Close. The
# window's close button quits the app, which ends the stream: stop the job.
{
	9p -a "$addr" read events | while read -r name key path rest; do
		case "$name $key" in
		"click cancel"|"action cancel")
			if kill -0 "$job" 2>/dev/null; then kill "$job"; else put ctl quit; fi ;;
		esac
	done
	kill "$job" 2>/dev/null
} &

lines=0
while kill -0 "$job" 2>/dev/null; do
	sleep 0.25
	n=$(wc -l <"$log")
	if (( n != lines )); then
		lines=$n
		put $m/line/text "$(tail -n 1 "$log" | cut -c1-200)"
		(( expect > 0 )) && put $m/bar/value $(( n * 100 / expect > 99 ? 99 : n * 100 / expect ))
	fi
	t=$(( SECONDS - start )); put $m/head/time/text "$(printf '%d:%02d' $((t / 60)) $((t % 60)))"
done
wait "$job"; status=$?

# Done: full bar, the whole log, and the button becomes Close, in one write.
put $m/more/content/log/value "$(cat "$log")"
if (( status == 0 )); then
	put $m/ctl "set bar value=100
delete head/spin
set foot/cancel label=Close : primary
set line text=$(q "Finished in $(( SECONDS - start ))s")
notify $(q "$title: done") type=success"
else
	put $m/ctl "set bar value=100
delete head/spin
set foot/cancel label=Close : primary
set line text=$(q "Failed with status $status")
set more open=on
notify $(q "$title failed") type=error sticky=on"
fi

wait "$host"
exit "$status"
