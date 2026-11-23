#!/usr/bin/env python3
"""A toy uitree renderer in Python, over 9P (protocols/render.md).

PROTOTYPE, for the 9P renderer spike. It dials the renderer tree that
`uitree-remote -R ADDR` serves, says hello, reads `changes` (a snapshot,
then batches), keeps its own copy of the tree, "draws" each window as
indented text, lays every node out as one row and reports that layout as
`bounds`, and acks each frame.

    render.py ADDR [--name N] [--role primary|mirror|view] [--draw] [--bench N]

ADDR is `unix!PATH` or `tcp!HOST!PORT`. --bench N clicks the counter's
`inc` N times and prints how long each click took to come back as a
batch, split at the core's encode.

The standard library only: a 9P2000 client is about eighty lines.
"""

import socket, struct, sys, threading, time

# ---------------------------------------------------------------- 9P2000

NOFID = 0xFFFFFFFF
T = dict(version=100, attach=104, error=106, walk=110, open=112, read=116, write=118, clunk=120)


def s9(s):
    b = s.encode()
    return struct.pack("<H", len(b)) + b


class NineP:
    """A 9P2000 client with one reader thread, so a blocked read on one fid
    doesn't hold up writes on another."""

    def __init__(self, addr):
        if addr.startswith("unix!"):
            self.sk = socket.socket(socket.AF_UNIX)
            self.sk.connect(addr[5:])
        else:
            _, host, port = addr.split("!")
            self.sk = socket.create_connection((host, int(port)))
        self.mu = threading.Lock()
        self.wmu = threading.Lock()
        self.waiting = {}
        self.next_tag = 1
        self.next_fid = 1
        self.msize = 65536
        threading.Thread(target=self._reader, daemon=True).start()
        r = self.rpc(T["version"], struct.pack("<I", self.msize) + s9("9P2000"), tag=0xFFFF)
        self.msize = struct.unpack("<I", r[:4])[0]
        self.root = self.fid()
        self.rpc(T["attach"], struct.pack("<II", self.root, NOFID) + s9("toy") + s9(""))

    def fid(self):
        with self.mu:
            f = self.next_fid
            self.next_fid += 1
            return f

    def _recvn(self, n):
        b = b""
        while len(b) < n:
            x = self.sk.recv(n - len(b))
            if not x:
                raise EOFError
            b += x
        return b

    def _reader(self):
        try:
            while True:
                size = struct.unpack("<I", self._recvn(4))[0]
                body = self._recvn(size - 4)
                typ, tag = body[0], struct.unpack("<H", body[1:3])[0]
                with self.mu:
                    w = self.waiting.pop(tag)
                w[1] = (typ, body[3:])
                w[0].set()
        except (EOFError, OSError):
            with self.mu:
                for w in self.waiting.values():
                    w[1] = (T["error"], s9("hung up"))
                    w[0].set()

    def rpc(self, typ, payload, tag=None):
        ev = [threading.Event(), None]
        with self.mu:
            if tag is None:
                tag = self.next_tag
                self.next_tag = self.next_tag % 0xFFFE + 1
            self.waiting[tag] = ev
            msg = struct.pack("<IBH", 7 + len(payload), typ, tag) + payload
            self.sk.sendall(msg)
        ev[0].wait()
        rtyp, body = ev[1]
        if rtyp == T["error"] + 1:  # Rerror
            n = struct.unpack("<H", body[:2])[0]
            raise IOError(body[2:2 + n].decode())
        return body

    def open(self, path, mode):
        f = self.fid()
        names = [x for x in path.split("/") if x]
        p = struct.pack("<IIH", self.root, f, len(names)) + b"".join(s9(n) for n in names)
        self.rpc(T["walk"], p)
        self.rpc(T["open"], struct.pack("<IB", f, mode))
        return f

    def read(self, f, off, n):
        body = self.rpc(T["read"], struct.pack("<IQI", f, off, n))
        k = struct.unpack("<I", body[:4])[0]
        return body[4:4 + k]

    def write(self, f, off, data):
        """Writes all of data, in pieces that fit msize. One writer at a
        time: `input` takes lines that may span pieces, so two threads'
        pieces must not interleave."""
        step = self.msize - 24
        with self.wmu:
            for i in range(0, len(data), step):
                piece = data[i:i + step]
                self.rpc(T["write"], struct.pack("<IQI", f, off + i, len(piece)) + piece)
        return len(data)

    def clunk(self, f):
        self.rpc(T["clunk"], struct.pack("<I", f))

    def cat(self, path):
        f = self.open(path, 0)
        out, off = b"", 0
        while True:
            b = self.read(f, off, self.msize - 24)
            if not b:
                break
            out += b
            off += len(b)
        self.clunk(f)
        return out.decode()

    def put(self, path, text):
        f = self.open(path, 1)
        self.write(f, 0, text.encode())
        self.clunk(f)


