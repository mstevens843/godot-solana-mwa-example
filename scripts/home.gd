extends Control

## Home page — shows connected wallet pubkey and buttons for all MWA methods.

const TAG := "[Home]"

@onready var pubkey_label: Label = $VBoxContainer/PubkeyLabel
@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var sign_msg_button: Button = $VBoxContainer/ButtonGrid/SignMessageButton
@onready var sign_tx_button: Button = $VBoxContainer/ButtonGrid/SignTxButton
@onready var sign_send_button: Button = $VBoxContainer/ButtonGrid/SignSendButton
@onready var capabilities_button: Button = $VBoxContainer/ButtonGrid/CapabilitiesButton
@onready var disconnect_button: Button = $VBoxContainer/DisconnectButton
@onready var delete_button: Button = $VBoxContainer/DeleteButton


func _ready() -> void:
	print("%s _ready | START" % TAG)

	# Display connected pubkey and wallet type
	var pubkey := MWAManager.connected_pubkey
	var wallet_name := MWAManager._wallet_type_name(MWAManager.connected_wallet_type)
	print("%s _ready | connected_pubkey=%s is_connected=%s wallet=%s (type=%d)" % [TAG, pubkey, str(MWAManager.get_is_connected()), wallet_name, MWAManager.connected_wallet_type])
	if pubkey.length() > 8:
		var short_key := pubkey.substr(0, 4) + "..." + pubkey.substr(pubkey.length() - 4)
		if not wallet_name.is_empty():
			pubkey_label.text = short_key + " (" + wallet_name + ")"
		else:
			pubkey_label.text = short_key
	else:
		pubkey_label.text = pubkey if not pubkey.is_empty() else "Not connected"

	# Connect button handlers
	sign_msg_button.pressed.connect(_on_sign_message)
	sign_tx_button.pressed.connect(_on_sign_transaction)
	sign_send_button.pressed.connect(_on_sign_and_send)
	capabilities_button.pressed.connect(_on_get_capabilities)
	disconnect_button.pressed.connect(_on_disconnect)
	delete_button.pressed.connect(_on_delete_account)

	# Listen for status updates
	MWAManager.status_updated.connect(_on_status_updated)
	MWAManager.disconnected.connect(_on_disconnected)

	status_label.text = "Connected — choose an action"
	print("%s _ready | DONE buttons wired, signals connected" % TAG)


func _on_sign_message() -> void:
	print("%s _on_sign_message | START" % TAG)
	_disable_buttons()
	var sig := await MWAManager.sign_message("Hello from MWA Example App!")
	if sig.is_empty():
		print("%s _on_sign_message | FAIL empty signature" % TAG)
		status_label.text = "Sign message failed"
	else:
		print("%s _on_sign_message | SUCCESS sig=%s" % [TAG, sig.substr(0, 20)])
		status_label.text = "Signed: " + sig.substr(0, 20) + "..."
	_enable_buttons()
	print("%s _on_sign_message | DONE" % TAG)


