package com.synccompanion.service

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import com.synccompanion.server.WebDavServer

/**
 * Wrapper around Android's [NsdManager] that advertises this device as a
 * WebDAV sync endpoint on the local network using DNS-SD (Bonjour).
 *
 * The Mac companion app discovers this advertisement and uses the embedded
 * `session_id` TXT record to verify it matches the QR code payload before
 * attempting a WebDAV connection.
 *
 * @param context  Used to obtain the [NsdManager] system service.
 */
class NsdHelper(private val context: Context) {

    private val nsdManager: NsdManager =
        context.getSystemService(Context.NSD_SERVICE) as NsdManager

    private var registrationListener: NsdManager.RegistrationListener? = null

    /** The actual service name assigned by the system (may differ from the requested name if there's a conflict). */
    private var registeredServiceName: String? = null

    /**
     * Registers the WebDAV service under [SERVICE_TYPE] with the given [sessionId]
     * embedded as a DNS TXT record attribute. The service is advertised on [WebDavServer.PORT].
     *
     * If a prior registration is still active it is unregistered before the new one
     * is started, ensuring only one advertisement is live at a time.
     *
     * @param sessionId  UUID identifying the active session. Embedded as the `session_id`
     *                   TXT attribute so the Mac companion can match it to the QR payload.
     */
    fun register(sessionId: String) {
        if (registrationListener != null) unregister()

        val serviceInfo = NsdServiceInfo().apply {
            serviceName = buildServiceName(sessionId)
            serviceType = SERVICE_TYPE
            port = WebDavServer.PORT
            // Include session_id in TXT record so Mac can verify it matches the QR payload
            setAttribute("session_id", sessionId)
            setAttribute("v", "1")
        }

        registrationListener = object : NsdManager.RegistrationListener {
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "NSD registration failed: $errorCode")
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "NSD unregistration failed: $errorCode")
            }

            override fun onServiceRegistered(info: NsdServiceInfo) {
                registeredServiceName = info.serviceName
                Log.i(TAG, "NSD registered as '${info.serviceName}' session=$sessionId")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.i(TAG, "NSD unregistered")
                registeredServiceName = null
            }
        }

        nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener)
    }

    /**
     * Unregisters the currently active NSD service advertisement.
     *
     * Safe to call even if no registration is active. Catches the [IllegalArgumentException]
     * Android throws when attempting to unregister a listener that was never registered
     * or has already been unregistered.
     */
    fun unregister() {
        registrationListener?.let {
            try {
                nsdManager.unregisterService(it)
            } catch (e: IllegalArgumentException) {
                Log.w(TAG, "NSD already unregistered: ${e.message}")
            }
            registrationListener = null
        }
    }

    companion object {
        private const val TAG = "NsdHelper"

        /** Bonjour service type used by both Android (advertiser) and the Mac companion app (discoverer). */
        const val SERVICE_TYPE = "_android-sync._tcp."

        private fun buildServiceName(sessionId: String): String {
            val model = Build.MODEL
                .replace(Regex("[^A-Za-z0-9_-]"), "-")
                .trim('-')
                .take(12)
                .ifEmpty { "Android" }
            val suffix = sessionId.takeLast(4).ifEmpty { "sync" }
            return "MiDoid-$model-$suffix"
        }
    }
}
