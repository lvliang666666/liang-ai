package com.lvcompany.ai_chat_app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// F9/F7 分享即问：接收系统分享（文本 + 图片）经 MethodChannel 桥给 Flutter。
///
/// - 冷启动：onCreate 的 intent 缓存，Flutter 侧就绪后经 channel 拉取或主动推
/// - 热启动（singleTop）：onNewIntent 缓存并主动推 "onSharedPayload" 事件
/// - 文本：EXTRA_TEXT 字符串；图片：EXTRA_STREAM Uri（content://），
///   Flutter 侧经 contentResolver 桥方法 "readShareImage" 读字节转 base64
///   （平台线程读文件，主线程只传 Uri 字符串）
class MainActivity : FlutterActivity() {
    private var pendingShareText: String? = null
    private var pendingShareImageUri: String? = null
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
                    "getSharedPayload" -> {
                        result.success(buildPayloadMap())
                        clearPending()
                    }
                    "readShareImage" -> {
                        val uri = call.argument<String>("uri")
                        if (uri == null) {
                            result.error("INVALID_ARGS", "uri is required", null)
                        } else {
                            readImageBytes(Uri.parse(uri), result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
            // 引擎就绪时若已有冷启动分享，主动推一次
            val payload = buildPayloadMap()
            if (payload != null) {
                c.invokeMethod("onSharedPayload", payload)
                clearPending()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent?.let { cacheFromIntent(it) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val had = cacheFromIntent(intent)
        if (had) {
            setIntent(intent)
            val payload = buildPayloadMap()
            val c = channel
            if (payload != null && c != null) {
                c.invokeMethod("onSharedPayload", payload)
                clearPending()
            }
        }
    }

    /// 从 intent 提取分享内容进缓存；有内容返回 true
    private fun cacheFromIntent(intent: Intent): Boolean {
        if (intent.action != Intent.ACTION_SEND) return false
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        if (!text.isNullOrBlank()) {
            pendingShareText = text
            return true
        }
        @Suppress("DEPRECATION")
        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        if (uri != null) {
            pendingShareImageUri = uri.toString()
            return true
        }
        return false
    }

    /// 组装 payload map（文本/图片二选一，图片优先级低于文本——
    /// 同一 intent 两者都有时文本更可能是用户想问的问题）
    private fun buildPayloadMap(): Map<String, Any?>? {
        pendingShareText?.let { return mapOf("type" to "text", "text" to it) }
        pendingShareImageUri?.let {
            return mapOf("type" to "image", "uri" to it)
        }
        return null
    }

    private fun clearPending() {
        pendingShareText = null
        pendingShareImageUri = null
    }

    /// 平台线程读图片字节，主线程回调 base64（Flutter 侧 MessageAttachment
    /// 直接可用）。读失败回 error，Flutter 侧 toast 提示
    private fun readImageBytes(uri: Uri, result: MethodChannel.Result) {
        runOnUiThread {
            try {
                val bytes = contentResolver.openInputStream(uri)?.use {
                    it.readBytes()
                }
                if (bytes == null) {
                    result.error("READ_FAILED", "无法读取分享的图片", null)
                } else {
                    val mime = contentResolver.getType(uri) ?: "image/png"
                    result.success(
                        mapOf(
                            "base64" to android.util.Base64.encodeToString(
                                bytes, android.util.Base64.NO_WRAP
                            ),
                            "mime" to mime,
                        )
                    )
                }
            } catch (e: Exception) {
                result.error("READ_FAILED", e.message, null)
            }
        }
    }
}
