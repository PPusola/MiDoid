package com.synccompanion.service

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import com.synccompanion.server.WebDavServer

class NsdHelper(private val context: Context) {

    private val nsdManager: NsdManager =
        context.getSystemService(Context.NSD_SERVICE) as NsdManager

    private var registrationListener: NsdManager.RegistrationListener? = null
    private var registeredServiceName: String? = null

    fun register(sessionId: String) {
        if (registrationListener != null) unregister()

        val serviceInfo = NsdServiceInfo().apply {
            serviceName = "AndroidSyncDevice"
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
        const val SERVICE_TYPE = "_android-sync._tcp."
    }
}
