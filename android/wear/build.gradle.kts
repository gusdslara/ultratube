plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "app.ultratube.wear"
    compileSdk = 35
    defaultConfig { applicationId = "app.ultratube.wear"; minSdk = 30; targetSdk = 35; versionCode = 5; versionName = "0.4.1"; testInstrumentationRunner = "app.ultratube.wear.CatalogSmoke" }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    // Same policy as the phone app: without a release keystore, sign with the debug key so it installs over dev builds.
    buildTypes { release { isMinifyEnabled = false; signingConfig = signingConfigs.getByName("debug") } }
}
dependencies {
    implementation(project(":media"))
    implementation("androidx.viewpager2:viewpager2:1.1.0")
    implementation("androidx.activity:activity-ktx:1.9.3")
}
