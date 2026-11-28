plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.flrone.core"
    compileSdk = 35

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("proguard-rules.pro")
    }

    buildTypes {
        release {
            isJniDebuggable = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    externalNativeBuild {
        cmake {
            path("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("androidx.annotation:annotation-jvm:1.9.1")
}

// The Go kernel is a plain c-shared library (buildScript/build-cshared.sh);
// CI writes one libthrone.so per ABI here and CMake links it.
val copyNativeLibs by tasks.register<Copy>("copyNativeLibs") {
    from(rootProject.file("deployment/android-cshared")) {
        include("*/libthrone.so")
    }
    into("src/main/jniLibs")
}

afterEvaluate {
    tasks.named("preBuild") {
        dependsOn(copyNativeLibs)
    }
}
