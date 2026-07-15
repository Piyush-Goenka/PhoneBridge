# Android Relay App Implementation Plan (Plan 2 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Kotlin Android app that listens to all device notifications, filters them (structural noise, allowlist, dedup), and relays survivors to the Mac bridge over pinned-certificate HTTPS, with QR pairing and phone-side dismissal forwarding.

**Architecture:** A thin `NotificationListenerService` feeds pure, JVM-testable filter and dedup logic, then a coroutine delivers via OkHttp with a fingerprint-pinning TrustManager. `NsdManager` resolves the Mac on demand (cached host tried first). One Compose screen: status, QR scan, allowlist, send log.

**Tech Stack:** Kotlin 2.1.20, AGP 8.9.2, Gradle 8.13 (wrapper), compileSdk/targetSdk 35, minSdk 26, Jetpack Compose (BOM 2025.02.00), OkHttp 4.12, zxing-android-embedded 4.3.0 (QR scan), JUnit 4 + MockWebServer + okhttp-tls for JVM tests.

**Spec:** `docs/superpowers/specs/2026-07-14-android-mac-notification-bridge-design.md`
**Prerequisite:** Plan 1 (Mac app) complete; the Mac app is how end-to-end acceptance runs.

## Global Constraints

- Never use an em dash in any file, code comment, or document. Use a comma, colon, or parentheses.
- Never run `git commit` or `git push` without asking Piyush and receiving explicit permission at that moment. If not granted, skip the commit and continue.
- No global or system-wide installs. Gradle comes via the project wrapper; if no Gradle exists to generate the wrapper, download a Gradle distribution zip into the session scratchpad (a local download, not an install) and use its `bin/gradle` once.
- Battery principle: the app does work only inside notification events. No polling, no persistent sockets, no background discovery, no WorkManager.
- Best-effort delivery: try cached host, one mDNS re-resolve, one retry, then drop and log. No queue, no database.
- Wire contract is `protocol.md` at repo root. If code and protocol.md disagree, fix the code.
- Android SDK is at `~/Library/Android/sdk` (compileSdk 35 platform already installed). Java 23 is the JDK, Kotlin/Java target is 17.
- Package namespace: `com.piyush.phonebridge`.

---

### Task 1: Gradle scaffold that assembles an empty app

**Files:**
- Create: `android/settings.gradle.kts`
- Create: `android/build.gradle.kts`
- Create: `android/gradle.properties`
- Create: `android/local.properties` (gitignored)
- Create: `android/app/build.gradle.kts`
- Create: `android/app/src/main/AndroidManifest.xml` (minimal; extended in later tasks)
- Create: `android/gradlew` + `android/gradle/wrapper/*` (generated)

**Interfaces:**
- Produces: `./gradlew :app:assembleDebug` and `./gradlew :app:testDebugUnitTest` both succeed. Later tasks only add source files and dependencies.

- [ ] **Step 1: Write settings.gradle.kts**

```kotlin
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "PhoneBridge"
include(":app")
```

- [ ] **Step 2: Write root build.gradle.kts**

```kotlin
plugins {
    id("com.android.application") version "8.9.2" apply false
    id("org.jetbrains.kotlin.android") version "2.1.20" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.20" apply false
}
```

- [ ] **Step 3: Write gradle.properties**

```properties
org.gradle.jvmargs=-Xmx2g
android.useAndroidX=true
kotlin.code.style=official
```

- [ ] **Step 4: Write local.properties**

```properties
sdk.dir=/Users/piyushgoenka/Library/Android/sdk
```

- [ ] **Step 5: Write app/build.gradle.kts**

```kotlin
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.piyush.phonebridge"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.piyush.phonebridge"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.02.00"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("com.squareup.okhttp3:okhttp-tls:4.12.0")
}
```

