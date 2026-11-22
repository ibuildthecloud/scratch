# Capture helpers: Xvfb on :99, lavapipe for Vulkan, xdotool to drive, ImageMagick import
# for stills and ffmpeg x11grab for GIFs. Start Xvfb first: Xvfb :99 -screen 0 1440x900x24 &
UITREEFS_DIR=${UITREEFS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
CAPTMP=${CAPTMP:-${TMPDIR:-/tmp}}
export DISPLAY=:99 VK_ICD_FILENAMES=/opt/lavapipe/lvp_icd.json H9ROOT=${H9ROOT:-$UITREEFS_DIR/third_party/hyper9/.local/9front/rootamd64}
G=$UITREEFS_DIR/target/release/uitreefs
OUT=$UITREEFS_DIR/examples/screenshots
mkdir -p $OUT
# start NAME TIMEOUT cmd...: run in bg, log to $CAPTMP/NAME.log
start() { n=$1; t=$2; shift 2; ( timeout $t "$@" > $CAPTMP/$n.log 2>&1; echo "exit=$?" >> $CAPTMP/$n.log ) & sleep 1; }
# wait for a uitreefs window to appear; sets WID, X, Y, W, H
waitwin() { for i in $(seq 1 ${1:-60}); do WID=$(xdotool search --onlyvisible --class uitreefs 2>/dev/null | tail -1); [ -z "$WID" ] && WID=$(xdotool search --onlyvisible --name . 2>/dev/null | tail -1); [ -n "$WID" ] && break; sleep 1; done; [ -z "$WID" ] && { echo no window; return 1; }; eval $(xdotool getwindowgeometry --shell $WID | sed 's/^WINDOW=.*//'); X=$X Y=$Y W=$WIDTH H=$HEIGHT; }
shot() { sleep ${2:-1}; import -window root -crop ${W}x${H}+${X}+${Y} +repage $OUT/$1.png; }
click() { xdotool mousemove $((X+$1)) $((Y+$2)) click 1; }
recstart() { ffmpeg -loglevel error -y -f x11grab -draw_mouse 0 -framerate 10 -video_size ${W}x${H} -i :99+$X,$Y $CAPTMP/$1.mp4 & RECPID=$!; sleep 0.5; }
recstop() { sleep 0.5; kill -INT $RECPID; wait $RECPID 2>/dev/null; ffmpeg -loglevel error -y -i $CAPTMP/$1.mp4 -vf "fps=10,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse" $OUT/$1.gif; }
killall_g() { pkill -f target/release/uitreefs; sleep 1; }
