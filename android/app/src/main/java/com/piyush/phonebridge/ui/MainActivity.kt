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
import com.piyush.phonebridge.net.HostResolver
import com.piyush.phonebridge.net.SweepProber
import com.piyush.phonebridge.pairing.PairingStore
import com.piyush.phonebridge.pairing.QrPayload
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {

    private lateinit var store: PairingStore
    private val paired = mutableStateOf(false)
    private val accessGranted = mutableStateOf(false)

    // null while a check is running (or nothing is paired), then the result
    // of actually knocking on the Mac's port with the pinned certificate.
    private val macReachable = mutableStateOf<Boolean?>(null)
    private val uiScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var reachabilityJob: Job? = null

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
                    macReachable = macReachable,
                    onEnableAccess = {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    },
                    onScanQr = {
                        scanLauncher.launch(
                            ScanOptions()
                                .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                .setPrompt("Scan the QR from the Mac menu bar app")
                                .setBeepEnabled(false)
                                .setOrientationLocked(true)
                                .setCaptureActivity(PortraitCaptureActivity::class.java))
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
        checkMacReachable()
    }

    override fun onDestroy() {
        uiScope.cancel()
        super.onDestroy()
    }

    // A foreground, user-initiated probe: knock on the cached address with
    // the pinned certificate; if that fails, let the resolver heal the cache
    // (mDNS, then the guarded subnet sweep) and verify whatever it finds.
    private fun checkMacReachable() {
        reachabilityJob?.cancel()
        macReachable.value = null
        if (!store.isPaired) return
        val fingerprint = store.fingerprint ?: return
        reachabilityJob = uiScope.launch {
            val reachable = withContext(Dispatchers.IO) {
                val prober = SweepProber(fingerprint)
                val cachedHit = store.host?.let {
                    prober.findMac(listOf(it), store.port) != null
                } ?: false
                cachedHit || HostResolver(this@MainActivity).rediscover(store)
                    ?.let { (host, port) -> prober.findMac(listOf(host), port) != null }
                    ?: false
            }
            macReachable.value = reachable
        }
    }
}
