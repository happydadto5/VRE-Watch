import org.gradle.api.tasks.compile.JavaCompile
import org.gradle.api.JavaVersion // Import JavaVersion

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.vre_new"
    compileSdk = flutter.compileSdkVersion
    // Explicitly set the NDK version required by plugins.
    // Removed duplicate and conflicting ndkVersion lines.
    ndkVersion = "27.0.12077973"


    compileOptions {
        // Enable core library desugaring for Java 8+ features
        isCoreLibraryDesugaringEnabled = true // Using the 'is' prefix which is sometimes needed in Kotlin DSL
        sourceCompatibility = JavaVersion.VERSION_1_8 // Set source compatibility to 1.8
        targetCompatibility = JavaVersion.VERSION_1_8 // Set target compatibility to 1.8
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_1_8.toString() // Set JVM target to 1.8
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.vre_new"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 21 // Set minimum SDK to 21 for foreground service support
        // Explicitly setting targetSdk to a version known to work well with flutter_local_notifications 15.1.1
        targetSdk = 34 // Setting target SDK to 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Add the core library desugaring dependency
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4") // Correct Kotlin DSL syntax for dependency
    implementation("androidx.multidex:multidex:2.0.1")
    implementation("androidx.core:core:1.13.1")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")

    // Removed duplicate tasks.withType<JavaCompile> blocks for clarity,
    // keeping only one instance as they appear identical in your provided content.
}

// Add a resolution strategy to force a specific version of androidx.core across all configurations
// This is the most effective way to fix the bigLargeIcon ambiguity in Kotlin DSL.
configurations.all {
    resolutionStrategy {
        // Force a specific version of androidx.core:core and core-ktx
        // Using a recent stable version known to work well
        force("androidx.core:core:1.13.1")
        force("androidx.core:core-ktx:1.13.1")
    }
}


tasks.withType<JavaCompile> {
    options.compilerArgs.add("-Xlint:-options")
}
