# MWA Integration Report — Godot SDK on Solana Seeker

**Date:** April 5, 2026
**Device:** Solana Seeker (hardware)
**Wallet:** Seed Vault (cofeelme.skr)
**SDK:** godot-solana-sdk v1.4.5
**Godot:** 4.6.2 stable
**Pubkey confirmed:** `7etjMSp87AUE135iW5dNeKridbW16rwSFVUN9ivfFm3w`

---

## Summary

We built a minimal Godot 4.x MWA example app and tested it on a real Solana Seeker phone with Seed Vault. The process uncovered **10 integration issues** in how the godot-solana-sdk's `WalletAdapter` communicates with GDScript. All 10 were diagnosed via deterministic logging (220+ log statements) and fixed. The app now successfully completes the full MWA parity flow: authorize with biometric sign-in, sign message, disconnect, delete account with biometric confirmation, and reconnect.

---

## Problem 1: `is_connected()` Overrides Godot Built-in

**Symptom:** `SCRIPT ERROR: The function signature doesn't match the parent. Parent signature is "is_connected(StringName, Callable) -> bool".`

**Root Cause:** Godot's `Object` base class has a built-in method `is_connected(signal_name, callable) -> bool` for checking signal connections. Our `func is_connected() -> bool` (no arguments, returns connection state) shadowed it with a different signature. Godot 4.6 treats this as a compile error, not a warning.

**Fix:** Renamed to `func get_is_connected() -> bool`. Updated all callers.

**File:** `scripts/mwa_manager.gd` (line 328 → 387)

---

## Problem 2: Variant Type Inference Warning

**Symptom:** `SCRIPT ERROR: The variable type is being inferred from a Variant value, so it will be typed as Variant. (Warning treated as error.)`

**Root Cause:** GDScript's `:=` operator infers the type from the right-hand side. When calling `cache.get_latest_auth()` which returns `Variant` (nullable Dictionary), `:=` infers the variable as `Variant` type. Godot 4.6 treats this as an error because it defeats type safety.

**Fix:** Changed `var cached := cache.get_latest_auth()` to `var cached = cache.get_latest_auth()` (untyped assignment, explicit Variant).

**File:** `scripts/mwa_manager.gd` (line 151)

---

## Problem 3: `connection_established` Signal Never Fires

**Symptom:** After calling `wallet_adapter.connect_wallet()`, the Seed Vault picker appears, user approves, but `connection_established` signal never fires. The authorize function times out after 30s.

**Diagnostic log:**
```
[MWAManager] authorize | calling wallet_adapter.connect_wallet()
[MWAManager] authorize | waiting for connection (timeout=30s)
... 30 seconds of silence ...
[MWAManager] authorize | TIMEOUT elapsed=30.0s
```

**Root Cause:** The WalletAdapter's C++ `_process()` polls the Kotlin Android plugin for state changes and emits signals. When the WalletAdapter is created via `ClassDB.instantiate("WalletAdapter")` (programmatic creation), the signal emission path appears to not fire reliably. The SDK's own `WalletService` uses a scene-based WalletAdapter (`@onready var wallet_adapter:WalletAdapter = $WalletAdapter`) which may have different initialization behavior.

**Fix:** Added a **polling fallback** alongside signal-based detection. Every 0.5s during the wait loop, we poll `wallet_adapter.get_connected_key()` directly. If it returns a valid base58 pubkey that differs from the pre-connect snapshot, we treat it as a successful connection.

Additionally added a `_process()` diagnostic logger that prints WalletAdapter state every 1s while waiting, which confirmed the pubkey appears ~4s after `connect_wallet()` even though the signal doesn't fire.

**Diagnostic log (after fix):**
```
[MWAManager] _process DIAG | key='' raw='[Pubkey:]' ...
[MWAManager] _process DIAG | key='' raw='[Pubkey:]' ...
[MWAManager] _process DIAG | key='' raw='[Pubkey:]' ...
[MWAManager] _process DIAG | key='7etjMSp87AUE135iW5dNeKridbW16rwSFVUN9ivfFm3w' ...
[MWAManager] authorize | POLL FALLBACK detected NEW key=7etjMSp87AUE135iW5dNeKridbW16rwSFVUN9ivfFm3w
[MWAManager] authorize | SUCCESS pubkey=7etjMSp87AUE135iW5dNeKridbW16rwSFVUN9ivfFm3w elapsed=4.0s
```

**File:** `scripts/mwa_manager.gd` — `authorize()` function + `_process()` diagnostic

---

## Problem 4: Pubkey Object vs String Type Mismatch

