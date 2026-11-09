const { createRunOncePlugin, withAndroidManifest } = require("@expo/config-plugins");

function withPumpTimerForegroundService(config) {
  return withAndroidManifest(config, (modConfig) => {
    const manifest = modConfig.modResults.manifest;
    const permissions = manifest["uses-permission"] ?? [];
    for (const permission of [
      "android.permission.FOREGROUND_SERVICE",
      "android.permission.FOREGROUND_SERVICE_SPECIAL_USE",
    ]) {
      if (!permissions.some((entry) => entry.$?.["android:name"] === permission)) {
        permissions.push({ $: { "android:name": permission } });
      }
    }
    manifest["uses-permission"] = permissions;

    const application = manifest.application?.[0];
    if (!application) throw new Error("Android application node is missing.");
    application.service = application.service ?? [];
    const serviceName = "expo.modules.pumptimer.PumpTimerForegroundService";
    let service = application.service.find((entry) => entry.$?.["android:name"] === serviceName);
    if (!service) {
      service = { $: { "android:name": serviceName } };
      application.service.push(service);
    }
    service.$ = {
      ...service.$,
      "android:name": serviceName,
      "android:enabled": "true",
      "android:exported": "false",
      "android:stopWithTask": "false",
      "android:foregroundServiceType": "specialUse",
    };
    service.property = service.property ?? [];
    const propertyName = "android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE";
    let property = service.property.find((entry) => entry.$?.["android:name"] === propertyName);
    if (!property) {
      property = { $: { "android:name": propertyName } };
      service.property.push(property);
    }
    property.$ = {
      ...property.$,
      "android:name": propertyName,
      "android:value": "User-visible countdown for an operator-started water pump filling session; keeps the remaining-time notification visible while the app UI is backgrounded.",
    };
    return modConfig;
  });
}

module.exports = createRunOncePlugin(
  withPumpTimerForegroundService,
  "with-pump-timer-foreground-service",
  "1.0.0",
);
