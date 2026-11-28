# Preserve line numbers without leaking build-machine source file paths into DEX
-renamesourcefileattribute SourceFile
-keepattributes SourceFile,LineNumberTable

-keep class com.gosu.cloudtune.media.PlaybackService { public <init>(); }
-dontwarn com.google.zxing.**
