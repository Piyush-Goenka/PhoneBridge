package com.piyush.phonebridge.relay

import android.app.Notification
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.telecom.TelecomManager
import android.util.Base64
import com.piyush.phonebridge.filter.DedupCache
import com.piyush.phonebridge.filter.NotificationFilter
import com.piyush.phonebridge.model.RelayNotification
import com.piyush.phonebridge.net.HostResolver
import com.piyush.phonebridge.net.MacClient
import com.piyush.phonebridge.pairing.PairingStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.Collections

class NotificationRelayService : NotificationListenerService() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val dedup = DedupCache()
    private val deliveredKeys: MutableSet<String> =
        Collections.synchronizedSet(LinkedHashSet())
    private val activeCallKeys: MutableSet<String> =
        Collections.synchronizedSet(HashSet())

    private var client: MacClient? = null
    private var clientToken: String? = null
    private val resolver by lazy { HostResolver(this) }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun defaultDialerPackage(): String? =
        (getSystemService(Context.TELECOM_SERVICE) as TelecomManager).defaultDialerPackage

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        scope.launch {
            val store = PairingStore(this@NotificationRelayService)
            if (!store.isPaired || !store.mirroringEnabled) return@launch

            val notification = extract(sbn)
            android.util.Log.d(
                "PhoneBridge",
                "posted pkg=${sbn.packageName} key=${sbn.key} " +
                    "ongoing=${sbn.isOngoing} flags=0x${Integer.toHexString(sbn.notification.flags)} " +
                    "category=${sbn.notification.category} " +
                    "titleLen=${notification?.title?.length} textLen=${notification?.text?.length} " +
                    "extracted=${notification != null}")
            if (notification == null) return@launch

            // Only the real phone app gets the call treatment. VoIP apps like
            // WhatsApp also tag their ringing notifications CATEGORY_CALL, but
            // reject/silence semantics are only reliable for telephony calls,
            // so everything else falls through to the normal mirror path.
            if (notification.category == "call" && store.mirrorCallsEnabled &&
                notification.pkg == defaultDialerPackage()
            ) {
                val sessionStarted = CallControl.isRinging(this@NotificationRelayService) &&
                    synchronized(activeCallKeys) {
                        if (activeCallKeys.isEmpty()) activeCallKeys.add(notification.key) else false
                    }
                if (sessionStarted) {
                    handleCall(notification, store)
                }
                return@launch
            }

            if (!NotificationFilter.shouldForward(notification, store.allowlist)) {
                android.util.Log.d("PhoneBridge", "dropped by filter: key=${sbn.key}")
                return@launch
            }
            if (dedup.isDuplicate(notification, System.currentTimeMillis())) {
                android.util.Log.d("PhoneBridge", "dropped as duplicate: key=${sbn.key}")
                return@launch
            }

            android.util.Log.d("PhoneBridge", "delivering: key=${sbn.key}")
            deliver(notification, store)
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (activeCallKeys.remove(sbn.key)) {
            CallControl.onRingEnded(this)
        }
        if (!deliveredKeys.remove(sbn.key)) return
        scope.launch {
            val store = PairingStore(this@NotificationRelayService)
            if (!store.isPaired) return@launch

            val macClient = clientFor(store) ?: return@launch
            val body = JSONObject().put("key", sbn.key).toString()
            val host = store.host
            val result = if (host != null) {
                macClient.postDismiss(host, store.port, body)
            } else {
                MacClient.SendResult.Failed("no cached host")
            }
            if (result is MacClient.SendResult.Failed) {
                resolver.rediscover(store)?.let { (newHost, newPort) ->
                    macClient.postDismiss(newHost, newPort, body)
                }
            }
        }
    }

    private suspend fun deliver(n: RelayNotification, store: PairingStore) {
        val macClient = clientFor(store) ?: return
        val icon = AppIcons.pngAndHash(packageManager, n.pkg)
        val body = JSONObject()
            .put("v", 1)
            .put("key", n.key)
            .put("pkg", n.pkg)
            .put("appName", n.appName)
            .put("title", n.title)
            .put("text", n.text)
            .put("postedAt", n.postedAt)
            .put("iconHash", icon?.second ?: "")
            .toString()

        var host = store.host
        var port = store.port
        var result = if (host != null) {
            macClient.postNotify(host, port, body)
        } else {
            MacClient.SendResult.Failed("no cached host")
        }

        if (result is MacClient.SendResult.Failed) {
            val rediscovered = resolver.rediscover(store)
            if (rediscovered == null) {
                SendLog.add(n.appName, n.title, "dropped: Mac not found")
                return
            }
            host = rediscovered.first
            port = rediscovered.second
            result = macClient.postNotify(host, port, body)
        }

        when (result) {
            is MacClient.SendResult.Ok -> {
                deliveredKeys.add(n.key)
                if (deliveredKeys.size > 200) {
                    synchronized(deliveredKeys) {
                        val iterator = deliveredKeys.iterator()
                        if (iterator.hasNext()) {
                            iterator.next()
                            iterator.remove()
                        }
                    }
                }
                SendLog.add(n.appName, n.title, "sent")
                if (result.needIcon && icon != null) {
                    val iconBody = JSONObject()
                        .put("iconHash", icon.second)
                        .put("png", Base64.encodeToString(icon.first, Base64.NO_WRAP))
                        .toString()
                    macClient.postIcon(host!!, port, iconBody)
                }
            }
            is MacClient.SendResult.AuthFailed ->
                SendLog.add(n.appName, n.title, "dropped: re-pair needed")
            is MacClient.SendResult.Failed ->
                SendLog.add(n.appName, n.title, "dropped: ${result.reason}")
        }
    }

    private suspend fun handleCall(n: RelayNotification, store: PairingStore) {
        val caller = n.title.ifBlank { n.text.ifBlank { "Unknown caller" } }
        val macClient = clientFor(store)
        if (macClient == null) {
            SendLog.add("Call", caller, "call dropped: not paired")
            activeCallKeys.remove(n.key)
            return
        }

        val callBody = JSONObject()
            .put("v", 1)
            .put("key", n.key)
            .put("caller", caller)
            .put("postedAt", n.postedAt)
            .toString()
        var host = store.host
        var port = store.port
        var posted = if (host != null) {
            macClient.postCall(host, port, callBody)
        } else {
            MacClient.SendResult.Failed("no cached host")
        }
        if (posted !is MacClient.SendResult.Ok) {
            val rediscovered = resolver.rediscover(store)
            if (rediscovered != null) {
                host = rediscovered.first
                port = rediscovered.second
                posted = macClient.postCall(host, port, callBody)
            }
        }
        if (posted !is MacClient.SendResult.Ok || host == null) {
            SendLog.add("Call", caller, "call dropped: Mac unreachable")
            activeCallKeys.remove(n.key)
            return
        }
        deliveredKeys.add(n.key)
        SendLog.add("Call", caller, "ringing on Mac")

        val waitBody = JSONObject().put("key", n.key).toString()
        when (val wait = macClient.postCallWait(host, port, waitBody)) {
            is MacClient.WaitResult.Action -> when (wait.action) {
                "answer" -> SendLog.add(
                    "Call", caller, CallControl.answer(this@NotificationRelayService))
                "reject" -> SendLog.add(
                    "Call", caller, CallControl.reject(this@NotificationRelayService))
                "silence" -> {
                    SendLog.add(
                        "Call", caller, CallControl.silence(this@NotificationRelayService))
                    scope.launch {
                        kotlinx.coroutines.delay(60_000)
                        CallControl.onRingEnded(this@NotificationRelayService)
                    }
                }
                else -> {}
            }
            is MacClient.WaitResult.Failed ->
                SendLog.add("Call", caller, "call wait failed: ${wait.reason}")
        }
    }

    private fun clientFor(store: PairingStore): MacClient? {
        val token = store.token ?: return null
        val fingerprint = store.fingerprint ?: return null
        if (client == null || clientToken != token) {
            client = MacClient(token, fingerprint)
            clientToken = token
        }
        return client
    }

    private fun extract(sbn: StatusBarNotification): RelayNotification? {
        val notification = sbn.notification ?: return null
        val extras = notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        val appName = try {
            val info = packageManager.getApplicationInfo(sbn.packageName, 0)
            packageManager.getApplicationLabel(info).toString()
        } catch (e: Exception) {
            sbn.packageName
        }
        return RelayNotification(
            key = sbn.key,
            pkg = sbn.packageName,
            appName = appName,
            title = title,
            text = text,
            postedAt = sbn.postTime,
            isOngoing = sbn.isOngoing,
            isGroupSummary = notification.flags and Notification.FLAG_GROUP_SUMMARY != 0,
            category = notification.category,
        )
    }
}
