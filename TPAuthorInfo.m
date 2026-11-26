#import "TPAuthorInfo.h"
#import "TPPrefs.h"
#import "TPUI.h"
#import "TPHUD.h"
#import "TPLocalization.h"
#import "TPVersion.h"
#import "TPDownloader.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <malloc/malloc.h>

NSString *const TPAuthorInfoDidUpdateNotification = @"TPAuthorInfoDidUpdateNotification";
void (^TPAuthorOpenProfile)(NSString *username);

static NSString *TPFlagForCountry(NSString *name);
static NSString *const kAppID        = @"com.bloks.www.text_post_app.about_this_profile_async_action";
static NSString *const kCacheKey     = @"tp_author_cache";
static NSString *const kPausedKey    = @"tp_author_paused_until";
static NSString *const kVariantKey   = @"tp_author_param_format";

static const NSTimeInterval kDelay          = 1.5;            // seconds between requests
static const NSTimeInterval kCooldown       = 60 * 60;        // rate-limit pause
static const NSTimeInterval kTTLLocation    = 21 * 86400;     // entries with a location
static const NSTimeInterval kTTLNoLocation  = 1 * 86400;      // entries without one
static const NSTimeInterval kTTLFailure     = 30 * 60;        // failed lookups
static const NSTimeInterval kTimeout        = 45;
static const NSUInteger     kQueueMax       = 10;
static const NSUInteger     kCacheMax       = 3000;
static const NSUInteger     kSessionMax     = 400;            // hard cap per app launch

static NSMutableDictionary<NSString *, NSDictionary *> *gCache;
static NSMutableArray<NSString *> *gQueue;
static NSMutableSet<NSString *> *gPending;
static id gObjectSet;
static BOOL gSelfCall;
static NSString *const kSynthPending  = @"tp_author_synth_pending";
static NSString *const kSynthDisabled = @"tp_author_synth_disabled";
static __weak id gUserSession;
static id gPandoService;
static id gPandoConsistency;
static id gAnalytics;
static id gSyntheticSet;          // object set we built ourselves
static NSInteger gSyntheticSubtype = -1;
static BOOL gSyntheticFailed;
static BOOL gHintShown;
static NSInteger gSyntheticRetries;  // retries of the built object set this launch (bad network)
static NSHashTable *gBadObjectSets;
static NSString *gObjectSetSource;
static BOOL gInFlight;
static NSUInteger gToken;
static NSString *gInFlightPk;
static CFAbsoluteTime gLastRequest;
static NSUInteger gSessionCount;
static NSUInteger gEmptyStreak;
static NSUInteger gSuccessCount;
static BOOL gParserGaveUp;
static BOOL gSaveScheduled;
static BOOL gPumpScheduled;
static NSMutableString *gDiag;

@interface TPAuthorBadgeLabel : UILabel
@property (nonatomic, copy) NSString *pk;
@property (nonatomic, weak) UIView *host;
@property (nonatomic, strong) CALayer *capsule;   // outline around everything after the NEW tag
@end

@implementation TPAuthorBadgeLabel
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.lineBreakMode = NSLineBreakByTruncatingTail;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(infoChanged:) name:TPAuthorInfoDidUpdateNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(prefsChanged:) name:TPPrefsDidChangeNotification object:nil];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)infoChanged:(NSNotification *)n {
    NSString *pk = n.userInfo[@"pk"];
    if (!pk || [pk isEqualToString:self.pk]) [self.host setNeedsLayout];
}
- (void)prefsChanged:(NSNotification *)n {
    NSString *k = n.userInfo[@"key"];
    if ([k hasPrefix:@"tp_author"] || [k isEqualToString:TPKeyTheme]) [self.host setNeedsLayout];
}
@end

@interface TPAuthorInfo ()
+ (void)pump;
@end

static CGFloat TPPkDistance(NSString *pk);

@implementation TPAuthorInfo

#pragma mark - Diagnostics

+ (void)log:(NSString *)line {
    if (![TPPrefs boolForKey:TPKeyDebugToast] || !line.length) return;
    void (^append)(void) = ^{
        if (!gDiag) gDiag = [NSMutableString string];
        static NSDateFormatter *f;
        if (!f) { f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss"; }
        [gDiag appendFormat:@"%@ %@\n", [f stringFromDate:[NSDate date]], line];
        if (gDiag.length > 14000) [gDiag deleteCharactersInRange:NSMakeRange(0, gDiag.length - 10000)];
    };
    if (NSThread.isMainThread) append(); else dispatch_async(dispatch_get_main_queue(), append);
}

+ (NSString *)diagnostics {
    NSMutableString *s = [NSMutableString stringWithFormat:@"ThreadsPulse %@ · Author Info\n", TP_VERSION];
    [s appendFormat:@"objectSet: %@ (%@)\n", gObjectSet ? NSStringFromClass([gObjectSet class]) : @"none", gObjectSetSource ?: @"-"];
    [s appendFormat:@"variant: %ld  requests: %lu  ok: %lu  emptyStreak: %lu  gaveUp: %d\n",
        (long)[[TPPrefs defaults] integerForKey:kVariantKey], (unsigned long)gSessionCount,
        (unsigned long)gSuccessCount, (unsigned long)gEmptyStreak, gParserGaveUp];
    [s appendFormat:@"built: disabled=%d last=%@ session=%d svc=%d\n", [[TPPrefs defaults] boolForKey:kSynthDisabled],
        [[TPPrefs defaults] stringForKey:@"tp_author_synth_last"] ?: @"-", gUserSession != nil, gPandoService != nil];
    [s appendFormat:@"cached: %lu  queue: %lu  paused: %.0fs\n", (unsigned long)gCache.count, (unsigned long)gQueue.count, [self pausedRemaining]];
    if (gDiag.length) [s appendString:gDiag];
    return s;
}

#pragma mark - Cache

static void TPLoadCache(void) {
    if (gCache) return;
    // One-time reset: earlier test builds could disable the built object set too eagerly.
    if (![[TPPrefs defaults] boolForKey:@"tp_author_synth_v3"]) {
        [[TPPrefs defaults] setBool:YES forKey:@"tp_author_synth_v3"];
        [[TPPrefs defaults] removeObjectForKey:kSynthDisabled];
        [[TPPrefs defaults] removeObjectForKey:kSynthPending];
    }
    if ([[TPPrefs defaults] boolForKey:kSynthPending] && [[TPPrefs defaults] boolForKey:@"tp_author_synth_worked"]) {
        // It has worked before, so an unfinished try means Threads was closed, not that it crashed.
        [[TPPrefs defaults] removeObjectForKey:kSynthPending];
    }
    if ([[TPPrefs defaults] boolForKey:kSynthPending]) {
        // The previous launch died while trying a built object set.
        [[TPPrefs defaults] removeObjectForKey:kSynthPending];
        [[TPPrefs defaults] setBool:YES forKey:kSynthDisabled];
        [[TPPrefs defaults] setObject:@"app closed or crashed during the try" forKey:@"tp_author_synth_last"];
    }
    gCache = [NSMutableDictionary dictionary];
    gQueue = [NSMutableArray array];
    gPending = [NSMutableSet set];
    NSDictionary *saved = [[TPPrefs defaults] dictionaryForKey:kCacheKey];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    [saved enumerateKeysAndObjectsUsingBlock:^(NSString *pk, NSDictionary *e, BOOL *stop) {
        if (![e isKindOfClass:[NSDictionary class]]) return;
        if ([e[@"joined"] hasPrefix:@"#"]) return;   // bad parse from an earlier build
        if ([e[@"v"] integerValue] < 2 && e[@"joined"]) return;   // saved before the join number was kept
        if ([e[@"v"] integerValue] < 3 && e[@"joined"] && !e[@"location"]) return;   // may be a hidden location
        if ([e[@"x"] doubleValue] > now) gCache[pk] = e;
    }];
}

static void TPSaveCacheSoon(void) {
    if (gSaveScheduled) return;
    gSaveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gSaveScheduled = NO;
        if (gCache.count > kCacheMax) {
            NSArray *keys = [gCache keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"x"] compare:b[@"x"]];
            }];
            for (NSUInteger i = 0; i < keys.count - kCacheMax; i++) [gCache removeObjectForKey:keys[i]];
        }
        [[TPPrefs defaults] setObject:[gCache copy] forKey:kCacheKey];
    });
}

static NSMutableDictionary<NSString *, NSString *> *gHeaderNames;
static NSMutableDictionary<NSString *, NSString *> *gPostAuthors;   // pk -> handle seen in a feed header

