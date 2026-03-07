#import "TLRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>

#define PREF_DOMAIN       @"com.tune.tweaklang"
#define PREF_NOTIFICATION CFSTR("com.tune.tweaklang/prefschanged")
#define LANG_KEY_PREFIX   @"lang_"
#define UI_LANG_KEY       @"ui_language"

@interface TLLanguageListController : PSListController
@end

@interface TLLanguageValueCell : PSTableCell
@end

@interface TLRootListController () {
    NSArray *_cachedBundles;
}
@end

static NSBundle *TLPrefsBundle(void) {
    return [NSBundle bundleForClass:[TLRootListController class]];
}

static NSString *TLPrimaryBundleToken(NSString *value) {
    if (value.length == 0) return nil;

    NSString *token = [value lastPathComponent];
    NSString *extension = [[token pathExtension] lowercaseString];
    NSSet *knownExtensions = [NSSet setWithObjects:
        @"bundle", @"framework", @"app", @"plist", nil];
    if (extension.length > 0 && [knownExtensions containsObject:extension]) {
        token = [token stringByDeletingPathExtension];
    }

    return token.length > 0 ? token : nil;
}

static NSString *TLNormalizedBundleKey(NSString *value) {
    NSString *baseName = TLPrimaryBundleToken(value);
    if (baseName.length == 0) return nil;

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

static NSString *TLNormalizedLocalizationCode(NSString *value) {
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

static NSString *TLApplicationSupportContainerName(NSString *path) {
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

static void TLAddBundleLookupKeys(NSMutableOrderedSet *keys, NSString *value) {
    NSString *primaryToken = TLPrimaryBundleToken(value);
    if (primaryToken.length > 0) {
        [keys addObject:primaryToken];
    }

    NSString *normalized = TLNormalizedBundleKey(value);
    if (normalized.length > 0) {
        [keys addObject:normalized];
    }
}

static NSArray *TLLookupKeysForBundle(NSBundle *bundle, NSString *fallbackName) {
    NSMutableOrderedSet *keys = [NSMutableOrderedSet orderedSet];
    NSString *bundlePath = [bundle bundlePath];

    TLAddBundleLookupKeys(keys, fallbackName);
    TLAddBundleLookupKeys(keys, [bundlePath lastPathComponent]);
    TLAddBundleLookupKeys(keys, TLApplicationSupportContainerName(bundlePath));

    return [keys array];
}

static NSString *TLBundleInfoDisplayName(NSBundle *bundle, NSString *fallbackName) {
    NSString *displayName = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    if (displayName.length == 0) {
        displayName = [bundle objectForInfoDictionaryKey:@"CFBundleName"];
    }
    if (displayName.length == 0) {
        displayName = fallbackName;
    }
    return displayName;
}

static NSString *TLPreferenceKeyForName(NSString *name) {
    if (name.length == 0) return nil;
    return [LANG_KEY_PREFIX stringByAppendingString:name];
}

static NSString *TLReadStringPreference(NSString *key) {
    if (key.length == 0) return nil;

    CFPropertyListRef value = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key,
        (__bridge CFStringRef)PREF_DOMAIN);
    if (!value) {
        return nil;
    }

    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        CFRelease(value);
        return nil;
    }

    NSString *stringValue = CFBridgingRelease(value);
    return stringValue.length > 0 ? stringValue : nil;
}

static NSString *TLReadLanguageOverrideValue(NSString *bundleKey, NSString *legacyKey) {
    NSString *value = TLReadStringPreference(TLPreferenceKeyForName(bundleKey));
    if (value.length > 0) {
        return value;
    }

    if (legacyKey.length > 0 && ![legacyKey isEqualToString:bundleKey]) {
        value = TLReadStringPreference(TLPreferenceKeyForName(legacyKey));
        if (value.length > 0) {
            return value;
        }
    }

    return @"system";
}

static void TLWriteLanguageOverrideValue(NSString *value, NSString *bundleKey, NSString *legacyKey) {
    NSString *primaryKey = TLPreferenceKeyForName(bundleKey);
    NSString *legacyPreferenceKey = TLPreferenceKeyForName(legacyKey);
    BOOL resetToDefault = (value.length == 0 || [value isEqualToString:@"system"]);

    if (primaryKey.length > 0) {
        CFPreferencesSetAppValue(
            (__bridge CFStringRef)primaryKey,
            resetToDefault ? NULL : (__bridge CFStringRef)value,
            (__bridge CFStringRef)PREF_DOMAIN);
    }

    if (legacyPreferenceKey.length > 0 && ![legacyPreferenceKey isEqualToString:primaryKey]) {
        CFPreferencesSetAppValue(
            (__bridge CFStringRef)legacyPreferenceKey,
            NULL,
            (__bridge CFStringRef)PREF_DOMAIN);
    }

    CFPreferencesAppSynchronize((__bridge CFStringRef)PREF_DOMAIN);
}

static NSString *TLPreferredLocalizationDirectory(NSBundle *bundle, NSString *language) {
    if (language.length == 0) return nil;

    NSString *bundlePath = [bundle bundlePath];
    NSString *exactDirectory = [NSString stringWithFormat:@"%@.lproj", language];
    NSString *exactPath = [bundlePath stringByAppendingPathComponent:exactDirectory];
    BOOL isDir = NO;

    if ([[NSFileManager defaultManager] fileExistsAtPath:exactPath isDirectory:&isDir] && isDir) {
        return exactDirectory;
    }

    NSString *targetCode = TLNormalizedLocalizationCode(language);
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath error:nil];
    for (NSString *item in contents) {
        if (![item hasSuffix:@".lproj"]) continue;
        NSString *candidateCode = TLNormalizedLocalizationCode([item stringByDeletingPathExtension]);
        if (candidateCode.length > 0 && [candidateCode isEqualToString:targetCode]) {
            return item;
        }
    }

    return nil;
}

