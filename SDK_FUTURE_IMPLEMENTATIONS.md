# SDK Future Implementations — godot-solana-sdk MWA 2.0

Remaining MWA 2.0 gaps in Virus-Axel/godot-solana-sdk.
Reference repo: https://github.com/Virus-Axel/godot-solana-sdk

## Active Development Branches

Working on authorize MWA 2.0 update + signAndSendTransactions together:

| Repo | Branch | Path |
|------|--------|------|
| godot-solana-sdk (fork) | `feat/authorize-2.0-sign-and-send-txs` | `~/Desktop/godot-solana-sdk` |
| Godot Example App | `feat/authorize-2.0-sign-and-send-txs` | `~/Desktop/grant-godot` |

Both repos have `main` untouched as the working fallback.

---

## Current Godot MWA Architecture

The Godot SDK uses the **Kotlin MWA clientlib-ktx** (NOT a pure reimplementation like Unity). The MWA layer is:

| File | Path | What it does |
|------|------|-------------|
| GDExtensionAndroidPlugin.kt | `android/plugin/src/main/java/plugin/walletadapterandroid/` | Godot plugin bridge -- exposes to GDScript: `connectWallet`, `signTransaction`, `signTextMessage`, `setIdentity`, `clearState` |
| MyComposable.kt | same dir | Jetpack Compose composables with actual MWA logic. Creates `MobileWalletAdapter`, calls `connect()`, `transact()` with `signTransactions()` / `signMessagesDetached()` |
| MyComponentActivity.kt | same dir | `ComposeWalletActivity` -- transparent Activity routed by `myAction` (0=connect, 1=signTx, 2=signMessage) |

**Key details:**
- Uses `MobileWalletAdapter` from `com.solanamobile:mobile-wallet-adapter-clientlib-ktx` (high-level Kotlin wrapper)
- Global state vars: `myResult`, `authToken`, `myConnectedKey`, `myAction`, etc.
- `signTransaction` uses `walletAdapter.transact(sender) { signTransactions(...) }` -- sign only, returns signed bytes
- Example app broadcasts via GDScript HTTPRequest RPC separately (app-side send)
- `connectWallet` uses `walletAdapter.connect(sender)` -- MWA 1.x style, no chain/features/SIWS
- `blockchain` set via enum (`Solana.Devnet`, `Solana.Mainnet`) -- old cluster approach
- Auth token cached in global `var authToken`, passed to `walletAdapter.authToken` before `transact()`

---

## Remaining Gaps

### 1. signAndSendTransactions -- DETAILED PLAN BELOW

The actual MWA 2.0 method where wallet signs AND broadcasts. Currently the app does sign-via-wallet + RPC-send separately.

**Previous attempt:** Timed out with Phantom. Cause unconfirmed -- could be Kotlin clientlib, Phantom, or our usage. Since Godot uses the same Kotlin clientlib as the reference implementation, this is the right place to retest and isolate the issue.

---

### 2. authorize MWA 2.0 Update -- DETAILED PLAN BELOW

Upgrade `connectWallet` from MWA 1.x (`connect()`) to MWA 2.0 (`authorize()` with chain/features/SIWS).

---

### 3. clone_authorization -- SKIP

Optional, no practical use case for games.

### 4. Error Code Mapping -- NICE TO HAVE

Map MWA error codes to specific GDScript signals instead of generic failure.

---

## Detailed Plan: signAndSendTransactions (Godot/Kotlin)

### What Changes

Currently `signTransaction` in MyComposable.kt does:
```kotlin
val result = walletAdapter.transact(sender) {
    signTransactions(arrayOf(myStoredTransaction ?: ByteArray(0)))
}
// returns signed bytes -> GDScript broadcasts via RPC
```

New `signAndSendTransaction` composable would do:
```kotlin
val result = walletAdapter.transact(sender) {
    signAndSendTransactions(arrayOf(myStoredTransaction ?: ByteArray(0)))
}
// returns signatures directly -> no RPC send needed
```

### Files to Modify

1. **MyComposable.kt** -- Add new `signAndSendTransaction` composable function
2. **MyComponentActivity.kt** -- Add `myAction = 3` route to new composable
3. **GDExtensionAndroidPlugin.kt** -- Add `signAndSendTransaction(serializedTransaction: ByteArray)` method with `@UsedByGodot`

