#!/usr/bin/env python3
"""A fake Nuphos runtime desktop for recording the iOS viewer with no real data.

Serves, on 127.0.0.1:PORT, the two backend calls the app makes:
  POST /teams/<t>/runtime-desktop/<s>       -> {"display": 1}
  GET  /teams/<t>/runtime-desktop/<s>/1     -> WebSocket, RFB as base64 text frames
and, with --tcp PORT2, plain RFB over TCP for protocol tests.

The desktop is a rendered picture (bg.raw, 1280x800 BGRA) with a notes window an
"agent" types into while the viewer watches. After {"t":"control","owner":"human"}
the agent stops and the viewer's keys type into the note instead.
"""
import asyncio, base64, gzip, hashlib, json, os, struct, sys

W, H = 1280, 800
HERE = os.path.dirname(os.path.abspath(__file__))
BG = gzip.open(os.path.join(HERE, "bg.raw.gz"), "rb").read()
GLYPHS = open(os.path.join(HERE, "glyphs.raw"), "rb").read()
GW_TOTAL, GH = 1129, 25
ADVANCE = GW_TOTAL / 94
NOTE_X, NOTE_Y, NOTE_W, NOTE_H, LINE = 148, 186, 650, 410, 34
NOTE_BG, INK = (0xF7, 0xFD, 0xFF), (0x33, 0x33, 0x33)  # BGR
SCRIPT = ["- [x] Bump the iOS version", "- [x] Run the desktop tests", "- [ ] Record the Desktop demo", "- [ ] Ask for review"]
ARROW = [
    "X..........", "XX.........", "XOX........", "XOOX.......", "XOOOX......", "XOOOOX.....", "XOOOOOX....",
    "XOOOOOOX...", "XOOOOOOOX..", "XOOOOOOOOX.", "XOOOOOXXXXX", "XOOXOOX....", "XOX.XOOX...", "XX..XOOX...",
    "X....XOOX..", ".....XOOX..", "......XX...",
]