static NSDictionary *TLLocalizedTable(NSBundle *bundle, NSString *language, NSString *tableName) {
    NSString *directory = TLPreferredLocalizationDirectory(bundle, language);
    if (directory.length == 0) return nil;

    NSString *path = [[[bundle bundlePath] stringByAppendingPathComponent:directory]
        stringByAppendingPathComponent:[tableName stringByAppendingPathExtension:@"strings"]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return nil;
    }

    return [NSDictionary dictionaryWithContentsOfFile:path];
}

static NSString *TLInterfaceLanguagePreference(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)UI_LANG_KEY,
        (__bridge CFStringRef)PREF_DOMAIN);
    if (!value) return @"system";

    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        CFRelease(value);
        return @"system";
    }

    NSString *language = CFBridgingRelease(value);
    return language.length > 0 ? language : @"system";
}

static void TLSetInterfaceLanguagePreference(NSString *value) {
    if (value.length == 0 || [value isEqualToString:@"system"]) {
        CFPreferencesSetAppValue(
            (__bridge CFStringRef)UI_LANG_KEY,
            NULL,
            (__bridge CFStringRef)PREF_DOMAIN);
    } else {
        CFPreferencesSetAppValue(
            (__bridge CFStringRef)UI_LANG_KEY,
            (__bridge CFStringRef)value,
            (__bridge CFStringRef)PREF_DOMAIN);
    }

    CFPreferencesAppSynchronize((__bridge CFStringRef)PREF_DOMAIN);
}

static NSString *TLLocalizedString(NSString *key, NSString *fallback) {
    NSBundle *bundle = TLPrefsBundle();
    NSString *language = TLInterfaceLanguagePreference();

    if (language.length == 0 || [language isEqualToString:@"system"]) {
        NSString *result = [bundle localizedStringForKey:key value:nil table:@"Localizable"];
        if (result.length > 0 && ![result isEqualToString:key]) {
            return result;
        }
        return fallback;
    }

    NSDictionary *strings = TLLocalizedTable(bundle, language, @"Localizable");
    NSString *result = strings[key];
    if (result.length > 0) {
        return result;
    }

    return fallback;
}

