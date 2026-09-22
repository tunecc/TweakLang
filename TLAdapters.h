//
//  TLAdapters.h
//  TweakLang
//
//  内置「硬编码双语」适配器注册表。
//
//  有些偏好 bundle 不提供任何 .lproj，也从不调用 NSBundle / CFBundle 的本地化
//  接口，而是在代码里用系统首选语言在中/英两套硬编码文案之间二选一。例如
//  Hello 键盘侠（cn.zqbb.hello.keyboard.ai）的 HelloKbAIPrefs.bundle：
//
//      BOOL isChinese = [[[NSLocale preferredLanguages] firstObject] hasPrefix:@"zh"];
//
//  （IDA 位置 HelloKbAIPrefs: 0x46274 / 0x436D8 / 0x17874；
//   -[HelloKbAIQuickStartManager localizedTextZh:en:] @ 0xDAFB8 即
//   return self.isChinese ? zh : en。）
//
//  这类 bundle 只能靠运行时改写 +[NSLocale preferredLanguages] 的返回值来切换语言，
//  因此必须在这里登记它实际支持的语言集合。Tweak.x 与 tweaklangprefs 共用本文件，
//  新增适配器只加一条表项，两侧逻辑都不用改。
//

#ifndef TL_ADAPTERS_H
#define TL_ADAPTERS_H

#import <Foundation/Foundation.h>

typedef struct {
    const char *bundleName;    // bundle 目录名（不含 .bundle）。必须等于真实目录名，同时是偏好键 bundleKey
    const char *const *languages;
    NSUInteger languageCount;
} TLAdapterEntry;

/// 返回适配器注册表；outCount 可为 NULL。
static inline const TLAdapterEntry *TLAdapterTable(NSUInteger *outCount) {
    static const char *const kHelloKbAILanguages[] = { "zh-Hans", "en" };

    static const TLAdapterEntry kTable[] = {
        // Hello 键盘侠：设置页无 .lproj，中英文案硬编码，按首选语言 hasPrefix:@"zh" 二选一。
        { "HelloKbAIPrefs", kHelloKbAILanguages, 2 },
    };

    if (outCount) {
        *outCount = sizeof(kTable) / sizeof(kTable[0]);
    }
    return kTable;
}

/// 按 bundle 路径找适配器；未命中返回 NULL。用于列表扫描。
///
/// 只按**目录名**精确匹配。这是有意的约束，不是遗漏：
///
///   - 列表侧用这个目录名当 bundleKey 写 `lang_<bundleKey>`；
///   - 运行时侧用它拼镜像标记 `/<bundleName>.bundle/` 来限定 hook 的作用域。
///
/// 两边必须是同一个名字，否则会出现「列表里能选、实际不生效」的条目。早期版本还允许按
/// CFBundleIdentifier 尾段兜底命中，但那恰恰会放过目录名不一致的 bundle——所以已移除。
/// 若未来某个适配器的目录名与想要的键不同，正确做法是让 bundleName 就等于目录名。
static inline const TLAdapterEntry *TLAdapterForBundle(NSString *bundlePath) {
    if (bundlePath.length == 0) return NULL;

    NSString *directoryName = [bundlePath lastPathComponent];
    NSString *bundleKey = [directoryName stringByDeletingPathExtension];
    if (bundleKey.length == 0) return NULL;

    NSUInteger count = 0;
    const TLAdapterEntry *table = TLAdapterTable(&count);
    for (NSUInteger index = 0; index < count; index++) {
        const TLAdapterEntry *entry = &table[index];
        if (entry->bundleName == NULL) continue;

        NSString *name = [NSString stringWithUTF8String:entry->bundleName];
        if ([name isEqualToString:bundleKey]) {
            return entry;
        }
    }

    return NULL;
}

/// 适配器 bundle 在已加载镜像路径中的标记，形如 "/HelloKbAIPrefs.bundle/"。
/// 运行时 hook 用它判断调用方是否来自某个适配器 bundle；Tweak.x 预置查找表时也用同一个函数，
/// 保证标记格式只有一处定义。尾部的斜杠不能省，否则 "X.bundleY/" 也会被误判。
static inline NSString *TLAdapterImageMarker(const TLAdapterEntry *entry) {
    if (!entry || entry->bundleName == NULL) return nil;
    NSString *name = [NSString stringWithUTF8String:entry->bundleName];
    return [NSString stringWithFormat:@"/%@.bundle/", name];
}

#endif /* TL_ADAPTERS_H */