class Desktop:
    def __init__(self):
        self.fb = bytearray(BG)
        self.lines = [""]
        self.human = False
        self.dirty = [(0, 0, W, H)]
        self.pointer = (640, 400)
        self.pointer_moved = False
        self.changed = asyncio.Event()
        self.render_note()

    def glyph(self, ch, x, y):
        code = ord(ch)
        if code <= 32 or code > 126:
            return
        gx = round((code - 33) * ADVANCE)
        gw = round((code - 32) * ADVANCE) - gx
        for row in range(GH):
            py = y + row
            if not 0 <= py < H:
                continue
            for col in range(gw):
                a = GLYPHS[row * GW_TOTAL + gx + col]
                if a == 0:
                    continue
                i = (py * W + x + col) * 4
                for c in range(3):
                    self.fb[i + c] = (NOTE_BG[c] * (255 - a) + INK[c] * a) // 255

    def render_note(self):
        for row in range(NOTE_Y, NOTE_Y + NOTE_H):
            start = (row * W + NOTE_X) * 4
            self.fb[start:start + NOTE_W * 4] = bytes([*NOTE_BG, 255]) * NOTE_W
        for n, line in enumerate(self.lines[-(NOTE_H // LINE):]):
            for k, ch in enumerate(line[: int(NOTE_W // ADVANCE) - 1]):
                self.glyph(ch, NOTE_X + round(k * ADVANCE), NOTE_Y + n * LINE + 4)
        caret_line = min(len(self.lines), NOTE_H // LINE) - 1
        cx = NOTE_X + round(len(self.lines[-1]) * ADVANCE) + 1
        for row in range(NOTE_Y + caret_line * LINE + 4, NOTE_Y + caret_line * LINE + 4 + GH):
            i = (row * W + min(cx, NOTE_X + NOTE_W - 2)) * 4
            self.fb[i:i + 8] = bytes([0xEC, 0x36, 0x7D, 255]) * 2
        self.dirty.append((NOTE_X, NOTE_Y, NOTE_W, NOTE_H))
        self.changed.set()

    def caret_point(self):
        line = min(len(self.lines), NOTE_H // LINE) - 1
        return (NOTE_X + round(len(self.lines[-1]) * ADVANCE) + 6, NOTE_Y + line * LINE + 16)

    def type(self, ch):
        if ch == "\n":
            self.lines.append("")
        elif ch == "\b":
            if self.lines[-1]:
                self.lines[-1] = self.lines[-1][:-1]
            elif len(self.lines) > 1:
                self.lines.pop()
        else:
            self.lines[-1] += ch
        self.render_note()

    async def agent(self):
        """Types the checklist, a character at a time, until someone takes over."""
        await asyncio.sleep(1.5)
        for line in SCRIPT:
            for ch in line:
                while self.human:
                    await asyncio.sleep(0.2)
                self.type(ch)
                self.pointer = self.caret_point()
                self.pointer_moved = True
                await asyncio.sleep(0.09)
            self.type("\n")
            await asyncio.sleep(0.6)


def cursor_rect():
    w, h = len(ARROW[0]), len(ARROW)
    colors, mask = bytearray(), bytearray()
    for row in ARROW:
        bits = 0
        for x, c in enumerate(row):
            colors += bytes([0, 0, 0, 0]) if c == "X" else bytes([255, 255, 255, 0])
            if c != ".":
                bits |= 0x80 >> (x % 8)
            if x % 8 == 7 or x == w - 1:
                mask.append(bits)
                bits = 0
    return struct.pack(">HHHHi", 0, 0, w, h, -239) + colors + mask


async def rfb(read, send, controls, desktop):
    """One viewer. `read(n)` returns exactly n bytes; `send(b)` queues bytes."""
    send(b"RFB 003.008\n")
    await read(12)
    send(bytes([1, 1]))
    await read(1)
    send(struct.pack(">I", 0))
    await read(1)
    name = b"Demo Mac"
    send(struct.pack(">HH", W, H) + bytes([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]) + struct.pack(">I", len(name)) + name)
    state = {"want": False, "encodings": set(), "cursor_sent": False, "buttons": 0}
    desktop.dirty.append((0, 0, W, H))

    async def updates():
        while True:
            await desktop.changed.wait()
            desktop.changed.clear()
            while not state["want"]:
                await asyncio.sleep(0.01)
            state["want"] = False
            rects = []
            if -239 in state["encodings"] and not state["cursor_sent"]:
                rects.append(cursor_rect())
                state["cursor_sent"] = True
            dirty, desktop.dirty = desktop.dirty, []
            if any(d == (0, 0, W, H) for d in dirty):
                dirty = [(0, 0, W, H)]
            for x, y, w, h in dirty:
                body = bytearray(struct.pack(">HHHHi", x, y, w, h, 0))
                for row in range(y, y + h):
                    start = (row * W + x) * 4
                    body += desktop.fb[start:start + w * 4]
                rects.append(bytes(body))
            if desktop.pointer_moved and -232 in state["encodings"]:
                desktop.pointer_moved = False
                rects.append(struct.pack(">HHHHi", desktop.pointer[0], desktop.pointer[1], 0, 0, -232))
            if not rects:
                state["want"] = True
                continue
            send(struct.pack(">BBH", 0, 0, len(rects)) + b"".join(rects))

    task = asyncio.create_task(updates())
    try:
        while True:
            kind = (await read(1))[0]
            if kind == 0:
                await read(19)
            elif kind == 2:
                _, n = struct.unpack(">BH", await read(3))
                state["encodings"] = set(struct.unpack(">%di" % n, await read(4 * n)))
            elif kind == 3:
                await read(9)
                state["want"] = True
                if desktop.dirty or desktop.pointer_moved:
                    desktop.changed.set()
            elif kind == 4:
                down, _, key = struct.unpack(">BHI", await read(7))
                if down and controls["human"]:
                    special = {0xFF0D: "\n", 0xFF08: "\b"}
                    ch = special.get(key) or (chr(key) if 32 <= key < 256 else chr(key - 0x01000000) if key >= 0x01000000 else None)
                    if ch:
                        desktop.type(ch)
            elif kind == 5:
                buttons, x, y = struct.unpack(">BHH", await read(5))
                desktop.pointer = (x, y)
            elif kind == 6:
                await read(3)
                await read(struct.unpack(">I", await read(4))[0])
            else:
                raise ValueError("client message %d" % kind)
    finally:
        task.cancel()


def reader(queue):
    buffer = bytearray()

    async def read(n):
        while len(buffer) < n:
            chunk = await queue.get()
            if chunk is None:
                raise ConnectionError("closed")
            buffer.extend(chunk)
        out = bytes(buffer[:n])
        del buffer[:n]
        return out

    return read


def ws_frame(text):
    data = text.encode()
    n = len(data)
    head = bytes([0x81]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack(">H", n) if n < 65536 else bytes([127]) + struct.pack(">Q", n))
    return head + data


async def handle_http(r, w, desktop):
    request = await r.readuntil(b"\r\n\r\n")
    head = request.decode(errors="replace").split("\r\n")
    method, path, _ = head[0].split(" ", 2)
    headers = {k.lower(): v for k, v in (h.split(": ", 1) for h in head[1:] if ": " in h)}
    length = int(headers.get("content-length", "0") or 0)
    if length:
        await r.readexactly(length)
    if method == "POST" and "/runtime-desktop/" in path:
        body = b'{"display":1}'
        w.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
        await w.drain()
        w.close()
        return
    if headers.get("upgrade", "").lower() != "websocket":
        w.write(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        await w.drain()
        w.close()
        return
    accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    w.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
    await w.drain()
    queue, controls = asyncio.Queue(), {"human": False}

    def send(data):
        for i in range(0, len(data), 48 * 1024):
            w.write(ws_frame(base64.b64encode(data[i:i + 48 * 1024]).decode()))

    async def frames():
        try:
            while True:
                b0, b1 = await r.readexactly(2)
                n = b1 & 0x7F
                if n == 126:
                    n = struct.unpack(">H", await r.readexactly(2))[0]
                elif n == 127:
                    n = struct.unpack(">Q", await r.readexactly(8))[0]
                mask = await r.readexactly(4) if b1 & 0x80 else b"\0\0\0\0"
                payload = bytes(c ^ mask[i % 4] for i, c in enumerate(await r.readexactly(n)))
                op = b0 & 0x0F
                if op == 8:
                    break
                if op == 9:
                    w.write(bytes([0x8A, len(payload)]) + payload)
                    continue
                if op != 1:
                    continue
                text = payload.decode()
                if text.startswith("{"):
                    controls["human"] = json.loads(text).get("owner") == "human"
                    desktop.human = controls["human"]
                    print("control:", "human" if controls["human"] else "agent", flush=True)
                else:
                    queue.put_nowait(base64.b64decode(text))
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        queue.put_nowait(None)

    reading = asyncio.create_task(frames())
    try:
        await rfb(reader(queue), send, controls, desktop)
    except ConnectionError:
        pass
    finally:
        desktop.human = False
        reading.cancel()
        w.close()


async def handle_tcp(r, w, desktop):
    queue, controls = asyncio.Queue(), {"human": True}

    async def pump():
        while chunk := await r.read(65536):
            queue.put_nowait(chunk)
        queue.put_nowait(None)

    asyncio.create_task(pump())
    try:
        await rfb(reader(queue), w.write, controls, desktop)
    except ConnectionError:
        pass


async def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    desktop = Desktop()
    asyncio.create_task(desktop.agent())
    servers = [await asyncio.start_server(lambda r, w: handle_http(r, w, desktop), "127.0.0.1", port)]
    if "--tcp" in sys.argv:
        servers.append(await asyncio.start_server(lambda r, w: handle_tcp(r, w, desktop), "127.0.0.1", int(sys.argv[sys.argv.index("--tcp") + 1])))
    print("fixture desktop on 127.0.0.1:%d" % port, flush=True)
    await asyncio.gather(*(s.serve_forever() for s in servers))


asyncio.run(main())
