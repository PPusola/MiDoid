package com.synccompanion.session

import android.content.Context
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/**
 * Business-logic layer on top of [SessionRepository].
 *
 * Provides the UI and [com.synccompanion.service.SyncService] with a clean API for
 * checking session state, streaming the live countdown, and safely handling expiry.
 * All persistent storage is delegated to [repository].
 *
 * @param context  Forwarded to [SessionRepository] for encrypted prefs access.
 */
class SessionManager(context: Context) {

    val repository = SessionRepository(context)

    /** Returns `true` if any session — timed or in-memory — is currently active. */
    fun isSessionActive(): Boolean = repository.isSessionActive()

    /**
     * Cold [Flow] that emits the remaining session milliseconds once per second.
     * Emits `0` when the session has expired or no session exists.
     *
     * The flow loops indefinitely — collect it within a lifecycle-aware coroutine
     * scope (e.g. `lifecycleScope`) to avoid leaks.
     */
    fun remainingMs(): Flow<Long> = flow {
        while (true) {
            emit(repository.remainingMs())
            delay(1_000)
        }
    }

    /**
     * Called by [com.synccompanion.service.SyncService] on start and every 60 seconds
     * to decide whether the service should keep running.
     *
     * - **In-memory sessions** (`expiryMs == 0`): always returns `true`. These sessions
     *   have no expiry timer and must be terminated by the user explicitly.
     * - **Timed sessions**: returns `false` and calls [revokeSession] if the session
     *   is no longer active (expired or already revoked).
     *
     * @return `true` to keep [com.synccompanion.service.SyncService] running,
     *         `false` to signal it should stop itself.
     */
    fun checkAndRevokeIfExpired(): Boolean {
        // In-memory sessions (expiryMs == 0) have no timer — valid until explicitly revoked.
        if (repository.isInMemorySession()) return true

        if (repository.loadActiveSession() == null && repository.loadToken() != null) {
            repository.revokeSession()
            return false
        }
        return repository.isSessionActive()
    }

    /** Revokes the active session via [SessionRepository] and stops [com.synccompanion.service.SyncService]. */
    fun revokeSession() = repository.revokeSession()

    /**
     * Formats a millisecond duration as a compact human-readable countdown string.
     *
     * Format rules:
     * - Hours present: `"Xh YYm"` (e.g. `"2h 05m"`)
     * - Minutes only:  `"Xm YYs"` (e.g. `"14m 30s"`)
     * - Seconds only:  `"Xs"`    (e.g. `"45s"`)
     *
     * @param ms  Remaining duration in milliseconds. Must be > 0 for a meaningful result.
     * @return    A formatted string, or `"Expired"` if [ms] is 0 or negative.
     */
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
