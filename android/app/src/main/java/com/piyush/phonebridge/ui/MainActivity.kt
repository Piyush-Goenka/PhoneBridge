package com.piyush.phonebridge.ui

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.mutableStateOf
import androidx.core.app.NotificationManagerCompat
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.piyush.phonebridge.pairing.PairingStore
import com.piyush.phonebridge.pairing.QrPayload

class MainActivity : ComponentActivity() {

    private lateinit var store: PairingStore
    private val paired = mutableStateOf(false)
    private val accessGranted = mutableStateOf(false)

    private val scanLauncher = registerForActivityResult(ScanContract()) { result ->
        val contents = result.contents ?: return@registerForActivityResult
        val payload = QrPayload.parse(contents)
        if (payload == null) {
            Toast.makeText(this, "Not a PhoneBridge QR code", Toast.LENGTH_LONG).show()
        } else {
            store.apply(payload)
            paired.value = true
            Toast.makeText(this, "Paired with ${payload.host}", Toast.LENGTH_LONG).show()
        }
    }

    private val callPermissionLauncher = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()
    ) {
        // Runs after the runtime dialog resolves, so the DND settings screen
        // never races with a pending permission prompt.
        promptForDndAccessIfNeeded()
    }

    private fun onMirrorCallsChanged(enabled: Boolean) {
        store.mirrorCallsEnabled = enabled
        if (!enabled) return
        callPermissionLauncher.launch(
            arrayOf(
                Manifest.permission.ANSWER_PHONE_CALLS,
                Manifest.permission.READ_PHONE_STATE))
    }

    private fun promptForDndAccessIfNeeded() {
        val notifications = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (!notifications.isNotificationPolicyAccessGranted) {
            Toast.makeText(
                this,
                "Allow Do Not Disturb access so Silence can quiet the ringer",
                Toast.LENGTH_LONG).show()
            startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        store = PairingStore(this)
        setContent {
            PhoneBridgeTheme {
                MainScreen(
                    store = store,
                    paired = paired,
                    accessGranted = accessGranted,
                    onEnableAccess = {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    },
                    onScanQr = {
                        scanLauncher.launch(
                            ScanOptions()
                                .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                .setPrompt("Scan the QR from the Mac menu bar app")
                                .setBeepEnabled(false)
                                .setOrientationLocked(true))
                    },
                    onMirrorCalls = ::onMirrorCallsChanged,
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        paired.value = store.isPaired
        accessGranted.value = NotificationManagerCompat
            .getEnabledListenerPackages(this)
            .contains(packageName)
    }
}
