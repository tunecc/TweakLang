#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <string.h>

#import "TLAdapters.h"

#define PREF_DOMAIN        CFSTR("com.tune.tweaklang")
#define PREF_NOTIFICATION  CFSTR("com.tune.tweaklang/prefschanged")
#define LANG_KEY_PREFIX    @"lang_"

static NSDictionary *bundleLanguageMap = nil;
static NSDictionary *bundleLanguageAliasMap = nil;
static NSCache *stringsCache = nil;

// 适配器型覆盖的查找表：镜像路径中的 "<bundle>.bundle/" 标记 -> @[拦截点, 已过滤的语言]。
// 语言必须在这里就按 adapterSupportsLanguage 过滤完再存进去，不能等 hook 里再读一次
// bundleLanguageMap：loadPreferences() 先替换偏好映射、最后才替换本表，两次替换都跑在
// Darwin 通知线程上；hook 若现场读映射，就可能在这个窗口内拿到适配器未声明的语言
// （手改 plist 写入 fr / zh-Hant 即可造出），而那按规格应当 %orig。
// 数组整体被字典 retain，语言串的生命周期由它兜住，不必依赖外层映射。
// 只有在用户真的为某个适配器 bundle 选了非 system 语言时才有条目，为空时 hook 直接 %orig。
static NSDictionary *adapterImageLanguageMap = nil;

static void rebuildAdapterImageLanguageMap(void);

#pragma mark - Preference Loading

static NSString *normalizedBundleKey(NSString *value) {
    if (value.length == 0) return nil;

    NSString *baseName = [[value lastPathComponent] stringByDeletingPathExtension];
    NSString *lowercase = [baseName lowercaseString];
    NSMutableString *normalized = [NSMutableString stringWithCapacity:lowercase.length];
    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];

    for (NSUInteger i = 0; i < lowercase.length; i++) {
        unichar c = [lowercase characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [normalized appendFormat:@"%C", c];
        }
    }

    if (normalized.length == 0) return nil;

    NSArray *suffixes = @[
        @"preferences",
        @"preference",
        @"settings",
        @"setting",
        @"localizations",
        @"localization",
        @"resources",
        @"resource",
        @"prefs",
        @"pref",
        @"bundle",
    ];

    BOOL changed = YES;
    while (changed && normalized.length > 0) {
        changed = NO;
        for (NSString *suffix in suffixes) {
            if ([normalized hasSuffix:suffix] && normalized.length > suffix.length) {
                [normalized deleteCharactersInRange:
                    NSMakeRange(normalized.length - suffix.length, suffix.length)];
                changed = YES;
                break;
            }
        }
    }

    return normalized.length > 0 ? normalized : nil;
}

static NSString *normalizedLocalizationCode(NSString *value) {
    if (value.length == 0) return nil;

    NSString *lowercase = [value lowercaseString];
    NSMutableString *normalized = [NSMutableString stringWithCapacity:lowercase.length];
    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];

    for (NSUInteger i = 0; i < lowercase.length; i++) {
        unichar c = [lowercase characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [normalized appendFormat:@"%C", c];
        }
    }

    return normalized.length > 0 ? normalized : nil;
}

static NSString *applicationSupportContainerName(NSString *path) {
    if (path.length == 0) return nil;

    NSRange range = [path rangeOfString:@"/Library/Application Support/"];
    if (range.location == NSNotFound) {
        return nil;
    }

    NSString *relativePath = [path substringFromIndex:NSMaxRange(range)];
    NSArray *components = [relativePath pathComponents];
    if (components.count < 2) {
        return nil;
    }

    NSString *containerName = components.firstObject;
    if (containerName.length == 0 || [containerName pathExtension].length > 0) {
        return nil;
    }

    return containerName;
}

static NSString *bundlePathForCFBundle(CFBundleRef bundle) {
    if (!bundle) return nil;

    CFURLRef bundleURL = CFBundleCopyBundleURL(bundle);
    if (!bundleURL) return nil;

    NSString *bundlePath = CFBridgingRelease(CFURLCopyFileSystemPath(bundleURL, kCFURLPOSIXPathStyle));
    CFRelease(bundleURL);
    return [bundlePath isKindOfClass:[NSString class]] ? bundlePath : nil;
}