static NSLocale *TLDisplayLocale(void) {
    NSString *language = TLInterfaceLanguagePreference();
    if (language.length == 0 || [language isEqualToString:@"system"]) {
        return [NSLocale currentLocale];
    }
    return [[NSLocale alloc] initWithLocaleIdentifier:language];
}

static NSString *TLDisplayTitleForLanguageValue(NSString *value, NSLocale *locale) {
    if (value.length == 0 || [value isEqualToString:@"system"]) {
        return TLLocalizedString(@"system_default", @"System Default");
    }

    NSString *normalized = [value stringByReplacingOccurrencesOfString:@"_"
                                                            withString:@"-"];
    NSString *name = [locale displayNameForKey:NSLocaleIdentifier value:normalized];
    if (name && ![name isEqualToString:value] && ![name isEqualToString:normalized]) {
        return [NSString stringWithFormat:@"%@ (%@)", name, value];
    }

    return value;
}

@implementation TLLanguageValueCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleValue1
                reuseIdentifier:reuseIdentifier
                      specifier:specifier];
    if (self) {
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        self.detailTextLabel.textAlignment = NSTextAlignmentRight;
        self.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        self.detailTextLabel.minimumScaleFactor = 0.8;
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];

    self.textLabel.text = specifier.name;

    NSString *value = [specifier performGetter];
    if (![value isKindOfClass:[NSString class]] || value.length == 0) {
        value = [specifier propertyForKey:@"default"] ?: @"system";
    }

    self.detailTextLabel.text = TLDisplayTitleForLanguageValue(value, TLDisplayLocale());
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
}

@end

@implementation TLRootListController

- (NSString *)title {
    return @"";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self updateLocalizedChrome];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self buildSpecifiers];
    }
    return _specifiers;
}

#pragma mark - Specifier Generation

- (NSMutableArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    NSArray *bundles = [self displayBundles];

    if (bundles.count == 0) {
        PSSpecifier *empty = [PSSpecifier groupSpecifierWithName:
            TLLocalizedString(@"empty.no_localizations",
                @"No tweaks with localization resources found.")];
        [specs addObject:empty];
        return specs;
    }

    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:
        TLLocalizedString(@"group.installed_tweaks", @"Installed Tweaks")];
    [group setProperty:[NSString stringWithFormat:
        TLLocalizedString(@"group.installed_tweaks.footer", @"%lu tweaks detected"),
        (unsigned long)bundles.count]
                forKey:@"footerText"];
    [specs addObject:group];

    for (NSDictionary *info in bundles) {
        NSString *name = info[@"name"];
        NSString *bundleKey = info[@"bundleKey"];
        NSString *legacyKey = info[@"legacyKey"];
        NSArray *languages = info[@"languages"];

        NSMutableArray *validValues = [NSMutableArray arrayWithObject:@"system"];
        NSMutableArray *validTitles = [NSMutableArray arrayWithObject:
            TLLocalizedString(@"system_default", @"System Default")];

        for (NSString *langCode in languages) {
            [validValues addObject:langCode];
            [validTitles addObject:[self displayNameForCode:langCode]];
        }

        PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name
            target:self
            set:@selector(setPreferenceValue:specifier:)
            get:@selector(readPreferenceValue:)
            detail:[TLLanguageListController class]
            cell:PSLinkListCell
            edit:Nil];

        [spec setProperty:PREF_DOMAIN forKey:@"defaults"];
        [spec setProperty:bundleKey forKey:@"bundleKey"];
        if (legacyKey.length > 0 && ![legacyKey isEqualToString:bundleKey]) {
            [spec setProperty:legacyKey forKey:@"legacyKey"];
        }
        [spec setProperty:info[@"path"] forKey:@"bundlePath"];
        [spec setProperty:TLPreferenceKeyForName(bundleKey)
                   forKey:@"key"];
        [spec setProperty:@"system" forKey:@"default"];
        [spec setProperty:validValues forKey:@"validValues"];
        [spec setProperty:validTitles forKey:@"validTitles"];
        [spec setProperty:validValues forKey:@"values"];
        [spec setProperty:validTitles forKey:@"titles"];
        [spec setProperty:validTitles forKey:@"shortTitles"];
        NSMutableDictionary *titleDictionary = [NSMutableDictionary dictionary];
        NSUInteger count = MIN(validValues.count, validTitles.count);
        for (NSUInteger index = 0; index < count; index++) {
            NSString *value = validValues[index];
            NSString *title = validTitles[index];
            if (value.length > 0 && title.length > 0) {
                titleDictionary[value] = title;
            }
        }
        [spec setProperty:titleDictionary forKey:@"titleDictionary"];
        [spec setProperty:titleDictionary forKey:@"shortTitleDictionary"];
        [spec setProperty:[TLLanguageValueCell class] forKey:PSCellClassKey];

        [specs addObject:spec];
    }

    return specs;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateLocalizedChrome];
    if (_cachedBundles) {
        _specifiers = nil;
        [self reloadSpecifiers];
    }
}

