plugins {
    application
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(25))
        vendor.set(JvmVendorSpec.AZUL)
    }
}

application {
    mainClass.set("bench.App")
    applicationDefaultJvmArgs = listOf("--enable-native-access=ALL-UNNAMED")
}

dependencies {
    implementation("info.picocli:picocli:4.7.7")
    implementation("org.xerial:sqlite-jdbc:3.53.1.0")
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
    jvmArgs("--enable-native-access=ALL-UNNAMED")
}
