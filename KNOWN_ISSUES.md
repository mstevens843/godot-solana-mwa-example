# Known Issues — Godot Solana SDK MWA Integration

> **If you're catching up on this app for the first time:** the first three sections below (Phantom `sign_messages`, Solflare `sign_messages`, Backpack `sign_and_send_transactions`) are *wallet*-side bugs/gaps that shaped how this example app routes each button. Each has a specific per-wallet workaround in `scripts/mwa_manager.gd`. Everything after is SDK-level (Godot Solana SDK) or dev-UX notes.

---

## High: Phantom Mobile Does Not Implement `sign_messages` Over MWA

**Status:** Wallet-side gap — worked around in this example by routing Phantom's **Delete Account** flow through a throwaway `sign_transaction` (0-lamport self-transfer) instead of `sign_messages`. The signed tx is NEVER broadcast; the signature is proof of consent.
**Severity:** Was High (delete hung indefinitely on Phantom before the fix).
**Affects:** Phantom Mobile (`app.phantom`). Same gap exists in Cocos and Unity example apps.

### What actually happens

Connect Phantom via MWA, then call `signTextMessage` or `sign_messages`. Phantom opens, the user sees an approve screen — but the response never reaches the dApp. One of two failure modes:
1. The request hangs for ~90 seconds, then the MWA client lib's internal timer fires a `TimeoutException` wrapped in `ExecutionException`.
2. After ~5-10 seconds the WebSocket closes from Phantom's side with a null-cause `CancellationException` (no protocol-level reply).

### Why (evidence)

Phantom Mobile's `get_capabilities` response advertises only MWA 1.x sign-and-send support — it never declares sign_messages:

```
features=["supports_sign_and_send_transactions"]  max_txs=10  max_msgs=1  versions=["legacy","0"]
```

Per the MWA spec, `features[]` is the authoritative list of implemented methods. Phantom simply has no handler for `sign_messages` on Android MWA. `max_msgs=1` is an advisory per-batch ceiling, not a support flag — it means nothing by itself. Calling the unimplemented method reliably fails because the wallet doesn't know to send a protocol-level error; it just closes the socket or lets the internal timer expire.

### Workaround in this example app

`scripts/mwa_manager.gd` `delete_account()` detects Phantom (`connected_wallet_type == WALLET_PHANTOM = 20`) and routes through `_confirm_delete_via_throwaway_tx()`:

1. Build a minimal `SystemProgram.transfer(payer, payer, 0)` — a 0-lamport self-transfer. Zero economic effect.
2. `tx.update_latest_blockhash()` via the configured RPC.
3. `tx.serialize()` → pass the bytes to `sign_transaction()` which calls MWA `sign_transactions` on Phantom (which it DOES implement).
4. A non-empty returned signature = user approved = proceed with local cache clear.
5. **The signed tx is NEVER broadcast.** The blockhash harmlessly expires. No lamports spent, no memo or transfer hits chain. The signature alone is proof of ownership.

This same gate is ALSO used for Solflare (see next section). Other wallets (Backpack, Jupiter, Seed Vault) continue to use the `sign_message` path for delete confirmation.

### Related Phantom-side issue: Blowfish transaction-warning modals

Even when `sign_transactions` works, Phantom's on-device transaction simulator (Blowfish) evaluates the originating dApp and stacks "this app may be malicious" warning modals in front of the approve screen when the dApp is unverified. Triggers:
- `APP_URI` is a placeholder (`https://example.com`).
- `APP_NAME` contains "Example" / "Test" / "Demo".
- `CLUSTER` is `mainnet-beta` (stricter threshold than devnet).
- dApp not on Phantom's verified allowlist.

**Mitigation:** Production dApps should register their domain with Phantom's dApp verification program and use a real identity in `scripts/app_config.gd`. The current Grant demo uses the `example.com` placeholder; production ports should replace it.

---

## High: Solflare Mobile Does Not Implement `sign_messages` Over MWA

**Status:** Wallet-side gap — worked around in this example by routing Solflare's **Delete Account** flow through the same throwaway `sign_transaction` gate as Phantom. The older workaround (re-auth via `connect_wallet()`) is superseded.
**Severity:** Was High (delete "crashed" on Solflare before).
**Affects:** Solflare Mobile (`com.solflare.mobile`).