static void addBundleCandidate(NSMutableOrderedSet *candidates, NSString *value) {
    if (value.length == 0) return;

    NSString *baseName = [[value lastPathComponent] stringByDeletingPathExtension];
    if (baseName.length > 0) {
        [candidates addObject:baseName];
    }

    NSString *normalized = normalizedBundleKey(value);
    if (normalized.length > 0) {
        [candidates addObject:normalized];
    }
}

static NSArray *bundleCandidates(NSBundle *bundle) {
    NSMutableOrderedSet *candidates = [NSMutableOrderedSet orderedSet];
    NSString *bundlePath = [bundle bundlePath];

    addBundleCandidate(candidates, [bundlePath lastPathComponent]);
    addBundleCandidate(candidates, applicationSupportContainerName(bundlePath));

    NSString *bundleIdentifier = [bundle bundleIdentifier];
    if (bundleIdentifier.length > 0) {
        addBundleCandidate(candidates, bundleIdentifier);
        addBundleCandidate(candidates, [[bundleIdentifier componentsSeparatedByString:@"."] lastObject]);
    }

    NSString *scanPath = [bundlePath stringByDeletingLastPathComponent];
    while (scanPath.length > 1 && ![scanPath isEqualToString:@"/"]) {
        NSString *component = [scanPath lastPathComponent];
        if ([component hasSuffix:@".bundle"] ||
            [component hasSuffix:@".framework"] ||
            [component hasSuffix:@".app"]) {
            addBundleCandidate(candidates, component);
        }
        NSString *nextPath = [scanPath stringByDeletingLastPathComponent];
        if ([nextPath isEqualToString:scanPath]) break;
        scanPath = nextPath;
    }

    return [candidates array];
}

static NSString *preferredLocalizationDirectory(NSString *bundlePath, NSString *language) {
    if (bundlePath.length == 0 || language.length == 0) return nil;

    NSString *exactDirectory = [NSString stringWithFormat:@"%@.lproj", language];
    NSString *exactPath = [bundlePath stringByAppendingPathComponent:exactDirectory];
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:exactPath isDirectory:&isDir] && isDir) {
        return exactDirectory;
    }

    NSString *targetCode = normalizedLocalizationCode(language);
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath error:nil];
    for (NSString *item in contents) {
        if (![item hasSuffix:@".lproj"]) continue;
        NSString *candidateCode = normalizedLocalizationCode([item stringByDeletingPathExtension]);
        if (candidateCode.length > 0 && [candidateCode isEqualToString:targetCode]) {
            return item;
        }
    }

    return nil;
}

static NSString *localizedResourcePath(NSBundle *bundle,
                                       NSString *name,
                                       NSString *ext,
                                       NSString *subpath,
                                       NSString *language) {
    if (language.length == 0) return nil;

    NSString *bundlePath = [bundle bundlePath];
    NSString *lprojDirectory = preferredLocalizationDirectory(bundlePath, language);
    if (lprojDirectory.length == 0) return nil;

    NSString *filename = name;
    if (filename.length == 0) {
        return nil;
    }

    if (ext.length > 0) {
        filename = [filename stringByAppendingPathExtension:ext];
    }

    NSMutableArray *candidatePaths = [NSMutableArray array];
    if (subpath.length > 0) {
        [candidatePaths addObject:[[[bundlePath stringByAppendingPathComponent:subpath]
            stringByAppendingPathComponent:lprojDirectory]
            stringByAppendingPathComponent:filename]];
        [candidatePaths addObject:[[[bundlePath stringByAppendingPathComponent:lprojDirectory]
            stringByAppendingPathComponent:subpath]
            stringByAppendingPathComponent:filename]];
    } else {
        [candidatePaths addObject:[[bundlePath stringByAppendingPathComponent:lprojDirectory]
            stringByAppendingPathComponent:filename]];
    }

    for (NSString *path in candidatePaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return path;
        }
    }

    return nil;
}

