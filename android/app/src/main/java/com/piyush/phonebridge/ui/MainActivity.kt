package com.piyush.phonebridge.ui

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
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
import com.piyush.phonebridge.net.ClientIdentity
import com.piyush.phonebridge.net.Enrollment
import com.piyush.phonebridge.net.HostResolver
import com.piyush.phonebridge.net.LocalAddressPolicy
import com.piyush.phonebridge.net.MacClient
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
    // Pairing flow state, surfaced to the UI (#8): a scanned payload awaiting
    // the user's confirmation to replace an existing pairing, an error to
    // show, and whether a reachability verification is in flight.
    private val pendingPairing = mutableStateOf<QrPayload?>(null)
    private val pairingError = mutableStateOf<String?>(null)
    private val verifyingPairing = mutableStateOf(false)
    private val uiScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var reachabilityJob: Job? = null

    private val scanLauncher = registerForActivityResult(ScanContract()) { result ->
        val contents = result.contents ?: return@registerForActivityResult
        val payload = QrPayload.parse(contents)
        if (payload == null) {
            Toast.makeText(this, "Not a PhoneBridge QR code", Toast.LENGTH_LONG).show()
        } else if (!ClientIdentity.ensure()) {
            // No hardware-backed identity means no mutual TLS; refuse rather
            // than silently downgrading the pairing.
            Toast.makeText(
                this, "This device can't create a secure key; pairing cancelled",
                Toast.LENGTH_LONG).show()
        } else {
            verifyAndPair(payload)
        }
    }

    // Before trusting a scanned QR, prove it points at a real Mac that holds
    // the scanned certificate (kills dead redirects and typos), and if it is a
    // DIFFERENT Mac than the current pairing, ask before redirecting every
    // notification to it. A silent overwrite is exactly the redirection risk.
    private fun verifyAndPair(payload: QrPayload) {
        verifyingPairing.value = true
        uiScope.launch {
            val verifiedHost = withContext(Dispatchers.IO) {
                if (!hasActiveWifi()) return@withContext null
                val candidates = LocalAddressPolicy.resolveAllowed(payload.host)
                SweepProber(payload.fingerprint).findMac(candidates, payload.port)
            }
            verifyingPairing.value = false
            if (verifiedHost == null) {
                pairingError.value = "Couldn't reach that Mac. Make sure it is the " +
                    "PhoneBridge Mac on the same Wi-Fi, then scan again."
                return@launch
            }
            // Persist the private address that passed the pin check, not the
            // untrusted hostname from the QR (which could later DNS-rebind).
            val verifiedPayload = payload.copy(host = verifiedHost)
            val existing = store.fingerprint
            if (store.isPaired && existing != null && existing != verifiedPayload.fingerprint) {
                pendingPairing.value = verifiedPayload
            } else {
                commitPairing(verifiedPayload)
            }
        }
    }

    private fun hasActiveWifi(): Boolean {
        val connectivity = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        val active = connectivity.activeNetwork ?: return false
        return connectivity.getNetworkCapabilities(active)
            ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
    }

    private fun commitPairing(payload: QrPayload) {
        store.apply(payload)
        paired.value = true
        Toast.makeText(this, "Paired with ${payload.host}", Toast.LENGTH_LONG).show()
        enrollWhilePairing(payload.host, payload.port)
        checkMacReachable()
    }

    private fun unpair() {
        store.clear()
        ClientIdentity.delete()
        paired.value = false
        macReachable.value = null
        Toast.makeText(this, "Unpaired from the Mac", Toast.LENGTH_LONG).show()
    }

    // Best-effort immediate enrollment right after a scan, so a fresh pairing
    // locks the Mac to mutual TLS without waiting for the first notification.
    // If the Mac is not reachable yet, the relay service enrolls on its next
    // successful send.
    private fun enrollWhilePairing(host: String, port: Int) {
        val token = store.token ?: return
        val fingerprint = store.fingerprint ?: return
        uiScope.launch {
            withContext(Dispatchers.IO) {
                Enrollment.ensure(store, MacClient(token, fingerprint), host, port)
            }
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
                    verifyingPairing = verifyingPairing,
                    pendingPairing = pendingPairing,
                    pairingError = pairingError,
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
                    onConfirmReplace = { commitPairing(it); pendingPairing.value = null },
                    onDismissPairingDialog = {
                        pendingPairing.value = null
                        pairingError.value = null
                    },
                    onUnpair = ::unpair,
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
        val token = store.token ?: return
        val fingerprint = store.fingerprint ?: return
        reachabilityJob = uiScope.launch {
            val reachable = withContext(Dispatchers.IO) {
                val prober = SweepProber(fingerprint)
                val cached = store.host?.takeIf {
                    prober.findMac(listOf(it), store.port) != null
                }?.let { it to store.port }
                val destination = cached
                    ?: HostResolver(this@MainActivity).rediscover(store)
                if (destination != null) {
                    // Opening the Mac's pairing QR switches it to enrollment
                    // mode. Reopening this app can now repair a rotated client
                    // identity immediately, without waiting for another phone
                    // notification or forcing a second QR scan.
                    Enrollment.ensure(
                        store,
                        MacClient(token, fingerprint),
                        destination.first,
                        destination.second,
                    )
                } else {
                    false
                }
            }
            macReachable.value = reachable
        }
    }
}
