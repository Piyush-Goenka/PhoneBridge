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
import java.util.concurrent.ConcurrentHashMap

class NotificationRelayService : NotificationListenerService() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val dedup = DedupCache()
    private val deliveredKeys: MutableSet<String> =
        Collections.synchronizedSet(LinkedHashSet())

    // Active call sessions: notification key to the caller name last sent to
    // the Mac. Compound decide-and-mutate steps synchronize on this map.
    private val activeCalls = ConcurrentHashMap<String, String>()

    // Keys answered via the Mac's Answer button. Those calls stay mirrored
    // after the ring stops so End call still has something to act on.
    private val answeredFromMac: MutableSet<String> =
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
                val caller = notification.title.ifBlank {
                    notification.text.ifBlank { CallSessionDecider.UNKNOWN_CALLER }
                }
                val decision = synchronized(activeCalls) {
                    CallSessionDecider.decide(
                        activeCaller = activeCalls[notification.key],
                        anySessionActive = activeCalls.isNotEmpty(),
                        answeredFromMac = answeredFromMac.contains(notification.key),
                        isRinging = CallControl.isRinging(this@NotificationRelayService),
                        caller = caller,
                    ).also { decided ->
                        when (decided) {
                            CallSessionDecider.Decision.Start ->
                                activeCalls[notification.key] = caller
                            is CallSessionDecider.Decision.UpdateCaller ->
                                activeCalls[notification.key] = decided.caller
                            is CallSessionDecider.Decision.End ->
                                activeCalls.remove(notification.key)
                            CallSessionDecider.Decision.Ignore -> {}
                        }
                    }
                }
                when (decision) {
                    CallSessionDecider.Decision.Start ->
                        handleCall(notification, caller, store)
                    is CallSessionDecider.Decision.UpdateCaller ->
                        updateCaller(notification.key, decision.caller, store)
                    is CallSessionDecider.Decision.End ->
                        endCallSession(notification.key, decision.caller, store)
                    CallSessionDecider.Decision.Ignore -> {}
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
        if (activeCalls.remove(sbn.key) != null) {
            CallControl.onRingEnded(this)
        }
        answeredFromMac.remove(sbn.key)
        if (!deliveredKeys.remove(sbn.key)) return
        scope.launch {
            val store = PairingStore(this@NotificationRelayService)
            if (!store.isPaired) return@launch
            sendDismiss(sbn.key, store)
        }
    }

    private suspend fun sendDismiss(key: String, store: PairingStore) {
        val macClient = clientFor(store) ?: return
        val body = JSONObject().put("key", key).toString()
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

    private suspend fun handleCall(n: RelayNotification, caller: String, store: PairingStore) {
        val macClient = clientFor(store)
        if (macClient == null) {
            SendLog.add("Call", caller, "call dropped: not paired")
            activeCalls.remove(n.key)
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
            activeCalls.remove(n.key)
            return
        }
        deliveredKeys.add(n.key)
        SendLog.add("Call", caller, "ringing on Mac")
        commandLoop(n.key, caller, host, port, macClient)
    }

    // The Mac can act more than once per call: Silence then Answer, Answer
    // then End call. So the phone keeps the command channel open for as long
    // as the session lives rather than acting once and walking away. Each
    // wait is a 45 s long poll on the Mac; a timeout just re-waits.
    private suspend fun commandLoop(
        key: String,
        caller: String,
        host: String,
        port: Int,
        macClient: MacClient,
    ) {
        val waitBody = JSONObject().put("key", key).toString()
        while (activeCalls.containsKey(key)) {
            when (val wait = macClient.postCallWait(host, port, waitBody)) {
                is MacClient.WaitResult.Action -> {
                    val done = runCallAction(wait.action, key, caller, host, port, macClient)
                    if (done) return
                }
                is MacClient.WaitResult.Failed -> {
                    SendLog.add("Call", caller, "call wait failed: ${wait.reason}")
                    return
                }
            }
        }
    }

    // Returns true when the session is over and the loop should stop.
    private fun runCallAction(
        action: String,
        key: String,
        caller: String,
        host: String,
        port: Int,
        macClient: MacClient,
    ): Boolean {
        val context = this@NotificationRelayService
        return when (action) {
            "answer" -> {
                val result = CallControl.answer(context)
                SendLog.add("Call", caller, result.message)
                if (result.ok) {
                    // Remember before telling the Mac: the dialer's
                    // ongoing-call re-post can beat the POST back.
                    answeredFromMac.add(key)
                    postCallState(key, caller, "active", host, port, macClient)
                }
                false
            }
            "silence" -> {
                val result = CallControl.silence(context)
                SendLog.add("Call", caller, result.message)
                if (result.ok) {
                    postCallState(key, caller, "silenced", host, port, macClient)
                    scope.launch {
                        kotlinx.coroutines.delay(60_000)
                        CallControl.onRingEnded(context)
                    }
                }
                false
            }
            "reject" -> {
                SendLog.add("Call", caller, CallControl.reject(context).message)
                true
            }
            "end" -> {
                SendLog.add("Call", caller, CallControl.hangUp(context).message)
                true
            }
            // "none" is a poll timeout, not an instruction: keep waiting as
            // long as the session is alive.
            else -> false
        }
    }

    private fun postCallState(
        key: String,
        caller: String,
        state: String,
        host: String,
        port: Int,
        macClient: MacClient,
    ) {
        val body = JSONObject()
            .put("v", 1)
            .put("key", key)
            .put("caller", caller)
            .put("postedAt", System.currentTimeMillis())
            .put("state", state)
            .toString()
        macClient.postCall(host, port, body)
    }

    // The dialer re-posted the ringing notification with a better name
    // (contact lookup finished after the first post). Refresh the Mac's
    // banner in place; best effort like every other send.
    private suspend fun updateCaller(key: String, caller: String, store: PairingStore) {
        val macClient = clientFor(store) ?: return
        val body = JSONObject()
            .put("v", 1)
            .put("key", key)
            .put("caller", caller)
            .put("postedAt", System.currentTimeMillis())
            .put("update", true)
            .toString()
        val host = store.host
        var result = if (host != null) {
            macClient.postCall(host, store.port, body)
        } else {
            MacClient.SendResult.Failed("no cached host")
        }
        if (result !is MacClient.SendResult.Ok) {
            resolver.rediscover(store)?.let { (newHost, newPort) ->
                result = macClient.postCall(newHost, newPort, body)
            }
        }
        if (result is MacClient.SendResult.Ok) {
            SendLog.add("Call", caller, "caller name updated")
        }
    }

    // Telephony left RINGING while the dialer's notification is still up:
    // the call was picked up on the phone. Close the Mac's card now instead
    // of leaving it until the call ends or the action window expires.
    private suspend fun endCallSession(key: String, caller: String, store: PairingStore) {
        CallControl.onRingEnded(this)
        if (!deliveredKeys.remove(key)) return
        SendLog.add("Call", caller, "answered on phone")
        sendDismiss(key, store)
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
