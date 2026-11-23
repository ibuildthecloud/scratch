//! uitree-remote: the 9P renderer spike (protocols/render.md). The core
//! with no renderer of its own: it serves `$ui` to the app as usual, and a
//! second 9P tree, the renderer tree, to any renderer that dials it.
//!
//!     uitree-remote -R ADDR [-r ROOT] CMD [ARG...]
//!
//! PROTOTYPE. It is a renderer over uitcore.h: an owner thread that pumps
//! when the core wakes it, encodes each pump once (stream.zig) and fans
//! the bytes out to every attached renderer's `changes`. Lines written to
//! `input` become the same uit_* input calls a built-in renderer makes.
//!
//! The renderer tree:
//!
//!     version     `uitree-render 0.1`
//!     hello       write `hello name=N role=primary|mirror|view`
//!     renderers   one line per attached renderer
//!     changes     a snapshot, then batches, as one stream per open
//!     input       lines: /debug/inject's grammar, plus request and closed
//!     stats       pump and encode times, for the spike's numbers

const std = @import("std");
const core = @import("uitcore");
const stream = @import("stream.zig");
const uit = @import("uit.zig");

const abi = core.abi;
const ninep = core.ninep;
const proto = core.proto;
const fsmod = ninep.fs;
const debug = ninep.debug;
const Err = fsmod.Err;
const ConnId = fsmod.ConnId;
const Allocator = std.mem.Allocator;
const UitStr = abi.UitStr;

const usage = "usage: uitree-remote -R ADDR [-a ADDR] [-r ROOT] [CMD [ARG...]]\n";

/// Past this many unread bytes a renderer is too slow: its queue is
/// dropped and it gets a fresh snapshot instead (render.md § Resync).
const max_queue = 4 << 20;

const Role = enum { none, primary, mirror, view };

const Renderer = struct {
    conn: ConnId,
    name: []u8 = &.{},
    role: Role = .none,
};

const Sub = struct {
    r: *Remote,
    conn: ConnId,
    buf: std.ArrayList(u8) = .empty,
    off: usize = 0,
    need_snap: bool = true,
    closed: bool = false,
    intr: bool = false,
    resyncs: u32 = 0,
};

const Job = struct {
    conn: ConnId,
    line: []const u8,
    err: *Err,
    failed: bool = false,
    done: bool = false,
    next: ?*Job = null,
};

const Stats = struct {
    pumps: u64 = 0,
    batches: u64 = 0,
    bytes: u64 = 0,
    pump_ns: std.ArrayList(u64) = .empty,
    enc_ns: std.ArrayList(u64) = .empty,
    snaps: u64 = 0,
    snap_bytes: u64 = 0,
    snap_ns: u64 = 0,
};

