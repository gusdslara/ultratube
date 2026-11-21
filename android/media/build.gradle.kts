plugins { id("com.android.library"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "app.ultratube.media"
    compileSdk = 35
    defaultConfig { minSdk = 26 }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
    api("androidx.media3:media3-exoplayer:1.5.1")
    api("androidx.media3:media3-session:1.5.1")
    api("androidx.media3:media3-ui:1.5.1")
    // Lives (YouTube HLS renditions, Twitch) on native surfaces.
    api("androidx.media3:media3-exoplayer-hls:1.5.1")
    // Watch-face chip for the playing session.
    implementation("androidx.wear:wear-ongoing:1.0.0")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("com.github.TeamNewPipe:NewPipeExtractor:v0.27.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.1")
    testImplementation("junit:junit:4.13.2")
    // Real org.json on the JVM (android.jar only has stubs).
    testImplementation("org.json:json:20240303")
}
