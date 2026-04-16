# Known Issues — Godot Solana SDK MWA Integration

## Critical: sign_text_message() Opens a New MWA Session (Double Wallet Picker)

**Status:** SDK bug — needs fix in godot-solana-sdk Kotlin Android plugin

**Severity:** High — breaks UX for all non-Seed-Vault wallets (Phantom, Solflare, Backpack)

### The Problem

Per the MWA 2.0 spec, once a session is established via `authorize()`, all subsequent privileged operations (`sign_messages`, `sign_and_send_transactions`) should happen **within that same session**. The user picks their wallet ONCE during authorization and never again.

The Godot SDK violates this. Each method call creates a **separate MWA session**:

```cpp
// connect_wallet() opens session #1 — user picks wallet, approves
android_plugin.call("connectWallet", mobile_blockchain, mobile_identity_uri, mobile_icon_path, mobile_identity_name);

// sign_text_message() opens session #2 — user sees OS wallet picker AGAIN
android_plugin.call("signTextMessage", message);
```

In React Native, both operations happen inside a single `transact()` callback — one session, one picker:

```typescript
await transact(async (wallet) => {
  const auth = await wallet.authorize({...});     // user picks wallet once
  const sig = await wallet.signMessages({...});   // same session, no picker
});
```

### What Happens on Device

1. User taps "Connect" → OS wallet picker appears → user picks Phantom → Phantom approves → connected
2. App calls `sign_text_message("Sign in to...")` → OS wallet picker appears AGAIN → user must pick Phantom AGAIN
3. User is confused — they already picked their wallet

Same issue on delete: user is already signed in with Phantom, taps "Delete Account", and the OS wallet picker opens asking them to pick a wallet again.

### Root Cause (C++ Source)

From `src/wallet_adapter/wallet_adapter.cpp`:

- `connect_wallet()` calls the Android plugin's `connectWallet()` method with identity params — opens MWA session #1
- `sign_text_message()` calls the Android plugin's `signTextMessage()` method — opens MWA session #2 (no session reuse)
- `sign_message()` calls the Android plugin's `signTransaction()` method — opens MWA session #3

Each Android plugin method dispatches a separate `Intent`, starting a new MWA association handshake. The Kotlin plugin does not maintain a persistent MWA session across calls.

### How React Native / Kotlin SDKs Handle This

**React Native:** `transact()` opens ONE WebSocket session. All operations (`authorize`, `signMessages`, `signAndSendTransactions`) happen within the callback on that single session.

**Kotlin:** `walletAdapter.transact(sender) { authResult -> ... }` — same pattern. Single session, multiple operations.

**Godot SDK:** No `transact()` equivalent. Each method is a standalone intent. No session persistence.

### Current Workaround (Example App)

For wallets where the double picker is a UX problem (Phantom, Solflare, Backpack):
- **Authorize flow:** Skip `sign_text_message()` after `connect_wallet()`. The `connect_wallet()` authorization is already a valid MWA `authorize()` per the spec. Seed Vault does not show the OS picker for signing (it handles it natively), so sign_text_message works fine for Seed Vault.
- **Delete flow:** Same approach — use `sign_text_message()` only for Seed Vault. For other wallets, the prior `connect_wallet()` authorization is sufficient proof of wallet ownership.

### Required SDK Fix

The Kotlin Android plugin (`WalletAdapterAndroid`) needs a `transact()`-style session manager:

1. `connectWallet()` establishes the MWA session AND keeps the WebSocket open
2. `signTextMessage()` and `signTransaction()` reuse the existing session instead of opening a new one
3. Session closes when `deauthorize()` is called or the adapter is destroyed

This is listed as a grant deliverable under "Ensure API parity with React Native SDK for wallet methods."

### Affected Wallets

| Wallet | Double Picker? | sign_text_message Works? |
|--------|---------------|-------------------------|
| Seed Vault | No (native, no OS picker) | Yes |
| Jupiter | No (native) | Yes |
| Phantom | **Yes** — picker shows again | Yes (if user picks wallet again) |
| Solflare | **Yes** — picker shows again | Yes (if user picks wallet again) |
| Backpack | **Yes** — picker shows again | Untested |

### References

