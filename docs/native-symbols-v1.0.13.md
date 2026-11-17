# Puffle v1.0.13 (version code 14) native symbols

The original release did not retain native symbol artifacts. Its packaged libraries
are stripped, so an archive of the packaged `.so` files is not a valid recovery.

`tool/recover_v1_0_13_native_symbols.py` downloads official Flutter 3.27.4 engine
symbols at the pinned engine revision, verifies the input AAB SHA-256, and requires
an exact GNU build-ID match for each arm, arm64, and x64 engine library. It then
creates the ABI-folder ZIP expected by Play Console and a verification report.
The recovery workflow publishes these two additional release assets without
rebuilding, replacing, or resigning any APK or AAB.

Coverage: this archive supplies `libflutter.so` engine symbols for all three
release architectures. Original Dart AOT `libapp.so` symbols and the AndroidX
datastore library symbols are unavailable; the report makes this limitation
explicit. Uploading engine symbols improves native engine crash diagnostics but
does not provide complete app symbolication. Play Console acceptance and the
warning state must be checked after upload; neither is proven by local validation.

In Play Console, open Test and release > App bundle explorer, choose version code
14, then Downloads > Assets > Native debug symbols and upload the ZIP. Do not
upload it as an app bundle or as a Java mapping file. Existing app bundles and
the payment flow are unchanged.

For future release builds, retain per-build Dart split-debug-info outputs, R8
mapping files, and native symbols. Never reuse app-specific symbols across
different builds without verifying their build IDs.
