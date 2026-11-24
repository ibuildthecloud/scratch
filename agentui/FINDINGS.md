# Findings: building agentui on uitree over a 9p mount

What was awkward, broken or missing while building `agentui` (a sidebar of
agent sessions and a fake terminal pane) on uitree. The app is a directory
run by `uitree/proto/appdir/appdir`. The runner loads `tree`, runs
`handlers/` scripts on events, and saves `tree` back.

There were two runners. The first ran on Linux: the GPUI host's
`UITREE_HOST_APP` handed it `$ui`, and it mounted that with Linux's
kernel 9p client (`mount -t 9p … version=9p2000.L`) and ran handlers as
Linux programs. It has since been removed. `appdir` now starts the
runner (`runner.rc`) and its handlers inside h9 (Part 2, item 10). Items
that only applied to the Linux runner say so.

Part 1 is about uitree itself (spec, core, GPUI host). Part 2 is about the
layer above it: the `appdir` runner and agentui. Each item says what we
hit, how we got around it, and what would fix it.

---

## Part 1: uitree

### 1. A `ctl` write split into pieces breaks here-values (bug)

`core.md` says a `ctl` written in several 9P writes applies when the file
is closed. The server applies each write as it arrives instead,
committing every complete line and holding only a partial last line
(`core/src/ninep/server.zig`, `workNow`, the `.ctl` write mode). A
multi-line value (`set term text=<<END … END`) whose body is split at a
line boundary is parsed in pieces, and the first piece fails with
`bad syntax: line 3: no END line ends the value`. Lines before it in the
same write still apply, so the update is half done.

- **Hit by:** a handler printing about 4 KB of ctl (a terminal screen as a
  here-value). bash's `printf` wrote it in more than one `write()`.
- **Workaround:** the runner sends handler output with one `cat`, which is
  one `write()` up to the mount's msize. Bigger outputs will still split.
- **Fix:** hold lines while a here-value is open (apply at its terminator
  or at clunk), or apply the whole `ctl` at close as the spec says.

### 2. Errors are invisible through a Linux mount

- **Writes that apply at close always "succeed".** `tree` (and other
  `at_close` files) commit on clunk, and Linux drops errors from close.
  `cat bad-tree > $win/tree` exits 0, and the error appears only on
  `$ui/trace`.
- **Errors that do come back lose their text.** A refused write shows as
  `unknown error 526` (the kernel's errno for an error string it can't
  map), not as `bad value: on: bogus` or `unknown style word: X`.
- **Hit by:** a tree with a bad style word. The window never appeared and
  nothing said why, until we read `trace`. Worse, our runner took the
  silence as success (Part 2, item 1).
- **Not only Linux.** Inside h9, `cat bad-tree > $ui/win/main/tree` also
  ends with an empty (successful) status. So the close-time half is
  uitree's own: an `at_close` file has no way to return its error to the
  writer. The lost error text, though, is Linux's alone: in h9 a refused
  `ctl` write prints `write error: not found: nosuch`.
- **Fix ideas:** map the protocol's error phrases to errnos under
  9P2000.L (`EINVAL` for `bad value`, `ENOENT` for `not found`, …); give
  each node or window a readable `error` file holding the last error; or
  apply `tree` writes per write, as `ctl` does, so the error reaches the
  writer.

### 3. Stream files don't work with Linux's 9p client as plain files

`events` and `trace` block until there is more to read. Linux's v9fs
(through netfs) keeps issuing reads until it has filled the caller's
buffer (`cat` asks for 1 MiB) or reads 0 bytes, so `cat events` shows
nothing at all, not even the `resync` line. The reader sits in
`p9_client_rpc` until it's killed.

- **Workaround:** read one byte at a time:
  `dd if=events bs=1 status=none | while read …`. That is one 9P round
  trip per byte.
- **Linux only.** Inside h9, `read < $ui/events` returns the `resync`
  line at once. This is a problem for Linux mounts, not a uitree bug.
- **Fix ideas:** document it for Linux mounts; check whether a mount
  option or open flag (`O_DIRECT`, a different `cache=`) makes v9fs return
  short reads; or have the host offer a line-oriented socket for events
  next to the file.

