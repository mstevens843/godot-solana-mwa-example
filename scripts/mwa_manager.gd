extends Node

## MWA Manager — Singleton that wraps the godot-solana-sdk WalletAdapter
## and exposes clean async methods for all MWA 2.0 operations.
##
## NOTE: The Godot SDK's WalletAdapter does not expose get_auth_token() or
## deauthorize(). Auth tokens are handled internally by the Kotlin plugin
## but not surfaced to GDScript. reauthorize() falls back to full authorize().
## The "Error loading GDExtension: WalletAdapterAndroid/plugin.gdextension"
## error on launch is expected and harmless — the AAR loads via Gradle, not GDExtension.

const TAG := "[MWAManager]"
const DIAG_INTERVAL := 2.0  # seconds between diagnostic logs (was 1.0 — reduced noise)

# Wallet type IDs (from godot-solana-sdk WalletAdapterUI)
const WALLET_PHANTOM := 20
const WALLET_SOLFLARE := 25
const WALLET_BACKPACK := 36

signal authorized(pubkey: String)
signal authorization_failed(error: String)
signal disconnected
signal message_signed(signature: String)
signal transaction_signed(signature: String)
signal transactions_sent(signatures: Array)
signal capabilities_received(caps: Dictionary)
signal status_updated(message: String)

var wallet_adapter: Node = null  # WalletAdapter node from godot-solana-sdk
var connected_pubkey: String = ""
var connected_wallet_type: int = -1  # actual wallet used — set during authorize, stored in cache
var auth_token: String = ""
var wallet_uri_base: String = ""
var siws_signature: String = ""
var siws_signed_message: String = ""
var siws_account_label: String = ""
var cache: AuthCache = AuthCache.new()

var _is_connected: bool = false
var _connection_completed: bool = false
var _connection_succeeded: bool = false
var _signing_completed: bool = false
var _last_signature: String = ""
var _waiting_for_connection: bool = false
var _waiting_for_signing: bool = false
var _diag_timer: float = 0.0
var _pre_connect_key: String = ""
var _deleted_keys: Array = []  # pubkeys explicitly deleted — reject in poll fallback
var _key_available: bool = false  # true ONLY after _on_connected signal fires — prevents Pubkey spam


func _ready() -> void:
	print("%s _ready | START" % TAG)
	print("%s _ready | platform=%s app=%s cluster=%s" % [TAG, OS.get_name(), AppConfig.APP_NAME, AppConfig.CLUSTER])
	_setup_wallet_adapter()
	print("%s _ready | DONE wallet_adapter_found=%s" % [TAG, str(wallet_adapter != null)])


func _process(delta: float) -> void:
	if not (_waiting_for_connection or _waiting_for_signing):
		return
	if wallet_adapter == null:
		return

	_diag_timer += delta
	if _diag_timer < DIAG_INTERVAL:
		return
	_diag_timer = 0.0

	# Poll WalletAdapter state while waiting (safe — no Pubkey error spam)
	var key_str = _safe_get_key_string()
	var wt = wallet_adapter.wallet_type if "wallet_type" in wallet_adapter else -1
	print("%s _process DIAG | waiting_conn=%s waiting_sign=%s key='%s' wallet_type=%s completed=%s succeeded=%s pre='%s' deleted_keys=%d" % [TAG, str(_waiting_for_connection), str(_waiting_for_signing), key_str, str(wt), str(_connection_completed), str(_connection_succeeded), _pre_connect_key, _deleted_keys.size()])


func _setup_wallet_adapter() -> void:
	print("%s _setup_wallet_adapter | START children=%d" % [TAG, get_child_count()])

	for child in get_children():
		var class_name_str := child.get_class()
		print("%s _setup_wallet_adapter | checking child=%s class=%s" % [TAG, child.name, class_name_str])
		if class_name_str == "WalletAdapter" or child.has_method("connect_wallet"):
			wallet_adapter = child
			print("%s _setup_wallet_adapter | FOUND wallet_adapter=%s" % [TAG, child.name])
			break

	if wallet_adapter == null:
		# Try to create WalletAdapter programmatically
		if ClassDB.class_exists("WalletAdapter"):
			print("%s _setup_wallet_adapter | creating WalletAdapter programmatically" % TAG)
			wallet_adapter = ClassDB.instantiate("WalletAdapter")
			wallet_adapter.name = "WalletAdapter"
			add_child(wallet_adapter)
			print("%s _setup_wallet_adapter | WalletAdapter created and added as child" % TAG)
		else:
			print("%s _setup_wallet_adapter | NOT_FOUND — WalletAdapter class not available. Install godot-solana-sdk plugin and enable it." % TAG)
			push_warning("MWAManager: WalletAdapter not found. Install godot-solana-sdk plugin.")
			return

	# Configure identity
	print("%s _setup_wallet_adapter | configuring identity name=%s uri=%s icon=%s" % [TAG, AppConfig.APP_NAME, AppConfig.APP_URI, AppConfig.APP_ICON_PATH])
	if wallet_adapter.has_method("set_mobile_identity_name"):
		wallet_adapter.set_mobile_identity_name(AppConfig.APP_NAME)
		print("%s _setup_wallet_adapter | set_mobile_identity_name OK" % TAG)
	else:
		print("%s _setup_wallet_adapter | WARN set_mobile_identity_name method not found" % TAG)

	if wallet_adapter.has_method("set_mobile_identity_uri"):
		wallet_adapter.set_mobile_identity_uri(AppConfig.APP_URI)
		print("%s _setup_wallet_adapter | set_mobile_identity_uri OK" % TAG)
	else:
		print("%s _setup_wallet_adapter | WARN set_mobile_identity_uri method not found" % TAG)

	if wallet_adapter.has_method("set_mobile_icon_path"):
		wallet_adapter.set_mobile_icon_path(AppConfig.APP_ICON_PATH)
		print("%s _setup_wallet_adapter | set_mobile_icon_path OK" % TAG)
	else:
		print("%s _setup_wallet_adapter | WARN set_mobile_icon_path method not found" % TAG)

	# Set cluster/blockchain
	if wallet_adapter.has_method("set_mobile_blockchain"):
		# SDK uses enum: 0=DEVNET, 1=MAINNET, 2=TESTNET
		var cluster_map := {"devnet": 0, "mainnet-beta": 1, "testnet": 2}
		var cluster_val: int = cluster_map.get(AppConfig.CLUSTER, 0)
		wallet_adapter.set_mobile_blockchain(cluster_val)
		print("%s _setup_wallet_adapter | set_mobile_blockchain=%d (%s)" % [TAG, cluster_val, AppConfig.CLUSTER])
	else:
		print("%s _setup_wallet_adapter | WARN set_mobile_blockchain method not found" % TAG)

	# Connect signals
	_connect_signal("connection_established", _on_connected)
	_connect_signal("connection_failed", _on_connection_failed)
	_connect_signal("message_signed", _on_message_signed)
	_connect_signal("signing_failed", _on_signing_failed)

	# Log available wallets
	if wallet_adapter.has_method("get_available_wallets"):
		var wallets = wallet_adapter.get_available_wallets()
		print("%s _setup_wallet_adapter | available_wallets=%s" % [TAG, str(wallets)])
	else:
		print("%s _setup_wallet_adapter | WARN get_available_wallets not found" % TAG)

	# Probe SDK API surface for auth_token, clear_state, deauthorize, etc.
	for method in ["get_auth_token", "clear_state", "deauthorize", "get_capabilities", "sign_in", "get_authorization_token"]:
		print("%s _setup_wallet_adapter | probe %s=%s" % [TAG, method, str(wallet_adapter.has_method(method))])

	# Try to clear stale state from previous session
	if wallet_adapter.has_method("clear_state"):
		wallet_adapter.clear_state()
		print("%s _setup_wallet_adapter | clear_state() called" % TAG)

	# Set Kotlin plugin identity vars so signing/transact works even after app restart + cache reconnect
	if Engine.has_singleton("WalletAdapterAndroid"):
		var cluster_map_k := {"devnet": 0, "mainnet-beta": 1, "testnet": 2}
		var cluster_k: int = cluster_map_k.get(AppConfig.CLUSTER, 0)
		var plugin = Engine.get_singleton("WalletAdapterAndroid")
		plugin.call("setIdentity", cluster_k, AppConfig.APP_URI, AppConfig.APP_ICON_PATH, AppConfig.APP_NAME)
		print("%s _setup_wallet_adapter | setIdentity called cluster=%d uri=%s icon=%s name=%s" % [TAG, cluster_k, AppConfig.APP_URI, AppConfig.APP_ICON_PATH, AppConfig.APP_NAME])

	print("%s _setup_wallet_adapter | DONE signals connected" % TAG)


