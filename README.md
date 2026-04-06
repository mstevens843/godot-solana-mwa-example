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

## License

MIT
