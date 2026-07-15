package com.piyush.phonebridge.relay

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

object SendLog {
    data class Entry(
        val time: Long,
        val appName: String,
        val title: String,
        val outcome: String,
    )

    private val _entries = MutableStateFlow<List<Entry>>(emptyList())
    val entries: StateFlow<List<Entry>> = _entries

    fun clear() {
        _entries.value = emptyList()
    }

    fun add(appName: String, title: String, outcome: String) {
        _entries.update { current ->
            (listOf(Entry(System.currentTimeMillis(), appName, title, outcome)) + current).take(50)
        }
    }
}
