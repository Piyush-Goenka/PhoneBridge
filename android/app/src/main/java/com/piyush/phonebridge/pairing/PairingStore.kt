package com.piyush.phonebridge.pairing

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.piyush.phonebridge.net.ClientIdentityMetadata

class PairingStore(context: Context) {

    companion object {
        private const val LEGACY_PREFS = "pairing"
        private const val SECURE_PREFS = "pairing.secure"
        private const val MIGRATION_COMPLETE = "legacyMigrationComplete"
        private const val LEGACY_CLIENT_ENROLLED = "clientEnrolled"
        private const val ENROLLED_CLIENT_FINGERPRINT = "enrolledClientFingerprint"

        // clientEnrolled intentionally is not migrated: it did not exist in
        // the plaintext store, and a newly restored pairing must enroll its
        // current Keystore identity before claiming mutual TLS is ready.
        private val migratableKeys = setOf(
            "token", "fingerprint", "host", "port", "allowlist",
            "mirroring", "mirrorCalls",
        )

        internal fun keysToMigrate(
            legacyKeys: Set<String>,
            secureKeys: Set<String>,
        ): Set<String> {
            if (MIGRATION_COMPLETE in secureKeys) return emptySet()
            return legacyKeys.intersect(migratableKeys) - secureKeys
        }

        private fun migrateLegacy(context: Context, secure: SharedPreferences) {
            synchronized(PairingStore::class.java) {
                val legacy = context.getSharedPreferences(LEGACY_PREFS, Context.MODE_PRIVATE)
                val secureKeys = secure.all.keys
                if (MIGRATION_COMPLETE in secureKeys) return

                val legacyValues = legacy.all
                val editor = secure.edit()
                for (key in keysToMigrate(legacyValues.keys, secureKeys)) {
                    when (val value = legacyValues[key]) {
                        is String -> editor.putString(key, value)
                        is Int -> editor.putInt(key, value)
                        is Boolean -> editor.putBoolean(key, value)
                        is Set<*> -> editor.putStringSet(
                            key, value.filterIsInstance<String>().toSet())
                    }
                }
                editor.putBoolean(MIGRATION_COMPLETE, true)

                // Delete the plaintext copy only after the encrypted write is
                // durably committed. A failed commit leaves it available for
                // another migration attempt instead of losing the pairing.
                if (editor.commit() && legacyValues.isNotEmpty()) {
                    legacy.edit().clear().apply()
                }
            }
        }
    }

    // Token, fingerprint, and host live in an AES-256 encrypted store whose
    // key is held in the Android Keystore (hardware-backed where available),
    // so the values are not readable from a raw prefs file or a backup.
    private val prefs: SharedPreferences = run {
        val masterKey = MasterKey.Builder(context.applicationContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context.applicationContext,
            SECURE_PREFS,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        ).also { migrateLegacy(context.applicationContext, it) }
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

    // Enrollment belongs to one exact client certificate. The old Boolean
    // survived a Keystore identity rotation and incorrectly skipped /enroll;
    // comparing fingerprints makes a repaired or replaced key enroll again.
    fun isClientEnrolled(clientFingerprint: String): Boolean =
        ClientIdentityMetadata.enrollmentMatches(
            prefs.getString(ENROLLED_CLIENT_FINGERPRINT, null),
            clientFingerprint,
        )

    fun markClientEnrolled(clientFingerprint: String) {
        prefs.edit()
            .putString(ENROLLED_CLIENT_FINGERPRINT, clientFingerprint.lowercase())
            .remove(LEGACY_CLIENT_ENROLLED)
            .apply()
    }

    fun clearClientEnrollment() {
        prefs.edit()
            .remove(ENROLLED_CLIENT_FINGERPRINT)
            .remove(LEGACY_CLIENT_ENROLLED)
            .apply()
    }

    val isPaired: Boolean
        get() = token != null && fingerprint != null

    fun apply(qr: QrPayload) {
        // Change the destination and clear its enrollment marker atomically;
        // the listener must never observe new pairing credentials with the old
        // Mac's enrollment state.
        prefs.edit()
            .putString("token", qr.token)
            .putString("fingerprint", qr.fingerprint)
            .putString("host", qr.host)
            .putInt("port", qr.port)
            .remove(ENROLLED_CLIENT_FINGERPRINT)
            .remove(LEGACY_CLIENT_ENROLLED)
            .apply()
    }

    // Forget the paired Mac. Leaves user preferences (allowlist, toggles)
    // intact so re-pairing does not reset them.
    fun clear() {
        prefs.edit()
            .remove("token")
            .remove("fingerprint")
            .remove("host")
            .remove("port")
            .remove(ENROLLED_CLIENT_FINGERPRINT)
            .remove(LEGACY_CLIENT_ENROLLED)
            .apply()
    }
}