- (void)updateLocalizedChrome {
    self.title = @"";
    self.navigationItem.title = @"";
    UIBarButtonItem *languageButton = [[UIBarButtonItem alloc]
        initWithTitle:TLLocalizedString(@"ui.button", @"Lang")
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(showInterfaceLanguagePicker)];
    UIBarButtonItem *refreshButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(refreshBundleList)];
    self.navigationItem.rightBarButtonItems = @[languageButton, refreshButton];
}

- (void)showInterfaceLanguagePicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        TLLocalizedString(@"ui.picker.title", @"TweakLang Interface")
        message:TLLocalizedString(@"ui.picker.message",
            @"Choose the interface language for this settings page.")
        preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *options = @[
        @{ @"value": @"system", @"title": TLLocalizedString(@"ui.picker.system", @"System Default") },
        @{ @"value": @"en", @"title": TLLocalizedString(@"ui.picker.english", @"English") },
        @{ @"value": @"zh-Hans", @"title": TLLocalizedString(@"ui.picker.zh_hans", @"Simplified Chinese") },
    ];

    for (NSDictionary *option in options) {
        UIAlertAction *action = [UIAlertAction actionWithTitle:option[@"title"]
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *selectedAction) {
                [self setInterfaceLanguage:option[@"value"]];
            }];
        [alert addAction:action];
    }

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:
        TLLocalizedString(@"ui.picker.cancel", @"Cancel")
        style:UIAlertActionStyleCancel
        handler:nil];
    [alert addAction:cancel];

    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) {
        popover.barButtonItem = self.navigationItem.rightBarButtonItem;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)setInterfaceLanguage:(NSString *)value {
    TLSetInterfaceLanguagePreference(value);
    [self updateLocalizedChrome];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)refreshBundleList {
    _cachedBundles = nil;
    _specifiers = nil;
    [self reloadSpecifiers];
}

#pragma mark - Preference I/O

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *bundleKey = [specifier propertyForKey:@"bundleKey"];
    NSString *legacyKey = [specifier propertyForKey:@"legacyKey"];
    NSString *value = TLReadLanguageOverrideValue(bundleKey, legacyKey);
    return value.length > 0 ? value : ([specifier propertyForKey:@"default"] ?: @"system");
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *bundleKey = [specifier propertyForKey:@"bundleKey"];
    NSString *legacyKey = [specifier propertyForKey:@"legacyKey"];
    NSString *stringValue = [value isKindOfClass:[NSString class]] ? value : @"system";

    TLWriteLanguageOverrideValue(stringValue, bundleKey, legacyKey);
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        PREF_NOTIFICATION, NULL, NULL, YES);
}

#pragma mark - Bundle Scanning

