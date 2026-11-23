//! The change stream of the renderer tree (protocols/render.md § The
//! change stream): what a pump changed, as text lines a renderer in any
//! language applies to its copy of the tree.
//!
//! PROTOTYPE. This is the 9P renderer spike: it encodes from the C ABI's
//! `UitChanges` plus the state pinned at the pump, so it runs on the owner
//! thread right after `uit_pump`, exactly where a built-in renderer would
//! read the same nodes in place. One encoding per pump, fanned out as bytes
//! to every attached renderer.
//!
//!     snap 7
//!     theme mode=light tokens=<<END ... END
//!     window main title=Counter size=300,180 state=normal
//!     new div win/main order='dec n inc' : h-flex size-full ...
//!     new text win/main/n text=0 : text-3xl font-semibold
//!     end 7
//!     batch 8
//!     set win/main/n text=1
//!     redraw main
//!     end 8

const std = @import("std");
const core = @import("uitcore");
const abi = core.abi;
const uit = @import("uit.zig");
const proto = core.proto;
const types = core.types;
const treem = core.tree;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const State = treem.state.State;
const Node = treem.state.Node;
const Handle = treem.Handle;
const tokenize = proto.tokenize;
const ctl = proto.ctl;

pub const Encoder = struct {
    gpa: Allocator,
    /// handle -> `win/main/f/ok`, for nodes the stream has made. A removed
    /// handle's path is only known from here.
    paths: std.AutoHashMapUnmanaged(Handle, []u8) = .empty,
    /// The reverse, for input lines that name a node by path. Keys are the
    /// same slices as `paths`' values.
    handles: std.StringHashMapUnmanaged(Handle) = .empty,
    /// The child order each node has as the renderer sees it: what the
    /// `new` lines appended and the `delete` lines took out, or the last
    /// `order=` sent. A batch sends `order=` only when the tree's differs,
    /// so a list that grows by one child costs one `new` line, not the
    /// whole list again (the first spike sent it every time: 71 MB for
    /// 5,000 rows built one write at a time).
    orders: std.AutoHashMapUnmanaged(Handle, std.ArrayList(Handle)) = .empty,
    parents: std.AutoHashMapUnmanaged(Handle, Handle) = .empty,
    /// uit_request seq -> the id= the renderer gave it, for `answer`.
    requests: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    /// Pump number: every snapshot and batch carries the one it is as of.
    seq: u64 = 0,

    pub fn deinit(e: *Encoder) void {
        var it = e.paths.valueIterator();
        while (it.next()) |p| e.gpa.free(p.*);
        e.paths.deinit(e.gpa);
        e.handles.deinit(e.gpa);
        e.clearOrders();
        e.orders.deinit(e.gpa);
        e.parents.deinit(e.gpa);
    }

    fn clearOrders(e: *Encoder) void {
        var it = e.orders.valueIterator();
        while (it.next()) |l| l.deinit(e.gpa);
        e.orders.clearRetainingCapacity();
        e.parents.clearRetainingCapacity();
    }

    /// The renderer appended `h` to its parent's order (a `new` line).
    fn appended(e: *Encoder, h: Handle, parent: Handle) !void {
        try e.parents.put(e.gpa, h, parent);
        try e.orders.put(e.gpa, h, .empty);
        if (e.orders.getPtr(parent)) |l| try l.append(e.gpa, h);
    }

    /// The renderer dropped `h` (a `delete` line, or under one).
    fn dropped(e: *Encoder, h: Handle) void {
        if (e.parents.fetchRemove(h)) |kv| if (e.orders.getPtr(kv.value)) |l| {
            if (std.mem.indexOfScalar(Handle, l.items, h)) |i| _ = l.orderedRemove(i);
        };
        if (e.orders.fetchRemove(h)) |kv| {
            var l = kv.value;
            l.deinit(e.gpa);
        }
    }

    /// `set PATH order=...` if the tree's order for `h` isn't the one the
    /// renderer has.
    fn fixOrder(e: *Encoder, a: Allocator, st: *const State, h: Handle, w: *Writer) !void {
        const n = st.node(h) orelse return;
        const l = e.orders.getPtr(h) orelse return;
        if (std.mem.eql(Handle, l.items, n.order.items)) return;
        const path = e.paths.get(h) orelse return;
        try w.writeAll("set ");
        try tokenize.quoteWord(w, path);
        var bodies: Bodies = .{};
        try bodies.attr(a, w, "order", try orderText(a, st, n));
        try w.writeByte('\n');
        l.clearRetainingCapacity();
        try l.appendSlice(e.gpa, n.order.items);
    }

    pub fn lookup(e: *Encoder, path: []const u8) ?Handle {
        return e.handles.get(path);
    }

    fn remember(e: *Encoder, h: Handle, path: []const u8) !void {
        if (e.paths.get(h) != null) return;
        // A new node at an old path (a `tree` rewrite) takes the path over.
        if (e.handles.fetchRemove(path)) |old| {
            if (e.paths.fetchRemove(old.value)) |kv| e.gpa.free(kv.value);
        }
        const p = try e.gpa.dupe(u8, path);
        try e.paths.put(e.gpa, h, p);
        try e.handles.put(e.gpa, p, h);
    }

    fn forget(e: *Encoder, h: Handle) void {
        const kv = e.paths.fetchRemove(h) orelse return;
        if (e.handles.get(kv.value)) |cur| if (cur == h) {
            _ = e.handles.remove(kv.value);
        };
        e.gpa.free(kv.value);
    }

    // -----------------------------------------------------------------
    // Snapshot

    /// The whole committed tree, for a renderer that just attached or fell
    /// behind: `snap N` ... `end N`. Resets the path maps from the state.
    pub fn snapshot(e: *Encoder, c: *abi.Core, w: *Writer) !void {
        var arena: std.heap.ArenaAllocator = .init(e.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const st = c.state();
        e.clearOrders();
        try w.print("snap {d}\n", .{e.seq});
        try theme(c, w);
        for (st.wins.items) |win| {
            if (win.hidden) continue;
            try windowLine(st, win, w);
            var all: std.ArrayList(Handle) = .empty;
            try st.subtree(a, win.root, &all);
            for (all.items) |h| {
                const n = st.node(h) orelse continue;
                if (n.kind == .over) continue;
                const path = try fullPath(a, st, h);
                try e.remember(h, path);
                try nodeLine(a, n, path, w);
                try e.appended(h, n.parent);
            }
            for (all.items) |h| try e.fixOrder(a, st, h, w);
            for (win.open.items) |h| try w.print("overlay open {s}\n", .{e.paths.get(h) orelse continue});
            if (win.focus != 0) try w.print("focus {s} {s}\n", .{ win.nameStr(), e.paths.get(win.focus) orelse "-" });
        }
        try w.print("end {d}\n", .{e.seq});
    }

    // -----------------------------------------------------------------
    // Batch

    /// What one pump changed, or nothing if it changed nothing a renderer
    /// draws. `x.t=` is CLOCK_MONOTONIC at the encode, in ns, for the
    /// spike's latency numbers.
    pub fn batch(e: *Encoder, c: *abi.Core, ch: *const abi.UitChanges, t_ns: u64, w: *Writer) !bool {
        const created = many(Handle, ch.created, ch.n_created);
        const removed = many(Handle, ch.removed, ch.n_removed);
        const props = many(abi.UitPropChange, ch.props, ch.n_props);
        const cmds = many(abi.UitHostCmd, ch.cmds, ch.n_cmds);
        if (created.len == 0 and removed.len == 0 and props.len == 0 and cmds.len == 0) return false;

        var arena: std.heap.ArenaAllocator = .init(e.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const st = c.state();

        try w.print("batch {d} x.t={d}\n", .{ e.seq, t_ns });

        // Windows first: a node line names its window.
        for (cmds) |hc| if (hc.tag == abi.UIT_CMD_WINDOW) {
            if (st.win(hc.win.slice())) |win| try windowLine(st, win, w);
        };

        // Deletes: only the top of each removed subtree.
        var gone: std.AutoHashMapUnmanaged(Handle, void) = .empty;
        for (removed) |h| try gone.put(a, h, {});
        for (removed) |h| {
            const p = e.paths.get(h) orelse continue;
            if (!underRemoved(e, &gone, h, p)) try w.print("delete {s}\n", .{p});
        }
        for (removed) |h| {
            e.dropped(h);
            e.forget(h);
        }

        // News, parents first (the order the tree made them in).
        var made: std.AutoHashMapUnmanaged(Handle, void) = .empty;
        var reorder: std.AutoArrayHashMapUnmanaged(Handle, void) = .empty;
        for (created) |h| {
            const n = st.node(h) orelse continue;
            if (n.kind == .over) continue;
            const path = try fullPath(a, st, h);
            try e.remember(h, path);
            try nodeLine(a, n, path, w);
            try e.appended(h, n.parent);
            try made.put(a, h, {});
            try reorder.put(a, n.parent, {});
        }

        // Sets: one line per node, its changed files as attributes.
        var by_node: std.AutoArrayHashMapUnmanaged(Handle, std.ArrayList([]const u8)) = .empty;
        for (props) |pc| {
            if (made.contains(pc.node)) continue;
            const f = pc.file.slice();
            if (std.mem.eql(u8, f, "order")) {
                try reorder.put(a, pc.node, {});
                continue;
            }
            const gop = try by_node.getOrPut(a, pc.node);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, f);
        }
        var bodies: Bodies = .{};
        for (by_node.keys(), by_node.values()) |h, files| {
            const n = st.node(h) orelse continue;
            const path = e.paths.get(h) orelse continue;
            try w.writeAll("set ");
            try tokenize.quoteWord(w, path);
            var style: ?[]const u8 = null;
            for (files.items) |f| {
                if (std.mem.eql(u8, f, "style")) {
                    style = n.value("style");
                    continue;
                }
                try bodies.attr(a, w, f, try propValue(a, c, st, n, f));
            }
            if (style) |s| {
                try w.writeAll(" :");
                if (s.len > 0) {
                    try w.writeByte(' ');
                    try w.writeAll(std.mem.trim(u8, s, " \t\r\n"));
                }
            }
            try bodies.flush(w);
            try w.writeByte('\n');
        }
        // Orders last, once every new and delete is in: only where the
        // tree's isn't what those imply. A removed child's parent comes
        // through as an `order` prop change.
        for (created) |h| try reorder.put(a, h, {});
        for (reorder.keys()) |h| try e.fixOrder(a, st, h, w);

        // Host commands, in order.
        for (cmds) |hc| try e.cmdLine(c, st, &hc, w);

        try w.print("end {d}\n", .{e.seq});
        return true;
    }

    fn cmdLine(e: *Encoder, c: *abi.Core, st: *const State, hc: *const abi.UitHostCmd, w: *Writer) !void {
        const win = hc.win.slice();
        switch (hc.tag) {
            abi.UIT_CMD_WINDOW => {}, // above
            abi.UIT_CMD_WINDOW_CTL => {
                try w.print("window-ctl {s} ", .{win});
                try ctlWords(w, &hc.ctl);
                try w.writeByte('\n');
            },
            abi.UIT_CMD_QUIT => try w.writeAll("quit\n"),
            abi.UIT_CMD_MENUS => try w.writeAll("menus\n"),
            abi.UIT_CMD_KEYMAP => try w.writeAll("keys\n"),
            abi.UIT_CMD_THEME => try theme(c, w),
            abi.UIT_CMD_SET_ACTION => try w.print("action {s} enabled={d} check={d}\n", .{ hc.name.slice(), hc.flag, hc.flag2 }),
            abi.UIT_CMD_OVERLAY => try w.print("overlay {s} {s}\n", .{ if (hc.flag == 1) "open" else "close", e.paths.get(hc.node) orelse "-" }),
            abi.UIT_CMD_FOCUS => try w.print("focus {s} {s}\n", .{ win, e.paths.get(hc.node) orelse "-" }),
            abi.UIT_CMD_CLIPBOARD => try w.writeAll("clip\n"),
            abi.UIT_CMD_COMPONENT_VERB => {
                try w.print("verb {s} ", .{e.paths.get(hc.node) orelse "-"});
                try ctlWords(w, &hc.ctl);
                try w.writeByte('\n');
            },
            abi.UIT_CMD_ANSWER => {
                if (e.requests.fetchRemove(hc.seq)) |kv| {
                    defer e.gpa.free(kv.value);
                    try w.writeAll("answer ");
                    try tokenize.quoteWord(w, kv.value);
                    try w.writeByte(' ');
                } else try w.print("answer {d} ", .{hc.seq});
                try tokenize.quoteWord(w, hc.answer.slice());
                try w.writeByte('\n');
            },
            abi.UIT_CMD_REDRAW => try w.print("redraw {s}\n", .{win}),
            abi.UIT_CMD_THEME_LOAD => {
                try w.writeAll("theme-load ");
                try tokenize.quoteWord(w, hc.name.slice());
                try w.writeByte('\n');
            },
            abi.UIT_CMD_ASSETS => {
                try w.writeAll("asset ");
                try tokenize.quoteWord(w, hc.name.slice());
                try w.writeByte('\n');
            },
            else => {},
        }
        _ = st;
    }
};

fn many(comptime T: type, p: ?[*]const T, n: usize) []const T {
    if (n == 0) return &.{};
    return (p orelse return &.{})[0..n];
}

fn underRemoved(e: *Encoder, gone: *std.AutoHashMapUnmanaged(Handle, void), self: Handle, path: []const u8) bool {
    var it = gone.keyIterator();
    while (it.next()) |g| {
        if (g.* == self) continue;
        const gp = e.paths.get(g.*) orelse continue;
        if (path.len > gp.len and std.mem.startsWith(u8, path, gp) and path[gp.len] == '/') return true;
    }
    return false;
}

fn fullPath(a: Allocator, st: *const State, h: Handle) ![]u8 {
    var aw: Writer.Allocating = .init(a);
    st.fullPath(&aw.writer, h) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn ctlWords(w: *Writer, c: *const abi.UitCtl) !void {
    try tokenize.quoteWord(w, c.verb.slice());
    for (many(abi.UitStr, c.args, c.n_args)) |x| {
        try w.writeByte(' ');
        try tokenize.quoteWord(w, x.slice());
    }
    for (many(abi.UitAttr, c.attrs, c.n_attrs)) |x| {
        try w.print(" {s}=", .{x.name.slice()});
        try tokenize.quoteValue(w, x.value.slice());
    }
}

/// Here-values for one line: attributes print `key=<<END` and the bodies
/// follow the line, in order.
const Bodies = struct {
    list: [16][]const u8 = undefined,
    markers: [16][24]u8 = undefined,
    mlen: [16]usize = undefined,
    n: usize = 0,

    fn attr(b: *Bodies, a: Allocator, w: *Writer, key: []const u8, v: []const u8) !void {
        _ = a;
        try w.print(" {s}=", .{key});
        if (ctl.hasNewline(v) and b.n < b.list.len) {
            const m = ctl.markerFor(&b.markers[b.n], v, b.n);
            // markerFor may return a static string; keep a copy.
            @memcpy(b.markers[b.n][0..m.len], m);
            b.mlen[b.n] = m.len;
            try w.print("<<{s}", .{m});
            b.list[b.n] = v;
            b.n += 1;
        } else try tokenize.quoteValue(w, v);
    }

    fn flush(b: *Bodies, w: *Writer) !void {
        for (0..b.n) |i| try ctl.writeBody(w, b.list[i], b.markers[i][0..b.mlen[i]]);
        b.n = 0;
    }
};

/// A file's value as uit_prop reads it, empty when unset.
fn propValue(a: Allocator, c: *abi.Core, st: *const State, n: *const Node, f: []const u8) ![]const u8 {
    if (std.mem.eql(u8, f, "order")) return orderText(a, st, n);
    var out: abi.UitStr = .{};
    const r = uit.uit_prop(c, n.id, abi.UitStr.of(f), &out);
    if (r != 1) return "";
    return a.dupe(u8, out.slice());
}

fn orderText(a: Allocator, st: *const State, n: *const Node) ![]const u8 {
    var aw: Writer.Allocating = .init(a);
    for (n.order.items, 0..) |ch, i| {
        if (i > 0) try aw.writer.writeByte(' ');
        try aw.writer.writeAll((st.node(ch) orelse continue).nameStr());
    }
    return aw.toOwnedSlice();
}

/// `window NAME prop=value ...`: the window's own props and state.
fn windowLine(st: *const State, win: *const treem.state.Win, w: *Writer) !void {
    try w.writeAll("window ");
    try tokenize.quoteWord(w, win.nameStr());
    if (win.title) |t| {
        try w.writeAll(" title=");
        try tokenize.quoteValue(w, t.bytes);
    }
    for (win.props.items) |p| {
        try w.print(" {s}=", .{p.key});
        try tokenize.quoteValue(w, p.val.bytes);
    }
    try w.print(" state={s}\n", .{@tagName(win.shownState())});
    _ = st;
}

fn isFlag(ty: *const types.Type, name: []const u8) bool {
    const x = ty.word(name) orelse return false;
    return x.kind == .flag;
}

const Item = struct { first: u32, word: ?[]const u8 = null, key: []const u8 = "", val: []const u8 = "" };

fn byFirst(_: void, x: Item, y: Item) bool {
    return x.first < y.first;
}

/// `new TYPE PATH words props : style`: one node, as tree/doc.zig prints
/// it in a document. Like `new` on a `ctl`, it appends the node to its
/// parent's order; `order` itself comes as a `set` when it differs.
fn nodeLine(a: Allocator, n: *const Node, path: []const u8, w: *Writer) !void {
    var items: std.ArrayList(Item) = .empty;
    var style: []const u8 = "";
    for (n.words.items) |x| try items.append(a, .{ .first = x.first, .word = x.name });
    for (n.files.items) |f| {
        const v = f.val.bytes;
        if (std.mem.eql(u8, f.name, "style")) {
            style = std.mem.trim(u8, v, " \t\r\n");
            continue;
        }
        if (std.mem.eql(u8, f.name, "order")) continue;
        if (treem.state.commonName(f.name) != null) {
            if (v.len > 0) try items.append(a, .{ .first = f.first, .key = f.name, .val = v });
            continue;
        }
        const p = n.ty.prop(f.name) orelse continue;
        if (p.readonly or treem.doc.isDefault(p, v)) continue;
        if (p.form == .bool and std.mem.eql(u8, v, "on") and isFlag(n.ty, f.name)) {
            try items.append(a, .{ .first = f.first, .word = f.name });
        } else try items.append(a, .{ .first = f.first, .key = f.name, .val = v });
    }
    std.mem.sort(Item, items.items, {}, byFirst);

    try w.writeAll("new ");
    try tokenize.quoteWord(w, n.ty.name);
    try w.writeByte(' ');
    try tokenize.quoteWord(w, path);
    for (items.items) |x| if (x.word) |word| {
        try w.writeByte(' ');
        try tokenize.quoteWord(w, word);
    };
    var bodies: Bodies = .{};
    for (items.items) |x| if (x.word == null) try bodies.attr(a, w, x.key, x.val);
    if (style.len > 0) {
        try w.writeAll(" : ");
        try w.writeAll(style);
    }
    try bodies.flush(w);
    try w.writeByte('\n');
}

/// `theme mode=light|dark tokens=<<END`: every token's value for the mode
/// in effect, as theme/tokens reads. Styles stay as written and the
/// renderer resolves names through this table, so a theme switch is one
/// record instead of every node's style again.
fn theme(c: *abi.Core, w: *Writer) !void {
    var aw: Writer.Allocating = .init(c.gpa);
    defer aw.deinit();
    for (c.cat.theme_tokens) |t| try tokenLine(c, &aw.writer, t.name);
    for (types.style.value_tokens) |t| try tokenLine(c, &aw.writer, t.name);
    const body = std.mem.trimEnd(u8, aw.written(), "\n");
    try w.print("theme mode={s} tokens=<<END", .{if (uit.uit_theme_dark(c) == 1) "dark" else "light"});
    try ctl.writeBody(w, body, "END");
    try w.writeByte('\n');
}

fn tokenLine(c: *abi.Core, w: *Writer, name: []const u8) !void {
    var out: abi.UitStr = .{};
    if (uit.uit_token_text(c, abi.UitStr.of(name), &out) != 1) return;
    try w.print("{s} ", .{name});
    try tokenize.quote(w, out.slice());
    try w.writeByte('\n');
}
