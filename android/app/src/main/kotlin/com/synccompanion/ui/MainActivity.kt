package com.synccompanion.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.view.View
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.synccompanion.R
import com.synccompanion.databinding.ActivityMainBinding
import com.synccompanion.security.SecurityChecks
import com.synccompanion.session.SessionManager
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var sessionManager: SessionManager
    private var lastAllFilesAccess = false

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* no-op on denial */ }

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
        binding.btnOpenSettings.setOnClickListener { startActivity(Intent(this, SettingsActivity::class.java)) }
        binding.btnEndSession.setOnClickListener { onEndSessionTapped() }

        observeSession()
    }

    override fun onResume() {
        super.onResume()
        val currentAllFilesAccess = hasAllFilesAccess()
        if (currentAllFilesAccess != lastAllFilesAccess) {
            lastAllFilesAccess = currentAllFilesAccess
        }
        refreshUi()
    }

    private fun observeSession() {
        lifecycleScope.launch {
            sessionManager.remainingMs().collect { remainingMs ->
                refreshDashboardStatsUi()
                if (remainingMs <= 0L && !sessionManager.isSessionActive()) {
                    showIdleState()
                } else {
                    showConnectedState(remainingMs)
                }
            }
        }
    }

    private fun refreshUi() {
        refreshDashboardStatsUi()
        if (sessionManager.isSessionActive()) {
            showConnectedState(sessionManager.repository.remainingMs())
        } else {
            showIdleState()
        }
    }

    private fun refreshDashboardStatsUi() {
        val macIp = sessionManager.repository.loadMacIp()
        val remainingMs = sessionManager.repository.remainingMs()
        val hasSelectedFolder = sessionManager.repository.loadSharedFolderUri() != null
        val hasAllFilesAccess = hasAllFilesAccess()

        binding.statMacValue.text = if (macIp.isNullOrBlank()) {
            getString(R.string.stat_mac_waiting)
        } else {
            getString(R.string.stat_mac_connected, macIp)
        }

        binding.statSessionValue.text = if (remainingMs > 0) {
            getString(R.string.stat_session_active, sessionManager.formatRemaining(remainingMs))
        } else {
            getString(R.string.stat_session_idle)
        }

        binding.statStorageValue.text = when {
            hasSelectedFolder -> getString(
                R.string.stat_storage_selected,
                sessionManager.repository.loadSharedFolderName() ?: "Selected folder"
            )
            hasAllFilesAccess -> getString(R.string.stat_storage_all_files)
            else -> getString(R.string.stat_storage_app)
        }

        binding.statPrivacyValue.setText(R.string.stat_privacy_local)
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

    private fun hasAllFilesAccess(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()
}
