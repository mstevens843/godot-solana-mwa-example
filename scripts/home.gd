extends Control

## Home page — shows connected wallet pubkey and buttons for all MWA methods.

const TAG := "[Home]"

@onready var pubkey_label: Label = $VBoxContainer/PubkeyLabel
@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var sign_msg_button: Button = $VBoxContainer/ButtonGrid/SignMessageButton
@onready var sign_tx_button: Button = $VBoxContainer/ButtonGrid/SignTxButton
@onready var sign_send_button: Button = $VBoxContainer/ButtonGrid/SignSendButton
@onready var capabilities_button: Button = $VBoxContainer/ButtonGrid/CapabilitiesButton
@onready var reconnect_button: Button = $VBoxContainer/ButtonGrid/ReconnectButton
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
	reconnect_button.pressed.connect(_on_reconnect)
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
	print("%s _on_sign_transaction | START" % TAG)
	_disable_buttons()
	# TODO: Build a real memo transaction with the SDK
	# var tx := TransactionBuilder.new().add_memo("MWA test").build()
	# var sig := await MWAManager.sign_transaction(tx.serialize())
	print("%s _on_sign_transaction | PLACEHOLDER — needs real serialized tx from SDK" % TAG)
	status_label.text = "Sign Transaction: requires a real serialized tx.\nBuild a memo tx with the SDK's TransactionBuilder."
	_enable_buttons()
	print("%s _on_sign_transaction | DONE" % TAG)


func _on_sign_and_send() -> void:
	print("%s _on_sign_and_send | START" % TAG)
	_disable_buttons()
	# TODO: Build real transactions with the SDK
	print("%s _on_sign_and_send | PLACEHOLDER — needs real transactions from SDK" % TAG)
	status_label.text = "Sign & Send: requires real transactions.\nBuild transactions with the SDK."
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


func _on_reconnect() -> void:
	print("%s _on_reconnect | START" % TAG)
	_disable_buttons()
	var success := await MWAManager.reauthorize()
	print("%s _on_reconnect | DONE success=%s" % [TAG, str(success)])
	if success:
		status_label.text = "Reconnected successfully"
	else:
		status_label.text = "Reconnect failed"
	_enable_buttons()


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
			capabilities_button, reconnect_button, disconnect_button, delete_button]:
		button.disabled = true


func _enable_buttons() -> void:
	print("%s _enable_buttons | enabling all" % TAG)
	for button in [sign_msg_button, sign_tx_button, sign_send_button,
			capabilities_button, reconnect_button, disconnect_button, delete_button]:
		button.disabled = false