**Symptom:** After poll fallback detected a key, `authorize()` still returned `false`. No SUCCESS log appeared. The function silently crashed.

**Diagnostic log:**
```
[MWAManager] authorize | POLL FALLBACK detected key=[Pubkey:7etjMSp87AUE135iW5dNeKridbW16rwSFVUN9ivfFm3w]
[Main] _on_connect_pressed | DONE success=false
```

**Root Cause:** `connected_pubkey` is declared as `var connected_pubkey: String = ""`. The SDK's `wallet_adapter.get_connected_key()` returns a `Pubkey` object (GDExtension type), not a String. The assignment `connected_pubkey = wallet_adapter.get_connected_key()` causes a silent type mismatch crash in GDScript — the function returns the default `false` without executing any further code.

**Fix:** Created `_extract_pubkey_string(key_obj) -> String` helper that:
1. Converts `str(key_obj)` → gets `"[Pubkey:BASE58HERE]"`
2. Parses out the base58 key from between `[Pubkey:` and `]`
3. Returns clean base58 string or empty string

All calls to `get_connected_key()` now go through this helper.

**File:** `scripts/mwa_manager.gd` — `_extract_pubkey_string()` helper (line 393)

---

## Problem 5: Empty Pubkey `[Pubkey:]` Triggers False Positive

**Symptom:** Poll fallback triggered instantly at 0.2s before the wallet even appeared.

**Diagnostic log:**
```
[MWAManager] authorize | POLL FALLBACK detected key=[Pubkey:] elapsed=0.2s
```

**Root Cause:** `wallet_adapter.get_connected_key()` returns a `Pubkey` object even when not connected — not null, not empty string, but an empty Pubkey object. `str()` gives `"[Pubkey:]"` which passes `!= null` and `!= ""` checks. The polling fallback triggered immediately on this empty object.

**Fix:** Two-part fix:
1. `_extract_pubkey_string()` returns `""` for `"[Pubkey:]"` (inner part is empty after parsing)
2. Poll fallback requires `poll_key_str.length() > 20` (base58 pubkeys are 32-44 chars) AND `poll_key_str != _pre_connect_key` (must be different from pre-connect snapshot)

**File:** `scripts/mwa_manager.gd` — `authorize()` polling logic

---

## Problem 6: Stale Key After Disconnect/Delete

**Symptom:** After delete account + reconnect, the poll fallback immediately accepts the stale key from the previous session instead of waiting for a fresh Seed Vault approval.

**Diagnostic log:**
```
[MWAManager] authorize | pre_connect_key='7etjMSp87AUE135iW5dNeKridbW16rwSFVUN9ivfFm3w'
... key matches pre_connect_key for 5s ...
[MWAManager] authorize | POLL FALLBACK same key=... elapsed=5.5s (accepting reconnect)
```

**Root Cause:** The Kotlin plugin's `ComposeWalletActivity` caches the connected pubkey internally. Our `deauthorize()` clears local GDScript state but doesn't clear the native plugin state. The SDK doesn't expose a `clearState()` method to GDScript.

**Fix:** In `delete_account()`, after clearing local state and cache, destroy the WalletAdapter node (`queue_free()`) and recreate it via `_setup_wallet_adapter()`. This forces a fresh native plugin instance with no stale state.

```gdscript
wallet_adapter.queue_free()
wallet_adapter = null
await get_tree().process_frame
_setup_wallet_adapter()
```

For `disconnect()` (not delete), we keep the stale key behavior — the 5s reconnect fallback is intentional, allowing quick reconnection without re-prompting Seed Vault.

**File:** `scripts/mwa_manager.gd` — `delete_account()` function

---

## Problem 7: Signature Passed as Signal Argument, Not via `get_message_signature()`

**Symptom:** `sign_text_message()` triggers the Seed Vault signing flow, user approves, but the signature is reported as empty and sign_message returns failure.

**Diagnostic log:**
```
[MWAManager] _on_message_signed | SIGNAL RECEIVED sig=empty sig_from_arg=[176, 72, 92, 140, 11, 46, 213, ...]
```

**Root Cause:** The `message_signed` signal passes the 64-byte Ed25519 signature as its **argument** (a `PackedByteArray`). Our handler tried to get the signature from `wallet_adapter.get_message_signature()` which returned empty. The signal argument was ignored.

This is a documentation gap in the SDK — the signal signature is not documented, and the `get_message_signature()` method appears to be a different code path that isn't populated when signing via the Compose Activity.

