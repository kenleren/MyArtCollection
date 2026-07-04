package com.kenleren.my_art_collection

import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.kenleren.my_art_collection/on_device_ai",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkAvailability" -> {
                    result.success(
                        mapOf(
                            "availability" to "unavailable",
                            "deviceModel" to "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
                            "message" to "On-device AI native provider is not bundled in this build.",
                        ),
                    )
                }
                "createDraft" -> {
                    result.error(
                        "ON_DEVICE_AI_UNAVAILABLE",
                        "On-device AI native provider is not bundled in this build.",
                        null,
                    )
                }
                else -> result.notImplemented()
            }
        }
    }
}