static void TPStore(NSString *pk, NSString *location, NSString *joined, NSString *number, BOOL hidden, BOOL failed, NSDictionary *extra) {
    if (![extra[@"u"] length] && gHeaderNames[pk]) {
        NSMutableDictionary *m = [extra mutableCopy] ?: [NSMutableDictionary dictionary];
        m[@"u"] = gHeaderNames[pk];
        extra = m;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    if (location.length) e[@"location"] = location;
    if (joined.length) e[@"joined"] = joined;
    if (number.length) e[@"number"] = number;
    if (hidden && !location.length) e[@"hidden"] = @YES;
    if ([extra[@"u"] length]) e[@"u"] = extra[@"u"];
    if ([extra[@"n"] length]) e[@"n"] = extra[@"n"];
    e[@"v"] = @3;
    NSTimeInterval ttl = failed ? kTTLFailure : (location.length ? kTTLLocation : kTTLNoLocation);
    e[@"x"] = @(now + ttl);
    gCache[pk] = e;
    TPSaveCacheSoon();
    [NSNotificationCenter.defaultCenter postNotificationName:TPAuthorInfoDidUpdateNotification object:nil userInfo:@{ @"pk": pk }];
}

#pragma mark - Public state

+ (BOOL)enabled {
    if (![TPPrefs boolForKey:TPKeyAuthorInfo]) return NO;
    return [TPPrefs boolForKey:TPKeyAuthorLocation] || [TPPrefs boolForKey:TPKeyAuthorJoined] || [TPPrefs boolForKey:TPKeyAuthorNewBadge];
}

+ (NSDictionary *)infoForPk:(NSString *)pk {
    if (!pk.length) return nil;
    TPLoadCache();
    NSDictionary *e = gCache[pk];
    if (!e) return nil;
    if ([e[@"x"] doubleValue] < [NSDate date].timeIntervalSince1970) { [gCache removeObjectForKey:pk]; return nil; }
    return e;
}

+ (NSTimeInterval)pausedRemaining {
    NSTimeInterval until = [[TPPrefs defaults] doubleForKey:kPausedKey];
    NSTimeInterval left = until - [NSDate date].timeIntervalSince1970;
    return left > 0 ? left : 0;
}

+ (void)resume {
    [[TPPrefs defaults] removeObjectForKey:kPausedKey];
    gParserGaveUp = NO;
    gEmptyStreak = 0;
    [self log:@"resumed by user"];
    [self pump];
}

+ (NSDictionary *)exportCache {
    TPLoadCache();
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    [gCache enumerateKeysAndObjectsUsingBlock:^(NSString *pk, NSDictionary *e, BOOL *stop) {
        if ([e[@"x"] doubleValue] <= now) return;
        if (![e[@"location"] length] && ![e[@"joined"] length] && ![e[@"hidden"] boolValue]) return;   // failed lookups
        out[pk] = e;
    }];
    return out;
}

+ (NSInteger)importCache:(NSDictionary *)entries {
    if (![entries isKindOfClass:[NSDictionary class]]) return 0;
    TPLoadCache();
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    __block NSInteger n = 0;
    [entries enumerateKeysAndObjectsUsingBlock:^(id pk, id e, BOOL *stop) {
        if (![pk isKindOfClass:[NSString class]] || ![e isKindOfClass:[NSDictionary class]]) return;
        if ([e[@"v"] integerValue] < 3 || [e[@"x"] doubleValue] <= now) return;
        if ([gCache[pk][@"x"] doubleValue] >= [e[@"x"] doubleValue]) return;
        gCache[pk] = e;
        n++;
    }];
    if (n) {
        TPSaveCacheSoon();
        [NSNotificationCenter.defaultCenter postNotificationName:TPAuthorInfoDidUpdateNotification object:nil userInfo:@{}];
    }
    return n;
}

+ (void)clearCache {
    TPLoadCache();
    [gCache removeAllObjects];
    [[TPPrefs defaults] removeObjectForKey:kCacheKey];
    [NSNotificationCenter.defaultCenter postNotificationName:TPAuthorInfoDidUpdateNotification object:nil userInfo:@{}];
}

+ (NSUInteger)cachedCount { TPLoadCache(); return gCache.count; }

+ (NSArray<NSDictionary *> *)allEntries {
    TPLoadCache();
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSMutableArray *out = [NSMutableArray array];
    [gCache enumerateKeysAndObjectsUsingBlock:^(NSString *pk, NSDictionary *e, BOOL *stop) {
        if ([e[@"x"] doubleValue] < now) return;
        if (!e[@"location"] && !e[@"hidden"] && !e[@"joined"]) return;   // failed lookups
        NSMutableDictionary *m = [e mutableCopy];
        m[@"pk"] = pk;
        [out addObject:m];
    }];
    return out;
}

+ (NSString *)flagForCountry:(NSString *)name { return TPFlagForCountry(name); }
+ (NSUInteger)sessionRequestCount { return gSessionCount; }

+ (void)noteUserSession:(id)session {
    if (session) gUserSession = session;
}
+ (void)noteService:(id)obj kind:(NSString *)kind {
    if (!obj) return;
    if ([kind isEqualToString:@"pando"]) gPandoService = obj;
    else if ([kind isEqualToString:@"consistency"]) gPandoConsistency = obj;
    else if ([kind isEqualToString:@"analytics"]) gAnalytics = obj;
}


// Builds an object set holding the logged-in session, so reading can start without the user
// opening "About this profile" first. Guarded: a crash during the first try disables it for good.

static id TPBuildObjectSet(NSInteger subtype) {

    id session = gUserSession;
    Class OS = objc_getClass("BKObjectSet"), SC = objc_getClass("IGSessionContext");
    if (!session || !OS || !SC) return nil;
    id os = [[OS alloc] init];
    Ivar tiv = class_getInstanceVariable(OS, "_table");
    if (!os || !tiv) return nil;
    NSMapTable *t = object_getIvar(os, tiv);
    if (![t isKindOfClass:[NSMapTable class]]) {
        t = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                      valueOptions:NSPointerFunctionsStrongMemory capacity:8];
        object_setIvar(os, tiv, t);
    }
    id ctx = [[SC alloc] init];
    Ivar us = class_getInstanceVariable(SC, "_loggedInContext_userSession");
    Ivar st = class_getInstanceVariable(SC, "_subtype");
    if (!ctx || !us || !st) return nil;
    object_setIvar(ctx, us, session);
    *(unsigned long long *)((char *)(__bridge void *)ctx + ivar_getOffset(st)) = (unsigned long long)subtype;
    [t setObject:ctx forKey:SC];
    Class foa = objc_getClass("FOAUserSession");
    if (foa) [t setObject:session forKey:foa];
    Class pc;
    if (gPandoService && (pc = objc_getClass("PNPandoGraphQLService"))) [t setObject:gPandoService forKey:pc];
    if (gPandoConsistency && (pc = objc_getClass("PNPandoGraphQLConsistency"))) [t setObject:gPandoConsistency forKey:pc];
    Protocol *alp = objc_getProtocol("FBAnalyticsLogging");
    if (gAnalytics && alp) [t setObject:gAnalytics forKey:(id)alp];
    for (NSString *name in @[@"BKGlobalStateStore", @"BKBloksSessionStore"]) {
        Class c = objc_getClass(name.UTF8String);
        id v = c ? [[c alloc] init] : nil;
        if (v) [t setObject:v forKey:c];
    }
    return os;
}

+ (void)noteObjectSet:(id)objectSet source:(NSString *)source {
    if (!objectSet || gSelfCall || [gBadObjectSets containsObject:objectSet]) return;
    if (objectSet != gObjectSet) [self log:[NSString stringWithFormat:@"objectSet captured from %@ (%@)", source, NSStringFromClass([objectSet class])]];
    gObjectSet = objectSet;
    gObjectSetSource = source;
    if (gQueue.count && !gInFlight) dispatch_async(dispatch_get_main_queue(), ^{ [self pump]; });
}

#pragma mark - Joined date

// Usernames Threads assigns when none is chosen at sign-up: an animal word, a dot and 6-8 digits
// (camel.253044). Word list and rule from lee-su-threads (MIT, see ThirdPartyLicenses). Only that exact form matches.
+ (BOOL)isDefaultUsername:(NSString *)username {
    if (username.length < 8) return NO;
    static NSSet *animals;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        animals = [NSSet setWithArray:@[@"aardvark", @"alligator", @"armadillo", @"badger", @"bat", @"bear", @"camel", @"capybara", @"chameleon", @"cheetah", @"chipmunk", @"crab", @"deer", @"dinosaur", @"dolphin", @"dragon", @"duck", @"elephant", @"elk", @"fox", @"gazelle", @"gecko", @"giraffe", @"goat", @"goose", @"hamster", @"hawk", @"horse", @"iguana", @"jellyfish", @"kangaroo", @"kitty", @"koala", @"lemming", @"leopard", @"lion", @"llama", @"lynx", @"macaque", @"marmoset", @"millipede", @"mongoose", @"moose", @"mouse", @"otter", @"owl", @"panda", @"panther", @"penguin", @"pigeon", @"platypus", @"quail", @"rabbit", @"reindeer", @"rhea", @"rhino", @"scorpion", @"seal", @"sheep", @"shrimp", @"sloth", @"spoonbill", @"squirrel", @"swan", @"tiger", @"turtle", @"unicorn", @"wolf", @"zebra"]];
        re = [NSRegularExpression regularExpressionWithPattern:@"^([a-z]+)\\.(\\d{6,8})$" options:0 error:nil];
    });
    NSString *u = username.lowercaseString;
    NSTextCheckingResult *m = [re firstMatchInString:u options:0 range:NSMakeRange(0, u.length)];
    return m && [animals containsObject:[u substringWithRange:[m rangeAtIndex:1]]];
}

