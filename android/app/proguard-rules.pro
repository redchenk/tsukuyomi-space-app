# QQ's bundled JAR uses reflection and does not ship consumer keep rules.
# Keep its SDK boundary while allowing the rest of the app to be optimized.
-keep class com.tencent.** { *; }

# These names are exported by the native Live2D library's JNI entry points.
-keepclasseswithmembernames,includedescriptorclasses class space.tsukuyomi.live2d.Live2DGpu {
    native <methods>;
}
