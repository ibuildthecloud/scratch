# uitreefs: GPUI Kit as files

Nov 22, 2026 · @Jeff Lindsay · Draft v0.2

## Summary

uitreefs is a GPUI Kit host that serves a writable 9P file tree. A client program builds and runs a native GPUI application by reading and writing files in that tree. It needs no Rust, no bindings and no library.

GPUI elements are values that are rebuilt every frame. A client cannot hold one. GPUI Kit's own `gpui-shell` hit the same wall and solved it with a retained *description* that Rust replays into fresh elements on every frame ([gpui-shell.md §8](https://github.com/longbridge/gpui-kit/blob/main/docs/gpui-shell.md)). uitreefs makes that description a file tree. Every node is a directory, the host's one root view walks the tree in `render`, and a write marks the tree dirty and calls `cx.notify()`. GPUI already rebuilds everything, so no reconciler is needed.

The rest is lessons from earlier filesystem GUI work ([docs/uxkit.md](https://github.com/progrium/9ux/pull/23)), Inferno Tk, and the 24 example clients written against the first version of this protocol (gpuifs, v0.1):

- A text protocol over 9P, with one quoting rule. Common lines (style words, booleans, data rows) need no quotes at all.
- Every event starts with the same three words, `name key path`, so a client branches on a word position, never on a search.
- Any `ctl` can create, set and delete by path, so a client that can open only one file can still do everything.
- One path per node. The path in an event is the path you write to, and the path `focus` takes.
- Fast interaction (typing, scrolling, resizing, dock drags) stays in the host. The client sees only semantic events.
- Action events are never dropped. State events are coalesced.
- A canvas is the escape hatch for custom drawing.
- Defaults a script would have written anyway: a `main` window exists from the start, closing the last window quits, and failed writes are loud.

```rc
uitreefs -t Greeter ./greet      # run ./greet in an h9 machine with the tree at $ui (/mnt/ui)
```

uitreefs is the file-protocol host only. The wider `uitree` toolchain (a launcher, client helpers per language, `.ui` documents as a format of their own) is a separate effort that this protocol is kept aligned with: the mount is `$ui`, and errors are reported as `uitree: ...`.

## Goals and non-goals

**Goals**

1. Any language that can do file I/O over 9P can build a GPUI Kit application.
2. Two tiers, both first-class: GPUI's raw elements (`div`, `text`, `img`, `svg`) with its full style vocabulary, and the styled `gpui-component` catalog.
3. Anything that happens many times a second runs in the host. The client stays out of the frame loop, except on a canvas.
4. No event that the client must act on is ever lost.
5. The tree is the whole truth. `cat` shows what is on screen, and a `trace` file logs every change.
6. Names, style words and component options follow GPUI Kit's Rust spelling, so its docs carry over.
7. A client in rc, awk, sed, jq or COBOL needs no parser: words at fixed positions, and a `ctl` line for every change.

**Non-goals**

- Host mounting. uitreefs speaks 9P2000 on a socket or a pipe. The standard client runs in an embedded h9 machine that mounts the tree itself. A host-side client attaching to `-a addr` brings its own 9P library or mount.
- Script callbacks. There is no expression language and no code inside the tree. Logic stays in the client, as in Inferno Tk, but the host carries enough built-in behavior that common UI needs no round trip.
- Exposing every Rust type. Components whose interface is closures over Rust data (custom `TableDelegate`s, render callbacks) are reached through a file-shaped model instead.
- A second wire format. There is no JSON form of events, `ctl` or documents. After the fixed head, a line is `line.split()` in Python or Node; a per-language helper can hand out objects without a second format.
- Remote display performance. A remote client works over any 9P transport, but this design does not tune for it.

## Why a file server

| Option | For | Against |
| --- | --- | --- |
| **Bindings per language** (Go, Python, ... over GPUI's Rust API) | Native speed, no extra hop | One binding per language, each chasing GPUI's API, which changes often. Closures, lifetimes and the per-frame rebuild don't map cleanly to most languages |
| **gpui-shell's JavaScript** | Exists, maintained by the GPUI Kit authors, in-process | One language. The UI can't be inspected or driven from outside the script, and no other process can share it |
| **uitreefs**: one host per app, serving 9P | Any language with file I/O. The UI is inspectable with `cat` and scriptable from any process the client chooses to share it with. The host is one Rust program that tracks GPUI | Every client change crosses 9P, a few tens of microseconds locally. The client can't run code inside a frame, so anything per-frame needs a built-in (§ What runs where) |

The cost is acceptable because the design keeps the client out of the frame loop: it acts once per user action, not once per frame.

## Architecture

uitreefs is one GPUI Kit process per client application. It serves one 9P2000 connection, on a Unix socket, a pipe it hands to a command it starts, or stdin and stdout. Normally the other end is mounted in the client's h9 machine (§ Running a client in h9).

- **One root view per window.** Each window's root is a GPUI `Render` view whose `render` walks that window's node tree and builds `div`s and `gpui-component` elements from it. This is gpui-shell's materialize step with a tree as its input instead of a script arena.
- **The tree lives on the main thread.** GPUI state is single-threaded. The 9P server runs on the background executor, parses each write into an op, and sends it to the main thread through a channel. The main thread applies it inside an `update` and calls `cx.notify()` on the affected window, so GPUI redraws on its next frame. Many writes between frames cost one redraw.
- **Reads never wait for the UI.** After each batch of ops the main thread publishes an immutable snapshot of the tree (an `Arc`, swapped in place). The 9P thread serves `cat` and `ls` from it, so a busy frame doesn't stall a reader. A read just after a write sees that write, because the 9P thread waits for the op's acknowledgement before it answers the write.
- **The namespace is a view.** The host keeps one tree internally. The 9P layer presents it as described in § The tree, translating paths both ways, so a path the client reads in an event, in `trace` or in an error is always one it can write to.
- **Component state is GPUI's.** Stateful components (`InputState`, `SelectState`, `TableState`, `DockArea`) are `Entity`s held in a map keyed by node path, created when the node is created and dropped when it is removed. Their values are mirrored into the snapshot when they change.
- **Element IDs are paths.** GPUI needs a stable `ElementId` for hover, scroll and focus state. The node's path is that ID, so state survives every frame and is dropped when the node goes away.
- **Events flow back through queues.** GPUI listeners on the built elements (`on_click`, a component's `on_change`, action handlers) push events into per-subscription queues that the 9P thread drains when a client reads `events`.

## Running a client in h9

uitreefs is a standalone program for macOS, Linux and Windows. It runs its client inside an **h9 machine**: a small Plan 9 machine that h9 runs in-process, on the host's hypervisor. The client is a 9front program (rc, awk, a C program, a `GOOS=plan9` Go binary) or a static Linux binary (Python, Node, Lua, Ruby, jq, Ghostscript, GnuCOBOL from an Alpine tree), and it sees the tree as ordinary files at `/mnt/ui`, named by `$ui`. Nothing on the host needs a 9P client, FUSE or a mount, and the client behaves the same on every platform.

```text
uitreefs [-t title] [-k] [--root builtin|DIR] [--dir HOSTDIR[:DST]]... [h9 sandbox flags] cmd [arg...]
uitreefs [-t title] -a addr          # no machine: serve 9P on addr, for tests and outside clients
```

`cmd` follows h9's rule: `./prog` or any path with a slash is a host file loaded into the machine, and a bare name (`rc`) is looked up on the machine's `$path`. With `--root builtin` (the default) the machine has h9's built-in root, which includes rc and the common 9front commands. `--root DIR` uses a full 9front tree. The host's current directory is the machine's working directory, read-write, as in `h9`.

```rc
uitreefs -t Notes rc ./notes.rc        # an rc client
uitreefs -t Greeter ./greet            # a GOOS=plan9 Go binary built on the host
uitreefs --dir alpine:#L -t Todo /bin/lua todo.lua   # a Linux client from an Alpine tree
```

1. uitreefs starts GPUI on the main thread and makes a socket pair. Its 9P server takes one end.
2. On a worker thread it creates an `h9.Machine` with the other end as an `.fd` mount on `/mnt/ui`, sets `$ui=/mnt/ui` in the guest environment, and calls `Machine.run` with `cmd`. The machine attaches to the tree once, before the client starts, so the client's first `open` finds it ready.
3. **The `main` window already exists**, hidden. Its files (`$ui/win/main/ctl`, `tree`, `events`) are there before the client runs, so a client that can open only fixed files (sed, jq) needs no launch step. The window appears once its root has content, or on `show`. The client's standard output and error go to uitreefs's own, and its standard input reads end of file.
4. **When the client exits**, `run` returns its exit string. uitreefs closes its windows and exits, with code 0 for an empty string and 1 otherwise. `-k` keeps the app running on host defaults instead, for a one-shot script that builds a UI and leaves.
5. **When the app quits** (`quit` on the root `ctl`, the user closing the last window, or a `quit` request the client doesn't keep), uitreefs calls `Signals.hangup`. Every blocked `events` read returns end of file, later file access fails with `app gone`, and h9 tears the machine down after 2 seconds.
6. With `-a addr` and no `cmd`, uitreefs makes no machine and serves 9P on `addr`, so a test harness or a client on the host can attach with any 9P library.

**Linux clients.** A Linux binary sees the Plan 9 namespace under `/9`. When any `--dir` targets the Linux view (`#L`), the program runs there, so uitreefs sets `$ui` to `/9/mnt/ui` and a Python or Node client uses it as is. Clients should always go through `$ui` rather than spell the path. (The same path in both views would need h9's Linux `/mnt`, which holds only h9's own mount points, to show `ui`; see open questions.)

### Embedding h9

h9 is a Zig library ([docs/embedding.md](https://github.com/progrium/hyper9/blob/main/docs/embedding.md)) and GPUI is Rust, so uitreefs links h9 through a small C ABI shim. The shim is a Zig file in the uitreefs repository, built as a static library by `build.rs` (which runs `zig build` against a path dependency on a hyper9 checkout). It wraps `h9.Machine` and nothing else:

```c
typedef struct H9Machine H9Machine;

typedef struct {
    const char *root;        /* "builtin", or an absolute host path to a 9front tree */
    const char *cwd;         /* absolute host path, bound at /mnt/term/cwd */
    const char *const *dirs; /* extra --dir mounts, "SRC:DST[:OPTS]" */
    int ninep_fd;            /* the guest end of the socket pair */
    const char *ninep_dst;   /* "/mnt/ui" */
    const char *const *env;  /* "name=value", with ui=/mnt/ui */
    int out_fd, err_fd;      /* the client's stdout and stderr */
    const char *profile;     /* h9 policy profile, plus the flags below */
    const char *const *policy_flags; /* --net, --write, --timeout, ... as h9 parses them */
} H9Config;

int  h9_new(const H9Config *cfg, H9Machine **m, char *err, size_t errlen);
int  h9_run(H9Machine *m, const char *prog, const char *const *argv,
            char *status, size_t statuslen);  /* blocks until the client exits */
void h9_hangup(H9Machine *m);                 /* any thread */
void h9_stop(H9Machine *m);                   /* any thread */
void h9_free(H9Machine *m);
```

`h9_run` returns 0 with `exits` text in `status`, or 1 with a kill note (`h9: timeout`), or a negative error with `err` filled in. The shim copies status and error text out before returning, so the Rust side never holds pointers into the machine.

**Threads.** GPUI owns the main thread, which macOS requires for AppKit. `h9_run` blocks, so it runs on a dedicated `std::thread`, never on GPUI's executors. When it returns, that thread sends the status to the main thread through GPUI's async channel. uitreefs doesn't use h9's `gfx` option, so h9 never needs the main thread. `h9_hangup` and `h9_stop` only set a flag, so the main thread can call them when the app quits.

**One client per process.** h9 allows one HVF machine per process on macOS. uitreefs runs one app per process anyway, so this costs nothing. A second client is a second uitreefs process.

**The 9P server.** The socket pair's host end is served by uitreefs's Rust 9P server on its background executor, as in § Architecture. It is the same server that `-a addr` puts on a socket. Only the transport differs.

### Platforms

| Host | h9 backend | Notes |
| --- | --- | --- |
| macOS, Apple Silicon | HVF, arm64 guests | The binary must be signed with the hypervisor entitlement, as h9's build does |
| Linux x86\_64 | KVM, or the native backend (5.11+) for a trusted client | Needs an amd64 root tree for `--root DIR` |
| Linux arm64 | KVM | Built in h9, but not yet run on an arm64 KVM host |
| Windows x86\_64 | WHP, with the Windows Hypervisor Platform feature | Needs an amd64 root tree |
| Windows on ARM, or no hypervisor | hcpu, h9's own emulator | MIT, built into `h9`, so it ships in uitreefs too. Slower than a hypervisor |

Go clients are built on the host with `GOOS=plan9 GOARCH=arm64` (or `amd64`), matching the machine's architecture, and run unchanged on every platform with that architecture.

## Who can reach the tree

The tree is the app. Anyone attached to it can read every field, including `secret` inputs, and can rebuild or quit the app. So:

- The default service is a socket pair mounted only in the client's h9 machine. Nothing on the host can reach it, and inside the machine only the client and programs it starts see `$ui`. The h9 sandbox flags limit what the client itself can reach: by default the cwd and outbound network, as in h9's default profile.
- `-a unix!path` creates the socket mode 0600. `-a tcp!...` is refused unless `-insecure` is also given. uitreefs does no authentication of its own, so remote use belongs behind something that does (an ssh tunnel, a 9P `auth` file in a later version).
- Every attach gets the same, full view. There is no separate read-only or public view yet. Open question 4 asks whether there should be.
- Secret values are readable, because the reader is the app. They never appear in `trace`, which logs `value=<secret>` instead.

## The tree

The tree has an app directory, a directory per window, and a directory per node below that. **A window is its root node**: `$ui/win/main/` holds the root node's files and children, plus the window's own files. A node's children are its subdirectories, and the node's `order` file sets their order.

```text
$ui/                      the root of the 9P service, /mnt/ui
    version               uitreefs 0.2, then one feature word per line
    ctl                   app verbs: window, set/new/delete/tree by path, ask, theme, quit, begin/commit
    events                every event in the app
    trace                 every applied write and every error, streamed (read-only, like #τ/tkevents)
    theme/                tokens (read/write), mode (light|dark), name
    keys                  key bindings (§ Actions, keys and menus)
    menu/                 app menus, one file per menu
    clip  clipfiles       the platform clipboard, as text and as paths
    drag/<n>/data         payloads of drags in progress
    asset/                files a node can name with @name: icons, images, fonts
    win/
        main/             the window named main, which is also its root node
            ctl  events  tree  type  style  order  tag ...   the root node's files
            title  bounds  state  focus                       the window's files
            over/         dialogs, sheets, popovers
            header/       a child node
                type      text
                text      Hello
            body/ ...
```

Paths are written relative to a window everywhere a client sees one: `f/emp/in` is the node at `$ui/win/main/f/emp/in`, it is the path in that node's events, the path `focus` reads and takes, and the path in a `set` line on the window's `ctl`. `.` is the window's root. An overlay's path starts with `over/`.

**Window files and child names.** The window's own files sit beside its root node's. `over` is reserved and can't be a child's name. `title`, `state` and `focus` can be: a child with one of those names shadows the window file in the directory listing and in paths, since `text title` is the most natural name a heading has. The window's title, state and focus stay reachable through the window's `ctl` (`title text`, `state ...`, `set . focus=path`).

**`@name` lookup.** `$ui/win/main/@total` is the unique descendant named `total`, wherever it is. If two nodes share the name, the walk fails with `in use: ambiguous: total (body/right/total, foot/total)`, so the shortcut never silently picks the wrong one. `@name` works in every path: file paths, `set` and `new` lines, `focus`, and `anchor=`.

### Node files

Every node has these files. A component adds its own (§ Component catalog).

| File | Read | Write |
| --- | --- | --- |
| `type` | the node's type | once, at creation; later writes fail with `type is fixed` |
| `style` | style words (§ Style language) | replaces them |
| `order` | child names in order, space-separated | reorders; a child not listed is not drawn |
| `tag` | the author's routing word | sets it; the key of every event about the node and its untagged descendants |
| `ctl` | the verbs this node takes, one per line | one or more command lines, applied together |
| `events` | this node's events only | — |
| `tree` | the subtree as a document (§ Atomic updates) | replaces the subtree |
| `bounds` | `x y w h` from the last layout, window-relative | — |
| `id` | the node's path | — |

Text-valued properties (`text`, `value`, `placeholder`, `label`) are files of their own. A write is the whole value, raw bytes, no quoting. That removes Inferno Tk's quoting problem for the cases that matter most, which are user text and labels.

### Commands on any `ctl`

Every node's `ctl` and the window's `ctl` take the same four node commands. Each names a path relative to that `ctl`'s node; `.` is the node itself.

| Command | Meaning |
| --- | --- |
| `set PATH [word ...] [prop=value ...] [: style ...]` | Write property files of the node at PATH. Every file is a prop: `text`, `value`, `label`, `items`, `order`, `tag`, `style`. On a window root, `title=`, `size=`, `min=`, `pos=` and `focus=` set the window |
| `new TYPE PATH [word ...] [prop=value ...] [: style ...]` | Make a node at PATH (its parent must exist), set its props and append it to the parent's `order` |
| `delete PATH` | Remove the node and its subtree |
| `tree PATH <<END` … `END` | Replace the subtree at PATH with a document (§ Atomic updates) |

The app's `ctl` takes the same commands with the window as the first path elements: `set win/main/n text=5`. So a client that can write only one file writes `$ui/ctl`. (`set ID enabled=off`, whose first word doesn't start with `win`, is the action command of § Actions.)

```rc
m=$ui/win/main
echo 'set . title=Counter size=320,200 pos=center : v_flex items_center p=24 gap=12' >$m/ctl
echo 'new text n text=0 : text_3xl font_bold
new button inc label=+1 primary' >$m/ctl
echo 'set n text=1' >$m/ctl
```

All the lines in one write apply together or not at all, so one `ctl` write replaces most `begin`/`commit` pairs. A `ctl` write may also be split across several 9P writes (as `cat` does for large input); the lines apply when the file is closed.

**Here-values.** A line ending in `prop=<<WORD` takes the following lines, up to a line holding only `WORD`, as that prop's value. This is how multi-line values (`items`, `rows`, `ops`, `text`) travel through a `ctl`:

```rc
echo 'set list items=<<END
inbox Inbox
sent Sent
END
set list value=inbox' >$m/ctl
```

### Creating nodes

There are four ways to create a node. All of them produce the same tree.

1. **mkdir**: `mkdir $m/save` makes an empty `div`. Write `type` before the first frame or it stays a `div`.
2. **`new` on any `ctl`**, as above.
3. **A document**: write a whole subtree as text to a node's `tree` file, or `tree PATH <<END` on a `ctl` (§ Atomic updates).
4. **`set`** never creates; it fails with `not found` on a missing path, loudly (§ Errors).

`rm -r` on a node, or `delete PATH` on a `ctl`, removes it. A node's path never changes while it exists. A rename is a delete and a create, so GPUI drops its element state (scroll offset, hover).

### Quoting and words

There is one rule, Plan 9's `tokenize`/`quote`: words split on blanks, and single quotes group a word, with `''` for a literal quote. It applies to every `ctl` line, every document line and every `prop=value` pair. Text files are never parsed. Three conventions keep quotes rare:

- **A lone `:` starts the style.** Everything after it is the node's style words, unquoted: `new div card tag=open:42 on=click : v_flex gap=4 p=12 rounded_md`. A `:` inside a word (`tag=open:42`, `hover:bg=accent`) is not the separator.
- **A bare word is a boolean or a flag.** `stripe` means `stripe=on`; `secret cleanable` sets the input's flags (the older `flags=secret,cleanable` still works). A bare word that is neither fails with `bad value`.
- **Data lines need no tabs** (§ Data files).

### Windows

The `main` window exists from the start, hidden until its root has content or it gets `show`. `window NAME [opts]` on the root `ctl` makes another; on `main` it sets options and shows it. A window's own `ctl` changes it.

| Verb | On | Meaning |
| --- | --- | --- |
| `window name [title=text] [size=w,h] [min=w,h] [pos=x,y\|center] [kind=normal\|dialog\|popup] [titlebar=system\|custom\|none] [resizable=on\|off]` | root `ctl` | Make a window, with an empty `div` as its root. `in use` if the name is taken (except the hidden default `main`). `kind=dialog` is modal to the app's first window and has no minimize or maximize |
| `set . title=text size=w,h pos=center ...` | window `ctl` | The same options, on an existing window |
| `show` | window `ctl` | Show a hidden window now, even with an empty root |
| `title text` | window `ctl` | Set the title. The `title` file does the same |
| `size w,h` / `move x,y` / `center` | window `ctl` | Resize or move. `bounds` reads `x y w h` back, in screen points |
| `state normal\|minimized\|maximized\|fullscreen` | window `ctl` | Change the state. The `state` file reads it back, and a `state` event follows every change, user-made ones included |
| `activate` | window `ctl` | Bring to front and take key focus |
| `close` | window `ctl` | Close, as the close button does. With `ask close`, this sends a `close` request (§ Requests) |
| `destroy` | window `ctl` | Close now, without asking |
| `notify text [type=...]` | window `ctl` | A toast (§ Overlays) |
| `ask close` / `ask none` | window `ctl` | Opt this window into `close` requests, or out |

**Closing the last window quits**, unless uitreefs runs with `-k`. A client that wants to confirm first writes `ask close quit` to the root `ctl` (§ Requests).

## Style language

A `style` file holds GPUI `Styled` method names, one word per call, separated by blanks. The host looks each word up in the same reflection table gpui-shell uses for its `NullaryStyle` and `ParamStyle` ops. A word that isn't in the table fails the write with `unknown style word`. A write never half-applies.

| Form | Meaning | Examples |
| --- | --- | --- |
| `name` | a method with no argument | `flex_col` `items_center` `size_full` `rounded_md` `overflow_y_scroll` `cursor_pointer` |
| `name=n` | one number, in pixels | `w=240` `gap=12` `p=16` `text_size=13` |
| `name=n%` / `name=nrem` | a relative length | `w=50%` `px=1.5rem` |
| `name=token` | a theme token (`theme/tokens`) | `bg=primary` `text_color=muted_foreground` `border_color=border` |
| `name=#rrggbb[aa]` | a literal color | `bg=#1e1e2e` |
| `name=a,b` | several arguments | `shadow=0,4,12,#0003` |
| `hover:word` `active:word` `focus:word` `disabled:word` | a state style, resolved by GPUI with no round trip | `hover:bg=accent` `focus:border_color=ring` |
| `group:name` / `group-hover(name):word` | GPUI groups | a card that lights its title on hover |

GPUI Kit's own layout helpers are words too: `v_flex` and `h_flex` mean `flex flex_col` and `flex flex_row` with `items_center` where GPUI Kit sets it. Size words (`xs` `sm` `md` `lg`) set a component's `Sizable` size. Variant words (`primary` `ghost` `outline` `danger` `link`) set a component's variant when the component has one. On a raw `div` those words fail, which keeps a typo visible.

**Style on a component styles what you see.** On a component, layout and box words apply to its outermost visible element, not to a wrapper around it: `w=300` on a `field` or `sidebar` sizes the field or the sidebar.

```rc
echo 'h_flex gap=8 p=12 rounded_lg bg=muted hover:bg=accent cursor_pointer' >$m/card/style
```

### Theme

`theme/tokens` is `name value` lines: `background #ffffff`, `primary #0b5cff`, `radius 6` and so on, using `gpui-component`'s `ThemeColor` field names. Writing a line changes one token everywhere at once, since every style that names a token re-resolves on the next frame. `theme/mode` takes `light` or `dark`. `theme/name` loads a theme from GPUI Kit's theme registry (`Catppuccin`, `Tokyo Night`, ...), and `ctl` takes `theme load path` for a JSON theme in GPUI Kit's format.

## Element tier

The element tier is GPUI itself: unstyled boxes and text, laid out by Taffy (flexbox and grid) from the style words. Use it to build a design of your own, or to place and compose catalog components.

| Type | Files beyond the common set | Notes |
| --- | --- | --- |
| `div` | — | The universal box. Any `div` with `on=click` (below) becomes interactive |
| `text` | `text` | A styled run. Long text wraps by the parent's width. Takes the flags `selectable` and `truncate` |
| `styled-text` | `text`, `runs` | Text plus `start len style...` highlight lines, for syntax colors or search hits |
| `img` | `src` | `@asset`, a file path the host can read, or an `https` URL. Writing raw image bytes to `data` also works |
| `svg` | `src` | An icon or vector file. `text_color` tints it |
| `icon` | `name` | A GPUI Kit `IconName` (`search`, `chevron-down`, ...). It is `svg` with the kit's icon set |
| `scroll` | `origin` | A scrolling div. `style` picks the axes (`overflow_y_scroll`). `origin` reads and writes `x y` |
| `spacer` | — | `flex_1`, for pushing siblings apart |
| `canvas` | `ops` | Custom drawing (§ Canvas) |

### Making an element interactive

A raw element sends nothing unless asked. Write the names of the events it should send to its `on` file, or give `on=` when making it:

```rc
echo 'click hover drop' >$m/card/on    # also: mouse_down mouse_up scroll key focus blur
```

Those events map to GPUI's `on_click`, `on_hover`, `on_drop` and the other listeners, which the host registers on the element it builds each frame. Pointer motion is available (`move`) but coalesced, as in § Events.

```rc
# A clickable card from raw elements
echo 'new div list/card1 tag=open:42 on=click : v_flex gap=4 p=12 rounded_md border_1 border_color=border hover:bg=accent cursor_pointer
new text list/card1/title text=''Quarterly report'' : text_sm font_semibold' >$m/ctl
# clicking it gives: click open:42 list/card1 win=main seq=17
```

## Component catalog

A component is a node whose `type` names a `gpui-component` component. It takes style words like any node, plus its own property files and `ctl` verbs. The host owns each component's GPUI state (an `InputState`, `SelectState`, `TableState` entity), keyed by the node's path, so it lives exactly as long as the node does.

Four rules apply to every component:

- **Uncontrolled by default.** A checkbox toggles itself, and a select changes its own value, then the host sends the event. The client never has to echo state back. Writing `controlled=on` makes the component wait for the client to write its `value`, as GPUI Kit's controlled API does.
- **Children are slots.** Where a component takes elements (a button's content, a dialog's footer, a tab's panel), the child directories are those elements. Where it takes named slots, the child names are the slot names: `prefix`, `suffix`, `header`, `footer`, `trigger`, `content`.
- **Items are files.** Lists, tables, trees and selects take their data as a line-oriented file, never as one directory per row. The host virtualizes them.
- **Words mean what they read as.** `dir=row|col` is the one spelling for arrangement (`h` and `v` are accepted and stored as `row` and `col`). `layout` means only the dock's saved state.

### Data files

`items`, `columns`, `rows`, `data`, `diagnostics` and `append` are lines of tab-separated fields. **A line with no tab in it is read as Plan 9 words instead**, with the usual quoting, so a script doesn't need `printf` or invisible tabs. Output from `awk -F'\t'` and other tools stays TSV and works unchanged. Lines starting `# ` (a group header) and a lone `-` (a separator) are kept as they are.

```rc
echo 'rs Rust
go Go
cob ''GnuCOBOL 3.2''' >$m/prefs/lang/in/items
```

The select and list format:

```text
id  label  [icon=name]  [disabled]
# a line starting with "# " is a group header; "-" alone is a separator
```

### Buttons and form controls

| Type | Properties (files or `prop=`) | Events |
| --- | --- | --- |
| `button` | `label`, `icon`, `loading`, `disabled`, `selected`; variant and size words in `style` | `click` |
| `button-group` | `multiple`, `value` (selected child names) | `change value=` |
| `dropdown-button` | `label`; a `menu` file (§ Actions grammar) | `click`, `action` |
| `checkbox` | `label`, `value` (`on`, `off`, `mixed`) | `change value=` |
| `radio-group` | `items`, `value`, `dir=row\|col` | `change value=` |
| `switch` / `toggle` | `label`, `value` | `change value=` |
| `slider` | `min` `max` `step` `value` (one number, or `lo hi` for a range), `dir` | `change value=` (coalesced while dragging), `commit value=` on release |
| `input` | `value`, `placeholder`, `mask`, `max_len`; flags `secret`, `cleanable`, `readonly`; `prefix`/`suffix` slots | `change` (coalesced, carries no text), `submit` (inside a form, the form sends it instead), `focus`, `blur` |
| `textarea` | as `input`, plus `rows`, `auto_grow=min,max` | as `input` |
| `number-input` | `value`, `min`, `max`, `step` | `change value=` |
| `otp-input` | `length`, `value`, `secret` | `change`, `complete value=` |
| `select` | `items`, `value`, `placeholder`, `searchable` | `change value=` |
| `combobox` | `items`, `value`, `multiple`; `query` is readable | `change value=`, `query` (coalesced, for a client that filters items itself) |
| `date-picker` | `value` (ISO date, or `start end`), `range`, `min`, `max`, `presets` | `change value=` |
| `calendar` | as `date-picker`, shown inline | `change value=` |
| `color-picker` | `value` (`#rrggbbaa`), `swatches` | `change value=` (coalesced), `commit` |
| `rating` | `max`, `value` | `change value=` |
| `form` | `dir=col\|row` arranges the fields; `labels=top\|side` places their labels; `label_width`; children are `field` nodes | `submit` |
| `field` | `label`, `description`, `error`, `required`; one control child | — |

The text of an `input` changes on every keystroke, so its `change` event says only that it changed. A client that needs the text reads the `value` file. That keeps the event stream small and makes a slow client see the newest text, never a backlog.

```rc
cat >$m/prefs/tree <<'EOF'
form prefs  labels=side
  field name  label=Name
    input in  placeholder='Your name'
  field lang  label=Language
    select in  searchable
  field ok
    button save  label=Save  tag=save  : primary
EOF
echo 'set prefs/lang/in items=<<END
rs Rust
go Go
c C
END' >$m/ctl
```

### Navigation

| Type | Properties | Events |
| --- | --- | --- |
| `tabs` | `value` (selected tab name), variant words (`underline`, `pill`, `segmented`); children are `tab` nodes | `change value=` |
| `tab` | `label`, `icon`, `closable`; its children are the panel, drawn only while selected | `close` |
| `sidebar` | `collapsed`, `side=left\|right`, `collapsible=icon\|off`; `header`, `footer` slots; children are `sidebar-group` nodes | `collapse value=` |
| `sidebar-group` | `label`; children are `sidebar-item` nodes | — |
| `sidebar-item` | `label`, `icon`, `active`, `badge`; children are sub-items | `click` |
| `breadcrumb` | `items` | `click id=` |
| `pagination` | `page`, `total`, `per_page` | `change page=` |
| `stepper` | `items`, `value`, `dir` | `change value=` |
| `title-bar` | `title`; children fill the bar. Writing it makes the window draw its own title bar, as GPUI Kit's `TitleBar` does | `action` from window controls |
| `toolbar` | children are buttons and separators | — |
| `status-bar` | `left`, `center`, `right` slots | — |
| `link` | `label`, `href` | `click` (the host opens `https` links itself unless `on` lists `click`) |

```rc
# A settings window: sidebar on the left, the page on the right
cat >$ui/win/main/tree <<'EOF'
div root  : h_flex items_stretch size_full
  sidebar nav
    sidebar-group g  label=Settings
      sidebar-item general  active  label=General  icon=settings  tag=page:general
      sidebar-item account  label=Account  icon=user  tag=page:account
      sidebar-item keys  label=Shortcuts  icon=keyboard  tag=page:keys
  div page  : flex_1 p=24
EOF
```

### Overlays

Overlays live in their window's `over/` directory, not in the node tree, because GPUI Kit draws them in the window's `Root` layer above everything. Each overlay is still a node with children, and its path is `over/NAME`. Writing `open` to its `ctl` shows it, and `close` hides it. An overlay can also be bound to a trigger node, which opens it with no round trip.

| Type | Properties | Events |
| --- | --- | --- |
| `dialog` | `title`, `description`, `width`, `modal`, `overlay_closable`, `keyboard` (Esc closes); `footer` slot | `open`, `close` |
| `alert-dialog` | `title`, `description`, `confirm`, `cancel` (button labels), `variant=danger` | `confirm`, `cancel` |
| `sheet` | `side=left\|right\|top\|bottom`, `size`, `title`; `footer` slot | `close` |
| `popover` | `anchor=<node path>`, `placement` (`bottom-start` ...), `trigger=click\|hover` | `open`, `close` |
| `hover-card` | as `popover`, with `trigger=hover` and open and close delays | — |
| `tooltip` | a `tooltip` file on any node, or `key=` for a shortcut hint | — |
| `context-menu` | `anchor=<node path>`; a menu body (§ Actions) | `action` |

Notifications don't need a node. The window `ctl` takes them as a verb, and GPUI Kit stacks and expires them:

```rc
echo 'notify ''Saved draft'' type=success' >$ui/win/main/ctl
echo 'notify ''Upload failed'' type=error sticky=on action=retry:''Try again''' >$ui/win/main/ctl
```

A confirm-before-delete flow:

```rc
o=$ui/win/main/over
echo 'new alert-dialog confirm-del title=''Delete 3 files?'' description=''This cannot be undone.'' confirm=Delete cancel=Keep variant=danger tag=del' >$o/ctl
echo open >$o/confirm-del/ctl
# events gives: confirm del over/confirm-del win=main seq=31
```

### Data display

These components need the items-are-files rule most. GPUI Kit's `List`, `Table` and `Tree` take a Rust delegate that answers how many rows there are and renders row n. In uitreefs the host supplies that delegate, and it reads from a file the client wrote.

| Type | Properties | Events |
| --- | --- | --- |
| `list` | `items` (the select format) or a `row` template child; `selectable`, `multiple`, `searchable`, `loading` | `select value=`, `open id=`, `scrolled_to_end` |
| `table` | `columns` (`id label width [sort] [fixed] [align=right]` lines), `rows` (first field is the row ID); `stripe`, `selectable=row\|cell`, `resizable`, `sortable` | `select row= col=`, `sort col= dir=`, `open row=`, `scrolled_to_end` |
| `tree` | `items` (`id parent label [icon=]` lines, parent `-` for roots), `expanded` (IDs); `selectable`, `multiple` | `select value=`, `expand id= value=`, `open id=` |
| `description-list` | `items` (`label value` lines), `columns`, `bordered`, `labels=side\|top` | — |
| `badge` | `count` or `dot`, `max`; one child it decorates | — |
| `tag` | `label`; variant and color words | `close` if `closable` |
| `avatar` / `avatar-group` | `src`, `name` (initials fallback), `max` | — |
| `kbd` | `key` in GPUI keystroke syntax (`cmd-shift-p`), drawn for the platform | — |
| `progress` | `value` 0 to 100, or empty for indeterminate; `variant=bar\|circle` | — |
| `spinner`, `skeleton`, `shimmer` | size words | — |
| `empty` | `title`, `description`, `icon`; children are actions | — |
| `alert` | `title`, `text`, `variant=info\|success\|warning\|error`, `closable` | `close` |
| `chart` | `kind=line\|bar\|area\|pie`, `data` (a header row, then rows), `x`, `y` (column names) | `select x=` |

**Sorting stays in the client.** A `sort` event says which column and direction the user asked for. The client rewrites `rows`, or writes `sorted=on` to let the host sort the column as text or numbers. Because `rows` is written whole, a large table can be fed in pages instead. The `append` file adds lines to the end, and a `scrolled_to_end` event asks for more.

**Templated rows.** For rows richer than text, a `list` takes a `row` child, an ordinary subtree whose text files can hold `{field}` placeholders. The host stamps it once per visible item, filling fields from the item's columns, named by a `fields` file. It keeps 100k rows as one file.

```rc
echo 'new table files stripe selectable=row sortable' >$m/ctl
echo 'set files columns=<<END
name Name 280 sort
size Size 90 sort align=right
mod Modified 160 sort
END' >$m/ctl
ls -l | awk '{print NR "\t" $9 "\t" $5 "\t" $6" "$7" "$8}' >$m/files/rows
```

### Editing and rich content

| Type | Properties | Events |
| --- | --- | --- |
| `editor` | `value`, `language` (a Tree-sitter grammar name), `line_numbers`, `soft_wrap`, `tab_size`, `readonly`; `diagnostics` (`line col len severity message` lines); `selection` (read/write `line col line col`) | `change` (coalesced), `save` (the bound key), `cursor line= col=` (coalesced), `hover line= col=` and `complete line= col= prefix=` (requests) |
| `markdown` | `text`, `selectable` | `link href=` |
| `html` | `text` (a safe HTML subset, as GPUI Kit's `TextView` renders it) | `link href=` |
| `diff` | `old` and `new`, or `patch` (unified); `view=split\|unified` | — |
| `message-list` | `items` (an `id role time` header line, then markdown, ended by a blank line); `stick_to_bottom` | `scrolled_to_top` |
| `bubble` | `role=user\|assistant`, `text` (markdown), `avatar` | — |

The `editor` is the clearest case of keeping fast work in the host. A 200k-line file is written once to `value`. Typing, selection, highlighting and scrolling all run in GPUI Kit's editor. The client gets coalesced `change` events and reads `value` when it wants the text, for example to save it.

LSP features become requests the client can answer. A `complete` event asks for completions. The client answers by writing `items` lines to the editor's `completions` file, tagged with the request's `seq=`, so a late answer to an old request is dropped. `hover` is answered the same way through `hover`. A client that doesn't answer gets no popup, and nothing waits on it.

```rc
echo 'new editor src language=rust line_numbers' >$m/ctl
cat main.rs >$m/src/value
echo '12 5 3 error ''mismatched types''' >$m/src/diagnostics
```

### Layout

| Type | Properties | Events |
| --- | --- | --- |
| `accordion` | `multiple`, `value` (open item names); children are `accordion-item` nodes with `title` | `change value=` |
| `collapsible` | `open`; a `trigger` slot and a `content` slot | `change value=` |
| `group-box` | `title`, variant words | — |
| `separator` | `dir`, `label` | — |
| `resizable` | `dir=row\|col`; children are `panel` nodes with `size`, `min`, `max` | `resize sizes=` (on release) |
| `grid` | `cols`, `rows`, `gap`; children take `col_span` and `row_span` style words | — |
| `dock` | `layout` (read/write, GPUI Kit's serialized `DockArea` JSON); children are `dock-panel` nodes | `layout` (on change, coalesced), `panel-close id=` (a request) |
| `dock-panel` | `title`, `icon`, `zone=center\|left\|right\|bottom`, `closable`, `zoomable` | `activate`, `close` |
| `virtual-list` | as `list`, with `item_height`, or `measure` for mixed heights | as `list` |

The dock shows why file state beats events. A user can drag tabs between docks, split, resize and zoom, all inside GPUI Kit. The client doesn't track any of it. To restore a layout on the next launch, it does `cat $m/ws/layout >layout.json` at quit and writes the file back at start.

```rc
echo 'new dock ws : size_full
new dock-panel ws/files title=Files icon=folder zone=left
new dock-panel ws/src title=main.rs zone=center
new dock-panel ws/log title=Output zone=bottom' >$m/ctl
test -f $home/lib/layout.json && cat $home/lib/layout.json >$m/ws/layout
```

### Not in this version

- **Raw `Render` views and delegates as code.** Anything that needs a Rust closure per row or per frame goes through a data file or a template.
- **`webview`.** It is a separate crate with its own process model. It could be a node with a `url` file later.
- **`speech`, `touch_selection`, `inspector`, `fps`.** These are platform or developer tools, not application UI.
- **The `gpui-base` unstyled layer as its own tier.** The element tier plus style words already gives full visual control, so a third tier would add little.

## Events

Events are text lines on `events` files. **Every line starts with three positional words**, then `key=value` attributes:

```text
name  key  path  attr=value ...  seq=N
```

| Word | Meaning |
| --- | --- |
| `name` | the event: `click`, `change`, `action`, `close`, ... |
| `key` | the routing word: the node's `tag`, inherited from the nearest tagged ancestor; for `action` events, the action id. `-` if there is none |
| `path` | the node's path, relative to its window, so it is the path you write to. `.` is the window itself, `over/x` an overlay, `-` app-level (`quit`, a menu action with no window) |

```text
click save f/ok/save win=main seq=118
change - prefs/lang/in win=main value=go seq=119
action save src win=main seq=120
close - . win=main via=titlebar seq=121
```

The third line is `cmd-s` bound to `save`: a button tagged `save` and the `save` action both put `save` in word 2, so one branch handles both. For an `action`, `path` is the focused node.

Attribute values are always one word (ids, numbers, `on`/`off`, dates). Text that can hold blanks is read from its file. So splitting on blanks is always correct: `$ev(2)` in rc, `$2` in awk, `strings.Fields(line)[1]` in Go, `UNSTRING ... DELIMITED BY SPACE` in COBOL, `/^click save /` in sed.

- **Where to read.** The app `events` file has every event, each window's `events` has that window's, and each node's `events` has that node's. A client picks the grain that suits it. Each open of an `events` file is its own subscription, starting with a `resync - - seq=N` line. When the window or node goes away, the stream ends with `gone - -`, then end of file.
- **Tags inherit.** Tag a form once and every input in it reports the form's tag. The nearest tag wins, so a tagged button inside a tagged form reports its own.
- **Echoes.** Changes the client made itself carry `via=ctl`. Changes the user made carry `via=user`.
- **Any read size.** A read returns as much as fits; a line longer than the buffer comes back in pieces over several reads. rc's `read`, awk's `getline <file` and a small `fgets` loop all read `events` directly.

### Two kinds of event

A click can't be reread later, but a value can. So events come in two kinds, and they are queued differently.

| Kind | Examples | When the reader is slow |
| --- | --- | --- |
| **State** | `change`, `select`, `cursor`, `resize`, `layout`, `move`, `scroll`, `hover` | **Coalesced.** A new event replaces a queued one with the same name about the same node, and moves to the back of the queue. The newest state always arrives, and the queue can't grow without bound |
| **Action** | `click`, `submit`, `open`, `action`, `confirm`, `cancel`, `close`, `quit`, `key`, `drop`, `error`, requests | **Never dropped.** Queued in order, up to 4,096 per subscription. Past that, the reader gets `lost - - n=N` and the host treats it as not answering |

Order is kept between the two. A coalesced event takes the position of its newest copy, so a client never sees a `change` after the `submit` that came from it.

### Requests

Some events can ask the client to decide: closing a window, quitting, closing a dialog, tab or dock panel, completing in an editor, or accepting a drop. **Requests are opt-in.** By default the host applies the answer at once: closing a window closes it, closing the last window or choosing Quit quits, and a drop is refused unless the node has a `drop` file.

A client that wants to answer writes `ask close quit` to the root `ctl` (or `ask close` to one window's `ctl`; `ask none` turns it off). Then, while an `events` file is open, the host sends the request and waits for the client to answer on the node's (or app's) `ctl` with `close`, `keep`, `accept` or `refuse` and the request's `seq=`. After 5 seconds with no answer, the host applies the default. With no `events` file open, the default applies at once.

### Drag and drop

GPUI drags carry a typed value inside the app and paths from the platform (`ExternalPaths`). uitreefs exposes both through files, so the dragged data never has to fit in an event line.

**Receiving.** A node becomes a drop target with a `drop` file listing what it accepts: `files`, `text`, `uri`, or a client-chosen type such as `note`. While a drag hovers over it, its `hover:` and `drop-over:` style words apply with no round trip. A drop sends a request event:

```text
drop pick nav/notes win=main type=files drag=7 pt=40,212 seq=301
```

The payload is in `$ui/drag/7/data`: one path per line for `files`, the text for `text`. Linux clients find dropped host files under `$ui/drag/7/files/`. The client answers with `accept seq=301` or `refuse seq=301` on the node's `ctl`. With no answer, the drop is refused. `drag/7` disappears once the request is answered.

**Starting a drag.** A node with `drag` in its `on` file and a `drag-type` file starts a drag in the host when the user presses and moves on it, with no round trip. The host sends `dragstart KEY PATH drag=8`. The client writes the payload to `$ui/drag/8/data`, which can happen after the drag begins, since the payload is only read at the drop. When it ends, a `dragend KEY PATH drag=8 result=dropped|cancelled target=<path>` event follows. Drags between uitreefs apps, or out to the platform, use `files` and `text` only.

### Clipboard

The root `clip` file is the platform clipboard, as text. Reading it returns the current text. Writing replaces it. `clipfiles` does the same for paths. Copy and paste inside inputs and editors are built in and never involve the client.

## Actions, keys and menus

GPUI routes keys through named actions: a keystroke matches a binding in a `key_context`, the binding names an action, and the action is dispatched up the focus path. uitreefs keeps that model and lets the client name the actions.

**Keys.** The root `keys` file holds one binding per line, in GPUI keystroke syntax:

```text
cmd-s        save
cmd-shift-p  palette
escape       dismiss      context=editor
ctrl-tab     next-tab     context=workspace
```

`cmd` means Cmd on macOS and Ctrl on Linux and Windows (GPUI's `secondary`), so one binding file serves every platform; `super` names the Super key there.

A node's `context` file sets its GPUI `key_context`, so `context=editor` binds only while focus is inside a node with that context. Built-in GPUI Kit actions (an input's `select-all`, a list's `select-next`) keep working and are not reported. An action named in `keys` that no built-in handles comes to the client as `action save src win=main`: the action id is the key, and the focused node is the path.

**Menus.** The root `menu/` directory sets the app menu bar (GPUI's `App::set_menus`, a native menu on macOS). Each menu is a file of item lines, which is uxkit's grammar:

```text
item new    label=New      key=cmd-n
item open   label=Open…    key=cmd-o
sep
sub recent  label='Open Recent'
  item a    label=a.txt
item quit   label=Quit     key=cmd-q
```

Choosing an item sends the same `action ID` event as its key. `set ID enabled=off` and `set ID check=on` on the root `ctl` change every item, button or binding for that action at once, the way GPUI disables an action that has no handler. Context menus and `dropdown-button` menus use the same item grammar in their `menu` file.

**Focus.** The window `focus` file reads the focused node's path. Writing a path moves focus there (GPUI's `FocusHandle::focus`); so does `set . focus=PATH`. `focus` and `blur` events are state events.

## Atomic updates and subtree documents

GPUI draws whenever it likes, so a client building a form one file at a time could show half a form. There are three ways to prevent that.

**One `ctl` write.** All the lines in one write apply together. With `set`, `new`, `delete`, `tree` and here-values, most updates fit in one write.

**Batches.** `begin` on a window's `ctl` freezes what that window draws. Writes still apply to the tree, and reads show them, but the frame keeps drawing the last committed tree. `commit` makes everything visible in one frame, and `abort` throws it all away. Batches are per client connection (per 9P session), so two clients can't commit each other's work. A batch left open for 2 seconds is committed, and the trace logs `batch timeout`, so a crashed client can't freeze a window.

**Subtree documents.** Every node has a `tree` file. Reading it prints the subtree as indented text. Writing it replaces the subtree in one step, and the host keeps any child whose name and type match, so focus, scroll and editor state survive. That makes a whole screen one `cat`:

```text
div root  : v_flex size_full p=24 gap=16
  text title  text='Sign in'  : text_xl font_semibold
  form f
    field user  label=Email
      input in  placeholder=you@example.com
    field pass  label=Password
      input in  secret
    field go
      button submit  label='Sign in'  tag=login  : primary w_full
  link help  label='Forgot password?'  href=https://example.com/reset
```

Each line is `type name [word ...] [prop=value ...] [: style ...]`, with two spaces of indent per level. Text properties fit inline when they are short. Longer text goes in a here-value: `text=<<END`, the lines, then `END`. The reader prints the same format, so `cat tree >screen.ui` saves a screen and writing it back restores it. A client that likes the document model can work only in `tree` files and never touch directories. The directory view is still there for scripts that want to change one label.

## Canvas

A `canvas` node holds a retained display list in its `ops` file. GPUI paints the list on the GPU every frame, so the client only writes when the picture changes.

```text
rect   bg      0 0 400 300   fill=background
rect   card    20 20 160 90  fill=muted radius=8 border=border
path   spark   M20,200 L60,180 L100,190 L140,150  stroke=primary width=2
circle dot     140 150 4     fill=primary
text   lbl     28 44         'Revenue'  size=13 color=muted_foreground
image  logo    360 12 24 24  src=@logo
```

Each line is `kind id geometry attrs`. Colors are theme tokens or literals. Writing `ops` replaces the list. The canvas's own `ctl` changes items by ID: `set dot 150 140`, `add`, `del`, `raise`, `lower`. So moving one item costs one short write, not a new picture. (On a canvas's own `ctl`, `set` edits an item; its node props are set from the window's `ctl`, `set chart : h=200`.) A `pixels` file takes raw RGBA at the canvas's size, for clients that render images themselves.

Pointer input follows the `on` file, as for any element: `mouse_down`, `mouse_up` and `click` are action events, and `move` and `drag` are coalesced. Events name the item under the pointer: `mouse_down - chart win=main item=dot x=141 y=150 button=left`. Hit testing runs in the host, so an item can have `hover:fill=accent` with no round trip.

## A complete client

A small notes app in rc: a sidebar list of notes, an editor, a toolbar with save and delete, key bindings and a menu. Notes are files in `$home/notes`.

```rc
#!/bin/rc
m=$ui/win/main
n=$home/notes

echo 'set . title=Notes size=900,600' >$m/ctl
cat >$m/tree <<'EOF'
div root  : h_flex items_stretch size_full
  sidebar nav  : w=220
    list notes  searchable  selectable  tag=pick
  div page  : v_flex flex_1
    toolbar bar
      button save  label=Save  icon=check  tag=save  : ghost sm
      button del   label=Delete  icon=trash  tag=del  : ghost sm danger
    editor body  language=markdown  soft_wrap  : flex_1
EOF

echo 'cmd-s save
cmd-n new' >$ui/keys
echo 'item new label=New key=cmd-n
item save label=Save key=cmd-s
sep
item quit label=Quit key=cmd-q' >$ui/menu/File

fn refresh { ls $n | sed 's,.*/,,; s/.*/& &/' >$m/nav/notes/items }
refresh
cur=''

cat $ui/events | while(ev=`{read}){
	switch($ev(1)-$ev(2)){
	case select-pick
		cur=`{echo $ev | sed 's/.* value=([^ ]*).*/\1/'}
		cat $n/$cur >$m/page/body/value
	case *-save
		cat $m/page/body/value >$n/$cur
		echo 'notify Saved type=success' >$m/ctl
	case *-new
		cur=untitled-`{date -n}; touch $n/$cur; refresh
	case *-del
		rm $n/$cur; refresh
	case *-quit
		echo quit >$ui/ctl
	}
}
```

The client handles five kinds of event, and branches on the first two words. Everything else runs in the host: typing, search in the list, sidebar resize, markdown highlighting, focus, the notification, and the native menu. Closing the window quits on its own.

Run it with `uitreefs -t Notes rc ./notes.rc`. The same program in Go is a `GOOS=plan9` binary that uses only package `os` and `strings.Fields` on `$ui`.

## What runs where

The client acts once per user action. Everything that happens many times a second stays in the host.

| Interaction | Runs in | The client sees |
| --- | --- | --- |
| Typing, selecting and editing text, undo | GPUI Kit input and editor | coalesced `change`, then reads `value` |
| Scrolling, scroll bars, virtualized lists and tables | GPUI Kit | `scrolled_to_end`, if it asked |
| Hover, press and focus styles | GPUI state styles | nothing |
| Opening and tracking menus, selects, popovers, tooltips | GPUI Kit | one `action` or `change` |
| Resizing panels, columns and dock splits, dragging dock tabs | GPUI Kit | one `resize` or `layout` on release |
| Key bindings and focus movement | GPUI's keymap and focus | `action` only for client-named actions |
| Drag and drop | GPUI and the platform | `dragstart`, `drop`, `dragend` |
| Toasts, dialog open and close animation | GPUI Kit | `close` and `confirm` |
| Drawing on a canvas | the client writes items, GPUI paints | coalesced `move` and `drag`, item hits |

Only the canvas puts the client near the frame loop, which is why its motion events are coalesced and why it takes a retained item list, not frames.

## Errors and limits

A failed write returns a 9P error whose text is one of a fixed set of phrases, followed by detail after a colon: `unknown style word: flexx`. **Errors are loud**: a failed write also goes to three places a script will see, since awk, COBOL and shell redirections often drop a write error.

- uitreefs's stderr: `uitree: write win/main/body/total/text: not found: body/total`
- the `trace`: `error path=win/main/body/total/text err='not found: body/total'`
- an `error` event on the app's and the window's `events`: `error - body/total/text win=main code=not_found seq=40`

| Error | When |
| --- | --- |
| `unknown command` | a `ctl` verb the node doesn't take |
| `bad syntax` | quoting or `prop=value` that doesn't parse |
| `unknown style word` | a style word not in the table, or not valid for this type |
| `unknown type` | a `type` or `new` that names no element or component, or a child the parent can't hold |
| `type is fixed` | writing `type` after the first frame |
| `in use` | `new` or `window` with a name that exists; an ambiguous `@name` |
| `not found` | a path, node or item ID that doesn't exist |
| `bad value` | a value of the wrong kind (`w=wide`) or out of range |
| `too large` | over a limit below |
| `no batch` | `commit` or `abort` with no `begin` |
| `app gone` | any access after the app quit |

The `trace` file streams: a reader gets the recent history first, then every new write and error as it happens.

| Limit | Value |
| --- | --- |
| One `ctl` write | 64 KiB per 9P write; a `ctl` written in pieces applies at close |
| A text property file (`value`, `text`) | 16 MiB |
| A data file (`items`, `rows`, `ops`) | 64 MiB |
| An image or `pixels` write | 16 MiB |
| Queued action events per subscription | 4,096 |
| Node depth | 64, as in gpui-shell |
| An open batch | 2 seconds |
| A request waiting for an answer | 5 seconds |

## Changes from gpuifs 0.1

uitreefs is gpuifs renamed, with the protocol reworked from what its 24 example clients had to work around. Every example in `examples/` has been moved over.

| Then | Now |
| --- | --- |
| `click win=main node=root/ok tag=save seq=3` | `click save ok win=main seq=3`: name, key, path first |
| `action id=save win=main focus=root/src` | `action save src win=main` |
| `$gpuifs/windows/main/root/f/emp/in` | `$ui/win/main/f/emp/in` |
| `overlays/` `keymap` `menus/` `clipboard` `clipboard-files` `drags/` `assets/` | `over/` `keys` `menu/` `clip` `clipfiles` `drag/` `asset/` |
| A node's `ctl` takes only `new NAME` and `delete NAME` | Any `ctl` takes `set`/`new`/`delete`/`tree` by path, with here-values |
| `style='v_flex gap=4'` | `: v_flex gap=4` |
| `stripe=on`, `flags=secret` | `stripe`, `secret` |
| `form layout=h`, `dir=h\|v`, `diff layout=` | `form labels=side`, `dir=row\|col` (and `form dir=` arranges fields), `diff view=` |
| Data lines must be TSV | A line without tabs is Plan 9 words |
| `events` reads shorter than a line fail | Any read size |
| Every client creates `main` and answers `close`/`quit` | `main` exists; requests are opt-in with `ask` |
| Errors only to the writer | Also stderr, `trace` and an `error` event |
| `/mnt/gpui`, `/9/mnt/gpui` for Linux clients | `$ui`: `/mnt/ui`, or `/9/mnt/ui` for Linux clients |

## Open questions

1. **Directory names vs. order.** Child names are IDs and `order` gives the order. Should a name like `10-header` also sort, so `ls` shows the order with no `order` file?
2. **Request timeout.** Five seconds before the default answer to a request is a guess. Should it be per request type, or set by the client?
3. **Templates beyond lists.** Row templates cover lists. Should tables and trees take a cell or item template too, or is text enough there?
4. **Multiple clients.** One app tree per client is the simple model. Should a second client be able to attach to a running app, as 9/UX's public view allows, and with what rights?
5. **Style word coverage.** The reflection table is GPUI's `Styled` methods plus GPUI Kit's helpers. Arbitrary GPUI `Style` fields with no method (grid templates, for one) need a `name=value` escape.
6. **`tree` diffing.** Keeping children by name and type is simple. Is it enough to keep editor and input state across a rewrite, or do some components need a stable `key=`?
7. **Accessibility.** GPUI Kit has AccessKit roles built in. Should `label` and `role` files be required on raw-element widgets, so a client-built button is still announced as a button?
8. **Tags with an argument.** `todo.rc` tags rows `del:t3` and splits on `:`. Is `verb:arg` in one key word enough, or should the head grow a fourth word?
9. **`@name` and `@asset`.** `@total` finds a node and `src=@logo` names an asset. A later `new` can make a working `@name` ambiguous. Should lookup be limited to tagged nodes, and should one of the two take another sigil?
10. **Shadowed window files.** A child named `title` hides the window's `title` file. Shadowing is the least surprising rule found so far; is a separate `win/main/.win/` directory for window files cleaner?
11. **The browser.** h9 has a WebAssembly host, and GPUI Kit builds for `wasm32`. uitreefs in a browser tab, with the client in an h9 machine beside it, may be possible.
12. **`$ui` in the Linux view.** Linux clients find the tree at `/9/mnt/ui`, because h9's Linux `/mnt` is its own directory of mount points and shows nothing else. One path in both views wants h9 to show the tree there too (a `ui` mount point beside `term`, or a union with the Linux tree's `/mnt`). Until then `$ui` differs by view, and a 9front program started from a Linux root has to set it.
