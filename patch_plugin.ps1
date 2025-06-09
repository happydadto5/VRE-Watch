# PowerShell script to patch flutter_foreground_task locally

# Step 1: Create the local plugin directory
$localPluginDir = "local_plugins/flutter_foreground_task"
if (-Not (Test-Path $localPluginDir)) {
    New-Item -ItemType Directory -Path $localPluginDir -Force
    Write-Host "Created directory: $localPluginDir"
} else {
    Write-Host "Directory already exists: $localPluginDir"
}

# Step 2: Copy the plugin from pub cache
$cachePath = "$env:USERPROFILE\AppData\Local\Pub\Cache\hosted\pub.dev\flutter_foreground_task-4.2.0\*"
Copy-Item -Path $cachePath -Destination $localPluginDir -Recurse -Force
Write-Host "Copied plugin files to: $localPluginDir"

# Step 3: Add the namespace to build.gradle
$gradleFile = "$localPluginDir\android\build.gradle"
$content = Get-Content $gradleFile
if ($content -notmatch "namespace 'com.pravera.flutter_foreground_task'") {
    $newContent = $content -replace '(android\s*\{)', "`$1`r`n    namespace 'com.pravera.flutter_foreground_task'"
    Set-Content $gradleFile $newContent
    Write-Host "Added namespace to: $gradleFile"
} else {
    Write-Host "Namespace already exists in: $gradleFile"
}

# Step 4: Update pubspec.yaml to use the local path
$pubspec = "pubspec.yaml"
$yaml = Get-Content $pubspec
$pattern = 'flutter_foreground_task:.*'
$replacement = "flutter_foreground_task:`r`n    path: local_plugins/flutter_foreground_task"
$yaml = $yaml -replace $pattern, $replacement
Set-Content $pubspec $yaml
Write-Host "Updated pubspec.yaml to use local plugin"

# Step 5: Run flutter pub get
flutter pub get
Write-Host "Ran flutter pub get"

Write-Host "`nScript complete. Press Enter to exit."
Read-Host 