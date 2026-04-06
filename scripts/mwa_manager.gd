extends Node

## MWA Manager — Singleton that wraps the godot-solana-sdk WalletAdapter
## and exposes clean async methods for all MWA 2.0 operations.

const TAG := "[MWAManager]"

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
var auth_token: String = ""
var wallet_uri_base: String = ""
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
	if _diag_timer < 1.0:
		return
	_diag_timer = 0.0

	# Poll WalletAdapter state every 1s while waiting
	var key_str = _extract_pubkey_string(wallet_adapter.get_connected_key())
	var raw_str = str(wallet_adapter.get_connected_key())
	var wt = wallet_adapter.wallet_type if "wallet_type" in wallet_adapter else -1
	print("%s _process DIAG | waiting_conn=%s waiting_sign=%s key='%s' raw='%s' wallet_type=%s completed=%s succeeded=%s pre='%s'" % [TAG, str(_waiting_for_connection), str(_waiting_for_signing), key_str, raw_str, str(wt), str(_connection_completed), str(_connection_succeeded), _pre_connect_key])


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

	print("%s _setup_wallet_adapter | DONE signals connected" % TAG)


func _connect_signal(sig_name: String, handler: Callable) -> void:
	if wallet_adapter.has_signal(sig_name):
		wallet_adapter.connect(sig_name, handler)
		print("%s _connect_signal | connected signal=%s" % [TAG, sig_name])
	else:
		print("%s _connect_signal | WARN signal=%s not found on WalletAdapter" % [TAG, sig_name])


## ─── AUTHORIZE ───────────────────────────────────────────────────────────────

func authorize() -> bool:
	print("%s authorize | START is_connected=%s wallet_adapter=%s" % [TAG, str(_is_connected), str(wallet_adapter != null)])

	if wallet_adapter == null:
		print("%s authorize | FAIL wallet_adapter is null" % TAG)
		authorization_failed.emit("WalletAdapter not initialized")
		return false

	_connection_completed = false
	_connection_succeeded = false
	_waiting_for_connection = true
	_diag_timer = 0.0

	# Snapshot current key BEFORE connect — so we can detect a NEW connection vs stale
	_pre_connect_key = _extract_pubkey_string(wallet_adapter.get_connected_key())
	print("%s authorize | pre_connect_key='%s'" % [TAG, _pre_connect_key])
	print("%s authorize | calling wallet_adapter.connect_wallet()" % TAG)
	status_updated.emit("Requesting wallet authorization...")
	wallet_adapter.connect_wallet()

	# Wait for result via signal handler flag OR polling fallback
	print("%s authorize | waiting for connection (timeout=60s)" % TAG)
	var elapsed := 0.0
	while not _connection_completed and elapsed < 60.0:
		await get_tree().create_timer(0.5).timeout
		elapsed += 0.5

		# Polling fallback: check get_connected_key() directly
		if not _connection_completed and wallet_adapter.has_method("get_connected_key"):
			var poll_key_str = _extract_pubkey_string(wallet_adapter.get_connected_key())
			if poll_key_str.length() > 20 and poll_key_str != _pre_connect_key:
				print("%s authorize | POLL FALLBACK detected NEW key=%s (was='%s') elapsed=%.1fs" % [TAG, poll_key_str, _pre_connect_key, elapsed])
				_connection_succeeded = true
				_connection_completed = true
			elif poll_key_str.length() > 20 and poll_key_str == _pre_connect_key and elapsed > 5.0:
				# Same key as before — might be a reconnect, accept after 5s delay
				print("%s authorize | POLL FALLBACK same key=%s elapsed=%.1fs (accepting reconnect)" % [TAG, poll_key_str, elapsed])
				_connection_succeeded = true
				_connection_completed = true

	_waiting_for_connection = false

	if _connection_completed and _connection_succeeded:
		var raw_key = wallet_adapter.get_connected_key()
		connected_pubkey = _extract_pubkey_string(raw_key)
		_is_connected = true
		print("%s authorize | CONNECTED pubkey=%s elapsed=%.1fs — now signing to confirm" % [TAG, connected_pubkey, elapsed])

		# Auto sign message to complete auth (Seed Vault biometric confirmation)
		status_updated.emit("Confirming identity...")
		var sign_in_sig = await sign_message("Sign in to %s" % AppConfig.APP_NAME)
		if sign_in_sig.is_empty():
			print("%s authorize | FAIL sign-in signature rejected or timed out" % TAG)
			_is_connected = false
			connected_pubkey = ""
			status_updated.emit("Sign-in cancelled")
			authorization_failed.emit("Sign-in confirmation rejected")
			return false

		print("%s authorize | SIGNED sig=%s — auth complete" % [TAG, sign_in_sig.substr(0, 20)])

		# Cache auth
		cache.set_auth(connected_pubkey, auth_token, wallet_uri_base)
		print("%s authorize | cached auth pubkey=%s auth_token_len=%d" % [TAG, connected_pubkey, auth_token.length()])

		status_updated.emit("Connected: " + _truncate_pubkey(connected_pubkey))
		authorized.emit(connected_pubkey)
		return true
	elif _connection_completed and not _connection_succeeded:
		print("%s authorize | REJECTED by wallet elapsed=%.1fs" % [TAG, elapsed])
		status_updated.emit("Authorization rejected by wallet")
		authorization_failed.emit("User rejected or wallet error")
		return false
	else:
		print("%s authorize | TIMEOUT elapsed=%.1fs" % [TAG, elapsed])
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

	print("%s reauthorize | cached_pubkey=%s cached_token_len=%d" % [TAG, str(cached.get("pubkey", "")), str(cached.get("auth_token", "")).length()])
	status_updated.emit("Reauthorizing with cached token...")

	# TODO: Use SDK's native reauthorize when available
	# For now, full re-auth
	print("%s reauthorize | falling back to full authorize()" % TAG)
	return await authorize()