# ---------------------------------------------------------------- the stream

def tokenize(line):
    """Plan 9 tokenize(2): blanks separate, '' quotes, '' inside is a quote."""
    out, i, n = [], 0, len(line)
    while i < n:
        while i < n and line[i] in " \t":
            i += 1
        if i >= n:
            break
        w = ""
        while i < n and line[i] not in " \t":
            if line[i] == "'":
                i += 1
                while i < n:
                    if line[i] == "'":
                        if i + 1 < n and line[i + 1] == "'":
                            w += "'"
                            i += 2
                            continue
                        i += 1
                        break
                    w += line[i]
                    i += 1
            else:
                w += line[i]
                i += 1
        out.append(w)
    return out


class Record:
    """One line of the stream: verb, words, attrs, style."""

    def __init__(self, toks):
        self.style = None
        if ":" in toks:
            k = toks.index(":")
            self.style = toks[k + 1:]
            toks = toks[:k]
        self.verb = toks[0] if toks else ""
        self.words, self.attrs = [], {}
        for t in toks[1:]:
            if "=" in t:
                a, v = t.split("=", 1)
                self.attrs[a] = v
            else:
                self.words.append(t)


class Stream:
    """Splits the `changes` bytes into records, with here-values."""

    def __init__(self):
        self.buf = ""
        self.pending = None  # (record, [(attr, marker)], lines)

    def feed(self, text):
        self.buf += text
        out = []
        while "\n" in self.buf:
            line, self.buf = self.buf.split("\n", 1)
            if self.pending:
                rec, heres, acc = self.pending
                if line == heres[0][1]:
                    rec.attrs[heres[0][0]] = "\n".join(acc)
                    heres.pop(0)
                    acc.clear()
                    if not heres:
                        out.append(rec)
                        self.pending = None
                else:
                    acc.append(line)
                continue
            rec = Record(tokenize(line))
            heres = [(a, v[2:]) for a, v in rec.attrs.items() if v.startswith("<<")]
            if heres:
                self.pending = (rec, heres, [])
            else:
                out.append(rec)
        return out


# ---------------------------------------------------------------- the renderer

