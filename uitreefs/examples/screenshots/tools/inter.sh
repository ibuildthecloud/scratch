# Usage: inter.sh EXAMPLE  (counter hello signin todo calc confirm chat gallery settings settings-dark stocks paint files dock notes)
# Runs one rc example in gpuifs under Xvfb, drives it with xdotool and writes PNG/GIF captures.
. $(dirname "$0")/lib.sh
cd $UITREEFS_DIR/examples/rc
typ() { xdotool type --delay 70 "$1"; }
drag() { xdotool mousemove $((X+$1)) $((Y+$2)) mousedown 1; shift 2; while [ $# -gt 1 ]; do xdotool mousemove $((X+$1)) $((Y+$2)); sleep 0.05; shift 2; done; xdotool mouseup 1; }
run() { n=$1; shift; start $n 120 $G "$@"; waitwin 40 || { echo "$n: no window"; return 1; }; sleep 6; }
case $1 in
counter) run counter -t Counter rc counter.rc; recstart counter; for i in 1 2 3; do click 225 90; sleep .6; done; click 73 90; sleep .6; xdotool key equal; sleep 1; recstop counter; shot counter-after 0;;
hello) run hello -t Greeter rc hello.rc; recstart hello; click 125 41; sleep .5; typ "Jeff"; sleep .3; click 307 41; sleep 2; recstop hello; shot hello-greeted 0;;
signin) run signin -t 'Sign in' rc signin.rc; recstart signin; click 175 229; sleep 2; click 170 118; typ "jeff@example"; click 175 229; sleep 2; click 300 118; typ ".com"; click 170 212; typ "hunter2"; sleep .5; click 175 283; sleep 3; recstop signin; shot signin-after 0;;
todo) run todo -t Todos rc todo.rc; recstart todo; click 205 96; for t in "Build gpuifs" "Run it in h9" "Take screenshots"; do typ "$t"; xdotool key Return; sleep 1.2; done; sleep 1; shot todo-items 0; recstop todo;;
calc) run calc -t Calculator rc calc.rc; recstart calc; for p in "42 313" "113 313" "255 195" "184 313" "255 372" "255 313" "42 195" "255 372"; do click $p; sleep .6; done; sleep 1; recstop calc; shot calc-result 0;;
confirm) run confirm -t Confirm rc confirm.rc 'Delete 3 files?' 'This cannot be undone.'; recstart confirm; sleep 1; xdotool mousemove $((X+250)) $((Y+117)); sleep 1; click 328 117; sleep 5; recstop confirm;;
chat) run chat -t Chat rc chat.rc; recstart chat; click 240 671; typ "I feel tired today"; xdotool key Return; sleep 4; typ "because of my computer"; xdotool key Return; sleep 4; recstop chat; shot chat-reply 0;;
gallery) run gallery -t Gallery rc gallery.rc; recstart gallery; for p in "43 286" "40 394" "38 490" "39 598" "42 658"; do click $p; sleep 3; shot gallery-$(echo $p|tr ' ' _) 0; done; click 1040 37; sleep 3; shot gallery-dark 0; recstop gallery;;
settings) run settings -t Settings rc settings.rc; recstart settings; click 84 105; sleep 3; shot settings-appearance 0; click 70 141; sleep 3; shot settings-account 0; click 75 177; sleep 3; shot settings-shortcuts 0; recstop settings;;
settings-dark) run settings -t Settings rc settings.rc; recstart settings-dark; click 84 105; sleep 3; click 500 134; sleep 4; shot settings-dark 0; click 70 69; sleep 3; recstop settings-dark; rm -f settings.txt;;
stocks) run stocks -t Stocks rc stocks.rc; recstart stocks; sleep 4; click 40 117; sleep 5; click 40 149; sleep 5; recstop stocks; shot stocks-nvda 0;;
paint) run paint -t Paint rc paint.rc; recstart paint; drag 100 200 140 160 180 150 220 170 240 210 230 260 200 290 160 300 120 280 100 240 100 200; click 73 19; sleep 1; drag 350 300 400 250 450 300 500 250 550 300 600 250; click 123 19; sleep 1; drag 300 450 350 470 400 480 450 470 500 450 550 420; sleep 2; recstop paint; shot paint-drawn 0;;
files) run files -t Files rc files.rc; recstart files; click 22 21; sleep 3; click 60 280; sleep 3; xdotool mousemove $((X+60)) $((Y+280)) click --repeat 2 1; sleep 3; recstop files; shot files-browse 0;;
dock) run dock -t Workspace rc dock.rc; recstart dock; xdotool key ctrl+shift+p; sleep 3; typ "spl"; sleep 2; shot dock-palette 0; xdotool key Escape; sleep 2; recstop dock;;
notes) run notes -t Notes rc notes.rc; recstart notes; xdotool key ctrl+n; sleep 4; click 500 200; typ "# Hello from h9"; xdotool key Return Return; typ "Written in a GPUI editor, saved by rc."; sleep 1; xdotool key ctrl+s; sleep 3; recstop notes; shot notes-new 0;;
still) shift; n=$1; d=$2; shift 2; cd $UITREEFS_DIR/examples/$d; start $n 90 $G "$@"; waitwin 60 || exit 1; shot $n 10;;
esac
killall_g
grep -v "^exit=143" $CAPTMP/${n:-$1}.log | tail -5