static NSDictionary *localizedStrings(NSBundle *bundle, NSString *language, NSString *tableName) {
    NSString *table = tableName.length > 0 ? tableName : @"Localizable";
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@|%@",
                          [bundle bundlePath], language, table];

    NSDictionary *strings = [stringsCache objectForKey:cacheKey];
    if (strings) {
        return strings;
    }

    NSString *stringsPath = localizedResourcePath(bundle, table, @"strings", nil, language);
    if (stringsPath.length > 0) {
        strings = [NSDictionary dictionaryWithContentsOfFile:stringsPath];
    }

    NSDictionary *cachedValue = strings ?: @{};
    [stringsCache setObject:cachedValue forKey:cacheKey];
    return cachedValue;
}

static void loadPreferences() {
    NSDictionary *prefs = (__bridge_transfer NSDictionary *)CFPreferencesCopyMultiple(
        NULL, PREF_DOMAIN,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSMutableDictionary *aliasMap = [NSMutableDictionary dictionary];
    for (NSString *key in prefs) {
        if ([key hasPrefix:LANG_KEY_PREFIX]) {
            NSString *bundleName = [key substringFromIndex:LANG_KEY_PREFIX.length];

            // 偏好文件可能被手改成非字符串值；类型不符时跳过，否则后面的
            // isEqualToString: 会在 %ctor 里直接把 Settings 带崩。
            id rawValue = prefs[key];
            if (![rawValue isKindOfClass:[NSString class]]) continue;
            NSString *lang = (NSString *)rawValue;

            if (lang.length > 0 && ![lang isEqualToString:@"system"]) {
                map[bundleName] = lang;

                NSString *alias = normalizedBundleKey(bundleName);
                if (alias.length > 0) {
                    NSString *existing = aliasMap[alias];
                    if (!existing) {
                        aliasMap[alias] = lang;
                    } else if (![existing isEqualToString:lang]) {
                        [aliasMap removeObjectForKey:alias];
                    }
                }
            }
        }
    }
    bundleLanguageMap = [map copy];
    bundleLanguageAliasMap = [aliasMap copy];
    [stringsCache removeAllObjects];

    rebuildAdapterImageLanguageMap();
}

#pragma mark - Hardcoded Bilingual Adapters

static BOOL adapterSupportsLanguage(const TLAdapterEntry *entry, NSString *language) {
    if (!entry || language.length == 0) return NO;

    for (NSUInteger index = 0; index < entry->languageCount; index++) {
        NSString *supported = [NSString stringWithUTF8String:entry->languages[index]];
        if ([supported isEqualToString:language]) {
            return YES;
        }
    }

    return NO;
}

static NSString *configuredLanguageForAdapter(const TLAdapterEntry *entry) {
    if (!entry || entry->bundleName == NULL) return nil;

    // 只用 bundleName 及其 normalized 形式当候选键。bundleName 就是列表侧写的
    // bundleKey，所以这里取到的就是 UI 写下去的那个值；不再用 CFBundleIdentifier
    // 尾段当候选，否则另一个恰好叫同名的 bundle 的偏好会被这个适配器捡走。
    NSMutableArray *candidates = [NSMutableArray array];
    NSString *bundleName = [NSString stringWithUTF8String:entry->bundleName];
    [candidates addObject:bundleName];

    NSString *normalized = normalizedBundleKey(bundleName);
    if (normalized.length > 0) {
        [candidates addObject:normalized];
    }

    for (NSString *candidate in candidates) {
        NSString *language = bundleLanguageMap[candidate];
        if (language.length > 0) {
            return language;
        }
    }

    NSString *alias = normalizedBundleKey(bundleName);
    if (alias.length > 0) {
        NSString *language = bundleLanguageAliasMap[alias];
        if (language.length > 0) {
            return language;
        }
    }

    return nil;
}

static void rebuildAdapterImageLanguageMap() {
    NSMutableDictionary *imageMap = [NSMutableDictionary dictionary];
    NSUInteger count = 0;
    const TLAdapterEntry *table = TLAdapterTable(&count);

    for (NSUInteger index = 0; index < count; index++) {
        const TLAdapterEntry *entry = &table[index];

        NSString *language = configuredLanguageForAdapter(entry);
        if (language.length == 0 || [language isEqualToString:@"system"]) continue;
        if (!adapterSupportsLanguage(entry, language)) continue;

        NSString *marker = TLAdapterImageMarker(entry);
        if (marker.length == 0) continue;
        imageMap[marker] = @[ @(entry->intercept), language ];
    }

    adapterImageLanguageMap = [imageMap copy];
}

// address 必须是 hook 方法体里直接取得的 __builtin_return_address(0)，
// 也就是调用目标本地化接口的那条指令的返回地址。
// intercept 是当前这个 hook 对应的拦截点；条目声明了别的拦截点就一律 %orig，
// 否则 Hello 键盘侠 的 NSLocale 判定会被 STTool 镜像反过来改写，反之亦然。
// 语言在 rebuildAdapterImageLanguageMap() 里就已按 adapterSupportsLanguage 过滤，
// 这里只做镜像与拦截点匹配，不再读偏好映射。
static NSString *adapterLanguageForCallerAddress(void *address, TLAdapterIntercept intercept) {
    if (adapterImageLanguageMap.count == 0) return nil;
    if (address == NULL) return nil;

    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr(address, &info) == 0 || info.dli_fname == NULL) return nil;

    NSString *imagePath = [NSString stringWithUTF8String:info.dli_fname];
    if (imagePath.length == 0) return nil;

    for (NSString *marker in adapterImageLanguageMap) {
        if (![imagePath containsString:marker]) continue;

        NSArray *cached = adapterImageLanguageMap[marker];
        if (![cached isKindOfClass:[NSArray class]] || cached.count != 2) continue;
        // 拦截点不匹配：跳过这个标记继续看下一个，而不是直接放弃，避免同一条镜像路径上出现
        // 两个标记时误判成「无命中」。
        if ([cached[0] unsignedIntegerValue] != (NSUInteger)intercept) continue;

        NSString *language = cached[1];
        return [language isKindOfClass:[NSString class]] ? language : nil;
    }

    return nil;
}

