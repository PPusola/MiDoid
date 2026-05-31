package com.synccompanion.transfer

import kotlinx.coroutines.launch
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TransferEventsTest {

    @Test
    fun `reportIncoming emits event to incoming flow`() = runTest {
        val received = mutableListOf<TransferEvent>()

        val job = launch {
            TransferEvents.incoming.collect { received.add(it) }
        }
        runCurrent()

        TransferEvents.reportIncoming("photo.jpg", 512, 1024, false)
        TransferEvents.reportIncoming("photo.jpg", 1024, 1024, true)

        // Give coroutines time to process
        testScheduler.advanceUntilIdle()
        job.cancel()

        assertEquals(2, received.size)
        assertEquals("photo.jpg", received[0].filename)
        assertEquals(512L, received[0].receivedBytes)
        assertEquals(1024L, received[0].totalBytes)
        assertFalse(received[0].complete)
        assertTrue(received[1].complete)
    }

    @Test
    fun `TransferEvent percent calculation`() {
        val event = TransferEvent("file.mp4", 250, 1000, false)
        assertEquals(25, event.percent)
    }

    @Test
    fun `TransferEvent percent is 0 when totalBytes is 0`() {
        val event = TransferEvent("file.mp4", 100, 0, false)
        assertEquals(0, event.percent)
    }

    @Test
    fun `TransferEvent percent clamped to 100`() {
        val event = TransferEvent("file.mp4", 2000, 1000, true)
        assertEquals(100, event.percent)
    }

    @Test
    fun `TransferEvent complete flag`() {
        val incomplete = TransferEvent("a", 0, 100, false)
        val complete   = TransferEvent("a", 100, 100, true)
        assertFalse(incomplete.complete)
        assertTrue(complete.complete)
    }

    @Test
    fun `multiple listeners each receive events`() = runTest {
        val listA = mutableListOf<TransferEvent>()
        val listB = mutableListOf<TransferEvent>()

        val jobA = launch { TransferEvents.incoming.collect { listA.add(it) } }
        val jobB = launch { TransferEvents.incoming.collect { listB.add(it) } }
        runCurrent()

        TransferEvents.reportIncoming("x.jpg", 1, 1, true)
        testScheduler.advanceUntilIdle()

        jobA.cancel(); jobB.cancel()

        assertEquals(1, listA.size)
        assertEquals(1, listB.size)
    }
}
