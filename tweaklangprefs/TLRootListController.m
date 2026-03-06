#import "TLRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>

#define PREF_DOMAIN       @"com.tune.tweaklang"
#define PREF_NOTIFICATION CFSTR("com.tune.tweaklang/prefschanged")
#define LANG_KEY_PREFIX   @"lang_"
#define UI_LANG_KEY       @"ui_language"

@interface TLLanguageListController : PSListController
@end

static NSBundle *TLPrefsBundle(void) {
    return [NSBundle bundleForClass:[TLRootListController class]];
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

@implementation TLRootListController

- (NSString *)title {
    return TLLocalizedString(@"app.title", @"TweakLang");
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

    PSSpecifier *header = [PSSpecifier groupSpecifierWithName:TLLocalizedString(@"app.title", @"TweakLang")];
    [header setProperty:TLLocalizedString(@"header.footer",
        @"Override the display language for individual jailbreak tweaks.\nChanges take effect when you re-enter a tweak's settings page.")
                 forKey:@"footerText"];
    [specs addObject:header];

    NSArray *bundles = [self scanInstalledBundles];

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
        [spec setProperty:[LANG_KEY_PREFIX stringByAppendingString:name]
                   forKey:@"key"];
        [spec setProperty:@"system" forKey:@"default"];
        [spec setProperty:validValues forKey:@"validValues"];
        [spec setProperty:validTitles forKey:@"validTitles"];

        [specs addObject:spec];
    }

    return specs;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateLocalizedChrome];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)updateLocalizedChrome {
    self.title = [self title];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:TLLocalizedString(@"ui.button", @"Lang")
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(showInterfaceLanguagePicker)];
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

#pragma mark - Preference I/O

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
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

- (NSArray *)scanInstalledBundles {
    NSMutableArray *results = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self jailbreakRoot];

    NSArray *scanDirs = @[
        @"Library/PreferenceBundles",
        @"Library/Application Support",
    ];

    for (NSString *relDir in scanDirs) {
        NSString *fullDir = [root stringByAppendingPathComponent:relDir];
        NSArray *items = [fm contentsOfDirectoryAtPath:fullDir error:nil];
        if (!items) continue;

        for (NSString *item in items) {
            if (![item hasSuffix:@".bundle"]) continue;

            NSString *bundleName = [item stringByDeletingPathExtension];
            if ([bundleName isEqualToString:@"TweakLangPrefs"]) continue;
            if ([seen containsObject:bundleName]) continue;

            NSString *bundlePath = [fullDir stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:bundlePath isDirectory:&isDir] || !isDir) {
                continue;
            }

            NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
            NSString *displayName = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
            if (displayName.length == 0) {
                displayName = [bundle objectForInfoDictionaryKey:@"CFBundleName"];
            }
            if (displayName.length == 0) {
                displayName = bundleName;
            }

            NSMutableArray *languages = [NSMutableArray array];
            NSArray *contents = [fm contentsOfDirectoryAtPath:bundlePath error:nil];
            for (NSString *sub in contents) {
                if ([sub hasSuffix:@".lproj"] &&
                    ![sub isEqualToString:@"Base.lproj"]) {
                    [languages addObject:[sub stringByDeletingPathExtension]];
                }
            }

            if (languages.count == 0) continue;

            [languages sortUsingSelector:@selector(caseInsensitiveCompare:)];
            [seen addObject:bundleName];
            [results addObject:@{
                @"name": displayName,
                @"path": bundlePath,
                @"languages": languages,
            }];
        }
    }

    [results sortUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] compare:b[@"name"]
                               options:NSCaseInsensitiveSearch];
        }];

    return results;
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
    NSString *currentValue = [self readPreferenceValue:self.specifier];

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

    return specs;
}
- (void)selectLanguage:(PSSpecifier *)specifier {
    NSString *value = [specifier propertyForKey:@"value"] ?: @"system";
    [super setPreferenceValue:value specifier:self.specifier];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        PREF_NOTIFICATION, NULL, NULL, YES);
    [self.navigationController popViewControllerAnimated:YES];
}

@end
