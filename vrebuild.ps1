# PowerShell script to clean, build, install, and launch the Flutter debug APK on an emulator

$apkPath = "android/app/build/outputs/flutter-apk/app-debug.apk"
$apkFallback = "android/app/build/outputs/apk/debug/app-debug.apk"

# Get the last write time before build
$preBuildTime = $null
if (Test-Path $apkPath) {
    $preBuildTime = (Get-Item $apkPath).LastWriteTimeUtc
    Write-Host "Pre-build APK timestamp: $preBuildTime"
} else {
    Write-Host "No existing APK found before build"
}

flutter clean
if ($LASTEXITCODE -ne 0) { Write-Host "flutter clean failed!"; exit 1 }

flutter pub get
if ($LASTEXITCODE -ne 0) { Write-Host "flutter pub get failed!"; exit 1 }

flutter build apk --debug
# Don't exit on build failure - we'll check the APK timestamp instead

# Check if the APK exists and was updated
$apk = $null
if (Test-Path $apkPath) {
    $postBuildTime = (Get-Item $apkPath).LastWriteTimeUtc
    Write-Host "Post-build APK timestamp: $postBuildTime"
    
    if ($preBuildTime -eq $null) {
        Write-Host "New APK created. Proceeding."
        $apk = $apkPath
    } elseif ($postBuildTime -gt $preBuildTime) {
        Write-Host "APK updated. Proceeding."
        $apk = $apkPath
    } else {
        Write-Host "ERROR: APK timestamp did not change after build. This indicates the build did not complete successfully."
        Write-Host "Pre-build time: $preBuildTime"
        Write-Host "Post-build time: $postBuildTime"
        exit 1
    }
} elseif (Test-Path $apkFallback) {
    Write-Host "Using fallback APK path: $apkFallback"
    $apk = $apkFallback
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