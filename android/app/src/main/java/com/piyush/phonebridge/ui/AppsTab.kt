package com.piyush.phonebridge.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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

    val filtered = remember(query, apps) {
        if (query.isBlank()) apps
        else apps.filter { it.label.contains(query.trim(), ignoreCase = true) }
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
        SectionLabel("${allowlist.size} OF ${apps.size} APPS MIRRORED")

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
