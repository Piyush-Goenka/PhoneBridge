package com.piyush.phonebridge.net

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.util.Calendar
import javax.net.ssl.KeyManager
import javax.net.ssl.KeyManagerFactory
import javax.security.auth.x500.X500Principal

// The phone's mutual-TLS identity. An EC P-256 keypair lives in the Android
// Keystore (hardware-backed where available); the private key is
// non-exportable, so it cannot leave the device via backups, adb, or root.
// Only the self-signed certificate (public half) is ever sent to the Mac.
object ClientIdentity {

    private const val ALIAS = "phonebridge-client"
    private const val KEYSTORE = "AndroidKeyStore"

    private fun keyStore(): KeyStore =
        KeyStore.getInstance(KEYSTORE).apply { load(null) }

    // Creates the keypair on first use. Returns false only when the Keystore
    // is unavailable (rare, very old devices), which callers surface as a
    // pairing error rather than downgrading to token-only silently.
    fun ensure(): Boolean {
        return try {
            val ks = keyStore()
            if (ks.containsAlias(ALIAS)) return true
            val end = Calendar.getInstance().apply { add(Calendar.YEAR, 30) }.time
            val generator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC, KEYSTORE)
            generator.initialize(
                KeyGenParameterSpec.Builder(
                    ALIAS,
                    KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setDigests(
                        KeyProperties.DIGEST_SHA256,
                        KeyProperties.DIGEST_SHA384,
                        KeyProperties.DIGEST_SHA512)
                    // Subject carries no trust meaning; the Mac pins the exact
                    // certificate, not any field inside it.
                    .setCertificateSubject(X500Principal("CN=PhoneBridge Phone"))
                    .setCertificateNotAfter(end)
                    .build())
            generator.generateKeyPair()
            true
        } catch (e: Exception) {
            false
        }
    }

    // Key managers backed by the Keystore entry, so every TLS connection the
    // phone opens can present the client certificate when the Mac asks for it.
    fun keyManagers(): Array<KeyManager>? {
        if (!ensure()) return null
        return try {
            val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
            kmf.init(keyStore(), null)
            kmf.keyManagers
        } catch (e: Exception) {
            null
        }
    }

    // Base64 DER of the client certificate, the body of the /enroll request.
    fun certificateDerBase64(): String? {
        if (!ensure()) return null
        return try {
            val cert = keyStore().getCertificate(ALIAS) ?: return null
            Base64.encodeToString(cert.encoded, Base64.NO_WRAP)
        } catch (e: Exception) {
            null
        }
    }
}
