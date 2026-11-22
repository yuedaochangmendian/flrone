repositories {
    // Maven Central rate-limits the shared GitHub Actions egress: CI hit HTTP 429
    // while resolving junit/org.json (2026-11-22), which failed the unit-test job
    // on unchanged code. The Aliyun mirrors serve the same coordinates and are
    // tried first; the upstream repositories below remain the fallback.
    maven(url = "https://maven.aliyun.com/repository/public")
    maven(url = "https://maven.aliyun.com/repository/google")
    google()
    mavenCentral()
    gradlePluginPortal()
    maven(url = "https://jitpack.io")
    // The AAR `flutter build aar` writes; see docs/bbox-flutter.md.
    // Also hosts the io.flutter engine artifacts (flutter_embedding_*, *_debug/profile/release)
    // copied from the Gradle cache so resolution works offline.
    maven { url = uri(rootProject.file("flutter/build/host/outputs/repo")) }
    // Fallback for the Flutter engine artifacts if the local repo is missing any.
    maven { url = uri("https://storage.flutter-io.cn/download.flutter.io") }
    maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
}