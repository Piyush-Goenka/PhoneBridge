package com.piyush.phonebridge.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AppListFilterTest {

    private val apps = listOf(
        AppEntry("com.whatsapp", "WhatsApp"),
        AppEntry("com.google.android.gm", "Gmail"),
        AppEntry("com.spotify.music", "Spotify"),
        AppEntry("com.instagram.android", "Instagram"),
    )
    private val allowlist = setOf("com.whatsapp", "com.google.android.gm")

    private fun labels(
        query: String = "",
        selectedOnly: Boolean = false,
        list: Set<String> = allowlist,
    ) = AppListFilter.visible(apps, query, list, selectedOnly).map { it.label }

    @Test
    fun showsEverythingByDefault() {
        assertEquals(listOf("WhatsApp", "Gmail", "Spotify", "Instagram"), labels())
    }

    @Test
    fun selectedOnlyShowsJustTheAllowlistedApps() {
        assertEquals(listOf("WhatsApp", "Gmail"), labels(selectedOnly = true))
    }

    @Test
    fun selectedOnlyWithNothingChosenIsEmpty() {
        assertTrue(labels(selectedOnly = true, list = emptySet()).isEmpty())
    }

    @Test
    fun searchIsCaseInsensitiveOnLabel() {
        assertEquals(listOf("Spotify"), labels(query = "spot"))
    }

    @Test
    fun searchAndSelectedOnlyCombine() {
        // "gram" matches Instagram, which is not on the allowlist.
        assertTrue(labels(query = "gram", selectedOnly = true).isEmpty())
        assertEquals(listOf("Gmail"), labels(query = "gmail", selectedOnly = true))
    }

    @Test
    fun whitespaceQueryIsTreatedAsNoQuery() {
        assertEquals(4, labels(query = "   ").size)
    }

    @Test
    fun preservesTheIncomingOrder() {
        assertEquals(listOf("WhatsApp", "Gmail"), labels(selectedOnly = true))
    }
}
