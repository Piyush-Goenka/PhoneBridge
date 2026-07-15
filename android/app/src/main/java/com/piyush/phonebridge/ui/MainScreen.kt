package com.piyush.phonebridge.ui

import android.content.Intent
import android.content.pm.PackageManager
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.piyush.phonebridge.pairing.PairingStore
import com.piyush.phonebridge.relay.SendLog
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class AppEntry(val pkg: String, val label: String)

fun launcherApps(pm: PackageManager): List<AppEntry> {
    val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
    return pm.queryIntentActivities(intent, 0)
        .map { AppEntry(it.activityInfo.packageName, it.loadLabel(pm).toString()) }
        .distinctBy { it.pkg }
        .sortedBy { it.label.lowercase() }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    store: PairingStore,
    paired: MutableState<Boolean>,
    accessGranted: MutableState<Boolean>,
    onEnableAccess: () -> Unit,
    onScanQr: () -> Unit,
) {
    val context = LocalContext.current
    val apps = remember { launcherApps(context.packageManager) }
    var allowlist by remember { mutableStateOf(store.allowlist) }
    var mirroring by remember { mutableStateOf(store.mirroringEnabled) }
    val log by SendLog.entries.collectAsState()
    val timeFormat = remember { SimpleDateFormat("HH:mm:ss", Locale.US) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("PhoneBridge") },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    titleContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                ),
            )
        },
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(innerPadding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
        item {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Status", style = MaterialTheme.typography.titleMedium)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            if (accessGranted.value) "Notification access: granted"
                            else "Notification access: needed",
                            modifier = Modifier.weight(1f))
                        if (!accessGranted.value) {
                            Button(onClick = onEnableAccess) { Text("Enable") }
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            if (paired.value) "Paired with ${store.host ?: "Mac"}"
                            else "Not paired",
                            modifier = Modifier.weight(1f))
                        Button(onClick = onScanQr) {
                            Text(if (paired.value) "Re-pair" else "Scan QR")
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Mirroring", modifier = Modifier.weight(1f))
                        Switch(checked = mirroring, onCheckedChange = {
                            mirroring = it
                            store.mirroringEnabled = it
                        })
                    }
                }
            }
        }

        item {
            Text("Apps to mirror", style = MaterialTheme.typography.titleMedium)
        }
        items(apps, key = { it.pkg }) { app ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Checkbox(
                    checked = app.pkg in allowlist,
                    onCheckedChange = { checked ->
                        allowlist = if (checked) allowlist + app.pkg else allowlist - app.pkg
                        store.allowlist = allowlist
                    })
                Text(app.label)
            }
        }

        item {
            HorizontalDivider()
            Text("Recent sends", style = MaterialTheme.typography.titleMedium)
        }
        if (log.isEmpty()) {
            item { Text("Nothing sent yet", style = MaterialTheme.typography.bodySmall) }
        }
        items(log) { entry ->
            Text(
                "${timeFormat.format(Date(entry.time))}  ${entry.appName}: " +
                    "${entry.title.take(30)}  [${entry.outcome}]",
                style = MaterialTheme.typography.bodySmall)
        }
        }
    }
}