const Remote = struct {
    gpa: Allocator,
    io: std.Io,
    c: *abi.Core = undefined,
    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    woken: bool = false,
    jobs: ?*Job = null,
    jobs_tail: ?*Job = null,
    subs: std.ArrayList(*Sub) = .empty,
    renderers: std.ArrayList(Renderer) = .empty,
    next_conn: std.atomic.Value(u64) = .init(1),
    finished: bool = false,
    enc: stream.Encoder,
    stats: Stats = .{},

    fn lock(r: *Remote) void {
        r.mu.lockUncancelable(r.io);
    }
    fn unlock(r: *Remote) void {
        r.mu.unlock(r.io);
    }

    fn wake(ctx: ?*anyopaque) callconv(.c) void {
        const r: *Remote = @ptrCast(@alignCast(ctx.?));
        r.lock();
        r.woken = true;
        r.cond.broadcast(r.io);
        r.unlock();
    }

    fn rendererOf(r: *Remote, conn: ConnId) ?*Renderer {
        for (r.renderers.items) |*x| if (x.conn == conn) return x;
        return null;
    }

    fn hasPrimary(r: *Remote) bool {
        for (r.renderers.items) |x| if (x.role == .primary) return true;
        return false;
    }

    // ---------------------------------------------------------------
    // The owner thread

    fn ownerLoop(r: *Remote) !void {
        var out: std.Io.Writer.Allocating = .init(r.gpa);
        defer out.deinit();
        while (true) {
            r.lock();
            while (!r.woken and r.jobs == null and !r.snapWanted()) r.cond.waitUncancelable(r.io, &r.mu);
            r.woken = false;
            const jobs = r.jobs;
            r.jobs = null;
            r.jobs_tail = null;
            r.unlock();

            // Input first: each is a uit_* input call, queued for this pump.
            var j = jobs;
            while (j) |x| : (j = x.next) r.apply(x) catch |e| {
                x.failed = true;
                if (e == error.OutOfMemory) x.err.note("out of memory");
            };

            const t0 = now();
            var ch: abi.UitChanges = .{};
            _ = uit.uit_pump(r.c, &ch);
            const t1 = now();
            out.clearRetainingCapacity();
            r.enc.seq += 1;
            const any = try r.enc.batch(r.c, &ch, t1, &out.writer);
            if (ch.exited == 1) {
                try out.writer.writeAll("exit ");
                try proto.tokenize.quoteWord(&out.writer, ch.exit_status.slice());
                try out.writer.writeByte('\n');
            }
            const t2 = now();
            r.stats.pumps += 1;
            if (any) {
                r.stats.batches += 1;
                r.stats.bytes += out.written().len;
                try r.stats.pump_ns.append(r.gpa, t1 - t0);
                try r.stats.enc_ns.append(r.gpa, t2 - t1);
            }

            // Snapshots for renderers that just attached (or fell behind),
            // as of this pump, so the next batch follows on.
            var snap: ?[]u8 = null;
            defer if (snap) |s| r.gpa.free(s);
            r.lock();
            const want = r.snapWanted();
            r.unlock();
            if (want) {
                const ts = now();
                var sw: std.Io.Writer.Allocating = .init(r.gpa);
                try r.enc.snapshot(r.c, &sw.writer);
                snap = try sw.toOwnedSlice();
                r.stats.snaps += 1;
                r.stats.snap_bytes = snap.?.len;
                r.stats.snap_ns = now() - ts;
            }

            r.lock();
            for (r.subs.items) |s| {
                if (s.need_snap) {
                    if (snap) |b| {
                        s.buf.clearRetainingCapacity();
                        s.off = 0;
                        try s.buf.appendSlice(r.gpa, b);
                        s.need_snap = false;
                    }
                } else if (out.written().len > 0) {
                    if (s.buf.items.len - s.off + out.written().len > max_queue) {
                        s.need_snap = true;
                        s.resyncs += 1;
                        r.woken = true;
                    } else try s.buf.appendSlice(r.gpa, out.written());
                }
            }
            var k = jobs;
            while (k) |x| : (k = x.next) x.done = true;
            if (ch.exited == 1) r.finished = true;
            r.cond.broadcast(r.io);
            r.unlock();
            if (ch.exited == 1) return;
        }
    }

    fn snapWanted(r: *Remote) bool {
        for (r.subs.items) |s| if (s.need_snap) return true;
        return false;
    }

    fn node(r: *Remote, win: ?[]const u8, path: ?[]const u8, err: *Err) !abi.UitNode {
        const w = win orelse "main";
        const p = path orelse ".";
        var buf: [512]u8 = undefined;
        const full = if (std.mem.eql(u8, p, "."))
            std.fmt.bufPrint(&buf, "win/{s}", .{w}) catch return err.set("bad value: path too long")
        else
            std.fmt.bufPrint(&buf, "win/{s}/{s}", .{ w, p }) catch return err.set("bad value: path too long");
        return r.enc.lookup(full) orelse err.print("not found: {s}", .{full});
    }

    fn check(r: *Remote, rc: c_int, err: *Err) !void {
        if (rc >= 0) return;
        return err.set(uit.uit_last_error(r.c).slice());
    }

    /// One `input` line, on the owner thread.
    fn apply(r: *Remote, j: *Job) !void {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const err = j.err;
        r.lock();
        const role: Role = if (r.rendererOf(j.conn)) |x| x.role else .none;
        r.unlock();
        if (role == .view) return err.set("permission denied: a view renderer sends no input");
        // A connection that never said hello is a mirror.
        const primary = role == .primary;

        const c = proto.ctl.parse(a, j.line) catch return err.set("bad syntax");
        if (std.mem.eql(u8, c.verb, "request")) {
            if (c.words.len != 1) return err.set("bad syntax: request NAME win= node= id= default=");
            const h = try r.node(c.attr("win"), c.attr("node"), err);
            const id = c.attr("id") orelse return err.set("bad syntax: request needs id=");
            const seq = uit.uit_request(r.c, h, UitStr.of(c.words[0]), null, 0, UitStr.of(c.attr("default") orelse ""));
            if (seq != 0) try r.enc.requests.put(r.gpa, seq, try r.gpa.dupe(u8, id));
            return;
        }
        if (std.mem.eql(u8, c.verb, "closed")) {
            if (!primary) return;
            return r.check(uit.uit_window_closed(r.c, UitStr.of(c.attr("win") orelse "main")), err);
        }

        const inj = try debug.parse(a, j.line, err);
        switch (inj) {
            .event => |ev| {
                const h = try r.node(ev.win, ev.node, err);
                const attrs = try a.alloc(abi.UitAttr, ev.attrs.len);
                for (ev.attrs, attrs) |x, *y| y.* = .{ .name = UitStr.of(x.key), .value = UitStr.of(x.value) };
                try r.check(uit.uit_emit(r.c, h, UitStr.of(ev.name), attrs.ptr, attrs.len), err);
            },
            .mirror => |m| {
                const h = try r.node(m.win, m.node, err);
                try r.check(uit.uit_mirror(r.c, h, UitStr.of(m.file), UitStr.of(m.value)), err);
            },
            // Layout and frames belong to the primary: a mirror lays out
            // for itself and its numbers aren't the app's.
            .bounds => |b| {
                if (!primary) return;
                const h = try r.node(b.win, b.node, err);
                try r.check(uit.uit_bounds(r.c, h, b.x, b.y, b.w, b.h), err);
            },
            .frame => |f| {
                if (!primary) return;
                try r.check(uit.uit_frame_drawn(r.c, UitStr.of(f.win orelse "main")), err);
            },
            .key => |k| try r.check(uit.uit_key(r.c, UitStr.of(k.win), UitStr.of(k.stroke), 0), err),
            .menu => |m| try r.check(uit.uit_menu_action(r.c, UitStr.of(m.item)), err),
            .appearance => |ap| {
                if (!primary) return;
                try r.check(uit.uit_system_dark(r.c, @intFromBool(ap.dark)), err);
            },
            .tick, .drag => return err.set("unsupported: not in the spike"),
        }
    }
};

fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// -------------------------------------------------------------------
// The renderer tree, as an Fs

const files = [_][]const u8{ "version", "hello", "renderers", "changes", "input", "stats" };

fn entryOf(name: []const u8) ?fsmod.Entry {
    for (files, 0..) |f, i| if (std.mem.eql(u8, f, name)) {
        const kind: fsmod.Kind = if (std.mem.eql(u8, f, "changes")) .stream else .file;
        const perm: u32 = if (std.mem.eql(u8, f, "input") or std.mem.eql(u8, f, "hello")) 0o222 else 0o444;
        return .{ .kind = kind, .qid = 0x7265_6e64_0000_0010 + i, .perm = perm };
    };
    return null;
}

const RenderFs = struct {
    r: *Remote,

    fn fs(x: *RenderFs) fsmod.Fs {
        return .{ .ptr = x, .vt = &vt };
    }

    const vt: fsmod.Fs.VTable = .{
        .connect = connect,
        .disconnect = disconnect,
        .stat = stat,
        .list = list,
        .open = open,
        .read = read,
        .commit = commit,
        .line = line,
        .create = create,
        .remove = remove,
    };

    fn self(p: *anyopaque) *Remote {
        const x: *RenderFs = @ptrCast(@alignCast(p));
        return x.r;
    }

    fn connect(p: *anyopaque) ConnId {
        const r = self(p);
        const id = r.next_conn.fetchAdd(1, .monotonic);
        r.lock();
        defer r.unlock();
        r.renderers.append(r.gpa, .{ .conn = id }) catch {};
        return id;
    }

    fn disconnect(p: *anyopaque, conn: ConnId) void {
        const r = self(p);
        r.lock();
        defer r.unlock();
        for (r.renderers.items, 0..) |x, i| if (x.conn == conn) {
            r.gpa.free(x.name);
            _ = r.renderers.orderedRemove(i);
            break;
        };
    }

    fn stat(_: *anyopaque, _: ConnId, path: []const u8) ?fsmod.Entry {
        if (path.len == 0) return .{ .kind = .dir, .qid = 0x7265_6e64_0000_0001, .perm = 0o555 };
        return entryOf(path);
    }

    fn list(_: *anyopaque, _: ConnId, path: []const u8, arena: Allocator, err: *Err) fsmod.Error![]const fsmod.DirEnt {
        if (path.len != 0) return err.set("not found");
        const out = try arena.alloc(fsmod.DirEnt, files.len);
        for (files, out) |f, *d| d.* = .{ .name = f, .entry = entryOf(f).? };
        return out;
    }

    fn open(p: *anyopaque, conn: ConnId, path: []const u8, mode: fsmod.OpenMode, err: *Err) fsmod.Error!fsmod.Opened {
        const r = self(p);
        const e = entryOf(path) orelse return err.set("not found");
        if (mode.write and e.perm & 0o222 == 0) return err.set("permission denied: read-only");
        if (mode.read and e.perm & 0o444 == 0) return err.set("permission denied: write-only");
        if (std.mem.eql(u8, path, "input")) return .{ .write_mode = .lines };
        if (std.mem.eql(u8, path, "changes")) {
            const s = try r.gpa.create(Sub);
            s.* = .{ .r = r, .conn = conn };
            r.lock();
            defer r.unlock();
            r.subs.append(r.gpa, s) catch return error.OutOfMemory;
            r.woken = true;
            r.cond.broadcast(r.io);
            return .{ .stream = .{ .ptr = s, .vt = &sub_vt } };
        }
        return .{};
    }

    fn read(p: *anyopaque, _: ConnId, path: []const u8, arena: Allocator, err: *Err) fsmod.Error![]const u8 {
        const r = self(p);
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        if (std.mem.eql(u8, path, "version")) {
            w.writeAll("uitree-render 0.1\n") catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, path, "renderers")) {
            r.lock();
            defer r.unlock();
            for (r.renderers.items) |x| {
                if (x.role == .none) continue;
                w.print("{s} {t}\n", .{ x.name, x.role }) catch return error.OutOfMemory;
            }
        } else if (std.mem.eql(u8, path, "stats")) {
            r.lock();
            defer r.unlock();
            const s = &r.stats;
            w.print("pumps {d}\nbatches {d}\nbytes {d}\n", .{ s.pumps, s.batches, s.bytes }) catch return error.OutOfMemory;
            w.print("snapshots {d} last_bytes={d} last_us={d}\n", .{ s.snaps, s.snap_bytes, s.snap_ns / 1000 }) catch return error.OutOfMemory;
            pct(w, "pump", s.pump_ns.items) catch return error.OutOfMemory;
            pct(w, "encode", s.enc_ns.items) catch return error.OutOfMemory;
            for (r.subs.items) |x| if (x.resyncs > 0) w.print("resyncs conn={d} n={d}\n", .{ x.conn, x.resyncs }) catch return error.OutOfMemory;
        } else return err.set("permission denied: write-only");
        return aw.written();
    }

    fn commit(p: *anyopaque, conn: ConnId, path: []const u8, _: u64, data: []const u8, err: *Err) fsmod.Error!void {
        const r = self(p);
        if (!std.mem.eql(u8, path, "hello")) return;
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        const c = proto.ctl.parse(arena.allocator(), std.mem.trim(u8, data, " \t\r\n")) catch return err.set("bad syntax");
        if (!std.mem.eql(u8, c.verb, "hello")) return err.set("bad syntax: hello name=N role=R");
        const name: []const u8 = c.attr("name") orelse "renderer";
        const rs = c.attr("role") orelse "mirror";
        const role = std.meta.stringToEnum(Role, rs) orelse return err.print("bad value: {s}", .{rs});
        r.lock();
        defer r.unlock();
        const x = r.rendererOf(conn) orelse return err.set("gone");
        if (role == .primary and x.role != .primary and r.hasPrimary()) return err.set("in use: a primary is attached");
        r.gpa.free(x.name);
        x.name = r.gpa.dupe(u8, name) catch return error.OutOfMemory;
        x.role = role;
    }

    fn line(p: *anyopaque, conn: ConnId, _: []const u8, l: []const u8, err: *Err) fsmod.Error!void {
        const r = self(p);
        const copy = r.gpa.dupe(u8, l) catch return error.OutOfMemory;
        defer r.gpa.free(copy);
        var job: Job = .{ .conn = conn, .line = copy, .err = err };
        r.lock();
        defer r.unlock();
        if (r.finished) return err.set("app gone");
        if (r.jobs_tail) |t| t.next = &job else r.jobs = &job;
        r.jobs_tail = &job;
        r.cond.broadcast(r.io);
        while (!job.done) r.cond.waitUncancelable(r.io, &r.mu);
        if (job.failed) return error.Failed;
    }

    fn create(_: *anyopaque, _: ConnId, _: []const u8, _: []const u8, _: bool, err: *Err) fsmod.Error!fsmod.Entry {
        return err.set("permission denied");
    }
    fn remove(_: *anyopaque, _: ConnId, _: []const u8, err: *Err) fsmod.Error!void {
        return err.set("permission denied");
    }
};

