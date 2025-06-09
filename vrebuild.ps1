# PowerShell script to clean, build, install, and launch the Flutter debug APK on an emulator

flutter clean
if ($LASTEXITCODE -ne 0) { Write-Host "flutter clean failed!"; exit 1 }

flutter pub get
if ($LASTEXITCODE -ne 0) { Write-Host "flutter pub get failed!"; exit 1 }

flutter build apk --debug
if ($LASTEXITCODE -ne 0) { Write-Host "APK build failed!"; exit 1 }

# Find the debug APK (prefer flutter-apk, fallback to apk/debug)
$apk1 = "android/app/build/outputs/flutter-apk/app-debug.apk"
$apk2 = "android/app/build/outputs/apk/debug/app-debug.apk"

if (Test-Path $apk1) {
    $apk = $apk1
} elseif (Test-Path $apk2) {
    $apk = $apk2
} else {
    Write-Host "No debug APK found!"; exit 1
}

# Always copy the APK to a known location for one-click install
$targetApk = "build/app-debug.apk"
if (!(Test-Path "build")) { mkdir "build" | Out-Null }
Copy-Item $apk $targetApk -Force

# Install the APK using adb
adb install -r $targetApk
if ($LASTEXITCODE -ne 0) { Write-Host "APK install failed!"; exit 1 }

# Launch the app using the correct package name
adb shell monkey -p com.example.vre_new -c android.intent.category.LAUNCHER 1
if ($LASTEXITCODE -ne 0) { Write-Host "App launch failed!"; exit 1 }

# Pause at the end so you can see the result
Write-Host "`nScript complete. Press Enter to exit."
Read-Host