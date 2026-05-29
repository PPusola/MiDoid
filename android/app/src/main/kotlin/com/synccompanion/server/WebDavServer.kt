package com.synccompanion.server

import android.util.Log
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Embedded TCP server that accepts WebDAV connections on port [PORT].
 *
 * Each accepted connection is dispatched to a bounded thread pool so several
 * simultaneous transfers can run without letting clients create unlimited
 * threads. The server is intentionally single-lifecycle: call
 * [start] once and [stop] once; re-use after stopping is not supported.
 *
 * @param storage  The [StorageBackend] all WebDAV requests are forwarded to.
 * @param token    Session token forwarded to [WebDavHandler] for per-request authentication.
 */
class WebDavServer(private val storage: StorageBackend, private val token: String) {

    /** Bounded worker pool for WebDAV requests. */
    private val pool: ExecutorService = Executors.newFixedThreadPool(MAX_WORKER_THREADS)

    /** Atomic flag shared between the accept loop and [stop] to signal shutdown. */
    private val running = AtomicBoolean(false)

    private var serverSocket: ServerSocket? = null

    /**
     * Binds [PORT] and starts the accept loop on a pool thread.
     * Idempotent — a second call while the server is already running is a no-op.
     *
     * @throws java.io.IOException if the port is already in use by another process.
     */
    fun start() {
        if (running.getAndSet(true)) return
        val ss = ServerSocket(PORT)
        serverSocket = ss
        pool.submit { acceptLoop(ss) }
        Log.i(TAG, "WebDAV server started on port $PORT")
    }

    /**
     * Closes the [ServerSocket] and clears the running flag.
     * The accept loop exits on the next iteration when it catches the resulting exception.
     * In-flight connections already dispatched to pool threads complete normally.
     */
    fun stop() {
        running.set(false)
        serverSocket?.close()
        serverSocket = null
        pool.shutdown()
        Log.i(TAG, "WebDAV server stopped")
    }

    /**
     * Blocks accepting connections from [ss] until [running] becomes false or
     * the socket is closed by [stop]. Each accepted [Socket] is immediately
     * submitted to the thread pool so this loop is never blocked by slow clients.
     *
     * @param ss  The bound [ServerSocket] to accept from.
     */
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

    /**
     * Handles a single client connection end-to-end: parses the HTTP request,
     * dispatches it through [WebDavHandler], writes the response, and closes the socket.
     *
     * A 30-second read timeout prevents idle or stalled clients from holding a
     * pool thread indefinitely.
     *
     * @param socket  The accepted client [Socket].
     */
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
        /** TCP port the WebDAV server binds to. macOS mounts it as `http://<device-ip>:8080`. */
        const val PORT = 8080
        private const val TAG = "WebDavServer"
        private const val MAX_WORKER_THREADS = 8
    }
}
