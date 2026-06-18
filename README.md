<p align="center">
  <img src="docs/assets/icon.png" alt="Magic Switch app icon" width="200">
</p>

<h1 align="center">Magic Switch</h1>

A macOS menu-bar utility that hands off Magic Keyboard, Magic Trackpad, and Magic Mouse between two Macs with one click — no KVM, no cables.

This is a security-hardened fork of [HoshimuraYuto/blue-switch](https://github.com/HoshimuraYuto/blue-switch). The original ships an unauthenticated, unencrypted LAN protocol that lets anyone on the same Wi-Fi take over your Bluetooth peripherals or spoof notifications. This fork replaces that channel with a sealed, mutually-authenticated channel keyed by a 12-character pairing code you share between your two Macs — with a massively improved UI/UX over the original: a guided pairing flow, inline status feedback, per-peripheral switching, a needs-attention menu-bar icon, and safe preflight-and-rollback handoffs.

<p align="center">
  <img src="docs/assets/menu.png" alt="The Magic Switch menu-bar dropdown" width="340"><br>
  <em>It lives in the menu bar: click a Mac to move every peripheral to it, or a single peripheral to move just that one. A checkmark marks whatever's on this Mac right now.</em>
</p>

## Installation

1. Grab the latest build from the [releases page](https://github.com/MegaManSec/magic-switch/releases).
2. Unzip and move `Magic Switch.app` to `/Applications`.
3. First launch: macOS will block it because the build isn't signed. Right-click → Open, or System Settings → Privacy & Security → "Open Anyway".
4. Approve **Bluetooth** and **Local Network** access when macOS prompts. Both are required — Bluetooth to control the peripherals, Local Network to discover and talk to the other Mac. If you dismiss the prompts, grant them later under System Settings → Privacy & Security.

## Setup

Magic Switch has four Settings tabs, and two of them use the word "pair" in different senses — which trips people up. **Pairing** is the cryptographic key shared between the two *Macs* (required, and set up inside Magic Switch); the Bluetooth pairing of your *peripherals* is a separate thing, done in System Settings. Do everything below on **both** Macs.

### 1. Pair your peripherals to each Mac (System Settings)

In **System Settings → Bluetooth on each Mac**, pair your Magic Keyboard / Mouse / Trackpad to *that* Mac the normal macOS way — **each peripheral has to be paired to both Macs**. Apple's Magic devices remember multiple hosts but only connect to one at a time; Magic Switch flips which Mac currently holds a peripheral, but it doesn't create those pairings for you. (Once that's done, you won't re-pair by hand on every switch — Magic Switch handles the handoff.)

Then launch Magic Switch, grant **Bluetooth** and **Local Network** when prompted, and right-click the menu-bar icon → **Settings**.

### 2. Peripheral tab — choose what to manage

Tick the Magic devices you want Magic Switch to hand back and forth. Each row's leading icon shows the detected device type; click it to override the type or reset it to Automatic.

<p align="center">
  <img src="docs/assets/peripheral-tab.png" alt="Peripheral tab showing registered and available peripherals" width="600"><br>
  <em>Peripheral tab — register the Magic devices you want to hand off. Each row's leading icon shows the detected device type.</em>
</p>

<p align="center">
  <img src="docs/assets/peripheral-type-picker.png" alt="Peripheral tab with a row's type picker open" width="600"><br>
  <em>That leading icon is also a picker — Magic Switch auto-detects the type (keyboard, mouse, trackpad, headphones, AirPods, microphone), and you can override it or set it back to Automatic.</em>
</p>

### 3. Device tab — pick the other Mac

Choose the other Mac under **Available Devices**. It shows up once it's on the same network running Magic Switch; a greyed-out row means it isn't reachable right now.

<p align="center">
  <img src="docs/assets/device-tab.png" alt="Device tab showing the connected Mac and available devices" width="600"><br>
  <em>Device tab — pick the other Mac, sync peripherals to it, and check it's reachable.</em>
</p>

### 4. Pairing tab — link the two Macs (required)

Generate a twelve-character code on one Mac and enter it on the other; either direction works, since both Macs derive the same key from the same code. They should then show the same eight-character fingerprint — if they differ, the code was mistyped. Until this is done, switching and peripheral sync refuse to talk to the peer.

<p align="center">
  <img src="docs/assets/pairing-not-paired.png" alt="Pairing tab before pairing" width="600"><br>
  <em>Before pairing — Generate a code on one Mac; Enter it on the other.</em>
</p>

<p align="center">
  <img src="docs/assets/pairing-generate-dialog.png" alt="Generated pairing code dialog" width="420">
  <img src="docs/assets/pairing-enter-dialog.png" alt="Enter pairing code dialog" width="420"><br>
  <em>Left: the code one Mac generates (Copy it). Right: type that code on the other Mac.</em>
</p>

<p align="center">
  <img src="docs/assets/pairing-paired.png" alt="Pairing tab after pairing, showing the fingerprint" width="600"><br>
  <em>After pairing — both Macs show the same fingerprint. If they differ, the code was mistyped.</em>
</p>

### 5. Sync your peripherals to the other Mac

On the **Device** tab, find the other Mac under **Connected Devices** and click its **Share** button (the box-with-an-up-arrow, beside **Ping**). A "Synced N peripherals to …" line confirms it. The button is greyed out while that Mac is offline.

### Other tab — preferences

**Launch at Login**, two peripheral-handling toggles (**Release peripherals when this Mac sleeps** and **Reconnect peripherals if they drop** — see [Troubleshooting](#troubleshooting)), the installed version, and update notifications (see [Updates](#updates)).

<p align="center">
  <img src="docs/assets/other-tab.png" alt="Other tab showing app preferences" width="600"><br>
  <em>Other tab — Launch at Login, the sleep-release and auto-reconnect toggles, license info, version, and a manual update check.</em>
</p>

## Usage

| Action                                  | Result                                                                                          |
| --------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Click the menu-bar icon (either button) | Open the menu |
| Menu → a Mac | Hand all peripherals between this Mac and that one |
| Menu → a peripheral | Switch just that one peripheral. Checkmark = currently on this Mac |
| Menu → Settings | Open the Settings window |

The menu-bar icon also signals state: a **warning triangle** means Magic Switch needs attention (not paired, or Bluetooth off/denied) — hover for the reason; **up/down arrows** flash briefly while peripherals are moving between Macs (the dropdown is pictured at the top of this README).

## Updates

Magic Switch tells you when there's a new version — it never updates itself. About once a day it makes a single anonymous request to GitHub's public releases API for [this repo](https://github.com/MegaManSec/magic-switch/releases) and compares your installed version with the latest published release; no account, sign-in, or telemetry is involved. When a newer version exists, an **Update Available** notice (with the new version number) appears at the top of the right-click menu and in **Settings → Other** — clicking it opens the release page so you can download and install it yourself. A failed check (offline, rate-limited, etc.) is retried about hourly; otherwise checks happen at most once every 24 hours. Your installed version is always shown in **Settings → Other**.

## Troubleshooting

- Both Macs running Magic Switch, both showing "Paired" in the Pairing tab.
- Devices powered on; Bluetooth enabled.
- Same network; not blocked by firewall.
- Bluetooth and Local Network permissions granted in System Settings → Privacy & Security.
- A **greyed-out device** — in the Device tab or the right-click menu — means it isn't reachable on the network right now (the other Mac is asleep, off Wi-Fi, or not running Magic Switch). Ping, Sync, and switching stay disabled until it's back online.
- On the **Device** tab, **Ping** tests whether the two Macs can reach each other over the secure channel.
- **Closing or sleeping one Mac hands its peripherals to the other.** When this Mac sleeps (or you close its lid), it hands the peripherals it holds to your other Mac — or, if that Mac isn't reachable yet, frees them so it can pick them up the moment it wakes. That's why you can close one Mac and find the keyboard and mouse already on the other. This is on by default; you can turn it off under **Settings → Other → "Release peripherals when this Mac sleeps."**
- **A peripheral didn't come back after sleep or a lid-close.** Apple's Magic devices sometimes get stuck once the Bluetooth radio sleeps and won't reconnect — even a manual reconnect fails until you switch the peripheral **off and on** with its power switch. Magic Switch keeps watching for anything that was on this Mac before it slept: the moment the device reappears (which a power-cycle triggers), it reconnects automatically — as long as your other Mac isn't actively using it. This is on by default; you can turn it off under **Settings → Other → "Reconnect peripherals if they drop."**

## Developer notes

Requirements: Xcode 16.1+ (Swift 5 language mode).

Build:
```bash
xcodebuild -project "Magic Switch.xcodeproj" -scheme "Magic Switch" -configuration Debug build
```

Format on commit (optional):
```bash
sh ./setup-hooks.sh
```

This sets `core.hooksPath` to the in-repo `.hooks/` directory, so be aware you're trusting whatever lives there in your current checkout.

## Architecture

Two Macs discover each other over Bonjour, then exchange short commands over a sealed TCP channel keyed by the shared pairing code.

```
                  Bonjour discovery (_magicswitch._tcp. in local.)
                 ┌──────────────────────────────────────────────────┐
                 │                                                  │
                 ▼                                                  ▼
   ┌────────────────────────────┐                    ┌────────────────────────────┐
   │  Mac A — Magic Switch      │                    │  Mac B — Magic Switch      │
   │                            │                    │                            │
   │   AppDelegate              │                    │   AppDelegate              │
   │   (status item, menu)      │                    │   (status item, menu)      │
   │       │         ▲          │                    │       │         ▲          │
   │       ▼         │          │     sealed TCP     │       ▼         │          │
   │   Outgoing  Incoming       │◀── ChaCha20-Poly ─▶│   Outgoing  Incoming       │
   │   Conn.     Conn.          │    (per session)   │   Conn.     Conn.          │
   │       │         │          │                    │       │         │          │
   │       ▼         ▼          │                    │       ▼         ▼          │
   │   NetworkDeviceStore       │                    │   NetworkDeviceStore       │
   │   BluetoothPeripheralStore │                    │   BluetoothPeripheralStore │
   │   PairingStore             │                    │   PairingStore             │
   │       │                    │                    │       │                    │
   │       ▼ IOBluetooth        │                    │       ▼ IOBluetooth        │
   │   Magic Keyboard           │ one host at a time │   Magic Keyboard           │
   │   Magic Trackpad           │ (peripherals owned │   Magic Trackpad           │
   │   Magic Mouse              │  by whichever Mac  │   Magic Mouse              │
   │                            │  took them last)   │                            │
   └────────────────────────────┘                    └────────────────────────────┘
```

## Security model

The LAN channel uses a shared symmetric key derived from the twelve-character pairing code via PBKDF2-HMAC-SHA256 (600k iterations) and stored in the Keychain. Per connection, both sides exchange a 32-byte nonce and derive direction-specific session keys via HKDF; messages are framed as length-prefixed ChaCha20-Poly1305 sealed boxes with monotonic counter nonces. Failed authentications are rate-limited per source IP (5 failures / 60s → 15-minute block), and the client side backs off after 5 failed outgoing attempts in the same window.

Each Mac pins the other's key fingerprint the first time it sees it (trust on first use). If a later advertisement carries a *different* fingerprint, that peer is dropped and the Device tab makes you explicitly **Trust** the new identity before switching resumes — so a key change or impersonation attempt is surfaced rather than silently accepted.

Known limits:
- The build isn't code-signed or notarized.
- Sixty bits of entropy in the pairing code is fine against an online attacker (rate limit makes brute force infeasible) but theoretically grindable offline if someone captures ciphertext. PBKDF2 stretching pushes the cost up but doesn't eliminate it; a PAKE would close the gap and is the obvious next step.

## License

GNU GPL v3.0. See [LICENSE](LICENSE).