- (NSString *)jailbreakRoot {
    NSString *bundlePath = [[NSBundle bundleForClass:[self class]] bundlePath];

    NSRange range = [bundlePath rangeOfString:@"/Library/PreferenceBundles/"];
    if (range.location != NSNotFound) {
        if (range.location == 0) return @"/";
        return [bundlePath substringToIndex:range.location];
    }

    if ([[NSFileManager defaultManager]
            fileExistsAtPath:@"/var/jb/Library/PreferenceBundles"]) {
        return @"/var/jb";
    }

    return @"/";
}

- (NSArray *)bundlePathsInDirectory:(NSString *)directoryPath recursive:(BOOL)recursive {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:directoryPath isDirectory:&isDir] || !isDir) {
        return @[];
    }

    NSMutableArray *bundlePaths = [NSMutableArray array];
    if (!recursive) {
        NSArray *items = [fm contentsOfDirectoryAtPath:directoryPath error:nil];
        for (NSString *item in items) {
            if (![item hasSuffix:@".bundle"]) continue;

            NSString *bundlePath = [directoryPath stringByAppendingPathComponent:item];
            BOOL itemIsDir = NO;
            if ([fm fileExistsAtPath:bundlePath isDirectory:&itemIsDir] && itemIsDir) {
                [bundlePaths addObject:bundlePath];
            }
        }
        return bundlePaths;
    }

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:directoryPath];
    for (NSString *relativePath in enumerator) {
        NSString *extension = [[relativePath pathExtension] lowercaseString];
        if ([extension isEqualToString:@"app"] || [extension isEqualToString:@"framework"]) {
            [enumerator skipDescendants];
            continue;
        }

        if (![extension isEqualToString:@"bundle"]) {
            continue;
        }

        NSString *bundlePath = [directoryPath stringByAppendingPathComponent:relativePath];
        BOOL itemIsDir = NO;
        if (![fm fileExistsAtPath:bundlePath isDirectory:&itemIsDir] || !itemIsDir) {
            continue;
        }

        [bundlePaths addObject:bundlePath];
        [enumerator skipDescendants];
    }

    return bundlePaths;
}

- (NSArray *)applicationSupportSearchRootsForJailbreakRoot:(NSString *)root {
    NSMutableOrderedSet *roots = [NSMutableOrderedSet orderedSet];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *globalApplicationSupportPath = [root
        stringByAppendingPathComponent:@"Library/Application Support"];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:globalApplicationSupportPath isDirectory:&isDir] && isDir) {
        [roots addObject:globalApplicationSupportPath];
    }

    NSString *appContainerRoot = @"/var/containers/Bundle/Application";
    NSArray *appContainers = [fm contentsOfDirectoryAtPath:appContainerRoot error:nil];
    for (NSString *containerName in appContainers) {
        NSString *containerPath = [appContainerRoot stringByAppendingPathComponent:containerName];
        BOOL containerIsDir = NO;
        if (![fm fileExistsAtPath:containerPath isDirectory:&containerIsDir] || !containerIsDir) {
            continue;
        }

        NSArray *items = [fm contentsOfDirectoryAtPath:containerPath error:nil];
        for (NSString *item in items) {
            if (![item hasPrefix:@".jbroot-"]) continue;

            NSString *jbrootPath = [containerPath stringByAppendingPathComponent:item];
            BOOL jbrootIsDir = NO;
            if (![fm fileExistsAtPath:jbrootPath isDirectory:&jbrootIsDir] || !jbrootIsDir) {
                continue;
            }

            NSString *applicationSupportPath = [jbrootPath
                stringByAppendingPathComponent:@"Library/Application Support"];
            BOOL appSupportIsDir = NO;
            if ([fm fileExistsAtPath:applicationSupportPath isDirectory:&appSupportIsDir] &&
                appSupportIsDir) {
                [roots addObject:applicationSupportPath];
            }
        }
    }

    return [roots array];
}