func _on_sign_transaction() -> void:
	print("%s _on_sign_transaction | START connected_pubkey=%s is_connected=%s wallet_type=%d" % [TAG, MWAManager.connected_pubkey, str(MWAManager.get_is_connected()), MWAManager.connected_wallet_type])
	_disable_buttons()
	status_label.text = "Building transaction..."

	# Build a minimal 0-lamport SOL transfer to self (harmless demo tx)
	var pubkey_str := MWAManager.connected_pubkey
	print("%s _on_sign_transaction | creating Pubkey from '%s' (len=%d)" % [TAG, pubkey_str, pubkey_str.length()])
	var payer = Pubkey.new_from_string(pubkey_str)
	print("%s _on_sign_transaction | payer=%s payer_type=%s" % [TAG, str(payer), str(typeof(payer))])

	var ix = SystemProgram.transfer(payer, payer, 0)
	print("%s _on_sign_transaction | instruction created ix=%s ix_type=%s" % [TAG, str(ix), str(typeof(ix))])

	var tx := Transaction.new()
	add_child(tx)
	tx.set_payer(payer)
	tx.add_instruction(ix)
	tx.url_override = AppConfig.get_rpc_url()
	print("%s _on_sign_transaction | transaction built, payer set, instruction added, url_override=%s" % [TAG, tx.url_override])

	# Fetch recent blockhash from RPC
	print("%s _on_sign_transaction | fetching blockhash via tx.update_latest_blockhash()" % TAG)
	status_label.text = "Fetching blockhash..."
	tx.update_latest_blockhash()
	var bh_result: Dictionary = await tx.blockhash_updated
	print("%s _on_sign_transaction | blockhash_updated signal received result_keys=%s has_result=%s" % [TAG, str(bh_result.keys()), str(bh_result.has("result"))])
	if bh_result.has("result"):
		print("%s _on_sign_transaction | blockhash=%s" % [TAG, str(bh_result["result"]).substr(0, 80)])
	else:
		print("%s _on_sign_transaction | blockhash_error=%s" % [TAG, str(bh_result).substr(0, 120)])

	if not bh_result.has("result"):
		print("%s _on_sign_transaction | FAIL no blockhash in result — cannot build valid transaction" % TAG)
		status_label.text = "Failed to fetch blockhash"
		tx.queue_free()
		_enable_buttons()
		return

	# Serialize and sign via MWA
	var tx_bytes := tx.serialize()
	print("%s _on_sign_transaction | serialized tx_bytes_size=%d tx_bytes_hex=%s" % [TAG, tx_bytes.size(), tx_bytes.hex_encode().substr(0, 40)])
	status_label.text = "Approve in wallet..."

	print("%s _on_sign_transaction | calling MWAManager.sign_transaction()" % TAG)
	var sig := await MWAManager.sign_transaction(tx_bytes)
	tx.queue_free()

	print("%s _on_sign_transaction | RESULT sig_empty=%s sig_len=%d sig=%s" % [TAG, str(sig.is_empty()), sig.length(), sig.substr(0, 40)])
	if sig.is_empty():
		print("%s _on_sign_transaction | FAIL empty signature returned from MWA" % TAG)
		status_label.text = "Sign transaction failed"
	else:
		print("%s _on_sign_transaction | SUCCESS sig=%s" % [TAG, sig.substr(0, 40)])
		status_label.text = "Signed: " + sig.substr(0, 20) + "..."
	_enable_buttons()
	print("%s _on_sign_transaction | DONE" % TAG)


