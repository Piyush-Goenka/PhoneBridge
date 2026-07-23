package com.piyush.phonebridge.net

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

internal data class ReachabilityCheck(
    val generation: Long,
    val successVersionAtStart: Long,
)

// One process-wide source of truth for the Home screen. Foreground probes and
// the notification service both feed it, because a successful real delivery
// is stronger evidence than an older failed probe.
internal class ReachabilityTracker {
    private val _reachable = MutableStateFlow<Boolean?>(null)
    val reachable: StateFlow<Boolean?> = _reachable.asStateFlow()

    private var generation = 0L
    private var successVersion = 0L

    @Synchronized
    fun beginCheck(): ReachabilityCheck {
        generation += 1
        _reachable.value = null
        return ReachabilityCheck(generation, successVersion)
    }

    @Synchronized
    fun completeCheck(check: ReachabilityCheck, reachedMac: Boolean) {
        // A newer foreground check or an unpair operation owns the state now.
        if (check.generation != generation) return

        if (reachedMac) {
            successVersion += 1
            _reachable.value = true
        } else if (check.successVersionAtStart == successVersion) {
            // Do not let an older failed probe overwrite a notification that
            // successfully reached the Mac while that probe was in flight.
            _reachable.value = false
        }
    }

    @Synchronized
    fun recordSuccess() {
        successVersion += 1
        _reachable.value = true
    }

    @Synchronized
    fun reset() {
        generation += 1
        successVersion += 1
        _reachable.value = null
    }
}

object MacReachability {
    private val tracker = ReachabilityTracker()

    val reachable: StateFlow<Boolean?> = tracker.reachable

    internal fun beginCheck(): ReachabilityCheck = tracker.beginCheck()

    internal fun completeCheck(check: ReachabilityCheck, reachedMac: Boolean) {
        tracker.completeCheck(check, reachedMac)
    }

    fun recordSuccess() {
        tracker.recordSuccess()
    }

    fun reset() {
        tracker.reset()
    }
}