### Implementation

**MyComposable.kt -- new composable:**
```kotlin
@Composable
fun signAndSendTransaction(sender: ActivityResultSender) {
    val activity = LocalContext.current as? Activity
    LaunchedEffect(Unit) {
        val connectionIdentity = ConnectionIdentity(
            identityUri = myIdentityUri,
            iconUri = myIconUri,
            identityName = myIdentityName
        )

        val walletAdapter = MobileWalletAdapter(connectionIdentity)
        when (myConnectCluster) {
            0 -> walletAdapter.blockchain = Solana.Devnet
            1 -> walletAdapter.blockchain = Solana.Mainnet
            2 -> walletAdapter.blockchain = Solana.Testnet
            else -> walletAdapter.blockchain = Solana.Devnet
        }

        if (authToken != null) {
            walletAdapter.authToken = authToken
        }

        val result = walletAdapter.transact(sender) {
            signAndSendTransactions(arrayOf(myStoredTransaction ?: ByteArray(0)))
        }

        when (result) {
            is TransactionResult.Success -> {
                authToken = result.authResult.authToken
                val signature = result.successPayload?.signatures?.first()
                signature?.let {
                    myMessageSignature = it
                    myMessageSigningStatus = 1
                }
            }
            is TransactionResult.NoWalletFound -> {
                myMessageSigningStatus = 2
            }
            is TransactionResult.Failure -> {
                myMessageSigningStatus = 2
                println("Error during signAndSend: " + result.e.message)
            }
        }

        myResult = result
        activity?.finish()
    }
}
```

**MyComponentActivity.kt -- add route:**
```kotlin
else if (myAction == 3) {
    hasConnectedWallet = true
    val sender = ActivityResultSender(this)
    setContent {
        signAndSendTransaction(sender)
    }
}
```

**GDExtensionAndroidPlugin.kt -- expose to GDScript:**
```kotlin
@UsedByGodot
fun signAndSendTransaction(serializedTransaction: ByteArray) {
    myAction = 3
    myStoredTransaction = serializedTransaction
    godot.getActivity()?.let {
        val intent = Intent(it, ComposeWalletActivity::class.java)
        it.startActivity(intent)
    }
}
```

### Key Difference from Unity Implementation

| | Unity SDK | Godot SDK |
|---|---|---|
| MWA layer | Pure C# reimplementation | Kotlin clientlib-ktx wrapper |
| signAndSend call | `client.signAndSendTransactions()` via JSON-RPC | `walletAdapter.transact { signAndSendTransactions() }` via clientlib |
| Session management | Manual LocalAssociationScenario | Handled by clientlib's `transact()` |
| Response type | Parse JSON-RPC response manually | `TransactionResult.Success` with `signatures` |