func _connect_signal(sig_name: String, handler: Callable) -> void:
	if wallet_adapter.has_signal(sig_name):
		wallet_adapter.connect(sig_name, handler)
		print("%s _connect_signal | connected signal=%s" % [TAG, sig_name])
	else:
		print("%s _connect_signal | WARN signal=%s not found on WalletAdapter" % [TAG, sig_name])


## ─── AUTHORIZE ───────────────────────────────────────────────────────────────

func authorize(wallet_type_id: int = -1) -> bool:
	print("%s authorize | START is_connected=%s wallet_adapter=%s wallet_type_id=%d (%s)" % [TAG, str(_is_connected), str(wallet_adapter != null), wallet_type_id, _wallet_type_name(wallet_type_id)])

	if wallet_adapter == null:
		print("%s authorize | FAIL wallet_adapter is null" % TAG)
		authorization_failed.emit("WalletAdapter not initialized")
		return false

	# Set wallet_type BEFORE connect so the SDK targets the right wallet
	if wallet_type_id >= 0 and "wallet_type" in wallet_adapter:
		wallet_adapter.wallet_type = wallet_type_id
		print("%s authorize | set wallet_adapter.wallet_type=%d" % [TAG, wallet_type_id])

	# Reset state flags (prevent leaks from prior attempts) — but keep _key_available
	# so we can read the current cached key for the pre_connect_key snapshot below.
	_connection_completed = false
	_connection_succeeded = false
	_waiting_for_connection = true
	_signing_completed = false
	_last_signature = ""
	_diag_timer = 0.0

	# Clear deleted keys — after delete_account, Connect should work as fresh slate
	if _deleted_keys.size() > 0:
		print("%s authorize | clearing _deleted_keys=%s (connect = clean slate)" % [TAG, str(_deleted_keys)])
		_deleted_keys.clear()

	# Log wallet_type for this attempt
	var current_wallet_type: int = wallet_adapter.wallet_type if "wallet_type" in wallet_adapter else -1
	print("%s authorize | wallet_type=%d (%s)" % [TAG, current_wallet_type, _wallet_type_name(current_wallet_type)])

	# Clear Java-side cached key so connect_wallet() opens the OS picker fresh.
	# The _on_connected signal may fire immediately with an empty key after clearing —
	# the authorize loop below rejects empty pubkeys and waits for the real connection.
	_clear_java_cached_key()

	# Destroy and recreate WalletAdapter to kill C++ cached connection state.
	print("%s authorize | DESTROYING adapter to force fresh OS picker" % TAG)
	var old_adapter = wallet_adapter
	wallet_adapter = null
	_key_available = false
	remove_child(old_adapter)
	old_adapter.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	_setup_wallet_adapter()
	if wallet_adapter == null:
		print("%s authorize | FAIL could not recreate WalletAdapter" % TAG)
		authorization_failed.emit("Failed to recreate WalletAdapter")
		return false
	# Re-apply wallet_type after recreation
	if wallet_type_id >= 0 and "wallet_type" in wallet_adapter:
		wallet_adapter.wallet_type = wallet_type_id
		print("%s authorize | re-applied wallet_type=%d after recreation" % [TAG, wallet_type_id])
	print("%s authorize | adapter recreated — fresh session" % TAG)

	# ─── STANDARD AUTHORIZE (connectWallet) ───
	# Uses C++ WalletAdapter's connect_wallet() which opens the OS wallet picker.

	# STEP_1: Reset stale Kotlin state
	if Engine.has_singleton("WalletAdapterAndroid"):
		var plugin = Engine.get_singleton("WalletAdapterAndroid")
		plugin.call("clearState")
		print("%s authorize | STEP_1 clearState() DONE" % TAG)

	# STEP_2: Call connect_wallet via C++ WalletAdapter
	print("%s authorize | STEP_2 calling connect_wallet() — OS picker should open" % TAG)
	status_updated.emit("Choose your wallet...")
	_connection_completed = false
	_connection_succeeded = false
	wallet_adapter.connect_wallet()
	print("%s authorize | STEP_3 connect_wallet() CALLED — waiting for signal" % TAG)

	# STEP_4: Poll for connection result (signal sets _connection_completed)
	print("%s authorize | STEP_4 POLLING start (timeout=60s, interval=0.3s)" % TAG)
	var elapsed := 0.0
	var poll_count := 0
	while elapsed < 60.0:
		await get_tree().create_timer(0.3).timeout
		elapsed += 0.3
		poll_count += 1
		if _connection_completed:
			print("%s authorize | STEP_4 POLL_EXIT _connection_completed=true elapsed=%.1fs polls=%d" % [TAG, elapsed, poll_count])
			break
		if elapsed < 10.0 or (int(elapsed * 10) % 50 == 0 and elapsed > 0.5):
			print("%s authorize | POLL elapsed=%.1fs completed=%s succeeded=%s polls=%d" % [TAG, elapsed, str(_connection_completed), str(_connection_succeeded), poll_count])

	_waiting_for_connection = false
	print("%s authorize | STEP_5 FINAL completed=%s succeeded=%s elapsed=%.1fs total_polls=%d" % [TAG, str(_connection_completed), str(_connection_succeeded), elapsed, poll_count])

	if _connection_completed and _connection_succeeded:
		# STEP_6: Success — extract pubkey
		_key_available = true
		var raw_key = wallet_adapter.get_connected_key()
		connected_pubkey = _extract_pubkey_string(raw_key)
		print("%s authorize | STEP_6 pubkey='%s' (len=%d)" % [TAG, connected_pubkey, connected_pubkey.length()])

		# REJECT empty pubkey
		if connected_pubkey.is_empty() or connected_pubkey.length() < 20:
			print("%s authorize | STEP_6 REJECTED empty pubkey (len=%d)" % [TAG, connected_pubkey.length()])
			_is_connected = false
			connected_pubkey = ""
			_key_available = false
			authorization_failed.emit("Empty pubkey — please try again")
			return false

		# REJECT deleted keys
		if connected_pubkey in _deleted_keys:
			print("%s authorize | STEP_6 REJECTED deleted key=%s" % [TAG, connected_pubkey])
			_is_connected = false
			connected_pubkey = ""
			_key_available = false
			status_updated.emit("This account was deleted. Choose a different wallet.")
			authorization_failed.emit("Deleted account — choose a different wallet")
			return false

		_is_connected = true
		connected_wallet_type = wallet_adapter.wallet_type if "wallet_type" in wallet_adapter else -1
		print("%s authorize | STEP_6 SUCCESS pubkey=%s wallet_type=%d (%s)" % [TAG, connected_pubkey, connected_wallet_type, _wallet_type_name(connected_wallet_type)])

		AndroidToastHelper.show("Connected: %s" % _truncate_pubkey(connected_pubkey))

		# STEP_7: Sync auth token from Kotlin plugin and cache to disk
		if Engine.has_singleton("WalletAdapterAndroid"):
			var kt_token := str(Engine.get_singleton("WalletAdapterAndroid").call("getAuthToken"))
			if not kt_token.is_empty():
				auth_token = kt_token
				print("%s authorize | STEP_7 AUTH_CACHE synced authToken from Kotlin plugin token_len=%d" % [TAG, kt_token.length()])
			else:
				print("%s authorize | STEP_7 AUTH_CACHE Kotlin getAuthToken returned empty, using local auth_token_len=%d" % [TAG, auth_token.length()])
		cache.set_auth(connected_pubkey, auth_token, wallet_uri_base, connected_wallet_type)
		print("%s authorize | STEP_7 AUTH_CACHE SAVED pubkey=%s token_len=%d wallet_type=%d" % [TAG, connected_pubkey, auth_token.length(), connected_wallet_type])

		status_updated.emit("Connected: " + _truncate_pubkey(connected_pubkey))
		authorized.emit(connected_pubkey)
		print("%s authorize | STEP_7 DONE — authorized signal emitted" % TAG)
		return true

	elif _connection_completed and not _connection_succeeded:
		print("%s authorize | REJECTED by wallet elapsed=%.1fs" % [TAG, elapsed])
		status_updated.emit("Authorization rejected by wallet")
		authorization_failed.emit("User rejected or wallet error")
		return false
	else:
		print("%s authorize | TIMEOUT elapsed=%.1fs — wallet never responded" % [TAG, elapsed])
		status_updated.emit("Authorization timed out")
		authorization_failed.emit("Timeout — no response from wallet")
		return false


