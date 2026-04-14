# SDK Fix: `clearState()` Must Reset `myResult` to Enable Disconnect/Reconnect

**Issue:** [#445](https://github.com/Virus-Axel/godot-solana-sdk/issues/445) — Bug #5: "No `clear_state()` or reset method exposed to GDScript; stale pubkey persists after deauthorize"

**Status:** Fixed and tested on Solana Seeker hardware with Phantom, Seed Vault

**SDK Version:** godot-solana-sdk v1.4.5, Godot 4.6.2 stable

---

## The Problem

After connecting to a wallet via `connect_wallet()`, calling deauthorize/disconnect, and then calling `connect_wallet()` again, the OS wallet picker **never reopens**. The SDK silently returns the cached connection from the previous session. Users cannot switch wallets or reconnect fresh.

### Root Cause

In `GDExtensionAndroidPlugin.kt`, `connectWallet()` has an early return that prevents reopening the wallet picker:

```kotlin
// Line 51 — GDExtensionAndroidPlugin.kt (BEFORE fix)
@UsedByGodot
fun connectWallet(cluster: Int, uri: String, icon: String, name: String) {
    if (myResult is TransactionResult.Success) {
        return  // ← RETURNS IMMEDIATELY. Never opens wallet picker again.
    }
    // ... opens ComposeWalletActivity ...
}
```

The existing `clearState()` method only resets `myMessageSigningStatus` — it does NOT clear `myResult`:

```kotlin
// Line 120 — GDExtensionAndroidPlugin.kt (BEFORE fix)
@UsedByGodot
fun clearState() {
    myMessageSigningStatus = 0  // ← Only clears signing status. myResult stays cached.
}
```

Since `myResult` is never cleared, `connectWallet()` always hits the early return after the first successful connection, for the entire lifetime of the app process.

### Why This Matters for the Grant

The Solana Mobile grant requires: *"Ensure users can easily disconnect, deauthorize, and reconnect."* Without this fix, disconnect→connect silently reuses the cached connection. The user never sees the wallet picker and cannot switch wallets.

---

## The Fix

### Change to `GDExtensionAndroidPlugin.kt`

**File:** `android/plugin/src/main/java/plugin/walletadapterandroid/GDExtensionAndroidPlugin.kt`

```kotlin
// AFTER fix — clearState() now resets myResult
@UsedByGodot
fun clearState() {
    myResult = null              // ← NEW: Clears the connection cache check
    myMessageSigningStatus = 0   // ← Existing: Resets signing status
}
```

**What changed:** Added `myResult = null` to `clearState()`.

**What this does:** When `clearState()` is called before `connectWallet()`, the early return check `if (myResult is TransactionResult.Success)` evaluates to `false` (because `myResult` is now `null`), so `connectWallet()` proceeds to open `ComposeWalletActivity` — which shows the OS wallet picker.

**What we intentionally did NOT change:**
- `myConnectedKey` is NOT cleared — signing operations (`signTextMessage`, `signTransaction`) need it
- `authToken` is NOT cleared — signing operations need it for MWA session reuse
- The C++ `WalletAdapter` layer calls `clearState()` internally before launching sign activities, so clearing `myConnectedKey`/`authToken` would break all signing

### Deterministic Logging Added

```kotlin
// connectWallet() now logs whether it opens the picker or returns cached
@UsedByGodot
fun connectWallet(cluster: Int, uri: String, icon: String, name: String) {
    Log.i("godot", "[KotlinPlugin] connectWallet | START myResult=${myResult?.javaClass?.simpleName}")
    if (myResult is TransactionResult.Success) {
        Log.i("godot", "[KotlinPlugin] connectWallet | CACHED — returning immediately")
        return
    }
    Log.i("godot", "[KotlinPlugin] connectWallet | FRESH — opening ComposeWalletActivity")
    // ...
}

// clearState() logs what it cleared
@UsedByGodot
fun clearState() {
    Log.i("godot", "[KotlinPlugin] clearState | clearing myResult (was ${myResult?.javaClass?.simpleName})")
    myResult = null
    myMessageSigningStatus = 0
}
```

---

## How the Example App Uses It

The GDScript `MWAManager` calls `clearState()` on the `WalletAdapterAndroid` singleton before each fresh `connect_wallet()` call:

```gdscript
# In authorize() — called by the Connect button
func authorize(wallet_type_id: int = -1) -> bool:
    # Clear Java-side cached connection so connectWallet() opens OS picker
    var plugin = Engine.get_singleton("WalletAdapterAndroid")
    plugin.call("clearState")
    
    # Destroy and recreate WalletAdapter node (clears C++ layer cache)
    # ... adapter destroy/recreate ...
    
    # Now connect_wallet() will open the wallet picker fresh
    wallet_adapter.connect_wallet()
```

The **Reconnect (cached)** button does NOT call `clearState()` — it reads the pubkey directly from a local `AuthCache` file without touching the SDK at all.

---

## Tested Flows (All Working)

| Flow | Result |
|------|--------|
| Fresh app launch → Connect | OS picker opens, user selects wallet |
| Connected → Disconnect → Connect | `clearState()` called → OS picker opens fresh |
| Connected → Disconnect → Reconnect (cached) | Uses local AuthCache, no SDK call, instant |
| Connected → Delete Account → Connect | `clearState()` called → OS picker opens fresh |
| Connected → Sign Message (Phantom) | `signTextMessage()` works, signing succeeds |
| Connected → Delete Account (sign confirmation) | `signTextMessage()` works, deletion confirmed |

---

## Files Changed

| File | Change |
|------|--------|
| `GDExtensionAndroidPlugin.kt` | `clearState()` now sets `myResult = null` + logging |
| `GDExtensionAndroidPlugin.kt` | `connectWallet()` — added logging for CACHED vs FRESH |
| `GDExtensionAndroidPlugin.kt` | `getConnectionStatus()` — removed per-frame log spam |
| `GDExtensionAndroidPlugin.kt` | Added `getCapabilitiesWallet()`, `getCapabilitiesStatus()`, `getCapabilitiesResult()` |
| `MyComposable.kt` | Added `myCapabilitiesResult`/`myCapabilitiesStatus` vars + `getWalletCapabilities()` Composable |
| `MyComponentActivity.kt` | Added `myAction == 3` routing for getCapabilities |

---

## SDK Fix #2: `getCapabilities()` — Query Wallet Capabilities

The MWA 2.0 spec includes `get_capabilities` for querying wallet limits and supported features. The Godot SDK did not expose this method. We added it to the Kotlin plugin.

### Root Cause

`GDExtensionAndroidPlugin.kt` had no `getCapabilities` method. The MWA client library (`mobile-wallet-adapter-clientlib-ktx:2.0.3`) has `getCapabilities()` available inside `walletAdapter.transact{}`, but the Godot plugin never called it.

### Changes

**MyComposable.kt** — Added static vars and Composable function:
```kotlin
var myCapabilitiesResult: String = ""
var myCapabilitiesStatus: Int = 0  // 0=pending, 1=success, 2=failed

@Composable
fun getWalletCapabilities(sender: ActivityResultSender) {
    // Opens MWA session, calls getCapabilities(), stores result as key=value string
    val result = walletAdapter.transact(sender) { getCapabilities() }
    // Stores: maxTransactions, maxMessages, supportsCloneAuth, supportsSignAndSend,
    //         supportedVersions, optionalFeatures
}
```

**MyComponentActivity.kt** — Added action routing:
```kotlin
else if (myAction == 3) {
    val sender = ActivityResultSender(this)
    setContent { getWalletCapabilities(sender) }
}
```

**GDExtensionAndroidPlugin.kt** — Added trigger and getters:
```kotlin
@UsedByGodot
fun getCapabilitiesWallet()  // Sets myAction=3, launches ComposeWalletActivity

@UsedByGodot
fun getCapabilitiesStatus(): Int  // 0=pending, 1=success, 2=failed

@UsedByGodot
fun getCapabilitiesResult(): String  // Comma-separated key=value pairs
```

### Return Values

The `GetCapabilitiesResult` from the MWA client contains:
- `maxTransactionsPerSigningRequest` (int)
- `maxMessagesPerSigningRequest` (int)
- `supportsCloneAuthorization` (boolean)
- `supportsSignAndSendTransactions` (boolean)
- `supportedTransactionVersions` (Object[])
- `supportedOptionalFeatures` (String[])

### GDScript Usage

```gdscript
var caps := await MWAManager.get_capabilities()
# caps = { "maxTransactions": "10", "maxMessages": "10", "supportsCloneAuth": "false", ... }
```

---

## Build Instructions

```bash
cd godot-solana-sdk/android
echo "sdk.dir=/path/to/Android/sdk" > local.properties
JAVA_HOME=$(/usr/libexec/java_home -v 17) ./gradlew :plugin:assembleDebug :plugin:assembleRelease
```

Output AARs:
- `plugin/build/outputs/aar/WalletAdapterAndroid-debug.aar`
- `plugin/build/outputs/aar/WalletAdapterAndroid-release.aar`

Copy to project:
```bash
cp plugin/build/outputs/aar/WalletAdapterAndroid-debug.aar \
   your-project/addons/SolanaSDK/WalletAdapterAndroid/bin/debug/
cp plugin/build/outputs/aar/WalletAdapterAndroid-release.aar \
   your-project/addons/SolanaSDK/WalletAdapterAndroid/bin/release/
```