+ (BOOL)isNewAccount:(NSString *)joined {
    if (!joined.length) return NO;
    NSRegularExpression *yr = [NSRegularExpression regularExpressionWithPattern:@"(\\d{4})" options:0 error:nil];
    NSTextCheckingResult *ym = [yr firstMatchInString:joined options:0 range:NSMakeRange(0, joined.length)];
    if (!ym) return NO;
    NSInteger year = [[joined substringWithRange:[ym rangeAtIndex:1]] integerValue];
    NSInteger month = -1;
    NSRegularExpression *cjk = [NSRegularExpression regularExpressionWithPattern:@"(\\d{1,2})\\s*[月월]" options:0 error:nil];
    NSTextCheckingResult *cm = [cjk firstMatchInString:joined options:0 range:NSMakeRange(0, joined.length)];
    if (cm) month = [[joined substringWithRange:[cm rangeAtIndex:1]] integerValue];
    if (month < 1) {
        NSArray *names = @[@"jan", @"feb", @"mar", @"apr", @"may", @"jun", @"jul", @"aug", @"sep", @"oct", @"nov", @"dec"];
        NSString *low = joined.lowercaseString;
        for (NSUInteger i = 0; i < names.count; i++) if ([low containsString:names[i]]) { month = i + 1; break; }
    }
    if (month < 1 || month > 12) return NO;
    NSCalendar *greg = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian]; // ROC calendar users would get year 115
    NSDateComponents *now = [greg components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:[NSDate date]];
    NSInteger joinedIdx = year * 12 + (month - 1);
    NSInteger nowIdx = now.year * 12 + (now.month - 1);
    return nowIdx - joinedIdx <= 2 && nowIdx - joinedIdx >= 0;
}

#pragma mark - Pointer safety

// A class pointer read from memory counts as a class when it lies inside a loaded image (the app,
// a framework or the system). objc_copyClassList used to supply the full list, but it loads every
// class in Threads at once, which crashes on iOS 16.
// A real class's isa (its metaclass) and the metaclass's isa (the root metaclass) also lie in an
// image; checking all three with dladdr only ever reads memory inside loaded images.
static BOOL TPIsImageClass(uintptr_t isa) {
    for (int depth = 0; depth < 3; depth++) {
        if (isa < 0x100000000ULL) return NO;
        Dl_info info;
        if (!dladdr((const void *)isa, &info) || !info.dli_fname) return NO;
        isa = *(const uintptr_t *)isa & 0x0000000ffffffff8ULL;
    }
    return YES;
}

// Block arguments of unknown signature are received as raw pointers; only treat one as an object
// when it is a tagged pointer or a heap allocation whose isa is a known class.
static id TPAsObject(void *p) {
    uintptr_t v = (uintptr_t)p;
    if (!v) return nil;
    if ((intptr_t)v < 0) return (__bridge id)p;
    if (v < 0x100000000ULL || (v & 7)) return nil;
    if (malloc_size(p) < 16) return nil;
    uintptr_t isa = *(uintptr_t *)p;
    const uintptr_t masks[] = { 0x0000000ffffffff8ULL, 0x007ffffffffffff8ULL, ~(uintptr_t)7 };
    for (int i = 0; i < 3; i++) {
        if (TPIsImageClass(isa & masks[i])) return (__bridge id)p;
    }
    return nil;
}

#pragma mark - String harvesting

static BOOL TPSkipClass(id obj) {
    NSString *n = NSStringFromClass([obj class]);
    for (NSString *p in @[@"UI", @"CA", @"BKObjectSet", @"BKContext", @"IGUserSession", @"FBMobileConfig", @"NSMapTable", @"NSHashTable", @"NSBundle", @"NSUserDefaults"]) {
        if ([n hasPrefix:p]) return YES;
    }
    return NO;
}

static void TPHarvestStrings(id obj, int depth, NSMutableSet<NSValue *> *visited, NSMutableArray<NSString *> *out, int *budget) {
    if (!obj || depth > 400 || *budget <= 0) return;
    (*budget)--;
    if ([obj isKindOfClass:[NSString class]]) { if ([(NSString *)obj length]) [out addObject:obj]; return; }
    if ([obj isKindOfClass:[NSAttributedString class]]) { [out addObject:[(NSAttributedString *)obj string]]; return; }
    if ([obj isKindOfClass:[NSData class]]) {
        NSData *d = obj;
        if (d.length > 2 && d.length < 4000000) {
            NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            if ([s hasPrefix:@"for (;;);"]) s = [s substringFromIndex:9];
            id json = s ? [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
            if (json) TPHarvestStrings(json, depth + 1, visited, out, budget);
            else if (s.length) [out addObject:s];
        }
        return;
    }
    if ([obj isKindOfClass:[NSNumber class]]) { [out addObject:[@"\u241Fnum:" stringByAppendingString:[obj stringValue]]]; return; }
    if ([obj isKindOfClass:[NSDate class]] || [obj isKindOfClass:[NSURL class]]) return;
    if ([obj isKindOfClass:[UIResponder class]] || [obj isKindOfClass:[CALayer class]] || [obj isKindOfClass:[UIImage class]]) return;
    if ([obj isKindOfClass:[NSError class]]) {
        NSError *e = obj;
        [out addObject:[NSString stringWithFormat:@"NSError %@ %ld", e.domain, (long)e.code]];
        if (e.localizedDescription) [out addObject:e.localizedDescription];
        TPHarvestStrings(e.userInfo, depth + 1, visited, out, budget);
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = obj;
        if (d[@"text"] || d[@"text_style"] || d[@"on_bind"]) {
            id style = d[@"text_style"];
            if ([style isKindOfClass:[NSString class]]) [out addObject:[@"␟style:" stringByAppendingString:style]];
        }
        for (id k in d) TPHarvestStrings(d[k], depth + 1, visited, out, budget);
        return;
    }
    if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSOrderedSet class]] || [obj isKindOfClass:[NSSet class]]) {
        for (id v in obj) TPHarvestStrings(v, depth + 1, visited, out, budget);
        return;
    }
    if (TPSkipClass(obj) || depth > 14) return;
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)obj];
    if ([visited containsObject:key]) return;
    [visited addObject:key];
    for (Class c = object_getClass(obj); c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *enc = ivar_getTypeEncoding(ivars[i]);
            if (!enc || enc[0] != '@' || enc[1] == '?') continue;
            id v = object_getIvar(obj, ivars[i]);
            TPHarvestStrings(v, depth + 1, visited, out, budget);
        }
        free(ivars);
    }
}

static NSString *TPDecodeEscapes(NSString *s) {
    if (![s containsString:@"\\u"]) return s;
    NSString *wrapped = [NSString stringWithFormat:@"\"%@\"", [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
    id v = [NSJSONSerialization JSONObjectWithData:[wrapped dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:nil];
    return [v isKindOfClass:[NSString class]] ? v : s;
}

// Bloks hides the location in a conditional binding: (bk.action.core.If, cond, "Taiwan", "Not shared")
static NSString *TPValueFromBinding(NSString *s) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\"((?:[^\"\\\\]|\\\\.)*)\"\\s*,\\s*\"((?:[^\"\\\\]|\\\\.)+)\"" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return nil;
    NSString *a = TPDecodeEscapes([s substringWithRange:[m rangeAtIndex:1]]);
    NSString *b = TPDecodeEscapes([s substringWithRange:[m rangeAtIndex:2]]);
    return a.length ? a : b;
}

static NSArray<NSString *> *kJoinedLabels, *kLocationLabels, *kSkipLabels;

static void TPInitLabels(void) {
    if (kJoinedLabels) return;
    kJoinedLabels   = @[@"Joined", @"已加入", @"加入日期", @"加入時間", @"参加日", @"가입일", @"가입 날짜", @"Se unió", @"Inscrit(e)"];
    kLocationLabels = @[@"Based in", @"所在地點", @"所在地", @"所在地区", @"위치", @"거주지", @"Ubicación"];
    kSkipLabels     = @[@"Name", @"名稱", @"名称", @"名前", @"이름",
                        @"Former usernames", @"Previous usernames", @"先前的用戶名稱", @"先前的使用者名稱", @"先前的用户名称", @"以前のユーザーネーム", @"이전 사용자 이름",
                        @"Verified by Meta", @"Meta 驗證", @"Meta 验证", @"Metaにより認証", @"Metaにより認証済み", @"Meta認証", @"Meta 인증", @"Meta 인증 완료"];
}

static BOOL TPIsLabel(NSString *s) {
    return [kJoinedLabels containsObject:s] || [kLocationLabels containsObject:s] || [kSkipLabels containsObject:s];
}

static NSString *TPCleanValue(NSString *raw) {
    NSString *s = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([s hasPrefix:@"("] && [s containsString:@"\""]) s = TPValueFromBinding(s);
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!s.length || s.length > 80 || [s hasPrefix:@"␟"] || [s hasPrefix:@"http"] || TPIsLabel(s)) return nil;
    return s;
}

// The native response is a Bloks action bundle whose state entries look like
//   <id> | gs | THREADS_ABOUT_THIS_PROFILE:<name> | p | <value>
// Collect name -> value; a value that is really the next entry's id (followed by "gs") is absent.
static NSDictionary<NSString *, NSString *> *TPStateValues(NSArray<NSString *> *strings) {
    static NSString *const prefix = @"THREADS_ABOUT_THIS_PROFILE:";
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < strings.count; i++) {
        NSString *k = strings[i];
        if (![k hasPrefix:prefix]) continue;
        NSString *name = [k substringFromIndex:prefix.length];
        NSUInteger j = i + 1;
        if (j < strings.count && [strings[j] isEqualToString:@"p"]) j++;
        if (j >= strings.count) continue;
        NSString *v = strings[j];
        if (j + 1 < strings.count && [strings[j + 1] isEqualToString:@"gs"]) continue;
        if ([v hasPrefix:prefix]) continue;
        if ([v hasPrefix:@"␟num:"]) v = [v substringFromIndex:5];
        if (v.length && !m[name]) m[name] = v;
    }
    return m;
}