## ─── REAUTHORIZE ─────────────────────────────────────────────────────────────

func reauthorize() -> bool:
	print("%s reauthorize | START" % TAG)
	var cached = cache.get_latest_auth()
	if cached == null:
		print("%s reauthorize | FAIL no cached authorization" % TAG)
		status_updated.emit("No cached authorization found")
		return false

	var cached_token := str(cached.get("auth_token", ""))
	print("%s reauthorize | cached_pubkey=%s cached_token_len=%d" % [TAG, str(cached.get("pubkey", "")), cached_token.length()])
	status_updated.emit("Reauthorizing with cached token...")

	# Use our AuthCache directly — no connect_wallet() call needed.
	# This is the ONLY place that uses cached reconnection.
	var pubkey := str(cached.get("pubkey", ""))
	var wt := int(cached.get("wallet_type", -1))
	print("%s reauthorize | CACHE_RECONNECT pubkey=%s wallet_type=%d (%s) — using AuthCache directly, no connect_wallet()" % [TAG, pubkey, wt, _wallet_type_name(wt)])

	if pubkey.is_empty():
		print("%s reauthorize | FAIL cached pubkey is empty" % TAG)
		authorization_failed.emit("Cached pubkey is empty")
		return false

	# Push cached auth token back into the Kotlin plugin so MWA operations
	# (sign, getCapabilities, etc.) use it without re-prompting the user.
	if not cached_token.is_empty() and Engine.has_singleton("WalletAdapterAndroid"):
		var plugin = Engine.get_singleton("WalletAdapterAndroid")
		plugin.call("setAuthToken", cached_token)
		print("%s reauthorize | CACHE_RESTORE pushed cached authToken to Kotlin plugin token_len=%d" % [TAG, cached_token.length()])
	else:
		print("%s reauthorize | CACHE_RESTORE SKIP — no cached token or no plugin (token_len=%d has_plugin=%s)" % [TAG, cached_token.length(), str(Engine.has_singleton("WalletAdapterAndroid"))])

	connected_pubkey = pubkey
	connected_wallet_type = wt
	auth_token = cached_token
	_is_connected = true
	_connection_completed = true
	_connection_succeeded = true
	_key_available = true

	print("%s reauthorize | CACHE_RECONNECT SUCCESS pubkey=%s wallet_type=%d auth_token_len=%d" % [TAG, connected_pubkey, connected_wallet_type, auth_token.length()])
	AndroidToastHelper.show("Reconnected: %s" % _truncate_pubkey(connected_pubkey))
	status_updated.emit("Connected: " + _truncate_pubkey(connected_pubkey))
	authorized.emit(connected_pubkey)
	return true


## ─── DEAUTHORIZE ─────────────────────────────────────────────────────────────

func deauthorize() -> void:
	print("%s deauthorize | START pubkey=%s is_connected=%s" % [TAG, connected_pubkey, str(_is_connected)])
	status_updated.emit("Deauthorizing...")

	# Try SDK deauthorize if available
	if wallet_adapter != null and wallet_adapter.has_method("deauthorize"):
		print("%s deauthorize | calling wallet_adapter.deauthorize()" % TAG)
		wallet_adapter.deauthorize()
	else:
		print("%s deauthorize | SDK deauthorize not available, clearing local state" % TAG)

	# Clear Kotlin-side auth token and force fresh wallet picker on next connect
	if Engine.has_singleton("WalletAdapterAndroid"):
		var plugin = Engine.get_singleton("WalletAdapterAndroid")
		plugin.call("setAuthToken", "")
		plugin.call("clearStateFullReset")
		print("%s deauthorize | AUTH_CACHE cleared Kotlin authToken + called clearStateFullReset" % TAG)

	# Clear cached auth from disk
	cache.clear_auth(connected_pubkey)
	print("%s deauthorize | AUTH_CACHE cleared disk cache for pubkey=%s" % [TAG, connected_pubkey])

	var old_pubkey := connected_pubkey
	connected_pubkey = ""
	connected_wallet_type = -1
	auth_token = ""
	wallet_uri_base = ""
	_is_connected = false
	_connection_completed = false
	_connection_succeeded = false
	_signing_completed = false
	_last_signature = ""
	_key_available = false

	print("%s deauthorize | DONE old_pubkey=%s state_cleared=true" % [TAG, old_pubkey])
	AndroidToastHelper.show("Wallet disconnected")
	status_updated.emit("Disconnected")
	disconnected.emit()


