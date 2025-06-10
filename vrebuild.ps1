# PowerShell script to clean, build, install, and launch the Flutter debug APK on an emulator

param(
    [int]$BuildType
)

if (-not $PSBoundParameters.ContainsKey('BuildType')) {
    $BuildType = Read-Host "Build type: (1) Debug only, (2) Debug and Release? Enter 1 or 2"
}

$apkDebugPath = "android/app/build/outputs/flutter-apk/app-debug.apk"
$apkDebugFallback = "android/app/build/outputs/apk/debug/app-debug.apk"
$apkReleasePath = "android/app/build/outputs/flutter-apk/app-release.apk"
$apkReleaseFallback = "android/app/build/outputs/apk/release/app-release.apk"

# Get the last write time before build (debug)
$preBuildTime = $null
if (Test-Path $apkDebugPath) {
    $preBuildTime = (Get-Item $apkDebugPath).LastWriteTimeUtc
    Write-Host "Pre-build debug APK timestamp: $preBuildTime"
} else {
    Write-Host "No existing debug APK found before build"
}

flutter clean
if ($LASTEXITCODE -ne 0) { Write-Host "flutter clean failed!"; exit 1 }

flutter pub get
if ($LASTEXITCODE -ne 0) { Write-Host "flutter pub get failed!"; exit 1 }

# Build debug APK
flutter build apk --debug

# Optionally build release APK
if ($BuildType -eq 2) {
    flutter build apk --release
}

# Check if the debug APK exists and was updated
$apkDebug = $null
if (Test-Path $apkDebugPath) {
    $postBuildTime = (Get-Item $apkDebugPath).LastWriteTimeUtc
    Write-Host "Post-build debug APK timestamp: $postBuildTime"
    
    if ($preBuildTime -eq $null) {
        Write-Host "New debug APK created. Proceeding."
        $apkDebug = $apkDebugPath
    } elseif ($postBuildTime -gt $preBuildTime) {
        Write-Host "Debug APK updated. Proceeding."
        $apkDebug = $apkDebugPath
    } else {
        Write-Host "ERROR: Debug APK timestamp did not change after build. This indicates the build did not complete successfully."
        Write-Host "Pre-build time: $preBuildTime"
        Write-Host "Post-build time: $postBuildTime"
        exit 1
    }
} elseif (Test-Path $apkDebugFallback) {
    Write-Host "Using fallback debug APK path: $apkDebugFallback"
    $apkDebug = $apkDebugFallback
} else {
    Write-Host "No debug APK found!"; exit 1
}

# Check if the release APK exists
$apkRelease = $null
if ($BuildType -eq 2) {
    if (Test-Path $apkReleasePath) {
        Write-Host "Release APK found at $apkReleasePath"
        $apkRelease = $apkReleasePath
    } elseif (Test-Path $apkReleaseFallback) {
        Write-Host "Using fallback release APK path: $apkReleaseFallback"
        $apkRelease = $apkReleaseFallback
    } else {
        Write-Host "No release APK found!"
    }
}

# Always copy the APKs to a known location for one-click install/distribution
if (!(Test-Path "build")) { mkdir "build" | Out-Null }
$targetDebugApk = "build/app-debug.apk"
$targetReleaseApk = "build/app-release.apk"
Copy-Item $apkDebug $targetDebugApk -Force
if ($apkRelease) { Copy-Item $apkRelease $targetReleaseApk -Force }

# Install the debug APK using adb
adb install -r $targetDebugApk
if ($LASTEXITCODE -ne 0) { Write-Host "APK install failed!"; exit 1 }

# Launch the app using the correct package name
adb shell monkey -p com.example.vre_new -c android.intent.category.LAUNCHER 1
if ($LASTEXITCODE -ne 0) { Write-Host "App launch failed!"; exit 1 }

# Pause at the end so you can see the result
Write-Host "`nScript complete. APKs are in the build directory. Press Enter to exit."
Read-Host