static BOOL TPLooksLikeMonth(NSString *v) {
    // A join date such as "2023年7月", "July 2023" or "2023년 7월": a plausible year that isn't part
    // of a colour (#FF000000), number or id.
    if (!v.length || v.length > 40 || [v hasPrefix:@"#"] || [v hasPrefix:@"("] || [v hasPrefix:@"http"]) return NO;
    return [v rangeOfString:@"(?<![0-9A-Za-z])(19|20)\\d{2}(?![0-9A-Za-z])" options:NSRegularExpressionSearch].length > 0;
}

static NSString *TPMonthFromTimestamp(double t) {
    if (t > 1e12) t /= 1000;
    if (t < 1.0e9 || t > 4.0e9) return nil;
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = NSLocale.currentLocale;
    f.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"yMMMM" options:0 locale:f.locale];
    return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]];
}

static NSDictionary *TPParseState(NSDictionary<NSString *, NSString *> *st) {
    NSString *location = nil, *joined = nil;
    BOOL countryHidden = [st[@"about_this_profile_country_visibility"] isEqualToString:@"0"];
    for (NSString *name in st) {
        NSString *v = st[name], *n = name.lowercaseString;
        if (countryHidden) break;
        if ([n hasSuffix:@"_visibility"] || [n containsString:@"visib"]) continue;
        if (!location && ([n hasSuffix:@"country"] || [n hasSuffix:@"location"] || [n hasSuffix:@"based_in"]) && !TPLooksLikeMonth(v)) location = v;
    }
    for (NSString *name in st) {
        NSString *v = st[name], *n = name.lowercaseString;
        if (!([n containsString:@"join"] || [n containsString:@"date"] || [n containsString:@"creat"])) continue;
        if (TPLooksLikeMonth(v)) { joined = v; break; }
        double t = v.doubleValue;
        NSString *m = TPMonthFromTimestamp(t);
        if (m) { joined = m; break; }
    }
    if (!joined) for (NSString *name in st) if (TPLooksLikeMonth(st[name])) { joined = st[name]; break; }
    if (joined) {
        NSRange dot = [joined rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"·•"]];
        if (dot.location != NSNotFound) joined = [[joined substringToIndex:dot.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    if (location.length) r[@"location"] = location;
    if (joined.length) r[@"joined"] = joined;
    return r;
}

static NSDictionary *TPParseStrings(NSArray<NSString *> *strings) {
    TPInitLabels();
    NSDictionary *st = TPStateValues(strings);
    NSDictionary *fromState = st.count ? TPParseState(st) : nil;
    NSString *location = nil, *joined = nil, *number = nil, *username = nil, *fullName = nil;
    // "Name" row: "Display Name（@handle" (the closing bracket is a separate span) or just "handle".
    for (NSUInteger i = 0; i < strings.count && !username; i++) {
        NSString *s = [strings[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![@[@"Name", @"名稱", @"名称", @"名前", @"이름"] containsObject:s]) continue;
        for (NSUInteger j = i + 1; j < strings.count && j <= i + 12; j++) {
            NSString *v = [strings[j] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSRange at = [v rangeOfString:@"@"];
            if (at.location != NSNotFound) {
                NSString *h = [v substringFromIndex:at.location + 1];
                NSRange bad = [h rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._"].invertedSet];
                if (bad.location != NSNotFound) h = [h substringToIndex:bad.location];
                if (h.length) {
                    username = h;
                    NSString *n = [[v substringToIndex:at.location] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" （("]];
                    if (n.length) fullName = n;
                }
                break;
            }
            if ([v rangeOfString:@"^[A-Za-z0-9._]{2,30}$" options:NSRegularExpressionSearch].location != NSNotFound &&
                ![v hasSuffix:@"dp"] && ![v hasSuffix:@"sp"] && ![@[@"normal", @"semibold", @"bold", @"column", @"row", @"center"] containsObject:v]) {
                username = v;
                break;
            }
        }
    }
    for (NSUInteger i = 0; i < strings.count; i++) {
        NSString *s = [strings[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        BOOL isJoined = [kJoinedLabels containsObject:s];
        BOOL isLocation = [kLocationLabels containsObject:s];
        if (!isJoined && !isLocation) continue;
        for (NSUInteger j = i + 1; j < strings.count && j <= i + 40; j++) {
            NSString *t = [strings[j] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (TPIsLabel(t)) break;
            NSString *v = TPCleanValue(t);
            if (!v) continue;
            if (isJoined && !TPLooksLikeMonth(v)) continue;
            if (isLocation && ([v hasSuffix:@"dp"] || [v hasSuffix:@"sp"] || [v hasPrefix:@"#"] || [v hasPrefix:@"("] ||
                               [@[@"column", @"row", @"visible", @"gone", @"semibold", @"normal", @"bold", @"center", @"start", @"end"] containsObject:v])) continue;
            if (isJoined && !joined) {
                NSRange dot = [v rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"·•"]];
                joined = [(dot.location != NSNotFound ? [v substringToIndex:dot.location] : v)
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (dot.location != NSNotFound)
                    number = [[v substringFromIndex:dot.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            } else if (isLocation && !location) {
                location = v;
            }
            break;
        }
    }
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    if (location) r[@"location"] = location;
    if (joined) r[@"joined"] = joined;
    if (number.length && number.length <= 24) r[@"number"] = number;
    if (username.length) r[@"u"] = username;
    if (fullName.length && fullName.length <= 60) r[@"n"] = fullName;
    if (fromState[@"location"]) r[@"location"] = fromState[@"location"];
    if (!r[@"joined"] && fromState[@"joined"]) r[@"joined"] = fromState[@"joined"];
    if ([st[@"about_this_profile_country_visibility"] isEqualToString:@"0"] ||
        [@[@"未分享", @"Not shared", @"未分享地點", @"共有されていません", @"공유되지 않음"] containsObject:r[@"location"] ?: @""]) {
        [r removeObjectForKey:@"location"];
        r[@"hidden"] = @YES;
    }
    return r;
}

static BOOL TPLooksRateLimited(NSArray<NSString *> *strings, BOOL success) {
    for (NSString *s in strings) {
        NSString *l = s.lowercaseString;
        if ([l containsString:@"feedback_required"] || [l containsString:@"rate limit"] || [l containsString:@"ratelimit"] ||
            [l containsString:@"too many requests"] || [l containsString:@"please wait a few minutes"]) return YES;
        if (success) continue;
        if ([l containsString:@"spam"] || [l containsString:@"try again later"] || [l containsString:@"checkpoint"] ||
            ([l hasPrefix:@"nserror "] && [l hasSuffix:@" 429"])) return YES;
    }
    return NO;
}

#pragma mark - Queue

+ (void)requestPk:(NSString *)pk {
    if (!pk.length || ![self enabled]) return;
    TPLoadCache();
    if ([self infoForPk:pk] || [gPending containsObject:pk] || [pk isEqualToString:gInFlightPk]) return;
    if ([self pausedRemaining] > 0 || gParserGaveUp || gSessionCount >= kSessionMax) return;
    [gQueue addObject:pk];
    [gPending addObject:pk];
    while (gQueue.count > kQueueMax) { [gPending removeObject:gQueue.firstObject]; [gQueue removeObjectAtIndex:0]; }
    [self pump];
}

static void TPPauseForRateLimit(NSString *why) {
    NSTimeInterval until = [NSDate date].timeIntervalSince1970 + kCooldown;
    [[TPPrefs defaults] setDouble:until forKey:kPausedKey];
    [gQueue removeAllObjects];
    [gPending removeAllObjects];
    [TPAuthorInfo log:[@"PAUSED 1h: " stringByAppendingString:why ?: @"?"]];
    [TPHUD toast:TPL(@"Threads asked to slow down. Author info paused for 1 hour.")];
}

static NSDictionary *TPParams(NSString *pk, NSInteger variant) {
    NSDictionary *inner = @{ @"target_user_id": pk,
                             @"referer_type": @"TextPostAppProfileOverflow",
                             @"atpTriggerSessionID": NSUUID.UUID.UUIDString.lowercaseString };
    if (variant == 0) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:inner options:0 error:nil];
        return @{ @"params": [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] };
    }
    return inner;
}

// The built object set failed (no response or an error, often a bad connection). Try again a few
// times with growing pauses before falling back to asking for "About this profile".
static void TPSyntheticRetryOrGiveUp(void) {
    static const NSTimeInterval waits[] = { 30, 60, 120 };
    if (gSyntheticRetries >= 3) { gSyntheticFailed = YES; return; }
    NSTimeInterval w = waits[gSyntheticRetries++];
    gSyntheticFailed = YES;   // hold off until the retry
    [TPAuthorInfo log:[NSString stringWithFormat:@"built objectSet: retrying in %.0fs", w]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(w * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gObjectSet) return;
        gSyntheticFailed = NO;
        [TPAuthorInfo pump];
    });
}

// Asks the user to open "About this profile" once. An alert rather than a toast, so it can't be
// missed; at most once a day.
static void TPShowSeedHint(void) {
    NSUserDefaults *d = [TPPrefs defaults];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - [d doubleForKey:@"tp_author_hint_at"] < 86400) return;
    UIViewController *top = [TPDownloader topViewController];
    if (!top || top.presentedViewController || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        gHintShown = NO;   // try again on a later pump
        return;
    }
    [d setDouble:now forKey:@"tp_author_hint_at"];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:TPL(@"Author Info")
        message:TPL(@"Open anyone's \"About this profile\" once to start showing author info.")
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Close") style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:a animated:YES completion:nil];
}

static void TPSyntheticTimedOut(void) {
    if (!(gSyntheticSet && !gObjectSet)) return;
    [[TPPrefs defaults] removeObjectForKey:kSynthPending];
    [[TPPrefs defaults] setObject:@"timeout" forKey:@"tp_author_synth_last"];
    gSyntheticSet = nil;
    [TPAuthorInfo log:@"built objectSet: no response"];
    TPSyntheticRetryOrGiveUp();
}

static void TPRequeueVisible(void);

static void TPFinish(NSUInteger token) {
    if (token != gToken || !gInFlight) return;
    gInFlight = NO;
    gInFlightPk = nil;
    if (!gQueue.count) TPRequeueVisible();
    [TPAuthorInfo pump];
}

// Runs on the callback thread: validate and retain whatever the fetcher handed us right away.
static NSArray *TPCollectArgs(void *a, void *b, void *c, NSString **shapeOut) {
    NSMutableArray *objs = [NSMutableArray array];
    NSMutableString *shape = [NSMutableString string];
    void *args[3] = { a, b, c };
    for (int i = 0; i < 3; i++) {
        id o = TPAsObject(args[i]);
        [shape appendFormat:@"%@%@", i ? @", " : @"", o ? NSStringFromClass([o class]) : (args[i] ? @"<raw>" : @"nil")];
        if (o) [objs addObject:o];
    }
    *shapeOut = shape;
    return objs;
}

static void TPHandleResult(NSUInteger token, NSString *pk, NSInteger variant, BOOL success, NSArray *objs, NSString *shape) {
    if (token != gToken || !gInFlight) return;
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    NSMutableSet *visited = [NSMutableSet set];
    int budget = 6000;
    for (id o in objs) TPHarvestStrings(o, 0, visited, strings, &budget);
    if (strings.count < 3) {
        for (id o in objs) {
            NSString *d = nil;
            @try { d = [o description]; } @catch (__unused NSException *e) {}
            if (d.length) [strings addObject:d];
        }
    }
    [TPAuthorInfo log:[NSString stringWithFormat:@"%@ pk=%@ v%ld args(%@) strings=%lu", success ? @"OK" : @"ERR", pk, (long)variant, shape, (unsigned long)strings.count]];

    if (TPLooksRateLimited(strings, success)) {
        TPPauseForRateLimit([strings componentsJoinedByString:@" | "].length > 160
                            ? [[strings componentsJoinedByString:@" | "] substringToIndex:160]
                            : [strings componentsJoinedByString:@" | "]);
        TPFinish(token);
        return;
    }

    NSString *joinedAll = [strings componentsJoinedByString:@" | "];
    BOOL usedSynthetic = gSyntheticSet && !gObjectSet;
    if (usedSynthetic) [[TPPrefs defaults] removeObjectForKey:kSynthPending];
    if (usedSynthetic && success) {
        static BOOL logged;
        if (!logged) { logged = YES; [TPAuthorInfo log:[NSString stringWithFormat:@"  built objectSet works (subtype %ld)", (long)gSyntheticSubtype]]; }
        gObjectSet = gSyntheticSet;
        gObjectSetSource = @"Built";
        [[TPPrefs defaults] setObject:[NSString stringWithFormat:@"ok (subtype %ld)", (long)gSyntheticSubtype] forKey:@"tp_author_synth_last"];
        [[TPPrefs defaults] setBool:YES forKey:@"tp_author_synth_worked"];
    } else if (usedSynthetic) {
        [[TPPrefs defaults] setObject:@"error" forKey:@"tp_author_synth_last"];
        [TPAuthorInfo log:[@"  built objectSet failed: " stringByAppendingString:joinedAll.length > 200 ? [joinedAll substringToIndex:200] : joinedAll]];
        gSyntheticSet = nil;
        if (gSyntheticSubtype < 2 && [joinedAll.lowercaseString containsString:@"no session context"]) gSyntheticSubtype++;
        else TPSyntheticRetryOrGiveUp();
        [gQueue addObject:pk];
        [gPending addObject:pk];
        gInFlight = NO;
        gInFlightPk = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [TPAuthorInfo pump]; });
        return;
    }
    if (!success && [joinedAll.lowercaseString containsString:@"no session context"]) {
        [TPAuthorInfo log:@"  objectSet has no session; waiting for another"];
        if (!gBadObjectSets) gBadObjectSets = [NSHashTable weakObjectsHashTable];
        if (gObjectSet) [gBadObjectSets addObject:gObjectSet];
        gObjectSet = nil;
        gObjectSetSource = nil;
        [gQueue addObject:pk];
        [gPending addObject:pk];
        gInFlight = NO;
        gInFlightPk = nil;
        return; // noteObjectSet: pumps again
    }

    NSDictionary *st = success ? TPStateValues(strings) : nil;
    if (st.count) {
        NSMutableArray *kv = [NSMutableArray array];
        for (NSString *k in [st.allKeys sortedArrayUsingSelector:@selector(compare:)]) [kv addObject:[NSString stringWithFormat:@"%@=%@", k, st[k]]];
        [TPAuthorInfo log:[@"  state: " stringByAppendingString:[kv componentsJoinedByString:@", "]]];
    }
    NSDictionary *info = success ? TPParseStrings(strings) : nil;
    if (info.count) {
        gEmptyStreak = 0;
        gSuccessCount++;
        [[TPPrefs defaults] setInteger:variant forKey:kVariantKey];
        [TPAuthorInfo log:[NSString stringWithFormat:@"  -> %@ / %@ / %@", info[@"location"] ?: @"-", info[@"joined"] ?: @"-", info[@"number"] ?: @"-"]];
        TPStore(pk, info[@"location"], info[@"joined"], info[@"number"], [info[@"hidden"] boolValue], NO, info);
    } else {
        gEmptyStreak++;
        NSString *sample = [strings componentsJoinedByString:@" | "];
        if (sample.length > 600) sample = [sample substringToIndex:600];
        [TPAuthorInfo log:[@"  strings: " stringByAppendingString:sample]];
        TPStore(pk, nil, nil, nil, NO, !success, nil);
        if (!success && !gSuccessCount && gEmptyStreak >= 6) {
            gParserGaveUp = YES;
            [gQueue removeAllObjects];
            [gPending removeAllObjects];
            [TPAuthorInfo log:@"no usable responses; stopped for this launch"];
        }
    }
    TPFinish(token);
}

+ (void)pump {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self pump]; }); return; }
    if (gInFlight || !gQueue.count || ![self enabled]) return;
    if ([self pausedRemaining] > 0 || gParserGaveUp || gSessionCount >= kSessionMax) {
        [gQueue removeAllObjects]; [gPending removeAllObjects];
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastRequest < kDelay) {
        if (gPumpScheduled) return;
        gPumpScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kDelay - (now - gLastRequest) + 0.05) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            gPumpScheduled = NO;
            [self pump];
        });
        return;
    }

    id os = gObjectSet;
    if (!os && !gSyntheticFailed && gUserSession && gPandoService && ![[TPPrefs defaults] boolForKey:kSynthDisabled]) {
        if (gSyntheticSubtype < 0) gSyntheticSubtype = 0;
        if (!gSyntheticSet) gSyntheticSet = TPBuildObjectSet(gSyntheticSubtype);
        os = gSyntheticSet;
        if (os) {
            [[TPPrefs defaults] setBool:YES forKey:kSynthPending];
            [[TPPrefs defaults] synchronize];
            [self log:[NSString stringWithFormat:@"trying built objectSet (subtype %ld)", (long)gSyntheticSubtype]];
        } else {
            gSyntheticFailed = YES;
            [self log:@"could not build objectSet"];
        }
    }
    if (!os) {
        static BOOL logged;
        if (!logged) { logged = YES; [self log:gUserSession ? @"waiting: no objectSet captured yet" : @"waiting: no objectSet, no user session"]; }
        BOOL gaveUp = (gSyntheticFailed && gSyntheticRetries >= 3) || [[TPPrefs defaults] boolForKey:kSynthDisabled];
        if (!gHintShown && gaveUp) {
            gHintShown = YES;
            TPShowSeedHint();
        }
        return; // noteObjectSet: pumps again
    }

    Class F = objc_getClass("BKSharedAsyncActionDataFetcher");
    SEL sel = NSSelectorFromString(@"fetchWithObjectSet:appID:params:timeoutOverride:successHandler:errorHandler:callbackQueue:");
    if (!F || ![F respondsToSelector:sel]) {
        static BOOL logged;
        if (!logged) { logged = YES; [self log:@"BKSharedAsyncActionDataFetcher not available"]; }
        gParserGaveUp = YES;
        return;
    }

    // On screen first, newest first; otherwise the nearest author just below the screen (read
    // ahead, so it is usually ready by the time it scrolls in). Authors that scrolled away are
    // dropped without spending a request; they are queued again if they come back.
    NSString *pk = nil;
    CGFloat best = CGFLOAT_MAX;
    for (NSString *q in [gQueue copy]) {
        CGFloat dist = [self infoForPk:q] ? -1 : TPPkDistance(q);
        if (dist < 0) { [gQueue removeObject:q]; [gPending removeObject:q]; continue; }
        if (dist < best || (dist == best && dist == 0)) { best = dist; pk = q; }   // later = newer wins ties on screen
    }
    if (!pk) return;
    if (best > 0) [self log:[NSString stringWithFormat:@"read ahead pk=%@ (%.0fpt below)", pk, best]];
    [gQueue removeObject:pk];
    [gPending removeObject:pk];

    gInFlight = YES;
    gInFlightPk = pk;
    gLastRequest = now;
    NSUInteger token = ++gToken;
    NSInteger variant = [[TPPrefs defaults] integerForKey:kVariantKey];
    gSessionCount++;
    NSDictionary *params = TPParams(pk, variant);

    void (^ok)(void *, void *, void *) = ^(void *a, void *b, void *c) {
        NSString *shape = nil;
        NSArray *objs = TPCollectArgs(a, b, c, &shape);
        dispatch_async(dispatch_get_main_queue(), ^{ TPHandleResult(token, pk, variant, YES, objs, shape); });
    };
    void (^fail)(void *, void *, void *) = ^(void *a, void *b, void *c) {
        NSString *shape = nil;
        NSArray *objs = TPCollectArgs(a, b, c, &shape);
        dispatch_async(dispatch_get_main_queue(), ^{ TPHandleResult(token, pk, variant, NO, objs, shape); });
    };

    @try {
        gSelfCall = YES;
        ((void (*)(id, SEL, id, id, id, id, id, id, id))objc_msgSend)(F, sel, os, kAppID, params, nil, ok, fail, dispatch_get_main_queue());
        gSelfCall = NO;
    } @catch (NSException *e) {
        gSelfCall = NO;
        [self log:[@"fetch threw: " stringByAppendingString:e.reason ?: @"?"]];
        gInFlight = NO; gInFlightPk = nil;
        gParserGaveUp = YES;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token == gToken && gInFlight) {
            TPSyntheticTimedOut();
            [self log:[@"timeout pk=" stringByAppendingString:pk]];
            TPStore(pk, nil, nil, nil, NO, YES, nil);
            TPFinish(token);
        }
    });
}

