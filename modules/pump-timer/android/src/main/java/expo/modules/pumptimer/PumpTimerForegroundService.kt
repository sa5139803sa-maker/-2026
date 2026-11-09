package expo.modules.pumptimer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import java.util.Locale

class PumpTimerForegroundService : Service() {
  companion object {
    const val ACTION_START = "expo.modules.pumptimer.action.START"
    const val ACTION_PAUSE = "expo.modules.pumptimer.action.PAUSE"
    const val ACTION_STOP = "expo.modules.pumptimer.action.STOP"
    const val EXTRA_OPERATION_ID = "operation_id"
    const val EXTRA_END_AT = "end_at_epoch_ms"
    const val EXTRA_REMAINING_MS = "remaining_ms"
    private const val CHANNEL_ID = "water-pump-timer-ongoing-v1"
    private const val NOTIFICATION_ID = 57031
    private const val PREFERENCES = "water_pump_timer_foreground_state"
    private const val KEY_MODE = "mode"
    private const val KEY_END_AT = "end_at_epoch_ms"
    private const val KEY_REMAINING_MS = "remaining_ms"
    private const val MODE_RUNNING = "running"
    private const val MODE_PAUSED = "paused"
  }

  override fun onCreate() {
    super.onCreate()
    createNotificationChannel()
  }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_START -> {
        val operationId = intent.getStringExtra(EXTRA_OPERATION_ID).orEmpty()
        val endAt = intent.getLongExtra(EXTRA_END_AT, 0L)
        if (operationId.isBlank() || endAt <= 0L) {
          stopServiceAndClearState(startId)
          return START_NOT_STICKY
        }
        preferences().edit()
          .putString(KEY_MODE, MODE_RUNNING)
          .putString(EXTRA_OPERATION_ID, operationId)
          .putLong(KEY_END_AT, endAt)
          .remove(KEY_REMAINING_MS)
          .apply()
        startAsForeground(buildRunningNotification(endAt))
      }
      ACTION_PAUSE -> {
        val operationId = intent.getStringExtra(EXTRA_OPERATION_ID).orEmpty()
        val remaining = intent.getLongExtra(EXTRA_REMAINING_MS, 0L).coerceAtLeast(0L)
        if (operationId.isBlank()) {
          stopServiceAndClearState(startId)
          return START_NOT_STICKY
        }
        preferences().edit()
          .putString(KEY_MODE, MODE_PAUSED)
          .putString(EXTRA_OPERATION_ID, operationId)
          .putLong(KEY_REMAINING_MS, remaining)
          .remove(KEY_END_AT)
          .apply()
        startAsForeground(buildPausedNotification(remaining))
      }
      ACTION_STOP -> {
        stopServiceAndClearState(startId)
        return START_NOT_STICKY
      }
      else -> restorePersistedNotification(startId)
    }
    return START_STICKY
  }

  private fun preferences() = getSharedPreferences(PREFERENCES, MODE_PRIVATE)

  private fun restorePersistedNotification(startId: Int) {
    val prefs = preferences()
    when (prefs.getString(KEY_MODE, null)) {
      MODE_RUNNING -> {
        val endAt = prefs.getLong(KEY_END_AT, 0L)
        if (endAt > 0L) startAsForeground(buildRunningNotification(endAt))
        else stopServiceAndClearState(startId)
      }
      MODE_PAUSED -> {
        val remaining = prefs.getLong(KEY_REMAINING_MS, 0L).coerceAtLeast(0L)
        startAsForeground(buildPausedNotification(remaining))
      }
      else -> stopServiceAndClearState(startId)
    }
  }

  private fun createNotificationChannel() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val channel = NotificationChannel(
      CHANNEL_ID,
      "عداد التعبئة المستمر",
      NotificationManager.IMPORTANCE_LOW,
    ).apply {
      description = "يعرض الوقت المتبقي للتعبئة أثناء عمل التطبيق في الخلفية"
      lockscreenVisibility = Notification.VISIBILITY_PUBLIC
      setShowBadge(false)
      enableVibration(false)
      setSound(null, null)
      enableLights(false)
    }
    getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
  }

  private fun baseBuilder(): Notification.Builder {
    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      Notification.Builder(this, CHANNEL_ID)
    } else {
      Notification.Builder(this)
    }
    builder
      .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
      .setContentTitle("عداد التعبئة")
      .setCategory(Notification.CATEGORY_SERVICE)
      .setVisibility(Notification.VISIBILITY_PUBLIC)
      .setOngoing(true)
      .setAutoCancel(false)
      .setOnlyAlertOnce(true)
      .setShowWhen(true)
      .setContentIntent(openAppPendingIntent())
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) builder.setSilent(true)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
    }
    return builder
  }

  private fun buildRunningNotification(endAt: Long): Notification {
    val builder = baseBuilder()
      .setContentText("التعبئة جارية — الوقت المتبقي")
      .setWhen(endAt)
      .setUsesChronometer(true)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) builder.setChronometerCountDown(true)
    return builder.build()
  }

  private fun buildPausedNotification(remainingMs: Long): Notification =
    baseBuilder()
      .setContentTitle("عداد التعبئة متوقف مؤقتًا")
      .setContentText("الوقت المتبقي: \${formatDuration(remainingMs)}")
      .setShowWhen(false)
      .setUsesChronometer(false)
      .build()

  private fun formatDuration(milliseconds: Long): String {
    val totalSeconds = (milliseconds.coerceAtLeast(0L) + 999L) / 1000L
    val hours = totalSeconds / 3600L
    val minutes = (totalSeconds % 3600L) / 60L
    val seconds = totalSeconds % 60L
    return if (hours > 0L) String.format(Locale.US, "%d:%02d:%02d", hours, minutes, seconds)
    else String.format(Locale.US, "%02d:%02d", minutes, seconds)
  }

  private fun openAppPendingIntent(): PendingIntent? {
    val launchIntent = packageManager.getLaunchIntentForPackage(packageName) ?: return null
    launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    return PendingIntent.getActivity(this, NOTIFICATION_ID, launchIntent, flags)
  }

  private fun startAsForeground(notification: Notification) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
    } else {
      startForeground(NOTIFICATION_ID, notification)
    }
  }

  private fun stopServiceAndClearState(startId: Int) {
    preferences().edit().clear().apply()
    stopForeground(STOP_FOREGROUND_REMOVE)
    stopSelf(startId)
  }
}