### 4. Style words can't hold a space, and there's no generic font name

The style parser splits on whitespace with no quoting
(`core/src/proto/style.zig`, `parseDiag`), so
`font-family='DejaVu Sans Mono'` fails with `unknown style word: Sans`.
The GPUI host passes the name to GPUI as is, and GPUI doesn't resolve
`monospace`, so that falls back to a proportional font.

- **Workaround:** installed `fonts-hack` for a one-word family (`Hack`).
- **Fix:** quoting in style words (the tokenizer `ctl` uses already has
  it), or a convention such as `font-family=DejaVu_Sans_Mono`, plus the
  generic families `monospace`, `sans-serif` and `serif` in the host.

### 5. `set PATH : style…` replaces every style word

There is no way to add or remove one style word. Changing one thing
means restating the whole list, so every live tweak needs the node's
current style first. The `collapse` handler restates the footer's full
style in each direction for the same reason.

- **Fix:** an additive form, for example `set PATH :+ w=300` and
  `set PATH :- hidden`, or `style add` / `style remove` verbs.

### 6. No terminal component in the GPUI host

`console` is in the spec's `desktop` profile, which the GPUI host doesn't
claim or implement. agentui fakes a terminal with `styled-text`: a
monospace font, color ranges in `runs`, and a screen we lay out
ourselves. The real need is an embedded terminal (like Ghostty) that
renders a TUI such as Claude Code and takes input.

- **Fix:** a terminal type: a PTY or VT byte stream in, a cell grid out,
  key input, resize. It could start as a host extra (`x.terminal`).

### 7. `styled-text` runs are byte offsets

`runs` lines are `START LEN words…`, counted in UTF-8 bytes of `text`.
Box drawing, `●`, `⎿` and `✻` are multi-byte, so every client needs byte
arithmetic (agentui's `bin/render` does it in Python, on the host). A run that overlaps another is
silently dropped, and so is one that doesn't fall on a character
boundary.

- **Fix:** consider character (or grapheme) offsets, or inline markup,
  and report dropped runs on `trace`.

### 8. Components drawn by GPUI Kit report no `bounds`

`sidebar-item` reads `0 0 0 0` in `bounds`, while raw elements report
real numbers. Anything that needs a node's position (tests, automation,
popovers anchored by a client) can't get it for those components.
Scripted clicks had to use positions measured from screenshots.

### 9. The GPUI host can't serve `$ui` to outside clients alongside an app

`uitree-headless -a ADDR` listens for outside clients next to the app in
h9. The GPUI `uitree` binary has no `-a`. Its only external endpoint is
`UITREE_HOST_APP`, which *replaces* the app in h9 with a command on the
host. So you can't run a normal app in a window and also mount its tree
to inspect or edit it.

- **Fix:** `uitree -a ADDR`, as headless has. Done on branch
  `gpui-listen` (about 30 lines in `renderer/gpui`; the core already
  supported it through `uit_listen`). See Part 2, item 11.

### 10. State outside the window tree has no home

`win/main/tree` is a good document of one window, but the theme
(`$ui/theme/mode`), key bindings, menus, assets and other windows aren't
in it. There's no single app document to save and restore. uitree also
can't store arbitrary data: a node directory refuses extra files, a
`set` with an unknown prop fails, and only `asset/` takes arbitrary
bytes. Everything is lost when the host quits.

- **Workaround:** the runner's `ui/` overlay (files written into `$ui` at
  start, never saved back).
- **Fix ideas:** an app-level document (`$ui/tree` covering windows,
  theme, keys and menus), and a per-app storage area.

### 11. A tree that fails to load shows no window

When the first `tree` write failed, the GPUI host never showed a window
at all. The process ran with no window and no error on screen. A window
with an error message (or the previous tree) would make the failure
visible.

### 12. Smaller things

- **The window's tree file leaves out window settings.** `title`, `size`
  and `pos` aren't in `win/main/tree`, so the runner keeps a separate
  `window` file.