## ─── SIGN MESSAGE ────────────────────────────────────────────────────────────

func sign_message(message: String) -> String:
	print("%s sign_message | START message='%s' message_len=%d is_connected=%s wallet_adapter=%s" % [TAG, message, message.length(), str(_is_connected), str(wallet_adapter != null)])

	if not _is_connected:
		print("%s sign_message | FAIL_REASON=not_connected _is_connected=%s" % [TAG, str(_is_connected)])
		status_updated.emit("Not connected")
		return ""
	if wallet_adapter == null:
		print("%s sign_message | FAIL_REASON=wallet_adapter_null" % TAG)
		status_updated.emit("Not connected")
		return ""

	# Log exact state before resetting
	print("%s sign_message | PRE_RESET _signing_completed=%s _last_signature_len=%d _waiting_for_signing=%s _connection_completed=%s _connection_succeeded=%s" % [TAG, str(_signing_completed), _last_signature.length(), str(_waiting_for_signing), str(_connection_completed), str(_connection_succeeded)])

	_signing_completed = false
	_last_signature = ""
	_waiting_for_signing = true

	# Log wallet adapter state right before calling sign
	var wa_key_before = _safe_get_key_string()
	var wa_type_before = wallet_adapter.wallet_type if "wallet_type" in wallet_adapter else -1
	print("%s sign_message | PRE_SIGN wa_key='%s' wa_type=%d has_sign_text_message=%s" % [TAG, wa_key_before, wa_type_before, str(wallet_adapter.has_method("sign_text_message"))])

	print("%s sign_message | CALLING wallet_adapter.sign_text_message('%s')" % [TAG, message])
	status_updated.emit("Signing message...")
	wallet_adapter.sign_text_message(message)
	print("%s sign_message | CALLED sign_text_message — now waiting" % TAG)

	# Wait for signing result
	print("%s sign_message | WAITING timeout=30s _signing_completed=%s" % [TAG, str(_signing_completed)])
	var elapsed := 0.0
	while not _signing_completed and elapsed < 30.0:
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
		# Log every 5 seconds while waiting
		if int(elapsed * 10) % 50 == 0 and elapsed > 0.1:
			print("%s sign_message | WAIT_TICK elapsed=%.1fs _signing_completed=%s _last_sig_len=%d" % [TAG, elapsed, str(_signing_completed), _last_signature.length()])

	_waiting_for_signing = false

	# Log exact final state
	print("%s sign_message | DONE_WAITING elapsed=%.1fs _signing_completed=%s _last_signature_len=%d _last_signature_empty=%s" % [TAG, elapsed, str(_signing_completed), _last_signature.length(), str(_last_signature.is_empty())])

	if _signing_completed and not _last_signature.is_empty():
		print("%s sign_message | SUCCESS sig=%s sig_len=%d elapsed=%.1fs" % [TAG, _last_signature.substr(0, 40), _last_signature.length(), elapsed])
		AndroidToastHelper.show("Message signed: %s..." % _last_signature.substr(0, 16))
		status_updated.emit("Message signed: " + _last_signature.substr(0, 16) + "...")
		message_signed.emit(_last_signature)
		return _last_signature
	else:
		print("%s sign_message | FAIL _signing_completed=%s _last_signature_empty=%s _last_signature_len=%d elapsed=%.1fs REASON=%s" % [TAG, str(_signing_completed), str(_last_signature.is_empty()), _last_signature.length(), elapsed, "timeout" if elapsed >= 30.0 else ("completed_but_empty_sig" if _signing_completed else "not_completed")])
		status_updated.emit("Signing failed or timed out")
		return ""


## ─── SIGN TRANSACTION ────────────────────────────────────────────────────────

func sign_transaction(serialized_tx: PackedByteArray) -> String:
	print("%s sign_transaction | START tx_bytes=%d is_connected=%s" % [TAG, serialized_tx.size(), str(_is_connected)])

	if not _is_connected or wallet_adapter == null:
		print("%s sign_transaction | FAIL not connected or no wallet_adapter" % TAG)
		status_updated.emit("Not connected")
		return ""

	_signing_completed = false
	_last_signature = ""
	_waiting_for_signing = true
	print("%s sign_transaction | calling wallet_adapter.sign_message(tx, 0)" % TAG)
	status_updated.emit("Signing transaction...")
	wallet_adapter.sign_message(serialized_tx, 0)

	# Wait for signing result
	print("%s sign_transaction | waiting for signature (timeout=30s)" % TAG)
	var elapsed := 0.0
	while not _signing_completed and elapsed < 30.0:
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1

	_waiting_for_signing = false

	if _signing_completed and not _last_signature.is_empty():
		print("%s sign_transaction | SUCCESS sig=%s elapsed=%.1fs" % [TAG, _last_signature.substr(0, 20), elapsed])
		AndroidToastHelper.show("Transaction signed successfully")
		status_updated.emit("Transaction signed: " + _last_signature.substr(0, 16) + "...")
		transaction_signed.emit(_last_signature)
		return _last_signature
	else:
		print("%s sign_transaction | FAIL completed=%s elapsed=%.1fs" % [TAG, str(_signing_completed), elapsed])
		status_updated.emit("Signing failed or timed out")
		return ""


## ─── SIGN AND SEND TRANSACTIONS ──────────────────────────────────────────────