**This matters because:** The Godot timeout issue was in the Kotlin clientlib path. If signAndSend still times out here but works in Unity (pure C#), the bug is in the clientlib. If it times out in both, the bug is in Phantom/wallet-side.

### How to Test

1. Build the Godot example app with a new "Sign & Send" button that calls `signAndSendTransaction`
2. Deploy to Solana Seeker
3. Test with Phantom -- does it time out again?
4. If timeout: add logging inside the composable to isolate exactly where it hangs (before transact? inside transact? after signAndSend call?)
5. If success: compare signature on Solscan, verify the wallet actually broadcast
6. Test user denial -- verify `TransactionResult.Failure` fires
7. Compare behavior with existing `signTransaction` on the same transaction

### Debugging the Previous Timeout

If it times out again, add this logging:
```kotlin
Log.i("godot", "[signAndSend] START")
val result = walletAdapter.transact(sender) {
    Log.i("godot", "[signAndSend] inside transact, calling signAndSendTransactions")
    signAndSendTransactions(arrayOf(myStoredTransaction ?: ByteArray(0)))
}
Log.i("godot", "[signAndSend] transact returned: ${result.javaClass.simpleName}")
```

This tells you:
- If "inside transact" never prints: issue is session establishment
- If "inside transact" prints but never returns: wallet accepted the session but signAndSend hangs (wallet-side issue)
- If transact returns Failure: check `result.e.message` for the actual error

---

## Detailed Plan: authorize MWA 2.0 Update (Godot/Kotlin)

### What Changes

Currently `connectWallet` in MyComposable.kt uses MWA 1.x:
```kotlin
walletAdapter.blockchain = Solana.Devnet  // cluster-based
val result = walletAdapter.connect(sender)
```

MWA 2.0 should use:
```kotlin
walletAdapter.blockchain = Solana.Devnet  // or set chain directly
val result = walletAdapter.connect(sender, signInPayload)  // with SIWS
// or
val result = walletAdapter.transact(sender, signInPayload) { authResult ->
    // authorized with SIWS in one step
}
```

### Kotlin clientlib-ktx MWA 2.0 API

The Kotlin clientlib already supports MWA 2.0. Key changes:

**connect() with SIWS:**
```kotlin
walletAdapter.signIn(sender, SignInWithSolana.Payload(
    domain = "mygame.com",
    statement = "Sign in to My Game"
))
```

**transact() with SIWS:**
```kotlin
walletAdapter.transact(sender, signInPayload) { authResult ->
    // authResult.signInResult contains SIWS result
}
```

**Chain via blockchain property:**
```kotlin
walletAdapter.blockchain = Solana.Devnet  // maps to "solana:devnet" internally
```

The Kotlin clientlib handles the chain/cluster mapping internally through the `Solana` enum.

### Files to Modify

1. **MyComposable.kt** -- Update `connectWallet` to support SIWS, add `getCapabilitiesWallet` if not already there
2. **GDExtensionAndroidPlugin.kt** -- Add SIWS params to `connectWallet`, expose sign-in result to GDScript
3. **MyComponentActivity.kt** -- May need updates if new actions are added

### What to Expose to GDScript

New return values from authorization:
- `getSignInResult()` -- returns sign-in signature bytes
- `getSignInMessage()` -- returns the signed message bytes
- `getAccountLabel()` -- returns wallet account label if available
- `getAccountChains()` -- returns supported chains array
- `getAccountFeatures()` -- returns supported features array

### Seed Vault SIWS Caveat

Same as Unity: Seed Vault does NOT support SIWS one-shot. The Kotlin clientlib's `signIn()` may fail or render broken UI on Seed Vault. Workaround: detect wallet type and fall back to `connect()` + `signMessagesDetached()` two-step flow.

---

## Failed Fix Attempts — 2026-04-15 Session

### signAndSendTransactions — What Works, What Doesn't

**Working (confirmed with Jupiter):**
- The Kotlin `signAndSendTransactionAsync` with standalone CoroutineScope works. Jupiter signed + broadcast successfully, returned 64-byte signature `36e69c56...`.
- `tx.url_override` must be set to mainnet RPC URL. Without it, `Transaction.new()` defaults to devnet, and wallets reject the devnet blockhash (Phantom: silent CancellationException, Solflare: "Network mismatch", Backpack/Jupiter: simulation failed).
- The GDScript side should NOT re-submit via RPC. The old code did `str(plugin.call("getSignAndSendResult"))` → `sendTransaction(base64_tx)` which fails because `str(PackedByteArray)` produces `[54, 230, ...]` not valid base64. The wallet already broadcast — just hex_encode the 64-byte signature and return it.
- 0-lamport transfers crash Backpack. Use non-zero amount (e.g., 100 lamports).

**Not yet applied (reverted):**
- `clearState()` before `signAndSendTransaction()` to reset stale `mySignAndSendStatus`
- Removing RPC re-submission from `sign_and_send_transactions()` in mwa_manager.gd
- Setting `tx.url_override` in home.gd
- Changing lamport amount from 0 to 100

### SIWS (connectWalletSiws) — The Activity Lifecycle Problem

**The Kotlin SIWS composable works.** `connectWalletSiws` in MyComposable.kt correctly calls `walletAdapter.signIn(sender, payload)`. Phantom, Solflare, Backpack, and Jupiter all process the SIWS request. Phantom state logs confirm: both `authorize` and `signMessages` requests are received, processed, and user-approved.

**The problem is the MWA WebSocket dying.** The MWA clientlib starts a local WebSocket server (`LocalAssociationScenario`) when `signIn()` is called. This WebSocket is tied to the `ComposeWalletActivity` lifecycle. Android destroys the activity ~4 seconds after the wallet opens (takes focus). The `authorize` response arrives in ~2s (before destruction), but the `signMessages` response arrives in ~4-5s (after destruction). The WebSocket server is dead, so the response is lost.

**Standalone CoroutineScope makes it WORSE.** Replacing `@Composable` + `LaunchedEffect` with a standalone `CoroutineScope(Dispatchers.Main + SupervisorJob())` keeps the coroutine alive but the `ActivityResultSender` dies with the activity. Result: consistent `TimeoutException` (never works) instead of intermittent `CancellationException` (sometimes works when activity survives).

**Why signAndSendTransaction works with standalone scope but SIWS doesn't:** signAndSendTransaction uses cached auth token, completes in ~8s without user interaction. SIWS requires two user prompts (connect + authenticate) and takes 10-30s — the WebSocket is long dead by then.

**SIWS works intermittently with LaunchedEffect.** When the activity happens to survive long enough (second attempt, wallet already warm in memory), SIWS completes in ~8s and succeeds. First attempt typically fails because the wallet needs to cold-start.

**Approaches NOT yet tried:**
1. Prevent ComposeWalletActivity destruction (keep-alive flags, foreground service, non-transparent activity with loading UI)
2. Combine authorize + signMessages into a single MWA call that completes faster
3. Use the C++ WalletAdapter's `connect_wallet()` for authorization, then do SIWS `signMessages` in a separate step via plugin (avoids the two-prompt timing issue)
4. Accept the race condition and add GDScript auto-retry (first attempt warms wallet, second attempt succeeds)

---

## MWA 2.0 Implementation Reference (from official Solana Mobile docs)

This section is the source of truth for implementation. Do NOT guess at parameter names, types, or behavior. Everything below comes from the official docs and the React Native reference implementation TypeScript definitions.

---

### Session Lifecycle -- How MWA Works Under the Hood

Every MWA operation happens inside a session. The Kotlin clientlib uses `transact()`:

```kotlin
val result = walletAdapter.transact(sender) { authResult ->
    // 1. clientlib handles authorize/reauthorize internally
    // 2. do privileged operations (sign, signAndSend, etc.)
    // 3. session auto-closes when this lambda returns
}
```

**What happens under the hood:**
1. Clientlib creates a `LocalAssociationScenario` (WebSocket server on random localhost port)
2. Dispatches `solana-wallet://` URI intent to wallet app via `ActivityResultSender`
3. Wallet opens, connects to WebSocket, performs P-256 ECDH key exchange
4. Encrypted JSON-RPC 2.0 channel established (AES-128-GCM)
5. Clientlib sends authorize/reauthorize (using cached `authToken` if available)
6. Lambda executes privileged requests
7. Session closes when lambda returns

**In Godot SDK:** Each operation (connect, sign, signMessage) creates a new `MobileWalletAdapter` instance and calls `connect()` or `transact()`. This opens the wallet app each time.

**Critical:** The `authToken` is the ONLY thing that persists between sessions. Store it after connect, set `walletAdapter.authToken` before `transact()` calls.

---

### Kotlin clientlib-ktx Method Signatures

**MobileWalletAdapter constructor:**
```kotlin
MobileWalletAdapter(connectionIdentity: ConnectionIdentity)

ConnectionIdentity(
    identityUri: Uri,
    iconUri: Uri,
    identityName: String
)
```

**Properties:**
```kotlin
walletAdapter.blockchain = Solana.Devnet    // sets chain
walletAdapter.authToken = "cached_token"    // for silent reauth
```

**connect() -- basic authorization:**
```kotlin
val result: TransactionResult<AuthorizationResult> = walletAdapter.connect(sender)
```

**signIn() -- authorization with SIWS:**
```kotlin
val result = walletAdapter.signIn(sender, SignInWithSolana.Payload(
    domain = "mygame.com",
    statement = "Sign in"
))
// result.authResult.signInResult contains SIWS data
```

**transact() -- session with privileged operations:**
```kotlin
val result = walletAdapter.transact(sender) {
    signTransactions(arrayOf(txBytes))
    // or
    signAndSendTransactions(arrayOf(txBytes))
    // or
    signMessagesDetached(arrayOf(msgBytes), arrayOf(pubkeyBytes))
}
```

**disconnect() -- deauthorize:**
```kotlin
val result = walletAdapter.disconnect(sender)
```

**TransactionResult sealed class:**
```kotlin
sealed class TransactionResult<T> {
    class Success<T>(val authResult: AuthorizationResult, val successPayload: T?)
    class NoWalletFound<T>
    class Failure<T>(val e: Exception)
}
```

---

### authorize() -- Complete MWA 2.0 Spec

**JSON-RPC method name:** `"authorize"`

**Request params:**
```json
{
    "identity": {
        "uri": "https://mygame.com",
        "icon": "/icon.png",
        "name": "My Game"
    },
    "chain": "solana:devnet",
    "features": ["solana:signAndSendTransaction", "solana:signInWithSolana"],
    "addresses": ["base64_encoded_address_1"],
    "auth_token": "previously_cached_token_or_null",
    "sign_in_payload": {
        "domain": "mygame.com",
        "statement": "Sign in to My Game",
        "uri": "https://mygame.com",
        "version": "1",
        "chainId": "mainnet",
        "nonce": "server_generated_nonce",
        "issuedAt": "2026-04-13T00:00:00Z",
        "expirationTime": "2026-04-14T00:00:00Z"
    }
}
```

**Response:**
```json
{
    "accounts": [
        {
            "address": "base64_encoded_pubkey",
            "label": "My Wallet",
            "icon": "data:image/png;base64,...",
            "chains": ["solana:mainnet", "solana:devnet"],
            "features": ["solana:signAndSendTransaction"]
        }
    ],
    "auth_token": "new_or_refreshed_token",
    "wallet_uri_base": "https://phantom.app",
    "sign_in_result": {
        "address": "base64_encoded_pubkey",
        "signed_message": "base64_encoded_signed_message",
        "signature": "base64_encoded_signature",
        "signature_type": "ed25519"
    }
}
```

**Parameter details:**

| Param | Type | Required | Notes |
|-------|------|----------|-------|
| identity | object | Yes | `{ uri, icon, name }` -- shown to user during approval |
| chain | string | No (defaults mainnet) | `"solana:mainnet"`, `"solana:devnet"`, `"solana:testnet"`. Replaces deprecated `cluster` |
| features | string[] | No | Feature IDs the app wants |
| addresses | string[] | No | Base64-encoded preferred account addresses |
| auth_token | string | No | Cached token for silent reauthorization |
| sign_in_payload | object | No | SIWS payload. If sent, response includes `sign_in_result` |

**MWA 2.0 deprecations:**
- `reauthorize` RPC method replaced by `auth_token` param in `authorize`
- `cluster` param deprecated, use `chain`
- `signTransactions` deprecated in favor of `signAndSendTransactions`

---

### signAndSendTransactions() -- Complete MWA 2.0 Spec

**JSON-RPC method name:** `"sign_and_send_transactions"`

**This is a PRIVILEGED method -- requires prior authorization in the same session.**

**Request params:**
```json
{
    "payloads": ["base64_unsigned_tx_1", "base64_unsigned_tx_2"],
    "options": {
        "min_context_slot": 12345,
        "commitment": "confirmed",
        "skip_preflight": true,
        "max_retries": 3,
        "wait_for_commitment_to_send_next_transaction": false
    }
}
```

**Response:**
```json
{
    "signatures": ["base64_sig_1", "base64_sig_2"]
}
```

| Param | Type | Required | Notes |
|-------|------|----------|-------|
| payloads | string[] | Yes | Base64-encoded UNSIGNED serialized transactions |
| options.min_context_slot | number | No | Wallet waits for this slot before submitting |
| options.commitment | string | No | "processed", "confirmed", or "finalized" |
| options.skip_preflight | boolean | No | RECOMMENDED -- wallet approval delay causes BlockhashNotFound |
| options.max_retries | number | No | Wallet retry count |
| options.wait_for_commitment_to_send_next_transaction | boolean | No | Sequential batch send |

---

### getCapabilities() -- Complete Spec

**JSON-RPC method name:** `"get_capabilities"`

**Non-privileged -- no authorization required.**

**Response:**
```json
{
    "max_transactions_per_request": 10,
    "max_messages_per_request": 1,
    "supported_transaction_versions": ["legacy", "0"],
    "features": ["solana:signAndSendTransaction", "solana:cloneAuthorization"]
}
```

---

### deauthorize() -- Complete Spec

**JSON-RPC method name:** `"deauthorize"`

**Request:** `{ "auth_token": "token_to_revoke" }`
**Response:** `{}`

---

### MWA 2.0 Error Codes

```
Code   Constant                        When
-1     ERROR_AUTHORIZATION_FAILED      auth_token invalid, revoked, or expired
-2     ERROR_INVALID_PAYLOADS          malformed transaction or message bytes
-3     ERROR_NOT_SIGNED                user declined signing in wallet UI
-4     ERROR_NOT_SUBMITTED             wallet signed but failed to broadcast (signAndSend only)
-5     ERROR_TOO_MANY_PAYLOADS         batch exceeds max per request
-100   ERROR_ATTEST_ORIGIN_ANDROID     origin attestation failed
```

---

### Known Feature Identifiers

```
"solana:signTransactions"           -- wallet supports signTransactions
"solana:signAndSendTransaction"     -- wallet supports signAndSendTransactions
"solana:cloneAuthorization"         -- wallet supports cloneAuthorization
"solana:signInWithSolana"           -- wallet supports SIWS
```

---

### Critical Implementation Gotchas -- DO NOT IGNORE

1. **`chain` defaults to mainnet if not specified.** Always set `walletAdapter.blockchain` explicitly.

2. **Signatures are Base64-encoded strings, NOT raw bytes.** `signAndSendTransactions` returns base64 sigs. `signTransactions` returns base64 signed TX bytes. Different things.

3. **`auth_token` persistence is YOUR responsibility.** Store after connect, set on `walletAdapter.authToken` before `transact()`. Currently stored in global var -- works but lost on app restart.

4. **`skip_preflight=true` recommended for signAndSend.** Wallet approval delay causes BlockhashNotFound.

5. **Seed Vault does NOT support SIWS one-shot.** `signIn()` may fail. Fallback: `connect()` + `signMessagesDetached()` two-step.

6. **`signTransactions` is deprecated in MWA 2.0.** Keep both methods, let developer choose.

7. **Accounts are arrays in MWA 2.0.** `accounts[0]` for primary, don't assume length 1.

8. **Godot SDK uses Kotlin clientlib-ktx.** Same library as React Native reference. If signAndSend times out here, it's likely a clientlib or wallet-side bug, NOT our code.

9. **Each operation creates a new MobileWalletAdapter instance.** This is intentional in Godot -- the transparent ComposeWalletActivity launches, does the MWA operation, then finishes. State flows through global vars.

10. **`setIdentity()` must be called before any signing operations after cache reconnect.** Otherwise Kotlin identity vars are null and the session crashes. This was a bug we already fixed.

---

## Device Test Results (2026-04-14, Solana Seeker + Phantom)

### PROVEN WORKING — Log-verified on device

| Feature | Status | Log Proof |
|---------|--------|-----------|
| **SIWS Authorize (MWA 2.0)** | WORKING | `signIn()` → `result_class=Success`, `sig_size=64`, `authToken_len=118`, `label=phantom-wallet` |
| **Sign Message (after SIWS)** | WORKING | `sign_message SUCCESS sig_len=128` — Kotlin authToken persists after SIWS, C++ WalletAdapter picks it up |
| **Sign Transaction (after SIWS)** | WORKING | `sign_transaction SUCCESS` — transact() reauthorizes with SIWS-cached authToken |
| **Disconnect** | WORKING | State cleared, returned to Main scene |
| **Reconnect (cache)** | WORKING | `CACHE_RECONNECT SUCCESS` from AuthCache |
| **Delete Account** | WORKING | Confirmation via sign_message, cache cleared, adapter recreated |
| **Seed Vault (legacy path)** | WORKING | `SIWS_CHECK use_siws=false wallet_type_id=-1` → correct fallback to connect_wallet() |

### FIXED — Activity lifecycle issue

| Feature | Status | Root Cause | Fix |
|---------|--------|------------|-----|
| **signAndSendTransactions** | FIX DEPLOYED | ComposeWalletActivity destroyed by Android after ~19s. LaunchedEffect coroutine cancelled, MWA session lost. | Moved from `@Composable` with `LaunchedEffect` to `suspend fun` in standalone `CoroutineScope(Dispatchers.Main + SupervisorJob())`. Coroutine survives activity destruction. |

### KNOWN STUBS — Not implemented on this branch

| Feature | Status | Reason |
|---------|--------|--------|
| **getCapabilities** | STUB (returns error) | Was on `feature/get-capabilities` branch, removed for this branch. GDScript fallback returns hardcoded defaults. Needs myAction==5 composable for real implementation. |

### Key SIWS Data from Phantom (first successful signIn)

```
pubkey_hex = b587a3efd5b92af66761a247a454d5ff8b821c978135498bfaac040d2f061374
base58     = DDckkaRQB5wtQfH9tG3hda9yyDL1nAHbhM6wGR1797is
sig_size   = 64 bytes (ed25519)
sig_hex    = 10e8df5c3736360631f46eece3403749324b889bcd6704e6d4745d5ef4898b80...
signedMsg  = "https://example.com wants you to sign in..." (139 bytes)
label      = phantom-wallet
chains     = null (Phantom doesn't report)
features   = null (Phantom doesn't report)
authToken  = 118 chars
```

---

## Build & Deploy Instructions (Kotlin SDK → Godot App)

After modifying any Kotlin files in the SDK (`MyComposable.kt`, `GDExtensionAndroidPlugin.kt`, `MyComponentActivity.kt`), you **must rebuild the AAR and copy it to the Godot project** before exporting the APK. The Godot project bundles the AAR at export time — it does NOT read from the SDK repo at runtime.

### Step 1: Build the AAR (requires JDK 17)

```bash
cd ~/Desktop/godot-solana-sdk/android && JAVA_HOME=$(/usr/libexec/java_home -v 17) ./gradlew assemble
```

- Uses JDK 17 (the project targets `compileSdk 33` which is incompatible with JDK 21)
- If JDK 17 is not installed: `brew install openjdk@17`
- Output AARs land in: `~/Desktop/godot-solana-sdk/android/plugin/build/outputs/aar/`
- Warnings about "deprecated publicKey" and "unnecessary safe call" are expected and harmless

### Step 2: Copy AARs to the Godot project

```bash
cp /Users/devlegacy/Desktop/godot-solana-sdk/android/plugin/build/outputs/aar/WalletAdapterAndroid-release.aar /Users/devlegacy/Desktop/grant-godot/addons/SolanaSDK/WalletAdapterAndroid/bin/release/WalletAdapterAndroid-release.aar
```

```bash
cp /Users/devlegacy/Desktop/godot-solana-sdk/android/plugin/build/outputs/aar/WalletAdapterAndroid-debug.aar /Users/devlegacy/Desktop/grant-godot/addons/SolanaSDK/WalletAdapterAndroid/bin/debug/WalletAdapterAndroid-debug.aar
```

### Step 3: Re-export APK from Godot editor

Open the Godot project, export Android APK. The new AAR is bundled automatically.

### Step 4: Install on Seeker

```bash
export PATH="$PATH:/Users/devlegacy/Library/Android/sdk/platform-tools" && adb -s SM02G4061960675 uninstall com.example.mwaexample ; adb -s SM02G4061960675 install /Users/devlegacy/Desktop/grant-godot/mwa-example.apk
```

### Why this is necessary

The Godot Android export embeds the AAR into the APK. If you modify Kotlin source but skip the rebuild+copy, the APK still contains the **old** AAR. Symptoms: `Nonexistent function 'connectWalletSiws (via call)' in base 'JNISingleton'` — the GDScript calls a Kotlin method that doesn't exist in the bundled AAR.

### Quick one-liner (build + copy)

```bash
cd ~/Desktop/godot-solana-sdk/android && JAVA_HOME=$(/usr/libexec/java_home -v 17) ./gradlew assemble && cp plugin/build/outputs/aar/WalletAdapterAndroid-release.aar /Users/devlegacy/Desktop/grant-godot/addons/SolanaSDK/WalletAdapterAndroid/bin/release/WalletAdapterAndroid-release.aar && cp plugin/build/outputs/aar/WalletAdapterAndroid-debug.aar /Users/devlegacy/Desktop/grant-godot/addons/SolanaSDK/WalletAdapterAndroid/bin/debug/WalletAdapterAndroid-debug.aar && echo "BUILD + COPY DONE"
```