(`org.json:json` as a test dependency gives JVM unit tests the real `JSONObject` implementation instead of Android's not-mocked stubs.)

- [ ] **Step 6: Write the minimal manifest**

`android/app/src/main/AndroidManifest.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="PhoneBridge" />
</manifest>
```

- [ ] **Step 7: Generate the Gradle wrapper**

No system Gradle exists. Download a distribution into the scratchpad and use it once:

```bash
SCRATCH="/private/tmp/claude-501/-Users-piyushgoenka-Desktop-New-Plans-Phone-Notification/0a81219b-f28f-467a-a3ad-1f879b9a763b/scratchpad"
curl -sSL https://services.gradle.org/distributions/gradle-8.13-bin.zip -o "$SCRATCH/gradle-8.13.zip"
unzip -q -o "$SCRATCH/gradle-8.13.zip" -d "$SCRATCH"
cd android
"$SCRATCH/gradle-8.13/bin/gradle" wrapper --gradle-version 8.13
```

Expected: `BUILD SUCCESSFUL`, and `android/gradlew`, `android/gradle/wrapper/gradle-wrapper.jar`, `android/gradle/wrapper/gradle-wrapper.properties` exist.

- [ ] **Step 8: Assemble**

Run: `cd android && ./gradlew :app:assembleDebug`
Expected: first run downloads dependencies, then `BUILD SUCCESSFUL`. APK at `android/app/build/outputs/apk/debug/app-debug.apk`.

- [ ] **Step 9: Ask Piyush for permission to commit; if granted:**

```bash
git add android/ && git commit -m "scaffold(android): gradle project assembling empty app"
```

(`android/local.properties` is gitignored; verify with `git status` that it is not staged.)

---

### Task 2: Model, NotificationFilter, DedupCache (pure JVM, TDD)

**Files:**
- Create: `android/app/src/main/java/com/piyush/phonebridge/model/RelayNotification.kt`
- Create: `android/app/src/main/java/com/piyush/phonebridge/filter/NotificationFilter.kt`
- Create: `android/app/src/main/java/com/piyush/phonebridge/filter/DedupCache.kt`
- Test: `android/app/src/test/java/com/piyush/phonebridge/filter/NotificationFilterTest.kt`
- Test: `android/app/src/test/java/com/piyush/phonebridge/filter/DedupCacheTest.kt`

**Interfaces:**
- Produces:
  - `data class RelayNotification(key: String, pkg: String, appName: String, title: String, text: String, postedAt: Long, isOngoing: Boolean, isGroupSummary: Boolean, category: String?)`
  - `object NotificationFilter { fun shouldForward(n: RelayNotification, allowlist: Set<String>): Boolean }`
  - `class DedupCache(windowMillis: Long = 30_000) { fun isDuplicate(n: RelayNotification, now: Long): Boolean }` (thread-safe; recording happens inside `isDuplicate`)
- No Android imports anywhere in these files. Category strings are the raw values of `Notification.CATEGORY_*` constants.

- [ ] **Step 1: Write RelayNotification.kt** (needed for the tests to compile)

```kotlin
package com.piyush.phonebridge.model

data class RelayNotification(
    val key: String,
    val pkg: String,
    val appName: String,
    val title: String,
    val text: String,
    val postedAt: Long,
    val isOngoing: Boolean,
    val isGroupSummary: Boolean,
    val category: String?,
)
```

- [ ] **Step 2: Write the failing tests**

`NotificationFilterTest.kt`:

```kotlin
package com.piyush.phonebridge.filter

import com.piyush.phonebridge.model.RelayNotification
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationFilterTest {

    private val allowlist = setOf("com.whatsapp", "com.spotify.music", "com.google.android.apps.maps")

    private fun notif(
        pkg: String = "com.whatsapp",
        title: String = "Alice",
        text: String = "hi",
        isOngoing: Boolean = false,
        isGroupSummary: Boolean = false,
        category: String? = null,
    ) = RelayNotification(
        key = "0|$pkg|1|null|10", pkg = pkg, appName = pkg,
        title = title, text = text, postedAt = 0L,
        isOngoing = isOngoing, isGroupSummary = isGroupSummary, category = category)

    @Test
    fun forwardsPlainMessageFromAllowlistedApp() {
        assertTrue(NotificationFilter.shouldForward(notif(), allowlist))
    }

    @Test
    fun dropsAppNotOnAllowlist() {
        assertFalse(NotificationFilter.shouldForward(notif(pkg = "com.random.game"), allowlist))
    }

    @Test
    fun dropsSpotifyMediaNotification() {
        // Media playback: ongoing, category transport.
        val spotify = notif(
            pkg = "com.spotify.music", title = "Song", text = "Artist",
            isOngoing = true, category = "transport")
        assertFalse(NotificationFilter.shouldForward(spotify, allowlist))
    }

    @Test
    fun dropsTransportCategoryEvenWhenNotOngoing() {
        val spotify = notif(pkg = "com.spotify.music", category = "transport")
        assertFalse(NotificationFilter.shouldForward(spotify, allowlist))
    }

    @Test
    fun dropsMapsNavigationUpdate() {
        val maps = notif(
            pkg = "com.google.android.apps.maps",
            title = "Turn right", text = "onto Main St",
            isOngoing = true, category = "navigation")
        assertFalse(NotificationFilter.shouldForward(maps, allowlist))
    }

    @Test
    fun dropsGroupSummary() {
        assertFalse(NotificationFilter.shouldForward(notif(isGroupSummary = true), allowlist))
    }

    @Test
    fun dropsProgressServiceAndSysCategories() {
        for (category in listOf("progress", "service", "sys")) {
            assertFalse(
                "category $category should drop",
                NotificationFilter.shouldForward(notif(category = category), allowlist))
        }
    }

    @Test
    fun dropsBlankNotification() {
        assertFalse(NotificationFilter.shouldForward(notif(title = "", text = " "), allowlist))
    }

    @Test
    fun forwardsMessageCategoryFromAllowlistedApp() {
        assertTrue(NotificationFilter.shouldForward(notif(category = "msg"), allowlist))
    }
}
```

`DedupCacheTest.kt`:

```kotlin
package com.piyush.phonebridge.filter

import com.piyush.phonebridge.model.RelayNotification
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DedupCacheTest {

    private fun notif(pkg: String = "com.whatsapp", title: String = "Alice", text: String = "hi") =
        RelayNotification(
            key = "k", pkg = pkg, appName = pkg, title = title, text = text,
            postedAt = 0L, isOngoing = false, isGroupSummary = false, category = null)

    @Test
    fun firstSightIsNotDuplicate() {
        val cache = DedupCache()
        assertFalse(cache.isDuplicate(notif(), now = 1_000L))
    }

    @Test
    fun samePostWithinWindowIsDuplicate() {
        // WhatsApp re-posting the identical notification moments later.
        val cache = DedupCache(windowMillis = 30_000L)
        assertFalse(cache.isDuplicate(notif(), now = 1_000L))
        assertTrue(cache.isDuplicate(notif(), now = 2_000L))
    }

    @Test
    fun samePostAfterWindowIsFresh() {
        val cache = DedupCache(windowMillis = 30_000L)
        assertFalse(cache.isDuplicate(notif(), now = 1_000L))
        assertFalse(cache.isDuplicate(notif(), now = 40_000L))
    }

    @Test
    fun differentTextIsNotDuplicate() {
        val cache = DedupCache()
        assertFalse(cache.isDuplicate(notif(text = "hi"), now = 1_000L))
        assertFalse(cache.isDuplicate(notif(text = "hi again"), now = 2_000L))
    }

    @Test
    fun differentPackageSameTextIsNotDuplicate() {
        val cache = DedupCache()
        assertFalse(cache.isDuplicate(notif(pkg = "a", text = "hi"), now = 1_000L))
        assertFalse(cache.isDuplicate(notif(pkg = "b", text = "hi"), now = 2_000L))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd android && ./gradlew :app:testDebugUnitTest`
Expected: compilation FAILS with unresolved reference `NotificationFilter` and `DedupCache`.

- [ ] **Step 4: Implement NotificationFilter.kt**

```kotlin
package com.piyush.phonebridge.filter

import com.piyush.phonebridge.model.RelayNotification

object NotificationFilter {

    // Raw values of Notification.CATEGORY_TRANSPORT, _PROGRESS, _NAVIGATION,
    // _SERVICE, _SYSTEM, kept as strings so this file stays JVM-pure.
    private val droppedCategories = setOf("transport", "progress", "navigation", "service", "sys")

    fun shouldForward(n: RelayNotification, allowlist: Set<String>): Boolean {
        if (n.isOngoing) return false
        if (n.isGroupSummary) return false
        if (n.category in droppedCategories) return false
        if (n.pkg !in allowlist) return false
        if (n.title.isBlank() && n.text.isBlank()) return false
        return true
    }
}
```

- [ ] **Step 5: Implement DedupCache.kt**

```kotlin
package com.piyush.phonebridge.filter

import com.piyush.phonebridge.model.RelayNotification

class DedupCache(private val windowMillis: Long = 30_000L) {

    private val seen = HashMap<Int, Long>()

    @Synchronized
    fun isDuplicate(n: RelayNotification, now: Long): Boolean {
        seen.entries.removeIf { now - it.value > windowMillis }
        val fingerprint = "${n.pkg}|${n.title}|${n.text}".hashCode()
        val duplicate = seen.containsKey(fingerprint)
        seen[fingerprint] = now
        return duplicate
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd android && ./gradlew :app:testDebugUnitTest`
Expected: `BUILD SUCCESSFUL`, 14 tests passing.

- [ ] **Step 7: Ask Piyush for permission to commit; if granted:**

```bash
git add android/ && git commit -m "feat(android): notification filter and dedup cache"
```

---

### Task 3: PairingStore (prefs + QR payload parsing, TDD on parsing)

**Files:**
- Create: `android/app/src/main/java/com/piyush/phonebridge/pairing/QrPayload.kt`
- Create: `android/app/src/main/java/com/piyush/phonebridge/pairing/PairingStore.kt`
- Test: `android/app/src/test/java/com/piyush/phonebridge/pairing/QrPayloadTest.kt`

**Interfaces:**
- Produces:
  - `data class QrPayload(host: String, port: Int, token: String, fingerprint: String) { companion object { fun parse(json: String): QrPayload? } }` (pure, JVM-testable; returns null on any malformed input)
  - `class PairingStore(context: Context)` with `var token: String?`, `var fingerprint: String?`, `var host: String?`, `var port: Int`, `var allowlist: Set<String>`, `var mirroringEnabled: Boolean`, `val isPaired: Boolean`, `fun apply(qr: QrPayload)` backed by `SharedPreferences("pairing", MODE_PRIVATE)` (app-sandboxed storage; acceptable for the token per spec threat model)

- [ ] **Step 1: Write the failing test**

`QrPayloadTest.kt`:

```kotlin
package com.piyush.phonebridge.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QrPayloadTest {

    private val valid = """
        {"v":1,"host":"Piyushs-MacBook.local","port":52735,
         "token":"abc123","fp":"deadbeef"}
    """.trimIndent()

    @Test
    fun parsesValidPayload() {
        val p = QrPayload.parse(valid)!!
        assertEquals("Piyushs-MacBook.local", p.host)
        assertEquals(52735, p.port)
        assertEquals("abc123", p.token)
        assertEquals("deadbeef", p.fingerprint)
    }

    @Test
    fun rejectsWrongVersion() {
        assertNull(QrPayload.parse(valid.replace("\"v\":1", "\"v\":2")))
    }

    @Test
    fun rejectsMissingField() {
        assertNull(QrPayload.parse("""{"v":1,"host":"x","port":1,"token":"t"}"""))
    }

    @Test
    fun rejectsGarbage() {
        assertNull(QrPayload.parse("not json at all"))
        assertNull(QrPayload.parse(""))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd android && ./gradlew :app:testDebugUnitTest`
Expected: compilation FAILS, unresolved reference `QrPayload`.

- [ ] **Step 3: Implement QrPayload.kt**

```kotlin
package com.piyush.phonebridge.pairing

import org.json.JSONException
import org.json.JSONObject

data class QrPayload(
    val host: String,
    val port: Int,
    val token: String,
    val fingerprint: String,
) {
    companion object {
        fun parse(json: String): QrPayload? = try {
            val obj = JSONObject(json)
            if (obj.getInt("v") != 1) null
            else QrPayload(
                host = obj.getString("host"),
                port = obj.getInt("port"),
                token = obj.getString("token"),
                fingerprint = obj.getString("fp").lowercase(),
            )
        } catch (e: JSONException) {
            null
        }
    }
}
```

- [ ] **Step 4: Implement PairingStore.kt**

```kotlin
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
        get() = prefs.getStringSet("allowlist", emptySet()) ?: emptySet()
        set(value) = prefs.edit().putStringSet("allowlist", value).apply()

    var mirroringEnabled: Boolean
        get() = prefs.getBoolean("mirroring", true)
        set(value) = prefs.edit().putBoolean("mirroring", value).apply()

    val isPaired: Boolean
        get() = token != null && fingerprint != null

    fun apply(qr: QrPayload) {
        token = qr.token
        fingerprint = qr.fingerprint
        host = qr.host
        port = qr.port
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd android && ./gradlew :app:testDebugUnitTest`
Expected: `BUILD SUCCESSFUL`, 18 tests passing.

- [ ] **Step 6: Ask Piyush for permission to commit; if granted:**

```bash
git add android/ && git commit -m "feat(android): pairing store and QR payload parsing"
```

---

### Task 4: MacClient (pinned-fingerprint HTTPS, TDD against MockWebServer)

**Files:**
- Create: `android/app/src/main/java/com/piyush/phonebridge/net/MacClient.kt`
- Test: `android/app/src/test/java/com/piyush/phonebridge/net/MacClientTest.kt`

**Interfaces:**
- Consumes: nothing Android-specific (plain Kotlin + OkHttp; JVM-testable).
- Produces:

```kotlin
class MacClient(token: String, fingerprintHex: String) {
    sealed interface SendResult {
        data class Ok(val needIcon: Boolean) : SendResult
        object AuthFailed : SendResult
        data class Failed(val reason: String) : SendResult
    }
    fun postNotify(host: String, port: Int, json: String): SendResult
    fun postIcon(host: String, port: Int, json: String): SendResult
    fun postDismiss(host: String, port: Int, json: String): SendResult
}
```

  - TLS: custom `X509TrustManager` accepting exactly one leaf certificate, the one whose DER SHA-256 equals `fingerprintHex`. Hostname verification disabled (the pin replaces it). Timeouts 3 s connect / 3 s read. A fingerprint mismatch surfaces as `Failed("certificate fingerprint mismatch, re-pair needed")`.

- [ ] **Step 1: Write the failing test**

`MacClientTest.kt`:

```kotlin
package com.piyush.phonebridge.net

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.security.MessageDigest

class MacClientTest {

    private lateinit var server: MockWebServer
    private lateinit var fingerprint: String

    @Before
    fun setUp() {
        val cert = HeldCertificate.Builder()
            .addSubjectAlternativeName("localhost")
            .build()
        fingerprint = MessageDigest.getInstance("SHA-256")
            .digest(cert.certificate.encoded)
            .joinToString("") { "%02x".format(it) }
        val certs = HandshakeCertificates.Builder()
            .heldCertificate(cert)
            .build()
        server = MockWebServer()
        server.useHttps(certs.sslSocketFactory(), false)
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun acceptsPinnedCertAndParsesNeedIcon() {
        server.enqueue(MockResponse().setBody("""{"needIcon":true}"""))
        val client = MacClient("tok", fingerprint)
        val result = client.postNotify(server.hostName, server.port, "{}")
        assertEquals(MacClient.SendResult.Ok(needIcon = true), result)
        val recorded = server.takeRequest()
        assertEquals("Bearer tok", recorded.getHeader("Authorization"))
        assertEquals("/notify", recorded.path)
    }

    @Test
    fun needIconFalseParsed() {
        server.enqueue(MockResponse().setBody("""{"needIcon":false}"""))
        val client = MacClient("tok", fingerprint)
        assertEquals(
            MacClient.SendResult.Ok(needIcon = false),
            client.postNotify(server.hostName, server.port, "{}"))
    }

    @Test
    fun rejectsWrongFingerprint() {
        server.enqueue(MockResponse().setBody("{}"))
        val client = MacClient("tok", "ab".repeat(32))
        val result = client.postNotify(server.hostName, server.port, "{}")
        assertTrue(result is MacClient.SendResult.Failed)
    }

    @Test
    fun http401IsAuthFailed() {
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"unauthorized"}"""))
        val client = MacClient("wrong", fingerprint)
        assertEquals(
            MacClient.SendResult.AuthFailed,
            client.postNotify(server.hostName, server.port, "{}"))
    }

    @Test
    fun connectionRefusedIsFailed() {
        val port = server.port
        server.shutdown()
        val client = MacClient("tok", fingerprint)
        assertTrue(client.postNotify("localhost", port, "{}") is MacClient.SendResult.Failed)
    }

    @Test
    fun dismissHitsDismissPath() {
        server.enqueue(MockResponse().setBody("{}"))
        val client = MacClient("tok", fingerprint)
        client.postDismiss(server.hostName, server.port, """{"key":"k"}""")
        assertEquals("/dismiss", server.takeRequest().path)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd android && ./gradlew :app:testDebugUnitTest`
Expected: compilation FAILS, unresolved reference `MacClient`.

- [ ] **Step 3: Implement MacClient.kt**

```kotlin
package com.piyush.phonebridge.net

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

class MacClient(private val token: String, fingerprintHex: String) {

    sealed interface SendResult {
        data class Ok(val needIcon: Boolean) : SendResult
        object AuthFailed : SendResult
        data class Failed(val reason: String) : SendResult
    }

    private val jsonType = "application/json".toMediaType()
    private val client: OkHttpClient

    init {
        val pin = fingerprintHex.lowercase()
        val trustManager = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {
                throw CertificateException("client certificates not supported")
            }

            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                val leaf = chain.firstOrNull()
                    ?: throw CertificateException("empty certificate chain")
                val fp = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
                    .joinToString("") { "%02x".format(it) }
                if (fp != pin) {
                    throw CertificateException("certificate fingerprint mismatch, re-pair needed")
                }
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        }
        val sslContext = SSLContext.getInstance("TLS").apply {
            init(null, arrayOf(trustManager), null)
        }
        client = OkHttpClient.Builder()
            .sslSocketFactory(sslContext.socketFactory, trustManager)
            .hostnameVerifier { _, _ -> true }
            .connectTimeout(3, TimeUnit.SECONDS)
            .readTimeout(3, TimeUnit.SECONDS)
            .writeTimeout(3, TimeUnit.SECONDS)
            .build()
    }

    fun postNotify(host: String, port: Int, json: String): SendResult =
        post(host, port, "/notify", json)

    fun postIcon(host: String, port: Int, json: String): SendResult =
        post(host, port, "/icon", json)

    fun postDismiss(host: String, port: Int, json: String): SendResult =
        post(host, port, "/dismiss", json)

    private fun post(host: String, port: Int, path: String, json: String): SendResult {
        val request = Request.Builder()
            .url("https://$host:$port$path")
            .header("Authorization", "Bearer $token")
            .post(json.toRequestBody(jsonType))
            .build()
        return try {
            client.newCall(request).execute().use { response ->
                when {
                    response.code == 401 -> SendResult.AuthFailed
                    !response.isSuccessful -> SendResult.Failed("HTTP ${response.code}")
                    else -> {
                        val body = response.body?.string() ?: ""
                        SendResult.Ok(needIcon = body.contains("\"needIcon\":true"))
                    }
                }
            }
        } catch (e: Exception) {
            SendResult.Failed(e.message ?: e.javaClass.simpleName)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd android && ./gradlew :app:testDebugUnitTest`
Expected: `BUILD SUCCESSFUL`, 24 tests passing.

- [ ] **Step 5: Ask Piyush for permission to commit; if granted:**

```bash
git add android/ && git commit -m "feat(android): pinned-fingerprint HTTPS client"
```

---

### Task 5: MacDiscovery (on-demand NsdManager resolution)

**Files:**
- Create: `android/app/src/main/java/com/piyush/phonebridge/net/MacDiscovery.kt`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `class MacDiscovery(context: Context) { suspend fun discover(timeoutMillis: Long = 4_000): Pair<String, Int>? }` returning `(hostAddress, port)` of the first resolved `_phonenotif._tcp.` service, or null on timeout. Discovery starts on call and always stops before returning (no background browsing, per the battery principle).
- Framework-bound, so no JVM unit test; correctness is exercised in Task 7's acceptance run.

- [ ] **Step 1: Implement MacDiscovery.kt**

```kotlin
package com.piyush.phonebridge.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume

class MacDiscovery(context: Context) {

    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager

    suspend fun discover(timeoutMillis: Long = 4_000): Pair<String, Int>? =
        withTimeoutOrNull(timeoutMillis) {
            suspendCancellableCoroutine { continuation ->
                val done = AtomicBoolean(false)
                var listenerRef: NsdManager.DiscoveryListener? = null

                // Resumes at most once and always stops discovery first, so no
                // background browsing ever outlives this call.
                fun finish(result: Pair<String, Int>?) {
                    if (done.compareAndSet(false, true)) {
                        listenerRef?.let { runCatching { nsd.stopServiceDiscovery(it) } }
                        if (continuation.isActive) continuation.resume(result)
                    }
                }

                val listener = object : NsdManager.DiscoveryListener {
                    override fun onServiceFound(info: NsdServiceInfo) {
                        @Suppress("DEPRECATION")
                        nsd.resolveService(info, object : NsdManager.ResolveListener {
                            override fun onServiceResolved(resolved: NsdServiceInfo) {
                                val host = resolved.host?.hostAddress
                                if (host != null) finish(host to resolved.port)
                            }

                            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                                // Keep waiting; another onServiceFound may resolve
                                // before the timeout fires.
                            }
                        })
                    }

                    override fun onServiceLost(info: NsdServiceInfo) {}
                    override fun onDiscoveryStarted(serviceType: String) {}
                    override fun onDiscoveryStopped(serviceType: String) {}

                    override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                        finish(null)
                    }

                    override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
                }
                listenerRef = listener

                nsd.discoverServices("_phonenotif._tcp.", NsdManager.PROTOCOL_DNS_SD, listener)

                continuation.invokeOnCancellation {
                    // Timeout path: withTimeoutOrNull cancels us; stop discovery
                    // but do not resume (the coroutine machinery handles it).
                    if (done.compareAndSet(false, true)) {
                        runCatching { nsd.stopServiceDiscovery(listener) }
                    }
                }
            }
        }
}
```

- [ ] **Step 2: Compile**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: `BUILD SUCCESSFUL` (a deprecation warning on `resolveService` is expected and suppressed).

- [ ] **Step 3: Ask Piyush for permission to commit; if granted:**

```bash
git add android/ && git commit -m "feat(android): on-demand mDNS discovery of the Mac"
```

---

### Task 6: SendLog, icon pipeline, NotificationRelayService (the orchestrator)

**Files:**
- Create: `android/app/src/main/java/com/piyush/phonebridge/relay/SendLog.kt`
- Create: `android/app/src/main/java/com/piyush/phonebridge/relay/AppIcons.kt`
- Create: `android/app/src/main/java/com/piyush/phonebridge/relay/NotificationRelayService.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`

**Interfaces:**
- Consumes: `RelayNotification`, `NotificationFilter`, `DedupCache` (Task 2), `PairingStore` (Task 3), `MacClient` (Task 4), `MacDiscovery` (Task 5).
- Produces:
  - `object SendLog { data class Entry(time: Long, appName: String, title: String, outcome: String); val entries: StateFlow<List<Entry>>; fun add(appName: String, title: String, outcome: String) }` (newest first, capped at 50; UI reads this in Task 7)
  - `object AppIcons { fun pngAndHash(pm: PackageManager, pkg: String): Pair<ByteArray, String>? }` (128 px PNG plus `"sha256:<hex>"`, memoized per package)
  - The registered `NotificationRelayService` with delivery policy: cached host first, one mDNS re-resolve on failure, then drop and log. Dismissals forwarded only for keys this session actually delivered.

- [ ] **Step 1: Write SendLog.kt**

```kotlin
package com.piyush.phonebridge.relay

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

object SendLog {
    data class Entry(
        val time: Long,
        val appName: String,
        val title: String,
        val outcome: String,
    )

    private val _entries = MutableStateFlow<List<Entry>>(emptyList())
    val entries: StateFlow<List<Entry>> = _entries

    fun add(appName: String, title: String, outcome: String) {
        _entries.value =
            (listOf(Entry(System.currentTimeMillis(), appName, title, outcome)) + _entries.value)
                .take(50)
    }
}
```

- [ ] **Step 2: Write AppIcons.kt**

```kotlin
package com.piyush.phonebridge.relay

import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

object AppIcons {

    private val cache = ConcurrentHashMap<String, Pair<ByteArray, String>>()

    fun pngAndHash(pm: PackageManager, pkg: String): Pair<ByteArray, String>? {
        cache[pkg]?.let { return it }
        return try {
            val drawable = pm.getApplicationIcon(pkg)
            val size = 128
            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            val png = out.toByteArray()
            val hex = MessageDigest.getInstance("SHA-256").digest(png)
                .joinToString("") { "%02x".format(it) }
            val result = png to "sha256:$hex"
            cache[pkg] = result
            result
        } catch (e: Exception) {
            null
        }
    }
}
```

- [ ] **Step 3: Write NotificationRelayService.kt**

```kotlin
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
        val store = PairingStore(this)
        if (!store.isPaired || !store.mirroringEnabled) return

        val notification = extract(sbn) ?: return
        if (!NotificationFilter.shouldForward(notification, store.allowlist)) return
        if (dedup.isDuplicate(notification, System.currentTimeMillis())) return

        scope.launch { deliver(notification, store) }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (!deliveredKeys.remove(sbn.key)) return
        val store = PairingStore(this)
        if (!store.isPaired) return

        scope.launch {
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
```

- [ ] **Step 4: Register the service in the manifest**

Replace `android/app/src/main/AndroidManifest.xml` with:

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.CAMERA" />

    <queries>
        <intent>
            <action android:name="android.intent.action.MAIN" />
            <category android:name="android.intent.category.LAUNCHER" />
        </intent>
    </queries>

    <application android:label="PhoneBridge">
        <service
            android:name=".relay.NotificationRelayService"
            android:exported="false"
            android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">
            <intent-filter>
                <action android:name="android.service.notification.NotificationListenerService" />
            </intent-filter>
        </service>
    </application>
</manifest>
```

- [ ] **Step 5: Build and run all unit tests**

Run: `cd android && ./gradlew :app:assembleDebug :app:testDebugUnitTest`
Expected: `BUILD SUCCESSFUL`, all 24 unit tests still passing.

- [ ] **Step 6: Ask Piyush for permission to commit; if granted:**

```bash
git add android/ && git commit -m "feat(android): notification relay service with delivery policy"
```

---

### Task 7: UI (Compose single screen) and MainActivity

**Files:**
- Create: `android/app/src/main/java/com/piyush/phonebridge/ui/MainActivity.kt`
- Create: `android/app/src/main/java/com/piyush/phonebridge/ui/MainScreen.kt`
- Modify: `android/app/src/main/AndroidManifest.xml` (add the activity)

**Interfaces:**
- Consumes: `PairingStore`, `QrPayload` (Task 3), `SendLog` (Task 6).
- Produces: the launcher activity. Sections top to bottom: notification access status with an enable button (deep link to `ACTION_NOTIFICATION_LISTENER_SETTINGS`), pairing status with a scan button (zxing `ScanContract`), mirroring toggle, app allowlist (launcher apps with checkboxes), recent sends list.

- [ ] **Step 1: Write MainActivity.kt**

```kotlin
package com.piyush.phonebridge.ui

import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.core.app.NotificationManagerCompat
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.piyush.phonebridge.pairing.PairingStore
import com.piyush.phonebridge.pairing.QrPayload

class MainActivity : ComponentActivity() {

    private lateinit var store: PairingStore
    private val paired = mutableStateOf(false)
    private val accessGranted = mutableStateOf(false)

    private val scanLauncher = registerForActivityResult(ScanContract()) { result ->
        val contents = result.contents ?: return@registerForActivityResult
        val payload = QrPayload.parse(contents)
        if (payload == null) {
            Toast.makeText(this, "Not a PhoneBridge QR code", Toast.LENGTH_LONG).show()
        } else {
            store.apply(payload)
            paired.value = true
            Toast.makeText(this, "Paired with ${payload.host}", Toast.LENGTH_LONG).show()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = PairingStore(this)
        setContent {
            MaterialTheme {
                MainScreen(
                    store = store,
                    paired = paired,
                    accessGranted = accessGranted,
                    onEnableAccess = {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    },
                    onScanQr = {
                        scanLauncher.launch(
                            ScanOptions()
                                .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                .setPrompt("Scan the QR from the Mac menu bar app")
                                .setBeepEnabled(false)
                                .setOrientationLocked(true))
                    },
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        paired.value = store.isPaired
        accessGranted.value = NotificationManagerCompat
            .getEnabledListenerPackages(this)
            .contains(packageName)
    }
}
```

- [ ] **Step 2: Write MainScreen.kt**

```kotlin
package com.piyush.phonebridge.ui

import android.content.Intent
import android.content.pm.PackageManager
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.piyush.phonebridge.pairing.PairingStore
import com.piyush.phonebridge.relay.SendLog
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class AppEntry(val pkg: String, val label: String)

fun launcherApps(pm: PackageManager): List<AppEntry> {
    val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
    return pm.queryIntentActivities(intent, 0)
        .map { AppEntry(it.activityInfo.packageName, it.loadLabel(pm).toString()) }
        .distinctBy { it.pkg }
        .sortedBy { it.label.lowercase() }
}

@Composable
fun MainScreen(
    store: PairingStore,
    paired: MutableState<Boolean>,
    accessGranted: MutableState<Boolean>,
    onEnableAccess: () -> Unit,
    onScanQr: () -> Unit,
) {
    val context = LocalContext.current
    val apps = remember { launcherApps(context.packageManager) }
    var allowlist by remember { mutableStateOf(store.allowlist) }
    var mirroring by remember { mutableStateOf(store.mirroringEnabled) }
    val log by SendLog.entries.collectAsState()
    val timeFormat = remember { SimpleDateFormat("HH:mm:ss", Locale.US) }

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Status", style = MaterialTheme.typography.titleMedium)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            if (accessGranted.value) "Notification access: granted"
                            else "Notification access: needed",
                            modifier = Modifier.weight(1f))
                        if (!accessGranted.value) {
                            Button(onClick = onEnableAccess) { Text("Enable") }
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            if (paired.value) "Paired with ${store.host ?: "Mac"}"
                            else "Not paired",
                            modifier = Modifier.weight(1f))
                        Button(onClick = onScanQr) {
                            Text(if (paired.value) "Re-pair" else "Scan QR")
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Mirroring", modifier = Modifier.weight(1f))
                        Switch(checked = mirroring, onCheckedChange = {
                            mirroring = it
                            store.mirroringEnabled = it
                        })
                    }
                }
            }
        }

        item {
            Text("Apps to mirror", style = MaterialTheme.typography.titleMedium)
        }
        items(apps, key = { it.pkg }) { app ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Checkbox(
                    checked = app.pkg in allowlist,
                    onCheckedChange = { checked ->
                        allowlist = if (checked) allowlist + app.pkg else allowlist - app.pkg
                        store.allowlist = allowlist
                    })
                Text(app.label)
            }
        }

        item {
            HorizontalDivider()
            Text("Recent sends", style = MaterialTheme.typography.titleMedium)
        }
        if (log.isEmpty()) {
            item { Text("Nothing sent yet", style = MaterialTheme.typography.bodySmall) }
        }
        items(log) { entry ->
            Text(
                "${timeFormat.format(Date(entry.time))}  ${entry.appName}: " +
                    "${entry.title.take(30)}  [${entry.outcome}]",
                style = MaterialTheme.typography.bodySmall)
        }
    }
}
```

- [ ] **Step 3: Add the activity to the manifest**

Inside `<application>`, before the `<service>` element, add:

```xml
        <activity
            android:name=".ui.MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
