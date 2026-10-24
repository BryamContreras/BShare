package com.bshare.bshare

import android.Manifest
import android.content.Intent
import android.content.ActivityNotFoundException
import android.net.Uri
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.SoftApConfiguration
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.WifiNetworkSuggestion
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.provider.OpenableColumns
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.content.pm.PackageManager
import android.util.Base64
import android.util.Log
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.NetworkInterface
import java.net.Inet4Address
import java.util.UUID
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private var hotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var hotspotInfo: Map<String, Any?>? = null
    private var pendingHotspotResult: MethodChannel.Result? = null
    private var wifiNetworkCallback: ConnectivityManager.NetworkCallback? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var shareChannel: MethodChannel? = null
    private val pendingSharedFiles = mutableListOf<Map<String, Any>>()
    private var viewerKeepsScreenOn = false
    private var cameraKeepsScreenOn = false
    private var cameraOriginalBrightness: Float? = null
    private var discoveryMulticastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bshare/share").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialSharedFiles" -> {
                        val files = pendingSharedFiles.toList()
                        pendingSharedFiles.clear()
                        result.success(files)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        handleSharedIntent(intent, notifyFlutter = false)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bshare/discovery").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "acquireMulticast" -> {
                        if (discoveryMulticastLock?.isHeld != true) {
                            val wifi = applicationContext.getSystemService(WifiManager::class.java)
                            val lock = wifi.createMulticastLock("BShare:discovery")
                            lock.setReferenceCounted(false)
                            lock.acquire()
                            discoveryMulticastLock = lock
                        }
                        result.success(null)
                    }
                    "releaseMulticast" -> {
                        releaseDiscoveryMulticast()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("discovery_multicast_error", error.message, null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bshare/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceName" -> result.success(deviceName())
                "getAndroidSdkInt" -> result.success(Build.VERSION.SDK_INT)
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bshare/apps").setMethodCallHandler { call, result ->
            when (call.method) {
                "listInstalledApps" -> thread {
                    try {
                        val apps = listInstalledApps()
                        runOnUiThread { result.success(apps) }
                    } catch (error: Exception) {
                        runOnUiThread {
                            result.error("apps_unavailable", error.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bshare/screen").setMethodCallHandler { call, result ->
            when (call.method) {
                "setKeepScreenOn" -> {
                    viewerKeepsScreenOn = call.argument<Boolean>("enabled") == true
                    updateKeepScreenOn()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bshare/screen_share").setMethodCallHandler { call, result ->
            when (call.method) {
                "startForegroundService" -> {
                    ScreenShareForegroundService.start(this)
                    result.success(null)
                }
                "stopForegroundService" -> {
                    ScreenShareForegroundService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bshare/camera").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "startForegroundService" -> {
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                            throw SecurityException("Camera permission must be granted before sharing")
                        }
                        CameraShareForegroundService.start(this) { error ->
                            if (error == null) result.success(null)
                            else result.error("camera_platform_error", error.message, null)
                        }
                    }
                    "stopForegroundService" -> {
                        CameraShareForegroundService.stop(this)
                        result.success(null)
                    }
                    "setMicrophoneActive" -> {
                        val active = call.argument<Boolean>("active")
                            ?: throw IllegalArgumentException("Microphone active state is required")
                        if (active) {
                            if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED ||
                                ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                                throw SecurityException("Camera and microphone permissions must be granted before sharing audio")
                            }
                        }
                        CameraShareForegroundService.setMicrophoneActive(active)
                        result.success(null)
                    }
                    "setDisplayState" -> {
                        val awake = call.argument<Boolean>("awake") == true
                        val dimmed = awake && call.argument<Boolean>("dimmed") == true
                        val attributes = window.attributes
                        if (awake && cameraOriginalBrightness == null) {
                            cameraOriginalBrightness = attributes.screenBrightness
                        }
                        cameraKeepsScreenOn = awake
                        updateKeepScreenOn()
                        attributes.screenBrightness = if (dimmed) 0.01f
                            else cameraOriginalBrightness ?: attributes.screenBrightness
                        window.attributes = attributes
                        if (!awake) cameraOriginalBrightness = null
                        result.success(null)
                    }
                    "listUsbAddresses" -> result.success(usbNetworkAddresses())
                    "openUsbTetheringSettings" -> {
                        try {
                            startActivity(Intent("android.settings.TETHER_SETTINGS"))
                        } catch (_: ActivityNotFoundException) {
                            startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS))
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("camera_platform_error", error.message, null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bshare/direct_network").setMethodCallHandler { call, result ->
            when (call.method) {
                "startLocalOnlyHotspot" -> startLocalOnlyHotspot(result)
                "stopLocalOnlyHotspot" -> {
                    stopLocalOnlyHotspot()
                    result.success(null)
                }
                "connectToWifi" -> connectToWifi(
                    call.argument<String>("ssid"),
                    call.argument<String>("password") ?: "",
                    result
                )
                "openWifiJoinSettings" -> openWifiJoinSettings(
                    call.argument<String>("ssid"),
                    call.argument<String>("password") ?: "",
                    result
                )
                "ensureWifiReady" -> ensureWifiReady(result)
                "openWifiPanel" -> openWifiPanel(result)
                "hasWifiNetwork" -> hasWifiNetwork(result)
                "bindToCurrentWifi" -> bindToCurrentWifi(result)
                "bindToWifiForHost" -> bindToWifiForHost(
                    call.argument<String>("host"),
                    call.argument<Int>("port") ?: 80,
                    call.argument<String>("path") ?: "/api/ping",
                    result
                )
                "disconnectWifi" -> {
                    disconnectWifi()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun updateKeepScreenOn() {
        if (viewerKeepsScreenOn || cameraKeepsScreenOn) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    private fun releaseDiscoveryMulticast() {
        val lock = discoveryMulticastLock
        discoveryMulticastLock = null
        if (lock?.isHeld == true) lock.release()
    }

    private fun usbNetworkAddresses(): List<Map<String, Any>> {
        val names = mutableSetOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val connectivity = getSystemService(ConnectivityManager::class.java)
            for (network in connectivity.allNetworks) {
                val capabilities = connectivity.getNetworkCapabilities(network) ?: continue
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_USB)) {
                    connectivity.getLinkProperties(network)?.interfaceName?.let { names.add(it) }
                }
            }
        }
        val addresses = mutableListOf<Map<String, Any>>()
        val interfaces = NetworkInterface.getNetworkInterfaces() ?: return addresses
        for (iface in interfaces) {
            val name = iface.name.lowercase()
            val usb = name.startsWith("rndis") || name.startsWith("usb") ||
                name.startsWith("ncm") || names.contains(iface.name)
            if (!usb || !iface.isUp || iface.isLoopback) continue
            for (address in iface.interfaceAddresses) {
                val ip = address.address
                if (ip !is Inet4Address || ip.isLoopbackAddress || ip.isAnyLocalAddress) continue
                addresses.add(mapOf(
                    "ip" to (ip.hostAddress ?: continue),
                    "prefixLength" to address.networkPrefixLength.toInt(),
                    "interfaceName" to iface.name,
                ))
            }
        }
        return addresses
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleSharedIntent(intent, notifyFlutter = true)
    }

    override fun onDestroy() {
        // The default Activity owns its FlutterEngine. Engine destruction can
        // interrupt Dart's async detached cleanup after WebRTC releases capture.
        // Close native execution owners here too; ordinary onStop/background
        // does not end an intentional camera or screen-sharing session.
        CameraShareForegroundService.stop(this)
        ScreenShareForegroundService.stop(this)
        cameraKeepsScreenOn = false
        viewerKeepsScreenOn = false
        updateKeepScreenOn()
        cameraOriginalBrightness?.let { original ->
            val attributes = window.attributes
            attributes.screenBrightness = original
            window.attributes = attributes
        }
        cameraOriginalBrightness = null
        try {
            releaseDiscoveryMulticast()
        } catch (error: Exception) {
            Log.w("BShare", "Could not release discovery multicast during shutdown", error)
        }
        stopLocalOnlyHotspot()
        disconnectWifi()
        super.onDestroy()
    }

    private fun handleSharedIntent(intent: Intent?, notifyFlutter: Boolean) {
        val sharedUris = sharedUrisFromIntent(intent)
        if (sharedUris.isEmpty()) return
        thread {
            val files = sharedUris.mapNotNull { uri -> copySharedUri(uri) }
            if (files.isEmpty()) return@thread
            runOnUiThread { enqueueSharedFiles(files, notifyFlutter) }
        }
    }

    @Suppress("DEPRECATION")
    private fun sharedUrisFromIntent(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) {
            return emptyList()
        }

        val uris = linkedSetOf<Uri>()
        if (action == Intent.ACTION_SEND) {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        } else {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        }
        intent.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                clip.getItemAt(index).uri?.let { uris.add(it) }
            }
        }
        return uris.toList()
    }

    private fun copySharedUri(uri: Uri): Map<String, Any>? {
        cleanShareCache()
        val displayName = sharedDisplayName(uri)
        val safeName = sanitizeFileName(displayName ?: uri.lastPathSegment ?: "shared-file")
        val targetDir = File(cacheDir, "shared_inbox").apply { mkdirs() }
        val target = File(targetDir, "${System.currentTimeMillis()}-${UUID.randomUUID()}-$safeName")
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            mapOf(
                "path" to target.absolutePath,
                "name" to safeName,
                "size" to target.length()
            )
        } catch (_: Exception) {
            try {
                target.delete()
            } catch (_: Exception) {
            }
            null
        }
    }

    private fun enqueueSharedFiles(files: List<Map<String, Any>>, notifyFlutter: Boolean) {
        pendingSharedFiles.addAll(files)
        if (!notifyFlutter) return
        shareChannel?.invokeMethod("onSharedFiles", files, object : MethodChannel.Result {
            override fun success(result: Any?) {
                pendingSharedFiles.removeAll(files.toSet())
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            }

            override fun notImplemented() {
            }
        })
    }

    private fun sharedDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (!cursor.moveToFirst()) return@use null
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) cursor.getString(index) else null
                }
        } catch (_: Exception) {
            null
        }
    }

    private fun sanitizeFileName(value: String): String {
        val cleaned = value
            .replace(Regex("""[\\/:*?"<>|\u0000-\u001F]"""), "_")
            .trim()
            .trim('.')
        return cleaned.ifEmpty { "shared-file" }
    }

    private fun cleanShareCache() {
        val targetDir = File(cacheDir, "shared_inbox")
        val cutoff = System.currentTimeMillis() - SHARE_CACHE_MAX_AGE_MS
        targetDir.listFiles()?.forEach { file ->
            if (file.lastModified() < cutoff) {
                try {
                    file.delete()
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun deviceName(): String {
        val candidates = listOf(
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1) {
                    Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
                } else {
                    null
                }
            } catch (_: Exception) {
                null
            },
            try {
                Settings.Global.getString(contentResolver, "device_name")
            } catch (_: Exception) {
                null
            },
            try {
                Settings.Secure.getString(contentResolver, "bluetooth_name")
            } catch (_: Exception) {
                null
            },
            androidModelName()
        )
        return candidates
            .mapNotNull { it?.trim() }
            .firstOrNull { it.isNotEmpty() && !it.equals("localhost", ignoreCase = true) }
            ?: "Android"
    }

    private fun androidModelName(): String {
        val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
        val model = Build.MODEL?.trim().orEmpty()
        if (model.isEmpty()) return "Android"
        if (manufacturer.isEmpty() || model.startsWith(manufacturer, ignoreCase = true)) {
            return model
        }
        return "$manufacturer $model"
    }

    private fun startLocalOnlyHotspot(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("hotspot_unsupported", "Local-only hotspot requires Android 8.0 or newer.", null)
            return
        }
        hotspotInfo?.let {
            result.success(it)
            return
        }
        if (pendingHotspotResult != null) {
            result.error("hotspot_starting", "The BShare network is already starting.", null)
            return
        }
        pendingHotspotResult = result

        val wifiManager = applicationContext.getSystemService(WifiManager::class.java)
        val callback = object : WifiManager.LocalOnlyHotspotCallback() {
            override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                hotspotReservation = reservation
                val info = hotspotInfoFromReservation(reservation)
                hotspotInfo = info
                pendingHotspotResult?.success(info)
                pendingHotspotResult = null
            }

            override fun onStopped() {
                hotspotReservation = null
                hotspotInfo = null
                pendingHotspotResult = null
            }

            override fun onFailed(reason: Int) {
                val pending = pendingHotspotResult
                pendingHotspotResult = null
                pending?.error("hotspot_failed", "Could not start BShare network. Reason: $reason", reason)
            }
        }

        try {
            wifiManager.startLocalOnlyHotspot(callback, Handler(Looper.getMainLooper()))
        } catch (error: Exception) {
            pendingHotspotResult = null
            result.error("hotspot_failed", error.message, null)
        }
    }

    private fun stopLocalOnlyHotspot() {
        try {
            hotspotReservation?.close()
        } catch (_: Exception) {
        } finally {
            hotspotReservation = null
            hotspotInfo = null
            pendingHotspotResult = null
        }
    }

    private fun hotspotInfoFromReservation(
        reservation: WifiManager.LocalOnlyHotspotReservation
    ): Map<String, Any?> {
        var ssid: String? = null
        var password: String? = null
        var securityType = "WPA2"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val config = reservation.softApConfiguration
            ssid = cleanWifiValue(config.ssid)
            password = cleanWifiValue(config.passphrase)
            securityType = if (config.securityType == SoftApConfiguration.SECURITY_TYPE_OPEN) {
                "OPEN"
            } else {
                "WPA2"
            }
        }
        if (ssid.isNullOrEmpty()) {
            @Suppress("DEPRECATION")
            val config = reservation.wifiConfiguration
            @Suppress("DEPRECATION")
            ssid = cleanWifiValue(config?.SSID)
            @Suppress("DEPRECATION")
            password = cleanWifiValue(config?.preSharedKey)
            securityType = if (password.isNullOrEmpty()) "OPEN" else "WPA2"
        }

        return mapOf(
            "ssid" to (ssid ?: ""),
            "password" to (password ?: ""),
            "securityType" to securityType
        )
    }

    private fun connectToWifi(
        ssid: String?,
        password: String,
        result: MethodChannel.Result
    ) {
        val wifiManager = applicationContext.getSystemService(WifiManager::class.java)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            connectToLegacyWifi(wifiManager, ssid, password, result)
            return
        }
        if (ssid.isNullOrBlank()) {
            result.error("wifi_connect_invalid", "Missing Wi-Fi name.", null)
            return
        }

        val connectivityManager = applicationContext.getSystemService(ConnectivityManager::class.java)
        disconnectWifi()

        try {
            wifiManager.startScan()
        } catch (_: Exception) {
        }

        val candidates = wifiSecurityCandidates(password)
        requestWifiNetwork(connectivityManager, ssid.trim(), password, candidates, 0, result)
    }

    private fun requestWifiNetwork(
        connectivityManager: ConnectivityManager,
        ssid: String,
        password: String,
        securityCandidates: List<String>,
        candidateIndex: Int,
        result: MethodChannel.Result
    ) {
        if (candidateIndex >= securityCandidates.size) {
            result.error(
                "wifi_connect_unavailable",
                "The BShare network was not available.",
                null
            )
            return
        }

        val securityType = securityCandidates[candidateIndex]
        val specifierBuilder = WifiNetworkSpecifier.Builder().setSsid(ssid)
        if (password.isNotEmpty() && securityType != "OPEN") {
            specifierBuilder.setWpa2Passphrase(password)
        }

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifierBuilder.build())
            .build()

        var completed = false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                connectivityManager.bindProcessToNetwork(network)
                if (!completed) {
                    completed = true
                    runOnUiThread { result.success(null) }
                }
            }

            override fun onUnavailable() {
                if (!completed) {
                    completed = true
                    if (wifiNetworkCallback === this) {
                        wifiNetworkCallback = null
                    }
                    try {
                        connectivityManager.unregisterNetworkCallback(this)
                    } catch (_: Exception) {
                    }
                    mainHandler.postDelayed({
                        requestWifiNetwork(
                            connectivityManager,
                            ssid,
                            password,
                            securityCandidates,
                            candidateIndex + 1,
                            result
                        )
                    }, WIFI_RETRY_DELAY_MS)
                }
            }

            override fun onLost(network: Network) {
                if (wifiNetworkCallback === this) {
                    connectivityManager.bindProcessToNetwork(null)
                    wifiNetworkCallback = null
                }
            }
        }

        wifiNetworkCallback = callback
        try {
            connectivityManager.requestNetwork(request, callback, WIFI_REQUEST_TIMEOUT_MS)
        } catch (error: Exception) {
            if (wifiNetworkCallback === callback) {
                wifiNetworkCallback = null
            }
            try {
                connectivityManager.unregisterNetworkCallback(callback)
            } catch (_: Exception) {
            }
            if (error is SecurityException) {
                result.error("wifi_connect_failed", error.message, null)
                return
            }
            mainHandler.postDelayed({
                requestWifiNetwork(
                    connectivityManager,
                    ssid,
                    password,
                    securityCandidates,
                    candidateIndex + 1,
                    result
                )
            }, WIFI_RETRY_DELAY_MS)
        }
    }

    private fun wifiSecurityCandidates(password: String): List<String> {
        if (password.isBlank()) return listOf("OPEN")
        return listOf("WPA2")
    }

    @Suppress("DEPRECATION")
    private fun connectToLegacyWifi(
        wifiManager: WifiManager,
        ssid: String?,
        password: String,
        result: MethodChannel.Result
    ) {
        if (ssid.isNullOrBlank()) {
            result.error("wifi_connect_invalid", "Missing Wi-Fi name.", null)
            return
        }
        if (!wifiManager.isWifiEnabled) {
            val enabled = wifiManager.setWifiEnabled(true)
            if (!enabled) {
                result.error("wifi_enable_failed", "Wi-Fi could not be enabled.", null)
                return
            }
        }

        val config = WifiConfiguration().apply {
            SSID = quoteWifiValue(ssid.trim())
            if (password.isBlank()) {
                allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE)
            } else {
                preSharedKey = quoteWifiValue(password)
            }
        }
        try {
            val networkId = wifiManager.addNetwork(config)
            if (networkId == -1) {
                result.error("wifi_connect_unavailable", "The BShare network was not available.", null)
                return
            }
            wifiManager.disconnect()
            wifiManager.enableNetwork(networkId, true)
            wifiManager.reconnect()
            result.success(null)
        } catch (error: Exception) {
            result.error("wifi_connect_failed", error.message, null)
        }
    }

    private fun openWifiJoinSettings(
        ssid: String?,
        password: String,
        result: MethodChannel.Result
    ) {
        if (ssid.isNullOrBlank()) {
            result.error("wifi_join_invalid", "Missing Wi-Fi name.", null)
            return
        }

        try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val suggestionBuilder = WifiNetworkSuggestion.Builder().setSsid(ssid.trim())
                if (password.isNotEmpty()) {
                    suggestionBuilder.setWpa2Passphrase(password)
                }
                Intent(Settings.ACTION_WIFI_ADD_NETWORKS).apply {
                    putParcelableArrayListExtra(
                        Settings.EXTRA_WIFI_NETWORK_LIST,
                        arrayListOf(suggestionBuilder.build())
                    )
                }
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Intent(Settings.Panel.ACTION_WIFI)
            } else {
                Intent(Settings.ACTION_WIFI_SETTINGS)
            }
            startActivity(intent)
            result.success(null)
        } catch (error: ActivityNotFoundException) {
            result.error("wifi_settings_unavailable", error.message, null)
        } catch (error: Exception) {
            result.error("wifi_settings_failed", error.message, null)
        }
    }

    private fun ensureWifiReady(result: MethodChannel.Result) {
        val wifiManager = applicationContext.getSystemService(WifiManager::class.java)
        if (wifiManager.isWifiEnabled) {
            result.success(true)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            result.success(false)
            return
        }
        try {
            @Suppress("DEPRECATION")
            result.success(wifiManager.setWifiEnabled(true))
        } catch (error: Exception) {
            result.error("wifi_enable_failed", error.message, null)
        }
    }

    private fun openWifiPanel(result: MethodChannel.Result) {
        try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Intent(Settings.Panel.ACTION_WIFI)
            } else {
                Intent(Settings.ACTION_WIFI_SETTINGS)
            }
            startActivity(intent)
            result.success(null)
        } catch (error: ActivityNotFoundException) {
            result.error("wifi_panel_unavailable", error.message, null)
        } catch (error: Exception) {
            result.error("wifi_panel_failed", error.message, null)
        }
    }

    private fun hasWifiNetwork(result: MethodChannel.Result) {
        val connectivityManager = applicationContext.getSystemService(ConnectivityManager::class.java)
        for (network in connectivityManager.allNetworks) {
            val capabilities = connectivityManager.getNetworkCapabilities(network) ?: continue
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                result.success(true)
                return
            }
        }
        result.success(false)
    }

    private fun bindToCurrentWifi(result: MethodChannel.Result) {
        val connectivityManager = applicationContext.getSystemService(ConnectivityManager::class.java)
        for (network in connectivityManager.allNetworks) {
            val capabilities = connectivityManager.getNetworkCapabilities(network) ?: continue
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                connectivityManager.bindProcessToNetwork(network)
                result.success(true)
                return
            }
        }
        result.success(false)
    }

    private fun bindToWifiForHost(
        host: String?,
        port: Int,
        path: String,
        result: MethodChannel.Result
    ) {
        if (host.isNullOrBlank() || port <= 0) {
            result.error("wifi_bind_invalid", "Missing receiver address.", null)
            return
        }
        val connectivityManager = applicationContext.getSystemService(ConnectivityManager::class.java)
        thread {
            val networks = connectivityManager.allNetworks
            for (network in networks) {
                val capabilities = connectivityManager.getNetworkCapabilities(network) ?: continue
                if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
                if (canReachHost(network, host.trim(), port, path)) {
                    connectivityManager.bindProcessToNetwork(network)
                    runOnUiThread { result.success(true) }
                    return@thread
                }
            }
            runOnUiThread { result.success(false) }
        }
    }

    private fun canReachHost(
        network: Network,
        host: String,
        port: Int,
        path: String
    ): Boolean {
        var connection: HttpURLConnection? = null
        return try {
            val normalizedPath = if (path.startsWith("/")) path else "/$path"
            val url = URL("http", host, port, normalizedPath)
            connection = network.openConnection(url) as HttpURLConnection
            connection.requestMethod = "GET"
            connection.connectTimeout = WIFI_HOST_PROBE_TIMEOUT_MS
            connection.readTimeout = WIFI_HOST_PROBE_TIMEOUT_MS
            connection.useCaches = false
            val status = connection.responseCode
            status in 200..299
        } catch (_: Exception) {
            false
        } finally {
            connection?.disconnect()
        }
    }

    private fun disconnectWifi() {
        val connectivityManager = applicationContext.getSystemService(ConnectivityManager::class.java)
        connectivityManager.bindProcessToNetwork(null)
        wifiNetworkCallback?.let {
            try {
                connectivityManager.unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        wifiNetworkCallback = null
    }

    private fun listInstalledApps(): List<Map<String, Any>> {
        val launcherIntent = Intent(Intent.ACTION_MAIN, null).addCategory(Intent.CATEGORY_LAUNCHER)
        val launchable = packageManager.queryIntentActivities(launcherIntent, PackageManager.MATCH_ALL)
        return launchable.mapNotNull { item ->
            try {
                val appInfo = packageManager.getApplicationInfo(item.activityInfo.packageName, 0)
                val source = appInfo.publicSourceDir ?: appInfo.sourceDir ?: return@mapNotNull null
                val file = File(source)
                mapOf(
                    "name" to packageManager.getApplicationLabel(appInfo).toString(),
                    "packageName" to item.activityInfo.packageName,
                    "sourcePath" to source,
                    "size" to file.length(),
                    "iconBase64" to drawableToBase64(packageManager.getApplicationIcon(appInfo))
                )
            } catch (_: Exception) {
                null
            }
        }.distinctBy { it["packageName"] as String }.sortedBy { (it["name"] as String).lowercase() }
    }

    private fun drawableToBase64(drawable: Drawable): String {
        val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
            drawable.bitmap
        } else {
            val size = 64
            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, canvas.width, canvas.height)
            drawable.draw(canvas)
            bitmap
        }
        val output = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 90, output)
        return Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP)
    }

    private fun cleanWifiValue(value: String?): String? {
        return value?.trim()?.trim('"')
    }

    private fun quoteWifiValue(value: String): String {
        val clean = value.trim().trim('"')
        return "\"$clean\""
    }

    companion object {
        private const val WIFI_REQUEST_TIMEOUT_MS = 12000
        private const val WIFI_RETRY_DELAY_MS = 700L
        private const val WIFI_HOST_PROBE_TIMEOUT_MS = 1500
        private const val SHARE_CACHE_MAX_AGE_MS = 24L * 60L * 60L * 1000L
    }
}
