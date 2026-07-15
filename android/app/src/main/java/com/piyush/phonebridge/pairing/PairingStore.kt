package com.piyush.phonebridge.pairing

import android.content.Context

class PairingStore(context: Context) {

    private val prefs = context.getSharedPreferences("pairing", Context.MODE_PRIVATE)

    var token: String?
        get() = prefs.getString("token", null)
        set(value) = prefs.edit().putString("token", value).apply()

    var fingerprint: String?
        get() = prefs.getString("fingerprint", null)
        set(value) = prefs.edit().putString("fingerprint", value).apply()

    var host: String?
        get() = prefs.getString("host", null)
        set(value) = prefs.edit().putString("host", value).apply()

    var port: Int
        get() = prefs.getInt("port", 52735)
        set(value) = prefs.edit().putInt("port", value).apply()

    var allowlist: Set<String>
        get() = prefs.getStringSet("allowlist", emptySet())?.toSet() ?: emptySet()
        set(value) = prefs.edit().putStringSet("allowlist", value).apply()

    var mirroringEnabled: Boolean
        get() = prefs.getBoolean("mirroring", true)
        set(value) = prefs.edit().putBoolean("mirroring", value).apply()

    var mirrorCallsEnabled: Boolean
        get() = prefs.getBoolean("mirrorCalls", false)
        set(value) = prefs.edit().putBoolean("mirrorCalls", value).apply()

    val isPaired: Boolean
        get() = token != null && fingerprint != null

    fun apply(qr: QrPayload) {
        token = qr.token
        fingerprint = qr.fingerprint
        host = qr.host
        port = qr.port
    }
}
