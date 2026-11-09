package expo.modules.pumptimer

import android.content.Intent
import android.os.Build
import expo.modules.kotlin.exception.Exceptions
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class PumpTimerModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("PumpTimer")

    AsyncFunction("startTimer") { operationId: String, endAtEpochMs: Double ->
      require(operationId.isNotBlank()) { "A pump operation ID is required." }
      require(endAtEpochMs.isFinite() && endAtEpochMs > 0.0) { "A valid timer end timestamp is required." }
      startForegroundService(
        serviceIntent(PumpTimerForegroundService.ACTION_START)
          .putExtra(PumpTimerForegroundService.EXTRA_OPERATION_ID, operationId)
          .putExtra(PumpTimerForegroundService.EXTRA_END_AT, endAtEpochMs.toLong()),
      )
    }

    AsyncFunction("pauseTimer") { operationId: String, remainingMs: Double ->
      require(operationId.isNotBlank()) { "A pump operation ID is required." }
      require(remainingMs.isFinite() && remainingMs >= 0.0) { "Remaining time must be zero or greater." }
      startForegroundService(
        serviceIntent(PumpTimerForegroundService.ACTION_PAUSE)
          .putExtra(PumpTimerForegroundService.EXTRA_OPERATION_ID, operationId)
          .putExtra(PumpTimerForegroundService.EXTRA_REMAINING_MS, remainingMs.toLong()),
      )
    }

    AsyncFunction("stopTimer") {
      val context = appContext.reactContext ?: throw Exceptions.ReactContextLost()
      // This is a stop command, not a new foreground-service start.
      context.startService(serviceIntent(PumpTimerForegroundService.ACTION_STOP))
    }
  }

  private fun serviceIntent(action: String): Intent {
    val context = appContext.reactContext ?: throw Exceptions.ReactContextLost()
    return Intent(context, PumpTimerForegroundService::class.java).setAction(action)
  }

  private fun startForegroundService(intent: Intent) {
    val context = appContext.reactContext ?: throw Exceptions.ReactContextLost()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
    else context.startService(intent)
  }
}
