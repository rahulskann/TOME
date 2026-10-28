package com.rahulkannan.tome

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The Flutter app, plus the link to the home-screen widget (channel "tome/widget"):
 * Dart asks to redraw widgets ("refresh") and for the pack a widget opened TOME
 * on ("takeLaunchPack"); a widget tapped while TOME is open sends "openPack".
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var launchPack: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        launchPack = packFrom(intent)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tome/widget").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "refresh" -> {
                        TomeWidgetProvider.updateAll(applicationContext)
                        result.success(null)
                    }
                    "takeLaunchPack" -> {
                        result.success(launchPack)
                        launchPack = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        packFrom(intent)?.let { channel?.invokeMethod("openPack", it) }
    }

    private fun packFrom(intent: Intent?): String? =
        intent?.takeIf { it.action == TomeWidgetProvider.ACTION_OPEN_PACK }
            ?.getStringExtra(TomeWidgetProvider.EXTRA_PACK_ID)
}