- (NSDictionary *)bundleEntryForPath:(NSString *)bundlePath
                      settingsLabels:(NSDictionary *)settingsLabels
                      seenBundleKeys:(NSMutableSet *)seen {
    NSString *bundleName = [[bundlePath lastPathComponent] stringByDeletingPathExtension];
    if (bundleName.length == 0 || [bundleName isEqualToString:@"TweakLangPrefs"]) {
        return nil;
    }

    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    NSString *bundleKey = bundleName;
    if (bundleKey.length == 0 || [seen containsObject:bundleKey]) {
        return nil;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *languages = [NSMutableArray array];
    NSArray *contents = [fm contentsOfDirectoryAtPath:bundlePath error:nil];
    for (NSString *sub in contents) {
        if ([sub hasSuffix:@".lproj"] &&
            ![sub isEqualToString:@"Base.lproj"]) {
            [languages addObject:[sub stringByDeletingPathExtension]];
        }
    }

    if (languages.count == 0) {
        return nil;
    }

    NSString *bundleDisplayName = TLBundleInfoDisplayName(bundle, bundleName);
    NSString *displayName = nil;
    for (NSString *lookupKey in TLLookupKeysForBundle(bundle, bundleName)) {
        NSString *resolvedLabel = settingsLabels[lookupKey];
        if (resolvedLabel.length > 0) {
            displayName = resolvedLabel;
            break;
        }
    }
    if (displayName.length == 0) {
        displayName = bundleDisplayName;
    }

    [languages sortUsingSelector:@selector(caseInsensitiveCompare:)];
    [seen addObject:bundleKey];
    NSMutableDictionary *entry = [@{
        @"name": displayName,
        @"bundleKey": bundleKey,
        @"path": bundlePath,
        @"languages": languages,
    } mutableCopy];
    if (bundleDisplayName.length > 0 && ![bundleDisplayName isEqualToString:bundleKey]) {
        entry[@"legacyKey"] = bundleDisplayName;
    }
    return entry;
}

- (NSArray *)scanInstalledBundles {
    NSMutableArray *results = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSString *root = [self jailbreakRoot];
    NSDictionary *settingsLabels = [self settingsDisplayNamesByLookupKey];

    NSMutableOrderedSet *bundlePaths = [NSMutableOrderedSet orderedSet];
    NSString *preferenceBundlesPath = [root
        stringByAppendingPathComponent:@"Library/PreferenceBundles"];
    [bundlePaths addObjectsFromArray:[self bundlePathsInDirectory:preferenceBundlesPath
                                                        recursive:NO]];

    for (NSString *applicationSupportRoot in
         [self applicationSupportSearchRootsForJailbreakRoot:root]) {
        [bundlePaths addObjectsFromArray:[self bundlePathsInDirectory:applicationSupportRoot
                                                            recursive:YES]];
    }

    for (NSString *bundlePath in bundlePaths) {
        NSDictionary *entry = [self bundleEntryForPath:bundlePath
                                        settingsLabels:settingsLabels
                                        seenBundleKeys:seen];
        if (entry) {
            [results addObject:entry];
        }
    }

    NSMutableDictionary *nameCounts = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in results) {
        NSString *displayName = entry[@"name"];
        if (displayName.length == 0) continue;
        NSNumber *count = nameCounts[displayName] ?: @0;
        nameCounts[displayName] = @(count.integerValue + 1);
    }

    for (NSMutableDictionary *entry in results) {
        NSString *displayName = entry[@"name"];
        if ([nameCounts[displayName] integerValue] > 1) {
            entry[@"name"] = [NSString stringWithFormat:@"%@ (%@)",
                displayName, entry[@"bundleKey"]];
        }
    }

    [results sortUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] compare:b[@"name"]
                               options:NSCaseInsensitiveSearch];
        }];

    return results;
}

- (NSArray *)cachedBundles {
    if (!_cachedBundles) {
        _cachedBundles = [[self scanInstalledBundles] copy];
    }

    return _cachedBundles ?: @[];
}