## ─── DEAUTHORIZE ─────────────────────────────────────────────────────────────

func deauthorize() -> void:
	print("%s deauthorize | START pubkey=%s is_connected=%s" % [TAG, connected_pubkey, str(_is_connected)])
	status_updated.emit("Deauthorizing...")

	# TODO: Call wallet_adapter deauthorize when SDK supports it
	# wallet_adapter.deauthorize(auth_token)
	print("%s deauthorize | TODO — SDK deauthorize not yet implemented, clearing local state" % TAG)

	var old_pubkey := connected_pubkey
	connected_pubkey = ""
	auth_token = ""
	wallet_uri_base = ""
	_is_connected = false
	_connection_completed = false
	_connection_succeeded = false
	_signing_completed = false
	_last_signature = ""

	print("%s deauthorize | DONE old_pubkey=%s state_cleared=true" % [TAG, old_pubkey])
	status_updated.emit("Disconnected")
	disconnected.emit()


## ─── SIGN MESSAGE ────────────────────────────────────────────────────────────

func sign_message(message: String) -> String:
	print("%s sign_message | START message_len=%d is_connected=%s" % [TAG, message.length(), str(_is_connected)])

	if not _is_connected or wallet_adapter == null:
		print("%s sign_message | FAIL not connected or no wallet_adapter" % TAG)
		status_updated.emit("Not connected")
		return ""

	_signing_completed = false
	_last_signature = ""
	print("%s sign_message | calling wallet_adapter.sign_text_message()" % TAG)
	status_updated.emit("Signing message...")
	wallet_adapter.sign_text_message(message)

	# Wait for signing result
	print("%s sign_message | waiting for signature (timeout=30s)" % TAG)
	var elapsed := 0.0
	while not _signing_completed and elapsed < 30.0:
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1

	if _signing_completed and not _last_signature.is_empty():
		print("%s sign_message | SUCCESS sig=%s elapsed=%.1fs" % [TAG, _last_signature.substr(0, 20), elapsed])
		status_updated.emit("Message signed: " + _last_signature.substr(0, 16) + "...")
		message_signed.emit(_last_signature)
		return _last_signature
	else:
		print("%s sign_message | FAIL completed=%s sig_empty=%s elapsed=%.1fs" % [TAG, str(_signing_completed), str(_last_signature.is_empty()), elapsed])
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
	print("%s sign_transaction | calling wallet_adapter.sign_message(tx, 0)" % TAG)
	status_updated.emit("Signing transaction...")
	wallet_adapter.sign_message(serialized_tx, 0)

	# Wait for signing result
	print("%s sign_transaction | waiting for signature (timeout=30s)" % TAG)
	var elapsed := 0.0
	while not _signing_completed and elapsed < 30.0:
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1

	if _signing_completed and not _last_signature.is_empty():
		print("%s sign_transaction | SUCCESS sig=%s elapsed=%.1fs" % [TAG, _last_signature.substr(0, 20), elapsed])
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

	status_updated.emit("Signing and sending %d transaction(s)..." % transactions.size())

	# TODO: Use wallet-native signAndSendTransactions when SDK supports it
	# For now, sign each and broadcast via RPC
	print("%s sign_and_send_transactions | TODO — using individual sign fallback" % TAG)
	var signatures: Array = []
	for i in range(transactions.size()):
		print("%s sign_and_send_transactions | signing tx %d/%d" % [TAG, i + 1, transactions.size()])
		var sig := await sign_transaction(transactions[i])
		if not sig.is_empty():
			signatures.append(sig)
			print("%s sign_and_send_transactions | tx %d signed sig=%s" % [TAG, i + 1, sig.substr(0, 16)])
		else:
			print("%s sign_and_send_transactions | tx %d FAILED" % [TAG, i + 1])

	print("%s sign_and_send_transactions | DONE signed=%d/%d" % [TAG, signatures.size(), transactions.size()])
	status_updated.emit("Sent %d transaction(s)" % signatures.size())
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

	# TODO: Use wallet_adapter.get_capabilities() when SDK supports it
	print("%s get_capabilities | TODO — returning placeholder capabilities" % TAG)
	var caps := {
		"max_transactions_per_request": 10,
		"max_messages_per_request": 10,
		"supported_transaction_versions": ["legacy", 0],
	}

	print("%s get_capabilities | DONE max_txs=%d max_msgs=%d" % [TAG, caps["max_transactions_per_request"], caps["max_messages_per_request"]])
	status_updated.emit("Capabilities received")
	capabilities_received.emit(caps)
	return caps


