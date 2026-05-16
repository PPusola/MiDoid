package com.synccompanion.server

import android.util.Log
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class WebDavServer(private val storage: StorageBackend, private val token: String) {

    private val pool = Executors.newCachedThreadPool()
    private val running = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null

    fun start() {
        if (running.getAndSet(true)) return
        val ss = ServerSocket(PORT)
        serverSocket = ss
        pool.submit { acceptLoop(ss) }
        Log.i(TAG, "WebDAV server started on port $PORT")
    }

    fun stop() {
        running.set(false)
        serverSocket?.close()
        serverSocket = null
        Log.i(TAG, "WebDAV server stopped")
    }

    private fun acceptLoop(ss: ServerSocket) {
        try {
            while (running.get()) {
                val socket = try { ss.accept() } catch (_: Exception) { break }
                pool.submit { handle(socket) }
            }
        } finally {
            ss.close()
        }
    }

    private fun handle(socket: Socket) {
        try {
            socket.soTimeout = 30_000
            val req = HttpRequest.parse(socket.getInputStream()) ?: return
            val resp = WebDavHandler.handle(req, storage, token)
            resp.writeTo(socket.getOutputStream())
        } catch (e: Exception) {
            Log.w(TAG, "Connection error: ${e.message}")
        } finally {
            socket.close()
        }
    }

    companion object {
        const val PORT = 8080
        private const val TAG = "WebDavServer"
    }
}
