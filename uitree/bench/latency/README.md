# Counter-click latency

How long a click on the counter's `+` takes to show up, in seven setups:

| # | Renderer | App |
| --- | --- | --- |
| 1 | native GPUI, no uitree (`renderer/gpui/crates/host/examples/native_counter.rs`) | in process |
| 2 | uitree's GPUI renderer (C ABI) | Go, on the host, 9P over a unix socket (`counter-go`) |
| 3 | uitree's GPUI renderer | the same Go, `GOOS=plan9` in h9 |
| 4 | uitree's GPUI renderer | `counter.rc` in h9 |
| 5 | 9P renderer (`renderer/toy-py`, Python) via `uitree-remote` | Go on the host |
| 6 | 9P renderer | Go in h9 |
| 7 | 9P renderer | `counter.rc` in h9 |

`./run.sh [N]` builds everything and runs them all (`ONLY='1 4'` for some).

Every row starts the clock where the click handler runs, after
hit-testing, so all of them skip the same OS and hit-test step. Rows 1 to 4
report three points: **state** (the new number is in the renderer's
hands), **render** (the window's render starts) and **frame** (the next
frame begins, so the rendered one has gone to the display). Rows 5 to 7
report click to new text applied in the Python renderer, which draws no
pixels; compare them with the state column, and add rows 1 to 4's
state-to-frame gap for a drawing 9P renderer.

Go on Apple silicon runs under h9's amd64 emulator (Go has no
plan9/arm64), so row 3 and row 6 pay for emulation; rows 2 and 5 don't.
