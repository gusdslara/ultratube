import java.util.Properties

plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }

// Release signing: android/key.properties (storeFile, storePassword, keyAlias, keyPassword),
// never committed. Without it the release build falls back to the debug key.
val keystoreFile = rootProject.file("key.properties")
val keystore = Properties().apply { if (keystoreFile.exists()) keystoreFile.inputStream().use { load(it) } }

android {
    namespace = "app.ultratube.wear"
    compileSdk = libs.versions.compileSdk.get().toInt()
    defaultConfig { applicationId = "app.ultratube.wear"; minSdk = libs.versions.minSdkWear.get().toInt(); targetSdk = 35; versionCode = 7; versionName = "0.5.1"; testInstrumentationRunner = "app.ultratube.wear.CatalogSmoke" }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    signingConfigs {
        if (keystoreFile.exists()) create("release") {
            storeFile = file(keystore.getProperty("storeFile"))
            storePassword = keystore.getProperty("storePassword")
            keyAlias = keystore.getProperty("keyAlias")
            keyPassword = keystore.getProperty("keyPassword")
        }
    }
    // Same policy as the phone app: without a release keystore, sign with the debug key.
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName(if (keystoreFile.exists()) "release" else "debug")
        }
    }
}
dependencies {
    implementation(project(":media"))
    implementation(libs.viewpager2)
    implementation(libs.activity.ktx)
    // QR code for "Entrar com o celular" (encoder only, no camera).
    implementation(libs.zxing.core)
}