**Fix:** Rewrote `_on_message_signed(sig: Variant)` to:
1. Check if `sig` is `PackedByteArray` → call `sig.hex_encode()` for a clean hex string
2. Check if `sig` is `Array` of ints → manually convert each byte to hex
3. Fall back to `get_message_signature()` only if the signal argument was empty

**Result:**
```
[MWAManager] _on_message_signed | SIGNAL RECEIVED sig_from_bytes=b0485c8c0b2ed594a72f67554da7d491... len=64
[MWAManager] _on_message_signed | FINAL sig_len=128 sig_empty=false
[MWAManager] sign_message | SUCCESS sig=b0485c8c0b2ed594a72f elapsed=11.3s
```

**File:** `scripts/mwa_manager.gd` — `_on_message_signed()` signal handler

---

## Problem 8: Delete Flow — `queue_free()` Doesn't Remove Immediately

**Symptom:** After delete account, clicking Connect again shows "WalletAdapter not initialized". The WalletAdapter was null.

**Diagnostic log:**
```
[MWAManager] _setup_wallet_adapter | START children=1       ← OLD dying node still in tree
[MWAManager] _setup_wallet_adapter | FOUND wallet_adapter=WalletAdapter  ← grabbed the DYING node
... later ...
[MWAManager] authorize | FAIL wallet_adapter is null         ← freed node = null reference
```

**Root Cause:** `queue_free()` marks the node for deletion at end of frame but doesn't remove it from the children list immediately. When `_setup_wallet_adapter()` iterates children to find a WalletAdapter, it finds the dying node, stores the reference, then the frame ends and the node is freed — leaving `wallet_adapter` as a null/invalid reference.

**Fix:** Use `remove_child()` before `queue_free()`. `remove_child()` immediately removes the node from the tree's children list, so the subsequent `_setup_wallet_adapter()` finds 0 children and creates a fresh WalletAdapter.

```gdscript
var old_adapter = wallet_adapter
wallet_adapter = null
remove_child(old_adapter)    # Immediately removes from children list
old_adapter.queue_free()     # Memory cleanup at end of frame
_setup_wallet_adapter()      # Creates fresh WalletAdapter — children=0
```

**Confirmed log (after fix):**
```
[MWAManager] delete_account | destroying stale WalletAdapter
[MWAManager] _setup_wallet_adapter | START children=0       ← CLEAN — old node removed
[MWAManager] _setup_wallet_adapter | creating WalletAdapter programmatically
[MWAManager] delete_account | WalletAdapter recreated, stale state cleared
```

**File:** `scripts/mwa_manager.gd` — `delete_account()` function

---

## Problem 9: Sign-In Flow — No Biometric Confirmation on Connect

**Symptom:** Connecting to Seed Vault only required the wallet picker approval. No biometric (double-tap + fingerprint) was required. This doesn't match the React Native SDK parity where `authorize()` includes a signature to prove wallet ownership.

**Root Cause:** The SDK's `connect_wallet()` only establishes the MWA session — it doesn't sign anything. The biometric confirmation only happens when signing a message or transaction.

**Fix:** Chained `sign_message("Sign in to MWA Example App")` automatically after `connect_wallet()` succeeds inside `authorize()`. The user experience is seamless — tap Connect → Seed Vault wallet picker → approve → biometric sign confirmation → Home. No intermediate screens.

If the user rejects the sign step, the entire auth is cancelled — `_is_connected` is reset, pubkey cleared.

**Confirmed log:**
```
[MWAManager] authorize | CONNECTED pubkey=7etj... — now signing to confirm
[MWAManager] sign_message | START message_len=26 is_connected=true
[MWAManager] _on_message_signed | SIGNAL RECEIVED sig_from_bytes=ba513f7a97edb332... len=64
[MWAManager] authorize | SIGNED sig=ba513f7a97edb332eaef — auth complete
[MWAManager] authorize | cached auth pubkey=7etj...
[Main] _on_authorized | changing to Home scene
```

**File:** `scripts/mwa_manager.gd` — `authorize()` success path

---

## Problem 10: Delete Flow — No Seed Vault Confirmation

**Symptom:** Tapping "Delete Account" immediately cleared local state without requiring wallet ownership proof. A stolen phone with an unlocked app could delete without Seed Vault confirmation.

**Fix:** `delete_account()` calls `sign_message("Confirm account deletion for MWA Example App")` before proceeding. The user must complete the full Seed Vault biometric flow (verify → double-tap → fingerprint) to confirm deletion. If rejected, deletion is cancelled.