#pragma mark - Bundle Matching

static BOOL isTargetBundle(NSString *bundlePath) {
    if (!bundlePath) return NO;
    if ([bundlePath containsString:@"/System/"]) return NO;
    return [bundlePath containsString:@"PreferenceBundles"] ||
           [bundlePath containsString:@"Application Support"] ||
           [bundlePath containsString:@"MobileSubstrate"] ||
           [bundlePath containsString:@".jbroot"] ||
           [bundlePath containsString:@"/var/jb/"];
}

static NSString *targetLanguageForBundle(NSBundle *bundle) {
    if (!bundleLanguageMap.count) return nil;
    NSString *bundlePath = [bundle bundlePath];
    if (!isTargetBundle(bundlePath)) return nil;

    NSArray *candidates = bundleCandidates(bundle);
    for (NSString *candidate in candidates) {
        NSString *language = bundleLanguageMap[candidate];
        if (language.length > 0) {
            return language;
        }
    }

    for (NSString *candidate in candidates) {
        NSString *normalized = normalizedBundleKey(candidate);
        NSString *language = bundleLanguageAliasMap[normalized];
        if (language.length > 0) {
            return language;
        }
    }

    return nil;
}

static NSArray *tableCandidates(NSBundle *bundle, NSString *tableName) {
    NSMutableOrderedSet *tables = [NSMutableOrderedSet orderedSet];

    if (tableName.length > 0) {
        [tables addObject:tableName];
    } else {
        [tables addObject:@"Root"];
        [tables addObject:@"Localizable"];
        [tables addObject:@"Settings"];
        NSString *bundleName = [[[bundle bundlePath] lastPathComponent] stringByDeletingPathExtension];
        if (bundleName.length > 0) {
            [tables addObject:bundleName];
        }
    }

    return [tables array];
}

static void preferencesChanged(CFNotificationCenterRef center,
                               void *observer,
                               CFStringRef name,
                               const void *object,
                               CFDictionaryRef userInfo) {
    loadPreferences();
}

#pragma mark - NSBundle Hooks

%hook NSBundle

- (NSArray *)preferredLocalizations {
    NSString *lang = targetLanguageForBundle(self);
    if (lang) return @[lang];

    // 资源型覆盖判的是 self 是不是目标 bundle；适配器分支判的是调用方镜像。
    // 只有 self 不是已配置语言的目标 bundle 时才轮到适配器，两条路径互不影响。
    NSString *adapterLang = adapterLanguageForCallerAddress(
        __builtin_return_address(0), TLAdapterInterceptBundlePreferredLocalizations);
    if (adapterLang.length > 0) return @[adapterLang];

    return %orig;
}