### What actually happens

Call `signTextMessage` on a Solflare MWA session. Solflare opens, shows an approve screen, then closes the WebSocket ~7 seconds later without a protocol-level result. Same `CancellationException msg=null` pattern previously attributed to a "Solflare crash" — the underlying cause is simpler: Solflare has no handler for this method.

### Why (evidence)

Solflare's `get_capabilities` response advertises `solana:signTransactions` but NOT `solana:signMessages`:

```
features=["solana:signTransactions"]  max_txs=20  max_msgs=20  versions=["legacy","0"]
```

Like Phantom, Solflare never declares sign_messages — no handler. `max_msgs=20` is advisory and meaningless for support. The wallet has no handler, so it closes the connection.

### Workaround in this example app

Same `_confirm_delete_via_throwaway_tx()` gate used for Phantom — see `scripts/mwa_manager.gd` `delete_account()`. Works cleanly; nothing broadcast. Historically Solflare used a re-authorization loop (`connect_wallet()` + polling connection result), which also worked but caused a second wallet picker flash. The throwaway-tx gate is the unified Phantom/Solflare path now.

Note: Solflare does NOT run a Blowfish-style transaction simulator. You will not see "this app may be malicious" modals on Solflare for the same transactions Phantom warns about.

---

## High: Backpack Mobile `sign_and_send_transactions` Crashes

**Status:** Wallet-side bug — worked around in this example by routing Backpack's **Sign & Send** button through Godot SDK's `Transaction.sign()` + `Transaction.send()` pattern (sign via MWA, broadcast via Solana JSON-RPC) instead of the native MWA `sign_and_send_transactions`. Same bug exists in Cocos and Unity example apps (both have matching workarounds).
**Severity:** High (the Sign & Send button was unusable on Backpack).
**Affects:** Backpack Mobile (`app.backpack`).

### What actually happens

Call MWA's native `sign_and_send_transactions` with Backpack connected. About 19 seconds pass with no wallet UI response, then the WebSocket closes from Backpack's side. The MWA client library surfaces this as a `CancellationException`. Backpack's own internal logs (not visible to dApps) show:

```
kotlinx.serialization.json.internal.JsonDecodingException:
  Class discriminator was missing in SolanaMobileWalletAdapterWalletLibModule
```

Backpack's Kotlin plugin fails to deserialize the sign_and_send RPC request and silently crashes the handler. Their `sign_transactions` handler is NOT affected.

### Workaround in this example app

`scripts/mwa_manager.gd` `sign_and_send_transactions()` checks `connected_wallet_type`. If it's `WALLET_BACKPACK` (36), the code routes through `_sign_and_broadcast_via_rpc()`:

1. Reconstruct each raw tx into a Godot `Transaction` node via `Transaction.new_from_bytes()`.
2. `tx.set_signers([wallet_adapter])` so the WalletAdapter is the signer.
3. `tx.sign()` + `await tx.fully_signed` — this triggers an MWA `sign_transactions` call to the wallet. Backpack's sign_transactions handler is correct; one wallet intent, one user approval.
4. `tx.url_override = AppConfig.get_rpc_url()` then `tx.send()` — broadcasts the signed tx to the configured Solana RPC endpoint. This is Godot SDK's native RPC broadcast, same as used by the MplCore/honeycomb examples.
5. `await tx.transaction_response_received` → collect the base58 signature from the RPC response.

Same UX as the native path (one wallet approval), tx lands on chain, works every time. For every wallet OTHER than Backpack, the native MWA `signAndSendTransaction` path is retained — no behavior change for Phantom, Solflare, Jupiter, or Seed Vault.

### Why split by wallet instead of always using sign+RPC?

Seed Vault has a smoother native sign_and_send UX because it can submit the tx from inside the secure enclave without a separate RPC roundtrip. Keeping the native path for non-Backpack wallets preserves that UX.

---

## Connect defaults to plain `authorize` (NOT SIWS)

**Status:** By design for this Grant demo (`AppConfig.USE_SIWS := false`).

The Connect button calls `connect_wallet()` → Kotlin plugin `connectWallet()` → MWA 1.x `authorize`. SIWS (MWA 2.0 Sign-In-With-Solana, which bundles a signed sign-in message into the authorize response) is deliberately NOT the default here because:

