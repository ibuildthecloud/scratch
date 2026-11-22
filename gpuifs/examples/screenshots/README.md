# Example captures

Every example in [examples/](..) run for real: gpuifs built in release mode
with GPUI and h9 linked in (Zig 0.16, hyper9 at the pinned submodule), rc and
awk clients running inside an h9 machine on the 9front 11952 amd64 root
(`--root`/`$H9ROOT`, emulated CPU since the container has no KVM), windows on
Xvfb with Mesa's lavapipe as the Vulkan driver, driven with xdotool. Linux
rendering only; nothing here says how the macOS host looks.

[tools/](tools) has the scripts that made them (`tools/inter.sh calc` and so on).

## What ran

| Example | Result | Captures |
| --- | --- | --- |
| rc/counter.rc | works: clicks and the `=` key both count | [counter.png](counter.png), [counter-after.png](counter-after.png), [counter.gif](counter.gif) |
| rc/confirm.rc | works: Delete exits 0 | [confirm.png](confirm.png), [confirm.gif](confirm.gif) |
| rc/hello.rc | works | [hello.png](hello.png), [hello-greeted.png](hello-greeted.png), [hello.gif](hello.gif) |
| rc/signin.rc | works: field errors, then the Welcome dialog | [signin.png](signin.png), [signin-after.png](signin-after.png), [signin.gif](signin.gif) |
| rc/todo.rc | works | [todo.png](todo.png), [todo-items.png](todo-items.png), [todo.gif](todo.gif) |
| rc/calc.rc | works: 12×3=36, +7=43 | [calc.png](calc.png), [calc-result.png](calc-result.png), [calc.gif](calc.gif) |
| rc/chat.rc | works, but the send and clear icons are blank (1) | [chat.png](chat.png), [chat-reply.png](chat-reply.png), [chat.gif](chat.gif) |
| rc/settings.rc | works, live dark mode too; pages sit too low (2) | [settings.png](settings.png), [settings-appearance.png](settings-appearance.png), [settings-account.png](settings-account.png), [settings-shortcuts.png](settings-shortcuts.png), [settings-dark.png](settings-dark.png), [settings.gif](settings.gif), [settings-dark.gif](settings-dark.gif) |
| rc/gallery.rc | works; stories sit too low (2) | [gallery.png](gallery.png), [gallery-input.png](gallery-input.png), [gallery-slider.png](gallery-slider.png), [gallery-table.png](gallery-table.png), [gallery-chart.png](gallery-chart.png), [gallery-dialog.png](gallery-dialog.png), [gallery.gif](gallery.gif) |
| rc/files.rc | works: tree, table, folder expands | [files.png](files.png), [files-browse.png](files-browse.png), [files.gif](files.gif) |
| rc/stocks.rc | table updates every second; the chart is a flat line (4) | [stocks.png](stocks.png), [stocks-nvda.png](stocks-nvda.png), [stocks.gif](stocks.gif) |
| rc/dock.rc | dock, panels and file tree render; Ctrl-Shift-P didn't open the palette (6) | [dock.png](dock.png), [dock-palette.png](dock-palette.png) |
| rc/notes.rc | **broken layout**: the app collapses to a strip in the middle (2) | [notes.png](notes.png) |
| rc/paint.rc | works after a one-line fix to the example (3) | [paint.png](paint.png), [paint-drawn.png](paint-drawn.png), [paint.gif](paint.gif) |
| go/greet | works (`GOOS=plan9` binary in h9) | [go-greet.png](go-greet.png), [go-greet-done.png](go-greet-done.png), [go-greet.gif](go-greet.gif) |
| go/clock | works | [go-clock.png](go-clock.png), [go-clock.gif](go-clock.gif) |
| c/life.c | works: built with 9front's `mk`/6c inside h9, then run there | [c-life-running.png](c-life-running.png), [c-life.gif](c-life.gif) |
| awk/csvview.awk | works; one header clipped (5) | [awk-csvview.png](awk-csvview.png) |
| python/hn.py | not run: this sandbox blocks the HN API host, and the kernel has no 9p filesystem to mount `gpuifs -a` for a host-side Python | — |
| sh/progress.sh | not run: needs plan9port's `9p`, which isn't installed here | — |

## Problems found

1. **Icons missing.** `crates/host/src/runtime.rs:328` registers
   `gpui_kit::assets::Assets`, GPUI Kit's default bundle, which only holds
   the icons its own components use. Icons a client names that aren't in it
   draw nothing: `send` and `trash` in chat, `trash` on the notes Delete
   button, the Shortcuts page icon in settings. `AllAssets` has the whole
   Lucide set.
2. **`h_flex` centers children vertically.** DESIGN.md says `h_flex` is GPUI
   Kit's, with `items_center`. So in `div root style='h_flex size_full'`, a
   child that doesn't set its own height is centered rather than stretched.
   settings.rc and gallery.rc show their pages lower than they should;
   notes.rc (and DESIGN.md § A complete client, which it copies) collapses
   completely. Either the examples add `h_full`/`items_start`, or the style
   table gets a stretch default, a DESIGN decision.
3. **paint.rc drew nothing** (fixed on this branch). Plan 9 rc puts no free
   caret after a subscript, so `'M'$last(1)','$last(2)` became two words and
   gpuifs rejected `M100.0` as a path segment. Explicit carets fix it.
4. **stocks chart is flat.** The line chart for the picked symbol draws a
   straight line across the middle even as the price moves.
5. **csvview:** the right-aligned "Mass (Earth=1)" header is clipped at its
   left edge.
6. **dock:** Ctrl-Shift-P didn't open the command palette under Xvfb. Not
   looked into; it may be how `cmd-` maps to Ctrl on Linux.
7. **Guest clock:** times inside h9 (chat stamps, clock, file dates) are an
   hour ahead of the host's UTC, so the guest isn't using the host's zone.
