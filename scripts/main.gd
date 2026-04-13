extends Control

## Landing page — Connect Wallet or wallet picker buttons.
## Flag-controlled: USE_OS_PICKER = true → single button, OS picker.
## USE_OS_PICKER = false → in-app wallet buttons, stores wallet type.

const TAG := "[Main]"
const WALLET_JUPITER := 40

@onready var connect_button: Button = $VBoxContainer/ConnectButton
@onready var seed_vault_button: Button = $VBoxContainer/SeedVaultButton
@onready var phantom_button: Button = $VBoxContainer/PhantomButton
@onready var solflare_button: Button = $VBoxContainer/SolflareButton
@onready var jupiter_button: Button = $VBoxContainer/JupiterButton
@onready var backpack_button: Button = $VBoxContainer/BackpackButton
@onready var reconnect_button: Button = $VBoxContainer/ReconnectButton
@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var subtitle_label: Label = $VBoxContainer/SubtitleLabel


func _ready() -> void:
	print("%s _ready | START" % TAG)

	# Wire signals
	connect_button.pressed.connect(_on_connect_pressed)
	seed_vault_button.pressed.connect(_on_wallet_pressed.bind(-1))
	phantom_button.pressed.connect(_on_wallet_pressed.bind(MWAManager.WALLET_PHANTOM))
	solflare_button.pressed.connect(_on_wallet_pressed.bind(MWAManager.WALLET_SOLFLARE))
	jupiter_button.pressed.connect(_on_wallet_pressed.bind(WALLET_JUPITER))
	backpack_button.pressed.connect(_on_wallet_pressed.bind(MWAManager.WALLET_BACKPACK))
	reconnect_button.pressed.connect(_on_reconnect_pressed)
	MWAManager.status_updated.connect(_on_status_updated)
	MWAManager.authorized.connect(_on_authorized)
	MWAManager.authorization_failed.connect(_on_auth_failed)
	print("%s _ready | signals connected" % TAG)

	# Toggle UI based on flag
	if AppConfig.USE_OS_PICKER:
		connect_button.visible = true
		seed_vault_button.visible = false
		phantom_button.visible = false
		solflare_button.visible = false
		jupiter_button.visible = false
		backpack_button.visible = false
		subtitle_label.text = "Solana Mobile Wallet Adapter Demo"
		status_label.text = "Tap Connect to link your wallet"
	else:
		connect_button.visible = false
		seed_vault_button.visible = true
		phantom_button.visible = true
		solflare_button.visible = true
		jupiter_button.visible = true
		backpack_button.visible = true
		subtitle_label.text = "Choose your wallet"
		status_label.text = "Select a wallet to connect"

	# Show reconnect button if we have a cached auth
	var cached = MWAManager.cache.get_latest_auth()
	var has_cached := cached != null
	reconnect_button.visible = has_cached
	if has_cached:
		AndroidToastHelper.show("Cached session found: %s..." % str(cached.get("pubkey", "")).substr(0, 8))
	print("%s _ready | DONE use_os_picker=%s cached_auth=%s reconnect_visible=%s" % [TAG, str(AppConfig.USE_OS_PICKER), str(has_cached), str(has_cached)])


# OS picker mode — single button
func _on_connect_pressed() -> void:
	print("%s _on_connect_pressed | START" % TAG)
	_disable_all()
	status_label.text = "Opening wallet..."
	var success := await MWAManager.authorize()
	print("%s _on_connect_pressed | DONE success=%s" % [TAG, str(success)])
	_enable_all()


# In-app picker mode — wallet-specific button
func _on_wallet_pressed(wallet_type_id: int) -> void:
	print("%s _on_wallet_pressed | START wallet_type=%d (%s)" % [TAG, wallet_type_id, MWAManager._wallet_type_name(wallet_type_id)])
	_disable_all()
	status_label.text = "Connecting to %s..." % MWAManager._wallet_type_name(wallet_type_id)
	var success := await MWAManager.authorize(wallet_type_id)
	print("%s _on_wallet_pressed | DONE success=%s" % [TAG, str(success)])
	_enable_all()


func _on_reconnect_pressed() -> void:
	print("%s _on_reconnect_pressed | START" % TAG)
	_disable_all()
	status_label.text = "Reconnecting..."
	var success := await MWAManager.reauthorize()
	print("%s _on_reconnect_pressed | DONE success=%s" % [TAG, str(success)])
	_enable_all()


func _on_authorized(pubkey: String) -> void:
	print("%s _on_authorized | pubkey=%s wallet_type=%d changing to Home scene" % [TAG, pubkey, MWAManager.connected_wallet_type])
	status_label.text = "Connected! Loading..."
	get_tree().change_scene_to_file("res://scenes/Home.tscn")


func _on_auth_failed(error: String) -> void:
	print("%s _on_auth_failed | error=%s" % [TAG, error])
	status_label.text = "Failed: " + error


func _on_status_updated(message: String) -> void:
	print("%s _on_status_updated | message=%s" % [TAG, message])
	status_label.text = message


func _disable_all() -> void:
	for btn in [connect_button, seed_vault_button, phantom_button, solflare_button, jupiter_button, backpack_button, reconnect_button]:
		btn.disabled = true


func _enable_all() -> void:
	for btn in [connect_button, seed_vault_button, phantom_button, solflare_button, jupiter_button, backpack_button, reconnect_button]:
		btn.disabled = false
