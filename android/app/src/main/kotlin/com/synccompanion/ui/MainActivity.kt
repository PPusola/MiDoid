package com.synccompanion.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.view.View
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.documentfile.provider.DocumentFile
import androidx.lifecycle.lifecycleScope
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.synccompanion.R
import com.synccompanion.databinding.ActivityMainBinding
import com.synccompanion.security.SecurityChecks
import com.synccompanion.service.SyncService
import com.synccompanion.session.SessionManager
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var sessionManager: SessionManager
    private var lastAllFilesAccess = false

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* no-op on denial */ }

    private val folderPicker =
        registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            if (uri != null) {
                persistFolderAccess(uri)
                val displayName = DocumentFile.fromTreeUri(this, uri)?.name ?: "Selected folder"
                sessionManager.repository.saveSharedFolder(uri, displayName)
                restartServiceIfActive()
                refreshUi()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        sessionManager = SessionManager(this)
        lastAllFilesAccess = hasAllFilesAccess()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }

        binding.fabScan.setOnClickListener { onScanTapped() }
        binding.btnSettings.setOnClickListener { startActivity(Intent(this, SettingsActivity::class.java)) }
        binding.btnEndSession.setOnClickListener { onEndSessionTapped() }
        binding.btnChooseFolder.setOnClickListener { folderPicker.launch(null) }
        binding.btnAllowAllFiles.setOnClickListener { openAllFilesSettings() }
        binding.btnClearFolder.setOnClickListener { onClearFolderTapped() }
        binding.btnPermissionInfo.setOnClickListener { showPermissionInfo() }

        observeSession()
    }

    override fun onResume() {
        super.onResume()
        val currentAllFilesAccess = hasAllFilesAccess()
        if (currentAllFilesAccess != lastAllFilesAccess) {
            lastAllFilesAccess = currentAllFilesAccess
            restartServiceIfActive()
        }
        refreshUi()
    }

    private fun observeSession() {
        lifecycleScope.launch {
            sessionManager.remainingMs().collect { remainingMs ->
                if (remainingMs <= 0L && !sessionManager.isSessionActive()) {
                    showIdleState()
                } else {
                    showConnectedState(remainingMs)
                }
            }
        }
    }

    private fun refreshUi() {
        refreshSharedFolderUi()
        refreshSecurityUi()
        if (sessionManager.isSessionActive()) {
            showConnectedState(sessionManager.repository.remainingMs())
        } else {
            showIdleState()
        }
    }

    private fun refreshSharedFolderUi() {
        val hasSelectedFolder = sessionManager.repository.loadSharedFolderUri() != null
        val hasAllFilesAccess = hasAllFilesAccess()
        binding.sharedFolderLabel.text =
            when {
                hasSelectedFolder -> getString(
                    R.string.shared_folder_selected,
                    sessionManager.repository.loadSharedFolderName() ?: "Selected folder"
                )
                hasAllFilesAccess -> getString(R.string.shared_folder_all_files)
                else -> getString(R.string.shared_folder_default)
            }
        binding.btnAllowAllFiles.visibility = if (hasSelectedFolder || hasAllFilesAccess) View.GONE else View.VISIBLE
        binding.btnClearFolder.visibility = if (hasSelectedFolder) View.VISIBLE else View.GONE
    }

    private fun refreshSecurityUi() {
        val macIp = sessionManager.repository.loadMacIp()
        val remainingMs = sessionManager.repository.remainingMs()
        val hasSelectedFolder = sessionManager.repository.loadSharedFolderUri() != null
        val hasAllFilesAccess = hasAllFilesAccess()

        binding.connectedMacLabel.text = if (macIp.isNullOrBlank()) {
            getString(R.string.security_mac_waiting)
        } else {
            getString(R.string.security_mac_connected, macIp)
        }

        binding.sessionExpiryLabel.text = if (remainingMs > 0) {
            getString(R.string.security_expiry_active, sessionManager.formatRemaining(remainingMs))
        } else {
            getString(R.string.security_expiry_idle)
        }

        binding.permissionStatusLabel.setText(
            when {
                hasSelectedFolder -> R.string.security_permission_selected
                hasAllFilesAccess -> R.string.security_permission_all_files
                else -> R.string.security_permission_default
            }
        )
    }

    private fun showIdleState() {
        binding.statusIcon.setImageResource(R.drawable.ic_sync)
        binding.statusIcon.clearAnimation()
        binding.statusTitle.setText(R.string.status_idle)
        binding.statusSubtitle.setText(R.string.status_idle_subtitle)
        binding.countdownChip.visibility = View.GONE
        binding.btnEndSession.visibility = View.GONE
        binding.fabScan.extend()
    }

    private fun showConnectedState(remainingMs: Long) {
        binding.statusIcon.setImageResource(R.drawable.ic_sync)
        binding.statusTitle.setText(R.string.status_connected)

        if (remainingMs > 0) {
            binding.statusSubtitle.text = getString(
                R.string.status_connected_subtitle,
                sessionManager.repository.loadMacIp() ?: "your Mac"
            )
            binding.countdownChip.visibility = View.VISIBLE
            binding.countdownChip.text = sessionManager.formatRemaining(remainingMs)
        } else {
            binding.statusSubtitle.setText(R.string.status_connected_until_disconnect)
            binding.countdownChip.visibility = View.GONE
        }

        binding.btnEndSession.visibility = View.VISIBLE
        binding.fabScan.shrink()
    }

    private fun onScanTapped() {
        if (SecurityChecks.isRooted()) {
            MaterialAlertDialogBuilder(this)
                .setTitle(R.string.root_warning_title)
                .setMessage(R.string.root_warning_message)
                .setPositiveButton(R.string.proceed_anyway) { _, _ -> launchScanner() }
                .setNegativeButton(android.R.string.cancel, null)
                .show()
        } else {
            launchScanner()
        }
    }

    private fun launchScanner() {
        startActivity(Intent(this, QrScanActivity::class.java))
    }

    private fun onEndSessionTapped() {
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.end_session_title)
            .setMessage(R.string.end_session_message)
            .setPositiveButton(R.string.end_session) { _, _ ->
                sessionManager.revokeSession()
                showIdleState()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun persistFolderAccess(uri: Uri) {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        contentResolver.takePersistableUriPermission(uri, flags)
    }

    private fun onClearFolderTapped() {
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

    private fun showPermissionInfo() {
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.permission_explainer_title)
            .setMessage(R.string.permission_explainer_message)
            .setPositiveButton(android.R.string.ok, null)
            .show()
    }

    private fun hasAllFilesAccess(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()

    private fun restartServiceIfActive() {
        if (!sessionManager.isSessionActive()) return
        stopService(Intent(this, SyncService::class.java))
        startForegroundService(Intent(this, SyncService::class.java))
    }
}
