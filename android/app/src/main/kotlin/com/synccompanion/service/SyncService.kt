package com.synccompanion.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.synccompanion.R
import com.synccompanion.server.DocumentTreeStorageBackend
import com.synccompanion.server.FileStorageBackend
import com.synccompanion.server.StorageBackend
import com.synccompanion.server.WebDavServer
import com.synccompanion.session.SessionManager
import com.synccompanion.ui.MainActivity

/**
 * Foreground service that keeps the WebDAV server and mDNS advertisement alive
 * while a sync session is active.
 *
 * Lifecycle:
 * 1. Started by [com.synccompanion.ui.SessionDurationSheet] after the user confirms a session.
 * 2. Validates the session token, starts the persistent notification, launches [WebDavServer],
 *    and registers the device with [NsdHelper] so the Mac can discover it via Bonjour.
 * 3. Checks session expiry every [EXPIRY_CHECK_INTERVAL_MS] ms on the main thread;
 *    automatically stops if the session expires or is revoked.
 * 4. Can be stopped explicitly via the "End Session" notification action (sends [ACTION_STOP])
 *    or from [MainActivity] when the user taps "End Session".
 */
class SyncService : Service() {

    private lateinit var sessionManager: SessionManager
    private lateinit var nsdHelper: NsdHelper
    private var webDavServer: WebDavServer? = null
    // Partial wake lock — keeps the CPU running while the screen is off so
    // the WebDAV server continues accepting connections when the device is locked.
    private var wakeLock: PowerManager.WakeLock? = null

    private val handler = Handler(Looper.getMainLooper())

    /**
     * Periodic Runnable posted every [EXPIRY_CHECK_INTERVAL_MS] on the main thread.
     * Stops the service if [SessionManager.checkAndRevokeIfExpired] returns `false`
     * (i.e. the session has expired), otherwise refreshes the notification countdown label.
     */
    private val expiryCheckRunnable = object : Runnable {
        override fun run() {
            if (!sessionManager.checkAndRevokeIfExpired()) {
                stopSelf()
                return
            }
            updateNotification()
            handler.postDelayed(this, EXPIRY_CHECK_INTERVAL_MS)
        }
    }

    /** Initializes [SessionManager] and [NsdHelper]. The WebDAV server is not started here. */
    override fun onCreate() {
        super.onCreate()
        sessionManager = SessionManager(this)
        nsdHelper = NsdHelper(this)
    }

    /**
     * Handles service start intents. Two paths are supported:
     *
     * - **[ACTION_STOP]**: revokes the active session and stops the service immediately.
     * - **Normal start**: validates the session token from [SessionManager], promotes the
     *   service to foreground with a persistent notification, launches [WebDavServer] on
     *   [WebDavServer.PORT], and begins mDNS advertisement via [NsdHelper].
     *
     * Returns [START_NOT_STICKY] on any failure so Android does not attempt to restart
     * the service without a valid, unexpired session.
     *
     * @param intent   The start intent; may carry [EXTRA_IN_MEMORY_SESSION] and [EXTRA_SESSION_ID]
     *                 for sessions that should not survive a device restart.
     * @param flags    Standard service flags (unused).
     * @param startId  Unique ID for this start request (unused).
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action

        if (action == ACTION_STOP) {
            sessionManager.revokeSession()
            stopSelf()
            return START_NOT_STICKY
        }

        val session = sessionManager.repository.loadActiveSession()
        if (session == null && !isInMemorySessionActive(intent)) {
            stopSelf()
            return START_NOT_STICKY
        }

        val token = sessionManager.repository.loadToken() ?: run {
            stopSelf()
            return START_NOT_STICKY
        }

        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)

        if (webDavServer == null) {
            try {
                webDavServer = WebDavServer(createStorageBackend(), token).also { it.start() }
            } catch (e: Exception) {
                android.util.Log.e("SyncService", "WebDAV server failed to start: ${e.message}")
                sessionManager.revokeSession()
                stopSelf()
                return START_NOT_STICKY
            }
        }

        val sessionId = session?.sessionId ?: intent?.getStringExtra(EXTRA_SESSION_ID) ?: ""
        nsdHelper.register(sessionId)

        acquireWakeLock()
        handler.removeCallbacks(expiryCheckRunnable)
        handler.postDelayed(expiryCheckRunnable, EXPIRY_CHECK_INTERVAL_MS)

        return START_STICKY
    }

    /** Cancels the expiry timer, unregisters the mDNS advertisement, shuts down the WebDAV server, and releases the wake lock. */
    override fun onDestroy() {
        handler.removeCallbacks(expiryCheckRunnable)
        nsdHelper.unregister()
        webDavServer?.stop()
        releaseWakeLock()
        super.onDestroy()
    }

