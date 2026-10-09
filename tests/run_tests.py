#!/usr/bin/env python3
"""Integration test: mock Samsung TV + throw-away FHEM instance (own ports/directory) with the module from this repository.
Usage: python3 tests/run_tests.py [--fhem /opt/fhem]  (production FHEM is only read). Ports: telnet 17074, mock 18001/18002/18003, WOL 19999."""
import json, os, shutil, socket, subprocess, sys, time, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
FHEM_SRC = sys.argv[sys.argv.index("--fhem") + 1] if "--fhem" in sys.argv else "/opt/fhem"
W = "/tmp/stws-test"
TELNET, REST, WSP, CTL, WOL = 17074, 18001, 18002, 18003, 19999
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + (("  (" + str(detail) + ")") if detail and not ok else ""), flush=True)


def ctl(path, **q):
    return json.loads(urllib.request.urlopen("http://127.0.0.1:%d/%s?%s" % (CTL, path, urllib.parse.urlencode(q)), timeout=5).read())


def fhem(cmd):
    s = socket.create_connection(("127.0.0.1", TELNET), timeout=10)
    s.sendall((cmd + "\n").encode())
    out, start = b"", time.time()
    s.settimeout(0.7)
    while time.time() - start < 15:
        try:
            d = s.recv(65536)
            if not d:
                break
            out += d
            start = max(start, time.time() - 14)
        except socket.timeout:
            if out:
                break
        except Exception:
            break
    try:
        s.sendall(b"quit\n")
    except Exception:
        pass
    s.close()
    return out.decode("utf-8", "replace").replace("\xff\xfb\x01", "").strip()


def reading(dev, r):
    try:
        return json.loads(fhem("jsonlist2 %s" % dev))["Results"][0]["Readings"][r]["Value"]
    except Exception:
        return None


def wait(cond, timeout=20, step=0.4):
    t = time.time()
    while time.time() - t < timeout:
        try:
            if cond():
                return True
        except Exception:
            pass
        time.sleep(step)
    return False


def setup():
    shutil.rmtree(W, ignore_errors=True)
    os.makedirs(W + "/fhem/log")
    shutil.copy(FHEM_SRC + "/fhem.pl", W + "/fhem/fhem.pl")
    subprocess.run(["cp", "-rs", FHEM_SRC + "/FHEM", W + "/fhem/FHEM"], check=True)
    for n in ("lib", "www", "contrib"):
        if os.path.exists(FHEM_SRC + "/" + n):
            os.symlink(FHEM_SRC + "/" + n, W + "/fhem/" + n)
    shutil.rmtree(W + "/fhem/FHEM/FhemUtils", ignore_errors=True)       # own, empty key store (never the production one)
    os.makedirs(W + "/fhem/FHEM/FhemUtils")
    p = W + "/fhem/FHEM/74_SamsungTizenWS.pm"
    if os.path.lexists(p):
        os.remove(p)
    shutil.copy(REPO + "/FHEM/74_SamsungTizenWS.pm", p)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", W + "/k.pem", "-out", W + "/c.pem",
                    "-subj", "/CN=127.0.0.1", "-days", "2"], check=True, capture_output=True)
    open(W + "/fhem/test.cfg", "w").write("""attr global modpath %s/fhem
attr global logfile %s/fhem/log/fhem.log
attr global verbose 3
attr global statefile %s/fhem/fhem.save
define telnetPort telnet %d
""" % (W, W, W, TELNET))


def drop_privileges():
    if os.geteuid() != 0:
        return None
    import pwd
    try:
        u = pwd.getpwnam("fhem")
    except KeyError:
        return None
    subprocess.run(["chown", "-R", "%d:%d" % (u.pw_uid, u.pw_gid), W], check=True)

    def fn():
        os.setgid(u.pw_gid)
        os.setuid(u.pw_uid)
    return fn


def ports_free():
    for port in (TELNET, REST, WSP, CTL):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
            return "port %d is already in use (stale test instance?)" % port
        except OSError:
            pass
    return None


def token():
    return fhem('{ (getKeyValue("tv_token"))[1] // "none" }')


