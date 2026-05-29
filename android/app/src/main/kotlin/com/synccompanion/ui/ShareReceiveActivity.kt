package com.synccompanion.ui

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Log
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.synccompanion.R
import com.synccompanion.session.SessionRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * Transparent activity that handles share intents (ACTION_SEND / ACTION_SEND_MULTIPLE).
 * Reads the file(s) from the incoming intent, POSTs each one to the Mac's IncomingFileServer
 * on port 8082 using the active session token, then finishes.
 *
 * Auth header:  Basic base64("sync:<token>")
 * X-Filename:   URL-decoded last path segment of the content URI
 * X-Device-Name: Build.MODEL (so the Mac can show "Received from Pixel 9")
 */
class ShareReceiveActivity : AppCompatActivity() {

    private lateinit var statusText: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_share_receive)
        statusText = findViewById(R.id.share_status)

        val repo = SessionRepository(this)
        val token = repo.loadToken()
        val macIp = repo.loadMacIp()

        if (token == null || macIp == null) {
            statusText.setText(R.string.share_no_session)
            finish()
            return
        }

        val uris: List<Uri>? = collectUris(intent)
        val sharedText = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()

        if (uris.isNullOrEmpty() && sharedText.isNullOrBlank()) {
            statusText.setText(R.string.share_no_files)
            finish()
            return
        }

        statusText.setText(R.string.share_sending)

        lifecycleScope.launch(Dispatchers.IO) {
            var successCount = 0
            var itemCount = 0

            uris?.forEach { uri ->
                itemCount++
                if (sendFile(uri, resolveFilename(uri) ?: "file", macIp, token)) {
                    successCount++
                }
            }

            if (!sharedText.isNullOrBlank()) {
                itemCount++
                if (sendText(sharedText, macIp, token)) {
                    successCount++
                }
            }

            withContext(Dispatchers.Main) {
                if (successCount == itemCount) {
                    statusText.text = resources.getQuantityString(
                        R.plurals.share_sent, successCount, successCount)
                } else {
                    statusText.setText(R.string.share_failed)
                }
                // Brief display so the user can see the result, then close
                window.decorView.postDelayed({ finish() }, 1_500)
            }
        }
    }

    // MARK: - Helpers

    private fun collectUris(intent: Intent): List<Uri>? {
        return when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                uri?.let { listOf(it) }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
            }
            else -> null
        }
    }

    private fun resolveFilename(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
            null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                return cursor.getString(0)
            }
        }
        // Fallback: last segment of the URI
        return uri.lastPathSegment?.let {
            java.net.URLDecoder.decode(it, "UTF-8")
        }
    }

    private fun sendFile(uri: Uri, filename: String, macIp: String, token: String): Boolean {
        val inputStream: InputStream = try {
            contentResolver.openInputStream(uri) ?: return false
        } catch (e: Exception) {
            Log.e(TAG, "Cannot open URI: $uri", e)
            return false
        }

        return try {
            sendStream(
                inputStream = inputStream,
                contentLength = resolveContentLength(uri),
                filename = filename,
                macIp = macIp,
                token = token
            )
        } finally {
            try { inputStream.close() } catch (_: Exception) {}
        }
    }

    private fun sendText(text: String, macIp: String, token: String): Boolean {
        val bytes = text.toByteArray(Charsets.UTF_8)
        return sendStream(
            inputStream = ByteArrayInputStream(bytes),
            contentLength = bytes.size.toLong(),
            filename = "Shared Text.txt",
            macIp = macIp,
            token = token
        )
    }

    private fun sendStream(
        inputStream: InputStream,
        contentLength: Long,
        filename: String,
        macIp: String,
        token: String
    ): Boolean {
        return try {
            val url = URL("http://$macIp:$RECEIVE_PORT/receive")
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.connectTimeout = 10_000
            conn.readTimeout = 30_000

            val auth = "Basic " + Base64.encodeToString("sync:$token".toByteArray(), Base64.NO_WRAP)
            conn.setRequestProperty("Authorization", auth)
            conn.setRequestProperty("X-Filename", filename)
            conn.setRequestProperty("X-Device-Name", Build.MODEL)
            conn.setRequestProperty("Content-Type", "application/octet-stream")
            conn.setRequestProperty("Connection", "close")

            if (contentLength >= 0L) {
                conn.setFixedLengthStreamingMode(contentLength)
            }

            val progressInput = CountingInputStream(inputStream, contentLength) { sent, total ->
                if (total > 0L) {
                    statusText.post {
                        statusText.text = getString(
                            R.string.share_sending_progress,
                            filename,
                            ((sent * 100) / total).coerceIn(0, 100).toInt()
                        )
                    }
                }
            }

            progressInput.use { input ->
                conn.outputStream.use { output ->
                    input.copyTo(output, bufferSize = 65_536)
                }
            }

            val code = conn.responseCode
            conn.disconnect()
            code in 200..299
        } catch (e: Exception) {
            Log.e(TAG, "Send failed for $filename", e)
            false
        }
    }

    private class CountingInputStream(
        private val inner: InputStream,
        private val totalBytes: Long,
        private val onProgress: (sentBytes: Long, totalBytes: Long) -> Unit
    ) : InputStream() {
        private var sentBytes = 0L
        private var nextReportBytes = PROGRESS_STEP_BYTES

        override fun read(): Int {
            val value = inner.read()
            if (value >= 0) report(1)
            return value
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            val count = inner.read(b, off, len)
            if (count > 0) report(count)
            return count
        }

        override fun close() = inner.close()

        private fun report(count: Int) {
            sentBytes += count
            if (sentBytes >= nextReportBytes || sentBytes >= totalBytes) {
                onProgress(sentBytes, totalBytes)
                nextReportBytes = sentBytes + PROGRESS_STEP_BYTES
            }
        }
    }

    private fun resolveContentLength(uri: Uri): Long {
        contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) {
                return cursor.getLong(0)
            }
        }

        return try {
            contentResolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
                descriptor.length
            } ?: -1L
        } catch (e: Exception) {
            Log.w(TAG, "Cannot resolve content length for URI: $uri", e)
            -1L
        }
    }

    companion object {
        private const val TAG = "ShareReceiveActivity"
        private const val RECEIVE_PORT = 8082
        private const val PROGRESS_STEP_BYTES = 512 * 1024L
    }
}
