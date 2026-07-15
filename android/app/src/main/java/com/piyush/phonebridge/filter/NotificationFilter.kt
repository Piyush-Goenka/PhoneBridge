package com.piyush.phonebridge.filter

import com.piyush.phonebridge.model.RelayNotification

object NotificationFilter {

    // Raw values of Notification.CATEGORY_TRANSPORT, _PROGRESS, _NAVIGATION,
    // _SERVICE, _SYSTEM, kept as strings so this file stays JVM-pure.
    private val droppedCategories = setOf("transport", "progress", "navigation", "service", "sys")

    fun shouldForward(n: RelayNotification, allowlist: Set<String>): Boolean {
        if (n.isOngoing) return false
        if (n.isGroupSummary) return false
        if (n.category in droppedCategories) return false
        if (n.pkg !in allowlist) return false
        if (n.title.isBlank() && n.text.isBlank()) return false
        return true
    }
}
