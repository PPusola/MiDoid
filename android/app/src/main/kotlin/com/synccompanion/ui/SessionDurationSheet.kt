package com.synccompanion.ui

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import com.google.android.material.bottomsheet.BottomSheetDialogFragment
import com.synccompanion.R
import com.synccompanion.databinding.SheetSessionDurationBinding
import com.synccompanion.service.SyncService
import com.synccompanion.session.SessionRepository

/**
 * Bottom sheet dialog that lets the user choose how long the sync session should last
 * before authorizing it and starting [SyncService].
 *
 * Shown by [QrScanActivity] immediately after a valid, non-expired [QrPayload] is decoded.
 * The user drags a discrete slider across six duration presets (from "Ends when disconnected"
 * up to 24 hours). Tapping "Start Session" writes credentials to [SessionRepository] and
 * starts [SyncService] as a foreground service. "Cancel" dismisses the sheet without creating a session.
 */
class SessionDurationSheet : BottomSheetDialogFragment() {

    private var _binding: SheetSessionDurationBinding? = null
    private val binding get() = _binding!!

    private lateinit var payload: QrPayload

    /**
     * Six discrete session durations in milliseconds. Index `0` uses value `0L` as the
     * sentinel for an in-memory session — no expiry timer, ends only when the user disconnects.
     */
    private val durationSteps = longArrayOf(
        0L,
        3_600_000L,
        14_400_000L,
        28_800_000L,
        43_200_000L,
        86_400_000L
    )

    /** Human-readable labels shown below the slider, aligned 1:1 with [durationSteps]. */
    private val durationLabels = listOf(
        "Ends when disconnected",
        "1 hour",
        "4 hours",
        "8 hours",
        "12 hours",
        "24 hours"
    )

    /**
     * Inflates the sheet layout. Uses the ViewBinding nullable pattern to prevent
     * memory leaks — the reference is released in [onDestroyView].
     */
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
        _binding = SheetSessionDurationBinding.inflate(inflater, container, false)
        return binding.root
    }

    /**
     * Configures the slider (0–5 steps, default index 2 = 4 hours), wires the live
     * duration label, and sets up the "Start Session" and "Cancel" button listeners.
     */
    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        @Suppress("DEPRECATION")
        payload = requireArguments().getParcelable(ARG_PAYLOAD)!!

        binding.slider.apply {
            valueFrom = 0f
            valueTo = (durationSteps.size - 1).toFloat()
            stepSize = 1f
            value = 2f  // default: 4 hours
            addOnChangeListener { _, value, _ ->
                updateLabel(value.toInt())
            }
        }

        updateLabel(2)

        binding.btnStartSession.setOnClickListener {
            val stepIndex = binding.slider.value.toInt()
            val durationMs = durationSteps[stepIndex]
            startSession(durationMs)
        }

        binding.btnCancel.setOnClickListener { dismiss() }
    }

    /**
     * Refreshes the duration label beneath the slider to match the current [index].
     *
     * @param index  Zero-based slider position; must be within bounds of [durationLabels].
     */
    private fun updateLabel(index: Int) {
        binding.tvDurationLabel.text = durationLabels[index]
    }

    /**
     * Authorizes the session and starts [SyncService] as a foreground service.
     *
     * Steps:
     * 1. Calls [SessionRepository.authorizeSession] with the token, session ID, duration, and Mac IP.
     * 2. Starts [SyncService] via `startForegroundService`. For in-memory sessions ([durationMs] == 0),
     *    attaches [SyncService.EXTRA_IN_MEMORY_SESSION] and [SyncService.EXTRA_SESSION_ID] so the
     *    service knows no persisted record exists.
     * 3. Dismisses the sheet and finishes [QrScanActivity] to return the user to [MainActivity].
     *
     * @param durationMs  Session length in milliseconds; `0L` means "ends on disconnect" (in-memory).
     */
    private fun startSession(durationMs: Long) {
        val ctx = requireContext()
        val repository = SessionRepository(ctx)

        repository.authorizeSession(
            token      = payload.token,
            sessionId  = payload.sessionId,
            durationMs = durationMs,
            macIp      = payload.macIp
        )

        ctx.startForegroundService(
            Intent(ctx, SyncService::class.java).apply {
                if (durationMs == 0L) {
                    putExtra(SyncService.EXTRA_IN_MEMORY_SESSION, true)
                    putExtra(SyncService.EXTRA_SESSION_ID, payload.sessionId)
                }
            }
        )

        dismiss()
        activity?.finish() // close QrScanActivity, return to MainActivity
    }

    /**
     * Releases the ViewBinding reference to avoid holding a reference to the
     * destroyed view beyond the Fragment's view lifecycle.
     */
    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }

    companion object {
        const val TAG = "SessionDurationSheet"
        private const val ARG_PAYLOAD = "payload"

        /**
         * Factory method that creates a [SessionDurationSheet] with [payload] bundled as
         * a Parcelable argument, following the Fragment factory pattern.
         *
         * @param payload  The [QrPayload] decoded from the scanned QR code.
         */
        fun newInstance(payload: QrPayload): SessionDurationSheet {
            return SessionDurationSheet().apply {
                arguments = Bundle().apply {
                    @Suppress("DEPRECATION")
                    putParcelable(ARG_PAYLOAD, payload)
                }
            }
        }
    }
}
