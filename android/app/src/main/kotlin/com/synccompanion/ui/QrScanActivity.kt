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

@Parcelize
data class QrPayload(
    val token: String,
    val macIp: String,
    val port: Int,
    val sessionId: String,
    val expiresAt: Long
) : Parcelable

class QrScanActivity : AppCompatActivity() {

    private lateinit var binding: ActivityQrScanBinding
    private lateinit var cameraExecutor: ExecutorService
    private var scanHandled = false

    private val cameraPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) startCamera() else finish()
        }

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

    private fun handleBarcodes(barcodes: List<Barcode>) {
        if (scanHandled) return
        val raw = barcodes.firstOrNull { it.rawValue != null }?.rawValue ?: return
        val payload = parseAndValidate(raw) ?: return
        scanHandled = true
        SessionDurationSheet.newInstance(payload).show(supportFragmentManager, SessionDurationSheet.TAG)
    }

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

    override fun onDestroy() {
        super.onDestroy()
        cameraExecutor.shutdown()
    }

    companion object {
        private const val TAG = "QrScanActivity"
    }
}
