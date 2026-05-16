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
import androidx.core.app.NotificationCompat
import com.synccompanion.R
import com.synccompanion.server.DocumentTreeStorageBackend
import com.synccompanion.server.FileStorageBackend
import com.synccompanion.server.StorageBackend
import com.synccompanion.server.WebDavServer
import com.synccompanion.session.SessionManager
import com.synccompanion.ui.MainActivity

class SyncService : Service() {

    private lateinit var sessionManager: SessionManager
    private lateinit var nsdHelper: NsdHelper
    private var webDavServer: WebDavServer? = null

    private val handler = Handler(Looper.getMainLooper())
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

    override fun onCreate() {
        super.onCreate()
        sessionManager = SessionManager(this)
        nsdHelper = NsdHelper(this)
    }

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

        webDavServer = WebDavServer(createStorageBackend(), token).also { it.start() }

        val sessionId = session?.sessionId ?: intent?.getStringExtra(EXTRA_SESSION_ID) ?: ""
        nsdHelper.register(sessionId)

        handler.postDelayed(expiryCheckRunnable, EXPIRY_CHECK_INTERVAL_MS)

        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(expiryCheckRunnable)
        nsdHelper.unregister()
        webDavServer?.stop()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun isInMemorySessionActive(intent: Intent?): Boolean =
        intent?.getBooleanExtra(EXTRA_IN_MEMORY_SESSION, false) == true

    private fun createStorageBackend(): StorageBackend {
        val selectedFolder = sessionManager.repository.loadSharedFolderUri()
        if (selectedFolder != null) {
            return DocumentTreeStorageBackend(
                context = this,
                resolver = contentResolver,
                treeUri = selectedFolder,
                rootDisplayName = "Android Folder"
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()) {
            return FileStorageBackend(Environment.getExternalStorageDirectory(), "Android Storage")
        }
        return FileStorageBackend(getExternalFilesDir(null) ?: filesDir)
    }

    private fun updateNotification() {
        val remaining = sessionManager.repository.remainingMs()
        val label = if (remaining > 0) {
            "Active · ${sessionManager.formatRemaining(remaining)} remaining"
        } else {
            "Active · ends on disconnect"
        }
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification(label))
    }

    private fun buildNotification(contentText: String = "Tap to view session"): android.app.Notification {
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
            .setContentTitle("Mac Sync Active")
            .setContentText(contentText)
            .setSmallIcon(R.drawable.ic_sync)
            .setContentIntent(openIntent)
            .addAction(R.drawable.ic_sync, "End Session", stopIntent)
            .setOngoing(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(CHANNEL_ID, "Mac Sync", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shows while phone is connected to Mac"
            setShowBadge(false)
        }
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "sync_channel"
        private const val NOTIFICATION_ID = 1
        private const val EXPIRY_CHECK_INTERVAL_MS = 60_000L
        const val ACTION_STOP = "com.synccompanion.STOP"
        const val EXTRA_SESSION_ID = "session_id"
        const val EXTRA_IN_MEMORY_SESSION = "in_memory_session"
    }
}
