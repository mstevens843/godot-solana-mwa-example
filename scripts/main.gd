extends Control

## Landing page — "Connect Wallet" button.
## On successful authorization, switches to the Home scene.

const TAG := "[Main]"

@onready var connect_button: Button = $VBoxContainer/ConnectButton
@onready var reconnect_button: Button = $VBoxContainer/ReconnectButton
@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var title_label: Label = $VBoxContainer/TitleLabel


func _ready() -> void:
	print("%s _ready | START" % TAG)

	connect_button.pressed.connect(_on_connect_pressed)
	reconnect_button.pressed.connect(_on_reconnect_pressed)
	MWAManager.status_updated.connect(_on_status_updated)
	MWAManager.authorized.connect(_on_authorized)
	MWAManager.authorization_failed.connect(_on_auth_failed)
	print("%s _ready | signals connected" % TAG)

	status_label.text = "Tap Connect to link your wallet"

	# Show reconnect button if we have a cached auth
	var cached = MWAManager.cache.get_latest_auth()
	var has_cached := cached != null
	reconnect_button.visible = has_cached
	print("%s _ready | DONE cached_auth=%s reconnect_visible=%s" % [TAG, str(has_cached), str(has_cached)])


func _on_connect_pressed() -> void:
	print("%s _on_connect_pressed | START" % TAG)
	connect_button.disabled = true
	reconnect_button.disabled = true
	status_label.text = "Opening wallet..."
	print("%s _on_connect_pressed | calling MWAManager.authorize()" % TAG)
	var success := await MWAManager.authorize()
	print("%s _on_connect_pressed | DONE success=%s" % [TAG, str(success)])
	connect_button.disabled = false
	reconnect_button.disabled = false


func _on_reconnect_pressed() -> void:
	print("%s _on_reconnect_pressed | START" % TAG)
	connect_button.disabled = true
	reconnect_button.disabled = true
	status_label.text = "Reconnecting..."
	print("%s _on_reconnect_pressed | calling MWAManager.reauthorize()" % TAG)
	var success := await MWAManager.reauthorize()
	print("%s _on_reconnect_pressed | DONE success=%s" % [TAG, str(success)])
	connect_button.disabled = false
	reconnect_button.disabled = false


func _on_authorized(pubkey: String) -> void:
	print("%s _on_authorized | pubkey=%s changing to Home scene" % [TAG, pubkey])
	status_label.text = "Connected! Loading..."
	get_tree().change_scene_to_file("res://scenes/Home.tscn")


func _on_auth_failed(error: String) -> void:
	print("%s _on_auth_failed | error=%s" % [TAG, error])
	status_label.text = "Failed: " + error


func _on_status_updated(message: String) -> void:
	print("%s _on_status_updated | message=%s" % [TAG, message])
	status_label.text = message
