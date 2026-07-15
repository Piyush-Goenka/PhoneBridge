package com.piyush.phonebridge.filter

import com.piyush.phonebridge.model.RelayNotification
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationFilterTest {

    private val allowlist = setOf("com.whatsapp", "com.spotify.music", "com.google.android.apps.maps")

    private fun notif(
        pkg: String = "com.whatsapp",
        title: String = "Alice",
        text: String = "hi",
        isOngoing: Boolean = false,
        isGroupSummary: Boolean = false,
        category: String? = null,
    ) = RelayNotification(
        key = "0|$pkg|1|null|10", pkg = pkg, appName = pkg,
        title = title, text = text, postedAt = 0L,
        isOngoing = isOngoing, isGroupSummary = isGroupSummary, category = category)

    @Test
    fun forwardsPlainMessageFromAllowlistedApp() {
        assertTrue(NotificationFilter.shouldForward(notif(), allowlist))
    }

    @Test
    fun dropsAppNotOnAllowlist() {
        assertFalse(NotificationFilter.shouldForward(notif(pkg = "com.random.game"), allowlist))
    }

    @Test
    fun dropsSpotifyMediaNotification() {
        // Media playback: ongoing, category transport.
        val spotify = notif(
            pkg = "com.spotify.music", title = "Song", text = "Artist",
            isOngoing = true, category = "transport")
        assertFalse(NotificationFilter.shouldForward(spotify, allowlist))
    }

    @Test
    fun dropsTransportCategoryEvenWhenNotOngoing() {
        val spotify = notif(pkg = "com.spotify.music", category = "transport")
        assertFalse(NotificationFilter.shouldForward(spotify, allowlist))
    }

    @Test
    fun dropsMapsNavigationUpdate() {
        val maps = notif(
            pkg = "com.google.android.apps.maps",
            title = "Turn right", text = "onto Main St",
            isOngoing = true, category = "navigation")
        assertFalse(NotificationFilter.shouldForward(maps, allowlist))
    }

    @Test
    fun dropsGroupSummary() {
        assertFalse(NotificationFilter.shouldForward(notif(isGroupSummary = true), allowlist))
    }

    @Test
    fun dropsProgressServiceAndSysCategories() {
        for (category in listOf("progress", "service", "sys")) {
            assertFalse(
                "category $category should drop",
                NotificationFilter.shouldForward(notif(category = category), allowlist))
        }
    }

    @Test
    fun dropsBlankNotification() {
        assertFalse(NotificationFilter.shouldForward(notif(title = "", text = " "), allowlist))
    }

    @Test
    fun forwardsMessageCategoryFromAllowlistedApp() {
        assertTrue(NotificationFilter.shouldForward(notif(category = "msg"), allowlist))
    }
}
