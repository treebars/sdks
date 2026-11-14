allprojects {
    repositories {
        /*
         * The Android Treebars SDK built from this repository, when tool/link-local-android-sdk.sh has
         * put it there; the script says why it is not a composite build. Only com.treebars is read
         * from it, and without it the published SDK of the same version is used.
         */
        val localSdk = rootProject.file("../build/local-android-sdk")
        if (localSdk.isDirectory) {
            exclusiveContent {
                forRepository { maven { url = localSdk.toURI() } }
                filter { includeGroup("com.treebars") }
            }
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
