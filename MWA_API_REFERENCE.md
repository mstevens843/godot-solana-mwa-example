# MWA 2.0 API Reference — Complete Method Guide for Godot Implementation

> Source: [MWA 2.0 Spec](https://solana-mobile.github.io/mobile-wallet-adapter/spec/spec.html), [React Native Reference](https://docs.solanamobile.com/get-started/react-native/mobile-wallet-adapter), [Kotlin Quickstart](https://docs.solanamobile.com/get-started/kotlin/quickstart)

---

## How MWA Sessions Work

Every MWA interaction happens inside a **session**. In React Native and Kotlin, this is the `transact()` wrapper. The session:

1. Opens a WebSocket connection to the wallet app
2. Performs key exchange (ECDH + AES-128-GCM encryption)
3. Enters **unauthorized state** — only `authorize`, `deauthorize`, `get_capabilities` are available
4. After `authorize()` succeeds → enters **authorized state** — `sign_messages`, `sign_and_send_transactions` become available
5. Session ends when the WebSocket closes

**In the Godot SDK**, `WalletAdapter.connect_wallet()` handles steps 1-4 internally. There is no explicit `transact()` wrapper — the adapter maintains the session.

---

## Method Categories

| Category | Methods | Requires Auth? |
|----------|---------|---------------|
| **Non-privileged** | `authorize`, `deauthorize`, `get_capabilities` | No |
| **Privileged (MANDATORY)** | `sign_messages`, `sign_and_send_transactions` | Yes |
| **Privileged (OPTIONAL)** | `clone_authorization`, `sign_transactions` (deprecated) | Yes |

**ALL MWA-compliant wallets MUST support sign_messages and sign_and_send_transactions.**
This includes Phantom, Solflare, Backpack, Seed Vault, Jupiter — every single one.

---

## 1. authorize

**Purpose:** Request authorization from the wallet. Returns an auth_token for privileged methods.

**Type:** Non-privileged (no prior auth needed)

### Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `identity` | Object | Optional | `{ name, uri, icon }` — app identity shown to user |
| `chain` | String | Optional | `"solana:mainnet"`, `"solana:testnet"`, `"solana:devnet"`. Defaults to `"solana:mainnet"` |
| `auth_token` | String | Optional | Previously stored token for **silent reauthorization** (skips user prompt) |
| `sign_in_payload` | Object | Optional | SIWS payload: `{ domain, statement, uri }` — combines auth + message signing |
| `features` | String[] | Optional | Feature IDs the dApp intends to use |
| `addresses` | String[] | Optional | Base64 account addresses to include in scope |

### Returns: AuthorizationResult

```
{
  auth_token: string           // SAVE THIS — use for reauthorize and deauthorize
  accounts: [{
    address: string            // base64 pubkey
    display_address: string
    label: string
    chains: string[]
    features: string[]
  }]
  wallet_uri_base: string      // optional — for future connections
  sign_in_result: {            // only if sign_in_payload was provided
    address: string
    signed_message: string     // base64
    signature: string          // base64
  }
}
```

### React Native
```typescript
const authResult = await transact(async (wallet: Web3MobileWallet) => {
  return await wallet.authorize({
    chain: 'solana:devnet',
    identity: {
      name: 'My App',
      uri: 'https://myapp.com',
      icon: 'favicon.ico',
    },
  });
});
// SAVE: authResult.auth_token, authResult.accounts[0].address
```

### Kotlin
```kotlin
val result = walletAdapter.connect(sender)
// result.authResult.accounts.first().publicKey
// result.authResult.authToken  <-- SAVE THIS
```

### Godot SDK (current)
```gdscript
wallet_adapter.set_mobile_identity_name("My App")
wallet_adapter.set_mobile_identity_uri("https://myapp.com")
wallet_adapter.set_mobile_icon_path("/icon.png")
wallet_adapter.set_mobile_blockchain(0)  # 0=devnet, 1=mainnet, 2=testnet
wallet_adapter.connect_wallet()
# Wait for connection_established signal
# Get key: wallet_adapter.get_connected_key()
# NOTE: auth_token is NOT exposed by the Godot SDK
```

---

## 2. Reauthorize (silent reconnect)

**Purpose:** Skip the user approval dialog on subsequent sessions by passing a cached `auth_token`.

**This is NOT a separate method** — it's `authorize()` with the `auth_token` parameter filled in.

### React Native
```typescript
const storedAuthToken = getFromStorage();
const authResult = await transact(async (wallet) => {
  return await wallet.authorize({
    chain: 'solana:devnet',
    identity: APP_IDENTITY,
    auth_token: storedAuthToken,  // <-- silent reauth
  });
});
```

### Kotlin
```kotlin
// Kotlin SDK handles this internally via the MobileWalletAdapter config
```

### Godot SDK (current)
```gdscript
# NOT SUPPORTED — SDK does not expose auth_token
# Workaround: call connect_wallet() again (full re-authorization)
wallet_adapter.connect_wallet()
```

---

## 3. deauthorize (disconnect / revoke)

**Purpose:** Invalidate an auth_token. The wallet forgets the dApp's authorization.

**Type:** Non-privileged

### Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `auth_token` | String | **Required** | The token to invalidate |

### Returns
Empty object `{}`

### React Native
```typescript
await transact(async (wallet) => {
  await wallet.deauthorize({ auth_token: previouslyStoredAuthToken });
});
```

### Kotlin
```kotlin
val result = walletAdapter.disconnect(sender)
// Internally invalidates the stored authToken
```

### Godot SDK (current)
```gdscript
# NOT EXPOSED — wallet_adapter.has_method("deauthorize") returns false
# Workaround: destroy and recreate WalletAdapter to kill the MWA session
var old = wallet_adapter
wallet_adapter = null
remove_child(old)
old.queue_free()
# Recreate fresh adapter
_setup_wallet_adapter()
```

---

## 4. sign_messages (MANDATORY — ALL wallets support this)

**Purpose:** Sign arbitrary byte payloads. Used for off-chain message signing, SIWS, identity verification.

**Type:** Privileged (requires prior `authorize`)

### Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `addresses` | String[] | **Required** | Base64 pubkeys of accounts that should sign |
| `payloads` | Uint8Array[] | **Required** | Byte arrays — each is a message to sign |

### Returns
`Uint8Array[]` — signed message payloads (signature appended to message)

### React Native
```typescript
const signedMessages = await transact(async (wallet) => {
  const auth = await wallet.authorize({
    chain: 'solana:devnet',
    identity: APP_IDENTITY,
  });

  const message = 'Hello world!';
  const messageBuffer = new Uint8Array(
    message.split('').map(c => c.charCodeAt(0)),
  );

  return await wallet.signMessages({
    addresses: [auth.accounts[0].address],
    payloads: [messageBuffer],
  });
});
```

### Kotlin
```kotlin
val result = walletAdapter.transact(sender) { authResult ->
  signMessagesDetached(
    arrayOf("Sign this message".toByteArray()),
    arrayOf(authResult.accounts.first().publicKey)
  )
}
val signature = result.successPayload?.messages?.first()?.signatures?.first()
```

### Godot SDK (current)
```gdscript
# sign_text_message() is the Godot SDK's wrapper for MWA sign_messages
wallet_adapter.sign_text_message("Hello world!")
# Wait for message_signed signal — signature comes as PackedByteArray argument
# OR use sign_message(bytes: PackedByteArray, signer_index: int) for raw bytes
```

**IMPORTANT:** The wallet MUST reject payloads that look like transactions. sign_messages is for arbitrary messages only.

---

## 5. sign_and_send_transactions (MANDATORY)

**Purpose:** Sign transactions AND submit them to the Solana network. The wallet handles RPC submission.

**Type:** Privileged (requires prior `authorize`)

### Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `transactions` | Transaction[] | **Required** | Unsigned transactions to sign and send |
| `options.min_context_slot` | number | Optional | Minimum slot for preflight checks |
| `options.commitment` | string | Optional | `"finalized"`, `"confirmed"`, `"processed"` |
| `options.skip_preflight` | boolean | Optional | Skip simulation before sending |
| `options.max_retries` | number | Optional | Max send retries |

### Returns
`string[]` — transaction signatures (base64)

### React Native
```typescript
const signatures = await transact(async (wallet) => {
  const auth = await wallet.authorize({
    chain: 'solana:devnet',
    identity: APP_IDENTITY,
  });

  const pubkey = new PublicKey(toByteArray(auth.accounts[0].address));
  const tx = new Transaction({
    ...latestBlockhash,
    feePayer: pubkey,
  }).add(
    SystemProgram.transfer({
      fromPubkey: pubkey,
      toPubkey: Keypair.generate().publicKey,
      lamports: 1_000_000,
    }),
  );

  return await wallet.signAndSendTransactions({
    transactions: [tx],
  });
});
```

### Kotlin
```kotlin
val result = walletAdapter.transact(sender) { authResult ->
  val userAddress = SolanaPublicKey(authResult.accounts.first().publicKey)
  val blockhash = rpcClient.getLatestBlockhash().result!!.blockhash
  val tx = Transaction(
    Message.Builder()
      .addInstruction(SystemProgram.transfer(userAddress, recipient, 1_000_000L))
      .setRecentBlockhash(blockhash)
      .build()
  )
  signAndSendTransactions(arrayOf(tx.serialize()))
}
val txSig = result.successPayload?.signatures?.first()
```

### Godot SDK (implemented in example app)
```gdscript
# Build a transaction using the SDK's C++ classes
var payer := Pubkey.new_from_string(connected_pubkey)
var ix := SystemProgram.transfer(payer, payer, 0)
var tx := Transaction.new()
tx.set_payer(payer)
tx.add_instruction(ix)
tx.update_latest_blockhash()
var bh_result: Dictionary = await tx.blockhash_updated

# Sign via MWA and collect signatures
var tx_bytes := tx.serialize()
var sigs := await MWAManager.sign_and_send_transactions([tx_bytes])
# sigs is an Array of signature hex strings

# Internally, sign_and_send_transactions calls wallet_adapter.sign_message(tx_bytes, 0)
# for each transaction and collects the signed results
```

---

## 6. sign_transactions (DEPRECATED in MWA 2.0)

**Purpose:** Sign transactions WITHOUT submitting. Replaced by `sign_and_send_transactions`.

**Type:** Privileged, Optional (for backward compatibility only)

### Godot SDK (implemented in example app)
```gdscript
# Build a transaction using SDK C++ classes, serialize, sign via MWA
var payer := Pubkey.new_from_string(connected_pubkey)
var ix := SystemProgram.transfer(payer, payer, 0)
var tx := Transaction.new()
tx.set_payer(payer)
tx.add_instruction(ix)
tx.update_latest_blockhash()
await tx.blockhash_updated

var tx_bytes := tx.serialize()
var sig := await MWAManager.sign_transaction(tx_bytes)
# sig is a hex-encoded Ed25519 signature string (128 chars)

# Internally calls wallet_adapter.sign_message(tx_bytes, 0)
# Waits for message_signed signal, returns signature
```

---

## 7. get_capabilities

**Purpose:** Query wallet's capabilities and limits.

**Type:** Non-privileged

### Returns
```
{
  max_transactions_per_request: number    // optional
  max_messages_per_request: number        // optional  
  supported_transaction_versions: string[] // ["legacy", 0]
  features: string[]                      // optional features only
}
```

**Mandatory features** (`solana:signMessages`, `solana:signAndSendTransaction`) are NOT listed — they're always present.

### Godot SDK (implemented via SDK plugin fix)
```gdscript
# Calls the real MWA getCapabilities via the Kotlin plugin
var caps := await MWAManager.get_capabilities()
# Returns Dictionary with keys:
#   maxTransactions — max transactions per signing request
#   maxMessages — max messages per signing request
#   supportsCloneAuth — whether wallet supports clone authorization
#   supportsSignAndSend — whether wallet supports sign and send
#   supportedVersions — transaction versions (e.g. "legacy;0")
#   optionalFeatures — optional MWA features supported

# Implementation: added getCapabilitiesWallet() to GDExtensionAndroidPlugin.kt
# which calls walletAdapter.transact { getCapabilities() } via MWA client
# Results stored as comma-separated key=value string, parsed in GDScript
```

---

## 8. Sign In With Solana (SIWS)

**Purpose:** Combine `authorize` + message signing in ONE step. User authorizes AND proves wallet ownership simultaneously.

**This is an optional parameter on `authorize()`**, not a separate method.

### Parameters (added to authorize)

| Param | Type | Description |
|-------|------|-------------|
| `sign_in_payload.domain` | String | Your app's domain |
| `sign_in_payload.statement` | String | Human-readable sign-in message |
| `sign_in_payload.uri` | String | Your app's URI |

### Returns (added to AuthorizationResult)
```
sign_in_result: {
  address: string         // which account signed in
  signed_message: string  // base64 signed message
  signature: string       // base64 signature
  signature_type: string  // "ed25519"
}
```

### React Native
```typescript
const result = await transact(async (wallet) => {
  return await wallet.authorize({
    chain: 'solana:devnet',
    identity: APP_IDENTITY,
    sign_in_payload: {
      domain: 'yourdomain.com',
      statement: 'Sign into My App',
      uri: 'https://yourdomain.com',
    },
  });
});
const signInResult = result.sign_in_result;
```

### Kotlin
```kotlin
val result = walletAdapter.signIn(
  sender,
  SignInWithSolana.Payload("yourdomain.com", "Sign in to My App")
)
val signInResult = result.authResult.signInResult
```

### Godot SDK
```gdscript
# NOT EXPOSED — SDK does not support sign_in_payload parameter
# Workaround: connect_wallet() then sign_text_message() separately
wallet_adapter.connect_wallet()
# After connection_established:
wallet_adapter.sign_text_message("Sign in to My App")
```

---

## Godot SDK Method Mapping

| MWA 2.0 Spec | React Native | Kotlin | Godot SDK | Status |
|---------------|-------------|--------|-----------|--------|
| `authorize` | `wallet.authorize()` | `walletAdapter.connect()` | `wallet_adapter.connect_wallet()` | Working — clearState() fix enables proper disconnect/reconnect |
| `deauthorize` | `wallet.deauthorize()` | `walletAdapter.disconnect()` | `clearState()` + local state clear | Working — via SDK plugin fix (PR #449) |
| `sign_messages` | `wallet.signMessages()` | `signMessagesDetached()` | `wallet_adapter.sign_text_message()` | Working — Seed Vault biometric, Phantom in-app approval |
| `sign_and_send_transactions` | `wallet.signAndSendTransactions()` | `signAndSendTransactions()` | Kotlin `signTransactions()` + GDScript RPC `sendTransaction` | Working — signs via MWA, submits via app-side RPC (same as Unity SDK) |
| `sign_transactions` | `wallet.signTransactions()` | N/A (deprecated) | `wallet_adapter.sign_message(bytes, 0)` | Working — builds real tx, signs via MWA |
| `get_capabilities` | `wallet.getCapabilities()` | `getCapabilities()` | `getCapabilitiesWallet()` via plugin | Working — added to SDK Kotlin plugin |
| `reauthorize` | `authorize({auth_token})` | Internal | AuthCache-based reconnect | Working — reads cached pubkey directly |
| SIWS | `authorize({sign_in_payload})` | `walletAdapter.signIn()` | **NOT EXPOSED** | Missing — SDK does not support sign_in_payload |

---

## Godot SDK Available Methods (from C++ source)

| Method | Signature | Purpose |
|--------|-----------|---------|
| `connect_wallet()` | `() -> void` | Opens wallet picker, authorizes MWA session |
| `sign_text_message()` | `(message: String) -> void` | Signs plain text via MWA sign_messages |
| `sign_message()` | `(serialized_message: PackedByteArray, index: int) -> void` | Signs serialized transaction bytes |
| `get_connected_key()` | `() -> Pubkey` | Returns connected wallet's public key object |
| `get_available_wallets()` | `() -> Array` | Lists installed MWA-compatible wallets |
| `is_idle()` | `() -> bool` | Whether adapter is in IDLE state |
| `is_connected()` | `() -> bool` | Inherited from Node — NOT MWA connection state |
| `clear_state()` | `() -> void` | Resets to IDLE (exists in C++ but NOT bound to GDScript) |

### Signals

| Signal | Argument | When |
|--------|----------|------|
| `connection_established` | None | Wallet authorized successfully |
| `connection_failed` | None | Wallet rejected authorization |
| `message_signed` | `PackedByteArray` (signature) | Message or transaction signed |
| `signing_failed` | None/Variant | User rejected signing |

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `wallet_type` | int | Wallet provider ID: 20=Phantom, 25=Solflare, 36=Backpack |

---

## SDK Gaps — Fixed

These methods were missing from the Godot SDK. We fixed them via Kotlin plugin modifications and GDScript workarounds:

| Gap | Status | How |
|-----|--------|-----|
| `clearState()` not resetting connection | **Fixed** | Added `myResult = null` to `clearState()` in Kotlin plugin ([PR #449](https://github.com/Virus-Axel/godot-solana-sdk/pull/449)) |
| `get_capabilities()` not exposed | **Fixed** | Added `getCapabilitiesWallet()` to Kotlin plugin, calls MWA `getCapabilities()` via `transact{}` |
| `sign_and_send_transactions()` not exposed | **Working** | Signs via Kotlin `signTransactions()` composable, submits to Solana RPC via GDScript HTTPRequest. Kotlin MWA clientlib's `signAndSendTransactions()` is broken with Phantom (times out), so we use the Unity SDK approach: sign via wallet, send via app-side RPC. |
| `sign_transactions()` not working | **Working** | Builds real Transaction, fetches blockhash, serializes, signs via MWA `wallet_adapter.sign_message(bytes, 0)` |
| `deauthorize` not exposed | **Working** | `clearState()` + destroy/recreate WalletAdapter + clear local GDScript state |
| `reauthorize` (silent reconnect) | **Working** | AuthCache reads cached pubkey directly, no SDK call needed |

## SDK Gaps — Remaining (require deeper SDK changes)

1. **`get_auth_token()`** — auth_token stored in Kotlin static var but not exposed through C++ to GDScript
2. **`authorize({sign_in_payload})`** — SIWS support requires changes to `connectWallet()` in both Kotlin and C++
3. **`authorize({auth_token})`** — silent reauthorization requires passing auth_token through C++ layer
4. **`wallet_uri_base`** — available in Kotlin `AuthorizationResult` but not read or stored
5. **`transact()` session model** — SDK opens separate MWA sessions per method call instead of one session for all operations