```

- [ ] **Step 4: Build and test**

Run: `cd android && ./gradlew :app:assembleDebug :app:testDebugUnitTest`
Expected: `BUILD SUCCESSFUL`, all unit tests passing.

- [ ] **Step 5: Ask Piyush for permission to commit; if granted:**

```bash
git add android/ && git commit -m "feat(android): pairing and allowlist UI"
```

---

### Task 8: End-to-end acceptance (manual, needs Piyush, the phone, and the Mac app running)

**Files:** none (checklist only).

**Interfaces:**
- Consumes: `app-debug.apk` (Task 7), running `PhoneBridge.app` from Plan 1.

- [ ] **Step 1: Install on the phone**

Phone plugged in with USB debugging enabled (Settings, Developer options). Then:

```bash
~/Library/Android/sdk/platform-tools/adb devices
~/Library/Android/sdk/platform-tools/adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

Expected: device listed as `device` (not `unauthorized`), then `Success`.

- [ ] **Step 2: Grant notification access**

Open PhoneBridge on the phone, tap Enable, toggle PhoneBridge on in the Android settings screen that opens, confirm the warning dialog. Back in the app, status shows "Notification access: granted".

- [ ] **Step 3: Pair**

Mac menu bar, "Show pairing QR". Phone: Scan QR, point at the Mac screen. Expect toast "Paired with <hostname>" and status "Paired".