- Not every mobile wallet implements SIWS (Seed Vault, specifically).
- SIWS adds a second wallet confirmation screen at connect time, increasing connect-flow friction for a dev/demo app.
- The Grant scope didn't require the signed-in-message.

Set `AppConfig.USE_SIWS := true` to opt into SIWS. `scripts/mwa_manager.gd` `authorize()` branches on this flag — see `_authorize_siws()` vs `_authorize_standard()`.

---

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

---

## High: `InsufficientFundsForRent` on Sign & Send — Underfunded Fee-Payer (Especially via Seed Vault)

**Status:** Worked around at the SDK layer — `mwa_manager.gd` does a pre-broadcast balance check and maps RPC-side rent errors to `last_error_code = "INSUFFICIENT_FUNDS_FOR_RENT"` so `home.gd` can tell the user to fund the account. Not a code bug; a funding problem.
**Severity:** Was Medium (user-confusing). The sign succeeded, the user saw the wallet approve, and then the transaction silently failed at RPC broadcast with a generic "Sign & send failed" message.
**Affects:** Any fee-payer with a balance below `rent_exempt_min + tx_fee + priority_fee_buffer` (~0.001 SOL). Especially visible with **Seed Vault** (the Solana Seeker's default wallet) because its Solflare-built wrapper injects ComputeBudget priority-fee instructions before signing — this raises the required balance before the tx ever reaches the RPC. Also hits **Phantom on Solana Seeker** because Phantom uses the same Seed Vault secure element there.

### What actually happens

Tap Sign & Send with a fee-payer whose balance is just barely above Solana's rent-exempt minimum (890,880 lamports). The base tx fee (~5000 lamports) plus Seed Vault's injected priority fees drops the account below rent, and preflight rejects:

```
code=-32002 "Transaction simulation failed: Transaction results in an account (0) with insufficient funds for rent"
err={"InsufficientFundsForRent":{"account_index":0}}
```

Signed-tx inflation is the fingerprint — unsigned memo tx is ~203 bytes, Seed Vault returns a signed tx of ~255 bytes (+52 bytes = one `SetComputeUnitLimit` + one `SetComputeUnitPrice` instruction plus the extra account for the `ComputeBudget111…` program).

### Why (evidence-backed)

- **Rent-exempt minimum for a zero-data System-owned account is 890,880 lamports** — ~0.00089 SOL. See [Solana accounts docs](https://solana.com/docs/core/accounts).
- **Seed Vault is a signing-only secure element behind a Solflare wrapper** — [Seed Vault Wallet blog post](https://blog.solanamobile.com/post/seed-vault-wallet----solana-seekers-native-mobile-wallet) confirms this. Its MWA `get_capabilities` reply only lists `solana:signTransactions`.
- **MWA 2.0 spec self-contradicts** on `solana:signAndSendTransaction` — "mandatory feature" but "implementation of this method by a wallet endpoint is optional." Seed Vault's capabilities reply is spec-compliant given that carve-out. See [MWA 2.0 spec](https://solana-mobile.github.io/mobile-wallet-adapter/spec/spec.html).
- **`skipPreflight: true` does NOT help** — Solana validators recheck rent at execution. The tx lands on-chain, fails at execution, and the fee is burned.

### Fix

1. **Pre-broadcast balance check** — `mwa_manager.gd` `sign_and_send_transactions` fetches the fee-payer balance via raw `HTTPRequest`-based `getBalance` before any wallet intent is opened. If `lamports < 1_000_000` (covers 890_880 rent + ~5_000 fee + ~100_000 priority-fee buffer), short-circuit with `last_error_code = "INSUFFICIENT_FUNDS_FOR_RENT"` — no wallet approval screen appears.
2. **RPC-side error detection** — `_sign_and_broadcast_via_rpc` (the Backpack sign+RPC fallback path) parses the `response["error"]` string for `InsufficientFundsForRent` and sets the same `last_error_code`. Handles the edge case where the balance was just above the threshold pre-check but the wallet's priority-fee injection pushed it over.
3. **UI toast** — `home.gd` `_on_sign_and_send` branches on `MWAManager.last_error_code`. On `INSUFFICIENT_FUNDS_FOR_RENT` it shows "Fee-payer underfunded — send ≥0.001 SOL to {pubkey} and retry".

### How to reproduce

1. Connect Seed Vault (on Seeker) or Phantom (using the Seeker's Seed Vault keypair) with a fee-payer balance near the rent-exempt minimum (fund it with exactly 0.0009 SOL). Tap Sign & Send. Expected: immediate "Fee-payer underfunded" message, no wallet intent opens. Logcat: `STEP_PREFLIGHT_FAIL balance=890880 required=~1000000`.
2. Send 0.01 SOL to the fee-payer from another wallet. Retry Sign & Send. Balance check passes, sign completes, tx lands on-chain.
3. Regression check: Backpack / Solflare / Jupiter with funded accounts — Sign & Send works unchanged.

### Files

- `scripts/mwa_manager.gd` — added `last_error_code` public variable, pre-flight balance check in `sign_and_send_transactions`, rent-error parse in `_sign_and_broadcast_via_rpc`, `_fetch_balance_lamports` HTTPRequest helper.
- `scripts/home.gd` — `_on_sign_and_send` branches on `last_error_code == "INSUFFICIENT_FUNDS_FOR_RENT"` to show the truthful message.

---

## Low: Jupiter Mobile `get_capabilities` Confirm Modal Renders Blank

**Status:** Wallet-side bug — no dApp-side fix. Documented so contributors don't waste cycles on it.
**Severity:** Cosmetic. The RPC response still makes it back to the app, so Get Capabilities returns the correct result. The modal UI just fails to render content.
**Affects:** Jupiter Mobile wallet (`ag.jup.app`).

### Symptom

Connect Jupiter → tap Get Capabilities → Jupiter opens its own bottom-sheet confirm modal. The modal frame renders but the content never loads — no message, no Approve button, no Reject button. Tapping outside dismisses it, and the dApp still receives a correct capabilities response. Nothing actionable on our side.

### Why (hypothesis)

Jupiter's public mobile adapter [TeamRaccoons/jup-mobile-adapter](https://github.com/TeamRaccoons/jup-mobile-adapter) is a WalletConnect/Reown wrapper, not a native MWA protocol wallet. That architectural mismatch likely explains the modal content failing to render. Per MWA spec, `get_capabilities` is a pure query that should not require user interaction at all, but Jupiter shows a confirm modal anyway (and fails to populate it). Zero GitHub issues filed in `jup-ag/*` or `TeamRaccoons/*` mentioning this.

### Fix

None on our side. Workaround for users: tap outside the modal to dismiss it — the capabilities response still arrives.

---

## Pass 14: `USE_MWA_SIGN_AND_SEND=false` now actually broadcasts

**Status:** Bug fix. The feature flag existed in `scripts/app_config.gd` before Pass 14, but flipping it off produced a sign-only path that printed *"RPC send not implemented (sign-only mode)"* and returned without broadcasting anything — the tx was signed but not on-chain.
**Severity:** Flag was advertised as a routing switch but didn't send transactions in the OFF position.
**Affects:** Anyone setting `USE_MWA_SIGN_AND_SEND=false`. Defaults (`true`) were never affected.

### What changed

`scripts/mwa_manager.gd` `sign_and_send_transactions()` now routes the `not AppConfig.USE_MWA_SIGN_AND_SEND` branch into the existing `_sign_and_broadcast_via_rpc()` helper (the same path Backpack uses unconditionally). One wallet prompt, tx signed via MWA `sign_transactions`, broadcast via `SolanaClient.send_transaction`. Toast and status updates now reflect a real on-chain signature.

### Result

Flag matrix now matches Cocos defaults and actually works:

| `USE_MWA_SIGN_AND_SEND` | Non-Backpack wallets | Backpack |
|---|---|---|
| `true` (default) | Native MWA `sign_and_send_transactions` (wallet broadcasts) | Forced to `_sign_and_broadcast_via_rpc` — wallet's native handler crashes |
| `false` | `_sign_and_broadcast_via_rpc` — sign via MWA, broadcast via RPC | Same (unchanged by flag) |

### Cross-reference

Cocos's per-wallet matrix (`../cocos-solana-mwa/WALLET_COMPATIBILITY.md`) documents exact wallet behaviour; Godot reaches the same matrix after this fix.