    /** This service does not support binding; returns `null`. */
    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Returns `true` if the start intent carries [EXTRA_IN_MEMORY_SESSION], indicating
     * an "ends on disconnect" session that was not persisted to encrypted prefs.
     */
    private fun isInMemorySessionActive(intent: Intent?): Boolean =
        intent?.getBooleanExtra(EXTRA_IN_MEMORY_SESSION, false) == true

    /**
     * Selects the appropriate [StorageBackend] based on the user's granted permissions:
     * 1. A user-selected SAF folder ([DocumentTreeStorageBackend]) if one was saved in prefs.
     * 2. Full external storage root ([FileStorageBackend]) if MANAGE_EXTERNAL_STORAGE is granted (Android 11+).
     * 3. App-private external files directory as a safe fallback requiring no special permission.
     */
    private fun createStorageBackend(): StorageBackend {
        val selectedFolder = sessionManager.repository.loadSharedFolderUri()
        if (selectedFolder != null) {
            return DocumentTreeStorageBackend(
                context = this,
                resolver = contentResolver,
                treeUri = selectedFolder,
                rootDisplayName = "MiDoid Folder"
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()) {
            return FileStorageBackend(Environment.getExternalStorageDirectory(), "Android Storage")
        }
        return FileStorageBackend(getExternalFilesDir(null) ?: filesDir, "MiDoid Storage")
    }

    /**
     * Updates the persistent notification with the current session countdown text.
     * Called every [EXPIRY_CHECK_INTERVAL_MS] by [expiryCheckRunnable].
     */
    private fun updateNotification() {
        val remaining = sessionManager.repository.remainingMs()
        val label = if (remaining > 0) {
            "Sharing files · ${sessionManager.formatRemaining(remaining)} remaining"
        } else {
            "Sharing files · tap to manage"
        }
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification(label))
    }

    private fun acquireWakeLock() {
        if (wakeLock != null) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MiDoid:SyncService").apply {
            acquire(wakeLockTimeoutMs())
        }
    }

    private fun wakeLockTimeoutMs(): Long {
        val remaining = sessionManager.repository.remainingMs()
        return if (remaining > 0L) {
            (remaining + 30_000L).coerceAtMost(MAX_WAKE_LOCK_MS)
        } else {
            MAX_WAKE_LOCK_MS
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }

    /**
     * Constructs the foreground service notification with an "Open" content intent
     * and an "End" action that sends [ACTION_STOP].
     *
     * @param contentText  Secondary text shown below the notification title.
     */
    private fun buildNotification(contentText: String = "Sharing files · tap to manage"): android.app.Notification {
        val openIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, SyncService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.notif_title))
            .setContentText(contentText)
            .setSmallIcon(R.drawable.ic_sync)
            .setContentIntent(openIntent)
            .addAction(R.drawable.ic_sync, getString(R.string.notif_action_end), stopIntent)
            .setOngoing(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    /** Creates the notification channel required for foreground services on Android 8+. */
    private fun createNotificationChannel() {
        val channel = NotificationChannel(CHANNEL_ID, getString(R.string.notif_channel_name), NotificationManager.IMPORTANCE_LOW).apply {
            description = getString(R.string.notif_channel_desc)
            setShowBadge(false)
        }
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "sync_channel"
        private const val NOTIFICATION_ID = 1

        /** How often the expiry check runs, in milliseconds. */
        private const val EXPIRY_CHECK_INTERVAL_MS = 60_000L
        private const val MAX_WAKE_LOCK_MS = 12 * 60 * 60 * 1000L

        /** Intent action that tells the service to revoke the session and shut down. */
        const val ACTION_STOP = "com.synccompanion.STOP"

        /** Intent extra carrying the session UUID for in-memory (no-persist) sessions. */
        const val EXTRA_SESSION_ID = "session_id"

        /**
         * Intent extra (Boolean) that marks a start as an in-memory-only session.
         * When `true`, [SessionManager.checkAndRevokeIfExpired] never kills the session
         * due to a missing persisted record.
         */
        const val EXTRA_IN_MEMORY_SESSION = "in_memory_session"
    }
}