func _on_sign_and_send() -> void:
	print("%s _on_sign_and_send | START connected_pubkey=%s is_connected=%s wallet_type=%d" % [TAG, MWAManager.connected_pubkey, str(MWAManager.get_is_connected()), MWAManager.connected_wallet_type])
	_disable_buttons()
	status_label.text = "Building transaction..."

	# Build a minimal 0-lamport SOL transfer to self (harmless demo tx)
	var pubkey_str := MWAManager.connected_pubkey
	print("%s _on_sign_and_send | creating Pubkey from '%s' (len=%d)" % [TAG, pubkey_str, pubkey_str.length()])
	var payer = Pubkey.new_from_string(pubkey_str)
	print("%s _on_sign_and_send | payer=%s payer_type=%s" % [TAG, str(payer), str(typeof(payer))])

	var ix = SystemProgram.transfer(payer, payer, 0)
	print("%s _on_sign_and_send | instruction created ix=%s ix_type=%s" % [TAG, str(ix), str(typeof(ix))])

	var tx := Transaction.new()
	add_child(tx)
	tx.set_payer(payer)
	tx.add_instruction(ix)
	tx.url_override = AppConfig.get_rpc_url()
	print("%s _on_sign_and_send | transaction built, payer set, instruction added, url_override=%s" % [TAG, tx.url_override])

	# Fetch recent blockhash from RPC
	print("%s _on_sign_and_send | fetching blockhash via tx.update_latest_blockhash()" % TAG)
	status_label.text = "Fetching blockhash..."
	tx.update_latest_blockhash()
	var bh_result: Dictionary = await tx.blockhash_updated
	print("%s _on_sign_and_send | blockhash_updated signal received result_keys=%s has_result=%s" % [TAG, str(bh_result.keys()), str(bh_result.has("result"))])
	if bh_result.has("result"):
		var result_data = bh_result["result"]
		print("%s _on_sign_and_send | blockhash_result=%s" % [TAG, str(result_data).substr(0, 200)])
		if result_data is Dictionary and result_data.has("value") and result_data["value"] is Dictionary:
			var bh_val = result_data["value"]
			print("%s _on_sign_and_send | BLOCKHASH=%s lastValidBlockHeight=%s" % [TAG, str(bh_val.get("blockhash", "MISSING")), str(bh_val.get("lastValidBlockHeight", "MISSING"))])
	else:
		print("%s _on_sign_and_send | blockhash_error=%s" % [TAG, str(bh_result).substr(0, 200)])

	if not bh_result.has("result"):
		print("%s _on_sign_and_send | FAIL no blockhash in result — cannot build valid transaction" % TAG)
		status_label.text = "Failed to fetch blockhash"
		tx.queue_free()
		_enable_buttons()
		return

	# Serialize, sign via MWA, then submit to network
	var tx_bytes := tx.serialize()
	print("%s _on_sign_and_send | serialized tx_bytes_size=%d tx_bytes_hex=%s" % [TAG, tx_bytes.size(), tx_bytes.hex_encode().substr(0, 80)])
	if tx_bytes.size() < 100 or tx_bytes.size() > 1500:
		print("%s _on_sign_and_send | WARNING unusual tx_bytes_size=%d (expected 100-1500)" % [TAG, tx_bytes.size()])
	status_label.text = "Approve in wallet..."

	print("%s _on_sign_and_send | calling MWAManager.sign_and_send_transactions() with 1 tx" % TAG)
	var sigs := await MWAManager.sign_and_send_transactions([tx_bytes])
	tx.queue_free()

	print("%s _on_sign_and_send | RESULT sigs_count=%d sigs=%s" % [TAG, sigs.size(), str(sigs).substr(0, 80)])
	if sigs.is_empty():
		print("%s _on_sign_and_send | FAIL no signatures returned from MWA" % TAG)
		status_label.text = "Sign & send failed"
	else:
		print("%s _on_sign_and_send | SUCCESS first_sig=%s" % [TAG, str(sigs[0]).substr(0, 40)])
		status_label.text = "Sent! Sig: " + str(sigs[0]).substr(0, 20) + "..."
	_enable_buttons()
	print("%s _on_sign_and_send | DONE" % TAG)


func _on_get_capabilities() -> void:
	print("%s _on_get_capabilities | START" % TAG)
	_disable_buttons()
	var caps := await MWAManager.get_capabilities()
	if caps.is_empty():
		print("%s _on_get_capabilities | FAIL empty result" % TAG)
		status_label.text = "Failed to get capabilities"
	else:
		print("%s _on_get_capabilities | SUCCESS keys=%s" % [TAG, str(caps.keys())])
		status_label.text = "Capabilities:\n"
		for key in caps:
			status_label.text += "  %s: %s\n" % [key, str(caps[key])]
	_enable_buttons()
	print("%s _on_get_capabilities | DONE" % TAG)


func _on_disconnect() -> void:
	print("%s _on_disconnect | START" % TAG)
	await MWAManager.deauthorize()
	print("%s _on_disconnect | DONE" % TAG)


func _on_delete_account() -> void:
	print("%s _on_delete_account | START" % TAG)
	await MWAManager.delete_account()
	print("%s _on_delete_account | DONE" % TAG)


func _on_disconnected() -> void:
	print("%s _on_disconnected | SIGNAL RECEIVED — changing to Main scene" % TAG)
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _on_status_updated(message: String) -> void:
	print("%s _on_status_updated | %s" % [TAG, message])
	status_label.text = message


func _disable_buttons() -> void:
	print("%s _disable_buttons | disabling all" % TAG)
	for button in [sign_msg_button, sign_tx_button, sign_send_button,
			capabilities_button, disconnect_button, delete_button]:
		button.disabled = true


func _enable_buttons() -> void:
	print("%s _enable_buttons | enabling all" % TAG)
	for button in [sign_msg_button, sign_tx_button, sign_send_button,
			capabilities_button, disconnect_button, delete_button]:
		button.disabled = false