class Tree:
    def __init__(self):
        self.reset()

    def reset(self):
        self.nodes = {}     # path -> dict(type, words, attrs, style)
        self.windows = {}   # name -> attrs
        self.overlays = {}  # win -> [path]
        self.tokens = {}
        self.mode = "light"

    def apply(self, r):
        v = r.verb
        if v == "window":
            self.windows.setdefault(r.words[0], {}).update(r.attrs)
        elif v == "new":
            ty, path = r.words[0], r.words[1]
            self.nodes[path] = dict(type=ty, words=r.words[2:], attrs=dict(r.attrs), style=r.style or [], order=[])
            # As on a ctl: a new node goes on the end of its parent's order.
            parent, _, name = path.rpartition("/")
            if parent in self.nodes:
                self.nodes[parent]["order"].append(name)
        elif v == "set":
            n = self.nodes.get(r.words[0])
            if n is None:
                return
            if "order" in r.attrs:
                n["order"] = r.attrs.pop("order").split()
            n["attrs"].update(r.attrs)
            if r.style is not None:
                n["style"] = r.style
        elif v == "delete":
            p = r.words[0]
            for k in [k for k in self.nodes if k == p or k.startswith(p + "/")]:
                del self.nodes[k]
            parent, _, name = p.rpartition("/")
            if parent in self.nodes and name in self.nodes[parent]["order"]:
                self.nodes[parent]["order"].remove(name)
        elif v == "overlay":
            win = r.words[1].split("/")[1]
            lst = self.overlays.setdefault(win, [])
            if r.words[0] == "open":
                lst.append(r.words[1])
            elif r.words[1] in lst:
                lst.remove(r.words[1])
        elif v == "theme":
            self.mode = r.attrs.get("mode", "light")
            self.tokens = dict(l.split(" ", 1) for l in r.attrs.get("tokens", "").split("\n") if " " in l)

    def walk(self, path, depth, out):
        n = self.nodes.get(path)
        if n is None:
            return
        out.append((path, depth, n))
        for c in n["order"]:
            self.walk(path + "/" + c, depth + 1, out)

    def layout(self, win):
        """Every node one row high, indented by depth: (path, x, y, w, h)."""
        rows = []
        self.walk("win/" + win, 0, rows)
        for o in self.overlays.get(win, []):
            self.walk(o, 1, rows)
        return [(p, d * 16, i * 20, 320 - d * 16, 20, n) for i, (p, d, n) in enumerate(rows)]

    def draw(self, win):
        w = self.windows.get(win, {})
        lines = ["+-- %s (%s, %s) --" % (w.get("title", win), w.get("size", "?"), self.mode)]
        for p, x, y, ww, h, n in self.layout(win):
            a = n["attrs"]
            label = a.get("text") or a.get("label") or a.get("value") or a.get("title") or ""
            lines.append("| " + " " * (x // 8) + "%s %s %s" % (n["type"], p.rsplit("/", 1)[-1], repr(label) if label else ""))
        return "\n".join(lines)


def rel(win, path):
    base = "win/" + win
    return "." if path == base else path[len(base) + 1:]


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    addr = args.pop(0)
    name, role, draw, bench, wait, once = "toy", "primary", False, 0, "win/main/inc", False
    while args:
        a = args.pop(0)
        if a == "--name":
            name = args.pop(0)
        elif a == "--role":
            role = args.pop(0)
        elif a == "--draw":
            draw = True
        elif a == "--bench":
            bench = int(args.pop(0))
        elif a == "--wait":
            wait = args.pop(0)
        elif a == "--once":
            once = True

    p = NineP(addr)
    print("render:", p.cat("version").strip(), file=sys.stderr)
    p.put("hello", "hello name=%s role=%s" % (name, role))
    inp = p.open("input", 1)
    t_open = time.monotonic_ns()
    ch = p.open("changes", 0)

    tree, st = Tree(), Stream()
    cur = []           # records of the batch or snapshot being read
    lock = threading.Lock()
    batch_cv = threading.Condition(lock)
    seen = []          # (seq, kind, t_encode, t_applied, records)
    laid = set()

    # One sender, so layout writes stay in order and whole lines.
    outq = []
    out_cv = threading.Condition()

    def sender():
        while True:
            with out_cv:
                out_cv.wait_for(lambda: outq)
                lines = outq[:]
                outq.clear()
            p.write(inp, 0, ("\n".join(lines) + "\n").encode())

    threading.Thread(target=sender, daemon=True).start()

    def reader():
        off = 0
        while True:
            b = p.read(ch, off, p.msize - 24)
            if not b:
                print("render: end of changes", file=sys.stderr)
                with batch_cv:
                    seen.append((None, "eof", 0, time.monotonic_ns(), []))
                    batch_cv.notify_all()
                return
            off += len(b)
            for r in st.feed(b.decode()):
                if r.verb in ("snap", "batch"):
                    cur.clear()
                    cur.append(r)
                    continue
                if r.verb != "end":
                    cur.append(r)
                    continue
                head, body = cur[0], cur[1:]
                with lock:
                    if head.verb == "snap":
                        tree.reset()
                        laid.clear()
                    for x in body:
                        tree.apply(x)
                    t_app = time.monotonic_ns()
                    out = []
                    if role == "primary":
                        for win in tree.windows:
                            for path, x, y, w, h, _ in tree.layout(win):
                                key = (path, x, y)
                                if key not in laid:
                                    laid.add(key)
                                    out.append("bounds win=%s node=%s value='%d %d %d %d'" % (win, rel(win, path), x, y, w, h))
                            out.append("frame win=%s" % win)
                    seen.append((int(head.words[0]), head.verb, int(head.attrs.get("x.t", 0)), t_app, body))
                    if draw:
                        for win in tree.windows:
                            print(tree.draw(win), flush=True)
                        print("render: %s %s, %d records" % (head.verb, head.words[0], len(body)), flush=True)
                    batch_cv.notify_all()
                if out and role != "view":
                    with out_cv:
                        outq.extend(out)
                        out_cv.notify()

    threading.Thread(target=reader, daemon=True).start()

    if once:
        # Attach, take the snapshot, report, leave: hot-attach.
        with batch_cv:
            batch_cv.wait_for(lambda: any(x[1] == "snap" for x in seen), timeout=30)
        snap = next(x for x in seen if x[1] == "snap")
        print("attach:              %d nodes, snapshot applied %.1f ms after open" % (len(tree.nodes), (snap[3] - t_open) / 1e6))
        print("counter:            ", tree.nodes.get("win/main/n", {}).get("attrs", {}).get("text"))
        print("renderers:          ", " / ".join(p.cat("renderers").strip().split("\n")))
        return

    if not bench:
        while True:
            with batch_cv:
                batch_cv.wait()
                if seen and seen[-1][1] == "eof":
                    return

    # --bench: wait for the counter, then click inc N times.
    with batch_cv:
        batch_cv.wait_for(lambda: wait in tree.nodes, timeout=90)
    time.sleep(0.3)
    print("tree:                %d nodes" % len(tree.nodes))
    rt, out_leg, inp_leg = [], [], []
    for i in range(bench):
        with batch_cv:
            start = len(seen)
        t0 = time.monotonic_ns()
        p.write(inp, 0, b"event click win=main node=inc\n")
        t_in = time.monotonic_ns()

        def has_text():
            for s in seen[start:]:
                if any(r.verb == "set" and r.words[:1] == ["win/main/n"] and "text" in r.attrs for r in s[4]):
                    return s
            return None

        with batch_cv:
            batch_cv.wait_for(has_text, timeout=10)
            s = has_text()
        if not s:
            print("render: no batch for click", i, file=sys.stderr)
            continue
        rt.append(s[3] - t0)
        out_leg.append(s[3] - s[2])
        inp_leg.append(t_in - t0)
        time.sleep(0.02)

    def pct(xs):
        xs = sorted(xs)
        q = lambda f: xs[int((len(xs) - 1) * f)] / 1e6
        return "p50 %.3f ms  p90 %.3f ms  max %.3f ms" % (q(0.5), q(0.9), q(1.0))

    print("clicks:              %d" % len(rt))
    print("round trip:          " + pct(rt))
    print("input write (9P):    " + pct(inp_leg))
    print("encode -> applied:   " + pct(out_leg))
    print("final:", tree.nodes["win/main/n"]["attrs"].get("text"))
    print(p.cat("stats").rstrip())


if __name__ == "__main__":
    main()
