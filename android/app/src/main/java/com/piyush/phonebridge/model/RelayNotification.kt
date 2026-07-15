package com.piyush.phonebridge.model

data class RelayNotification(
    val key: String,
    val pkg: String,
    val appName: String,
    val title: String,
    val text: String,
    val postedAt: Long,
    val isOngoing: Boolean,
    val isGroupSummary: Boolean,
    val category: String?,
)
