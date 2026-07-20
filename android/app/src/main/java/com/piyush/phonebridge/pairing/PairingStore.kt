package com.piyush.phonebridge.pairing

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class PairingStore(context: Context) {

    // Token, fingerprint, and host live in an AES-256 encrypted store whose
    // key is held in the Android Keystore (hardware-backed where available),
    // so the values are not readable from a raw prefs file or a backup.
    private val prefs: SharedPreferences = run {
        val masterKey = MasterKey.Builder(context.applicationContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context.applicationContext,
            "pairing.secure",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

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

    // Whether this phone's client certificate has been enrolled on the Mac
    // (mutual TLS). Reset on every fresh pairing so a new Mac re-enrolls.
    var clientEnrolled: Boolean
        get() = prefs.getBoolean("clientEnrolled", false)
        set(value) = prefs.edit().putBoolean("clientEnrolled", value).apply()

    val isPaired: Boolean
        get() = token != null && fingerprint != null

    fun apply(qr: QrPayload) {
        token = qr.token
        fingerprint = qr.fingerprint
        host = qr.host
        port = qr.port
        clientEnrolled = false
    }
}
