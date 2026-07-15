package com.piyush.phonebridge.relay

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import com.piyush.phonebridge.filter.DedupCache
import com.piyush.phonebridge.filter.NotificationFilter
import com.piyush.phonebridge.model.RelayNotification
import com.piyush.phonebridge.net.MacClient
import com.piyush.phonebridge.net.MacDiscovery
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

    private var client: MacClient? = null
    private var clientToken: String? = null

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        scope.launch {
            val store = PairingStore(this@NotificationRelayService)
            if (!store.isPaired || !store.mirroringEnabled) return@launch

            val notification = extract(sbn) ?: return@launch
            if (!NotificationFilter.shouldForward(notification, store.allowlist)) return@launch
            if (dedup.isDuplicate(notification, System.currentTimeMillis())) return@launch

            deliver(notification, store)
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (!deliveredKeys.remove(sbn.key)) return
        scope.launch {
            val store = PairingStore(this@NotificationRelayService)
            if (!store.isPaired) return@launch

            val macClient = clientFor(store) ?: return@launch
            val host = store.host ?: return@launch
            val body = JSONObject().put("key", sbn.key).toString()
            macClient.postDismiss(host, store.port, body)
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
            val rediscovered = MacDiscovery(this@NotificationRelayService).discover()
            if (rediscovered == null) {
                SendLog.add(n.appName, n.title, "dropped: Mac not found")
                return
            }
            host = rediscovered.first
            port = rediscovered.second
            store.host = host
            store.port = port
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
