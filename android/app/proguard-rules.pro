# mobile_scanner 7.2.0 only keeps com.google.mlkit.* (one package level).
# ML Kit discovers its registrars by manifest names and invokes their no-arg
# constructors through reflection. R8 full mode otherwise removes those
# constructors, and BarcodeScanning.getClient then fails on scanner startup.
# Match the upstream fixes without disabling optimization for the rest of BShare:
# https://github.com/juliansteenbakker/mobile_scanner/pull/1726
# https://github.com/juliansteenbakker/mobile_scanner/commit/5825d7a
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.* { *; }