#pragma mark - Swift String reading

// Reads a Swift `String?` stored inline in an object (two words). Handles small, native and
// bridged representations; anything else returns nil.
static NSString *TPSwiftString(const void *base) {
    uint64_t w0 = ((const uint64_t *)base)[0], w1 = ((const uint64_t *)base)[1];
    if (!w0 && !w1) return nil;
    uint8_t disc = (uint8_t)(w1 >> 56);
    if (disc & 0x20) {
        NSUInteger n = disc & 0x0F;
        if (!n || n > 15) return nil;
        char buf[16];
        memcpy(buf, &w0, 8);
        memcpy(buf + 8, &w1, 7);
        return [[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding];
    }
    uintptr_t obj = (uintptr_t)(w1 & 0x0FFFFFFFFFFFFFFFULL);
    if (obj < 0x100000000ULL) return nil;
    if (disc & 0x40) { // bridged NSString
        id o = TPAsObject((void *)obj);
        return [o isKindOfClass:[NSString class]] ? [o copy] : nil;
    }
    uint64_t count = w0 & 0x0000FFFFFFFFFFFFULL;
    if (!count || count > 64) return nil;
    if (!(disc & 0x80) && malloc_size((void *)obj) == 0) return nil; // native heap storage
    return [[NSString alloc] initWithBytes:(const void *)(obj + 32) length:(NSUInteger)count encoding:NSUTF8StringEncoding];
}

static BOOL TPIsDigits(NSString *s) {
    if (!s.length || s.length > 24) return NO;
    return [s rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
}

// Swift ivars of struct/enum/optional type have no type encoding; their raw bits aren't an
// object. Read an ivar as an object only when it is one (see TPDownloader's ivarValue).
static id TPCheckedIvarAI(id obj, Ivar iv) {
    if (!obj || !iv) return nil;
    const char *enc = ivar_getTypeEncoding(iv);
    if (enc && enc[0] == '@') return object_getIvar(obj, iv);
    if (enc && enc[0]) return nil;
    void *p = *(void **)((uint8_t *)(__bridge void *)obj + ivar_getOffset(iv));
    uintptr_t v = (uintptr_t)p;
    if (!v) return nil;
    if ((intptr_t)v < 0) return object_getClass((__bridge id)p) ? (__bridge id)p : nil;
    if (v < 0x100000000ULL || (v & 7) || malloc_size(p) < 16) return nil;
    return (__bridge id)p;
}

static id TPIvarObject(id obj, const char *name) {
    if (!obj) return nil;
    return TPCheckedIvarAI(obj, class_getInstanceVariable(object_getClass(obj), name));
}

static NSString *TPHeaderPk(UIView *contentView) {
    id pic = TPIvarObject(contentView, "profilePictureView");
    if (!pic) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(pic), "userPk");
    if (!iv) return nil;
    NSString *pk = TPSwiftString((const char *)(__bridge void *)pic + ivar_getOffset(iv));
    return TPIsDigits(pk) ? pk : nil;
}

#pragma mark - Badge

// The header's title is the author's handle. Some About-this-profile layouts have no Name row, so
// the handle seen here fills the gap (Location Stats needs it to open the profile).
static NSString *TPTitleText(UIView *v, int depth) {
    if (!v || depth > 4) return nil;
    if ([v isKindOfClass:[UILabel class]]) return ((UILabel *)v).attributedText.string ?: ((UILabel *)v).text;
    if ([v respondsToSelector:@selector(attributedText)]) {
        id t = [(id)v attributedText];
        if ([t isKindOfClass:[NSAttributedString class]]) return [t string];
    }
    for (UIView *s in v.subviews) { NSString *t = TPTitleText(s, depth + 1); if (t.length) return t; }
    return nil;
}

static void TPNoteHeaderName(NSString *pk, UIView *title) {
    if (!pk.length) return;
    NSString *t = [TPTitleText(title, 0) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // The title can carry a verified mark or other trailing text; keep the leading handle.
    NSRange r = [t ?: @"" rangeOfString:@"^[A-Za-z0-9._]{1,30}" options:NSRegularExpressionSearch];
    if (r.location == NSNotFound) return;
    NSString *u = [t substringWithRange:r];
    if (!gHeaderNames) gHeaderNames = [NSMutableDictionary dictionary];
    if ([gHeaderNames[pk] isEqualToString:u]) return;
    gHeaderNames[pk] = u;
    NSDictionary *e = gCache[pk];
    if (e && ![e[@"u"] length]) {
        NSMutableDictionary *m = [e mutableCopy];
        m[@"u"] = u;
        gCache[pk] = m;
        TPSaveCacheSoon();
    }
}

static const void *kBadgeKey = &kBadgeKey;
static NSHashTable *gBadges;

// Headers that scrolled in while the queue was full were dropped; once it drains, pick up
// whatever is still on screen without info.
// 0 when the author's header is on screen (with a small margin), how far below the screen it is
// when it's within the next screen (read ahead), or -1 when it's elsewhere (scrolled away).
static CGFloat TPPkDistance(NSString *pk) {
    BOOL known = NO;
    CGFloat best = -1;
    for (TPAuthorBadgeLabel *b in gBadges.allObjects) {
        if (![b.pk isEqualToString:pk]) continue;
        known = YES;
        UIView *host = b.host;
        UIWindow *w = host.window;
        if (!w || host.hidden) continue;
        CGRect r = [host convertRect:host.bounds toView:w];
        CGFloat h = w.bounds.size.height;
        if (CGRectIntersectsRect(CGRectInset(w.bounds, 0, -120), r)) return 0;
        CGFloat below = CGRectGetMinY(r) - h;
        if (below > 0 && below <= h && (best < 0 || below < best)) best = below;
    }
    return known ? best : 0;   // not from a feed header we track: don't second-guess it
}

static void TPRequeueVisible(void) {
    for (TPAuthorBadgeLabel *b in gBadges.allObjects) {
        UIView *host = b.host;
        if (b.pk.length && host.window && ![TPAuthorInfo infoForPk:b.pk]) [TPAuthorInfo requestPk:b.pk];
    }
}

// "台灣" / "Australia" / "澳大利亞" -> 🇹🇼 / 🇦🇺. Names come from Threads in the app's language, so
// they are matched against several locales' country names plus a few known spellings.
static NSString *TPFlagForCountry(NSString *name) {
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        NSArray *locales = @[@"zh_TW", @"zh_HK", @"zh_MO", @"zh_Hant", @"zh_Hans_CN", @"zh_Hans_SG", @"en_US", @"en_GB",
                             @"ja_JP", @"ko_KR", NSLocale.currentLocale.localeIdentifier];
        for (NSString *lid in locales) {
            NSLocale *loc = [NSLocale localeWithLocaleIdentifier:lid];
            for (NSString *cc in NSLocale.ISOCountryCodes) {
                NSString *n = [loc localizedStringForCountryCode:cc];
                if (n.length && !m[n]) m[n] = cc;
            }
        }
        NSDictionary *extra = @{ @"澳大利亞": @"AU", @"澳大利亚": @"AU", @"台灣": @"TW", @"臺灣": @"TW", @"台湾": @"TW",
                                 @"南韓": @"KR", @"韓國": @"KR", @"北韓": @"KP", @"中國": @"CN", @"中國大陸": @"CN",
                                 @"香港": @"HK", @"澳門": @"MO", @"紐西蘭": @"NZ", @"新西蘭": @"NZ", @"英國": @"GB",
                                 @"美國": @"US", @"阿拉伯聯合大公國": @"AE", @"Taiwan": @"TW", @"South Korea": @"KR",
                                 @"United States": @"US", @"United Kingdom": @"GB", @"Hong Kong": @"HK", @"Macau": @"MO" };
        [m addEntriesFromDictionary:extra];
        map = m;
    });
    NSString *key = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *cc = map[key];
    if (!cc) {
        for (NSString *suffix in @[@"特別行政區", @"特别行政区", @"SAR China", @"S.A.R."]) {
            NSRange r = [key rangeOfString:suffix];
            if (r.location != NSNotFound) { cc = map[[[key stringByReplacingCharactersInRange:r withString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]]; if (cc) break; }
        }
    }
    if (cc.length != 2) return nil;
    NSMutableString *flag = [NSMutableString string];
    for (NSUInteger i = 0; i < 2; i++) {
        unichar c = [cc.uppercaseString characterAtIndex:i];
        if (c < 'A' || c > 'Z') return nil;
        uint32_t scalar = 0x1F1E6 + (c - 'A');
        uint32_t le = NSSwapHostIntToLittle(scalar);
        [flag appendString:[[NSString alloc] initWithBytes:&le length:4 encoding:NSUTF32LittleEndianStringEncoding]];
    }
    return flag;
}

static NSAttributedString *TPSpacer(CGFloat w) {
    NSTextAttachment *a = [NSTextAttachment new];
    a.image = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(MAX(w, 1), 1)] imageWithActions:^(UIGraphicsImageRendererContext *c) {}];
    a.bounds = CGRectMake(0, 0, w, 1);
    return [NSAttributedString attributedStringWithAttachment:a];
}