- (NSArray *)displayBundles {
    NSArray *bundles = [self cachedBundles];
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:bundles.count];

    for (NSDictionary *info in bundles) {
        NSMutableDictionary *entry = [info mutableCopy];
        entry[@"currentValue"] = TLReadLanguageOverrideValue(
            info[@"bundleKey"], info[@"legacyKey"]);
        [results addObject:entry];
    }

    [results sortUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            BOOL aCustomized = ![a[@"currentValue"] isEqualToString:@"system"];
            BOOL bCustomized = ![b[@"currentValue"] isEqualToString:@"system"];
            if (aCustomized != bCustomized) {
                return aCustomized ? NSOrderedAscending : NSOrderedDescending;
            }
            return [a[@"name"] compare:b[@"name"]
                               options:NSCaseInsensitiveSearch];
        }];

    return results;
}

- (NSDictionary *)settingsDisplayNamesByLookupKey {
    NSMutableDictionary *labels = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *preferencesPath = [[self jailbreakRoot]
        stringByAppendingPathComponent:@"Library/PreferenceLoader/Preferences"];
    NSArray *items = [fm contentsOfDirectoryAtPath:preferencesPath error:nil];

    for (NSString *item in items) {
        if (![[[item pathExtension] lowercaseString] isEqualToString:@"plist"]) {
            continue;
        }

        NSString *plistPath = [preferencesPath stringByAppendingPathComponent:item];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if (![plist isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSMutableArray *entries = [NSMutableArray array];
        id rawEntry = plist[@"entry"];
        if ([rawEntry isKindOfClass:[NSDictionary class]]) {
            [entries addObject:rawEntry];
        } else if ([rawEntry isKindOfClass:[NSArray class]]) {
            for (id candidate in (NSArray *)rawEntry) {
                if ([candidate isKindOfClass:[NSDictionary class]]) {
                    [entries addObject:candidate];
                }
            }
        }

        NSString *fallbackBundleName = [item stringByDeletingPathExtension];
        for (NSDictionary *entry in entries) {
            NSString *label = [entry[@"label"] isKindOfClass:[NSString class]]
                ? entry[@"label"]
                : nil;
            NSString *bundleReference = [entry[@"bundle"] isKindOfClass:[NSString class]]
                ? entry[@"bundle"]
                : fallbackBundleName;
            if (label.length == 0 || bundleReference.length == 0) {
                continue;
            }

            NSMutableOrderedSet *lookupKeys = [NSMutableOrderedSet orderedSet];
            TLAddBundleLookupKeys(lookupKeys, bundleReference);
            TLAddBundleLookupKeys(lookupKeys, fallbackBundleName);
            for (NSString *lookupKey in lookupKeys) {
                if (lookupKey.length > 0 && !labels[lookupKey]) {
                    labels[lookupKey] = label;
                }
            }
        }
    }

    return labels;
}

#pragma mark - Language Display Names

- (NSString *)displayNameForCode:(NSString *)code {
    NSString *normalized = [code stringByReplacingOccurrencesOfString:@"_"
                                                          withString:@"-"];
    NSLocale *locale = TLDisplayLocale();
    NSString *name = [locale displayNameForKey:NSLocaleIdentifier
                                        value:normalized];
    if (name && ![name isEqualToString:code] && ![name isEqualToString:normalized]) {
        return [NSString stringWithFormat:@"%@ (%@)", name, code];
    }
    return code;
}

@end

@implementation TLLanguageListController

- (NSString *)title {
    return self.specifier.name ?: TLLocalizedString(@"language.page_title", @"Language");
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self updateNavigationTitle];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self buildSpecifiers];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateNavigationTitle];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)updateNavigationTitle {
    NSString *resolvedTitle = self.specifier.name ?: TLLocalizedString(@"language.page_title", @"Language");
    self.title = resolvedTitle;
    self.navigationItem.title = resolvedTitle;
}