func sign_and_send_transactions(transactions: Array) -> Array:
	print("%s sign_and_send_transactions | START tx_count=%d is_connected=%s" % [TAG, transactions.size(), str(_is_connected)])

	if not _is_connected or wallet_adapter == null:
		print("%s sign_and_send_transactions | FAIL not connected" % TAG)
		status_updated.emit("Not connected")
		return []

	var has_plugin: bool = Engine.has_singleton("WalletAdapterAndroid")
	print("%s sign_and_send_transactions | has_WalletAdapterAndroid=%s" % [TAG, str(has_plugin)])

	if not has_plugin:
		print("%s sign_and_send_transactions | FAIL plugin not available" % TAG)
		status_updated.emit("Sign & send not available — plugin missing")
		return []

	var plugin = Engine.get_singleton("WalletAdapterAndroid")
	status_updated.emit("Signing and sending %d transaction(s)..." % transactions.size())

	# MWA 2.0 signAndSendTransactions: wallet signs AND broadcasts.
	# We get back a 64-byte Ed25519 signature — NOT a signed tx.
	# No RPC sendTransaction needed — the wallet already broadcast.

	var signatures: Array = []
	for i in range(transactions.size()):
		var tx_bytes: PackedByteArray = transactions[i]
		print("%s sign_and_send_transactions | tx %d/%d ENTRY tx_bytes_size=%d tx_hex=%s" % [TAG, i + 1, transactions.size(), tx_bytes.size(), tx_bytes.hex_encode().substr(0, 80)])

		# STEP 1: Reset Kotlin global state before each tx
		print("%s sign_and_send_transactions | STEP_1 tx %d/%d PRE_CLEAR — calling clearState()" % [TAG, i + 1, transactions.size()])
		plugin.call("clearState")
		print("%s sign_and_send_transactions | STEP_2 tx %d clearState() DONE" % [TAG, i + 1])

		# STEP 3: Verify status is 0 after clearState
		var pre_status: int = plugin.call("getSignAndSendStatus")
		print("%s sign_and_send_transactions | STEP_3 tx %d POST_CLEAR status=%d (must be 0)" % [TAG, i + 1, pre_status])
		if pre_status != 0:
			print("%s sign_and_send_transactions | STEP_3 CRITICAL clearState DID NOT RESET status still=%d" % [TAG, pre_status])

		# STEP 4: Call signAndSendTransaction on the Kotlin plugin
		print("%s sign_and_send_transactions | STEP_4 tx %d calling plugin.signAndSendTransaction() tx_bytes_size=%d" % [TAG, i + 1, tx_bytes.size()])
		status_updated.emit("Approve tx %d/%d in wallet..." % [i + 1, transactions.size()])
		plugin.call("signAndSendTransaction", tx_bytes)
		print("%s sign_and_send_transactions | STEP_4 tx %d signAndSendTransaction() CALLED — wallet activity should launch" % [TAG, i + 1])

		# STEP 5: Poll for wallet result (wallet signs + broadcasts, returns signature)
		print("%s sign_and_send_transactions | STEP_5 tx %d POLLING start (timeout=60s, interval=0.3s)" % [TAG, i + 1])
		var elapsed := 0.0
		var poll_count := 0
		while elapsed < 60.0:
			await get_tree().create_timer(0.3).timeout
			elapsed += 0.3
			poll_count += 1
			var poll_status: int = plugin.call("getSignAndSendStatus")
			if poll_status != 0:
				print("%s sign_and_send_transactions | STEP_5 tx %d POLL_EXIT status=%d elapsed=%.1fs polls=%d" % [TAG, i + 1, poll_status, elapsed, poll_count])
				break
			if elapsed < 10.0 or (int(elapsed * 10) % 50 == 0 and elapsed > 0.5):
				print("%s sign_and_send_transactions | STEP_5_POLL tx %d elapsed=%.1fs status=%d polls=%d" % [TAG, i + 1, elapsed, poll_status, poll_count])

		# STEP 6: Read final status
		var final_status: int = plugin.call("getSignAndSendStatus")
		print("%s sign_and_send_transactions | STEP_6 tx %d FINAL_STATUS=%d elapsed=%.1fs total_polls=%d" % [TAG, i + 1, final_status, elapsed, poll_count])

		if final_status == 1:
			# STEP 7: Wallet signed + broadcast successfully — get the 64-byte signature
			var sig_bytes: PackedByteArray = plugin.call("getSignAndSendResult")
			var sig_hex: String = sig_bytes.hex_encode()
			print("%s sign_and_send_transactions | STEP_7 tx %d SUCCESS sig_bytes_size=%d sig_hex=%s" % [TAG, i + 1, sig_bytes.size(), sig_hex])
			if sig_bytes.size() != 64:
				print("%s sign_and_send_transactions | STEP_7 WARNING expected 64 bytes got %d raw_hex=%s" % [TAG, sig_bytes.size(), sig_bytes.hex_encode()])
			signatures.append(sig_hex)
		elif final_status == 0:
			print("%s sign_and_send_transactions | STEP_7 tx %d TIMEOUT elapsed=%.1fs — wallet never responded" % [TAG, i + 1, elapsed])
		else:
			print("%s sign_and_send_transactions | STEP_7 tx %d FAILED status=%d — wallet rejected or error" % [TAG, i + 1, final_status])

	print("%s sign_and_send_transactions | STEP_8 DONE sent=%d/%d signatures=%s" % [TAG, signatures.size(), transactions.size(), str(signatures).substr(0, 200)])
	if signatures.size() > 0:
		AndroidToastHelper.show("Sent %d transaction(s)" % signatures.size(), true)
		status_updated.emit("Sent! Sig: %s..." % str(signatures[0]).substr(0, 20))
	else:
		status_updated.emit("Sign & send failed")
	transactions_sent.emit(signatures)
	return signatures


## ─── GET CAPABILITIES ────────────────────────────────────────────────────────

func get_capabilities() -> Dictionary:
	print("%s get_capabilities | START is_connected=%s" % [TAG, str(_is_connected)])

	if not _is_connected or wallet_adapter == null:
		print("%s get_capabilities | FAIL not connected" % TAG)
		status_updated.emit("Not connected")
		return {}

	status_updated.emit("Querying wallet capabilities...")

	# Call the real getCapabilities via the WalletAdapterAndroid plugin
	var has_plugin: bool = Engine.has_singleton("WalletAdapterAndroid")
	print("%s get_capabilities | has_WalletAdapterAndroid=%s" % [TAG, str(has_plugin)])

	if has_plugin:
		var plugin = Engine.get_singleton("WalletAdapterAndroid")
		print("%s get_capabilities | plugin=%s calling getCapabilitiesWallet()" % [TAG, str(plugin)])
		plugin.call("getCapabilitiesWallet")

		# Poll for result (the Kotlin plugin opens a wallet activity)
		print("%s get_capabilities | POLLING for result (timeout=30s)" % TAG)
		var elapsed := 0.0
		while elapsed < 30.0:
			await get_tree().create_timer(0.2).timeout
			elapsed += 0.2
			var poll_status = plugin.call("getCapabilitiesStatus")
			if poll_status != 0:
				print("%s get_capabilities | POLL_DONE status=%d elapsed=%.1fs" % [TAG, poll_status, elapsed])
				break
			if int(elapsed * 10) % 50 == 0 and elapsed > 0.5:
				print("%s get_capabilities | POLL_TICK elapsed=%.1fs status=0 (still waiting)" % [TAG, elapsed])

		var status = plugin.call("getCapabilitiesStatus")
		var result_str = plugin.call("getCapabilitiesResult")
		print("%s get_capabilities | FINAL_STATUS=%d result_str_len=%d result_str='%s'" % [TAG, status, str(result_str).length(), str(result_str).substr(0, 120)])

		if status == 1 and not str(result_str).is_empty():
			# Parse the comma-separated key=value string from Kotlin
			var caps := {}
			var parts = str(result_str).split(",")
			print("%s get_capabilities | parsing %d key=value pairs" % [TAG, parts.size()])
			for part in parts:
				var kv = part.split("=", true, 1)
				if kv.size() == 2:
					caps[kv[0]] = kv[1]
					print("%s get_capabilities | PARSED key='%s' value='%s'" % [TAG, kv[0], kv[1]])
				else:
					print("%s get_capabilities | SKIP malformed part='%s'" % [TAG, part])
			print("%s get_capabilities | DONE total_caps=%d caps=%s" % [TAG, caps.size(), str(caps)])
			AndroidToastHelper.show("Capabilities received from wallet")
			status_updated.emit("Capabilities received")
			capabilities_received.emit(caps)
			return caps
		else:
			print("%s get_capabilities | FAIL status=%d result_empty=%s elapsed=%.1fs" % [TAG, status, str(str(result_str).is_empty()), elapsed])
			status_updated.emit("Failed to get capabilities")
			return {}

	# Fallback: hardcoded defaults if plugin not available
	print("%s get_capabilities | FALLBACK — plugin not available, returning defaults" % TAG)
	var caps := {
		"max_transactions_per_request": 10,
		"max_messages_per_request": 10,
		"supported_transaction_versions": ["legacy", 0],
	}
	status_updated.emit("Capabilities (defaults)")
	capabilities_received.emit(caps)
	return caps


