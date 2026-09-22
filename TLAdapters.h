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
//   return self.isChinese ? zh : en）。
//
//  STTool（cn.llld.snapshottool，SnapshotToolprefs.bundle）是同一回事，但查的是
//  另一个接口：
//
//      BOOL isChinese = [[[NSBundle mainBundle] preferredLocalizations] firstObject] hasPrefix:@"zh"];
//
//  （IDA 位置 SnapshotToolprefs: -[SnapshotToolllldRootListController isChinese] @ 0x17108、
//   -[additionalSTController isChinese] @ 0x19938、-[GPT_STController isChinese] @ 0x88D8；
//   主页与附加页在 viewDidLoad @ 0x14428 / 0x18FC8 把结果写进全局 _isChinese @ 0x371F8 后全页复用。）
//
//  Hello 120Hz（cn.zqbb.fix120hz，hello120hz.bundle）与 Hello CPU（cn.zqbb.holdcpu，
//  holdcpu.bundle）是第三类：判定接口与 STTool 相同，但它们既写硬编码双语分支，
//  又真的提供 .lproj 资源：
//
//      BOOL isChinese = [[[NSBundle mainBundle] preferredLocalizations] firstObject] hasPrefix:@"zh"];
//
//  （IDA 位置 hello120hz: -[Mode3Controller isChinese] @ 0x4CE54，以及
//   hello120hzPreRootListController 区域的内联判定 @ 0x26518 / 0x26630；
//   holdcpu: -[holdcpuPreRootListController isChinese] @ 0x81D7C / @ 0x829A4。
//   两个二进制都有控制流平坦化，"zh" 是由加密字节运行时还原出来的，strings 里搜不到。）
//
//  它们的资源布局相同：Base.lproj 是英文、zh_CN.lproj 是中文、CFBundleDevelopmentRegion
//  为 English、没有 en.lproj。所以除了接管硬编码分支（intercept），还要告诉两侧
//  "Base.lproj 就是英文"——这就是 baseLanguage 字段：列表侧用它把 English 加进语言集合，
//  运行时侧用它把 English 解析到 Base.lproj。
//
//  这类 bundle 只能靠运行时改写它实际查询的那个本地化接口的返回值来切换语言，
//  因此必须在这里登记两件事：它实际支持的语言集合，以及它实际查询哪个接口。
//  Tweak.x 与 tweaklangprefs 共用本文件，新增适配器只加一条表项，两侧逻辑都不用改。
//
//

#ifndef TL_ADAPTERS_H
#define TL_ADAPTERS_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, TLAdapterIntercept) {
    /// 目标插件用 +[NSLocale preferredLanguages] 判定语言。
    TLAdapterInterceptLocalePreferredLanguages,
    /// 目标插件用 -[NSBundle preferredLocalizations] 判定语言。
    TLAdapterInterceptBundlePreferredLocalizations,
};

typedef struct {
    const char *bundleName;    // bundle 目录名（不含 .bundle）。必须等于真实目录名，同时是偏好键 bundleKey
    const char *const *languages;
    NSUInteger languageCount;
    TLAdapterIntercept intercept;   // 目标插件实际查询的本地化接口；写错等于「列表里能选、实际不生效」
    // 该 bundle 的 Base.lproj 用的是什么语言（Info.plist 的 CFBundleDevelopmentRegion）。
    // NULL 表示不适用。填了之后：列表侧把该代码并进语言集合，运行时侧把该代码解析到
    // Base.lproj——没有这一行，英文文案虽然躺在 Base.lproj 里也永远送不到用户面前。
    // 只对命中注册表的 bundle 生效，未登记的 bundle 行为一行不变。
    const char *baseLanguage;
} TLAdapterEntry;

/// 返回适配器注册表；outCount 可为 NULL。
static inline const TLAdapterEntry *TLAdapterTable(NSUInteger *outCount) {
    static const char *const kHelloKbAILanguages[] = { "zh-Hans", "en" };
    static const char *const kSnapshotToolLanguages[] = { "zh-Hans", "en" };
    // Hello 120Hz 与 Hello CPU 都用 zh_CN.lproj（不是 en.lproj），所以中文代码必须写成
    // 磁盘上的真实目录名 zh_CN；写成 zh-Hans 会在资源解析时匹配不到 zh_CN.lproj。
    static const char *const kHello120HzLanguages[] = { "zh_CN", "en" };
    static const char *const kHoldCpuLanguages[] = { "zh_CN", "en" };

    static const TLAdapterEntry kTable[] = {
        // Hello 键盘侠：设置页无 .lproj，中英文案硬编码，按首选语言 hasPrefix:@"zh" 二选一。
        // 判定取自 +[NSLocale preferredLanguages]。
        { "HelloKbAIPrefs", kHelloKbAILanguages, 2, TLAdapterInterceptLocalePreferredLanguages, NULL },
        // STTool：设置页无 .lproj，主页面与附加页有大量中英文案硬编码分支，但判定取自
        // -[NSBundle preferredLocalizations]（对 mainBundle 取 firstObject 后 hasPrefix:@"zh"）。
        // GPT 页与中文 plist 段没有英文分支，本条目只让插件自己的英文分支显形，不替它造文案。
        { "SnapshotToolprefs", kSnapshotToolLanguages, 2, TLAdapterInterceptBundlePreferredLocalizations, NULL },
        // Hello 120Hz：Base.lproj 是英文、zh_CN.lproj 是中文（CFBundleDevelopmentRegion=English，
        // 没有 en.lproj）。主页 specifier 全由代码用硬编码文案构造，子页 Mode3 的文案走
        // Mode3.strings（Base 与 zh_CN 两组 key 完全一致）。判定取自
        // -[NSBundle preferredLocalizations]（对 mainBundle）。
        { "hello120hz", kHello120HzLanguages, 2, TLAdapterInterceptBundlePreferredLocalizations, "en" },
        // Hello CPU：同上，但主页走 Root.plist + Root.strings，且 Enable / Thermal Control /
        // Don't Fix Battery Health 只在 zh_CN.lproj 有译文，英文依赖 Base 回落下的缺失 key 规则。
        { "holdcpu", kHoldCpuLanguages, 2, TLAdapterInterceptBundlePreferredLocalizations, "en" },
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

/// 条目声明的 Base.lproj 语言；未声明返回 nil。
/// 列表侧把它并进语言集合，运行时侧把它解析到 Base.lproj。两侧比较前都应先各自归一化
/// （只留小写字母数字），避免写 "en" 而用户代码是 "en_US" 时漏判。
static inline NSString *TLAdapterBaseLanguage(const TLAdapterEntry *entry) {
    if (!entry || entry->baseLanguage == NULL) return nil;
    NSString *language = [NSString stringWithUTF8String:entry->baseLanguage];
    return language.length > 0 ? language : nil;
}

#endif /* TL_ADAPTERS_H */
