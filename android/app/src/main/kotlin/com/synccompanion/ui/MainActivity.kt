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
import com.google.android.material.snackbar.Snackbar
import com.synccompanion.R
import com.synccompanion.databinding.ActivityMainBinding
import com.synccompanion.security.SecurityChecks
import com.synccompanion.service.SyncService
import com.synccompanion.session.SessionManager
import com.synccompanion.transfer.TransferEvents
import kotlinx.coroutines.launch

/**
 * Main dashboard screen. Displays the current session status alongside four stat tiles:
 * Mac IP address, session countdown, storage mode, and privacy indicator.
 *
 * Observes [SessionManager.remainingMs] as a live Flow so the countdown chip and
 * idle/connected state transitions happen automatically without polling or manual refreshes.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var sessionManager: SessionManager

    /** Tracks the MANAGE_EXTERNAL_STORAGE state at last resume to detect background changes. */
    private var lastAllFilesAccess = false

    /**
     * Runtime permission launcher for POST_NOTIFICATIONS (required on Android 13+).
     * Denial is silently accepted — notification permission is not critical to core function.
     */
    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* no-op on denial */ }

    /**
     * Inflates the layout, initializes [SessionManager], requests notification permission
     * on Android 13+, wires button click listeners, and starts the session Flow observer.
     */
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
        binding.btnOpenSettings.setOnClickListener { startActivity(Intent(this, SettingsActivity::class.java)) }
        binding.btnEndSession.setOnClickListener { onEndSessionTapped() }

        observeSession()
        observeIncomingTransfers()
    }

    /**
     * Re-checks MANAGE_EXTERNAL_STORAGE on return from the system settings screen
     * (the user may have granted or revoked it while the app was in the background)
     * and refreshes all UI tiles to reflect any permission change.
     */
    override fun onResume() {
        super.onResume()
        val currentAllFilesAccess = hasAllFilesAccess()
        if (currentAllFilesAccess != lastAllFilesAccess) {
            lastAllFilesAccess = currentAllFilesAccess
        }
        refreshUi()
        ensureActiveServiceRunning()
    }

    private fun ensureActiveServiceRunning() {
        if (!sessionManager.isSessionActive()) return
        val sessionId = sessionManager.repository.loadSessionId() ?: return
        val intent = Intent(this, SyncService::class.java).apply {
            if (sessionManager.repository.isInMemorySession()) {
                putExtra(SyncService.EXTRA_IN_MEMORY_SESSION, true)
                putExtra(SyncService.EXTRA_SESSION_ID, sessionId)
            }
        }
        startForegroundService(intent)
    }

    /**
     * Collects [SessionManager.remainingMs] in [lifecycleScope] so the collector is
     * automatically cancelled when the Activity is destroyed. Transitions the UI to
     * idle when both the countdown reaches 0 and no session is active.
     */
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

    private fun observeIncomingTransfers() {
        lifecycleScope.launch {
            TransferEvents.incoming.collect { event ->
                if (event.complete) {
                    Snackbar.make(
                        binding.root,
                        getString(R.string.transfer_received, event.filename),
                        Snackbar.LENGTH_SHORT
                    ).show()
                    refreshUi()
                } else if (event.totalBytes > 0) {
                    binding.statusSubtitle.text = getString(
                        R.string.transfer_receiving_progress,
                        event.filename,
                        event.percent
                    )
                } else {
                    binding.statusSubtitle.text = getString(R.string.transfer_receiving, event.filename)
                }
            }
        }
    }

    /** Synchronizes all UI elements with the current session state on demand (e.g. after onResume). */
    private fun refreshUi() {
        refreshDashboardStatsUi()
        if (sessionManager.isSessionActive()) {
            showConnectedState(sessionManager.repository.remainingMs())
        } else {
            showIdleState()
        }
    }

    /**
     * Populates the four stat tiles with live values from [SessionManager.repository]:
     * - **Mac**: IP address or "Waiting for Mac…" if not yet connected.
     * - **Session**: formatted countdown or "Idle".
     * - **Storage**: selected folder name, "All files access", or "App storage".
     * - **Privacy**: always "Local only — no cloud".
     */
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

    /**
     * Transitions the UI to idle state: sync icon static (no animation), "Ready to scan"
     * headline, hidden countdown chip and "End Session" button, and expanded scan FAB.
     */
    private fun showIdleState() {
        binding.statusIcon.setImageResource(R.drawable.ic_sync)
        binding.statusIcon.clearAnimation()
        binding.statusTitle.setText(R.string.status_idle)
        binding.statusSubtitle.setText(R.string.status_idle_subtitle)
        binding.countdownChip.visibility = View.GONE
        binding.btnEndSession.visibility = View.GONE
        binding.fabScan.extend()
    }

    /**
     * Transitions the UI to connected state. Shows the Mac IP in the subtitle and,
     * for timed sessions, the live countdown chip. For in-memory sessions ([remainingMs] == 0)
     * the chip is hidden and the subtitle reads "Active until disconnected".
     *
     * @param remainingMs  Milliseconds left in the session; 0 means in-memory (no timer).
     */
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

    /**
     * Called when the scan FAB is tapped. If [SecurityChecks.isRooted] returns `true`,
     * shows a warning dialog offering the user a chance to cancel before proceeding.
     * On non-rooted devices, launches [QrScanActivity] directly.
     */
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

    /** Starts [QrScanActivity] to scan the Mac companion app's QR code. */
    private fun launchScanner() {
        startActivity(Intent(this, QrScanActivity::class.java))
    }

    /**
     * Shows a confirmation dialog before revoking the active session. On confirmation,
     * calls [SessionManager.revokeSession] (which also stops [com.synccompanion.service.SyncService])
     * and immediately transitions the UI to idle state.
     */
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

    /**
     * Returns `true` if MANAGE_EXTERNAL_STORAGE is granted, giving the app access
     * to the entire device filesystem. Only possible on Android 11 (API 30) and above.
     */
    private fun hasAllFilesAccess(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()
}
