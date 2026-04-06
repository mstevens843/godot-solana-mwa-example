extends Node

## App identity sent to wallets during MWA authorization.
## Change these values for your own app.

const APP_NAME := "MWA Example App"
const APP_URI := "https://example.com"
const APP_ICON_PATH := "/icon.png"
const CLUSTER := "devnet"  # "devnet", "testnet", or "mainnet-beta"


func _ready() -> void:
	print("[AppConfig] _ready | START")
	print("[AppConfig] _ready | app_name=%s app_uri=%s cluster=%s icon=%s" % [APP_NAME, APP_URI, CLUSTER, APP_ICON_PATH])
	print("[AppConfig] _ready | DONE")
