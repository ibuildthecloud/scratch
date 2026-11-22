#!/bin/bash
# Usage: more.sh EXAMPLE  (sed-counter ps-stamps cobol-payroll jq-ttt, or all)
# The sed, PostScript, COBOL and jq examples, run in gpuifs under Xvfb and
# driven with xdotool, like inter.sh. sed is 9front's, inside h9; gs, the
# COBOL program and jq are Linux programs, run by h9 on the Alpine root
# that linuxroot.sh makes ($H9LINUX).
. $(dirname "$0")/lib.sh
H9LINUX=${H9LINUX:-$GPUIFS_DIR/third_party/hyper9/.local/linux/edge-tools}
[ -d "$H9LINUX/usr/bin" ] || { echo "no Linux root at $H9LINUX: run linuxroot.sh" >&2; exit 1; }
typ() { xdotool type --delay 60 "$1"; }
run() { n=$1; shift; start $n 300 $G "$@"; waitwin 40 || { echo "$n: no window"; return 1; }; sleep 5; }
one() {
case $1 in
sed-counter)
	cd $GPUIFS_DIR/examples/sed
	run counter -t Counter rc -c "echo 'window main title=Counter size=420,240' >/mnt/gpui/ctl; sed -nuf counter.sed /mnt/gpui/events"
	shot sed-counter 0
	recstart sed-counter
	for i in $(seq 12); do click 345 80; sleep .3; done; sleep 1
	for i in $(seq 15); do click 73 80; sleep .3; done; sleep 1
	click 210 191; sleep 1.5
	recstop sed-counter
	# 2026 presses of =, each one a full sed re-render
	xdotool key --delay 4 --repeat 2026 equal; sleep 8
	shot sed-counter-2026 0;;
ps-stamps)
	cd $GPUIFS_DIR/examples/ps
	run stamps -t Stamps --dir $H9LINUX:'#L' sh -c "exec gs -q -dNODISPLAY --permit-file-all='/9/mnt/gpui/*' stamps.ps </9/mnt/gpui/events"
	recstart ps-stamps
	click 150 580; sleep 1.5
	click 440 19; sleep .8; click 330 600; sleep 1.5
	click 102 19; sleep .8; click 466 19; sleep .8; click 430 300; sleep 1.5
	click 196 19; sleep .8; click 690 230; sleep 1.5
	click 277 19; sleep .8; click 590 520; sleep 1.2; click 790 500; sleep 1.2; click 820 330; sleep 1.2
	click 808 19; sleep 1; click 800 360; sleep 2
	recstop ps-stamps
	shot ps-stamps 0;;
cobol-payroll)
	cd $GPUIFS_DIR/examples/cobol
	$G --headless --dir $H9LINUX:'#L' cobc -x payroll.cob || exit 1
	run payroll -t Payroll --dir $H9LINUX:'#L' --env COB_LS_VALIDATE=false ./payroll
	recstart cobol-payroll
	click 481 207; sleep 2
	click 481 82; typ "Grace Hopper"; xdotool key Tab; typ "45"; xdotool key Tab; typ "62.50"; xdotool key Return; sleep 2
	typ "Alan Turing"; xdotool key Tab; typ "38"; xdotool key Tab; typ "71.25"; xdotool key Return; sleep 2
	typ "Ada Lovelace"; xdotool key Tab; typ "52"; xdotool key Tab; typ "88"; xdotool key Return; sleep 3
	recstop cobol-payroll
	shot cobol-payroll 0
	rm -f payroll;;
jq-ttt)
	cd $GPUIFS_DIR/examples/jq
	run ttt -t Tic-tac-toe --dir $H9LINUX:'#L' sh -c 'G=/9$gpuifs; jq -nj --arg window 1 -f ttt.jq >$G/ctl && jq -nRj --unbuffered -f ttt.jq <$G/events >$G/windows/main/root/ctl'
	recstart jq-ttt
	cell() { click $((70 + ($1 % 3) * 100)) $((118 + ($1 / 3) * 100)); sleep 1.3; }
	for c in 4 2 3 7 8; do cell $c; done; sleep 1.5
	shot jq-ttt-draw 0
	click 170 428; sleep 1.2
	for c in 0 8 2; do cell $c; done; sleep 2
	recstop jq-ttt
	shot jq-ttt 0;;
esac
killall_g
grep -v "^exit=143" $CAPTMP/${n:-$1}.log | tail -5
}
if [ "$1" = all ]; then for e in sed-counter ps-stamps cobol-payroll jq-ttt; do one $e; done; else one "$1"; fi