fn pct(w: *std.Io.Writer, name: []const u8, xs: []const u64) !void {
    if (xs.len == 0) return;
    const s = try std.heap.c_allocator.dupe(u64, xs);
    defer std.heap.c_allocator.free(s);
    std.mem.sort(u64, s, {}, std.sort.asc(u64));
    const at = struct {
        fn f(v: []const u64, q: f64) f64 {
            const i: usize = @intFromFloat(@as(f64, @floatFromInt(v.len - 1)) * q);
            return @as(f64, @floatFromInt(v[i])) / 1000.0;
        }
    }.f;
    try w.print("{s}_us n={d} p50={d:.1} p90={d:.1} max={d:.1}\n", .{ name, s.len, at(s, 0.5), at(s, 0.9), at(s, 1.0) });
}

const sub_vt: fsmod.Stream.VTable = .{ .read = subRead, .interrupt = subInterrupt, .close = subClose };

fn subRead(p: *anyopaque, buf: []u8) error{Interrupted}!usize {
    const s: *Sub = @ptrCast(@alignCast(p));
    const r = s.r;
    r.lock();
    defer r.unlock();
    while (true) {
        if (s.intr) {
            s.intr = false;
            return error.Interrupted;
        }
        if (!s.need_snap and s.off < s.buf.items.len) {
            const n = @min(buf.len, s.buf.items.len - s.off);
            @memcpy(buf[0..n], s.buf.items[s.off..][0..n]);
            s.off += n;
            if (s.off == s.buf.items.len) {
                s.buf.clearRetainingCapacity();
                s.off = 0;
            }
            return n;
        }
        if (r.finished or s.closed) return 0;
        r.cond.waitUncancelable(r.io, &r.mu);
    }
}

