package com.bshare.bshare

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/** Camera capture must not reuse the MediaProjection foreground-service type. */
class CameraShareForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "bshare_camera_share"
        private const val NOTIFICATION_ID = 1003
        private const val START_REQUEST_ID = "startRequestId"
        private const val START_TIMEOUT_MS = 5000L
        private val mainHandler = Handler(Looper.getMainLooper())
        private var activeService: CameraShareForegroundService? = null
        private var nextRequestId = 0
        private val pendingStarts = mutableMapOf<Int, PendingStart>()

        private class PendingStart(
            val onReady: (Exception?) -> Unit,
            val timeout: Runnable,
        )

        /** Resolve only after CAMERA foreground execution is actually ready. */
        fun start(context: Context, onReady: (Exception?) -> Unit) {
            if (activeService?.foregroundReady == true) {
                onReady(null)
                return
            }
            val requestId = ++nextRequestId
            val application = context.applicationContext
            val timeout = Runnable {
                val pending = pendingStarts.remove(requestId) ?: return@Runnable
                if (pendingStarts.isEmpty() && activeService == null) {
                    application.stopService(Intent(application, CameraShareForegroundService::class.java))
                }
                pending.onReady(IllegalStateException("Camera foreground service did not become ready"))
            }
            pendingStarts[requestId] = PendingStart(onReady, timeout)
            mainHandler.postDelayed(timeout, START_TIMEOUT_MS)
            val intent = Intent(context, CameraShareForegroundService::class.java)
                .putExtra(START_REQUEST_ID, requestId)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Exception) {
                finishStart(requestId, error)
            }
        }

        /** MainActivity's channel runs on the main thread, as do service callbacks. */
        fun setMicrophoneActive(active: Boolean) {
            val service = activeService?.takeIf { it.foregroundReady }
            if (service == null) {
                if (active) throw IllegalStateException("Camera foreground service is not running")
                return
            }
            service.updateForeground(active)
        }

        fun stop(context: Context) {
            activeService?.foregroundReady = false
            context.stopService(Intent(context, CameraShareForegroundService::class.java))
            finishPendingStarts(IllegalStateException("Camera foreground service was stopped"))
        }

        private fun finishStart(requestId: Int, error: Exception?) {
            val pending = pendingStarts.remove(requestId) ?: return
            mainHandler.removeCallbacks(pending.timeout)
            pending.onReady(error)
        }

        private fun finishPendingStarts(error: Exception) {
            for (requestId in pendingStarts.keys.toList()) finishStart(requestId, error)
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var foregroundReady = false
    private var microphoneActive = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val requestId = intent?.getIntExtra(START_REQUEST_ID, -1) ?: -1
        // A cancelled or timed-out start must never resurrect capture execution.
        if (!pendingStarts.containsKey(requestId)) {
            if (!foregroundReady) stopSelf(startId)
            return START_NOT_STICKY
        }
        try {
            if (!foregroundReady) {
                updateForeground(microphone = false)
                acquireWakeLock()
                foregroundReady = true
                activeService = this
            }
            finishStart(requestId, null)
        } catch (error: Exception) {
            finishStart(requestId, error)
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private fun updateForeground(microphone: Boolean) {
        if (foregroundReady && microphoneActive == microphone) return
        val spanish = resources.configuration.locales[0].language == "es"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    if (spanish) "Cámara del dispositivo" else "Device camera",
                    NotificationManager.IMPORTANCE_LOW,
                )
            )
        }
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(
                if (microphone) {
                    if (spanish) "BShare está compartiendo cámara y micrófono" else "BShare is sharing your camera and microphone"
                } else {
                    if (spanish) "BShare está compartiendo la cámara" else "BShare is sharing your camera"
                }
            )
            .setContentText(if (spanish) "Toca para volver y detener la transmisión" else "Tap to return and stop sharing")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                if (microphone) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
            // Passing CAMERA alone on mute removes MICROPHONE from this service.
            // This call is synchronous; Dart may acquire audio only after it returns.
            startForeground(NOTIFICATION_ID, notification, types)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        microphoneActive = microphone
    }

    @Suppress("DEPRECATION")
    @SuppressLint("WakelockTimeout")
    private fun acquireWakeLock() {
        if (wakeLock != null) return
        // Keeps automatic device locking from interrupting an intentional stream,
        // including when the app is backgrounded. The activity separately dims.
        wakeLock = getSystemService(PowerManager::class.java).newWakeLock(
            PowerManager.SCREEN_DIM_WAKE_LOCK, "$packageName:CameraShare",
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        foregroundReady = false
        microphoneActive = false
        if (activeService === this) activeService = null
        finishPendingStarts(IllegalStateException("Camera foreground service was destroyed"))
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        stopForeground(true)
        super.onDestroy()
    }
}
