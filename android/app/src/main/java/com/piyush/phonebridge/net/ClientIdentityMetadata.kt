package com.piyush.phonebridge.net

import java.security.AlgorithmParameters
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

internal enum class ClientIdentityHealth {
    Usable,
    Incompatible,
    Unavailable;

    val shouldReplace: Boolean
        get() = this == Incompatible
}

// Pure identity bookkeeping kept separate from AndroidKeyStore so the
// rotation-sensitive decisions are covered by ordinary JVM tests.
internal object ClientIdentityMetadata {

    const val P256_CURVE = "secp256r1"
    private const val RAW_ECDSA = "NONEwithECDSA"
    private val rawSignProbe = ByteArray(32) { index -> (index + 1).toByte() }

    fun fingerprint(certificateDer: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(certificateDer)
            .joinToString("") { "%02x".format(it) }

    fun enrollmentMatches(
        enrolledFingerprint: String?,
        currentFingerprint: String,
    ): Boolean = enrolledFingerprint?.equals(currentFingerprint, ignoreCase = true) == true

    fun isP256(publicKey: ECPublicKey): Boolean {
        val named = AlgorithmParameters.getInstance("EC").apply {
            init(ECGenParameterSpec(P256_CURVE))
        }.getParameterSpec(java.security.spec.ECParameterSpec::class.java)
        val actual = publicKey.params
        return actual.curve == named.curve &&
            actual.generator == named.generator &&
            actual.order == named.order &&
            actual.cofactor == named.cofactor
    }

    // Deliberately uses raw ECDSA: Conscrypt hashes the TLS transcript itself
    // before asking the Keystore private key to sign it.
    @Throws(Exception::class)
    fun rawEcdsaRoundTrip(privateKey: PrivateKey, publicKey: ECPublicKey): Boolean {
        val signer = Signature.getInstance(RAW_ECDSA)
        signer.initSign(privateKey)
        signer.update(rawSignProbe)
        val signature = signer.sign()

        val verifier = Signature.getInstance(RAW_ECDSA)
        verifier.initVerify(publicKey)
        verifier.update(rawSignProbe)
        return verifier.verify(signature)
    }
}

// An OkHttp client captures its TLS key managers at construction. Every
// credential that affects that TLS session belongs in the cache key.
internal data class MacClientCacheKey(
    val token: String,
    val macFingerprint: String,
    val clientFingerprint: String,
)
