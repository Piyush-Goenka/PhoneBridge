package com.piyush.phonebridge.relay

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.telecom.TelecomManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat

object CallControl {

    // ok distinguishes "the phone actually did it" from "declined or
    // skipped", which is what decides whether the Mac card changes state.
    data class Result(val ok: Boolean, val message: String)

    private var savedRingerMode: Int? = null

    private fun granted(context: Context, permission: String) =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED

    private fun callState(context: Context): Int? {
        if (!granted(context, Manifest.permission.READ_PHONE_STATE)) return null
        val telephony =
            context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
        @Suppress("DEPRECATION")
        return telephony.callState
    }

    fun isRinging(context: Context): Boolean =
        callState(context) == TelephonyManager.CALL_STATE_RINGING

    // Ringing or connected: the call session is still worth commanding.
    fun isCallAlive(context: Context): Boolean =
        callState(context) != TelephonyManager.CALL_STATE_IDLE

    fun answer(context: Context): Result {
        if (!granted(context, Manifest.permission.ANSWER_PHONE_CALLS)) {
            return Result(false, "answer failed: no permission")
        }
        if (!isRinging(context)) return Result(false, "answer skipped: not ringing")
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        return try {
            @Suppress("DEPRECATION")
            telecom.acceptRingingCall()
            Result(true, "call answered")
        } catch (e: SecurityException) {
            Result(false, "answer failed")
        }
    }

    fun reject(context: Context): Result {
        if (!granted(context, Manifest.permission.ANSWER_PHONE_CALLS)) {
            return Result(false, "reject failed: no permission")
        }
        if (!isRinging(context)) return Result(false, "reject skipped: not ringing")
        if (!canEndCall()) return Result(false, "reject needs Android 9+")
        return if (endCall(context)) {
            Result(true, "call rejected")
        } else {
            Result(false, "reject failed")
        }
    }

    // Hangs up a call that is already connected (the Mac's End call button).
    fun hangUp(context: Context): Result {
        if (!granted(context, Manifest.permission.ANSWER_PHONE_CALLS)) {
            return Result(false, "end failed: no permission")
        }
        if (!isCallAlive(context)) return Result(false, "end skipped: no active call")
        if (!canEndCall()) return Result(false, "end needs Android 9+")
        return if (endCall(context)) {
            Result(true, "call ended")
        } else {
            Result(false, "end failed")
        }
    }

    // TelecomManager.endCall() only exists on API 28+. minSdk is 26, so on
    // Android 8/8.1 there is no supported way to hang up; degrade cleanly
    // instead of crashing with NoSuchMethodError.
    private fun canEndCall(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P

    private fun endCall(context: Context): Boolean {
        if (!canEndCall()) return false
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        return try {
            @Suppress("DEPRECATION")
            telecom.endCall()
        } catch (e: SecurityException) {
            false
        }
    }

    @Synchronized
    fun silence(context: Context): Result {
        val notifications =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!notifications.isNotificationPolicyAccessGranted) {
            return Result(false, "silence failed: no DND access")
        }
        if (!isRinging(context)) return Result(false, "silence skipped: not ringing")
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (savedRingerMode == null) savedRingerMode = audio.ringerMode
        audio.ringerMode = AudioManager.RINGER_MODE_SILENT
        return Result(true, "ringer silenced")
    }

    @Synchronized
    fun onRingEnded(context: Context) {
        val saved = savedRingerMode ?: return
        savedRingerMode = null
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audio.ringerMode = saved
    }
}