def main():
    busy = ports_free()
    if busy:
        raise SystemExit(busy)
    setup()
    pre = drop_privileges()
    mock = subprocess.Popen([sys.executable, HERE + "/mock_tv.py", W + "/c.pem", W + "/k.pem", str(REST), str(WSP), str(CTL), str(WOL)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, preexec_fn=pre)
    time.sleep(1.5)
    fh = subprocess.Popen(["perl", "fhem.pl", "test.cfg"], cwd=W + "/fhem", stdout=subprocess.PIPE, stderr=subprocess.STDOUT, preexec_fn=pre)
    try:
        if not wait(lambda: "telnetPort" in fhem("list telnetPort"), 25):
            print("FHEM did not start")
            raise SystemExit(1)

        # --- define; TV is on but not paired yet: the pairing dialog is "confirmed" by the mock after ~1.2 s
        fhem("define tv SamsungTizenWS 127.0.0.1 %d" % WSP)
        fhem("attr tv restPort %d" % REST)
        fhem("attr tv interval 5")
        fhem("attr tv wolMac c0:48:e6:4e:97:ee")
        fhem("attr tv wolBroadcast 127.0.0.1")
        fhem("attr tv wolPort %d" % WOL)
        fhem("attr tv keyDelay 100")
        check("define without host is refused", "Usage" in fhem("define bad SamsungTizenWS"))
        check("REST poll: presence/power/model", wait(lambda: reading("tv", "power") == "on" and reading("tv", "modelName") == "QE65Q7FNA", 15),
              (reading("tv", "power"), reading("tv", "modelName")))
        check("pairing starts without token", wait(lambda: reading("tv", "state") in ("pairing", "connected"), 10), reading("tv", "state"))
        check("pairing confirmed: token stored in the key store", wait(lambda: token() == "TOK12345", 15), token())
        check("state connected, tokenState paired", wait(lambda: reading("tv", "state") == "connected" and reading("tv", "tokenState") == "paired", 10),
              (reading("tv", "state"), reading("tv", "tokenState")))
        check("client name sent to the TV", "FHEM" in ctl("state")["names_seen"], ctl("state")["names_seen"])

        # --- keys
        fhem("set tv volumeUp")
        check("volumeUp -> KEY_VOLUP (Click)", wait(lambda: {"key": "KEY_VOLUP", "cmd": "Click", "type": "SendRemoteKey"} in ctl("state")["keys"], 6), ctl("state")["keys"])
        fhem("set tv key KEY_HOME")
        check("key KEY_HOME", wait(lambda: any(k["key"] == "KEY_HOME" for k in ctl("state")["keys"]), 6))
        check("invalid key refused", "invalid key" in fhem("set tv key volume_up"))
        fhem("set tv keys KEY_HOME,KEY_RIGHT,KEY_ENTER")
        check("keys: sequence in order", wait(lambda: [k["key"] for k in ctl("state")["keys"]][-3:] == ["KEY_HOME", "KEY_RIGHT", "KEY_ENTER"], 8),
              [k["key"] for k in ctl("state")["keys"]][-4:])
        check("lastKey reading", reading("tv", "lastKey") == "KEY_ENTER", reading("tv", "lastKey"))
        sl = fhem("set tv ?")
        check("set list: FHEM-conform text, keys and short commands", sl.startswith("Unknown argument ?, choose one of") and "volumeUp:noArg" in sl and "KEY_MUTE" in sl, sl[:120])

        # --- apps
        fhem("set tv refreshApps")
        check("installed apps read", wait(lambda: reading("tv", "appCount") == "3" and "Netflix" in (reading("tv", "apps") or ""), 8), reading("tv", "apps"))
        fhem("set tv app Netflix")
        check("app launch by name -> appId", wait(lambda: any(l and l.get("appId") == "11101200001" for l in ctl("state")["launches"]), 6), ctl("state")["launches"])
        check("unknown app refused", "unknown app" in fhem("set tv app No_Such_App!"))
        check("get apps lists names and ids", "11101200001" in fhem("get tv apps"))
        check("get info shows the device data", "QE65Q7FNA" in fhem("get tv info"))

        # --- KEY_POWER switches the TV off
        fhem("set tv off")
        check("off -> KEY_POWER sent", wait(lambda: any(k["key"] == "KEY_POWER" for k in ctl("state")["keys"]), 6))
        check("TV went off: state off, presence absent", wait(lambda: reading("tv", "state") == "off" and reading("tv", "presence") == "absent", 25),
              (reading("tv", "state"), reading("tv", "presence")))
        check("keys are refused while the TV is off", "TV is off" in fhem("set tv volumeUp"), fhem("set tv volumeUp"))

        # --- Wake on LAN
        fhem("set tv on")
        check("on -> magic packet for the configured MAC", wait(lambda: "c0:48:e6:4e:97:ee" in ctl("state")["wol"], 6), ctl("state")["wol"])
        check("TV is back: power on and connected with the stored token", wait(lambda: reading("tv", "power") == "on" and reading("tv", "state") == "connected", 25),
              (reading("tv", "power"), reading("tv", "state")))
        check("reconnect uses the stored token (no new pairing)", ctl("state")["tokens_seen"][-1] == "TOK12345", ctl("state")["tokens_seen"])

        # --- standby (newer models answer REST with PowerState standby)
        ctl("powerstate", value="standby")
        check("PowerState standby: state standby, websocket closed", wait(lambda: reading("tv", "state") == "standby", 15), reading("tv", "state"))
        ctl("powerstate", value="on")
        check("PowerState on again: connected", wait(lambda: reading("tv", "state") == "connected", 20), reading("tv", "state"))
        ctl("powerstate", value="none")

        # --- pairing denied
        ctl("approve", mode="deny")
        before = ctl("state")["connections"]
        fhem("set tv pairingReset")
        check("pairingReset deletes the token", wait(lambda: token() == "none", 6), token())
        check("denied pairing: tokenState denied", wait(lambda: reading("tv", "tokenState") == "denied", 20), reading("tv", "tokenState"))
        time.sleep(12)
        check("denied pairing: no reconnect storm", ctl("state")["connections"] - before <= 2, ctl("state")["connections"] - before)
        ctl("approve", mode="allow")
        fhem("set tv pairingReset")
        check("pairing works again after pairingReset", wait(lambda: token() == "TOK12345" and reading("tv", "state") == "connected", 25), (token(), reading("tv", "state")))

        # --- attributes
        check("interval below 5 refused", "minimum 5" in fhem("attr tv interval 1"))
        check("keyDelay out of range refused", "keyDelay" in fhem("attr tv keyDelay 99999"))
        fhem("attr tv wolMac nonsense")
        check("invalid wolMac gives a clear error", "invalid MAC" in fhem("set tv on"), fhem("set tv on"))
        fhem("deleteattr tv wolMac")
        check("wake without wolMac gives a clear error", "wolMac" in fhem("set tv on"), fhem("set tv on"))
        fhem("attr tv wolMac c0:48:e6:4e:97:ee")
        fhem("attr tv disable 1")
        check("disable: state disabled and keys refused", wait(lambda: reading("tv", "state") == "disabled", 8) and "disabled" in fhem("set tv volumeUp"))
        fhem("attr tv disable 0")
        check("enable again: connected", wait(lambda: reading("tv", "state") == "connected", 20), reading("tv", "state"))
        # --- TVs that send ms.channel.ready (newer models) work as well
        ctl("ready", on=1)
        fhem("attr tv disable 1")
        time.sleep(1)
        fhem("attr tv disable 0")
        check("TV with ms.channel.ready: reconnects", wait(lambda: reading("tv", "state") == "connected", 20), reading("tv", "state"))
        n = len(ctl("state")["keys"])
        fhem("set tv mute")
        check("TV with ms.channel.ready: key arrives", wait(lambda: len(ctl("state")["keys"]) > n and ctl("state")["keys"][-1]["key"] == "KEY_MUTE", 8))
    finally:
        try:
            fhem("shutdown")
        except Exception:
            pass
        mock.terminate()
        try:
            fh.wait(10)
        except Exception:
            fh.terminate()
            try:
                fh.wait(5)
            except Exception:
                fh.kill()
                fh.wait()
        log = open(W + "/fhem/log/fhem.log", errors="replace").read() if os.path.exists(W + "/fhem/log/fhem.log") else ""
        bad = [l for l in log.splitlines() if "PERL WARNING" in l or "Undefined subroutine" in l or "Use of uninitialized" in l]
        check("no Perl warnings in the FHEM log", not bad, bad[:3])
    print("%d/%d checks passed" % (sum(results), len(results)))
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
