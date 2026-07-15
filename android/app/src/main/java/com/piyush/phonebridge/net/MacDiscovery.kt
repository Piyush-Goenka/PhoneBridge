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
                        runCatching {
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

                runCatching {
                    nsd.discoverServices("_phonenotif._tcp.", NsdManager.PROTOCOL_DNS_SD, listener)
                }.onFailure { finish(null) }

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
