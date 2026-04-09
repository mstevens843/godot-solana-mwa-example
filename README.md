# MWA Example App — Godot

Minimal Godot 4.x Android app demonstrating all Solana Mobile Wallet Adapter (MWA) 2.0 API methods with Seed Vault integration on Solana Seeker.

## Features

- **Authorize** — Connect wallet via MWA (Seed Vault picker)
- **Reauthorize** — Silent reconnect with cached auth token
- **Deauthorize** — Revoke wallet authorization
- **Sign Message** — Sign an arbitrary text message
- **Sign Transaction** — Sign a serialized transaction
- **Sign & Send Transaction** — Sign and broadcast to network
- **Get Capabilities** — Query wallet limits and supported versions
- **Auth Cache** — Persistent file-based token storage with extensible interface
- **Delete Account** — Deauthorize + clear all cached data

## Prerequisites

- Godot 4.2+ (download from https://godotengine.org)
- Android SDK + NDK (for Android export)
- `godot-solana-sdk` plugin (https://github.com/Virus-Axel/godot-solana-sdk)
- Solana Seeker or Android device with a MWA-compatible wallet (Phantom, Solflare, Seed Vault)

## Setup

1. **Install Godot 4.x**
   ```bash
   brew install --cask godot
   ```

2. **Clone this project**
   ```bash
   cd ~/Desktop/grant-godot
   ```

3. **Install godot-solana-sdk**
   - Download the latest release from https://github.com/Virus-Axel/godot-solana-sdk/releases
   - Copy the `addons/SolanaSDK/` folder into this project's `addons/` directory
   - In Godot: Project > Project Settings > Plugins > Enable "Solana SDK"

4. **Add WalletAdapter node**
   - Open `scenes/Main.tscn` in Godot
   - The MWAManager autoload will look for a WalletAdapter child node
   - Add a WalletAdapter node to the scene tree (provided by the plugin)

5. **Configure Android Export**
   - Editor > Editor Settings > Export > Android: set SDK/NDK paths
   - Project > Export > Add Android preset
   - Set package name, min SDK (API 24+), keystore

6. **Build & Run**
   - Export to Android APK
   - Install on Seeker: `adb install -r mwa-example.apk`
   - Tap "Connect Wallet" → Seed Vault picker should appear

## Project Structure

```
grant-godot/
├── project.godot          # Project config + autoloads
├── scenes/
│   ├── Main.tscn          # Landing page (Connect button)
│   └── Home.tscn          # Home page (all MWA method buttons)
├── scripts/
│   ├── main.gd            # Landing page logic
│   ├── home.gd            # Home page logic (7 action buttons)
│   ├── mwa_manager.gd     # MWA singleton (authorize, sign, cache)
│   ├── auth_cache.gd      # File-based auth token cache
│   └── app_config.gd      # App identity config
├── assets/
│   └── icon.png           # App icon
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
Wallet App (Seed Vault / Phantom / Solflare)
```

## Testing on Solana Seeker (or any Android device)

### Prerequisites

- Solana Seeker or Android device connected via USB
- USB debugging enabled on the device
- Android SDK installed (adb is at `~/Library/Android/sdk/platform-tools/adb`)

### First-time setup: Fix macOS Gatekeeper

The SDK's native libraries get quarantined by macOS when downloaded. You **must** clear this before exporting or the native types (`WalletAdapter`, `Pubkey`, `Keypair`, etc.) won't load on the device:

```bash
xattr -cr ~/Desktop/grant-godot/addons/SolanaSDK/bin/
```

### The .gdextension file

The file `addons/SolanaSDK/bin/godot-solana-sdk.gdextension` tells Godot which native libraries to package per platform. **If this file is missing, the APK will build without errors but crash at runtime** with:

```
WalletAdapter class not available. Install godot-solana-sdk plugin and enable it.
```

If you see this error, verify the file exists. If not, copy it from the SDK release:

```bash
cp ~/Downloads/SolanaSDK/bin/godot-solana-sdk.gdextension ~/Desktop/grant-godot/addons/SolanaSDK/bin/
```

Then re-export the APK from Godot.

### Export APK

1. Open the project in Godot: `open /Applications/Godot.app ~/Desktop/grant-godot/project.godot`
2. **Project > Export > Android > Export Project**
3. Save as `mwa-example.apk`

### Install and run

```bash
# Uninstall old version and install new APK
~/Library/Android/sdk/platform-tools/adb uninstall com.example.mwaexample && ~/Library/Android/sdk/platform-tools/adb install ~/Desktop/grant-godot/mwa-example.apk

# Start log monitoring (run in a separate terminal)
~/Library/Android/sdk/platform-tools/adb logcat -c && ~/Library/Android/sdk/platform-tools/adb logcat -s godot

# Launch the app
~/Library/Android/sdk/platform-tools/adb shell monkey -p com.example.mwaexample -c android.intent.category.LAUNCHER 1
```

### What to look for in logs

Success — native library loaded:
```
[MWAManager] _setup_wallet_adapter | FOUND wallet_adapter=WalletAdapter
```

Failure — native library missing (see .gdextension section above):
```
[MWAManager] _setup_wallet_adapter | NOT_FOUND — WalletAdapter class not available
```

### Test flows

| Flow | Expected Toast | Seed Vault Steps |
|------|---------------|------------------|
| Connect | "Authorized: ABC..." | Wallet picker → approve → biometric |
| Sign Message | "Message signed: ..." | Verify → biometric |
| Disconnect | "Wallet disconnected" | None |
| Reconnect | "Reauthorizing with cached token..." | Wallet picker → approve → biometric |
| Delete Account | "Account deleted, cache cleared" | Verify → biometric → clear all |

## License

MIT
