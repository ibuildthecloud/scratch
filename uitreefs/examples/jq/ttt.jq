# ttt.jq: tic-tac-toe against jq, which plays perfectly.
#
#	uitreefs -t 'Tic-tac-toe' --dir ALPINE:#L sh -c \
#	    'jq -nRj --unbuffered -f ttt.jq <$ui/events >$ui/win/main/ctl'
#
# jq is a Linux program, so it runs in the h9 machine on an Alpine root
# (ALPINE is a tree with jq installed), where the tree is at $ui as for a
# Plan 9 client. jq can't open files, so the shell only wires them up:
# events in, the main window's ctl out. The main window exists before any
# client runs, so there is nothing to set up first. Everything else is jq,
# as a reducer: foreach folds each event line into the game state and
# emits that state's ctl lines.
#
# Every event line starts name key path, so jq splits on blanks and looks
# at the first two words. The first line (resync) makes the screen: the
# window's options and style, and a 3x3 grid. After that, each move is one
# ctl write of set lines, a cell's text and style each, which apply
# together.

def lines: [[0,1,2],[3,4,5],[6,7,8],[0,3,6],[1,4,7],[2,5,8],[0,4,8],[2,4,6]];
def winner($b): first(lines[] | select($b[.[0]] != null and $b[.[0]] == $b[.[1]] and $b[.[1]] == $b[.[2]])) // null;
def empties($b): [range(9) | select($b[.] == null)];
def other: if . == "X" then "O" else "X" end;

# negamax: the game's value for $p, to move on $b. A win now is worth 10,
# and each move it waits costs one, so jq wins fast and loses slow.
def negamax($b; $p):
  if winner($b) then -10
  else empties($b) as $e
  | if ($e | length) == 0 then 0
    else [$e[] as $i | - negamax($b | .[$i] = $p; $p | other)] | max
      | if . > 0 then . - 1 elif . < 0 then . + 1 else . end
    end
  end;
def best($b; $p):
  if (empties($b) | length) == 8 then
    # The reply to an opening move is book: the centre, or a corner.
    if $b[4] == null then 4 else 0 end
  else [empties($b)[] as $i | {i: $i, s: (- negamax($b | .[$i] = $p; $p | other))}]
    | max_by(.s) | .i
  end;

def full: empties(.board) | length == 0;
def settle($who):
  if winner(.board) then
    .over = true | .line = winner(.board) | .score[$who] += 1
    | .msg = (if $who == "X" then "You win. jq has a bug." else "jq wins." end)
  elif full then .over = true | .score.draw += 1 | .msg = "Draw. jq doesn't lose."
  else . end;

def play($i):
  if .over or .board[$i] != null then .
  else .board[$i] = "X" | settle("X")
    | if .over then .
      else .board[best(.board; "O")] = "O" | settle("O")
        | if .over then . else .msg = "Your move." end
      end
  end;

def newgame: .board = [range(9) | null] | .over = false | .line = null | .msg = "You're X. Your move.";

# ---- Drawing ----------------------------------------------------------------

def q: "'" + gsub("'"; "''") + "'";
def look($i):
  .board[$i] as $v
  | ((.line // []) | index([$i]) != null) as $won
  | (if $v == "X" then "text_color=info" elif $v == "O" then "text_color=danger" else "" end) as $ink
  | (if $won then "bg=success text_color=success_foreground"
     elif $v == null and (.over | not) then "cursor_pointer hover:bg=accent" else "" end) as $hi
  | "h=92 flex items_center justify_center rounded_lg border_1 border_color=border text_size=52 font_bold \($ink) \($hi)";
def cell($i): "set board/c\($i) text=\((.board[$i] // "") | q) : \(look($i))";
def score: "You \(.score.X)   jq \(.score.O)   draws \(.score.draw)";
def screen:
  [ "set . title=Tic-tac-toe size=340,470 resizable=off pos=center : v_flex items_center p=24 gap=16 bg=background",
    "new text status text=\(.msg | q) : text_lg font_semibold text_center w_full",
    "new grid board cols=3 gap=8 : w=292",
    (range(9) as $i | "new text board/c\($i) tag=c\($i) on=click : \(look($i))"),
    "new text score text=\(score | q) : text_sm text_center text_color=muted_foreground",
    "new button again label='New game' tag=again : ghost" ]
  | join("\n") + "\n";
def update:
  [ "set status text=\(.msg | q)", (range(9) as $i | cell($i)), "set score text=\(score | q)" ]
  | join("\n") + "\n";

# ---- The reducer ------------------------------------------------------------

foreach (inputs | split(" ") | select(.[0] == "resync" or .[0] == "click")) as $w (
  {score: {X: 0, O: 0, draw: 0}} | newgame;
  .first = ($w[0] == "resync")
  | if $w[1] == "again" then newgame
    elif $w[1] | test("^c[0-8]$") then play($w[1][1:] | tonumber)
    else . end;
  if .first then screen else update end
)