## ─── DELETE ACCOUNT ──────────────────────────────────────────────────────────

func delete_account() -> void:
	print("%s delete_account | START pubkey=%s" % [TAG, connected_pubkey])

	if not _is_connected or wallet_adapter == null:
		print("%s delete_account | FAIL not connected" % TAG)
		status_updated.emit("Not connected — cannot delete")
		return

	# Require wallet confirmation before deleting.
	# Route based on connected_wallet_type:
	#   Solflare (25) → connect_wallet() only (signMessage broken on MWA for Solflare)
	#   All others → sign_text_message() (biometric/sign confirmation)
	print("%s delete_account | connected_wallet_type=%d (%s)" % [TAG, connected_wallet_type, _wallet_type_name(connected_wallet_type)])

	if connected_wallet_type == WALLET_SOLFLARE:
		# Solflare: signMessage broken — use connect_wallet() like SolPulse's nativeAuthorize()
		print("%s delete_account | Solflare — using connect_wallet() for confirmation" % TAG)
		status_updated.emit("Approve in Solflare to confirm deletion...")
		_connection_completed = false
		_connection_succeeded = false
		_key_available = false
		wallet_adapter.connect_wallet()

		var elapsed := 0.0
		while not _connection_completed and elapsed < 30.0:
			await get_tree().create_timer(0.5).timeout
			elapsed += 0.5

		if not (_connection_completed and _connection_succeeded):
			print("%s delete_account | Solflare confirmation rejected — cancelling delete" % TAG)
			status_updated.emit("Delete cancelled — wallet confirmation required")
			return
		print("%s delete_account | confirmed via Solflare connect_wallet()" % TAG)
	else:
		# All other wallets: sign_text_message for confirmation
		print("%s delete_account | requesting confirmation via sign_message" % TAG)
		status_updated.emit("Confirm deletion in your wallet...")
		var sig = await sign_message("Confirm account deletion for %s" % AppConfig.APP_NAME)
		if sig.is_empty():
			print("%s delete_account | sign failed — aborting delete" % TAG)
			status_updated.emit("Delete cancelled — confirmation required")
			return
		print("%s delete_account | confirmed sig=%s — proceeding with deletion" % [TAG, sig.substr(0, 20)])

	# Record the key being deleted so poll fallback won't accept it as a reconnect
	if not connected_pubkey.is_empty():
		_deleted_keys.append(connected_pubkey)
		print("%s delete_account | recorded deleted key=%s total_deleted=%d" % [TAG, connected_pubkey, _deleted_keys.size()])

	await deauthorize()
	cache.clear_all()

	# Destroy and recreate WalletAdapter to clear stale internal state (pubkey)
	if wallet_adapter != null:
		print("%s delete_account | destroying stale WalletAdapter" % TAG)
		var old_adapter = wallet_adapter
		wallet_adapter = null
		remove_child(old_adapter)
		old_adapter.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
		_setup_wallet_adapter()
		print("%s delete_account | WalletAdapter recreated, stale state cleared" % TAG)

	print("%s delete_account | DONE cache cleared, session destroyed" % TAG)
	AndroidToastHelper.show("Account deleted, cache cleared", true)
	status_updated.emit("Account deleted — all cached data cleared")


## ─── HELPERS ─────────────────────────────────────────────────────────────────

## Dump exhaustive diagnostics about the Android plugin layer.
## Logs every singleton, every method, every property — pure observation, no fixes.
func _dump_android_plugin_diagnostics() -> void:
	print("%s DIAG_PLUGIN | ========== ANDROID PLUGIN DIAGNOSTICS ==========" % TAG)

	# 1. List ALL engine singletons
	var singletons = Engine.get_singleton_list()
	print("%s DIAG_PLUGIN | Engine singletons count=%d list=%s" % [TAG, singletons.size(), str(singletons)])

	# 2. Check WalletAdapterAndroid singleton
	var has_wa = Engine.has_singleton("WalletAdapterAndroid")
	print("%s DIAG_PLUGIN | has_singleton('WalletAdapterAndroid')=%s" % [TAG, str(has_wa)])

	if has_wa:
		var plugin = Engine.get_singleton("WalletAdapterAndroid")
		print("%s DIAG_PLUGIN | plugin=%s type=%s class=%s" % [TAG, str(plugin), str(typeof(plugin)), plugin.get_class()])

		# Dump ALL methods on the plugin
		var methods = plugin.get_method_list()
		print("%s DIAG_PLUGIN | plugin method_count=%d" % [TAG, methods.size()])
		for m in methods:
			print("%s DIAG_PLUGIN | plugin_method: %s" % [TAG, m.get("name", "?")])

		# Try every possible method name
		for method_name in ["clearState", "clear_state", "getConnectionStatus", "get_connection_status",
				"getConnectedKey", "get_connected_key", "getAuthToken", "get_auth_token",
				"connectWallet", "connect_wallet", "getLatestAction", "get_latest_action",
				"getSigningStatus", "get_signing_status", "getMessageSignature"]:
			var has = plugin.has_method(method_name)
			if has:
				print("%s DIAG_PLUGIN | TRY %s → EXISTS" % [TAG, method_name])
				if method_name in ["clearState", "clear_state", "getConnectionStatus",
						"get_connection_status", "getLatestAction", "get_latest_action",
						"getSigningStatus", "get_signing_status"]:
					var result = plugin.call(method_name)
					print("%s DIAG_PLUGIN | CALL %s() → %s (type=%s)" % [TAG, method_name, str(result), str(typeof(result))])
			else:
				print("%s DIAG_PLUGIN | TRY %s → NOT_FOUND" % [TAG, method_name])

	# 3. WalletAdapter node methods and properties
	if wallet_adapter != null:
		print("%s DIAG_PLUGIN | wallet_adapter class=%s" % [TAG, wallet_adapter.get_class()])
		var wa_methods = wallet_adapter.get_method_list()
		print("%s DIAG_PLUGIN | wallet_adapter method_count=%d" % [TAG, wa_methods.size()])
		for m in wa_methods:
			var mname = m.get("name", "?")
			if not mname.begins_with("_") and not mname in ["get_class", "get_name", "get_parent", "set", "get", "has_method", "call", "emit_signal", "connect", "disconnect", "is_connected"]:
				print("%s DIAG_PLUGIN | wa_method: %s" % [TAG, mname])

		for pname in ["connected", "wallet_type", "active_signer_index", "wallet_state"]:
			if pname in wallet_adapter:
				var val = wallet_adapter.get(pname)
				print("%s DIAG_PLUGIN | wa_prop: %s = %s" % [TAG, pname, str(val)])

	# 4. JavaClassWrapper availability
	print("%s DIAG_PLUGIN | ClassDB.class_exists('JavaClassWrapper')=%s" % [TAG, str(ClassDB.class_exists("JavaClassWrapper"))])
	print("%s DIAG_PLUGIN | Engine.has_singleton('JavaClassWrapper')=%s" % [TAG, str(Engine.has_singleton("JavaClassWrapper"))])

	if Engine.has_singleton("JavaClassWrapper"):
		var jcw = Engine.get_singleton("JavaClassWrapper")
		print("%s DIAG_PLUGIN | JavaClassWrapper=%s class=%s" % [TAG, str(jcw), jcw.get_class()])
		if jcw.has_method("wrap"):
			var kt = jcw.wrap("plugin.walletadapterandroid.MyComposableKt")
			print("%s DIAG_PLUGIN | MyComposableKt wrap=%s" % [TAG, str(kt)])
			if kt != null:
				for m in kt.get_method_list():
					print("%s DIAG_PLUGIN | kt_method: %s" % [TAG, m.get("name", "?")])

	print("%s DIAG_PLUGIN | ========== END DIAGNOSTICS ==========" % TAG)


