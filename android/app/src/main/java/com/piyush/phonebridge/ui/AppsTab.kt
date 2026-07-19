package com.piyush.phonebridge.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toBitmap
import com.piyush.phonebridge.pairing.PairingStore

@Composable
fun AppsTab(store: PairingStore) {
    val context = LocalContext.current
    val apps = remember { launcherApps(context.packageManager) }
    var allowlist by remember { mutableStateOf(store.allowlist) }
    var query by remember { mutableStateOf("") }
    var selectedOnly by rememberSaveable { mutableStateOf(false) }

    val filtered = remember(query, apps, allowlist, selectedOnly) {
        AppListFilter.visible(apps, query, allowlist, selectedOnly)
    }

    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Spacer(Modifier.size(8.dp))
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text("Search apps") },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            singleLine = true,
            shape = RoundedCornerShape(14.dp),
        )

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ScopeChip(
                text = "All ${apps.size}",
                selected = !selectedOnly,
                onClick = { selectedOnly = false })
            ScopeChip(
                text = "Selected ${allowlist.size}",
                selected = selectedOnly,
                onClick = { selectedOnly = true })
        }

        if (filtered.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    when {
                        selectedOnly && allowlist.isEmpty() ->
                            "No apps mirrored yet.\nTap All and tick the ones you want."
                        else -> "No apps match \"${query.trim()}\""
                    },
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center)
            }
        } else {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(filtered, key = { it.pkg }) { app ->
                    AppRow(
                        app = app,
                        checked = app.pkg in allowlist,
                        onToggle = { checked ->
                            allowlist =
                                if (checked) allowlist + app.pkg else allowlist - app.pkg
                            store.allowlist = allowlist
                        })
                }
            }
        }
    }
}

@Composable
private fun ScopeChip(text: String, selected: Boolean, onClick: () -> Unit) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = { Text(text) },
        shape = RoundedCornerShape(10.dp),
        colors = FilterChipDefaults.filterChipColors(
            containerColor = Brand.card,
            labelColor = Brand.inkSecondary,
            selectedContainerColor = Brand.accentSoft,
            selectedLabelColor = Brand.accent),
        border = FilterChipDefaults.filterChipBorder(
            enabled = true,
            selected = selected,
            borderColor = Brand.border,
            selectedBorderColor = Brand.accent),
    )
}

@Composable
private fun AppRow(app: AppEntry, checked: Boolean, onToggle: (Boolean) -> Unit) {
    val context = LocalContext.current
    val iconPainter = remember(app.pkg) {
        try {
            BitmapPainter(
                context.packageManager.getApplicationIcon(app.pkg)
                    .toBitmap(96, 96).asImageBitmap())
        } catch (e: Exception) {
            null
        }
    }

    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (iconPainter != null) {
            Image(
                painter = iconPainter,
                contentDescription = null,
                modifier = Modifier.size(38.dp))
        } else {
            Spacer(Modifier.size(38.dp))
        }
        Spacer(Modifier.size(12.dp))
        Text(
            app.label,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.weight(1f))
        Checkbox(checked = checked, onCheckedChange = onToggle)
    }
}
