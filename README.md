# ClawWatch

**A Telegram client for Apple Watch and iPhone, built as an agent-native surface.**

ClawWatch is a fork of [Mercury](https://github.com/mercurytelegram/Mercury) — the open-source standalone Telegram client for Apple Watch — extended into a two-app, agent-connected system. It keeps everything Mercury does on the wrist, adds a native iPhone app that shares the same engine, and turns the whole thing into a device your AI agent can *talk to and act through* — over Telegram, as a structured OpenClaw node, and by live voice.

> This is a personal fork under DoctorDuRant LLC. For the original standalone watch client, see the [upstream Mercury project](https://github.com/mercurytelegram/Mercury). Credits to the original authors are at the bottom.

---

## What's in this fork

- **Two native apps that share one engine.** The watchOS app and a new iPhone app (`ClawWatch iOS`) are built on the same TDLib service core — messaging, health/status, the agent logic — with per-platform UI on top.
- **A companion + standalone watch.** The watch app installs on its own *and* pairs with the phone, so it can relay through the phone when nearby and run independently otherwise.
- **An AI agent channel with three doors:** Telegram `#`-commands (works anywhere), a structured **OpenClaw node** (the agent's direct JSON API into the device), and a **live voice** channel.
- **Remote access without a VPN** via Cloudflare Tunnel — so the standalone watch can reach a private gateway from anywhere.
- A trust layer (per-category consent, a command token, rate limiting, an audit log) over all of it.

---

## Architecture

```
                    ┌──────────────── your devices ────────────────┐
                    │                                               │
   Apple Watch  ────┤  shared TDLib service core (messaging,        │
   (standalone +    │  health/status, agent logic, PTT, voice)      │
    companion)      │                                               │
                    │        per-platform UI on top                 │
   iPhone       ────┤                                               │
   (ClawWatch iOS)  └───────────────────────────────────────────────┘
        │  │  │
        │  │  └── Live voice ....... wss:// → voice server (STT → agent → TTS)
        │  └───── OpenClaw node .... wss:// → OpenClaw gateway (structured tools)
        └──────── Telegram ......... Telegram's servers (always-on floor)

              off-network: gateway + voice exposed via Cloudflare Tunnel
```

**Three channels, by design.** Telegram is the reliable floor — text and `#`-commands, works anywhere with internet, no infrastructure. The OpenClaw node is the agent's direct, structured tool API. Live voice is the spoken channel. Nothing replaces Telegram; the others are upgrades that need a reachable gateway.

---

## The apps

### Apple Watch app — standalone + companion

The full Mercury watch client (messaging, secret chats, complications, Siri, notifications — see **Messaging** below) plus this fork's additions: the agent channel, walkie-talkie, disappearing messages, live voice, and a standalone OpenClaw node. It runs on its own on a cellular watch and, when paired, is the companion of the iPhone app.

### iPhone app — `ClawWatch iOS`

A native iOS app on the same shared core. It embeds the watch app as its companion (so the two share a WatchConnectivity link) while the watch stays independently installable.

iOS-specific capabilities:

- **Push notifications** with inline quick-reply, mark-as-read, and open-link actions; APNs registered with Telegram.
- **CallKit + PushKit VoIP** — native incoming-call UI mapped to TDLib call signaling.
- **Live Activities & Dynamic Island** — a call activity; plus a home-screen unread widget.
- **Notification Service** and **Share** extensions.
- **Photo send** (system photo picker), **App Intents / Siri Shortcuts**, background refresh (`BGTaskScheduler`), HealthKit.
- **Walkie-talkie**, **disappearing messages**, the **agent settings** screen, the **OpenClaw node**, and **live voice**.

---

## Messaging

Real-time text; voice notes (waveform + OGG Opus); photos with captions (send on iPhone); inline video/GIF/video-note playback; stickers (WebP + Lottie); reactions; replies; system-share of messages/media/locations; message info; delete for self/everyone; tappable URLs, Apple Music links, phone numbers, and addresses (open in Maps).

- **Disappearing messages** — per-chat auto-delete timer (Off / 1 Day / 1 Week / 1 Month), on both watch and iPhone.
- **Walkie-talkie (push-to-talk)** — hold to record a voice note, release to send; designated chats auto-play incoming voice notes. On the watch, **Lift to Speak** uses the wrist gesture (raise to record, lower to send) and holds the connection with an extended runtime session.
- **Secret chats** (end-to-end encrypted), **location sharing**, **contacts / new chats**, **chat folders**, pin/mute, read receipts, unread badges, **global + in-chat search**.
- **Siri & Shortcuts**, **watch-face complications**, **notifications** with smart link actions, **double-tap** gesture, account/session management, block/report, background sync, haptics.

---

## The AI agent channel

Designed for use with [OpenClaw](https://github.com/openclaw/openclaw) (or any agent framework on Telegram). Mark any chat as an assistant chat (brain icon); the agent then reaches the device three ways.

### 1. Telegram `#`-commands — the floor

Works anywhere with internet, no gateway needed. Natural-language queries ("what's your heart rate?") also work. Silent `#`-commands suppress the notification and reply in place.

**Read / status:** `#status` `#json` `#capabilities` `#session` `#health` `#heart` `#steps` `#rings` `#o2` `#sleep` `#workout` `#calendar` `#weather` `#music` `#battery` `#focus` `#noise` `#temp` `#vo2` `#speed` `#distance` `#respiratory` `#reminder` `#altitude`

- `#json` — a parseable JSON status snapshot (instead of prose)
- `#capabilities` — what this device can sense/do right now, plus the command list
- `#session` — the device's stable session id

**Act (actuators):** `#navigate <place>` · `#directions <place>` · `#play <song>` (opens Apple Music) · `#remind <text>` (iOS) · `#call <name>` · `#open <url>`

**Interrupt:** `#alert <text>` — a critical notification that bypasses silent/Focus · `#notify <text>` — time-sensitive

`#help` lists everything.

### 2. OpenClaw node — the structured tool channel

The phone (and the watch) register as first-class **OpenClaw nodes**, so the agent queries the device directly as JSON — no chat round-trip. Implemented to OpenClaw's real node protocol: a persistent Curve25519/Ed25519 device identity, a v3-signed connect over the gateway WebSocket, and `node.invoke` handling.

Node commands: `battery.get` `location.get` `health.snapshot` `device.info` `heart.get` `steps.get` `sleep.get` `workout.get` `calendar.get` `weather.get` `system.notify` — plus **watch-only sensors relayed from the phone over WatchConnectivity**: `watch.heart` `watch.temp` `watch.o2` `watch.rings` `watch.health`.

Configure the gateway URL + token in **Agent settings** on the phone; it syncs to the watch via iCloud. Pair the device once (`openclaw nodes approve`) — the identity travels, so it stays paired from any network.

### 3. Live voice

Full-duplex spoken channel: the app streams mic audio up and plays agent audio back over a WebSocket. The app is a dumb audio pipe — **the server does STT and TTS** (see **Server setup**). Works on iPhone and (foreground-only) on the watch. Echo cancellation is on, so barge-in triggers on you, not the agent's own voice.

### Trust & consent (applies to all of the above)

- **Per-category consent** — grant the agent Health / Location / Calendar / Media / Actions independently.
- **Command token** — an optional shared secret; commands must be sent as `#<token> <cmd>` or they're ignored.
- **Rate limiting** and a reviewable **audit log** of every agent query.
- **Interactive buttons** — inline keyboards on agent messages route taps back (callback / URL).
- **Proactive context** (iOS) — pushes "Arrived at / Left <place>" to assistant chats on location visits.

Configure it all in **Agent settings**.

---

## Server setup

The server side runs wherever OpenClaw runs — **Windows, Linux, or macOS**. None of it is Mac-only.

### OpenClaw gateway (the node channel)

```bash
npm install -g openclaw
openclaw gateway          # WebSocket server on 127.0.0.1:18789
```

Minimal `~/.openclaw/openclaw.json` — set a token and allowlist ClawWatch's node commands:

```json
{
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "port": 18789,
    "auth": { "mode": "token", "token": "<your-token>" },
    "nodes": {
      "allowCommands": [
        "battery.get", "location.get", "health.snapshot", "device.info",
        "heart.get", "steps.get", "sleep.get", "workout.get",
        "calendar.get", "weather.get", "system.notify",
        "watch.heart", "watch.temp", "watch.o2", "watch.rings", "watch.health"
      ]
    }
  }
}
```

You also need a model/LLM configured in OpenClaw for the agent to *use* the node. Pair the device with `openclaw nodes approve` on first connect.

### Live-voice server

A WebSocket server (default `:8790`) that turns audio into agent turns and back. Its contract — the fixed part the app already speaks:

| | |
|---|---|
| Transport | WebSocket, binary frames |
| Device → server | 16 kHz · mono · signed 16-bit LE PCM |
| Server → device | 24 kHz · mono · signed 16-bit LE PCM |
| Query params | `?token=<token>&device=<watch\|phone>` (the app appends these) |
| Turn-taking | server owns barge-in (`CW_BARGE_IN=1`; the app does echo cancellation) |

Inside it: Whisper (STT) → the OpenClaw agent → TTS (local MLX/Chatterbox for ~free, or a hosted voice). [openclaw-voice](https://github.com/Purple-Horizons/openclaw-voice) provides most of this. See [`docs/`](docs) if present, or the voice server's own README.

---

## Remote access with Cloudflare Tunnel

On the LAN the apps hit the gateway's local IP. Off-network, the standalone watch **cannot** join a Tailscale tailnet — but it *can* make a normal outbound `wss://` connection to a public hostname. So expose the gateway and voice server through a Cloudflare Tunnel.

### On the server

Use [`deploy/cloudflared-config.example.yml`](deploy/cloudflared-config.example.yml):

```bash
cloudflared tunnel login
cloudflared tunnel create clawwatch
# copy the example config to ~/.cloudflared/config.yml, fill in the UUID + hostnames
cloudflared tunnel route dns clawwatch gateway.example.com
cloudflared tunnel route dns clawwatch voice.example.com
cloudflared tunnel run clawwatch
# Cloudflare dashboard → Network → enable WebSockets
```

`cloudflared` runs on the box and reaches the services over loopback, so nothing binds `0.0.0.0` and no ports are opened. TLS is terminated at Cloudflare's edge, giving you `wss://` for free.

### In the app

In **Agent settings** (phone; syncs to the watch via iCloud), point the URLs at the public hostnames:

- Node gateway: `wss://gateway.example.com`
- Voice base URL: `wss://voice.example.com`

**No Cloudflare API keys are ever needed in the app** — it just connects to a URL. Two options for auth:

- **Plain tunnel** — the app's own `?token=` (voice) and the gateway's token + device pairing (node) are the auth. Nothing Cloudflare-specific in the app.
- **Cloudflare Access** (recommended for a public gateway) — generate a Zero Trust *service token* and enter its two values (`CF-Access-Client-Id` / `CF-Access-Client-Secret`) in Agent settings. The app adds them as headers to both the node and voice sockets; the edge rejects anything without them. Leave blank for the plain-tunnel path.

Use a **named** tunnel (stable hostname) rather than a quick `trycloudflare.com` URL, since the app syncs the URL to the watch.

---

## Building the apps (Xcode / macOS)

The apps build with Xcode on macOS. Targets: **ClawWatch iOS** (iPhone app, embeds the watch app) and **Mercury Watch App** (watchOS).

### 1. Telegram API credentials

Get an **API ID** and **API Hash** from [my.telegram.org](https://my.telegram.org) ([docs](https://core.telegram.org/api/obtaining_api_id)).

Copy `Mercury Watch App/Utils/Services/SecretService-sample.swift` to `SecretService.swift` (it's gitignored), rename the enum to `SecretService`, and fill in your `apiId` / `apiHash`.

### 2. Signing & identifiers

Set your own team and bundle IDs. This fork uses (team `ADVQS8RXPZ`, DoctorDuRant LLC):

| Target | Bundle ID |
|---|---|
| iPhone app | `com.doctordurant.clawwatch.ios` |
| Watch app | `com.doctordurant.clawwatch.ios.watchkitapp` |
| Widget | `com.doctordurant.clawwatch.ios.widget` |
| Notification Service | `com.doctordurant.clawwatch.ios.notificationservice` |
| Share extension | `com.doctordurant.clawwatch.ios.share` |

Shared entitlements: App Group `group.com.doctordurant.clawwatch`, iCloud key-value store `<TEAM>.com.doctordurant.clawwatch.shared` (this is what syncs agent/voice config from phone to watch). Capabilities to enable per target: Push, HealthKit, Background Modes (audio/voip/fetch/remote-notification/location), App Groups, iCloud (key-value), Critical Alerts.

### 3. Build & run

Open `Mercury.xcodeproj`, select the **ClawWatch iOS** scheme (or **Mercury Watch App**), and build. First build resolves the Swift packages (TDLibKit and friends).

**Device builds (`xcodebuild`) need `EXCLUDED_ARCHS=armv7k`.** The iPhone app embeds the watch app, so a device build also compiles the watch slice; TDLib can't link the 32-bit `armv7k` (Series 3) architecture, and TDLibKit's package manifest still lists it. Pass the flag on the command line — it's the only place that reaches the Swift-package build (project/target settings don't propagate to SPM targets):

```bash
xcodebuild -project Mercury.xcodeproj -scheme "ClawWatch iOS" \
  -destination "id=<device-udid>" -allowProvisioningUpdates \
  EXCLUDED_ARCHS=armv7k build
```

Xcode GUI builds to a paired 64-bit watch don't hit this. Note also that the **Critical Alerts** entitlement is removed by default — it needs per-account approval from Apple; re-add `com.apple.developer.usernotifications.critical-alerts` once granted.

---

## Security

- TDLib database encrypted at rest with a Keychain-stored key; file protection on sensitive directories.
- Keychain-based credential storage (incl. the node's device identity key).
- Voice recordings deleted immediately after sending; release builds suppress sensitive logging.
- The agent channel is gated by consent, an optional token, rate limiting, and an audit log.
- Dependencies pinned; privacy manifest included. `SecretService.swift` and `.mcp.json` are gitignored (real credentials stay local).

---

## Credits

ClawWatch is a fork of **[Mercury](https://github.com/mercurytelegram/Mercury)** by **Alessandro Alberti** ([@AlessandroAlberti](https://t.me/AlessandroAlberti)) and **Marco Tammaro** ([@MarcoTammaro](https://t.me/MarcoTammaro)) — the original standalone Apple Watch Telegram client. This fork adds the iPhone app, the AI agent channel, live voice, and the OpenClaw/Cloudflare integration.

Before opening a pull request, read the [contributor guidelines](CONTRIBUTING.md).
