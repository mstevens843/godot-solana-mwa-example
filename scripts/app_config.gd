extends Node

## App identity sent to wallets during MWA authorization.
## Change these values for your own app.

const APP_NAME := "MWA Example App"
const APP_URI := "https://example.com"
const APP_ICON_PATH := "/icon.png"
const CLUSTER := "mainnet-beta"  # "devnet", "testnet", or "mainnet-beta"
const USE_OS_PICKER := true  # true = OS wallet picker, false = in-app wallet buttons (stores wallet type)
const SIWS_DOMAIN := "example.com"
const SIWS_STATEMENT := "Sign in to MWA Example App"


static func get_rpc_url() -> String:
	match CLUSTER:
		"mainnet-beta": return "https://api.mainnet-beta.solana.com"
		"devnet": return "https://api.devnet.solana.com"
		"testnet": return "https://api.testnet.solana.com"
		_: return "https://api.mainnet-beta.solana.com"


func _ready() -> void:
	print("[AppConfig] _ready | START")
	print("[AppConfig] _ready | app_name=%s app_uri=%s cluster=%s rpc_url=%s icon=%s" % [APP_NAME, APP_URI, CLUSTER, get_rpc_url(), APP_ICON_PATH])
	print("[AppConfig] _ready | DONE")
