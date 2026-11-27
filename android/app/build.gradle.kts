import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

fun computeVersionCode(rawVersion: String): Int {
    val clean = rawVersion.removePrefix("v").substringBefore("-")
    val parts = clean.split(".")
    val major = parts.getOrNull(0)?.toIntOrNull() ?: 0
    val minor = parts.getOrNull(1)?.toIntOrNull() ?: 0
    val patch = parts.getOrNull(2)?.toIntOrNull() ?: 0
    return maxOf(1, major * 10000 + minor * 100 + patch)
}

val appVersion: String = providers.gradleProperty("appVersion")
    .orElse(providers.environmentVariable("APP_VERSION"))
    .orElse("1.0.0")
    .get()
    .removePrefix("v")

android {
    compileSdk {
        version = release(37) { minorApiLevel = 2 }
    }
    buildToolsVersion = "37.0.0"
    namespace = "com.gosu.cloudtune"

    defaultConfig {
        applicationId = "com.gosu.cloudtune"
        minSdk = 31
        targetSdk = 36
        ndk {
            abiFilters += "arm64-v8a"
        }
        versionCode = computeVersionCode(appVersion)
        versionName = appVersion
    }

    val signingPath = System.getenv("CLOUDTUNE_ANDROID_SIGNING_PROPERTIES")
    if (!signingPath.isNullOrBlank()) {
        val signing = Properties().apply {
            file(signingPath).inputStream().use { load(it) }
        }
        signingConfigs.create("release") {
            storeFile = file(signing.getProperty("storeFile"))
            storePassword = signing.getProperty("storePassword")
            keyAlias = signing.getProperty("keyAlias")
            keyPassword = signing.getProperty("keyPassword")
        }
    }

    buildTypes {
        getByName("debug") {
            isDebuggable = true
            isMinifyEnabled = false
        }
        getByName("release") {
            signingConfigs.findByName("release")?.let { signingConfig = it }
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }

    lint {
        abortOnError = true
        checkReleaseBuilds = true
        disable += setOf("GradleDependency", "AndroidGradlePluginVersion", "NewerVersionAvailable")
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            isReturnDefaultValues = true
            all {
                it.systemProperty("robolectric.graphicsMode", "NATIVE")
                it.environment("CLOUDTUNE_RENDER_SNAPSHOTS", System.getenv("CLOUDTUNE_RENDER_SNAPSHOTS") ?: "0")
            }
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
    implementation("androidx.core:core-ktx:1.19.1")
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    implementation("androidx.media3:media3-session:1.11.1")
    implementation("androidx.media3:media3-ui:1.11.1")
    implementation("com.google.zxing:core:3.5.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("org.json:json:20260814")
    testImplementation("org.robolectric:robolectric:4.18.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