**Confirmed log:**
```
[MWAManager] delete_account | requesting Seed Vault confirmation via sign_message
[MWAManager] _on_message_signed | SIGNAL RECEIVED sig_from_bytes=06b06ffd6bd5a0c3... len=64
[MWAManager] delete_account | confirmed sig=06b06ffd6bd5a0c3c482 — proceeding with deletion
[MWAManager] deauthorize | DONE old_pubkey=7etj... state_cleared=true
[AuthCache] clear_all | DONE
[MWAManager] delete_account | WalletAdapter recreated, stale state cleared
```

**File:** `scripts/mwa_manager.gd` — `delete_account()` function

---

## Architecture: How the Integration Works

```
GDScript (mwa_manager.gd)
    │
    ├─ authorize(): connect_wallet() + poll key + auto sign_message("Sign in")
    ├─ sign_message(): sign_text_message() + capture sig from signal arg
    ├─ deauthorize(): clear local state
    └─ delete_account(): sign_message("Confirm deletion") + deauthorize + clear cache + recreate WalletAdapter
    │
    ↓ calls methods on
C++ GDExtension (WalletAdapter — from godot-solana-sdk)
    │
    ├─ connect_wallet() → launches Kotlin ComposeWalletActivity
    ├─ sign_text_message() → launches signing activity
    ├─ get_connected_key() → polls Kotlin plugin state → returns Pubkey object
    └─ message_signed signal → emits with PackedByteArray argument
    │
    ↓ communicates with
Kotlin Android Plugin (GDExtensionAndroidPlugin.kt)
    │
    ├─ Uses com.solanamobile:mobile-wallet-adapter-clientlib-ktx:2.0.3
    ├─ ComposeWalletActivity handles MWA protocol
    └─ State variables polled by C++ _process()
    │
    ↓ Android Intent
Wallet App (Seed Vault on Solana Seeker)
    │
    ├─ Wallet picker → user selects wallet
    ├─ Verify → "Confirm you are authorized to sign with this wallet"
    ├─ Biometric → double-tap side + fingerprint
    └─ Returns result via Activity result
```

---

## Key Insights for SDK Improvement

1. **Signal reliability:** The `connection_established` signal doesn't fire when WalletAdapter is created via `ClassDB.instantiate()`. This is likely a GDExtension binding issue. A polling-based API (returning state from methods) may be more reliable than signal-based for programmatically created nodes.

2. **Type safety:** `get_connected_key()` returns a `Pubkey` GDExtension object, not a String. This should be documented. Consider adding `get_connected_key_string() -> String` for convenience.

3. **Signature delivery:** The `message_signed` signal passes the signature as a `PackedByteArray` argument. This is not documented. `get_message_signature()` appears to return empty when signing via the Compose Activity path. The signal argument should be the documented primary method.

4. **State clearing:** After deauthorize, the native plugin retains the connected pubkey. There should be a `clear_state()` method exposed to GDScript to reset the adapter without recreating the node.

5. **Empty Pubkey:** `get_connected_key()` returns `[Pubkey:]` (empty Pubkey object) instead of `null` when not connected. This makes null-checking unreliable. Consider returning `null` for disconnected state.

---

## Working Flows (Confirmed on Seeker Hardware — April 5, 2026)

| Flow | Status | Time | Seed Vault Steps |
|------|--------|------|------------------|
| Connect + Sign In | **Working** | ~14s total | Wallet picker → approve → sign "Sign in" → biometric |
| Sign Message | **Working** | ~9s | Verify → biometric |
| Disconnect | **Working** | Instant | None (local state clear) |
| Delete Account | **Working** | ~9s + recreate | Sign "Confirm deletion" → biometric → clear all |
| Reconnect (after disconnect) | **Working** | ~14s | Same as Connect + Sign In |
| Reconnect (after delete) | **Working** | ~14s | Fresh auth (no stale key) |
| Auth Cache Persistence | **Working** | — | File-based at `user://auth_cache.json` |

### Full Sign-In Flow (confirmed in adb logcat)
```
User taps "Connect Wallet"
  → connect_wallet() → Seed Vault wallet picker (4s)
  → CONNECTED pubkey=7etj...Fm3w
  → auto sign_message("Sign in to MWA Example App") → Seed Vault verify + biometric (9s)
  → SIGNED sig=ba513f7a97edb332...
  → cached → authorized → Home screen
Total: ~14 seconds
```

### Full Delete Flow (confirmed in adb logcat)
```
User taps "Delete Account"
  → sign_message("Confirm account deletion") → Seed Vault verify + biometric (9s)
  → confirmed sig=06b06ffd6bd5a0c3...
  → deauthorize → cache.clear_all() → WalletAdapter destroyed + recreated
  → Landing screen (fresh state)
Total: ~9 seconds
```
