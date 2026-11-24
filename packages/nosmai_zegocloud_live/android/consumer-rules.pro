# ZEGO Express: JNI and reflection (ZEGO's documented rule).
-keep class **.zego.** { *; }
-dontwarn **.zego.**
-dontwarn com.hihonor.**
# Nosmai calls back from native code.
-keep class com.nosmai.** { *; }
-dontwarn com.nosmai.**
-keepclasseswithmembernames class * { native <methods>; }