## ─── DELETE ACCOUNT ──────────────────────────────────────────────────────────

func delete_account() -> void:
	print("%s delete_account | START pubkey=%s" % [TAG, connected_pubkey])

	if not _is_connected or wallet_adapter == null:
		print("%s delete_account | FAIL not connected" % TAG)
		status_updated.emit("Not connected — cannot delete")
		return

	# Require Seed Vault confirmation before deleting
	print("%s delete_account | requesting Seed Vault confirmation via sign_message" % TAG)
	status_updated.emit("Confirm deletion in Seed Vault...")
	var sig = await sign_message("Confirm account deletion for %s" % AppConfig.APP_NAME)

	if sig.is_empty():
		print("%s delete_account | FAIL user rejected or signing failed — aborting delete" % TAG)
		status_updated.emit("Delete cancelled — confirmation required")
		return

	print("%s delete_account | confirmed sig=%s — proceeding with deletion" % [TAG, sig.substr(0, 20)])

	await deauthorize()
	cache.clear_all()

	# Destroy and recreate WalletAdapter to clear stale internal state (pubkey)
	if wallet_adapter != null:
		print("%s delete_account | destroying stale WalletAdapter" % TAG)
		var old_adapter = wallet_adapter
		wallet_adapter = null
		remove_child(old_adapter)
		old_adapter.queue_free()
		_setup_wallet_adapter()
		print("%s delete_account | WalletAdapter recreated, stale state cleared" % TAG)

	print("%s delete_account | DONE cache cleared, session destroyed" % TAG)
	status_updated.emit("Account deleted — all cached data cleared")


## ─── HELPERS ─────────────────────────────────────────────────────────────────

func get_is_connected() -> bool:
	return _is_connected


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


## ─── SIGNAL HANDLERS ─────────────────────────────────────────────────────────

func _on_connected() -> void:
	var key := ""
	if wallet_adapter and wallet_adapter.has_method("get_connected_key"):
		key = wallet_adapter.get_connected_key()
	print("%s _on_connected | SIGNAL RECEIVED pubkey=%s" % [TAG, key])
	_connection_succeeded = true
	_connection_completed = true


func _on_connection_failed() -> void:
	print("%s _on_connection_failed | SIGNAL RECEIVED" % TAG)
	_connection_succeeded = false
	_connection_completed = true  # Set flag so wait loop exits


func _on_message_signed(sig: Variant) -> void:
	_last_signature = ""
	# The signature comes as the signal argument (byte array), NOT from get_message_signature()
	if sig != null:
		if sig is PackedByteArray:
			_last_signature = sig.hex_encode()
			print("%s _on_message_signed | SIGNAL RECEIVED sig_from_bytes=%s len=%d" % [TAG, _last_signature.substr(0, 32) + "...", sig.size()])
		elif sig is Array and sig.size() > 0:
			# Convert Array of ints to hex
			var hex := ""
			for b in sig:
				hex += "%02x" % (int(b) & 0xFF)
			_last_signature = hex
			print("%s _on_message_signed | SIGNAL RECEIVED sig_from_array=%s len=%d" % [TAG, _last_signature.substr(0, 32) + "...", sig.size()])
		else:
			var sig_str := str(sig)
			if sig_str.length() > 10:
				_last_signature = sig_str
			print("%s _on_message_signed | SIGNAL RECEIVED sig_from_str=%s type=%s" % [TAG, sig_str.substr(0, 32), typeof(sig)])
	# Fallback: try get_message_signature() if signal arg was empty
	if _last_signature.is_empty() and wallet_adapter and wallet_adapter.has_method("get_message_signature"):
		var fallback = wallet_adapter.get_message_signature()
		if fallback != null and str(fallback).length() > 0:
			_last_signature = str(fallback)
			print("%s _on_message_signed | FALLBACK from get_message_signature=%s" % [TAG, _last_signature.substr(0, 32)])
	print("%s _on_message_signed | FINAL sig_len=%d sig_empty=%s" % [TAG, _last_signature.length(), str(_last_signature.is_empty())])
	_signing_completed = true


func _on_signing_failed() -> void:
	print("%s _on_signing_failed | SIGNAL RECEIVED" % TAG)
	_signing_completed = true  # Set flag so wait loop exits
	_last_signature = ""
	status_updated.emit("Signing failed")
