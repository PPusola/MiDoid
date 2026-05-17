package com.synccompanion.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Parcelable
import android.util.Log
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import com.google.android.material.snackbar.Snackbar
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.synccompanion.R
import com.synccompanion.databinding.ActivityQrScanBinding
import kotlinx.parcelize.Parcelize
import org.json.JSONException
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Structured payload extracted from a MiDoid Mac companion QR code.
 *
 * @property token      Session bearer token used for WebDAV Basic-auth (password field).
 * @property macIp      IPv4 address of the Mac on the local Wi-Fi network.
 * @property port       WebDAV server port on the Mac (8080 in current builds).
 * @property sessionId  UUID used to match this QR code to the mDNS service advertisement.
 * @property expiresAt  Unix timestamp in seconds after which this QR code must be rejected.
 */
@Parcelize
data class QrPayload(
    val token: String,
    val macIp: String,
    val port: Int,
    val sessionId: String,
    val expiresAt: Long
) : Parcelable

/**
 * Full-screen camera activity that scans the MiDoid Mac companion QR code.
 *
 * Uses CameraX for the live viewfinder and ML Kit's [BarcodeScanning] client for
 * real-time barcode analysis on a dedicated background executor thread. Once a valid,
 * non-expired payload is detected, [scanHandled] is set to prevent duplicate processing
 * and [SessionDurationSheet] is shown to let the user choose a session duration.
 */
class QrScanActivity : AppCompatActivity() {

    private lateinit var binding: ActivityQrScanBinding

    /** Single-threaded executor used for ML Kit image analysis; shut down in [onDestroy]. */
    private lateinit var cameraExecutor: ExecutorService

    /** Set to `true` after a valid QR code is processed to suppress all further frames. */
    private var scanHandled = false

    /**
     * Requests [Manifest.permission.CAMERA] at runtime.
     * Starts the camera on grant; finishes the Activity on denial (user cannot scan without it).
     */
    private val cameraPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) startCamera() else finish()
        }

    /**
     * Inflates the layout, creates the camera executor, and either starts the camera immediately
     * (if camera permission is already granted) or requests it via [cameraPermission].
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityQrScanBinding.inflate(layoutInflater)
        setContentView(binding.root)

        cameraExecutor = Executors.newSingleThreadExecutor()

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            == PackageManager.PERMISSION_GRANTED
        ) {
            startCamera()
        } else {
            cameraPermission.launch(Manifest.permission.CAMERA)
        }

        binding.btnClose.setOnClickListener { finish() }
    }

    /**
     * Binds CameraX use cases (Preview + ImageAnalysis) to this Activity's lifecycle.
     * The analyzer uses [ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST] so slow ML Kit processing
     * does not cause frame backpressure — older frames are simply dropped.
     */
    private fun startCamera() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()

            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(binding.previewView.surfaceProvider)
            }

            val scanner = BarcodeScanning.getClient()
            val imageAnalysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { analysis ->
                    analysis.setAnalyzer(cameraExecutor) { imageProxy ->
                        if (scanHandled) { imageProxy.close(); return@setAnalyzer }
                        val mediaImage = imageProxy.image
                        if (mediaImage != null) {
                            val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
                            scanner.process(image)
                                .addOnSuccessListener { barcodes -> handleBarcodes(barcodes) }
                                .addOnCompleteListener { imageProxy.close() }
                        } else {
                            imageProxy.close()
                        }
                    }
                }

            try {
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, imageAnalysis)
            } catch (e: Exception) {
                Log.e(TAG, "Camera bind failed: ${e.message}")
            }
        }, ContextCompat.getMainExecutor(this))
    }

    /**
     * Processes barcodes detected in a single camera frame. Ignores the list entirely
     * once [scanHandled] is `true`. Takes the first barcode with a non-null raw value
     * and passes it to [parseAndValidate]; shows [SessionDurationSheet] on success.
     *
     * @param barcodes  Barcodes detected by ML Kit in the current frame; may be empty.
     */
    private fun handleBarcodes(barcodes: List<Barcode>) {
        if (scanHandled) return
        val raw = barcodes.firstOrNull { it.rawValue != null }?.rawValue ?: return
        val payload = parseAndValidate(raw) ?: return
        scanHandled = true
        SessionDurationSheet.newInstance(payload).show(supportFragmentManager, SessionDurationSheet.TAG)
    }

    /**
     * Parses [raw] as JSON and validates it as a [QrPayload].
     *
     * **Validation rules:**
     * - JSON must contain `token` (or legacy field `pubkey`), `mac_ip`, `port`,
     *   `session_id`, and `expires_at`.
     * - `expires_at` (Unix seconds) must be greater than the current time.
     *   If expired, shows a snackbar and resets [scanHandled] so the user can scan again.
     *
     * @param raw  Raw string value decoded from the barcode.
     * @return     A valid [QrPayload], or `null` if parsing fails or the QR code is expired.
     */
    private fun parseAndValidate(raw: String): QrPayload? {
        return try {
            val json = JSONObject(raw)
            val expiresAt = json.getLong("expires_at")
            val nowSec = System.currentTimeMillis() / 1000

            if (expiresAt < nowSec) {
                runOnUiThread {
                    Snackbar.make(binding.root, R.string.qr_expired, Snackbar.LENGTH_LONG).show()
                    scanHandled = false
                }
                return null
            }

            // Support both current "token" field and legacy "pubkey" field name
            val token = json.optString("token").ifEmpty { json.optString("pubkey") }
            if (token.isEmpty()) throw JSONException("No value for token")

            QrPayload(
                token     = token,
                macIp     = json.getString("mac_ip"),
                port      = json.getInt("port"),
                sessionId = json.getString("session_id"),
                expiresAt = expiresAt
            )
        } catch (e: JSONException) {
            Log.w(TAG, "Invalid QR payload: ${e.message}")
            null
        }
    }

    /** Shuts down [cameraExecutor] to release the background thread. */
    override fun onDestroy() {
        super.onDestroy()
        cameraExecutor.shutdown()
    }

    companion object {
        private const val TAG = "QrScanActivity"
    }
}