- **Saved trees drop props equal to their default.** `collapsible=icon`
  disappeared from `tree` after we set it. That's correct, but surprising
  when you're reading the diff after an edit.
- **`trace` replays everything since the host started before streaming.**
  It's useful for debugging, but a watcher has to skip or tolerate the
  history, and it grows for the life of the host.
- **Files on the mount show no owner or time.** Owner is `4294967294`
  and timestamps are 1970.
- **`on=click,hover` is stored as the literal text `click,hover`.** Open
  question 8 in `core.md` asks about the list form; the quoted form
  (`on='click hover'`) works.
- **`bounds` is in logical points** and the window here runs at 2×. A
  client converting to screen pixels has to work out the scale from
  window sizes; it isn't in the window's files.

---

## Part 2: our layer (appdir runner and agentui)

### 1. The runner overwrote `tree` after a failed load (fixed)

A tree with one bad style word didn't load. The window's tree stayed
empty, and the save loop wrote that empty tree (`div root`) over the
file. This happened twice. Because of Part 1, item 2, the write's exit
status can't detect it.

- **Fix in place:** the runner reads `trace` for
  `error path=win/main/tree` right after loading, and won't save at all
  if it finds one. Tested with a bad tree: the file is left alone.
- **Still fragile:** it waits a fixed 300 ms for the error to appear on
  `trace`.

### 2. Design and runtime state are mixed in one file

`tree` holds the structure and styling we write, and also the selected
session, the collapsed flag, an input's typed value and the whole
terminal screen text. A diff of `tree` mixes "I changed the header" with
"someone clicked Docs search". This is the main tension in the model.
Editing the file and reloading has the same problem from the other side:
a reload loses runtime state unless that state is in the file.

- **Direction:** split them. One design document (edited by hand or saved
  from live edits) and a separate state file the runtime owns, merged at
  load.

### 3. Saving only goes one way

Editing `tree` in an editor while the app runs gets overwritten at the
next save, because the runner never reloads from disk. Generators go
stale the same way: `bin/mktree` builds the original light sidebar, and
running it now would throw away every live edit.

- **Direction:** watch the file and reload on change, which needs item 2
  first so reloads don't lose state. Then retire generators, or make them
  produce only the first version of a file.

### 4. Handler paths are tied to the tree's structure

Handlers live at the node's path (`handlers/row/inc/click`). Our first
counter put them at `handlers/inc/` and clicks silently did nothing,
because the node is `row/inc`. Wrapping a node in a new `div` will
disconnect its handlers the same way. Bubbling helps, since agentui's one
`handlers/nav/click` catches every sidebar item, but that handler then
has to filter out paths that aren't sessions (`nav/footer/*`).

- **Direction:** also look handlers up by `tag`, the routing word
  uitree already provides, which survives restructuring.

### 5. One source of truth for UI state

`bin/show` first cleared only the item named in a `current` file. After
some failed runs `current` disagreed with the tree, and two sidebar items
showed as active. It now clears every item. Any state kept both in a
file and in the tree will drift.

### 6. What the runner covers

- Only `win/main`. Key and menu `action` events reach only a root-level
  `handlers/action`, and their key is ignored.
- Plain `div` and `text` nodes need `on=click` in the tree. The runner
  could set `on` from which handler files exist.
- Each event starts a new process, and handlers run one at a time.
  That's fine for clicks and too slow for `hover` or `move`.
- The `ui/` overlay loads at start and is never saved back.

### 7. The Linux mount needed root and left stale mounts (gone with item 10)

The first, Linux-mount runner needed the 9p kernel module,
passwordless `sudo` for `mount`, and a mount point at `/mnt/uitree/NAME`.
If the runner is killed hard, the mount stays behind and needs
`umount -l`. A FUSE 9p client would avoid `sudo`. plan9port's `9pfuse`
was tried and its build failed here. Debian's `9mount` (a small setuid
helper for the same kernel module) is what we use now: it mounts on a
directory the user owns, with no `sudo` (item 11).

### 8. The fake terminal

- **Fallback fonts break column alignment.** `✻` and `⎿` aren't in
  Hack, so they come from DejaVu and Symbola at different widths, and box
  borders next to them shift.
