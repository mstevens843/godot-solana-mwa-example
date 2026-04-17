# Feature Flags

All flags are in `scripts/app_config.gd`. Flip them to toggle MWA behaviors.

---

## USE_SIWS (default: true)

Controls how the app authorizes with the wallet.

**true** - Uses Sign In With Solana (MWA 2.0). Combines connect + prove ownership in one wallet prompt. Returns SIWS signature, signed message, and account label alongside the pubkey. One tap for the user instead of two.

**false** - Uses standard `connectWallet` (MWA 1.x). Opens the OS wallet picker, user approves, returns pubkey and auth token. No ownership proof.

**Note:** Seed Vault does not support SIWS. If you need Seed Vault support, set this to false.

**How to test:**
1. Set `USE_SIWS = true` in app_config.gd
2. Build and deploy
3. Tap Connect - wallet should show SIWS sign-in prompt
4. Check logcat for `_authorize_siws | STEP_5 SUCCESS` and `siws_sig_size=64`
5. Set `USE_SIWS = false`, rebuild
6. Tap Connect - wallet should show standard authorize prompt
7. Check logcat for `_authorize_standard | STEP_5 SUCCESS`

---

## USE_MWA_SIGN_AND_SEND (default: true)

Controls how "Sign & Send" works.

**true** - Uses MWA 2.0 native `signAndSendTransactions`. The wallet signs AND broadcasts the transaction to the network. Returns the transaction signature directly. No RPC call from the app.

**false** - Fallback mode. Signs via MWA (wallet returns signature only), then the app would send via RPC. Currently signs only (RPC send not implemented in fallback). Use this to test sign-only flows or if the wallet does not support signAndSendTransactions.

**How to test:**
1. Set `USE_MWA_SIGN_AND_SEND = true` in app_config.gd
2. Build and deploy
3. Tap "Sign & Send" on the Home screen
4. Check logcat for `MWA_NATIVE MODE` and `STEP_7 SUCCESS sig_bytes_size=64`
5. Set `USE_MWA_SIGN_AND_SEND = false`, rebuild
6. Tap "Sign & Send"
7. Check logcat for `FALLBACK MODE` and `FALLBACK tx 1 SIGNED`

---

## USE_AUTH_CACHE (default: true)

Controls whether auth tokens are persisted to disk across app restarts.

**true** - After connecting, the auth token is synced from the Kotlin plugin via `getAuthToken()` and saved to `user://auth_cache.json`. On next app launch, the "Reconnect (Cached)" button appears. Tapping it restores the token via `setAuthToken()` and reconnects without opening the wallet picker.

**false** - No disk caching. Auth tokens live in Kotlin memory only. If you kill the app, you need to re-authorize through the wallet. No "Reconnect (Cached)" button on launch.

**How to test:**
1. Set `USE_AUTH_CACHE = true` in app_config.gd
2. Build and deploy, connect to a wallet
3. Check logcat for `AUTH_CACHE synced authToken` and `AUTH_CACHE SAVED`
4. Kill the app (swipe away from recents)
5. Relaunch - "Reconnect (Cached)" button should appear
6. Tap it - should reconnect without wallet picker
7. Check logcat for `CACHE_RESTORE pushed cached authToken` and `CACHE_RECONNECT SUCCESS`
8. Set `USE_AUTH_CACHE = false`, rebuild
9. Connect, kill app, relaunch - no "Reconnect (Cached)" button

---

## USE_OS_PICKER (default: true)

Controls the wallet selection UI on the connect screen.

**true** - Shows a single "Connect" button. The OS wallet picker appears and the user chooses their wallet there.

**false** - Shows individual wallet buttons (Phantom, Solflare, Jupiter, Backpack, Seed Vault). The app targets the specific wallet directly.

---

## All flags at a glance

| Flag | Default | What it controls |
|------|---------|-----------------|
| USE_SIWS | true | SIWS authorize vs standard connectWallet |
| USE_MWA_SIGN_AND_SEND | true | Wallet broadcasts vs sign-only + app RPC |
| USE_AUTH_CACHE | true | Disk token persistence vs in-memory only |
| USE_OS_PICKER | true | OS wallet picker vs in-app wallet buttons |
