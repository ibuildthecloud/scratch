# Example captures

Every example in [examples/](..) run for real: gpuifs built in release mode
with GPUI and h9 linked in (Zig 0.16, hyper9 at the pinned submodule), rc and
awk clients running inside an h9 machine on the 9front 11952 amd64 root
(`--root`/`$H9ROOT`, emulated CPU since the container has no KVM), windows on
Xvfb with Mesa's lavapipe as the Vulkan driver, driven with xdotool. GIFs are
recorded without the pointer. Linux rendering only; nothing here says how the
macOS host looks.

[tools/all.sh](tools/all.sh) remakes every capture; `tools/inter.sh calc`
remakes one. Start `Xvfb :99 -screen 0 1440x900x24` first.

## What ran

| Example | Result | Captures |
| --- | --- | --- |
| [rc/counter.rc](../rc/counter.rc) | clicks and the `=` key both count | [counter.png](counter.png), [counter-after.png](counter-after.png), [counter.gif](counter.gif) |
| [rc/confirm.rc](../rc/confirm.rc) | Delete exits 0 | [confirm.png](confirm.png), [confirm.gif](confirm.gif) |
| [rc/hello.rc](../rc/hello.rc) | greets | [hello.png](hello.png), [hello-greeted.png](hello-greeted.png), [hello.gif](hello.gif) |
| [rc/signin.rc](../rc/signin.rc) | field errors, then the Welcome dialog | [signin.png](signin.png), [signin-after.png](signin-after.png), [signin.gif](signin.gif) |
| [rc/todo.rc](../rc/todo.rc) | adds tasks | [todo.png](todo.png), [todo-items.png](todo-items.png), [todo.gif](todo.gif) |
| [rc/calc.rc](../rc/calc.rc) | 12×3=36, +7=43 | [calc.png](calc.png), [calc-result.png](calc-result.png), [calc.gif](calc.gif) |
| [rc/chat.rc](../rc/chat.rc) | Eliza answers | [chat.png](chat.png), [chat-reply.png](chat-reply.png), [chat.gif](chat.gif) |
| [rc/settings.rc](../rc/settings.rc) | four pages, live dark mode | [settings.png](settings.png), [settings-appearance.png](settings-appearance.png), [settings-account.png](settings-account.png), [settings-shortcuts.png](settings-shortcuts.png), [settings-dark.png](settings-dark.png), [settings.gif](settings.gif), [settings-dark.gif](settings-dark.gif) |
| [rc/gallery.rc](../rc/gallery.rc) | stories switch, Dark switch works | [gallery.png](gallery.png), [gallery-input.png](gallery-input.png), [gallery-slider.png](gallery-slider.png), [gallery-table.png](gallery-table.png), [gallery-chart.png](gallery-chart.png), [gallery-dialog.png](gallery-dialog.png), [gallery-dark.png](gallery-dark.png), [gallery.gif](gallery.gif) |
| [rc/files.rc](../rc/files.rc) | tree, table, folder expands | [files.png](files.png), [files-browse.png](files-browse.png), [files.gif](files.gif) |
| [rc/stocks.rc](../rc/stocks.rc) | rows update every second, picked symbol charted | [stocks.png](stocks.png), [stocks-nvda.png](stocks-nvda.png), [stocks.gif](stocks.gif) |
| [rc/dock.rc](../rc/dock.rc) | panels, file tree, Ctrl-Shift-P palette | [dock.png](dock.png), [dock-palette.png](dock-palette.png), [dock.gif](dock.gif) |
| [rc/notes.rc](../rc/notes.rc) | Ctrl-N makes a note, the editor takes markdown | [notes.png](notes.png), [notes-new.png](notes-new.png), [notes.gif](notes.gif) |
| [rc/paint.rc](../rc/paint.rc) | strokes in three colors | [paint.png](paint.png), [paint-drawn.png](paint-drawn.png), [paint.gif](paint.gif) |
| [go/greet](../go/greet/main.go) | `GOOS=plan9` binary in h9 | [go-greet.png](go-greet.png), [go-greet-done.png](go-greet-done.png), [go-greet.gif](go-greet.gif) |
| [go/clock](../go/clock/main.go) | ticks | [go-clock.png](go-clock.png), [go-clock.gif](go-clock.gif) |
| [c/life.c](../c/life.c) | built with 9front's `mk`/6c inside h9, run there | [c-life-running.png](c-life-running.png), [c-life.gif](c-life.gif) |
| [awk/csvview.awk](../awk/csvview.awk) | table with sorting | [awk-csvview.png](awk-csvview.png) |
| [python/hn.py](../python/hn.py) | not run: the capture sandbox blocks the HN API host, and its kernel has no 9p filesystem to mount `gpuifs -a` for a host-side Python | — |
| [sh/progress.sh](../sh/progress.sh) | not run: needs plan9port's `9p` | — |

## Fixed while capturing

- **Layouts.** `h_flex` carries GPUI Kit's `items_center`, so the two-pane
  roots of settings, gallery and notes centered their panes instead of
  filling the window (notes collapsed to a strip), and stocks' chart had no
  height. Those rows now say `items_stretch`, as do DESIGN.md's two
  sidebar-and-page snippets.
- **Icons.** The host registered GPUI Kit's default icon bundle, which only
  holds the icons its own components use; it now registers `AllAssets`, the
  whole Lucide set, so `send`, `trash`, `keyboard` and the rest draw.
- **Sidebar width.** A sidebar's `w=` sized only the box around GPUI Kit's
  Sidebar, which drew at its own 255px over the page beside it. The width
  now reaches the Sidebar.
- **`cmd-` keys off macOS.** GPUI reads `cmd` as Super on Linux and
  Windows, so every `cmd-` binding was out of reach there. The host now
  binds `cmd` as GPUI's `secondary` (Cmd on macOS, Ctrl elsewhere).
- **paint.rc.** Plan 9 rc adds no free caret after a subscript, so
  `'M'$last(1)','$last(2)` was two words and every stroke was refused; and
  "Blue" was the `primary` token, near-black in the default theme. It is
  `info` now.
- **csvview.awk.** Numeric columns were 100px whatever their header; they
  now widen to fit it.

## Still open

- The stocks chart's line looks nearly flat, likely because its y axis
  starts at zero, so a few dollars on a price of 140 barely moves it (not
  checked).
- Times inside h9 follow the 9front root's `/adm/timezone/local` (CET on
  the release ISO), not the host's zone.
- In the release profile, `host`'s `every_table_word_resolves` test fails
  on `debug`/`debug_below`, which GPUI only has in debug builds.