- (NSString *)localizedStringForKey:(NSString *)key value:(NSString *)value table:(NSString *)tableName {
    NSString *lang = targetLanguageForBundle(self);
    if (lang) {
        for (NSString *table in tableCandidates(self, tableName)) {
            NSDictionary *strings = localizedStrings(self, lang, table);
            NSString *result = strings[key];
            if (result.length > 0) {
                return result;
            }
        }
    }
    return %orig;
}

- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)ext {
    NSString *lang = targetLanguageForBundle(self);
    if (lang) {
        NSString *result = localizedResourcePath(self, name, ext, nil, lang);
        if (result.length > 0) {
            return result;
        }
    }
    return %orig;
}

- (NSString *)pathForResource:(NSString *)name
                       ofType:(NSString *)ext
                  inDirectory:(NSString *)subpath {
    NSString *lang = targetLanguageForBundle(self);
    if (lang) {
        NSString *result = localizedResourcePath(self, name, ext, subpath, lang);
        if (result.length > 0) {
            return result;
        }
    }
    return %orig;
}

- (NSString *)pathForResource:(NSString *)name
                       ofType:(NSString *)ext
                  inDirectory:(NSString *)subpath
              forLocalization:(NSString *)localizationName {
    NSString *lang = targetLanguageForBundle(self);
    if (lang) {
        NSString *result = localizedResourcePath(self, name, ext, subpath, lang);
        if (result.length > 0) {
            return result;
        }
    }
    return %orig;
}

%end

#pragma mark - Hardcoded Bilingual Adapters

// 只有按 .lproj 提供本地化的 bundle 才走上面的 NSBundle hook。Hello 键盘侠 这类
// 插件没有任何 .lproj，它自己用 [[[NSLocale preferredLanguages] firstObject]
// hasPrefix:@"zh"] 决定显示中文还是英文；STTool 则用
// [[[NSBundle mainBundle] preferredLocalizations] firstObject] hasPrefix:@"zh"]。
// 所以这里按调用方镜像改写它们各自查询的那个接口的返回值：
// 调用方来自已配置语言的适配器 bundle、且该条目声明的就是这个接口时才生效，
// Settings.app 自身和其它 PreferenceBundle 的调用一律 %orig。
%hook NSLocale

+ (NSArray<NSString *> *)preferredLanguages {
    NSString *language = adapterLanguageForCallerAddress(
        __builtin_return_address(0), TLAdapterInterceptLocalePreferredLanguages);
    if (language.length > 0) {
        return @[language];
    }
    return %orig;
}

%end

%hookf(CFStringRef, CFBundleCopyLocalizedString, CFBundleRef bundle, CFStringRef key, CFStringRef value, CFStringRef tableName) {
    if (!bundle || !key) {
        return %orig;
    }

    NSString *bundlePath = bundlePathForCFBundle(bundle);
    if (bundlePath.length == 0 || !isTargetBundle(bundlePath)) {
        return %orig;
    }

    NSBundle *nsBundle = [NSBundle bundleWithPath:bundlePath];
    if (!nsBundle) {
        return %orig;
    }

    NSString *language = targetLanguageForBundle(nsBundle);
    if (language.length == 0) {
        return %orig;
    }

    NSString *keyString = (__bridge NSString *)key;
    NSString *tableString = tableName ? (__bridge NSString *)tableName : nil;
    for (NSString *table in tableCandidates(nsBundle, tableString)) {
        NSDictionary *strings = localizedStrings(nsBundle, language, table);
        NSString *result = strings[keyString];
        if (result.length > 0) {
            return (CFStringRef)CFRetain((__bridge CFTypeRef)result);
        }
    }

    return %orig;
}

#pragma mark - Constructor

%ctor {
    stringsCache = [[NSCache alloc] init];
    stringsCache.countLimit = 256;

    loadPreferences();

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        preferencesChanged,
        PREF_NOTIFICATION, NULL,
        CFNotificationSuspensionBehaviorCoalesce);
}
