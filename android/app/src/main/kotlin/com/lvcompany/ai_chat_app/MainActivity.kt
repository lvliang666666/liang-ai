package com.lvcompany.ai_chat_app

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// F9 分享即问：接收 ACTION_SEND text/plain 分享文本，经 MethodChannel 桥给 Flutter。
///
/// - 冷启动：onCreate 的 intent 缓存，Flutter 侧就绪后经 channel "getSharedText" 拉取
/// - 热启动（singleTop）：onNewIntent 缓存并主动推 "onSharedText" 事件
/// - 只取 EXTRA_TEXT 字符串；无文本（其他 App 分享空内容）时回 null，Flutter 侧静默忽略
class MainActivity : FlutterActivity() {
    private var pendingShareText: String? = null
    private var channel: MethodChannel? = null

    companion object {
        const val CHANNEL_NAME = "ai_chat_app/share"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME
        ).also { c ->
            c.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSharedText" -> {
                        result.success(pendingShareText)
                        pendingShareText = null // 拉取即消费，避免重复预填
                    }
                    else -> result.notImplemented()
                }
            }
            // 引擎就绪时若已有冷启动分享文本，主动推一次
            pendingShareText?.let { text ->
                c.invokeMethod("onSharedText", text)
                pendingShareText = null
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent?.let { pendingShareText = extractShareText(it) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val text = extractShareText(intent)
        if (text != null) {
            setIntent(intent)
            val c = channel
            if (c != null) {
                // 引擎已就绪：直接推给 Flutter
                c.invokeMethod("onSharedText", text)
            } else {
                pendingShareText = text
            }
        }
    }

    private fun extractShareText(intent: Intent): String? {
        if (intent.action != Intent.ACTION_SEND) return null
        return intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }
    }
}
