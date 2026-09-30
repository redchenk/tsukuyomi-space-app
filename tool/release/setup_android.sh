#!/usr/bin/env bash
set -euo pipefail
# User-level properties override the template's 8 GB heap. Leave capacity for
# Flutter's compiler, native C++ compilation, Kotlin and the hosted runner.
gradle_config_dir="${GRADLE_USER_HOME:-$HOME/.gradle}"
mkdir -p "$gradle_config_dir"
cat > "$gradle_config_dir/gradle.properties" <<'PROPERTIES'
org.gradle.jvmargs=-Xmx3G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=256m -XX:+HeapDumpOnOutOfMemoryError
org.gradle.workers.max=2
kotlin.daemon.jvmargs=-Xmx512m
PROPERTIES
