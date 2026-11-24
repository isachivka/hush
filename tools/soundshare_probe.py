"""Record 5 s of TV sound straight from an LG webOS TV (soundshare). See docs/lg-soundshare.md.

uv run --no-project --with websockets python tools/soundshare_probe.py <tv-ip>   → tools/tv.wav
Registers with LG ThinQ's manifest (taken from Sources/Hush/Manifest.swift); the client key
is kept in ~/.config/hush/probe-client-key. Quit Hush first: the TV streams to one client.
"""
import array, asyncio, json, os, re, socket, ssl, sys, time, wave
import websockets

HERE = os.path.dirname(os.path.abspath(__file__))
if len(sys.argv) < 2: sys.exit(__doc__)
TV = sys.argv[1]
KEYF = os.path.expanduser("~/.config/hush/probe-client-key")
SS = "ssap://com.webos.service.soundshare"
src = open(os.path.join(HERE, "../Sources/Hush/Manifest.swift")).read()
MANIFEST = json.loads(re.search(r'#"(.*)"#', src).group(1))
MANIFEST["deviceName"] = "Hush probe"


async def main():
    ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    key = open(KEYF).read().strip() if os.path.exists(KEYF) else ""
    async with websockets.connect(f"wss://{TV}:3001", ssl=ctx, max_size=None) as ws:
        await ws.send(json.dumps({"type": "register", "id": "reg",
                                  "payload": {"client-key": key, "pairingType": "PROMPT", "manifest": MANIFEST}}))
        while True:
            m = json.loads(await asyncio.wait_for(ws.recv(), 120)); print("<", json.dumps(m)[:200])
            if m.get("type") == "registered":
                key = m["payload"]["client-key"]; os.makedirs(os.path.dirname(KEYF), exist_ok=True)
                open(KEYF, "w").write(key); break
            if m.get("type") == "error": return
        ip = ws.local_address[0]
        req = lambda i, uri, pl, t="request": ws.send(json.dumps({"id": i, "type": t, "uri": uri, "payload": pl}))
        await req("st", SS + "/getStreamOutStatus", {"deviceParam": {"key": key}, "subscribe": True}, "subscribe")
        await req("go", SS + "/startStreamOut", {"deviceParam": {"key": key, "addr": ip, "port": "9000"}})
        while True:
            m = json.loads(await asyncio.wait_for(ws.recv(), 10)); print("<", json.dumps(m)[:300])
            if m.get("id") == "go": break
        sock = socket.create_connection((TV, 9000), 5); sock.settimeout(3)
        data, t0 = b"", time.time()
        try:
            while time.time() - t0 < 5:
                d = sock.recv(65536)
                if not d: break
                data += d
        except socket.timeout:
            pass
        sock.close()
        await req("stop", SS + "/stopStreamOut", {"deviceParam": {"key": key}})
        await asyncio.sleep(0.5)
        a = array.array("h"); a.frombytes(data[:len(data) // 4 * 4]); a.byteswap()  # TV sends big-endian
        print("seconds", round(len(data) / 192000, 2), "peak", max(map(abs, a), default=0))
        with wave.open(os.path.join(HERE, "tv.wav"), "wb") as w:
            w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000); w.writeframes(a.tobytes())

asyncio.run(main())
