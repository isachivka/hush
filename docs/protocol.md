# How Hush gets the sound: LG webOS soundshare

The TV's "listen to TV sound privately" stream (what LG ThinQ plays on a phone), taken by the Mac
directly. Implemented in `Sources/Hush/SoundShare.swift`; a Python probe that records 5 s is
`tools/soundshare_probe.py`. Found by reading the decompiled LG ThinQ 5.2 Android app (`com.lge.lms.things.service.smarttv.remoteSound`,
ConnectSDK `com.connectsdk3.service.webos.WebOSTVServiceSocketClient`).

## Protocol

1. SSAP websocket `wss://<tv>:3001` (self-signed certificate). Register with **ThinQ's manifest**
   (`setLGMobileManifest`: appId `com.lge.test`, serial `49d0233e…`, LG-signed, `TEST_SECURE` and
   `SECURE_*` permissions) — copied verbatim into `Sources/Hush/Manifest.swift`. `pairingType: PROMPT`; this TV
   registered a new client without asking.
2. `subscribe ssap://com.webos.service.soundshare/getStreamOutStatus {"deviceParam":{"key":<client-key>},"subscribe":true}`
   — pushes `{"params":{"type":"requestAudio","typeParams":{"command":"streamOutStatus","state":"RUNNING|IDLE","count":n,"pcmSize":4096}}}`.
   The immediate reply may say `errorText: "a Key is not correct."`; that is harmless.
3. `request …/startStreamOut {"deviceParam":{"key":<client-key>,"addr":<mac ip>,"port":"9000"}}`
   → `{"returnValue":true}`; state becomes RUNNING and the TV's speakers go silent.
4. TCP connect to **the TV**, port 9000, and read: **raw PCM, 48 kHz, stereo, 16-bit big-endian**,
   4096-byte chunks (21 ms). No handshake. First bytes arrive ~20 ms after connecting.
5. `request …/stopStreamOut {"deviceParam":{"key":…}}` → IDLE, the speakers come back.

ThinQ waits for a `requestAudio` push with `command: startStreamOut`, `result`, `addr`, `port` (via
`ssap://system/getHostMessage`); the TV never sent it to us, and connecting to `<tv>:9000` right
after `returnValue:true` works. ThinQ also has a UDP mode (`DatagramSocket(9000)` when no addr comes
back); not needed.

## Pitfalls

- `startStreamOut` answers `500 Application error`, `result: NOT_AVAILABLE`,
  `"Device count is already MAX."` when the client has not subscribed to `getStreamOutStatus` on
  the same connection first. It answered the same for a client registered with the manifest that
  open-source webOS libraries use (aiowebostv / ConnectSDK "LG Remote App"), subscription or not;
  with ThinQ's manifest and the subscription it streams.
- `deviceName` in the manifest is the name the TV shows for the client; it is outside the signed
  part, so any name works.
- Results ThinQ knows: SUCCESS, NOT_AVAILABLE, MAX_CONNECTION, BT_SINK (the TV plays to Bluetooth),
  MINIMAL_APP, MIRACAST_PLAYING. ThinQ refuses at `count >= 3`.
- The TV now and then drops a websocket right after several quick reconnects; retry after a second.
- A stream started for an earlier connection (the client quit or restarted, the Mac slept) stays
  RUNNING: `stopStreamOut` answers `There is no connected…`, and every `startStreamOut` is refused
  with `a Key is not correct.` or `Device count is already MAX.` (the subscribe reply then carries
  a `streamOutKey`). Connecting to `<tv>:9000`, reading and hanging up makes the TV drop it; the
  next start works.
- One client streams at a time: starting from the Mac stops ThinQ's stream and the other way round.
- Tested on an OLED65C1RLA (webOS 6, 2021).
