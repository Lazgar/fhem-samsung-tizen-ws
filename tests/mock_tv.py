#!/usr/bin/env python3
"""Mock of a Samsung Tizen TV for testing the FHEM module without a TV: REST info API (plain HTTP), the secure remote WebSocket
(TLS, token pairing) and a Wake-on-LAN listener.
Usage: mock_tv.py <tls-cert> <tls-key> [rest-port=18001] [ws-port=18002] [control-port=18003] [wol-port=19999]
Control (127.0.0.1:<control-port>): /state, /power?on=1|0, /approve?mode=allow|deny, /powerstate?value=standby|on|none
Only the Python standard library is used."""
import base64, hashlib, json, socket, ssl, struct, sys, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

CERT, KEY = sys.argv[1], sys.argv[2]
REST = int(sys.argv[3]) if len(sys.argv) > 3 else 18001
WS = int(sys.argv[4]) if len(sys.argv) > 4 else 18002
CTL = int(sys.argv[5]) if len(sys.argv) > 5 else 18003
WOLP = int(sys.argv[6]) if len(sys.argv) > 6 else 19999
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TV_MAC = "c0:48:e6:4e:97:ee"
TOKEN = "TOK12345"

S = {"power": True, "pair": "allow", "powerstate": "none", "keys": [], "launches": [], "posts": [], "wol": [], "connections": 0,
     "tokens_seen": [], "names_seen": []}
clients = []
lock = threading.Lock()

APPS = [{"appId": "11101200001", "name": "Netflix", "app_type": 2}, {"appId": "111299001912", "name": "YouTube", "app_type": 2},
        {"appId": "3201606009684", "name": "Spotify", "app_type": 2}]


def info():
    d = {"FrameTVSupport": "false", "OS": "Tizen", "TokenAuthSupport": "true", "countryCode": "AT", "modelName": "QE65Q7FNA",
         "name": "[TV] Samsung Q7 Series (65)", "networkType": "wired", "resolution": "3840x2160", "wifiMac": TV_MAC}
    if S["powerstate"] != "none":
        d["PowerState"] = S["powerstate"]
    return {"device": d, "name": d["name"], "remote": "1.0", "type": "Samsung SmartTV", "version": "2.0.25"}


def frame(text):
    b = text.encode()
    n = len(b)
    head = bytes([0x81])
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    return head + b


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        c = sock.recv(n - len(buf))
        if not c:
            raise EOFError
        buf += c
    return buf


def recv_frame(sock):
    h = recv_exact(sock, 2)
    op, masked, ln = h[0] & 0x0F, h[1] & 0x80, h[1] & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", recv_exact(sock, 8))[0]
    mask = recv_exact(sock, 4) if masked else b"\0\0\0\0"
    data = bytearray(recv_exact(sock, ln))
    for i in range(ln):
        data[i] ^= mask[i % 4]
    return op, bytes(data)


def drop_clients():
    with lock:
        cs = list(clients)
        clients.clear()
    for c in cs:
        try:
            c.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass


def ws_session(sock, path):
    q = parse_qs(urlparse(path).query)
    token = q.get("token", [""])[0]
    with lock:
        S["connections"] += 1
        S["tokens_seen"].append(token)
        S["names_seen"].append(base64.b64decode(q.get("name", [""])[0] + "==").decode(errors="replace") if q.get("name") else "")
        clients.append(sock)
    if token != TOKEN:
        if S["pair"] == "allow":
            time.sleep(1.2)                      # the user is looking at the dialog
        else:
            sock.sendall(frame(json.dumps({"event": "ms.channel.timeOut"})))
            time.sleep(0.2)
            return
    sock.sendall(frame(json.dumps({"event": "ms.channel.connect", "data": {"id": "1", "token": TOKEN, "clients": []}})))
    sock.sendall(frame(json.dumps({"event": "ms.channel.ready"})))
    while True:
        op, data = recv_frame(sock)
        if op == 8:
            return
        if op != 1:
            continue
        m = json.loads(data.decode())
        p = m.get("params", {})
        if m.get("method") == "ms.remote.control":
            with lock:
                S["keys"].append({"key": p.get("DataOfCmd"), "cmd": p.get("Cmd"), "type": p.get("TypeOfRemote")})
            if p.get("DataOfCmd") == "KEY_POWER":
                def off():
                    time.sleep(0.8)
                    S["power"] = False
                    drop_clients()
                threading.Thread(target=off, daemon=True).start()
        elif m.get("method") == "ms.channel.emit":
            if p.get("event") == "ed.installedApp.get":
                sock.sendall(frame(json.dumps({"event": "ed.installedApp.get", "from": "host", "data": {"data": APPS}})))
            elif p.get("event") == "ed.apps.launch":
                with lock:
                    S["launches"].append(p.get("data"))


class Rest(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _reply(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if not S["power"]:
            self.connection.close()
            return
        if urlparse(self.path).path in ("/api/v2/", "/api/v2"):
            return self._reply(info())
        self._reply({"error": "not found"}, 404)

    def do_POST(self):
        if not S["power"]:
            self.connection.close()
            return
        n = int(self.headers.get("Content-Length", 0))
        self.rfile.read(n)
        with lock:
            S["posts"].append(self.path)
        self._reply({"ok": True})


class WsHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if not S["power"]:
            self.connection.close()
            return
        key = self.headers.get("Sec-WebSocket-Key", "")
        acc = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          "Sec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
        self.wfile.flush()
        self.close_connection = True
        try:
            ws_session(self.connection, self.path)
        except Exception:
            pass
        with lock:
            if self.connection in clients:
                clients.remove(self.connection)


class Ctl(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        out = {"ok": True}
        if u.path == "/power":
            S["power"] = q.get("on", "1") == "1"
            if not S["power"]:
                drop_clients()
        elif u.path == "/approve":
            S["pair"] = q.get("mode", "allow")
        elif u.path == "/powerstate":
            S["powerstate"] = q.get("value", "none")
        elif u.path == "/state":
            with lock:
                out = dict(S)
        b = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)


class TServer(HTTPServer):
    daemon_threads = True

    def process_request(self, request, client_address):
        threading.Thread(target=self._h, args=(request, client_address), daemon=True).start()

    def _h(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        except Exception:
            pass
        finally:
            try:
                self.shutdown_request(request)
            except Exception:
                pass


def wol_listener():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", WOLP))
    while True:
        d, _ = s.recvfrom(1024)
        if len(d) == 102 and d[:6] == b"\xff" * 6:
            mac = ":".join("%02x" % b for b in d[6:12])
            with lock:
                S["wol"].append(mac)
            if mac == TV_MAC:
                def on():
                    time.sleep(1.0)
                    S["power"] = True
                threading.Thread(target=on, daemon=True).start()


if __name__ == "__main__":
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    ws = TServer(("127.0.0.1", WS), WsHandler)
    ws.socket = ctx.wrap_socket(ws.socket, server_side=True)
    threading.Thread(target=ws.serve_forever, daemon=True).start()
    threading.Thread(target=TServer(("127.0.0.1", REST), Rest).serve_forever, daemon=True).start()
    threading.Thread(target=wol_listener, daemon=True).start()
    print("mock tv ready", flush=True)
    TServer(("127.0.0.1", CTL), Ctl).serve_forever()
