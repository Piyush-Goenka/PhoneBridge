package com.piyush.phonebridge.ui

// Which apps the Apps tab shows: the search box narrowed by the
// All/Selected filter. No Android or Compose imports, so it is unit-tested
// on the JVM like the other pure list logic in this project.
object AppListFilter {

    fun visible(
        apps: List<AppEntry>,
        query: String,
        allowlist: Set<String>,
        selectedOnly: Boolean,
    ): List<AppEntry> {
        val base = if (selectedOnly) apps.filter { it.pkg in allowlist } else apps
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return base
        return base.filter { it.label.contains(trimmed, ignoreCase = true) }
    }
}
