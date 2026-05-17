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
import com.synccompanion.R
import com.synccompanion.databinding.ActivitySettingsBinding
import com.synccompanion.service.SyncService
import com.synccompanion.session.SessionManager

class SettingsActivity : AppCompatActivity() {

    private lateinit var binding: ActivitySettingsBinding
    private lateinit var sessionManager: SessionManager

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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)

        sessionManager = SessionManager(this)

        binding.settingsToolbar.setNavigationOnClickListener { finish() }
        binding.btnSettingsChooseFolder.setOnClickListener { folderPicker.launch(null) }
        binding.btnSettingsAllFiles.setOnClickListener { openAllFilesSettings() }
        binding.btnSettingsAppStorage.setOnClickListener { clearSharedFolder() }
    }

    override fun onResume() {
        super.onResume()
        refreshUi()
    }

    private fun refreshUi() {
        val folderName = sessionManager.repository.loadSharedFolderName()
        binding.storageModeStatus.text = when {
            folderName != null -> getString(R.string.storage_mode_selected, folderName)
            hasAllFilesAccess() -> getString(R.string.storage_mode_all_files)
            else -> getString(R.string.storage_mode_app_storage)
        }
    }

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

    private fun hasAllFilesAccess(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()

    private fun restartServiceIfActive() {
        if (!sessionManager.isSessionActive()) return
        stopService(Intent(this, SyncService::class.java))
        startForegroundService(Intent(this, SyncService::class.java))
    }
}
