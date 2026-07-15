package com.piyush.phonebridge.relay

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.telecom.TelecomManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat

object CallControl {

    private var savedRingerMode: Int? = null

    private fun granted(context: Context, permission: String) =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED

    fun isRinging(context: Context): Boolean {
        if (!granted(context, Manifest.permission.READ_PHONE_STATE)) return false
        val telephony =
            context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
        @Suppress("DEPRECATION")
        return telephony.callState == TelephonyManager.CALL_STATE_RINGING
    }

    fun reject(context: Context): String {
        if (!granted(context, Manifest.permission.ANSWER_PHONE_CALLS)) {
            return "reject failed: no permission"
        }
        if (!isRinging(context)) return "reject skipped: not ringing"
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        @Suppress("DEPRECATION")
        val ended = try {
            telecom.endCall()
        } catch (e: SecurityException) {
            false
        }
        return if (ended) "call rejected" else "reject failed"
    }

    @Synchronized
    fun silence(context: Context): String {
        val notifications =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!notifications.isNotificationPolicyAccessGranted) {
            return "silence failed: no DND access"
        }
        if (!isRinging(context)) return "silence skipped: not ringing"
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (savedRingerMode == null) savedRingerMode = audio.ringerMode
        audio.ringerMode = AudioManager.RINGER_MODE_SILENT
        return "ringer silenced"
    }

    @Synchronized
    fun onRingEnded(context: Context) {
        val saved = savedRingerMode ?: return
        savedRingerMode = null
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audio.ringerMode = saved
    }
}