- [ ] **Step 4: Allowlist a test app**

Tick WhatsApp (or any messaging app) in "Apps to mirror".

- [ ] **Step 5: The acceptance matrix** (phone and Mac on the same Wi-Fi)

| # | Action | Expected |
|---|---|---|
| 1 | Receive a WhatsApp message | Mac banner within about a second: title is the sender, subtitle WhatsApp, WhatsApp icon thumbnail. Phone log shows "sent" |
| 2 | Clear that notification on the phone | The banner leaves the Mac's Notification Center |
| 3 | Receive a notification from a non-allowlisted app | Nothing on the Mac, nothing in the log |
| 4 | Play music in a media app | No mirrored banner (structural filter) |
| 5 | Toggle Mirroring off on the phone, message again | Nothing sent (no log entry, no banner). Toggle back on |
| 6 | Quit the Mac app, message again | Phone log shows "dropped: Mac not found" after a few seconds. No crash, nothing queued |
| 7 | Relaunch the Mac app, message again | Delivery works again (cached host or re-resolve) |
| 8 | Turn phone Wi-Fi off (cellular only), message again | Log shows dropped; nothing arrives later when Wi-Fi returns (no queue, by design) |

- [ ] **Step 6: Battery sanity check**

After a few hours of normal use: Android Settings, Battery, PhoneBridge should show negligible usage. This validates the event-driven principle.

- [ ] **Step 7: Ask Piyush for permission to commit any fixes made during acceptance; if granted, commit them with descriptive messages.**

---

## Plan 2 done criteria

- `./gradlew :app:testDebugUnitTest` passes (filter, dedup, QR parsing, pinned-TLS client).
- The acceptance matrix in Task 8 passes on real hardware.
- Battery usage is negligible after hours of normal phone use.
