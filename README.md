# Hush

Your LG TV's sound in your Mac's headphones — the TV goes quiet, nobody else hears a thing.

LG TVs can send their sound to a phone running the LG ThinQ app ("listen to TV sound privately").
Hush does the same for a Mac: a menu bar app that pairs with the TV over Wi-Fi, starts that stream
and plays it to whatever the Mac plays to (AirPods, any Bluetooth or wired headphones), with as
little delay as it can. No phone, no ThinQ, no extra hardware.

Good for late-night gaming or films while someone sleeps next door.

## How it works

```
LG TV ──Wi-Fi──▶ Mac (Hush)
  1. SSAP websocket wss://tv:3001, registered the way LG ThinQ registers (the TV asks once)
  2. soundshare/startStreamOut → the TV mutes its speakers and serves raw audio on TCP :9000
  3. 48 kHz stereo 16-bit PCM, uncompressed → ~40 ms jitter buffer → 128-frame output buffer
     → the current output device
```

There is no codec and no resampling anywhere on the way, so what the TV sends is what you hear.
Most of the remaining delay is the headphones' own: Bluetooth adds roughly 150 ms, wired almost
nothing. Full protocol notes: [docs/protocol.md](docs/protocol.md).

## Requirements

- An LG webOS TV that supports "listen to TV sound privately" in LG ThinQ (tested on a 2021 OLED,
  webOS 6). If ThinQ can do it with your TV, Hush most likely can too.
- macOS 14 or newer, on the same network as the TV.

## Install

Download `Hush.zip` from [Releases](../../releases), unzip it and move `Hush.app` to Applications.
The app is not notarized, so the first launch needs one of:

- System Settings → Privacy & Security → "Hush was blocked…" → Open Anyway, or
- `xattr -dr com.apple.quarantine /Applications/Hush.app`

Or build it yourself (Xcode command line tools):

```bash
scripts/build-app.sh --install    # → ~/Applications/Hush.app
```

## Use

1. Click the headphones icon in the menu bar. Hush lists the LG TVs it finds on the network
   (or type the TV's IP address) — press **Pair**.
2. Accept the request on the TV with the remote (first time only). Allow Hush to access the local
   network when macOS asks.
3. The TV's speakers go silent and the sound plays on the Mac.

Turning the switch off, or quitting Hush, gives the sound back to the TV's speakers. Hush
reconnects by itself when the TV is switched off and on again or the Mac wakes up.

The **Buffer** slider trades delay against stutter: the default 40 ms is fine on a decent Wi-Fi;
raise it if you hear dropouts. The line under it shows the output device, its own latency, how much
is buffered and how many underruns happened.

Hush logs a line of stats every 10 s: `log stream --predicate 'subsystem == "hush"'`.

## Notes

- One listener at a time: starting Hush stops a phone's ThinQ stream and the other way round.
- The TV refuses while it plays to Bluetooth or mirrors a screen; Hush says so in the menu.
- `tools/soundshare_probe.py <tv-ip>` records 5 s of TV sound to `tools/tv.wav` — handy to check a
  TV without the app.

## Disclaimer

Hush is not affiliated with or endorsed by LG Electronics. It talks to the TV with the same
messages the LG ThinQ app sends, including the registration manifest from that app, only to
interoperate with a TV you own. LG and webOS are trademarks of LG Electronics.

## License

[MIT](LICENSE)
