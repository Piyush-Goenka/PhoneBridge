package com.piyush.phonebridge.net

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.Calendar
import java.util.concurrent.CopyOnWriteArraySet
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
    private var cachedSnapshot: Snapshot? = null
    private var cachedTlsMaterial: TlsMaterial? = null
    private val changeListeners = CopyOnWriteArraySet<() -> Unit>()

    private data class Snapshot(
        val certificateDerBase64: String,
        val fingerprint: String,
    )

    class TlsMaterial internal constructor(
        val certificateDerBase64: String,
        val fingerprint: String,
        internal val keyManagers: Array<KeyManager>,
    )

    private fun keyStore(): KeyStore =
        KeyStore.getInstance(KEYSTORE).apply { load(null) }

    internal fun addChangeListener(listener: () -> Unit) {
        changeListeners.add(listener)
    }

    internal fun removeChangeListener(listener: () -> Unit) {
        changeListeners.remove(listener)
    }

    private fun notifyIdentityChanged() {
        changeListeners.forEach { listener -> runCatching { listener() } }
    }

    // Creates the keypair on first use. Returns false only when the Keystore
    // is unavailable (rare, very old devices), which callers surface as a
    // pairing error rather than downgrading to token-only silently.
    @Synchronized
    fun ensure(): Boolean {
        if (cachedSnapshot != null) return true
        return try {
            val ks = keyStore()
            if (ks.containsAlias(ALIAS)) {
                val health = identityHealth(ks)
                if (health == ClientIdentityHealth.Usable) {
                    cachedSnapshot = readSnapshot(ks)
                    return cachedSnapshot != null
                }
                // A provider/Keystore outage is not evidence that the key is
                // obsolete. Keep it and retry instead of rotating away the
                // certificate that the Mac already trusts.
                if (!health.shouldReplace) {
                    return false
                }
            }

            // Key authorizations are immutable. Builds before the TLS fix made
            // an EC key without DIGEST_NONE, so Conscrypt's raw ECDSA client
            // signature failed at every handshake. Replace any key that cannot
            // prove it supports the exact signing primitive TLS will request.
            cachedSnapshot = null
            cachedTlsMaterial = null
            if (ks.containsAlias(ALIAS)) {
                ks.deleteEntry(ALIAS)
                // Cancel pooled TLS sessions that still carry the certificate
                // we just proved unusable.
                notifyIdentityChanged()
            }
            val end = Calendar.getInstance().apply { add(Calendar.YEAR, 30) }.time
            val generator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC, KEYSTORE)
            generator.initialize(
                KeyGenParameterSpec.Builder(
                    ALIAS,
                    KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(
                        ECGenParameterSpec(ClientIdentityMetadata.P256_CURVE))
                    .setDigests(
                        KeyProperties.DIGEST_NONE,
                        KeyProperties.DIGEST_SHA256,
                        KeyProperties.DIGEST_SHA384,
                        KeyProperties.DIGEST_SHA512)
                    // Subject carries no trust meaning; the Mac pins the exact
                    // certificate, not any field inside it.
                    .setCertificateSubject(X500Principal("CN=PhoneBridge Phone"))
                    .setCertificateNotAfter(end)
                    .build())
            generator.generateKeyPair()
            val generated = keyStore()
            val usable = identityHealth(generated) == ClientIdentityHealth.Usable
            if (usable) {
                cachedSnapshot = readSnapshot(generated)
            } else if (generated.containsAlias(ALIAS)) {
                generated.deleteEntry(ALIAS)
            }
            usable && cachedSnapshot != null
        } catch (e: Exception) {
            cachedSnapshot = null
            cachedTlsMaterial = null
            false
        }
    }

    // Conscrypt hashes the TLS transcript itself and asks AndroidKeyStore for
    // NONEwithECDSA over that digest. A normal SHA256withECDSA self-test would
    // miss the exact authorization bug that broke real devices.
    private fun identityHealth(ks: KeyStore): ClientIdentityHealth {
        val cert = try {
            ks.getCertificate(ALIAS)
        } catch (e: Exception) {
            return ClientIdentityHealth.Unavailable
        } ?: return ClientIdentityHealth.Incompatible
        val publicKey = cert.publicKey as? ECPublicKey
            ?: return ClientIdentityHealth.Incompatible
        if (!ClientIdentityMetadata.isP256(publicKey)) {
            return ClientIdentityHealth.Incompatible
        }

        val privateKey = try {
            ks.getKey(ALIAS, null) as? PrivateKey
        } catch (e: Exception) {
            return ClientIdentityHealth.Unavailable
        } ?: return ClientIdentityHealth.Incompatible

        // This deterministic authorization check identifies the exact legacy
        // key bug without relying on an exception from a live Keystore sign.
        val keyInfo = try {
            KeyFactory.getInstance(privateKey.algorithm, KEYSTORE)
                .getKeySpec(privateKey, KeyInfo::class.java)
        } catch (e: Exception) {
            return ClientIdentityHealth.Unavailable
        }
        if (KeyProperties.DIGEST_NONE !in keyInfo.digests) {
            return ClientIdentityHealth.Incompatible
        }

        return try {
            if (ClientIdentityMetadata.rawEcdsaRoundTrip(privateKey, publicKey)) {
                ClientIdentityHealth.Usable
            } else {
                // A successful signature that does not verify proves the
                // certificate and private key do not describe one identity.
                ClientIdentityHealth.Incompatible
            }
        } catch (e: Exception) {
            if (e.hasCause<KeyPermanentlyInvalidatedException>()) {
                ClientIdentityHealth.Incompatible
            } else {
                ClientIdentityHealth.Unavailable
            }
        }
    }

    private inline fun <reified T : Throwable> Throwable.hasCause(): Boolean {
        var current: Throwable? = this
        while (current != null) {
            if (current is T) return true
            current = current.cause
        }
        return false
    }

    private fun readSnapshot(ks: KeyStore): Snapshot? {
        val cert = ks.getCertificate(ALIAS) ?: return null
        return Snapshot(
            certificateDerBase64 = Base64.encodeToString(cert.encoded, Base64.NO_WRAP),
            fingerprint = ClientIdentityMetadata.fingerprint(cert.encoded),
        )
    }

    // Captures the certificate and the key managers in one synchronized
    // operation. Callers use this same object for TLS, cache identity, and the
    // /enroll body so none of those can accidentally describe different keys.
    @Synchronized
    fun tlsMaterial(): TlsMaterial? {
        cachedTlsMaterial?.let { return it }
        val identity = snapshot() ?: return null
        return try {
            val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
            kmf.init(keyStore(), null)
            TlsMaterial(
                certificateDerBase64 = identity.certificateDerBase64,
                fingerprint = identity.fingerprint,
                keyManagers = kmf.keyManagers,
            ).also { cachedTlsMaterial = it }
        } catch (e: Exception) {
            null
        }
    }

    // Key managers backed by the Keystore entry, so every TLS connection the
    // phone opens can present the client certificate when the Mac asks for it.
    @Synchronized
    fun keyManagers(): Array<KeyManager>? {
        return tlsMaterial()?.keyManagers?.clone()
    }

    // Drops the identity on unpair so the next pairing generates a fresh key
    // and the old certificate can never authenticate again.
    @Synchronized
    fun delete() {
        cachedSnapshot = null
        cachedTlsMaterial = null
        try {
            val ks = keyStore()
            if (ks.containsAlias(ALIAS)) ks.deleteEntry(ALIAS)
        } catch (e: Exception) {
            // Nothing usable to delete; unpair proceeds regardless.
        } finally {
            // Even when the Keystore is unavailable, callers asked to revoke
            // the in-memory identity and its established TLS sessions.
            notifyIdentityChanged()
        }
    }

    // Base64 DER of the client certificate, the body of the /enroll request.
    @Synchronized
    private fun snapshot(): Snapshot? {
        if (!ensure()) return null
        return cachedSnapshot
    }
}