// Style: [NEW]  ( 🇹🇼 台灣 | 2023年7月 | #5,012,861 )  — one outlined capsule with hairline dividers.
// level 0 full, 1 drops the country name (when there's a flag) and the join number, 2 keeps only the flag.
// *prefixWidth receives the width of the NEW tag part, so the outline can start after it.
static NSAttributedString *TPBadgeText(NSDictionary *info, UIFont *font, UIColor *color, int level, CGFloat *prefixWidth) {
    BOOL showLoc = [TPPrefs boolForKey:TPKeyAuthorLocation];
    BOOL showJoin = [TPPrefs boolForKey:TPKeyAuthorJoined] && level < 2;
    BOOL showNew = [TPPrefs boolForKey:TPKeyAuthorNewBadge];
    BOOL showNumber = [TPPrefs boolForKey:TPKeyAuthorJoinNumber] && level == 0;
    NSString *loc = info[@"location"], *joined = info[@"joined"], *number = info[@"number"];
    BOOL hidden = [info[@"hidden"] boolValue];
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: color };
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:font.pointSize - 1 weight:UIImageSymbolWeightMedium];

    NSMutableAttributedString *prefix = [NSMutableAttributedString new];
    void (^pill)(NSString *, UIColor *, UIColor *) = ^(NSString *label, UIColor *fill, UIColor *ink) {
        UIFont *bold = [UIFont systemFontOfSize:font.pointSize - 1 weight:UIFontWeightBold];
        CGSize ts = [label sizeWithAttributes:@{ NSFontAttributeName: bold }];
        CGSize ps = CGSizeMake(ceil(ts.width) + 10, ceil(font.lineHeight) + 2);
        UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithSize:ps] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [fill setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, ps.width, ps.height) cornerRadius:ps.height / 2] fill];
            [label drawAtPoint:CGPointMake((ps.width - ts.width) / 2, (ps.height - ts.height) / 2)
                withAttributes:@{ NSFontAttributeName: bold, NSForegroundColorAttributeName: ink }];
        }];
        NSTextAttachment *a = [NSTextAttachment new];
        a.image = img;
        a.bounds = CGRectMake(0, (font.capHeight - ps.height) / 2, ps.width, ps.height);
        if (prefix.length) [prefix appendAttributedString:TPSpacer(4)];
        [prefix appendAttributedString:[NSAttributedString attributedStringWithAttachment:a]];
    };
    if (showNew && [TPAuthorInfo isNewAccount:joined]) pill(TPL(@"NEW"), [TPUI accent], UIColor.whiteColor);
    if ([TPPrefs boolForKey:TPKeyAuthorDefaultName] && [TPAuthorInfo isDefaultUsername:info[@"u"]]) {
        // Rendered into an image, so resolve the dynamic colours for the current appearance now.
        UITraitCollection *tc = UIScreen.mainScreen.traitCollection;
        pill(TPL(@"Default Name"), [UIColor.tertiarySystemFillColor resolvedColorWithTraitCollection:tc],
             [UIColor.secondaryLabelColor resolvedColorWithTraitCollection:tc]);
    }

    NSMutableArray<NSAttributedString *> *items = [NSMutableArray array];
    if (showLoc && (loc.length || hidden)) {
        NSMutableAttributedString *it = [NSMutableAttributedString new];
        // A hidden location gets the colour globe emoji, like the flags (and the Location Stats page).
        NSString *flag = loc.length ? TPFlagForCountry(loc) : @"🌐";
        if (flag) {
            [it appendAttributedString:[[NSAttributedString alloc] initWithString:flag attributes:attrs]];
        } else {
            UIImage *img = [[UIImage systemImageNamed:(loc.length ? @"mappin" : @"globe") withConfiguration:cfg]
                            imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
            if (img) {
                NSTextAttachment *a = [NSTextAttachment new];
                a.image = img;
                a.bounds = CGRectMake(0, (font.capHeight - img.size.height) / 2, img.size.width, img.size.height);
                [it appendAttributedString:[NSAttributedString attributedStringWithAttachment:a]];
            }
        }
        // Without a flag the name is the only way to tell the country, so it stays even when compact.
        NSString *name = loc.length ? loc : TPL(@"Not shared");
        if (level == 0 || (loc.length && !TPFlagForCountry(loc))) {
            [it appendAttributedString:TPSpacer(4)];
            [it appendAttributedString:[[NSAttributedString alloc] initWithString:name attributes:attrs]];
        }
        [items addObject:it];
    }
    if (showJoin && joined.length) {
        [items addObject:[[NSAttributedString alloc] initWithString:joined attributes:attrs]];
        if (showNumber && number.length) [items addObject:[[NSAttributedString alloc] initWithString:number attributes:attrs]];
    }

    NSMutableAttributedString *s = [prefix mutableCopy];
    CGFloat pw = 0;
    if (items.count) {
        if (prefix.length) [s appendAttributedString:TPSpacer(5)];
        pw = ceil([s boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, 40) options:0 context:nil].size.width);
        if (!prefix.length) pw = 0;
        [s appendAttributedString:TPSpacer(7)];
        UIImage *line = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1, ceil(font.capHeight) + 2)] imageWithActions:^(UIGraphicsImageRendererContext *c) {
            [[color colorWithAlphaComponent:0.45] setFill];
            UIRectFill(CGRectMake(0, 0, 1, ceil(font.capHeight) + 2));
        }];
        for (NSUInteger i = 0; i < items.count; i++) {
            if (i) {
                [s appendAttributedString:TPSpacer(6)];
                NSTextAttachment *d = [NSTextAttachment new];
                d.image = line;
                d.bounds = CGRectMake(0, -1, 0.5, line.size.height);
                [s appendAttributedString:[NSAttributedString attributedStringWithAttachment:d]];
                [s appendAttributedString:TPSpacer(6)];
            }
            [s appendAttributedString:items[i]];
        }
        [s appendAttributedString:TPSpacer(7)];
    }
    if (prefixWidth) *prefixWidth = items.count ? pw : -1;
    // The flag emoji's font has a taller line than the 12 pt text, which pushed the baseline down
    // inside the capsule. Pin the line to the text font so the label centres it evenly.
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.minimumLineHeight = ps.maximumLineHeight = ceil(font.lineHeight);
    ps.lineBreakMode = NSLineBreakByClipping;
    [s addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, s.length)];
    return s;
}

