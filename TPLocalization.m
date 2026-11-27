#import "TPLocalization.h"
#import <dlfcn.h>
#import "TPPrefs.h"

static NSBundle *TPBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *const rel = @"/Library/Application Support/ThreadsPulse/ThreadsPulse.bundle";
        NSMutableArray<NSString *> *paths = [NSMutableArray array];

        const char *(*jbroot)(const char *) = dlsym(RTLD_DEFAULT, "jbroot");
        if (jbroot) {
            const char *r = jbroot(rel.fileSystemRepresentation);
            if (r) [paths addObject:[NSString stringWithUTF8String:r]];
        }

        Dl_info me;
        if (dladdr((const void *)&TPBundle, &me) && me.dli_fname) {
            NSString *dylib = [NSString stringWithUTF8String:me.dli_fname];
            for (NSString *marker in @[@"/Library/MobileSubstrate/DynamicLibraries/", @"/usr/lib/TweakInject/"]) {
                NSRange r = [dylib rangeOfString:marker];
                if (r.location != NSNotFound) {
                    [paths addObject:[[dylib substringToIndex:r.location] stringByAppendingString:rel]];
                    break;
                }
            }
        }

        [paths addObject:[@"/var/jb" stringByAppendingString:rel]];
        [paths addObject:rel];

        NSString *inApp = [NSBundle.mainBundle pathForResource:@"ThreadsPulse" ofType:@"bundle"];
        if (inApp) [paths addObject:inApp];
        [paths addObject:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/ThreadsPulse.bundle"]];

        Dl_info info;
        if (dladdr((const void *)&TPBundle, &info) && info.dli_fname) {
            NSString *dir = [[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];
            [paths addObject:[dir stringByAppendingPathComponent:@"ThreadsPulse.bundle"]];
        }

        for (NSString *p in paths) {
            if ([NSFileManager.defaultManager fileExistsAtPath:p]) {
                bundle = [NSBundle bundleWithPath:p];
                if (bundle) break;
            }
        }
    });
    return bundle;
}

// The language chosen in ThreadsPulse's settings, or the system's when "Follow System".
static NSDictionary<NSString *, NSString *> *TPChosenTable(NSBundle *b) {
    static NSString *const codes[] = { nil, @"en", @"zh-Hant", @"zh-Hans", @"ja", @"ko", @"vi" };
    static NSDictionary *tables[7];
    NSInteger lang = [[TPPrefs defaults] integerForKey:TPKeyLanguage];
    if (lang < 1 || lang > 6) return nil;
    if (!tables[lang]) {
        NSString *path = [b pathForResource:@"Localizable" ofType:@"strings" inDirectory:nil
                            forLocalization:codes[lang]];
        tables[lang] = (path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil) ?: @{};
    }
    return tables[lang];
}

NSString *TPLocalized(NSString *key) {
    NSBundle *b = TPBundle();
    if (!b) return key;
    NSDictionary *t = TPChosenTable(b);
    if (t) return t[key] ?: key;
    return [b localizedStringForKey:key value:key table:nil];
}
