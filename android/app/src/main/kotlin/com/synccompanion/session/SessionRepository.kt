package com.synccompanion.session

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.synccompanion.service.SyncService

data class SessionData(val token: String, val expiryMs: Long, val sessionId: String)

class SessionRepository(private val context: Context) {

    private val prefs = EncryptedSharedPreferences.create(
        context,
        "session_store",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    fun authorizeSession(token: String, sessionId: String, durationMs: Long) {
        val expiryMs = if (durationMs > 0) System.currentTimeMillis() + durationMs else 0L
        prefs.edit()
            .putString(KEY_TOKEN, token)
            .putLong(KEY_EXPIRY_MS, expiryMs)
            .putString(KEY_SESSION_ID, sessionId)
            .commit()
    }

    fun revokeSession() {
        prefs.edit()
            .remove(KEY_TOKEN)
            .remove(KEY_EXPIRY_MS)
            .remove(KEY_SESSION_ID)
            .commit()
        context.stopService(Intent(context, SyncService::class.java))
    }

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

        return SessionData(token = token, expiryMs = expiryMs, sessionId = sessionId)
    }

    fun loadToken(): String? = prefs.getString(KEY_TOKEN, null)?.trim()

    fun saveSharedFolder(uri: Uri) {
        prefs.edit()
            .putString(KEY_SHARED_FOLDER_URI, uri.toString())
            .commit()
    }

    fun loadSharedFolderUri(): Uri? =
        prefs.getString(KEY_SHARED_FOLDER_URI, null)?.let(Uri::parse)

    fun clearSharedFolder() {
        prefs.edit().remove(KEY_SHARED_FOLDER_URI).commit()
    }

    fun isSessionActive(): Boolean = loadActiveSession() != null

    fun remainingMs(): Long {
        val expiryMs = prefs.getLong(KEY_EXPIRY_MS, -1L)
        if (expiryMs <= 0L) return 0L
        return (expiryMs - System.currentTimeMillis()).coerceAtLeast(0L)
    }

    companion object {
        private const val KEY_TOKEN      = "session_pubkey"  // key name kept for existing installs
        private const val KEY_EXPIRY_MS  = "session_expiry_ms"
        private const val KEY_SESSION_ID = "session_id"
        private const val KEY_SHARED_FOLDER_URI = "shared_folder_uri"
    }
}
