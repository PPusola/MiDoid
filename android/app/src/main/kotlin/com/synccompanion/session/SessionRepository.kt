package com.synccompanion.session

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.synccompanion.service.SyncService

/**
 * Value object holding the credentials and metadata for the currently active session.
 *
 * @property token      Bearer token used for WebDAV Basic-auth (username: "sync", password: this).
 * @property expiryMs   Absolute expiry timestamp in milliseconds since epoch; never 0 here
 *                      (in-memory sessions are excluded from [SessionRepository.loadActiveSession]).
 * @property sessionId  UUID identifying this session, matched against the QR payload by the Mac.
 * @property macIp      IPv4 address of the Mac that initiated the session, or `null` if unknown.
 */
data class SessionData(val token: String, val expiryMs: Long, val sessionId: String, val macIp: String?)

/**
 * Encrypted persistent storage for active session credentials and user preferences.
 *
 * All values are kept in [EncryptedSharedPreferences] backed by an AES-256-GCM master
 * key held in Android Keystore. Nothing is written to plain storage.
 *
 * **Two session modes:**
 * - **Timed** (`durationMs > 0`): [KEY_EXPIRY_MS] is set to a future absolute timestamp.
 *   Survives app restarts and auto-expires.
 * - **In-memory** (`durationMs == 0`): [KEY_EXPIRY_MS] is stored as `0L`. Treated as active
 *   until explicitly revoked, but excluded from [loadActiveSession] so it does not survive restarts.
 *
 * @param context  Used to initialize [EncryptedSharedPreferences] and to stop [SyncService].
 */
class SessionRepository(private val context: Context) {

    private val prefs = EncryptedSharedPreferences.create(
        context,
        "session_store",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    /**
     * Persists credentials for a new session, overwriting any existing values.
     *
     * If [durationMs] is `0`, [KEY_EXPIRY_MS] is stored as `0L` to mark an in-memory session.
     * Otherwise [KEY_EXPIRY_MS] is set to `System.currentTimeMillis() + durationMs`.
     *
     * @param token       Bearer token for WebDAV authentication.
     * @param sessionId   UUID matching the QR payload session identifier.
     * @param durationMs  Session length in milliseconds, or `0` for "ends on disconnect".
     * @param macIp       IPv4 address of the originating Mac.
     */
    fun authorizeSession(token: String, sessionId: String, durationMs: Long, macIp: String) {
        val expiryMs = if (durationMs > 0) System.currentTimeMillis() + durationMs else 0L
        prefs.edit()
            .putString(KEY_TOKEN, token)
            .putLong(KEY_EXPIRY_MS, expiryMs)
            .putString(KEY_SESSION_ID, sessionId)
            .putString(KEY_MAC_IP, macIp)
            .commit()
    }

    /**
     * Clears all session keys from encrypted prefs and stops [SyncService].
     * Safe to call even when no session is active — the stop intent is harmless
     * if the service is not running.
     */
    fun revokeSession() {
        prefs.edit()
            .remove(KEY_TOKEN)
            .remove(KEY_EXPIRY_MS)
            .remove(KEY_SESSION_ID)
            .remove(KEY_MAC_IP)
            .commit()
        context.stopService(Intent(context, SyncService::class.java))
    }

    /**
     * Loads and validates the active timed session. Returns `null` if:
     * - No token is stored.
     * - The session is in-memory (`expiryMs == 0`) — those are not meant to survive restarts.
     * - The session has passed its expiry timestamp — triggers [revokeSession] automatically.
     *
     * @return A [SessionData] for a valid, unexpired timed session, or `null`.
     */
    fun loadActiveSession(): SessionData? {
        val token     = prefs.getString(KEY_TOKEN, null)     ?: return null
        val sessionId = prefs.getString(KEY_SESSION_ID, null) ?: return null
        val expiryMs  = prefs.getLong(KEY_EXPIRY_MS, -1L)

        // In-memory-only sessions (durationMs == 0) don't survive restarts
        if (expiryMs == 0L) return null

        if (System.currentTimeMillis() > expiryMs) {
            revokeSession()
            return null
        }

        return SessionData(
            token = token,
            expiryMs = expiryMs,
            sessionId = sessionId,
            macIp = prefs.getString(KEY_MAC_IP, null)
        )
    }

    /**
     * Returns the raw token string from encrypted prefs, stripped of whitespace.
     * Returns `null` if no token has been stored.
     */
    fun loadToken(): String? = prefs.getString(KEY_TOKEN, null)?.trim()

    /** Returns the Mac's IPv4 address stored at session creation, or `null` if absent. */
    fun loadMacIp(): String? = prefs.getString(KEY_MAC_IP, null)

    /**
     * Persists the SAF folder URI and its display name for use by [SyncService]
     * when creating the [com.synccompanion.server.DocumentTreeStorageBackend].
     *
     * @param uri          Persisted tree URI granted by [android.provider.DocumentsContract].
     * @param displayName  Human-readable folder name shown in the Settings and dashboard UI.
     */
    fun saveSharedFolder(uri: Uri, displayName: String) {
        prefs.edit()
            .putString(KEY_SHARED_FOLDER_URI, uri.toString())
            .putString(KEY_SHARED_FOLDER_NAME, displayName)
            .commit()
    }

    /** Returns the persisted SAF folder [Uri], or `null` if the user has not selected one. */
    fun loadSharedFolderUri(): Uri? =
        prefs.getString(KEY_SHARED_FOLDER_URI, null)?.let(Uri::parse)

    /** Returns the display name of the persisted SAF folder, or `null`. */
    fun loadSharedFolderName(): String? =
        prefs.getString(KEY_SHARED_FOLDER_NAME, null)

    /** Removes the persisted SAF folder URI and display name from encrypted prefs. */
    fun clearSharedFolder() {
        prefs.edit()
            .remove(KEY_SHARED_FOLDER_URI)
            .remove(KEY_SHARED_FOLDER_NAME)
            .commit()
    }

    /**
     * Returns `true` if a token exists and [KEY_EXPIRY_MS] is exactly `0L`,
     * which is the sentinel value used for in-memory (no-persist) sessions.
     */
    fun isInMemorySession(): Boolean =
        prefs.getString(KEY_TOKEN, null) != null &&
        prefs.getLong(KEY_EXPIRY_MS, -1L) == 0L

    /**
     * Returns `true` if any kind of session is currently active.
     * Combines [isInMemorySession] and [loadActiveSession] so both session
     * modes are covered by a single boolean check.
     */
    fun isSessionActive(): Boolean = isInMemorySession() || loadActiveSession() != null

    /**
     * Returns the number of milliseconds remaining until the timed session expires.
     * Returns `0` if the session has already expired or if this is an in-memory session
     * (which has no expiry timer).
     */
    fun remainingMs(): Long {
        val expiryMs = prefs.getLong(KEY_EXPIRY_MS, -1L)
        if (expiryMs <= 0L) return 0L
        return (expiryMs - System.currentTimeMillis()).coerceAtLeast(0L)
    }

    companion object {
        private const val KEY_TOKEN      = "session_pubkey"  // key name kept for existing installs
        private const val KEY_EXPIRY_MS  = "session_expiry_ms"
        private const val KEY_SESSION_ID = "session_id"
        private const val KEY_MAC_IP = "mac_ip"
        private const val KEY_SHARED_FOLDER_URI = "shared_folder_uri"
        private const val KEY_SHARED_FOLDER_NAME = "shared_folder_name"
    }
}
