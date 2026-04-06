class_name AuthCache
extends RefCounted

## File-based authorization token cache.
## Persists MWA auth tokens to user:// so the app can silently
## reauthorize on next launch without prompting the user again.

const TAG := "[AuthCache]"
const CACHE_PATH := "user://auth_cache.json"

var _data: Dictionary = {}


func _init() -> void:
	print("%s _init | START path=%s" % [TAG, CACHE_PATH])
	_load()
	print("%s _init | DONE entries=%d" % [TAG, _data.size()])


## Store an authorization result keyed by wallet public key.
func set_auth(pubkey: String, auth_token: String, wallet_uri_base: String = "") -> void:
	print("%s set_auth | START pubkey=%s auth_token_len=%d wallet_uri_base=%s" % [TAG, pubkey, auth_token.length(), wallet_uri_base])
	_data[pubkey] = {
		"auth_token": auth_token,
		"wallet_uri_base": wallet_uri_base,
		"timestamp": Time.get_unix_time_from_system(),
	}
	_save()
	print("%s set_auth | DONE total_entries=%d" % [TAG, _data.size()])


## Retrieve a cached authorization for a given pubkey.
## Returns null if not found.
func get_auth(pubkey: String) -> Variant:
	print("%s get_auth | START pubkey=%s" % [TAG, pubkey])
	if _data.has(pubkey):
		var entry: Dictionary = _data[pubkey]
		print("%s get_auth | FOUND timestamp=%s auth_token_len=%d" % [TAG, str(entry.get("timestamp", 0)), str(entry.get("auth_token", "")).length()])
		return entry
	print("%s get_auth | NOT_FOUND" % TAG)
	return null


## Get the most recently cached auth (any pubkey).
func get_latest_auth() -> Variant:
	print("%s get_latest_auth | START total_entries=%d" % [TAG, _data.size()])
	var latest: Dictionary = {}
	var latest_time: float = 0.0
	var latest_pubkey: String = ""
	for key in _data:
		var entry: Dictionary = _data[key]
		var ts: float = entry.get("timestamp", 0.0)
		print("%s get_latest_auth | checking pubkey=%s timestamp=%s" % [TAG, key, str(ts)])
		if ts > latest_time:
			latest = entry.duplicate()  # FIX: duplicate to avoid mutating _data
			latest_pubkey = key
			latest_time = ts
	if latest.is_empty():
		print("%s get_latest_auth | NONE_FOUND" % TAG)
		return null
	latest["pubkey"] = latest_pubkey  # Safe — operating on a copy
	print("%s get_latest_auth | FOUND pubkey=%s timestamp=%s" % [TAG, latest_pubkey, str(latest_time)])
	return latest


## Remove a specific pubkey's cached auth.
func clear_auth(pubkey: String) -> void:
	print("%s clear_auth | START pubkey=%s existed=%s" % [TAG, pubkey, str(_data.has(pubkey))])
	_data.erase(pubkey)
	_save()
	print("%s clear_auth | DONE remaining_entries=%d" % [TAG, _data.size()])


## Clear all cached authorizations.
func clear_all() -> void:
	print("%s clear_all | START entries=%d" % [TAG, _data.size()])
	_data = {}
	_save()
	print("%s clear_all | DONE" % TAG)


func _save() -> void:
	print("%s _save | START path=%s entries=%d" % [TAG, CACHE_PATH, _data.size()])
	var file := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if file:
		var json_str := JSON.stringify(_data, "\t")
		file.store_string(json_str)
		file.close()
		print("%s _save | DONE bytes=%d" % [TAG, json_str.length()])
	else:
		print("%s _save | FAIL could not open file for writing" % TAG)


func _load() -> void:
	print("%s _load | START path=%s" % [TAG, CACHE_PATH])
	if not FileAccess.file_exists(CACHE_PATH):
		print("%s _load | NO_FILE creating empty cache" % TAG)
		return
	var file := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if file:
		var content := file.get_as_text()
		file.close()
		print("%s _load | FILE_READ bytes=%d" % [TAG, content.length()])
		var json := JSON.new()
		var err := json.parse(content)
		if err == OK and json.data is Dictionary:
			_data = json.data
			print("%s _load | PARSED entries=%d" % [TAG, _data.size()])
			for key in _data:
				print("%s _load | entry pubkey=%s timestamp=%s" % [TAG, key, str(_data[key].get("timestamp", 0))])
		else:
			print("%s _load | PARSE_FAIL error=%s" % [TAG, str(err)])
	else:
		print("%s _load | FAIL could not open file for reading" % TAG)