- [MWA 2.0 Spec — Session Lifecycle](https://solana-mobile.github.io/mobile-wallet-adapter/spec/spec.html)
- [React Native transact() API](https://docs.solanamobile.com/get-started/react-native/mobile-wallet-adapter)
- [Kotlin transact() API](https://docs.solanamobile.com/get-started/kotlin/quickstart)
- Godot SDK source: `src/wallet_adapter/wallet_adapter.cpp` — `sign_text_message()`, `connect_wallet()`
- GitHub issue filed: Virus-Axel/godot-solana-sdk#445

---

## Medium: Cannot Identify Which Wallet the User Selected from OS Picker

**Status:** SDK limitation — `wallet_uri_base` not captured from MWA authorize response

### The Problem

After the OS wallet picker returns and `connect_wallet()` succeeds, the app has no way to know which wallet the user chose. The `wallet_type` property on WalletAdapter is an INPUT (set before connecting to target a specific wallet) — it is NOT updated based on which wallet responded.

### Why It Matters

Apps need to know the connected wallet for:
- Displaying the wallet name/icon in the UI
- Storing the wallet type in a database for user profiles
- Routing wallet-specific operations (e.g., Seed Vault biometric vs Phantom signing)

### What the MWA Spec Provides

The MWA 2.0 `AuthorizationResult` includes:
- `wallet_uri_base` (optional) — a URI that identifies the wallet endpoint (e.g., `https://phantom.app/...`)
- `wallet_icon` (optional) — a data URI with the wallet's icon

These could be used to identify which wallet handled the request.

### What the Godot SDK Discards

From `MyComposable.kt` (Kotlin Android plugin):
```kotlin
// ONLY these two fields are captured from AuthorizationResult:
authToken = result.authResult.authToken
myConnectedKey = result.authResult.publicKey

// wallet_uri_base — NOT read, NOT stored
// wallet_icon — NOT read, NOT stored
// accounts[].label — NOT read, NOT stored
```

From `wallet_adapter.cpp` (C++ layer):
```
// Only these Android plugin methods exist:
getConnectedKey()      // returns pubkey bytes
getConnectionStatus()  // returns int
// NO getWalletUriBase()
// NO getWalletIcon()
// NO getWalletName()
```

### Workaround: In-App Wallet Picker (How SolPulse Does It)

Since the SDK can't report which wallet was used, the alternative is to build an in-app wallet picker — buttons for each wallet in the app's own UI. When the user taps a wallet button, the app:

1. Sets `wallet_adapter.wallet_type = provider_id` (e.g., 20 for Phantom, 25 for Solflare)
2. Calls `wallet_adapter.connect_wallet()` — the SDK targets that specific wallet
3. Stores the `provider_id` alongside the pubkey in the app's auth cache or database

This is the pattern used by the SDK's own `WalletAdapterUI` class and by production apps like SolPulse:

```gdscript
# From godot-solana-sdk's wallet_service.gd:
func login_adapter(provider_id: int) -> void:
    wallet_adapter.wallet_type = provider_id
    wallet_adapter.connect_wallet()

# Known wallet type IDs:
# 20 = Phantom
# 25 = Solflare
# 36 = Backpack
# 40 = Jupiter
# -1 = Seed Vault (default)
```

**Trade-off:** This replaces the OS wallet picker with an in-app picker. The user selects the wallet in your app's UI instead of the Android system picker. Both approaches are valid — the OS picker is simpler UX but loses wallet identity.

### Required SDK Fix (Proper Solution)

To support wallet identification with the OS picker (no in-app picker needed):

1. **`MyComposable.kt`** — read and store `wallet_uri_base` from `AuthorizationResult`:
   ```kotlin
   authToken = result.authResult.authToken
   myConnectedKey = result.authResult.publicKey
   myWalletUriBase = result.authResult.walletUriBase  // ADD THIS
   ```

2. **`GDExtensionAndroidPlugin.kt`** — add getter method:
   ```kotlin
   fun getWalletUriBase(): String = myWalletUriBase ?: ""
   ```

3. **`wallet_adapter.cpp`** — bind to GDScript:
   ```cpp
   String WalletAdapter::get_wallet_uri_base() {
       return android_plugin.call("getWalletUriBase");
   }
   ```

This would let GDScript read `wallet_adapter.get_wallet_uri_base()` after connection and identify the wallet without needing an in-app picker.

---

## Medium: auth_token Not Exposed to GDScript

**Status:** SDK limitation

The MWA `authorize()` response includes an `auth_token` for silent reauthorization on subsequent sessions. The Godot SDK's Kotlin plugin receives this token but does not surface it to C++ or GDScript.

**Impact:** `reauthorize()` cannot use a cached token — falls back to full `authorize()` every time, requiring user interaction.

**Required fix:** Expose `get_auth_token()` method on WalletAdapter.

---

## Medium: deauthorize() Not Exposed to GDScript

**Status:** SDK limitation

The MWA spec defines `deauthorize(auth_token)` to invalidate authorization. The Godot SDK does not expose this method. All probes return false:
```
probe deauthorize=false
probe clear_state=false
```

**Impact:** "Delete Account" / "Disconnect" cannot properly revoke the wallet's authorization. We can only clear local state and destroy the WalletAdapter.

**Required fix:** Expose `deauthorize()` method on WalletAdapter. Requires `auth_token` to be available first.

---

## Low: Pubkey Error Spam When Key is Empty

**Status:** Workaround in place (`_key_available` flag)

`wallet_adapter.get_connected_key()` returns an empty `Pubkey` object when not connected. Calling `str()` on it triggers C++ `Pubkey::from_bytes` validation that logs "Pubkey must be 32 bytes" every frame.

**Workaround:** `_key_available` flag prevents calling `get_connected_key()` until `connection_established` signal fires.

**Required fix:** SDK should return `null` instead of an empty Pubkey object, or `from_bytes` should not log errors for empty input.

---

## Low: WalletAdapterAndroid plugin.gdextension Load Error

**Status:** Expected, harmless

```
ERROR: Error loading GDExtension configuration file: 'res://addons/WalletAdapterAndroid/plugin.gdextension'
```

This appears on every launch. The WalletAdapterAndroid is loaded as an AAR via the Gradle build system, not as a GDExtension. Godot scans for `.gdextension` files and logs an error when it can't find one. Non-fatal — the plugin works correctly via the AAR path.

---

## Failed Fix Attempts — 2026-04-15 Session

### Attempt 1: sign_and_send — Add clearState() + STEP logging to mwa_manager.gd

**What was tried:** Added `plugin.call("clearState")` before `signAndSendTransaction()` to reset stale `myMessageSigningStatus`. Added STEP_1-8 numbered logs. Changed sign_and_send from the old "sign via wallet + RPC send" to direct MWA 2.0 approach (no RPC resubmission).

**What actually happened:** The code was reverted by the user before testing because other changes broke things first.

**Why it failed:** Got bundled with other changes that broke the app. Never tested in isolation.

### Attempt 2: sign_and_send — Set tx.url_override to mainnet RPC

**What was tried:** Added `tx.url_override = AppConfig.get_rpc_url()` to fix devnet blockhash issue. Solflare was showing "Network mismatch — transaction is for devnet." Phantom was silently rejecting (CancellationException). All wallets were failing because `Transaction.new()` defaults to devnet RPC.

**What actually happened:** This fix was correct and verified working — Jupiter successfully signed and sent (status=1, got 64-byte signature). But the old GDScript code then tried to re-submit the already-broadcast transaction via RPC `sendTransaction`, passing `str(PackedByteArray)` as "base64" — RPC rejected with `"invalid base64 encoding: InvalidByte(0, 91)"`.

**Root cause confirmed:** Transaction objects default to devnet RPC when `url_override` is not set. This fix (setting url_override) is correct and should be re-applied.

### Attempt 3: sign_and_send — Remove RPC re-submission from mwa_manager.gd

**What was tried:** Rewrote `sign_and_send_transactions()` to remove the HTTP `sendTransaction` RPC call. MWA 2.0 `signAndSendTransactions` has the wallet broadcast — no need to re-submit. Just extract the 64-byte signature and return it.

**What actually happened:** Jupiter test succeeded with this change (got signature `36e69c56...`). Backpack crashed ("Backpack has stopped") — caused by 0-lamport transfer, not by this change.

**Why it failed:** Got reverted along with everything else. The fix itself was correct.

### Attempt 4: sign_and_send — Change 0-lamport to 100-lamport transfer

**What was tried:** Changed `SystemProgram.transfer(payer, payer, 0)` to `SystemProgram.transfer(payer, payer, 100)` in `_on_sign_and_send()`. 0-lamport transfers crash Backpack ("Cannot read property 'err' of undefined").

**What actually happened:** Never tested — got reverted with everything else.

### Attempt 5: SIWS authorize — Replace connect_wallet() with connectWalletSiws()

**What was tried:** Changed `authorize()` in mwa_manager.gd to call the Kotlin plugin's `connectWalletSiws()` instead of the C++ WalletAdapter's `connect_wallet()`. SIWS combines authorize + sign-in into one MWA session.

**What actually happened:** SIWS worked intermittently. Phantom succeeded on second attempt (first failed with CancellationException — activity destroyed). Backpack and Jupiter SIWS worked. But it was unreliable — sometimes the `ComposeWalletActivity` is destroyed by Android before the wallet returns the result.

**Root cause (from Phantom state logs):** Phantom processes BOTH MWA requests correctly (`authorize` then `signMessages`). User approves both. But the response for `signMessages` is lost because the local MWA WebSocket server dies when Android destroys `ComposeWalletActivity`. The `authorize` response arrives in ~2s (before destruction). The `signMessages` response arrives in ~4-5s (after destruction). Race condition.

### Attempt 6: SIWS — Convert connectWalletSiws from @Composable to standalone CoroutineScope

**What was tried:** Changed `connectWalletSiws` from a `@Composable` function with `LaunchedEffect` to a `suspend` function launched in `CoroutineScope(Dispatchers.Main + SupervisorJob())`. Same pattern as `signAndSendTransactionAsync` which works reliably.

**What actually happened:** Made SIWS WORSE. Changed the error from intermittent `CancellationException` (sometimes works) to consistent `TimeoutException` (never works). The standalone scope keeps the coroutine alive, but the `ActivityResultSender` dies with the activity. The MWA WebSocket server can't deliver responses without a live sender. `signAndSendTransaction` works with standalone scope because it completes in ~8s (cached auth, no user interaction). SIWS takes 10-30s (two user prompts).

**Why it failed:** The `ActivityResultSender` is tied to the activity lifecycle. Keeping the coroutine alive is useless if the sender is dead. The LaunchedEffect version at least sometimes works because the Compose lifecycle keeps the sender alive slightly longer.

### Attempt 7: SIWS — Add auto-retry in GDScript authorize()

**What was tried:** Wrapped the SIWS call + polling in a retry loop (max 2 attempts). Theory: first attempt warms up the wallet, second attempt succeeds because wallet responds faster.

**What actually happened:** Never tested — got reverted with everything else. The auto-retry wouldn't have helped anyway because the WebSocket death happens on every attempt regardless.

---

## Key Findings from 2026-04-15 Session

1. **Transaction url_override is required.** `Transaction.new()` defaults to devnet RPC. Must set `tx.url_override` to mainnet. This fix is confirmed correct.

2. **sign_and_send should NOT re-submit via RPC.** MWA 2.0 `signAndSendTransactions` has the wallet broadcast. The GDScript side should just extract the signature. The old code's `str(PackedByteArray)` → `sendTransaction` approach is broken (invalid base64).

3. **0-lamport transfers crash Backpack.** Use non-zero amount (100 lamports) for sign_and_send.

4. **SIWS WebSocket dies with ComposeWalletActivity.** The MWA clientlib's `LocalAssociationScenario` starts a local WebSocket server that is activity-bound. When Android destroys the activity (~4s after wallet opens), the WebSocket dies. The `authorize` response arrives before destruction (~2s), but `signMessages` response arrives after (~4-5s). This is why SIWS works intermittently — it's a race condition.

5. **Standalone CoroutineScope does NOT fix SIWS.** The coroutine survives but the `ActivityResultSender` and WebSocket are dead. Makes things worse (TimeoutException vs intermittent CancellationException).

6. **signAndSendTransaction works with standalone scope** because it uses cached auth token and completes in ~8s without user interaction. SIWS requires two user prompts and takes too long.
