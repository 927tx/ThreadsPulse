#import "TPLocalization.h"
#import <dlfcn.h>
#import "TPPrefs.h"
#import "TPVersion.h"

// The bundle that came with this dylib comes first: a sideloaded IPA carries its own, while a
// jailbroken device may still have an older one from a .deb install under /var/jb. Among the
// bundles found, one whose version matches this build wins; otherwise the first one found.
static NSBundle *TPBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *const rel = @"/Library/Application Support/ThreadsPulse/ThreadsPulse.bundle";
        NSMutableArray<NSString *> *paths = [NSMutableArray array];

        Dl_info info;
        NSString *dylib = nil;
        if (dladdr((const void *)&TPBundle, &info) && info.dli_fname) dylib = [NSString stringWithUTF8String:info.dli_fname];
        if (dylib) [paths addObject:[[dylib stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"ThreadsPulse.bundle"]];
        NSString *inApp = [NSBundle.mainBundle pathForResource:@"ThreadsPulse" ofType:@"bundle"];
        if (inApp) [paths addObject:inApp];
        [paths addObject:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/ThreadsPulse.bundle"]];

        const char *(*jbroot)(const char *) = dlsym(RTLD_DEFAULT, "jbroot");
        if (jbroot) {
            const char *r = jbroot(rel.fileSystemRepresentation);
            if (r) [paths addObject:[NSString stringWithUTF8String:r]];
        }
        for (NSString *marker in @[@"/Library/MobileSubstrate/DynamicLibraries/", @"/usr/lib/TweakInject/"]) {
            NSRange r = dylib ? [dylib rangeOfString:marker] : NSMakeRange(NSNotFound, 0);
            if (r.location != NSNotFound) {
                [paths addObject:[[dylib substringToIndex:r.location] stringByAppendingString:rel]];
                break;
            }
        }
        [paths addObject:[@"/var/jb" stringByAppendingString:rel]];
        [paths addObject:rel];

        NSBundle *first = nil;
        for (NSString *p in paths) {
            if (![NSFileManager.defaultManager fileExistsAtPath:p]) continue;
            NSBundle *b = [NSBundle bundleWithPath:p];
            if (!b) continue;
            if (!first) first = b;
            if ([[b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:TP_VERSION]) { bundle = b; break; }
        }
        if (!bundle) bundle = first;
    });
    return bundle;
}

// The language chosen in ThreadsPulse's settings, or for "Follow System" the best match of the
// device's languages among the bundle's own. That match is made here rather than left to NSBundle,
// which follows the host app's language for a bundle that isn't the app's own (a sideloaded or
// re-signed Threads can end up in English that way).
static NSDictionary<NSString *, NSString *> *TPChosenTable(NSBundle *b) {
    static NSString *const codes[] = { nil, @"en", @"zh-Hant", @"zh-Hans", @"ja", @"ko", @"vi" };
    static NSDictionary *tables[7];
    NSInteger lang = [[TPPrefs defaults] integerForKey:TPKeyLanguage];
    if (lang < 0 || lang > 6) lang = 0;
    // TPL() is also called from background queues (downloads, Author Info): load each table once,
    // under a lock, so two threads can't store it at the same time.
    @synchronized ([NSBundle class]) {
    if (!tables[lang]) {
        NSString *code = codes[lang];
        if (!code) {
            NSMutableArray *have = [NSMutableArray array];
            for (NSString *l in b.localizations) if (![l isEqualToString:@"Base"]) [have addObject:l];
            code = [NSBundle preferredLocalizationsFromArray:have forPreferences:NSLocale.preferredLanguages].firstObject;
            // With none of the device's languages available, the match is just some localization: use English.
            BOOL spoken = NO;
            for (NSString *pref in NSLocale.preferredLanguages)
                if (code.length && [code hasPrefix:[pref componentsSeparatedByString:@"-"].firstObject]) { spoken = YES; break; }
            if (!spoken) code = @"en";
        }
        // The file is read straight from <code>.lproj: NSBundle's own lookup by localization name can
        // miss on some installs (it matched nothing for zh-Hant on a sideloaded build).
        NSString *path = [b.bundlePath stringByAppendingPathComponent:[code stringByAppendingString:@".lproj/Localizable.strings"]];
        if (![NSFileManager.defaultManager fileExistsAtPath:path])
            path = [b pathForResource:@"Localizable" ofType:@"strings" inDirectory:nil forLocalization:code];
        tables[lang] = (path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil) ?: @{};
    }
    return tables[lang];
    }
}

NSString *TPLocalized(NSString *key) {
    NSBundle *b = TPBundle();
    if (!b) return key;
    NSDictionary *t = TPChosenTable(b);
    return t[key] ?: key;
}
