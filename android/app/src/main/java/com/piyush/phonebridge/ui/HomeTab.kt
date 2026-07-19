package com.piyush.phonebridge.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.piyush.phonebridge.pairing.PairingStore

@Composable
fun HomeTab(
    store: PairingStore,
    paired: MutableState<Boolean>,
    accessGranted: MutableState<Boolean>,
    macReachable: MutableState<Boolean?>,
    onEnableAccess: () -> Unit,
    onScanQr: () -> Unit,
    onMirrorCalls: (Boolean) -> Unit,
) {
    var mirroring by remember { mutableStateOf(store.mirroringEnabled) }
    var mirrorCalls by remember { mutableStateOf(store.mirrorCallsEnabled) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        QuietCard {
            Column(
                Modifier.padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .background(Brand.accentSoft, CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Filled.Phone,
                            contentDescription = null,
                            tint = Brand.accent)
                    }
                    Spacer(Modifier.size(12.dp))
                    Column {
                        Text(
                            "PhoneBridge",
                            style = MaterialTheme.typography.titleLarge
                                .copy(fontWeight = FontWeight.SemiBold))
                        Text(
                            if (paired.value) "Connected to your Mac"
                            else "Not connected yet",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }

                StatusLine(
                    ok = paired.value,
                    text = if (paired.value) "Paired with ${store.host ?: "Mac"}"
                    else "Not paired: scan the QR from the Mac menu bar")
                StatusLine(
                    ok = accessGranted.value,
                    text = if (accessGranted.value) "Notification access granted"
                    else "Notification access needed")
                if (paired.value) {
                    StatusLine(
                        ok = macReachable.value,
                        text = when (macReachable.value) {
                            true -> "Mac reachable now"
                            false -> "Mac not reachable right now"
                            null -> "Checking if the Mac is reachable"
                        })
                }
            }
        }

        if (!accessGranted.value) {
            Button(
                onClick = onEnableAccess,
                modifier = Modifier.fillMaxWidth().height(48.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Brand.amberSoft,
                    contentColor = Color(0xFF92400E)),
            ) {
                Icon(Icons.Filled.Notifications, contentDescription = null)
                Spacer(Modifier.size(8.dp))
                Text("Enable notification access")
            }
        }

        SectionLabel("MIRRORING")

        QuietCard {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
                ToggleRow(
                    title = "Mirror notifications",
                    subtitle = "Show allowlisted apps on the Mac",
                    checked = mirroring,
                ) {
                    mirroring = it
                    store.mirroringEnabled = it
                }
                ToggleRow(
                    title = "Mirror calls",
                    subtitle = "Reject or silence phone calls from the Mac",
                    checked = mirrorCalls,
                ) {
                    mirrorCalls = it
                    onMirrorCalls(it)
                }
            }
        }

        FilledTonalButton(
            onClick = onScanQr,
            modifier = Modifier.fillMaxWidth().height(48.dp),
        ) {
            Text(if (paired.value) "Re-pair with the Mac" else "Scan pairing QR")
        }
    }
}

@Composable
fun QuietCard(content: @Composable () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = Brand.card),
        border = BorderStroke(1.dp, Brand.border),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
    ) {
        content()
    }
}

@Composable
fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelMedium.copy(letterSpacing = 1.4.sp),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 4.dp, top = 2.dp),
    )
}

@Composable
private fun StatusLine(ok: Boolean?, text: String) {
    val dot = when (ok) {
        true -> Brand.emerald
        false -> Brand.amber
        null -> Color(0xFFB8B8B2)
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(9.dp)
                .background(dot, CircleShape))
        Spacer(Modifier.size(10.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun ToggleRow(
    title: String,
    subtitle: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}
