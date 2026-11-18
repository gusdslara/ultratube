# Ultratube release shrinking rules.
# NewPipeExtractor resolves extractors reflectively and runs YouTube's player
# JavaScript through Mozilla Rhino; both break if R8 renames or strips them.
-keep class org.schabi.newpipe.extractor.** { *; }
-keep class org.mozilla.javascript.** { *; }
-keep class org.mozilla.classfile.ClassFileWriter
-keep class app.ultratube.media.** { *; }
-keep class com.ppplayer.app.** { *; }
-dontwarn org.mozilla.javascript.**
-dontwarn org.mozilla.classfile.**
-dontwarn java.beans.**
-dontwarn javax.script.**
-dontwarn javax.lang.model.**
-dontwarn jdk.dynalink.**
-dontwarn com.google.re2j.**
-dontwarn org.jsoup.**
-dontwarn org.slf4j.**
-dontwarn javax.annotation.**
