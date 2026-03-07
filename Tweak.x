#import <Foundation/Foundation.h>

#ifdef __has_include
  #if __has_include(<roothide.h>)
    #include <roothide.h>
  #endif
#endif
#ifndef jbroot
  #define jbroot(path) path
#endif

#define PREF_DOMAIN        CFSTR("com.tune.tweaklang")
#define PREF_NOTIFICATION  CFSTR("com.tune.tweaklang/prefschanged")
#define LANG_KEY_PREFIX    @"lang_"

static NSDictionary *bundleLanguageMap = nil;
static NSDictionary *bundleLanguageAliasMap = nil;
static NSCache *stringsCache = nil;

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
            NSString *lang = prefs[key];
            if (lang && ![lang isEqualToString:@"system"]) {
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

    for (NSString *candidate in bundleCandidates(bundle)) {
        NSString *language = bundleLanguageMap[candidate];
        if (language.length > 0) {
            return language;
        }
    }

    for (NSString *candidate in bundleCandidates(bundle)) {
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
