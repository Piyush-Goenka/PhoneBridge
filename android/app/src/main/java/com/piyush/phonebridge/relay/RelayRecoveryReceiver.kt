package com.piyush.phonebridge.relay

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.service.notification.NotificationListenerService
import androidx.core.app.NotificationManagerCompat

// Updating an APK kills its process and can leave Android's listener binding
// in a long restart backoff. Ask the system to reconnect immediately once the
// replacement is complete; this receiver contains no network or secret logic.
class RelayRecoveryReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (context.packageName !in
            NotificationManagerCompat.getEnabledListenerPackages(context)
        ) return

        NotificationListenerService.requestRebind(
            ComponentName(context, NotificationRelayService::class.java))
    }
}