- (NSMutableArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    NSArray *values = [self.specifier propertyForKey:@"validValues"] ?: @[@"system"];
    NSArray *titles = [self.specifier propertyForKey:@"validTitles"] ?: @[TLLocalizedString(@"system_default", @"System Default")];
    NSString *bundlePath = [self.specifier propertyForKey:@"bundlePath"];
    NSString *currentValue = TLReadLanguageOverrideValue(
        [self.specifier propertyForKey:@"bundleKey"],
        [self.specifier propertyForKey:@"legacyKey"]);

    if (currentValue.length == 0) {
        currentValue = [self.specifier propertyForKey:@"default"] ?: @"system";
    }

    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:nil];
    [group setProperty:TLLocalizedString(@"language.instructions",
        @"Choose which localization this tweak's settings page should use.")
                forKey:@"footerText"];
    [specs addObject:group];

    NSUInteger count = MIN(values.count, titles.count);
    for (NSUInteger index = 0; index < count; index++) {
        NSString *value = values[index];
        NSString *title = titles[index];
        BOOL isCurrent = [value isEqualToString:currentValue];
        NSString *displayTitle = isCurrent
            ? [NSString stringWithFormat:TLLocalizedString(@"language.selected_format", @"[Selected] %@"), title]
            : title;

        PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:displayTitle
            target:self
            set:NULL
            get:NULL
            detail:Nil
            cell:PSButtonCell
            edit:Nil];

        spec.buttonAction = @selector(selectLanguage:);
        [spec setProperty:value forKey:@"value"];
        [specs addObject:spec];
    }

    if (bundlePath.length > 0) {
        PSSpecifier *toolsGroup = [PSSpecifier groupSpecifierWithName:
            TLLocalizedString(@"filza.group_title", @"Folder")];
        [toolsGroup setProperty:TLLocalizedString(@"filza.group_footer",
            @"Open this tweak's bundle folder in Filza.")
                        forKey:@"footerText"];
        [specs addObject:toolsGroup];

        PSSpecifier *filzaButton = [PSSpecifier preferenceSpecifierNamed:
            TLLocalizedString(@"filza.open_button", @"Open in Filza")
            target:self
            set:NULL
            get:NULL
            detail:Nil
            cell:PSButtonCell
            edit:Nil];
        filzaButton.buttonAction = @selector(openBundleFolderInFilza:);
        [filzaButton setProperty:bundlePath forKey:@"bundlePath"];
        [specs addObject:filzaButton];
    }

    return specs;
}

- (void)openBundleFolderInFilza:(PSSpecifier *)specifier {
    NSString *bundlePath = [specifier propertyForKey:@"bundlePath"];
    if (bundlePath.length == 0) {
        return;
    }

    NSString *encodedPath = [bundlePath stringByAddingPercentEncodingWithAllowedCharacters:
        [NSCharacterSet URLPathAllowedCharacterSet]];
    if (encodedPath.length == 0) {
        encodedPath = bundlePath;
    }

    NSURL *url = [NSURL URLWithString:[@"filza://view" stringByAppendingString:encodedPath]];
    if (!url) {
        [self presentFilzaUnavailableAlert];
        return;
    }

    UIApplication *application = [UIApplication sharedApplication];
    [application openURL:url
                 options:@{}
       completionHandler:^(BOOL success) {
           if (!success) {
               dispatch_async(dispatch_get_main_queue(), ^{
                   [self presentFilzaUnavailableAlert];
               });
           }
       }];
}

- (void)presentFilzaUnavailableAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        TLLocalizedString(@"filza.unavailable_title", @"Filza Unavailable")
        message:TLLocalizedString(@"filza.unavailable_message",
            @"Couldn't open Filza. Make sure Filza is installed and its URL scheme is enabled.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:
        TLLocalizedString(@"filza.unavailable_confirm", @"OK")
        style:UIAlertActionStyleDefault
        handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)selectLanguage:(PSSpecifier *)specifier {
    NSString *value = [specifier propertyForKey:@"value"] ?: @"system";
    TLWriteLanguageOverrideValue(value,
        [self.specifier propertyForKey:@"bundleKey"],
        [self.specifier propertyForKey:@"legacyKey"]);
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        PREF_NOTIFICATION, NULL, NULL, YES);
    [self.navigationController popViewControllerAnimated:YES];
}

@end
