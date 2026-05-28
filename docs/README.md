# Blue Switch

A macOS menu-bar utility that hands off Magic Keyboard, Magic Trackpad, and Magic Mouse between two Macs with one click — no KVM, no cables.

This is a security-hardened fork of [HoshimuraYuto/blue-switch](https://github.com/HoshimuraYuto/blue-switch). The original ships an unauthenticated, unencrypted LAN protocol that lets anyone on the same Wi-Fi take over your Bluetooth peripherals or spoof notifications. This fork replaces that channel with a sealed, mutually-authenticated channel keyed by a 9-character pairing code you share between your two Macs.

## Installation

1. Grab the latest build from the [releases page](https://github.com/MegaManSec/blue-switch/releases).
2. Unzip and move `Blue Switch.app` to `/Applications`.
3. First launch: macOS will block it because the build isn't signed. Right-click → Open, or System Settings → Privacy & Security → "Open Anyway".

## Setup

Do this on **both** Macs.

1. **Pair your peripherals to both Macs** at the macOS level (System Settings → Bluetooth). Apple's Magic devices remember multiple hosts but only connect to one at a time — Blue Switch flips which one currently holds the session.
2. Launch Blue Switch. Grant **Bluetooth** and **Local Network** permission when prompted.
3. Right-click the menu-bar icon → Settings:
   - **Peripheral** tab: tick the Magic devices you want Blue Switch to manage.
   - **Device** tab: pick the other Mac from "Available Devices."
4. **Pairing** tab — *new in this fork, required*:
   - On one Mac, click "Generate Code." A nine-character code appears.
   - On the other, click "Enter Code" and type it in.
   - Both Macs should show the same eight-character fingerprint after pairing. If they don't, you typed the code wrong.
5. Hit the sync button on the **Device** tab to share your peripheral list with the other Mac.

Until step 4 completes, the switch action and peripheral sync refuse to talk to the peer.

## Usage

| Action                    | Result                                              |
| ------------------------- | --------------------------------------------------- |
| Left-click menu bar icon  | Hand peripherals between the two Macs               |
| Right-click menu bar icon | Open Settings / show registered peripherals & peers |

## Troubleshooting

- Both Macs running Blue Switch, both showing "Paired" in the Pairing tab.
- Devices powered on; Bluetooth enabled.
- Same network; not blocked by firewall.
- Bluetooth and Local Network permissions granted in System Settings → Privacy & Security.

## Developer notes

Requirements: Xcode 16.1+, Swift 6.

Build:
```bash
xcodebuild -project "Blue Switch.xcodeproj" -scheme "Blue Switch" -configuration Debug build
```

Format on commit (optional):
```bash
sh ./setup-hooks.sh
```

This sets `core.hooksPath` to the in-repo `.hooks/` directory, so be aware you're trusting whatever lives there in your current checkout.

## Security model

The LAN channel uses a shared symmetric key derived from the nine-character pairing code via PBKDF2-HMAC-SHA256 (600k iterations) and stored in the Keychain. Per connection, both sides exchange a 32-byte nonce and derive direction-specific session keys via HKDF; messages are framed as length-prefixed ChaCha20-Poly1305 sealed boxes with monotonic counter nonces. Failed authentications are rate-limited per source IP (5 failures / 60s → 15-minute block).

Known limits:
- The build isn't code-signed or notarized.
- Forty-five bits of entropy in the pairing code is fine against an online attacker (rate limit makes brute force infeasible) but theoretically grindable offline if someone captures ciphertext. PBKDF2 stretching pushes the cost up but doesn't eliminate it; a PAKE would close the gap and is the obvious next step.

## License

GNU GPL v3.0. See [LICENSE](../LICENSE).