fn subInterrupt(p: *anyopaque) void {
    const s: *Sub = @ptrCast(@alignCast(p));
    s.r.lock();
    defer s.r.unlock();
    s.intr = true;
    s.r.cond.broadcast(s.r.io);
}

fn subClose(p: *anyopaque) void {
    const s: *Sub = @ptrCast(@alignCast(p));
    const r = s.r;
    r.lock();
    for (r.subs.items, 0..) |x, i| if (x == s) {
        _ = r.subs.orderedRemove(i);
        break;
    };
    r.unlock();
    s.buf.deinit(r.gpa);
    r.gpa.destroy(s);
}

// -------------------------------------------------------------------

fn onConn(ctx: *anyopaque, conn: ninep.transport.Conn) void {
    const srv: *ninep.Server = @ptrCast(@alignCast(ctx));
    srv.serve(conn) catch {};
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var raddr: ?[]const u8 = null;
    var aaddr: ?[]const u8 = null;
    var root: []const u8 = "";
    if (init.environ_map.get("H9ROOT")) |v| root = v;
    var i: usize = 1;
    while (i + 1 < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 2) {
        if (std.mem.eql(u8, args[i], "-R")) raddr = args[i + 1] else if (std.mem.eql(u8, args[i], "-a")) aaddr = args[i + 1] else if (std.mem.eql(u8, args[i], "-r")) root = args[i + 1] else {
            std.debug.print(usage, .{});
            std.process.exit(2);
        }
    }
    const argv = args[i..];
    if (raddr == null or (argv.len == 0 and aaddr == null)) {
        std.debug.print(usage, .{});
        std.process.exit(2);
    }

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var r: Remote = .{ .gpa = gpa, .io = threaded.io(), .enc = .{ .gpa = gpa } };

    const cfg: abi.UitConfig = .{
        .abi_version = abi.abi_version,
        .types = .{},
        .style_words = .{},
        .theme_tokens = .{},
        .system_dark = 0,
        .wake = Remote.wake,
        .wake_ctx = &r,
    };
    var cp: ?*abi.Core = null;
    if (uit.uit_create(&cfg, &cp) != abi.UIT_OK) return error.Create;
    r.c = cp.?;
    _ = uit.uit_themes(r.c, UitStr.of(core.types.embedded.themes));

    var rfs: RenderFs = .{ .r = &r };
    var srv: ninep.Server = .init(gpa, r.io, rfs.fs());
    const l = try ninep.transport.listen(gpa, raddr.?);
    try l.start(&srv, onConn);
    std.debug.print("uitree-remote: renderers dial {s}\n", .{l.dial});

    // -a: also serve $ui on ADDR, for an app that runs on the host and
    // dials it (the latency bench's compiled client) instead of in h9.
    if (aaddr) |aa| {
        var dial: UitStr = .{};
        if (uit.uit_listen(r.c, UitStr.of(aa), &dial) != abi.UIT_OK) {
            std.debug.print("uitree-remote: listen {s}: {s}\n", .{ aa, uit.uit_last_error(r.c).slice() });
            return error.Listen;
        }
        std.debug.print("uitree-remote: apps dial {s}\n", .{dial.slice()});
    }
    if (argv.len == 0) {
        try r.ownerLoop();
        return;
    }

    const uargv = try init.arena.allocator().alloc(UitStr, argv.len);
    for (argv, uargv) |x, *y| y.* = UitStr.of(x);
    const margs: abi.UitMachineArgs = .{
        .prog = uargv[0],
        .argv = uargv.ptr,
        .argc = uargv.len,
        .root = UitStr.of(root),
        .cwd = .{},
        .dirs = null,
        .n_dirs = 0,
        .env = null,
        .n_env = 0,
        .h9_flags = null,
        .n_h9_flags = 0,
        .out_fd = -1,
        .err_fd = -1,
    };
    if (uit.uit_run_machine(r.c, &margs) != abi.UIT_OK) {
        std.debug.print("uitree-remote: {s}\n", .{uit.uit_last_error(r.c).slice()});
        return error.Machine;
    }
    try r.ownerLoop();
    // Let renderers read the last batch and the end of file.
    r.io.sleep(.fromMilliseconds(200), .awake) catch {};
    std.process.exit(0);
}
