package com.synccompanion.session

import android.content.Context
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

class SessionManager(context: Context) {

    val repository = SessionRepository(context)

    fun isSessionActive(): Boolean = repository.isSessionActive()

    /** Emits remaining milliseconds every second. Emits 0 when expired or no session. */
    fun remainingMs(): Flow<Long> = flow {
        while (true) {
            emit(repository.remainingMs())
            delay(1_000)
        }
    }

    /**
     * Called on SyncService start and every 60 seconds.
     * Returns true if the session is still valid, false if it was revoked.
     */
    fun checkAndRevokeIfExpired(): Boolean {
        if (repository.loadActiveSession() == null && repository.loadToken() != null) {
            repository.revokeSession()
            return false
        }
        return repository.isSessionActive()
    }

    fun revokeSession() = repository.revokeSession()

    /** Human-readable countdown string for notification and UI labels. */
    fun formatRemaining(ms: Long): String {
        if (ms <= 0L) return "Expired"
        val totalSeconds = ms / 1000
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val seconds = totalSeconds % 60
        return when {
            hours > 0 -> "%dh %02dm".format(hours, minutes)
            minutes > 0 -> "%dm %02ds".format(minutes, seconds)
            else -> "%ds".format(seconds)
        }
    }
}
