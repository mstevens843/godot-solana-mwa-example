# Next Steps — Godot MWA Example App

## Immediate (Before First Run)

1. **Install Godot 4.2+**
   ```bash
   brew install --cask godot
   ```

2. **Install godot-solana-sdk plugin**
   - Download latest release from https://github.com/Virus-Axel/godot-solana-sdk/releases
   - Copy `addons/SolanaSDK/` into `grant-godot/addons/`
   - Open project in Godot → Project > Project Settings > Plugins → Enable "Solana SDK"

3. **Add WalletAdapter node to MWAManager autoload**
   - The MWAManager autoload is already configured in `project.godot`
   - In the Godot editor, go to Project > Project Settings > Autoload
   - Select MWAManager → Add a `WalletAdapter` child node (from plugin)
   - OR: modify `mwa_manager.gd` `_setup_wallet_adapter()` to create one programmatically

4. **Configure Android export**
   - Editor > Editor Settings > Export > Android → set SDK/NDK paths
   - Project > Export > Add Android preset
   - Package name: `com.example.mwaexample`
   - Min SDK: API 24
   - Sign with keystore

5. **Build and install on Seeker**
   ```bash
   adb install -r mwa-example.apk
   ```

## First Run — What to Watch For

Run `adb logcat | grep -E "\[MWAManager\]|\[AuthCache\]|\[Main\]|\[Home\]|\[AppConfig\]"` while testing.

Expected log flow for Connect:
```
[AppConfig] _ready | START
[AppConfig] _ready | app_name=MWA Example App ...
[AuthCache] _init | START
[AuthCache] _load | NO_FILE creating empty cache
[MWAManager] _ready | START
[MWAManager] _setup_wallet_adapter | FOUND wallet_adapter=WalletAdapter
[Main] _ready | START
[Main] _ready | DONE cached_auth=false
--- user taps Connect ---
[Main] _on_connect_pressed | START
[MWAManager] authorize | START
[MWAManager] authorize | calling wallet_adapter.connect_wallet()
--- Seed Vault picker should appear ---
[MWAManager] _on_connected | SIGNAL RECEIVED pubkey=ABC...
[MWAManager] authorize | SUCCESS pubkey=ABC...
[AuthCache] set_auth | START pubkey=ABC...
[Main] _on_authorized | changing to Home scene
[Home] _ready | START
[Home] _ready | connected_pubkey=ABC... is_connected=true
```

## After Connect Works — Fill In SDK Methods

### Sign Transaction (requires SDK transaction builder)
In `home.gd` `_on_sign_transaction()`, replace placeholder with:
```gdscript
# Build a memo transaction
var tx = Transaction.new()
# Add memo instruction via SDK
var serialized = tx.serialize()
var sig = await MWAManager.sign_transaction(serialized)
```

### Sign & Send (requires SDK + RPC)
In `home.gd` `_on_sign_and_send()`:
```gdscript
var tx = Transaction.new()
# Build real transaction
var sigs = await MWAManager.sign_and_send_transactions([tx.serialize()])
```

### Get Capabilities (requires SDK support)
In `mwa_manager.gd` `get_capabilities()`, replace placeholder with actual SDK call when the Godot SDK adds `get_capabilities` to the Kotlin plugin.

### Deauthorize (requires SDK support)
In `mwa_manager.gd` `deauthorize()`, add actual SDK call when `deauthorize` is added to the Kotlin plugin layer.

## Grant Deliverable Checklist

- [ ] Connect wallet (authorize) — Seed Vault picker appears
- [ ] Pubkey displays on Home screen
- [ ] Sign Message — shows signature
- [ ] Sign Transaction — signs a memo tx
- [ ] Sign & Send — signs and broadcasts
- [ ] Get Capabilities — shows wallet limits
- [ ] Reconnect — silent reauthorize with cached token
- [ ] Disconnect — clears session, returns to Landing
- [ ] Delete Account — clears session + cache
- [ ] Auth cache persists across app restarts
- [ ] All logs visible in `adb logcat`
- [ ] README complete with setup instructions
- [ ] Tested on Solana Seeker with Seed Vault

## Debugging

All deterministic logs use the format: `[Component] method | key=value`

Filter logs:
```bash
# All MWA logs
adb logcat | grep -E "\[(MWAManager|AuthCache|Main|Home|AppConfig)\]"

# Just auth flow
adb logcat | grep "\[MWAManager\] authorize"

# Just cache operations
adb logcat | grep "\[AuthCache\]"

# Just UI events
adb logcat | grep -E "\[(Main|Home)\]"
```
