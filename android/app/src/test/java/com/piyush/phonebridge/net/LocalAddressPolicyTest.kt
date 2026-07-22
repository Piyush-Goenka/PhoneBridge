package com.piyush.phonebridge.net

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress

class LocalAddressPolicyTest {

    private fun allowed(address: String): Boolean =
        LocalAddressPolicy.isAllowed(InetAddress.getByName(address))

    @Test
    fun acceptsPrivateLinkLocalAndVpnAddresses() {
        assertTrue(allowed("10.0.0.1"))
        assertTrue(allowed("172.31.255.254"))
        assertTrue(allowed("192.168.1.10"))
        assertTrue(allowed("169.254.10.4"))
        assertTrue(allowed("100.100.10.1"))
        assertTrue(allowed("fd12:3456::1"))
        assertTrue(allowed("fe80::1"))
    }

    @Test
    fun rejectsPublicLoopbackAndUnspecifiedAddresses() {
        assertFalse(allowed("8.8.8.8"))
        assertFalse(allowed("1.1.1.1"))
        assertFalse(allowed("127.0.0.1"))
        assertFalse(allowed("0.0.0.0"))
        assertFalse(allowed("::1"))
        assertFalse(allowed("2001:4860:4860::8888"))
    }
}