- **No nesting in the markup.** `bin/show`'s `{style|text}` markup
  doesn't nest; `{sel|{c|❯} …}` drew the raw braces.
- **The terminal text is saved in `tree`.** The whole screen lands in
  `tree` on every switch (see item 2).

### 9. How we used the mount

- **Behavior went through 9p:** handlers, session switching, collapse,
  and reading `trace`, `events` and `bounds` while debugging.
- **The second round of UI changes was entirely live:** dark theme,
  sidebar header and footer, status icons and the collapse toggle, all
  written through the mount and saved by the runner. A plain restart
  brought everything back.
- **The first round went through the file and restarts:** the original
  tree and the font changes. That was partly forced (a tree that wouldn't
  load, a newly installed font, changes to the runner itself) and partly
  habit.

### 10. Running the layer inside h9

`appdir DIR` copies `runner.rc` into `DIR/.appdir/` and starts
`uitree rc .appdir/runner.rc` from `DIR`. The runner and every handler
then run in the h9 machine, where `$ui` is mounted natively. This needed
no uitree change: the GPUI binary already runs a program in h9 in the
current directory, which h9 maps read-write at `/mnt/term/cwd`.

Gained:
- Plain `read` on `events`.
- Error text on refused `ctl` writes.
- No `sudo`, no host mount and nothing stale after a crash.
- The app is sandboxed.

Lost, until item 11: the live tree was only in the machine, so there
were no files on the host to develop with, which was the point of the
whole exercise.

Costs and quirks:
- **Only the app directory is visible.** The runner has to be copied in,
  and handlers can't reach other host paths. `uitree-headless` has
  `-d SRC:DST` for more; the GPUI binary doesn't.
- **Handlers are Plan 9 programs** (`rc`, `awk`, `sed`, `grep`). There's
  no Python, so agentui's markup step became a host-side dev tool
  (`bin/render`, run after editing a screen), and `bin/show` is now `rc`
  that sends the pre-rendered `screen.text` and `screen.runs`.
- **Plan 9 awk counts characters, not bytes,** which is why `runs` (Part
  1, item 7) can't easily be computed in h9.
