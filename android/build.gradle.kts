allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// tobias 5.3.4 exports -dontshrink/-dontoptimize as consumer rules. On
// AGP 8 these disable R8 for the whole application. Replace only that
// library's rules, keeping its SDK entry points and the shared Pub cache intact.
subprojects {
    if (name == "tobias") {
        plugins.withId("com.android.library") {
            extensions.configure<com.android.build.api.variant.LibraryAndroidComponentsExtension> {
                finalizeDsl { library ->
                    library.defaultConfig.consumerProguardFiles.clear()
                    library.defaultConfig.consumerProguardFiles(
                        rootProject.file("tobias-consumer-rules.pro")
                    )
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
