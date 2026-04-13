# MWA Example App — Godot

Minimal Godot 4.x Android app demonstrating all Solana Mobile Wallet Adapter (MWA) 2.0 API methods with multi-wallet support (Seed Vault, Phantom, Solflare, Backpack, Jupiter) on Solana Seeker.

## What This Project Does

Brought the Godot Mobile Wallet Adapter SDK to parity with the React Native SDK. Found and fixed 10 integration bugs during testing, submitted a `clearState()` SDK fix ([PR #449](https://github.com/Virus-Axel/godot-solana-sdk/pull/449)) to enable proper disconnect/reconnect flows. Built a complete example app verified on Solana Seeker hardware with all five MWA wallet providers. All flows working: connect, disconnect, reconnect fresh, reconnect cached, delete account, sign message.

Related: [Issue #445 - 10 bugs found during integration](https://github.com/Virus-Axel/godot-solana-sdk/issues/445)

## Features

- **Authorize** — Connect wallet via MWA with OS wallet picker (all installed wallets)
- **Reauthorize** — Instant reconnect using cached auth token (no wallet interaction)
- **Deauthorize** — Disconnect and clear local authorization state
- **Sign Message** — Sign an arbitrary text message (Seed Vault uses biometric, Phantom uses in-app approval)
- **Sign Transaction** — Sign a serialized transaction
- **Sign & Send Transaction** — Sign and broadcast to network
- **Get Capabilities** — Query wallet limits and supported versions
- **Auth Cache** — Persistent file-based token storage at `user://auth_cache.json`
- **Delete Account** — Sign confirmation + deauthorize + clear all cached data + destroy adapter
- **Multi-Wallet Support** — Seed Vault, Phantom, Solflare, Backpack, Jupiter
- **Fresh Connect** — `clearState()` SDK fix ensures OS picker opens after disconnect (no stale cache)
- **Cached Reconnect** — Separate reconnect button uses AuthCache directly without touching the SDK

## Wallet Support

| Wallet | Connect | Disconnect | Reconnect (Fresh) | Reconnect (Cached) | Sign Message | Delete Account |
|--------|---------|------------|-------------------|-------------------|--------------|----------------|
| Seed Vault | Yes | Yes | Yes | Yes | Yes (biometric) | Yes (biometric) |
| Phantom | Yes | Yes | Yes | Yes | Skipped (SDK session limit) | Yes (sign confirmation) |
| Solflare | Yes | Yes | Yes | Yes | Skipped (SDK session limit) | Yes (connect confirmation) |
| Backpack | Yes | Yes | Yes | Yes | Skipped (SDK session limit) | Yes (sign confirmation) |
| Jupiter | Yes | Yes | Yes | Yes | Skipped (SDK session limit) | Yes (sign confirmation) |

Non-Seed-Vault wallets skip the sign-in step during authorize because the Godot SDK opens a separate MWA session for each method call. `sign_text_message()` in a new unauthorized session fails on these wallets. This is a known SDK limitation documented in [KNOWN_ISSUES.md](KNOWN_ISSUES.md).

## SDK Fix: clearState()

The core SDK fix that makes disconnect/reconnect work. Without this, `connectWallet()` silently returns the cached connection after the first connect and never opens the OS picker again.

**Root cause:** `clearState()` only reset `myMessageSigningStatus` but did not clear `myResult`. The `connectWallet()` function checks `if (myResult is TransactionResult.Success) { return }` and skips the wallet picker entirely.

**Fix:** Added `myResult = null` to `clearState()` in `GDExtensionAndroidPlugin.kt`. Full writeup: [SDK_CLEARSTATE_FIX.md](SDK_CLEARSTATE_FIX.md)

**PR:** [#449 - fix: clearState() now resets myResult to enable disconnect/reconnect](https://github.com/Virus-Axel/godot-solana-sdk/pull/449)

## Prerequisites

- Godot 4.2+ (download from https://godotengine.org)
- Android SDK + NDK (for Android export)
- `godot-solana-sdk` plugin (https://github.com/Virus-Axel/godot-solana-sdk)
- Solana Seeker or Android device with an MWA-compatible wallet

## Setup

1. **Install Godot 4.x**
   ```bash
   brew install --cask godot
   ```

2. **Clone this project**
   ```bash
   git clone https://github.com/mstevens843/godot-solana-mwa-example.git
   cd godot-solana-mwa-example
   ```

3. **Install godot-solana-sdk**
   - Download the latest release from https://github.com/Virus-Axel/godot-solana-sdk/releases
   - Copy the `addons/SolanaSDK/` folder into this project's `addons/` directory
   - In Godot: Project > Project Settings > Plugins > Enable "Solana SDK"

4. **Configure Android Export**
   - Editor > Editor Settings > Export > Android: set SDK/NDK paths
   - Project > Export > Add Android preset
   - Set package name, min SDK (API 24+), keystore

5. **Build & Run**
   - Export to Android APK
   - Install on Seeker: `adb install -r mwa-example.apk`
   - Tap "Connect Wallet" to open the OS wallet picker

## Project Structure

```
godot-solana-mwa-example/
├── project.godot              # Project config + autoloads
├── scenes/
│   ├── Main.tscn              # Landing page (Connect + Reconnect buttons)
│   └── Home.tscn              # Home page (all MWA method buttons)
├── scripts/
│   ├── main.gd                # Landing page logic (OS picker + cached reconnect)
│   ├── home.gd                # Home page logic (sign, disconnect, delete)
│   ├── mwa_manager.gd         # MWA singleton (authorize, sign, cache, clearState)
│   ├── auth_cache.gd          # File-based auth token cache
│   └── app_config.gd          # App identity config
├── addons/SolanaSDK/          # godot-solana-sdk plugin (with rebuilt AAR)
├── SDK_CLEARSTATE_FIX.md      # Detailed writeup of the clearState SDK fix
├── KNOWN_ISSUES.md            # 8 documented SDK limitations with workarounds
├── MWA_API_REFERENCE.md       # MWA 2.0 method reference (React Native + Godot)
├── MWA_INTEGRATION_REPORT.md  # 10 bugs found during integration testing
└── README.md
```

## Architecture

```
GDScript (mwa_manager.gd)
    ↓ calls
C++ GDExtension (WalletAdapter node from godot-solana-sdk)
    ↓ calls
Kotlin Android Plugin (wraps mobile-wallet-adapter-clientlib-ktx:2.0.3)
    ↓ Android Intent
Wallet App (Seed Vault / Phantom / Solflare / Backpack / Jupiter)
```

## Testing on Solana Seeker (or any Android device)

### Prerequisites

- Solana Seeker or Android device connected via USB
- USB debugging enabled on the device
- Android SDK installed (adb is at `~/Library/Android/sdk/platform-tools/adb`)

### First-time setup: Fix macOS Gatekeeper

The SDK's native libraries get quarantined by macOS when downloaded. You must clear this before exporting or the native types (`WalletAdapter`, `Pubkey`, `Keypair`, etc.) won't load on the device:

```bash
xattr -cr addons/SolanaSDK/bin/
```

### Export APK

1. Open the project in Godot
2. Project > Export > Android > Export Project
3. Save as `mwa-example.apk`

### Install and run

```bash
# Install APK
adb install -r mwa-example.apk

# Start log monitoring (run in a separate terminal)
adb logcat -c && adb logcat -s godot

# Or filter for app-specific logs only
adb logcat -c && adb logcat | grep -E "\[MWAManager\]|\[AuthCache\]|\[Main\]|\[Home\]|\[KotlinPlugin\]"
```

### Test flows

| Flow | Expected Result |
|------|----------------|
| Connect | OS wallet picker opens, select wallet, approve, lands on Home screen |
| Sign Message | Wallet opens for signing approval, signature returned |
| Disconnect | Returns to landing page, Reconnect (cached) button appears |
| Reconnect (cached) | Instant reconnect using AuthCache, no wallet interaction |
| Connect (after disconnect) | `clearState()` called, OS picker opens fresh |
| Delete Account | Sign confirmation in wallet, cache cleared, returns to landing page |
| Connect (after delete) | `clearState()` called, OS picker opens fresh, clean slate |

## Documentation

- [SDK_CLEARSTATE_FIX.md](SDK_CLEARSTATE_FIX.md) — Root cause analysis and fix for the disconnect/reconnect bug
- [KNOWN_ISSUES.md](KNOWN_ISSUES.md) — 8 documented SDK limitations with workarounds
- [MWA_API_REFERENCE.md](MWA_API_REFERENCE.md) — Complete MWA 2.0 method reference
- [MWA_INTEGRATION_REPORT.md](MWA_INTEGRATION_REPORT.md) — 10 bugs found and fixed during integration testing

## License

MIT