func get_is_connected() -> bool:
	return _is_connected


## Clear the Java-side cached state via the SDK's clearState() method.
## We rebuilt the AAR so clearState() now clears myResult, myConnectedKey,
## authToken, myMessageSignature, myMessageSigningStatus, and myAction.
## This forces connectWallet() to open the OS picker instead of returning
## immediately from its `if (myResult is TransactionResult.Success) return` check.
func _clear_java_cached_key() -> void:
	if not Engine.has_singleton("WalletAdapterAndroid"):
		print("%s _clear_java_cached_key | SKIP WalletAdapterAndroid singleton not found" % TAG)
		return

	var plugin = Engine.get_singleton("WalletAdapterAndroid")
	var has_clear: bool = plugin.has_method("clearState")
	print("%s _clear_java_cached_key | plugin=%s has_method_clearState=%s" % [TAG, str(plugin), str(has_clear)])

	# Call clearState — with rebuilt AAR, @UsedByGodot should make it visible
	# If has_method returns false, try calling anyway (JNI may forward it)
	plugin.call("clearState")
	print("%s _clear_java_cached_key | CALLED clearState() on WalletAdapterAndroid — myResult/myConnectedKey/authToken should now be null" % TAG)


## Clear the Java-side WalletAdapterAndroid plugin's cached state.
## The Kotlin plugin (MyComposableKt) stores myConnectedKey and authToken as static fields.
## These persist for the entire app lifetime and cause connect_wallet() to auto-reconnect
## without opening the OS picker. We clear them via JavaClassWrapper so the next
## connect_wallet() call opens a fresh OS picker.
func _clear_java_plugin_state() -> void:
	print("%s _clear_java_plugin_state | START — attempting to clear Java-side cached pubkey and authToken" % TAG)

	# Approach 1: Try calling clearState on the WalletAdapterAndroid singleton directly.
	# The method exists in the bytecode but has_method returns false because it's not
	# registered with Godot's plugin system. JNI singletons sometimes forward calls anyway.
	if Engine.has_singleton("WalletAdapterAndroid"):
		var plugin = Engine.get_singleton("WalletAdapterAndroid")
		print("%s _clear_java_plugin_state | APPROACH_1 trying plugin.call('clearState') on WalletAdapterAndroid singleton" % TAG)
		print("%s _clear_java_plugin_state | APPROACH_1 plugin=%s has_method_clearState=%s" % [TAG, str(plugin), str(plugin.has_method("clearState"))])

		# Try calling it even though has_method is false — JNI may forward
		var call_succeeded := true
		plugin.call("clearState")
		print("%s _clear_java_plugin_state | APPROACH_1 call('clearState') completed (no crash = might have worked)" % TAG)

		# NOTE: Even if clearState works, it only resets myMessageSigningStatus in the
		# current bytecode — NOT myConnectedKey. So this alone won't fix the OS picker issue.
		# We need Approach 2 or an SDK modification.

	# Approach 2: Try JavaClassWrapper to call static setters on MyComposableKt
	if Engine.has_singleton("JavaClassWrapper"):
		var jcw = Engine.get_singleton("JavaClassWrapper")
		var kt = jcw.wrap("plugin.walletadapterandroid.MyComposableKt")
		print("%s _clear_java_plugin_state | APPROACH_2 MyComposableKt=%s" % [TAG, str(kt)])

		if kt != null:
			# Check if has_java_method can find the static methods (different from has_method)
			var has_java_check: bool = kt.has_method("has_java_method")
			print("%s _clear_java_plugin_state | APPROACH_2 has_java_method_available=%s" % [TAG, str(has_java_check)])

			if has_java_check:
				var found_setter: bool = kt.call("has_java_method", "setMyConnectedKey")
				var found_token: bool = kt.call("has_java_method", "setAuthToken")
				var found_getter: bool = kt.call("has_java_method", "getMyConnectedKey")
				var found_get_token: bool = kt.call("has_java_method", "getAuthToken")
				print("%s _clear_java_plugin_state | APPROACH_2 has_java_method: setMyConnectedKey=%s setAuthToken=%s getMyConnectedKey=%s getAuthToken=%s" % [TAG, str(found_setter), str(found_token), str(found_getter), str(found_get_token)])

				# If has_java_method finds them, try calling via the JavaClass
				if found_setter:
					kt.call("setMyConnectedKey", PackedByteArray())
					print("%s _clear_java_plugin_state | APPROACH_2 CALLED setMyConnectedKey(empty)" % TAG)
				if found_token:
					kt.call("setAuthToken", "")
					print("%s _clear_java_plugin_state | APPROACH_2 CALLED setAuthToken('')" % TAG)

				# Verify
				if found_getter:
					var post_key = kt.call("getMyConnectedKey")
					var post_len = post_key.size() if post_key is PackedByteArray else -1
					print("%s _clear_java_plugin_state | APPROACH_2 POST_CLEAR myConnectedKey byte_len=%d" % [TAG, post_len])
				if found_get_token:
					var post_token = kt.call("getAuthToken")
					print("%s _clear_java_plugin_state | APPROACH_2 POST_CLEAR authToken='%s'" % [TAG, str(post_token).substr(0, 20)])
			else:
				print("%s _clear_java_plugin_state | APPROACH_2 has_java_method not available on wrapped class" % TAG)

			# Approach 3: Try get_java_method_list to see ALL available Java methods
			if kt.has_method("get_java_method_list"):
				var java_methods = kt.call("get_java_method_list")
				print("%s _clear_java_plugin_state | APPROACH_3 get_java_method_list returned %d methods" % [TAG, java_methods.size() if java_methods is Array else -1])
				if java_methods is Array:
					for m in java_methods:
						if str(m).find("set") >= 0 or str(m).find("get") >= 0 or str(m).find("clear") >= 0 or str(m).find("connect") >= 0 or str(m).find("auth") >= 0:
							print("%s _clear_java_plugin_state | APPROACH_3 java_method: %s" % [TAG, str(m)])
	else:
		print("%s _clear_java_plugin_state | FAIL JavaClassWrapper not available" % TAG)

	print("%s _clear_java_plugin_state | DONE — check logs above to see which approach (if any) worked" % TAG)


## Safely get the connected key as a string WITHOUT triggering C++ Pubkey
## validation errors. Returns "" if no key is connected.
## Only calls get_connected_key() when _key_available is true (set by _on_connected signal).
func _safe_get_key_string() -> String:
	if not _key_available or wallet_adapter == null:
		return ""
	return _extract_pubkey_string(wallet_adapter.get_connected_key())


