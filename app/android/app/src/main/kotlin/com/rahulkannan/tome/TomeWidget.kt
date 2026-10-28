package com.rahulkannan.tome

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.io.File

// The home-screen widget: one pack's progress. The Flutter app writes what to
// show to <files>/widget-data.json (lib/widget/home_widget.dart) and asks for a
// redraw; this side only reads it.

/** One pack as the app last described it. */
data class WidgetPack(val id: String, val name: String, val slot: String?, val found: Int, val total: Int)

data class WidgetData(val atlas: Boolean, val packs: List<WidgetPack>) {
    companion object {
        fun read(context: Context): WidgetData {
            val file = File(context.filesDir, "widget-data.json")
            if (!file.exists()) return WidgetData(false, emptyList())
            return try {
                val json = JSONObject(file.readText())
                val list = json.optJSONArray("packs")
                val packs = (0 until (list?.length() ?: 0)).mapNotNull { i ->
                    val p = list?.optJSONObject(i) ?: return@mapNotNull null
                    val id = p.optString("id").ifEmpty { return@mapNotNull null }
                    WidgetPack(
                        id = id,
                        name = p.optString("name", id),
                        slot = if (p.isNull("slot")) null else p.optString("slot"),
                        found = p.optInt("found"),
                        total = p.optInt("total"),
                    )
                }
                WidgetData(json.optString("theme") == "atlas", packs)
            } catch (e: Exception) {
                WidgetData(false, emptyList())
            }
        }
    }
}

/** Which pack each placed widget shows. */
object WidgetChoices {
    private fun prefs(c: Context) = c.getSharedPreferences("tome_widgets", Context.MODE_PRIVATE)

    fun packFor(c: Context, widgetId: Int): String? = prefs(c).getString("pack_$widgetId", null)

    fun choose(c: Context, widgetId: Int, packId: String) =
        prefs(c).edit().putString("pack_$widgetId", packId).apply()

    fun forget(c: Context, widgetIds: IntArray) =
        prefs(c).edit().apply { widgetIds.forEach { remove("pack_$it") } }.apply()
}

class TomeWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val data = WidgetData.read(context)
        ids.forEach { draw(context, manager, it, data) }
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) =
        draw(context, manager, id, WidgetData.read(context))

    override fun onDeleted(context: Context, ids: IntArray) = WidgetChoices.forget(context, ids)

    companion object {
        const val ACTION_OPEN_PACK = "com.rahulkannan.tome.OPEN_PACK"
        const val EXTRA_PACK_ID = "packId"

        /** Below this width (dp) the widget shows just the count. */
        private const val WIDE_FROM_DP = 170

        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, TomeWidgetProvider::class.java))
            val data = WidgetData.read(context)
            ids.forEach { draw(context, manager, it, data) }
        }

        fun draw(context: Context, manager: AppWidgetManager, widgetId: Int, data: WidgetData) {
            val packId = WidgetChoices.packFor(context, widgetId)
            val pack = data.packs.firstOrNull { it.id == packId }
            val width = manager.getAppWidgetOptions(widgetId).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
            val wide = width == 0 || width >= WIDE_FROM_DP
            val views = RemoteViews(context.packageName, if (wide) R.layout.widget_wide else R.layout.widget_small)

            val atlas = data.atlas
            val ink = if (atlas) 0xFF3B2516.toInt() else 0xFFE6E8EF.toInt()
            val muted = if (atlas) 0xFF6B4E33.toInt() else 0xFF9AA3B8.toInt()
            val accent = if (atlas) 0xFF8E2A1E.toInt() else 0xFFF1D48A.toInt()
            views.setInt(R.id.widget_root, "setBackgroundResource",
                if (atlas) R.drawable.widget_bg_atlas else R.drawable.widget_bg_dark)

            val name = pack?.name ?: if (packId == null) "TOME" else "Not on this phone"
            views.setTextViewText(R.id.name, name)
            views.setTextColor(R.id.name, ink)
            views.setTextViewText(R.id.count, if (pack == null || pack.total == 0) "–" else "${pack.found}/${pack.total}")
            views.setTextColor(R.id.count, accent)
            views.setTextViewText(R.id.label, if (pack == null) "tap to open" else "found")
            views.setTextColor(R.id.label, muted)
            if (wide) {
                views.setTextViewText(R.id.slot, pack?.slot ?: "")
                views.setViewVisibility(R.id.slot, if (pack?.slot == null) View.GONE else View.VISIBLE)
                views.setTextColor(R.id.slot, muted)
                views.setViewVisibility(R.id.bar_dark, if (atlas) View.GONE else View.VISIBLE)
                views.setViewVisibility(R.id.bar_atlas, if (atlas) View.VISIBLE else View.GONE)
                views.setProgressBar(if (atlas) R.id.bar_atlas else R.id.bar_dark,
                    maxOf(pack?.total ?: 0, 1), pack?.found ?: 0, false)
            }

            val open = Intent(context, MainActivity::class.java).apply {
                action = ACTION_OPEN_PACK
                if (pack != null) putExtra(EXTRA_PACK_ID, pack.id)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            views.setOnClickPendingIntent(R.id.widget_root, PendingIntent.getActivity(
                context, widgetId, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            manager.updateAppWidget(widgetId, views)
        }
    }
}
