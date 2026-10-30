package com.lvcompany.ai_chat_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews

/**
 * P2 桌面小组件：最近会话 + 快速新对话 + 当天简报一行
 *
 * 数据流（零新插件，复用 F9 的 MethodChannel 模式）：
 * - Flutter 侧 WidgetDataService 经 SharedPreferences（原生可读的
 *   "flutter." 前缀键）推送 JSON：{briefing, sessions: [{id, title}]}
 * - 本 Provider onUpdate/onUpdateAll 时读该键渲染 RemoteViews；
 *   数据为空时显示「打开 Liang AI 开始对话」空态
 * - 点击：新对话按钮 → liangai://new；会话行 → liangai://chat/<id>；
 *   简报行 → liangai://briefing。MainActivity 经 deep link 打开
 *   （singleTop 复用既有进程，冷启动也走同一入口）
 *
 * 为什么走 SharedPreferences 而非 AppWidgetManager 传 Intent extra：
 * widget 更新可能在 App 进程死亡后由系统触发（onUpdate），此时
 * MethodChannel 不可用；SharedPreferences 是跨进程持久的最简通道。
 */
class HomeWidgetProvider : AppWidgetProvider() {

    companion object {
        /** Flutter 侧写入的 widget 数据键（SharedPreferences "flutter." 前缀） */
        const val DATA_KEY = "flutter.home_widget_data"

        /** deep link scheme://host 约定（与 AndroidManifest intent-filter 一致） */
        const val LINK_NEW = "liangai://new"
        const val LINK_BRIEFING = "liangai://briefing"
        const val LINK_CHAT_PREFIX = "liangai://chat/"

        /** 最多展示的最近会话数（与布局 widget_session_0..2 对应） */
        const val MAX_SESSIONS = 3
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            render(context, appWidgetManager, id)
        }
    }

    override fun onEnabled(context: Context) {
        // 首个 widget 放上桌面：立即渲染一次（此时可能尚无数据，显示空态）
        renderAll(context)
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        // 无需清理：数据键常驻，重加 widget 立即有内容
    }

    /** 用当前持久化数据重渲染全部 widget 实例 */
    fun renderAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(
            ComponentName(context, HomeWidgetProvider::class.java)
        )
        for (id in ids) {
            render(context, manager, id)
        }
    }

    /** 读数据键 → 渲染单个 widget 实例 */
    private fun render(context: Context, manager: AppWidgetManager, appWidgetId: Int) {
        val views = RemoteViews(context.packageName, R.layout.home_widget)
        val json = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE
        ).getString(DATA_KEY, null)

        var briefing: String? = null
        val sessions = mutableListOf<Pair<String, String>>() // id to title
        if (!json.isNullOrBlank()) {
            try {
                val root = org.json.JSONObject(json)
                briefing = root.optString("briefing", null)
                val arr = root.optJSONArray("sessions")
                if (arr != null) {
                    for (i in 0 until minOf(arr.length(), MAX_SESSIONS)) {
                        val o = arr.optJSONObject(i) ?: continue
                        val sid = o.optString("id", "")
                        val title = o.optString("title", "")
                        if (sid.isNotEmpty() && title.isNotEmpty()) {
                            sessions.add(sid to title)
                        }
                    }
                }
            } catch (_: Exception) {
                // 坏数据按空态渲染（下次 Flutter 推送自愈）
            }
        }

        // 标题行 + 新对话按钮（恒显示）
        views.setTextViewText(R.id.widget_title, "Liang AI")
        views.setOnClickPendingIntent(
            R.id.widget_new_chat, linkPendingIntent(context, LINK_NEW, "new")
        )

        // 简报行：有内容才显示
        if (briefing.isNullOrBlank()) {
            views.setViewVisibility(R.id.widget_briefing, android.view.View.GONE)
        } else {
            views.setViewVisibility(R.id.widget_briefing, android.view.View.VISIBLE)
            views.setTextViewText(R.id.widget_briefing, briefing)
            views.setOnClickPendingIntent(
                R.id.widget_briefing, linkPendingIntent(context, LINK_BRIEFING, "briefing")
            )
        }

        // 会话行：逐行填充，多余的隐藏
        val rowIds = intArrayOf(
            R.id.widget_session_0, R.id.widget_session_1, R.id.widget_session_2
        )
        for (i in rowIds.indices) {
            if (i < sessions.size) {
                val (sid, title) = sessions[i]
                views.setViewVisibility(rowIds[i], android.view.View.VISIBLE)
                views.setTextViewText(rowIds[i], title)
                views.setOnClickPendingIntent(
                    rowIds[i],
                    linkPendingIntent(context, "$LINK_CHAT_PREFIX$sid", "chat_$sid")
                )
            } else {
                views.setViewVisibility(rowIds[i], android.view.View.GONE)
            }
        }

        // 空态：无简报无会话时标题下提示（复用 briefing 行显示引导文案）
        if (briefing.isNullOrBlank() && sessions.isEmpty()) {
            views.setViewVisibility(R.id.widget_briefing, android.view.View.VISIBLE)
            views.setTextViewText(R.id.widget_briefing, "打开 Liang AI 开始对话")
            views.setOnClickPendingIntent(
                R.id.widget_briefing, linkPendingIntent(context, LINK_NEW, "empty")
            )
        }

        manager.updateAppWidget(appWidgetId, views)
    }

    /** deep link PendingIntent：打开 MainActivity（singleTop 复用/冷启动同入口） */
    private fun linkPendingIntent(context: Context, uri: String, requestCode: String): PendingIntent {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri)).apply {
            setPackage(context.packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        return PendingIntent.getActivity(
            context,
            requestCode.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
