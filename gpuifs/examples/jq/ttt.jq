# ttt.jq: tic-tac-toe against jq, which plays perfectly.
#
#	gpuifs -t 'Tic-tac-toe' --dir ALPINE:#L sh -c \
#	    'G=/9$gpuifs; jq -nj --arg window 1 -f ttt.jq >$G/ctl &&
#	     jq -nRj --unbuffered -f ttt.jq <$G/events >$G/windows/main/root/ctl'
#
# jq is a Linux program, so it runs in the h9 machine on an Alpine root
# (ALPINE is a tree with jq installed), where the gpuifs tree is /9 followed
# by $gpuifs. jq can't open files, so the shell only wires them up: events
# in, ctl lines out. Everything else is jq, as a reducer: foreach folds each
# event line into the game state and emits the screen for that state.
#
# The screen is drawn again in full on every move: one ctl write deletes
# the nodes and makes them anew, and a ctl write applies all its lines
# together. jq writes only to the root node's ctl, which can't set the
# root's style, so jq also does the layout, placing every node at
# absolute coordinates it works out itself.
#
# The first run, with --arg window 1, prints the window command; the window
# has to exist before the shell can open the root's ctl.

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
def at($x; $y; $w; $h): "absolute left=\($x) top=\($y) w=\($w) h=\($h)";
def cell($i):
  .board[$i] as $v
  | ((.line // []) | index([$i]) != null) as $won
  | (if $v == "X" then "text_color=info" elif $v == "O" then "text_color=danger" else "" end) as $ink
  | (if $won then "bg=success text_color=success_foreground"
     elif $v == null and (.over | not) then "cursor_pointer hover:bg=accent" else "" end) as $look
  | "new text c\($i) text=\(($v // "") | q) tag=c\($i) on=click style="
    + ((at(24 + ($i % 3) * 100; 72 + (($i / 3) | floor) * 100; 92; 92)
        + " flex items_center justify_center rounded_lg border_1 border_color=border text_size=52 font_bold \($ink) \($look)") | q);
def screen:
  [ "new text status text=\(.msg | q) style=\((at(24; 24; 292; 32) + " text_lg font_semibold text_center") | q)",
    (range(9) as $i | cell($i)),
    "new text score text=\("You \(.score.X)   jq \(.score.O)   draws \(.score.draw)" | q) style=\((at(24; 380; 292; 20) + " text_sm text_center text_color=muted_foreground") | q)",
    "new button again label='New game' tag=again style=\((at(110; 412; 120; 32) + " ghost") | q)" ]
  | join("\n") + "\n";
def unscreen: (["status", "c\(range(9))", "score", "again"] | map("delete \(.)\n") | add);

# ---- The reducer ------------------------------------------------------------

def tag: (capture(" tag=(?<t>[^ ]+)") | .t) // null;

if $ARGS.named.window then
  "window main title=Tic-tac-toe size=340,470 resizable=off pos=center\n"
else
  foreach (inputs | select(test("^(resync|click|close|quit) "))) as $ev (
    {score: {X: 0, O: 0, draw: 0}, drawn: false} | newgame;
    if ($ev | startswith("close ") or startswith("quit ")) then .quit = true
    else ($ev | tag) as $t
      | .prev = .drawn | .drawn = true
      | if $t == "again" then newgame
        elif ($t // "") | test("^c[0-8]$") then play($t[1:] | tonumber)
        else . end
    end;
    if .quit then halt
    else (if .prev then unscreen else "" end) + screen end
  )
end
