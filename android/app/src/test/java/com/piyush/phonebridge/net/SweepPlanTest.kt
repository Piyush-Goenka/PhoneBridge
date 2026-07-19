package com.piyush.phonebridge.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SweepPlanTest {

    @Test
    fun fullSlash24EnumeratesNeighboursOnly() {
        val hosts = SweepPlan.candidates("192.168.1.37", 24, cachedHost = null)
        assertEquals(253, hosts.size)
        assertTrue("192.168.1.1" in hosts)
        assertTrue("192.168.1.254" in hosts)
        assertFalse("192.168.1.37" in hosts)   // own address
        assertFalse("192.168.1.0" in hosts)    // network address
        assertFalse("192.168.1.255" in hosts)  // broadcast address
    }

    @Test
    fun cachedHostProbedFirst() {
        val hosts = SweepPlan.candidates("192.168.1.37", 24, cachedHost = "192.168.1.50")
        assertEquals("192.168.1.50", hosts.first())
        assertEquals(253, hosts.size)
        assertEquals(1, hosts.count { it == "192.168.1.50" })
    }

    @Test
    fun cachedHostOutsideSubnetIgnored() {
        val hosts = SweepPlan.candidates("192.168.1.37", 24, cachedHost = "10.0.0.5")
        assertEquals("192.168.1.1", hosts.first())
    }

    @Test
    fun subnetsWiderThanSlash23AreRefused() {
        assertTrue(SweepPlan.candidates("10.1.2.3", 16, null).isEmpty())
        assertTrue(SweepPlan.candidates("10.1.2.3", 22, null).isEmpty())
        assertEquals(509, SweepPlan.candidates("10.1.2.3", 23, null).size)
    }

    @Test
    fun tinySubnetWorks() {
        assertEquals(listOf("192.168.1.1"), SweepPlan.candidates("192.168.1.2", 30, null))
    }

    @Test
    fun garbageInputYieldsNothing() {
        assertTrue(SweepPlan.candidates("not-an-ip", 24, null).isEmpty())
        assertTrue(SweepPlan.candidates("192.168.1.300", 24, null).isEmpty())
        assertTrue(SweepPlan.candidates("192.168.1.1", 31, null).isEmpty())
    }

    @Test
    fun privateRangesRecognised() {
        assertTrue(SweepPlan.isPrivateIpv4("10.0.0.1"))
        assertTrue(SweepPlan.isPrivateIpv4("172.16.0.1"))
        assertTrue(SweepPlan.isPrivateIpv4("172.31.255.254"))
        assertTrue(SweepPlan.isPrivateIpv4("192.168.29.107"))
        assertFalse(SweepPlan.isPrivateIpv4("172.32.0.1"))
        assertFalse(SweepPlan.isPrivateIpv4("8.8.8.8"))
        assertFalse(SweepPlan.isPrivateIpv4("garbage"))
    }

    @Test
    fun cooldownGatesRepeatSweeps() {
        assertTrue(SweepPlan.shouldSweep(now = 1_000_000, lastFailureAt = 0))
        assertFalse(SweepPlan.shouldSweep(now = 1_000_000, lastFailureAt = 999_000))
        assertTrue(SweepPlan.shouldSweep(now = 1_000_000, lastFailureAt = 910_000 - 1))
    }
}