+ (CGFloat)extraHeaderHeight {
    if (![self enabled] || ![TPPrefs boolForKey:TPKeyAuthorOwnLine]) return 0;
    return ceil([UIFont systemFontOfSize:12].lineHeight) + 12;
}

static Ivar TPFindIvar(id obj, const char *name) {
    for (Class c = obj ? object_getClass(obj) : Nil; c; c = class_getSuperclass(c)) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) return iv;
    }
    return NULL;
}

static id TPIvarDeep(id obj, const char *name) {
    Ivar iv = TPFindIvar(obj, name);
    return TPCheckedIvarAI(obj, iv);
}

static NSString *TPUsernameOf(id user) {
    if (!user || ![user respondsToSelector:@selector(username)]) return nil;
    id u = nil;
    @try { u = [user valueForKey:@"username"]; } @catch (__unused id e) {}
    return [u isKindOfClass:[NSString class]] && [u length] ? u : nil;
}

// Author and post of a feed post header, from its model (the title is drawn text, not readable):
// author from the profile picture's user or the header's user fragment, post from its media.
+ (NSDictionary *)postInfoInHeader:(UIView *)contentView {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    id pic = TPIvarDeep(contentView, "profilePictureView");
    id image = TPIvarDeep(pic, "image");
    NSString *author = TPUsernameOf(TPIvarDeep(image, "_profileImageModel_user"));
    if (author) out[@"via"] = @"picture";
    id vm = TPIvarDeep(contentView, "viewModel");
    if (!author) { author = TPUsernameOf(TPIvarDeep(vm, "userFragment")); if (author) out[@"via"] = @"user"; }
    if (!author) {
        UIView *title = TPIvarObject(contentView, "titleLabel");
        id tv = TPIvarDeep(title, "textView");
        id styled = [tv respondsToSelector:@selector(styledString)] ? [tv valueForKey:@"styledString"] : nil;
        NSAttributedString *as = [styled respondsToSelector:@selector(attributedString)] ? [styled valueForKey:@"attributedString"] : nil;
        NSString *t = [as isKindOfClass:[NSAttributedString class]] ? as.string : TPTitleText(title, 0);
        NSRange r = [t ?: @"" rangeOfString:@"^[A-Za-z0-9._]{1,30}" options:NSRegularExpressionSearch];
        if (r.location != NSNotFound) { author = [t substringWithRange:r]; out[@"via"] = @"title"; }
    }
    if (!author) {
        NSString *pk = TPHeaderPk(contentView);
        author = pk ? (gCache[pk][@"u"] ?: gHeaderNames[pk]) : nil;
        if (author) out[@"via"] = @"cache";
    }
    if (author.length) out[@"author"] = author;

    id media = TPIvarDeep(vm, "mediaFragment");
    id code = nil;
    if ([media respondsToSelector:@selector(code)]) { @try { code = [media valueForKey:@"code"]; } @catch (__unused id e) {} }
    if ([code isKindOfClass:[NSString class]] && [code length]) out[@"code"] = code;
    for (NSString *k in @[@"pk", @"id", @"mediaID"]) {
        if (out[@"mediaId"] || ![media respondsToSelector:NSSelectorFromString(k)]) continue;
        id v = nil;
        @try { v = [media valueForKey:k]; } @catch (__unused id e) {}
        if ([v isKindOfClass:[NSString class]] && [v length]) out[@"mediaId"] = v;
    }
    if (!out[@"mediaId"] && vm) {
        Ivar iv = TPFindIvar(vm, "mediaIdForLogging");
        NSString *mid = iv ? TPSwiftString((const char *)(__bridge void *)vm + ivar_getOffset(iv)) : nil;
        if (mid.length) out[@"mediaId"] = mid;
    }
    return out;
}

