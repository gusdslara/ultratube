plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "app.ultratube.wear"
    compileSdk = libs.versions.compileSdk.get().toInt()
    defaultConfig { applicationId = "app.ultratube.wear"; minSdk = libs.versions.minSdkWear.get().toInt(); targetSdk = 35; versionCode = 7; versionName = "0.5.1"; testInstrumentationRunner = "app.ultratube.wear.CatalogSmoke" }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    // Same policy as the phone app: without a release keystore, sign with the debug key so it installs over dev builds.
    buildTypes { release { isMinifyEnabled = false; signingConfig = signingConfigs.getByName("debug") } }
}
dependencies {
    implementation(project(":media"))
    implementation(libs.viewpager2)
    implementation(libs.activity.ktx)
    // QR code for "Entrar com o celular" (encoder only, no camera).
    implementation(libs.zxing.core)
}
