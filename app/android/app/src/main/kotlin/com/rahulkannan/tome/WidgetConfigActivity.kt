package com.rahulkannan.tome

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import android.widget.ArrayAdapter
import android.widget.ListView
import android.widget.TextView

/** Asks which pack a new (or long-pressed) home-screen widget should show. */
class WidgetConfigActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val widgetId = intent?.extras?.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        val result = Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
        setResult(RESULT_CANCELED, result) // backing out doesn't place the widget
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        setTitle(R.string.widget_pick_title)

        val packs = WidgetData.read(this).packs
        if (packs.isEmpty()) {
            val pad = (24 * resources.displayMetrics.density).toInt()
            setContentView(TextView(this).apply {
                setText(R.string.widget_no_packs)
                setPadding(pad, pad / 2, pad, pad)
            })
            return
        }
        val list = ListView(this)
        list.adapter = ArrayAdapter(this, android.R.layout.simple_list_item_1,
            packs.map { if (it.slot != null) "${it.name} · ${it.slot}" else it.name })
        list.setOnItemClickListener { _, _, position, _ ->
            WidgetChoices.choose(this, widgetId, packs[position].id)
            TomeWidgetProvider.draw(this, AppWidgetManager.getInstance(this), widgetId, WidgetData.read(this))
            setResult(RESULT_OK, result)
            finish()
        }
        setContentView(list)
    }
}
