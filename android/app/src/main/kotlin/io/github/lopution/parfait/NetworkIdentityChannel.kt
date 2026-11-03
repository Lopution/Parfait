package io.github.lopution.parfait

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import java.net.Inet6Address
import java.net.InetAddress
import java.security.MessageDigest

/** What the default network's identity is derived from; built by hand in JVM tests. */
internal data class NetworkFacts(
    val transport: Transport,
    /** MCC+MNC of the SIM that carries mobile data, when the system knows it. */
    val simOperator: String? = null,
    val addresses: List<InetAddress> = emptyList(),
    val gateways: List<InetAddress> = emptyList(),
    val dnsServers: List<InetAddress> = emptyList(),
) {
    enum class Transport { NONE, VPN, CELLULAR, LOCAL }
}

/**
 * Names the default network, so the app keeps what it learns about routes
 * per network: `none`, `vpn`, `mobile:<mccmnc>` (a data-SIM switch is a new
 * network) or `wifi:<fingerprint>` for Wi-Fi, ethernet and other local
 * links. Which route reaches pixiv depends on the carrier, and Wi-Fi only
 * names it through its addresses: SSIDs need the location permission.
 *
 * No permission is needed, and no address appears in an identity: the
 * fingerprint is a hash.
 */
object NetworkIdentityChannel {
    private const val EVENT_CHANNEL = "parfait/network_identity/events"
    private val OPERATOR = Regex("[0-9]{5,6}")

    fun configure(context: Context, engine: FlutterEngine) {
        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(DefaultNetworkStreamHandler(context.applicationContext))
    }

    internal fun identity(facts: NetworkFacts): String =
        when (facts.transport) {
            NetworkFacts.Transport.NONE -> "none"
            NetworkFacts.Transport.VPN -> "vpn"
            NetworkFacts.Transport.CELLULAR ->
                facts.simOperator?.takeIf(OPERATOR::matches)?.let { "mobile:$it" } ?: "mobile"
            NetworkFacts.Transport.LOCAL ->
                localFingerprint(facts)?.let { "wifi:$it" } ?: "wifi"
        }

    /**
     * The first 32 bits of a global IPv6 address are the provider's block
     * (in China 240e Telecom, 2408 Unicom, 2409 Mobile); without one, the
     * gateways and DNS servers name the router.
     */
    private fun localFingerprint(facts: NetworkFacts): String? {
        val prefix = facts.addresses.firstOrNull(::isGlobalIpv6)?.address?.copyOf(4)
        val source =
            when {
                prefix != null -> "v6:" + prefix.toHex()
                facts.gateways.isEmpty() && facts.dnsServers.isEmpty() -> return null
                else ->
                    "lan:" + facts.gateways.mapNotNull { it.hostAddress }.sorted() +
                        "|" + facts.dnsServers.mapNotNull { it.hostAddress }.sorted()
            }
        val digest = MessageDigest.getInstance("SHA-256").digest(source.toByteArray())
        return digest.copyOf(4).toHex()
    }

    /** Global unicast, 2000::/3: not link-local, not unique-local. */
    private fun isGlobalIpv6(address: InetAddress) =
        address is Inet6Address && (address.address[0].toInt() and 0xE0) == 0x20

    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }
}

/**
 * Follows the default network on the main looper: the current identity on
 * listen, then every change. Android follows a new default network's
 * `onAvailable` with its capabilities and link properties, so an identity
 * is sent once both are known; repeats (signal strength changes) are not.
 */
private class DefaultNetworkStreamHandler(
    private val context: Context,
) : EventChannel.StreamHandler {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private var callback: ConnectivityManager.NetworkCallback? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        val sink = events ?: return
        val connectivity = connectivity
        if (connectivity == null) {
            sink.error("network_identity_unavailable", "no ConnectivityManager", null)
            return
        }
        var last: String? = null
        fun send(identity: String) {
            if (identity == last) return
            last = identity
            sink.success(identity)
        }
        val next =
            object : ConnectivityManager.NetworkCallback() {
                private var current: Network? = null
                private var capabilities: NetworkCapabilities? = null
                private var link: LinkProperties? = null

                override fun onAvailable(network: Network) {
                    if (network == current) return
                    current = network
                    capabilities = null
                    link = null
                }

                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                    if (network != current) return
                    capabilities = caps
                    sendFacts()
                }

                override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                    if (network != current) return
                    link = properties
                    sendFacts()
                }

                override fun onLost(network: Network) {
                    if (network != current) return
                    current = null
                    send("none")
                }

                private fun sendFacts() {
                    val caps = capabilities ?: return
                    val properties = link ?: return
                    send(NetworkIdentityChannel.identity(facts(caps, properties)))
                }
            }
        callback = next
        connectivity.registerDefaultNetworkCallback(next, Handler(Looper.getMainLooper()))
        // With no default network the callback stays silent until one comes.
        if (connectivity.activeNetwork == null) send("none")
    }

    override fun onCancel(arguments: Any?) {
        callback?.let { connectivity?.unregisterNetworkCallback(it) }
        callback = null
    }

    private fun facts(caps: NetworkCapabilities, link: LinkProperties): NetworkFacts {
        val transport =
            when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> NetworkFacts.Transport.VPN
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ->
                    NetworkFacts.Transport.CELLULAR
                else -> NetworkFacts.Transport.LOCAL
            }
        return NetworkFacts(
            transport = transport,
            simOperator =
                if (transport == NetworkFacts.Transport.CELLULAR) dataSimOperator() else null,
            addresses = link.linkAddresses.map { it.address },
            gateways = link.routes.filter { it.isDefaultRoute }.mapNotNull { it.gateway },
            dnsServers = link.dnsServers,
        )
    }

    /** The data SIM's operator; reading it needs no permission. */
    private fun dataSimOperator(): String? {
        val telephony = context.getSystemService(TelephonyManager::class.java) ?: return null
        val subscription = SubscriptionManager.getDefaultDataSubscriptionId()
        val manager =
            if (SubscriptionManager.isValidSubscriptionId(subscription)) {
                telephony.createForSubscriptionId(subscription)
            } else {
                telephony
            }
        return manager.simOperator
    }
}
