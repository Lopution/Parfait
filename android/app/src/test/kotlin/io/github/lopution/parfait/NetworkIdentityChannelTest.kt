package io.github.lopution.parfait

import io.github.lopution.parfait.NetworkFacts.Transport
import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM tests for the network identity derivation. */
class NetworkIdentityChannelTest {
    private fun ip(literal: String): InetAddress = InetAddress.getByName(literal)

    private fun identity(facts: NetworkFacts) = NetworkIdentityChannel.identity(facts)

    private fun wifi(
        addresses: List<String> = emptyList(),
        gateways: List<String> = listOf("192.168.1.1"),
        dns: List<String> = listOf("192.168.1.1"),
    ) = NetworkFacts(
        Transport.LOCAL,
        addresses = addresses.map(::ip),
        gateways = gateways.map(::ip),
        dnsServers = dns.map(::ip),
    )

    @Test
    fun `the kind and the data SIM's operator name the network`() {
        val cases =
            mapOf(
                NetworkFacts(Transport.NONE) to "none",
                NetworkFacts(Transport.VPN, simOperator = "46001") to "vpn",
                NetworkFacts(Transport.CELLULAR, simOperator = "46001") to "mobile:46001",
                NetworkFacts(Transport.CELLULAR, simOperator = "46011") to "mobile:46011",
                NetworkFacts(Transport.CELLULAR, simOperator = "310260") to "mobile:310260",
                NetworkFacts(Transport.CELLULAR, simOperator = "") to "mobile",
                NetworkFacts(Transport.CELLULAR, simOperator = "46a01") to "mobile",
                NetworkFacts(Transport.CELLULAR) to "mobile",
                NetworkFacts(Transport.LOCAL) to "wifi",
            )
        for ((facts, expected) in cases) assertEquals(facts.toString(), expected, identity(facts))
    }

    @Test
    fun `a local link is named by its provider's IPv6 block, else by its router`() {
        val telecom = identity(wifi(listOf("192.168.1.5", "240e:388:1::5")))
        val telecomOtherHome =
            identity(wifi(listOf("240e:388:9f00::1"), gateways = listOf("10.0.0.1")))
        val unicom = identity(wifi(listOf("2408:8207::5")))
        // Link-local and unique-local addresses name nothing.
        val routerOnly = identity(wifi(listOf("fe80::1", "fd00::5", "192.168.1.5")))
        val sameRouterReordered =
            identity(
                wifi(
                    gateways = listOf("192.168.1.1"),
                    dns = listOf("223.5.5.5", "192.168.1.1"),
                ),
            )
        val sameRouterSorted =
            identity(wifi(dns = listOf("192.168.1.1", "223.5.5.5")))
        val otherRouter = identity(wifi(gateways = listOf("192.168.31.1")))

        assertEquals(telecom, telecomOtherHome)
        assertNotEquals(telecom, unicom)
        assertNotEquals(telecom, routerOnly)
        assertEquals(sameRouterReordered, sameRouterSorted)
        assertNotEquals(routerOnly, otherRouter)
        for (name in listOf(telecom, unicom, routerOnly, otherRouter)) {
            assertTrue(name, Regex("wifi:[0-9a-f]{8}").matches(name))
        }
    }
}