## Extract a clean base58 pubkey string from a Pubkey object.
## Pubkey objects stringify as "[Pubkey:BASE58HERE]" or "[Pubkey:]" when empty.
func _extract_pubkey_string(key_obj) -> String:
	if key_obj == null:
		return ""
	var raw := str(key_obj)
	# Handle "[Pubkey:XXXX]" format
	if raw.begins_with("[Pubkey:") and raw.ends_with("]"):
		var inner := raw.substr(8, raw.length() - 9)  # strip "[Pubkey:" and "]"
		return inner.strip_edges()
	# Handle plain string
	if raw.length() > 20 and raw.length() < 50:
		return raw  # Likely already a base58 string
	# Try to_string() method
	if key_obj is Object and key_obj.has_method("to_string"):
		var ts = key_obj.to_string()
		if ts != null and str(ts).length() > 20:
			return str(ts)
	return ""


func _truncate_pubkey(pubkey: String) -> String:
	if pubkey.length() > 8:
		return pubkey.substr(0, 4) + "..." + pubkey.substr(pubkey.length() - 4)
	return pubkey


func _wallet_type_name(wallet_type: int) -> String:
	match wallet_type:
		WALLET_PHANTOM: return "Phantom"
		WALLET_SOLFLARE: return "Solflare"
		WALLET_BACKPACK: return "Backpack"
		_: return "Seed Vault/Other"


## Force the wallet to open for re-authorization confirmation.
## Destroys the current WalletAdapter to kill the existing MWA session,
## then creates a fresh one and calls connect_wallet(). With no session,
## the wallet MUST open its authorization UI — no auto-reconnect.
## Returns true if the user approved in the wallet, false if rejected/timed out.
func _reauthorize_for_confirmation() -> bool:
	# Kill the existing MWA session so connect_wallet() actually opens the wallet
	print("%s _reauthorize_for_confirmation | destroying adapter to force fresh MWA session" % TAG)
	if wallet_adapter != null:
		var old_adapter = wallet_adapter
		wallet_adapter = null
		remove_child(old_adapter)
		old_adapter.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame

	# Create fresh adapter — no existing session
	_setup_wallet_adapter()
	if wallet_adapter == null:
		print("%s _reauthorize_for_confirmation | FAIL could not create WalletAdapter" % TAG)
		return false

	# Now connect_wallet() WILL open the wallet since there's no session
	_connection_completed = false
	_connection_succeeded = false
	_key_available = false
	wallet_adapter.connect_wallet()

	print("%s _reauthorize_for_confirmation | waiting for wallet approval (timeout=30s)" % TAG)
	var elapsed := 0.0
	while not _connection_completed and elapsed < 30.0:
		await get_tree().create_timer(0.5).timeout
		elapsed += 0.5

	if _connection_completed and _connection_succeeded:
		_is_connected = true
		connected_pubkey = _extract_pubkey_string(wallet_adapter.get_connected_key())
		print("%s _reauthorize_for_confirmation | CONFIRMED pubkey=%s elapsed=%.1fs" % [TAG, connected_pubkey, elapsed])
		return true
	else:
		print("%s _reauthorize_for_confirmation | REJECTED or TIMEOUT elapsed=%.1fs" % [TAG, elapsed])
		return false


## ─── SIGNAL HANDLERS ─────────────────────────────────────────────────────────

func _on_connected() -> void:
	_key_available = true
	var key_str = _safe_get_key_string()
	var wa_type = wallet_adapter.wallet_type if wallet_adapter != null and "wallet_type" in wallet_adapter else -1
	print("%s _on_connected | SIGNAL pubkey=%s pubkey_len=%d wallet_type=%d _waiting_for_connection=%s _waiting_for_signing=%s _connection_completed_before=%s" % [TAG, key_str, key_str.length(), wa_type, str(_waiting_for_connection), str(_waiting_for_signing), str(_connection_completed)])

	# Reject empty pubkeys — this happens when Java cached key was cleared.
	# The real connection from the OS picker will fire this signal again with a real key.
	if key_str.is_empty() or key_str.length() < 20:
		print("%s _on_connected | REJECTED empty/short pubkey (len=%d) — waiting for real connection from OS picker" % [TAG, key_str.length()])
		_key_available = false
		return

	_connection_succeeded = true
	_connection_completed = true


func _on_connection_failed() -> void:
	print("%s _on_connection_failed | SIGNAL _waiting_for_connection=%s _waiting_for_signing=%s" % [TAG, str(_waiting_for_connection), str(_waiting_for_signing)])
	_connection_succeeded = false
	_connection_completed = true


func _on_message_signed(sig: Variant) -> void:
	print("%s _on_message_signed | SIGNAL FIRED _waiting_for_signing=%s _waiting_for_connection=%s _signing_completed_before=%s sig_type=%s sig_is_null=%s" % [TAG, str(_waiting_for_signing), str(_waiting_for_connection), str(_signing_completed), str(typeof(sig)), str(sig == null)])
	_last_signature = ""
	if sig != null:
		if sig is PackedByteArray:
			_last_signature = sig.hex_encode()
			print("%s _on_message_signed | FORMAT=PackedByteArray hex=%s byte_len=%d" % [TAG, _last_signature.substr(0, 40), sig.size()])
		elif sig is Array and sig.size() > 0:
			var hex := ""
			for b in sig:
				hex += "%02x" % (int(b) & 0xFF)
			_last_signature = hex
			print("%s _on_message_signed | FORMAT=Array hex=%s array_len=%d" % [TAG, _last_signature.substr(0, 40), sig.size()])
		else:
			var sig_str := str(sig)
			if sig_str.length() > 10:
				_last_signature = sig_str
			print("%s _on_message_signed | FORMAT=other str=%s type=%s" % [TAG, sig_str.substr(0, 40), typeof(sig)])
	else:
		print("%s _on_message_signed | sig=NULL" % TAG)
	# Fallback
	if _last_signature.is_empty() and wallet_adapter and wallet_adapter.has_method("get_message_signature"):
		var fallback = wallet_adapter.get_message_signature()
		print("%s _on_message_signed | FALLBACK_ATTEMPT result=%s result_len=%d" % [TAG, str(fallback).substr(0, 40), str(fallback).length()])
		if fallback != null and str(fallback).length() > 0:
			_last_signature = str(fallback)
			print("%s _on_message_signed | FALLBACK_USED sig=%s" % [TAG, _last_signature.substr(0, 40)])
	print("%s _on_message_signed | FINAL sig_len=%d sig_empty=%s setting_signing_completed=true" % [TAG, _last_signature.length(), str(_last_signature.is_empty())])
	_signing_completed = true


func _on_signing_failed(error_info: Variant = null) -> void:
	print("%s _on_signing_failed | SIGNAL error=%s type=%s _waiting_for_signing=%s _waiting_for_connection=%s" % [TAG, str(error_info), str(typeof(error_info)), str(_waiting_for_signing), str(_waiting_for_connection)])
	_signing_completed = true
	_last_signature = ""
	status_updated.emit("Signing failed")
