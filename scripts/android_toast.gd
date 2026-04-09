class_name AndroidToastHelper
extends Node

## Shows native Android toast messages. Falls back to print() in editor/desktop.

static func show(message: String, long_duration: bool = false) -> void:
	if OS.get_name() != "Android":
		print("[Toast] %s" % message)
		return
	var android_runtime = Engine.get_singleton("AndroidRuntime")
	if android_runtime == null:
		print("[Toast] %s (no AndroidRuntime)" % message)
		return
	var activity = android_runtime.getActivity()
	var toast_callable = func():
		var ToastClass = JavaClassWrapper.wrap("android.widget.Toast")
		var duration = ToastClass.LENGTH_LONG if long_duration else ToastClass.LENGTH_SHORT
		ToastClass.makeText(activity, message, duration).show()
	activity.runOnUiThread(android_runtime.createRunnableFromGodotCallable(toast_callable))
