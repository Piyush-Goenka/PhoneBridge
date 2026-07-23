package com.piyush.phonebridge.ui

import android.content.Intent
import android.content.pm.PackageManager
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import com.piyush.phonebridge.pairing.PairingStore
import com.piyush.phonebridge.pairing.QrPayload

data class AppEntry(val pkg: String, val label: String)

fun launcherApps(pm: PackageManager): List<AppEntry> {
    val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
    return pm.queryIntentActivities(intent, 0)
        .map { AppEntry(it.activityInfo.packageName, it.loadLabel(pm).toString()) }
        .distinctBy { it.pkg }
        .sortedBy { it.label.lowercase() }
}

private data class TabSpec(val label: String, val icon: ImageVector)

private val tabs = listOf(
    TabSpec("Home", Icons.Filled.Home),
    TabSpec("Apps", Icons.Filled.Search),
    TabSpec("Activity", Icons.Filled.Notifications),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    store: PairingStore,
    paired: MutableState<Boolean>,
    accessGranted: MutableState<Boolean>,
    macReachable: Boolean?,
    verifyingPairing: MutableState<Boolean>,
    pendingPairing: MutableState<QrPayload?>,
    pairingError: MutableState<String?>,
    onEnableAccess: () -> Unit,
    onScanQr: () -> Unit,
    onMirrorCalls: (Boolean) -> Unit,
    onConfirmReplace: (QrPayload) -> Unit,
    onDismissPairingDialog: () -> Unit,
    onUnpair: () -> Unit,
) {
    var selectedTab by rememberSaveable { mutableIntStateOf(0) }

    val pending = pendingPairing.value
    if (pending != null) {
        AlertDialog(
            onDismissRequest = onDismissPairingDialog,
            title = { Text("Replace paired Mac?") },
            text = {
                Text(
                    "This QR is for a different Mac (${pending.host}). Pairing with it " +
                        "will send your notifications there instead of your current Mac.")
            },
            confirmButton = {
                TextButton(onClick = { onConfirmReplace(pending) }) { Text("Replace") }
            },
            dismissButton = {
                TextButton(onClick = onDismissPairingDialog) { Text("Cancel") }
            },
        )
    }

    val error = pairingError.value
    if (error != null) {
        AlertDialog(
            onDismissRequest = onDismissPairingDialog,
            title = { Text("Pairing failed") },
            text = { Text(error) },
            confirmButton = { TextButton(onClick = onDismissPairingDialog) { Text("OK") } },
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(tabs[selectedTab].label) },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                ),
            )
        },
        bottomBar = {
            NavigationBar(containerColor = Brand.card) {
                tabs.forEachIndexed { index, tab ->
                    NavigationBarItem(
                        selected = selectedTab == index,
                        onClick = { selectedTab = index },
                        icon = { Icon(tab.icon, contentDescription = tab.label) },
                        label = { Text(tab.label) },
                        colors = androidx.compose.material3.NavigationBarItemDefaults.colors(
                            indicatorColor = MaterialTheme.colorScheme.surfaceVariant,
                            selectedIconColor = Brand.ink,
                            selectedTextColor = Brand.ink,
                            unselectedIconColor = Brand.inkSecondary,
                            unselectedTextColor = Brand.inkSecondary,
                        ),
                    )
                }
            }
        },
    ) { innerPadding ->
        val content = Modifier.padding(innerPadding)
        when (selectedTab) {
            0 -> androidx.compose.foundation.layout.Box(content) {
                HomeTab(
                    store = store,
                    paired = paired,
                    accessGranted = accessGranted,
                    macReachable = macReachable,
                    verifying = verifyingPairing.value,
                    onEnableAccess = onEnableAccess,
                    onScanQr = onScanQr,
                    onMirrorCalls = onMirrorCalls,
                    onUnpair = onUnpair)
            }
            1 -> androidx.compose.foundation.layout.Box(content) { AppsTab(store = store) }
            else -> androidx.compose.foundation.layout.Box(content) { ActivityTab() }
        }
    }
}
