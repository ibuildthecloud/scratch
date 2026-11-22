#!/bin/bash
# all.sh: every capture in ../ (stills first, then the driven runs).
# Go clients are built for GOOS=plan9 and the C one with mk inside h9.
T=$(dirname "$0"); . $T/lib.sh
i() { bash $T/inter.sh "$@"; }
# Start from no saved state: todo.rc and settings.rc keep files in rc/.
rm -f $UITREEFS_DIR/examples/rc/todo.txt $UITREEFS_DIR/examples/rc/settings.txt
for e in counter:Counter confirm:Confirm hello:Greeter signin:'Sign in' todo:Todos calc:Calculator chat:Chat settings:Settings gallery:Gallery files:Files stocks:Stocks dock:Workspace notes:Notes paint:Paint; do
	n=${e%%:*}; t=${e#*:}
	if [ $n = confirm ]; then i still $n rc -t "$t" rc $n.rc 'Delete 3 files?' 'This cannot be undone.'; else i still $n rc -t "$t" rc $n.rc; fi
done
i still awk-csvview awk -t CSV awk -f csvview.awk planets.csv
for e in counter hello signin todo calc confirm chat gallery settings settings-dark stocks paint files dock notes; do i $e; done
# Go and C
B=$CAPTMP/gpuifs-bin; mkdir -p $B
(cd $UITREEFS_DIR/examples/go/greet && GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0 go build -o $B/greet .)
(cd $UITREEFS_DIR/examples/go/clock && GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0 go build -o $B/clock .)
cd $B
start greet 90 $G -t Greeter ./greet; waitwin 60 && { sleep 6; shot go-greet 0; recstart go-greet; click 120 40; xdotool type --delay 70 "Go client"; xdotool key Return; sleep 3; recstop go-greet; shot go-greet-done 0; }; killall_g
start clock 90 $G -t Clock ./clock; waitwin 60 && { sleep 8; shot go-clock 0; recstart go-clock; sleep 5; recstop go-clock; }; killall_g
cd $UITREEFS_DIR/examples/c
timeout 300 $G --headless rc -c 'objtype=amd64; mk' >/dev/null 2>&1
start life 120 $G -t Life rc -c './6.out'; waitwin 60 && { sleep 8; recstart c-life; click 340 35; sleep 1.5; click 203 35; sleep 8; recstop c-life; shot c-life-running 0; }; killall_g
rm -f 6.out life.6
ffmpeg -loglevel error -y -i $CAPTMP/c-life.mp4 -vf "fps=6,scale=400:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=16[p];[b][p]paletteuse" $OUT/c-life.gif
ffmpeg -loglevel error -y -i $CAPTMP/stocks.mp4 -vf "fps=5,scale=700:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse" $OUT/stocks.gif
rm -f $UITREEFS_DIR/examples/rc/settings.txt