- **rc quirks.** Plan 9 `sed` ends its output with a newline, and
  backquotes that don't split (`` `''{} ``) keep it, so `$ev_value` was
  "on" plus a newline until the runner split it with `` `{} ``. rc also
  needs `=` quoted inside arguments.
- **No inotify.** The runner saves by checking the tree once a second
  instead of watching `trace`. Reloading when `tree` changes on disk
  would need the same kind of polling.
- **Plan 9 `cat` writes 8 KB at a time,** so a handler printing more than
  8 KB of `ctl` will hit Part 1, item 1.
- **A real terminal can't run in there.** A PTY driving a VT emulator
  needs Linux programs, so a real terminal pane would need a host-side
  helper or a terminal type in uitree.

### 11. The live tree as files on the host again

`uitree -a ADDR` (branch `gpui-listen`) serves the app's `$ui` on a
socket next to the app in h9. `appdir` now starts uitree with
`-a unix!/tmp/appdir-UID-NAME.sock`, mounts that socket with `9mount` at
`~/uitree/NAME` as the user, and unmounts when the window closes.

The result is the model we wanted:
- **Develop with files.** `cat ~/uitree/NAME/win/main/tree`,
  `echo 'set …' > …/ctl` and so on, from any host tool.
- **The runner saves `DIR/tree` within a second of any change,** whoever
  made it: you, a handler or a user clicking.
- **Handlers still run sandboxed in h9.**

Host-side reads and writes go through Linux's 9p client, so Part 1,
items 2 and 3 apply to them: `events` needs `dd bs=1`, and refused writes
show `unknown error 526`. `trace` shows the real error text.

## Part 3: developing a feature live (the profile menu and settings)

We added a profile row to the sidebar footer (avatar, name, plan), a
menu that opens from it, and a settings dialog (display name, email,
theme, terminal font size, notifications). Everything was done through
`~/uitree/agentui`: `cat` and `echo` on `ctl`, documents written to
`tree` files, an image written to `asset/`, and `rc` handlers saved in
`agentui/handlers/`. There were no restarts until the end, when one
restart checked that it all comes back.

**What felt good**
- Each step showed up in the window at once. An avatar, a menu and a
  dialog took one `ctl` write or one `tree` write each.
- **Reading a node's `tree`, editing it and writing it back** was the
  natural way to rework the menu. It's the file-based dev loop at its
  best.
- **Overwriting `asset/pfp`** redrew the avatar with no other change.
- **Handlers are picked up on every event.** The `tr` bug below was fixed
  by editing the file, and the next keystroke used the fix.
- **Form components report real `bounds`,** so finding a field's
  position was a `cat`.

**uitree**
1. **The window's tree doesn't include its overlays, and `over/tree`
   doesn't round-trip.** Popovers and dialogs live under `over/`, and
   `win/main/tree` leaves them out, so a restart silently lost the whole
   menu and dialog. `over/tree` reads back as one root per overlay, but a
   write with more than one root fails (`bad syntax: line 16: more than
   one root`). What a file returns when read should be accepted when
   written back.
2. **Verbs and edits travel by different routes.** A handler's stdout
   goes to the window's `ctl`, which takes `set`, `new`, `delete` and
   `tree`. Opening or closing an overlay is a verb on *that node's* `ctl`
   (`echo open > $win/over/settings/ctl`), so handlers write to two
   places. A window `ctl` form such as `open over/settings` would keep one
   channel.
3. **Replacing a popover's `tree` closes it,** because the node is
   recreated. Live editing of an open overlay means reopening it after
   every edit.
4. **An unknown icon name draws nothing and reports nothing.**
   `icon=circle-help` (the set has `circle-question-mark`) just left a
   gap. `trace` should report it, or the descriptor should list valid
   names.
5. **`justify-start` on a `button` doesn't move its contents.** Labels
   stayed centered, so the menu was rebuilt from `div` rows.
6. **`bounds` is inconsistent across components:** real for `input`,
   `select` and `dialog`; `0 0 0 0` for `sidebar-item` (Part 1, item 8).

**Our layer**
1. **Overlays needed their own saved document.** The runner now saves
   `win/main/over/tree` to `DIR/overlays`. Because of uitree item 1, it
   splits the file on load and recreates each overlay with `new` before
   writing its `tree`. It has to skip here-value bodies (`items=<<END`),
   whose lines aren't indented. The first version wrote the file whole,
   failed to load, and the load-failure guard kept both files safe.
2. **State outside the tree needs a second copy by hand.** The avatar
   image went to `asset/pfp` *and* `ui/asset/pfp`; the theme handler
   writes `$ui/theme/mode` *and* `ui/theme/mode`. The `ui/` overlay
   loads at start and is never saved back, so it's easy to forget one.
3. **Plan 9 tools differ in small ways.** `tr -d '\n'` deletes the
   letter `n` (Plan 9 `tr` has no `\n`), which turned "Darren S." into
   "Darre S.". `awk` is the safe way to read the first line of a value.
4. **Design and state are still mixed.** The dialog's current values
   (name, theme, font size) are saved in `overlays`, next to its layout
   (Part 2, item 2).
5. **Changing the runner needs a restart,** and a restart is where
   anything the runner doesn't save gets lost. Part 2, item 3 (save
   history) would have made that cheaper.
6. **Test-harness noise, not uitree:** X keyboard focus moved to the
   desktop partway through, so scripted typing went nowhere. Scripted
   clicks also need the window's 2× scale applied to `bounds`.

## What worked well

- Mounting `$ui` and using plain shell (`echo`, `cat`, a `while read`
  loop) as the whole app runtime.
- Handlers that print `ctl` lines to stdout: small, easy to test by
  running them by hand (`bin/show appdir`), and picked up again on every
  event.
- Bubbling handlers by path: one handler covers a whole sidebar.
- `trace` as the one place that shows every write and every error from
  every client.
- Live edits show up in under a frame, and the saved `tree` reads like
  hand-written source.
