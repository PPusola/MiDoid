package com.synccompanion.transfer

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

data class TransferEvent(
    val filename: String,
    val receivedBytes: Long,
    val totalBytes: Long,
    val complete: Boolean
) {
    val percent: Int
        get() = if (totalBytes > 0) {
            ((receivedBytes * 100) / totalBytes).coerceIn(0, 100).toInt()
        } else {
            0
        }
}

object TransferEvents {
    private val mutableIncoming = MutableSharedFlow<TransferEvent>(
        replay = 0,
        extraBufferCapacity = 16
    )

    val incoming = mutableIncoming.asSharedFlow()

    fun reportIncoming(filename: String, receivedBytes: Long, totalBytes: Long, complete: Boolean) {
        mutableIncoming.tryEmit(
            TransferEvent(
                filename = filename,
                receivedBytes = receivedBytes,
                totalBytes = totalBytes,
                complete = complete
            )
        )
    }
}