static NSString *TPShortcodeFromMediaPK(NSString *pk) {
    if (!pk.length) return nil;
    pk = [[pk componentsSeparatedByString:@"_"] firstObject];
    unsigned long long n = strtoull(pk.UTF8String, NULL, 10);
    if (!n) return nil;
    static const char *alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    NSMutableString *s = [NSMutableString string];
    while (n) { [s insertString:[NSString stringWithFormat:@"%c", alpha[n % 64]] atIndex:0]; n /= 64; }
    return s;
}

static void TPNotePostAuthorFromHeader(UIView *contentView) {
    if (!contentView) return;
    NSDictionary *info = [TPAuthorInfo postInfoInHeader:contentView];
    NSString *author = info[@"author"];
    if (!author.length) return;
    NSString *code = info[@"code"];
    NSString *sc = [info[@"mediaId"] length] ? TPShortcodeFromMediaPK(info[@"mediaId"]) : nil;
    if (!code.length && !sc.length) return;
    if (!gPostAuthors) gPostAuthors = [NSMutableDictionary dictionary];
    if (gPostAuthors.count >= 2000) [gPostAuthors removeAllObjects];
    if (code.length) gPostAuthors[code] = author;
    if (sc.length) gPostAuthors[sc] = author;
}

+ (NSString *)authorForPostCode:(NSString *)code {
    return code.length ? gPostAuthors[code] : nil;
}

+ (NSString *)locationForUsername:(NSString *)username {
    if (!username.length) return nil;
    TPLoadCache();
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    __block NSString *loc = nil;
    [gCache enumerateKeysAndObjectsUsingBlock:^(NSString *pk, NSDictionary *e, BOOL *stop) {
        if ([e[@"x"] doubleValue] < now || ![e[@"u"] isEqualToString:username]) return;
        if ([e[@"location"] isKindOfClass:[NSString class]] && [e[@"location"] length]) { loc = e[@"location"]; *stop = YES; }
    }];
    return loc;
}

+ (NSString *)usernameForPk:(NSString *)pk {
    if (!pk.length) return nil;
    NSString *u = gCache[pk][@"u"] ?: gHeaderNames[pk];
    return u.length ? u : nil;
}

+ (NSString *)pkForHeader:(UIView *)contentView {
    return contentView ? TPHeaderPk(contentView) : nil;
}

+ (BOOL)isNewAccountForPk:(NSString *)pk {
    if (!pk.length) return NO;
    NSString *joined = gCache[pk][@"joined"];
    return joined.length ? [self isNewAccount:joined] : NO;
}

+ (void)layoutBadgeInHeader:(UIView *)contentView {
    TPNotePostAuthorFromHeader(contentView);
    TPAuthorBadgeLabel *badge = objc_getAssociatedObject(contentView, kBadgeKey);
    if (![self enabled]) { badge.hidden = YES; return; }

    NSString *pk = TPHeaderPk(contentView);
    UIView *title = TPIvarObject(contentView, "titleLabel");
    if (!pk || ![title isKindOfClass:[UIView class]] || title.superview == nil) { badge.hidden = YES; return; }

    if (!badge) {
        badge = [[TPAuthorBadgeLabel alloc] initWithFrame:CGRectZero];
        badge.host = contentView;
        if (!gBadges) gBadges = [NSHashTable weakObjectsHashTable];
        [gBadges addObject:badge];
        objc_setAssociatedObject(contentView, kBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (badge.superview != title.superview) [title.superview addSubview:badge];
    badge.pk = pk;
    TPNoteHeaderName(pk, title);

    NSDictionary *info = [self infoForPk:pk];
    if (!info) {
        badge.hidden = YES;
        if (contentView.window) [self requestPk:pk];
        return;
    }
    UIFont *font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    __block CGFloat prefixW = -1;
    NSAttributedString *text = TPBadgeText(info, font, UIColor.secondaryLabelColor, 0, &prefixW);
    if (!text.length) { badge.hidden = YES; return; }
    badge.attributedText = text;

    CGRect tf = title.frame;
    // Threads' text wrapper traps on a non-finite proposed size, so only ever pass the frame it
    // already laid itself out in.
    if (!(tf.size.width > 1 && tf.size.height > 1 && isfinite(tf.size.width) && isfinite(tf.size.height))) { badge.hidden = YES; return; }
    UIView *host = title.superview;
    CGFloat lineH = 22;
    CGFloat h = ceil(font.lineHeight) + 6;

    // Right edge of the free space on a line: the nearest visible sibling (edit / Threads icons,
    // ••• button) that sits on that line to the right of the name.
    CGFloat (^rightLimit)(CGFloat, CGFloat) = ^CGFloat(CGFloat top, CGFloat bottom) {
        CGFloat limit = host.bounds.size.width - 8;
        for (UIView *v in host.subviews) {
            if (v == title || v == badge || v.hidden || v.alpha < 0.05 || v.bounds.size.width < 2) continue;
            CGRect r = v.frame;
            if (CGRectGetMaxY(r) <= top || r.origin.y >= bottom) continue;
            if (r.origin.x <= tf.origin.x + 40) continue;
            limit = MIN(limit, r.origin.x - 6);
        }
        return limit;
    };

    // Most complete form that fits: full, then without the country name and icons, then flag only.
    CGFloat (^fit)(CGFloat) = ^CGFloat(CGFloat avail) {
        for (int level = 0; level < 3; level++) {
            CGFloat pw = prefixW;
            NSAttributedString *t = level ? TPBadgeText(info, font, UIColor.secondaryLabelColor, level, &pw) : text;
            if (!t.length) break;
            CGFloat w = ceil([t boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, 40) options:0 context:nil].size.width) + 1;
            if (w <= avail) { badge.attributedText = t; prefixW = pw; return w; }
        }
        return -1;
    };

    CGRect frame;
    CGFloat extra = [TPAuthorInfo extraHeaderHeight];
    if (extra > 0) {
        // Own line under the name (and the wrapped timestamp, if any).
        CGFloat y = CGRectGetMaxY(tf) + 4;
        CGFloat w = fit(host.bounds.size.width - 8 - tf.origin.x);
        if (w <= 0) { badge.hidden = YES; return; }
        frame = CGRectMake(tf.origin.x, round(y), w, h);
    } else if (tf.size.height > lineH + 8) {
        // Name and time wrapped onto two lines (e.g. full date format). The second line holds only
        // the end of the timestamp, so right-align the badge there.
        CGFloat top = tf.origin.y + lineH, bottom = CGRectGetMaxY(tf);
        CGFloat limit = rightLimit(top, bottom);
        CGFloat w = fit(limit - (tf.origin.x + 110));
        if (w <= 0) { badge.hidden = YES; return; }
        frame = CGRectMake(limit - w, round(top + (bottom - top - h) / 2), w, h);
    } else {
        CGFloat used = [title sizeThatFits:tf.size].width;
        if (!(used > 0) || !isfinite(used) || used > tf.size.width) used = tf.size.width;
        CGFloat x = tf.origin.x + used + 6;
        CGFloat limit = rightLimit(tf.origin.y, CGRectGetMaxY(tf));
        CGFloat w = fit(limit - x);
        if (w <= 0) { badge.hidden = YES; return; }
        frame = CGRectMake(x, round(tf.origin.y + (tf.size.height - h) / 2), w, h);
    }
    badge.frame = frame;
    badge.hidden = NO;

    // Outline capsule around the info (not the NEW tag).
    if (!badge.capsule) {
        badge.capsule = [CALayer layer];
        badge.capsule.borderWidth = 0.5;
        [badge.layer insertSublayer:badge.capsule atIndex:0];
    }
    badge.capsule.hidden = prefixW < 0;
    if (prefixW >= 0) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        badge.capsule.frame = CGRectMake(prefixW, 0.25, frame.size.width - prefixW - 0.5, frame.size.height - 0.5);
        badge.capsule.cornerRadius = (frame.size.height - 0.5) / 2;
        badge.capsule.borderColor = [UIColor.tertiaryLabelColor resolvedColorWithTraitCollection:badge.traitCollection].CGColor;
        [CATransaction commit];
    }
}

@end
