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

class SessionDurationSheet : BottomSheetDialogFragment() {

    private var _binding: SheetSessionDurationBinding? = null
    private val binding get() = _binding!!

    private lateinit var payload: QrPayload

    // Slider steps in milliseconds; index 0 = in-memory only (disconnect)
    private val durationSteps = longArrayOf(
        0L,
        3_600_000L,
        14_400_000L,
        28_800_000L,
        43_200_000L,
        86_400_000L
    )

    private val durationLabels = listOf(
        "Ends when disconnected",
        "1 hour",
        "4 hours",
        "8 hours",
        "12 hours",
        "24 hours"
    )

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
        _binding = SheetSessionDurationBinding.inflate(inflater, container, false)
        return binding.root
    }

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

    private fun updateLabel(index: Int) {
        binding.tvDurationLabel.text = durationLabels[index]
    }

    private fun startSession(durationMs: Long) {
        val ctx = requireContext()
        val repository = SessionRepository(ctx)

        repository.authorizeSession(
            token      = payload.token,
            sessionId  = payload.sessionId,
            durationMs = durationMs
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

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }

    companion object {
        const val TAG = "SessionDurationSheet"
        private const val ARG_PAYLOAD = "payload"

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
