plugins { id("com.android.library"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "app.ultratube.media"
    compileSdk = libs.versions.compileSdk.get().toInt()
    defaultConfig { minSdk = libs.versions.minSdkMedia.get().toInt() }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
    // Versions: android/gradle/libs.versions.toml (shared by the phone and watch builds).
    api(libs.bundles.media3)
    // Watch-face chip for the playing session.
    implementation(libs.wear.ongoing)
    implementation(libs.core.ktx)
    implementation(libs.newpipe.extractor)
    implementation(libs.okhttp)
    implementation(libs.coroutines.android)
    testImplementation(libs.junit)
    // Real org.json on the JVM (android.jar only has stubs).
    testImplementation(libs.json)
}
