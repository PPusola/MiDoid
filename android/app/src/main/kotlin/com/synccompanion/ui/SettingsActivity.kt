package com.synccompanion.ui

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.documentfile.provider.DocumentFile
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.synccompanion.R
import com.synccompanion.databinding.ActivitySettingsBinding
import com.synccompanion.service.SyncService
import com.synccompanion.session.SessionManager

/**
 * Settings screen for configuring which part of the Android filesystem MiDoid exposes
 * over WebDAV.
 *
 * **Three storage modes, in order of access breadth:**
 * 1. **Selected folder** — user picks a specific folder via SAF [OpenDocumentTree]; most restrictive.
 * 2. **All files** — MANAGE_EXTERNAL_STORAGE grants full device storage access (Android 11+ only).
 * 3. **App storage** — app's private external files directory; no special permission required (fallback).
 *
 * Changing the storage mode while a session is active calls [restartServiceIfActive] so [SyncService]
 * immediately picks up the new [com.synccompanion.server.StorageBackend] without requiring a new QR scan.
 */
class SettingsActivity : AppCompatActivity() {

    private lateinit var binding: ActivitySettingsBinding
    private lateinit var sessionManager: SessionManager

    /**
     * SAF folder picker launched when the user taps "Choose Folder".
     *
     * On a successful selection:
     * 1. Takes a persistable URI permission (read + write) so access survives app restarts.
     * 2. Saves the URI and folder display name to [com.synccompanion.session.SessionRepository].
     * 3. Calls [restartServiceIfActive] to apply the new storage immediately.
     * 4. Refreshes the UI to show the newly selected folder name.
     */
    private val folderPicker =
        registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            if (uri != null) {
                val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                contentResolver.takePersistableUriPermission(uri, flags)
                val displayName = DocumentFile.fromTreeUri(this, uri)?.name ?: "Selected folder"
                sessionManager.repository.saveSharedFolder(uri, displayName)
                restartServiceIfActive()
                refreshUi()
            }
        }

    /**
     * Inflates the layout, initializes [SessionManager], and wires the toolbar back button
     * and the four storage option buttons.
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)

        sessionManager = SessionManager(this)

        binding.settingsToolbar.setNavigationOnClickListener { finish() }
        binding.btnSettingsChooseFolder.setOnClickListener { folderPicker.launch(null) }
        binding.btnSettingsAllFiles.setOnClickListener { openAllFilesSettings() }
        binding.btnSettingsAppStorage.setOnClickListener { clearSharedFolder() }
        binding.btnSettingsPermissionInfo.setOnClickListener { showPermissionInfo() }
    }

    /**
     * Refreshes the storage mode status label each time the user returns to this screen.
     * Handles the case where the user grants or revokes MANAGE_EXTERNAL_STORAGE in system
     * settings while this Activity is in the background.
     */
    override fun onResume() {
        super.onResume()
        refreshUi()
    }

    /**
     * Updates the storage mode status label to reflect whichever mode is currently active:
     * selected folder name, "All files access", or "App storage (default)".
     */
    private fun refreshUi() {
        val folderName = sessionManager.repository.loadSharedFolderName()
        binding.storageModeStatus.text = when {
            folderName != null -> getString(R.string.storage_mode_selected, folderName)
            hasAllFilesAccess() -> getString(R.string.storage_mode_all_files)
            else -> getString(R.string.storage_mode_app_storage)
        }
    }

    /**
     * Removes the persisted SAF folder from both [android.content.ContentResolver]
     * (revokes the persistable URI permission so Android can reclaim it) and
     * [com.synccompanion.session.SessionRepository]. Restarts the service if active
     * so it falls back to all-files or app storage immediately.
     *
     * `runCatching` wraps the permission revocation because it may throw if the URI
     * was already revoked by the system.
     */
    private fun clearSharedFolder() {
        val uri = sessionManager.repository.loadSharedFolderUri()
        if (uri != null) {
            runCatching {
                contentResolver.releasePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            }
        }
        sessionManager.repository.clearSharedFolder()
        restartServiceIfActive()
        refreshUi()
    }

    /**
     * Opens the system settings page for MANAGE_EXTERNAL_STORAGE for this app.
     *
     * First tries the app-specific deep link (`ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION`);
     * falls back to the global all-files access list if the deep link is not supported
     * by the device's settings app. No-op on Android 10 and below.
     */
    private fun openAllFilesSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val intent = Intent(
            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
            Uri.parse("package:$packageName")
        )
        runCatching { startActivity(intent) }.getOrElse {
            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }

    /**
     * Returns `true` if MANAGE_EXTERNAL_STORAGE is currently granted.
     * Always returns `false` on Android 10 and below (the permission did not exist).
     */
    private fun hasAllFilesAccess(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()

    /**
     * Shows a Material dialog explaining the three permission levels so the user can
     * make an informed choice about how much of their device MiDoid can access.
     */
    private fun showPermissionInfo() {
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.permission_explainer_title)
            .setMessage(R.string.permission_explainer_message)
            .setPositiveButton(android.R.string.ok, null)
            .show()
    }

    /**
     * Stops then immediately restarts [SyncService] so it re-initializes its
     * [com.synccompanion.server.StorageBackend] with the updated storage configuration.
     *
     * Called after any storage mode change (folder selection, all-files toggle, or clear).
     * No-op if no session is currently active — the new backend will be picked up automatically
     * the next time the service starts.
     */
    private fun restartServiceIfActive() {
        if (!sessionManager.isSessionActive()) return
        stopService(Intent(this, SyncService::class.java))
        startForegroundService(Intent(this, SyncService::class.java))
    }
}
