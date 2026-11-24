# appdir

A prototype for building a uitree app as a directory of files, and for
developing it by reading and writing files. While the app runs, its live
`$ui` is mounted on the host at `~/uitree/NAME`. Change it with `cat` and
`echo`, and whatever the window ends up showing is saved back into the
directory.

- The window is the GPUI renderer (`renderer/gpui`).
- The app's runner (`runner.rc`) and its event handlers run inside h9, in
  Plan 9 (`rc`, `awk`, `sed`, `grep`).
- `uitree -a` serves the same `$ui` on a unix socket, and `9mount` mounts
  it on the host as you, without `sudo`.

What was awkward along the way, in uitree and in this layer, is in
[FINDINGS.md](FINDINGS.md).

## Running it

```sh
DISPLAY=:0 uitree/proto/appdir/appdir uitree/proto/appdir/examples/agentui
```

The window opens, and `appdir: live $ui at ~/uitree/agentui` says where
the live tree is. Closing the window stops the app and unmounts.

### Requirements

- **The GPUI binary with `-a`** (`cargo build --release -p uitree` in
  `renderer/gpui`). `$UITREE` names another binary.
- **A 9front root with `rc`**, as for the rest of uitree: `$H9ROOT`, by
  default hyper9's isoroot in this checkout
  (`third_party/hyper9/.local/9front/root-amd64`; see `uitree/README.md`
  for how to build it).
- **Linux's 9p module** (`modprobe 9p`) and **`9mount`** (Debian/Ubuntu:
  `apt install 9mount`, a small setuid helper) for the host mount. Without
  them the app still runs; it just isn't mounted.
- A display. GPUI needs Vulkan; with no GPU, install Mesa's lavapipe
  (`mesa-vulkan-drivers`).

`$APPDIR_MNT` changes the mountpoint (default `~/uitree/NAME`).

## Developing live

```sh
cd ~/uitree/agentui/win/main
cat tree                                   # the window as a document
echo "set nav/header/t text='Sessions'" > ctl
cat nav/header/t/text
cat over/settings/tree > /tmp/s; $EDITOR /tmp/s; cat /tmp/s > over/settings/tree
cat ~/pic.png > ~/uitree/agentui/asset/pfp
```

The runner saves `tree` and `overlays` back into the app directory within
a second of any change, whoever made it: you, a handler or someone using
the window. Handlers are looked up again on every event, so editing one
takes effect on the next click.

From the host, `events` and `trace` stream forever. Linux's 9p client
only returns a read once its buffer is full, so read them one byte at a
time (`dd if=trace bs=1 status=none`). A refused write shows as
`unknown error 526` on the host; `trace` has the real message.

## The app directory

```
tree        the main window's nodes, as a uitree document
overlays    its popovers, dialogs and sheets (win/main/over/tree)
window      ctl lines for the window at start (title, size)
ui/...      files written to the same path under $ui at start
            (ui/theme/mode, ui/asset/NAME); not saved back
handlers/   handlers/PATH/EVENT: what runs on an event
.appdir.log the runner's log (ignored by git)
.appdir/    the runner's working files (ignored by git)
```

Anything else in the directory is the app's own state. Handlers run with
the directory as their current directory, so they can read and write it.
They can't see anything outside it: h9 maps in only the directory it
starts in.

If `tree` or `overlays` fails to load (a typo in a style word, say), the
error goes to `.appdir.log` and the runner saves nothing, so the files
are left as they were.

## Handlers

An event on the node at `PATH` runs the nearest of
`handlers/PATH/EVENT`, then the same for each parent path, up to
`handlers/EVENT`. So `handlers/nav/click` catches clicks anywhere in the
sidebar.

A handler is an executable, usually an `rc` script, run as
`handler EVENT KEY PATH`:

- **stdin** is the event line (`click save nav/footer/new win=main …`).
- **Environment:** `$ui`, `$win` (`$ui/win/main`), `$node` (`$win/PATH`),
  and each attribute of the event as `$ev_NAME` (`$ev_value`, `$ev_x`).
- **stdout** is written to the window's `ctl` in one write
  (`set`, `new`, `delete`, `tree`).
- **Verbs** such as `open` and `close` go to the node's own `ctl`:
  `echo open >$win/over/settings/ctl`.
- **stderr** goes to `.appdir.log`.

Handlers run one at a time, in event order. A plain `div` or `text` only
sends an event that its `on` lists (`on=click`); components such as
`button` and `input` send theirs on their own.

## Examples

- **[examples/counter](examples/counter):** the smallest app: +, − and
  Reset handlers, a history file and a note field.
- **[examples/agentui](examples/agentui):** an agent-sessions app
  (sessions grouped by project in a sidebar, a fake terminal pane, a
  collapsible sidebar, a profile menu and a settings dialog). Its
  terminal screens are written in a small markup in
  `sessions/*/screen`; after editing one, run `bin/render` on the host to
  turn it into `screen.text` and `screen.runs`.
