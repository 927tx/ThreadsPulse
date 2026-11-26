#import "TPDownloader.h"
#import <malloc/malloc.h>
#import "TPVersion.h"
#import "TPPrefs.h"
#import "TPLocalization.h"
#import <Photos/Photos.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import "vpx/vpx_decoder.h"
#import "vpx/vp8dx.h"
#import "dav1d/dav1d.h"
#import <objc/runtime.h>
#import "TPUI.h"
#import "TPHUD.h"
#import "TPCapsule.h"

#import "TPDownloadManager.h"
#import "TPAuthorInfo.h"

@interface TPDownloadJob : NSObject <NSURLSessionDownloadDelegate>
- (instancetype)initWithItems:(NSArray<NSDictionary *> *)items;
- (void)start;
- (void)dashFailed:(NSString *)why;
- (void)dashMerged:(NSURL *)file;
- (NSString *)recordID;
- (void)cancelFromManager;
- (BOOL)isDownloading;
@end

@interface TPDownloadJob (Transcode)
- (void)transcodeDash;
@end

static NSString *sPendingReport;
static NSMutableSet *sJobs;
// Downloads run one job at a time; jobs started meanwhile wait here (the progress capsule
// doesn't block the app, so several posts can be queued).
static NSMutableArray<NSArray<NSDictionary *> *> *sQueue;
static BOOL sQueuePaused;
// One video converts at a time; while it does, the next queued post may already download.
static __weak id sConvertingJob;
static NSMutableArray<void (^)(void)> *sConvertWaiters;
static void TPStartNextJob(void);

// Collects every <Representation> in an MPD with the attributes it inherits from its
// <AdaptationSet>. Threads/Instagram manifests use one <BaseURL> per Representation that points
// at a complete fragmented MP4, so no segment handling is needed.
@interface TPMPDParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *reps;
@end

@implementation TPMPDParser {
    NSDictionary *_set;
    NSMutableDictionary *_rep;
    NSMutableString *_text;
    BOOL _inBaseURL;
}
- (instancetype)init { if ((self = [super init])) _reps = [NSMutableArray array]; return self; }
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)el namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary *)a {
    NSString *name = el.lowercaseString;
    if ([name isEqualToString:@"adaptationset"]) _set = a;
    else if ([name isEqualToString:@"representation"]) {
        _rep = [NSMutableDictionary dictionary];
        for (NSString *k in @[@"contentType", @"mimeType", @"codecs"]) if (_set[k]) _rep[k] = _set[k];
        [_rep addEntriesFromDictionary:a];
    } else if ([name isEqualToString:@"baseurl"] && _rep) {
        _inBaseURL = YES;
        _text = [NSMutableString string];
    }
}
- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)str { if (_inBaseURL) [_text appendString:str]; }
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)el namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
    NSString *name = el.lowercaseString;
    if ([name isEqualToString:@"baseurl"] && _inBaseURL) {
        _inBaseURL = NO;
        NSString *t = [_text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.length) _rep[@"BaseURL"] = t;
    } else if ([name isEqualToString:@"representation"]) {
        if (_rep[@"BaseURL"]) [_reps addObject:_rep];
        _rep = nil;
    } else if ([name isEqualToString:@"adaptationset"]) {
        _set = nil;
    }
}
@end

static NSDictionary *TPDashInfoFromManifest(NSData *mpd, NSInteger progressivePixels);
static NSString *TPTranscodeTarget(NSString *codec);
static NSInteger TPProgressivePixels(id obj);

// Four-character code of the first video track ("avc1", "hvc1", "av01", "vp09"…), or nil.
static NSString *TPVideoFourCC(NSURL *file) {
    AVURLAsset *a = [AVURLAsset URLAssetWithURL:file options:nil];
    AVAssetTrack *t = [a tracksWithMediaType:AVMediaTypeVideo].firstObject;
    CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)t.formatDescriptions.firstObject;
    if (!fd) return nil;
    FourCharCode c = CMFormatDescriptionGetMediaSubType(fd);
    char s[5] = { (char)(c >> 24), (char)(c >> 16), (char)(c >> 8), (char)c, 0 };
    return [NSString stringWithUTF8String:s];
}

static BOOL TPFileHasAudio(NSURL *file) {
    return [[AVURLAsset URLAssetWithURL:file options:nil] tracksWithMediaType:AVMediaTypeAudio].count > 0;
}

@implementation TPDownloader

+ (UIViewController *)topViewController { return TPTopViewController(); }

+ (void)toast:(NSString *)text { [TPHUD toast:text]; }

static id TPSafeValue(id obj, NSString *key) {
    if (!obj) return nil;
    SEL sel = NSSelectorFromString(key);
    if ([obj respondsToSelector:sel]) {
        @try { return [obj valueForKey:key]; } @catch (__unused id e) {}
    }
    return nil;
}

static NSInteger TPInt(id v) {
    if (!v) return 0;
    if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    for (NSString *key in @[@"value", @"longLongValue", @"intValue"]) {
        if (![v respondsToSelector:NSSelectorFromString(key)]) continue;
        @try {
            id n = [v valueForKey:key];
            if ([n respondsToSelector:@selector(integerValue)]) return [n integerValue];
        } @catch (__unused id e) {}
    }
    return 0;
}

// Scores candidate video URLs; audio-only DASH tracks return -1. The efg query parameter is a
// base64 JSON tag that names the encoding (progressive, resolution, audio).
static NSInteger TPScoreURL(NSURL *u) {
    NSString *abs = u.absoluteString;
    NSString *tag = @"";
    NSURLComponents *c = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *q in c.queryItems) {
        if ([q.name isEqualToString:@"efg"] && q.value.length) {
            NSString *b64 = [[q.value stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                             stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
            while (b64.length % 4) b64 = [b64 stringByAppendingString:@"="];
            NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
            NSString *js = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
            if (js) tag = js;
        }
    }
    NSString *lower = tag.lowercaseString;
    if ([lower containsString:@"audio"] || [lower containsString:@"heaac"]) return -1;

    NSInteger score = 1;
    if ([abs.lowercaseString containsString:@".mp4"]) score += 50;
    if ([lower containsString:@"progressive"]) score += 100000;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\.(\\d{3,4})\\." options:0 error:nil];
    NSTextCheckingResult *r = [re firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
    if (r) score += [[tag substringWithRange:[r rangeAtIndex:1]] integerValue];
    return score;
}

+ (NSURL *)bestURLFromObject:(id)obj {
    if (!obj) return nil;

    NSArray *versions = TPSafeValue(obj, @"videoVersions");
    if (![versions isKindOfClass:[NSArray class]] || versions.count == 0) {
        id inner = TPSafeValue(obj, @"video");
        versions = TPSafeValue(inner, @"videoVersions");
    }

    NSURL *best = nil;
    NSInteger bestScore = -1;

    for (id ver in versions) {
        NSString *s = TPSafeValue(ver, @"urlString");
        if (![s isKindOfClass:[NSString class]] || s.length == 0) {
            id u = TPSafeValue(ver, @"url");
            if ([u isKindOfClass:[NSURL class]]) s = [(NSURL *)u absoluteString];
        }
        if (!s.length) continue;
        NSInteger w = TPInt(TPSafeValue(ver, @"width"));
        NSInteger h = TPInt(TPSafeValue(ver, @"height"));
        NSInteger score = w * h;
        if (score == 0) score = TPInt(TPSafeValue(ver, @"bandwidth"));
        if (score > bestScore) {
            NSURL *u = [NSURL URLWithString:s];
            if (u) { best = u; bestScore = score; }
        }
    }

    if (!best) {
        id all = TPSafeValue(obj, @"allVideoURLs");
        NSInteger bs = -1;
        for (id u in all) {
            if (![u isKindOfClass:[NSURL class]]) continue;
            NSInteger sc = TPScoreURL(u);
            if (sc < 0) continue;
            if (!best || sc > bs) { best = u; bs = sc; }
        }
    }
    if (!best) {
        id u = TPSafeValue(obj, @"videoURLForCurrentNetworkConditions");
        if ([u isKindOfClass:[NSURL class]]) best = u;
    }
    return best;
}

// An ivar read as an object only when it really holds one. Swift ivars of struct, enum or
// optional type have no ObjC type encoding, and object_getIvar then returns their raw bits:
// messaging those crashes (seen with the share sheet's cells). So: object ivars ("@") as is;
// untyped ones only if the bits are a heap object or a tagged pointer of a known class.
static id TPCheckedObject(void *p) {
    uintptr_t v = (uintptr_t)p;
    if (!v) return nil;
    if ((intptr_t)v < 0) return object_getClass((__bridge id)p) ? (__bridge id)p : nil;   // tagged pointer
    if (v < 0x100000000ULL || (v & 7)) return nil;
    if (malloc_size(p) < 16) return nil;
    return (__bridge id)p;
}

static id TPCheckedIvar(id obj, Ivar iv) {
    if (!obj || !iv) return nil;
    const char *enc = ivar_getTypeEncoding(iv);
    if (enc && enc[0] == '@') return object_getIvar(obj, iv);
    if (enc && enc[0]) return nil;   // a C type: not an object
    return TPCheckedObject(*(void **)((uint8_t *)(__bridge void *)obj + ivar_getOffset(iv)));
}

static id TPIvarObject(id obj, const char *name) {
    for (Class c = [obj class]; c; c = class_getSuperclass(c)) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) return TPCheckedIvar(obj, iv);
    }
    return nil;
}

static id TPResolvePlayer(UIView *view, id hint) {
    if (hint) return hint;
    return TPIvarObject(view, "videoPlayer");
}

static id TPInnerPlayer(id player) {
    id inner = TPSafeValue(player, @"videoPlayer");
    if (!inner) inner = TPIvarObject(player, "_videoPlayer");
    return inner;
}

static id TPFindProvider(id player) {
    if (!player) return nil;
    id p = TPSafeValue(player, @"video");
    if (p) return p;
    id inner = TPInnerPlayer(player);
    p = TPSafeValue(inner, @"video");
    if (p) return p;
    return TPIvarObject(player, "pendingVideoToReload");
}

+ (NSURL *)bestURLFromVideoView:(UIView *)view player:(id)hint {
    if (!view) return nil;
    id player = TPResolvePlayer(view, hint);
    NSURL *u = [self bestURLFromObject:TPFindProvider(player)];
    if (!u) u = [self bestURLFromObject:TPInnerPlayer(player)];
    if (!u) u = [self bestURLFromObject:player];
    return u;
}

static NSString *TPShort(id v) {
    NSString *d = v ? [v description] : @"nil";
    return d.length > 380 ? [[d substringToIndex:380] stringByAppendingString:@"…"] : d;
}

+ (NSString *)debugReportForVideoView:(UIView *)view player:(id)hint {
    id ivarPlayer = TPIvarObject(view, "videoPlayer");
    id player = TPResolvePlayer(view, hint);
    id inner = TPInnerPlayer(player);
    id provider = TPFindProvider(player);
    NSMutableString *r = [NSMutableString string];
    [r appendFormat:@"ThreadsPulse %@\n", TP_VERSION];
    [r appendFormat:@"view: %@\n", NSStringFromClass([view class])];
    [r appendFormat:@"player (callback): %@\n", hint ? NSStringFromClass([hint class]) : @"nil"];
    [r appendFormat:@"player (ivar): %@\n", ivarPlayer ? NSStringFromClass([ivarPlayer class]) : @"nil"];
    [r appendFormat:@"inner player: %@\n", inner ? NSStringFromClass([inner class]) : @"nil"];
    [r appendFormat:@"provider: %@\n", provider ? NSStringFromClass([provider class]) : @"nil"];
    [r appendFormat:@"allVideoURLs: %@\n", TPShort(TPSafeValue(provider, @"allVideoURLs"))];
    [r appendFormat:@"URL for current network: %@\n", TPShort(TPSafeValue(provider, @"videoURLForCurrentNetworkConditions"))];
    id vv = TPSafeValue(provider, @"videoVersions");
    [r appendFormat:@"videoVersions: %@\n", vv ? TPShort(vv) : @"none"];
    NSData *dash = TPSafeValue(provider, @"dashManifestData");
    if (![dash isKindOfClass:[NSData class]]) dash = TPSafeValue(inner, @"dashManifestData");
    if (![dash isKindOfClass:[NSData class]]) dash = TPSafeValue(player, @"currentMPD");
    if ([dash isKindOfClass:[NSData class]]) {
        NSDictionary *best = TPDashInfoFromManifest(dash, TPProgressivePixels(provider));
        [r appendFormat:@"DASH best: %@\n", best ? [NSString stringWithFormat:@"%@ (%@)%@", best[@"dashSize"], best[@"dashLabel"] ?: @"?", best[@"dashAudio"] ? @" + audio" : @""] : @"not larger than progressive"];
        NSString *x = [[NSString alloc] initWithData:dash encoding:NSUTF8StringEncoding];
        [r appendFormat:@"DASH manifest: %lu bytes\n%@\n", (unsigned long)dash.length, TPShort(x)];
    } else {
        [r appendString:@"DASH manifest: none\n"];
    }
    return r;
}

+ (void)showReport:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:TPL(@"Diagnostics")
                                                                   message:text
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"Copy") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            UIPasteboard.generalPasteboard.string = text;
        }]];
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"Close") style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
    });
}

// Walks an object's ObjC ivars collecting http(s) URLs. GraphQL models already hold full media
// URLs for items that were never played or loaded.
static void TPHarvest(id obj, int depth, NSMutableSet<NSValue *> *visited, NSMutableArray<NSURL *> *out, int *budget) {
    if (!obj || depth > 8 || *budget <= 0) return;
    (*budget)--;

    if ([obj isKindOfClass:[NSURL class]]) {
        NSString *sch = [(NSURL *)obj scheme].lowercaseString;
        if ([sch isEqualToString:@"http"] || [sch isEqualToString:@"https"]) [out addObject:obj];
        return;
    }
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *str = obj;
        if (str.length > 12 && str.length < 3000 && ([str hasPrefix:@"https://"] || [str hasPrefix:@"http://"])) {
            NSURL *u = [NSURL URLWithString:str];
            if (u) [out addObject:u];
        }
        return;
    }
    if ([obj isKindOfClass:[NSNumber class]] || [obj isKindOfClass:[NSDate class]] || [obj isKindOfClass:[NSData class]]) return;
    if ([obj isKindOfClass:[UIResponder class]] || [obj isKindOfClass:[CALayer class]] || [obj isKindOfClass:[UIImage class]]) return;

    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (id v in [(NSDictionary *)obj allValues]) TPHarvest(v, depth + 1, visited, out, budget);
        return;
    }
    if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSSet class]] || [obj isKindOfClass:[NSOrderedSet class]]) {
        for (id v in obj) TPHarvest(v, depth + 1, visited, out, budget);
        return;
    }

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
            TPHarvest(v, depth + 1, visited, out, budget);
        }
        free(ivars);
    }
}

static NSArray<NSURL *> *TPHarvestURLs(id obj) {
    NSMutableArray<NSURL *> *out = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    int budget = 4000;
    TPHarvest(obj, 0, visited, out, &budget);
    return out;
}

static NSInteger TPImageScore(NSURL *u) {
    NSString *s = u.absoluteString;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(\\d{3,4})x(\\d{3,4})" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return 1;
    return [[s substringWithRange:[m rangeAtIndex:1]] integerValue] * [[s substringWithRange:[m rangeAtIndex:2]] integerValue];
}

+ (NSURL *)bestVideoURLHarvestedFromObject:(id)obj {
    NSURL *best = nil;
    NSInteger bs = -1;
    for (NSURL *u in TPHarvestURLs(obj)) {
        if (![u.path.lowercaseString containsString:@".mp4"]) continue;
        NSInteger sc = TPScoreURL(u);
        if (sc < 0) continue;
        if (!best || sc > bs) { best = u; bs = sc; }
    }
    return best;
}

static NSURL *TPBestImageURLIn(id obj) {
    NSURL *best = nil;
    NSInteger bs = -1;
    for (NSURL *u in TPHarvestURLs(obj)) {
        NSString *path = u.path.lowercaseString;
        BOOL isImage = NO;
        for (NSString *ext in @[@".jpg", @".jpeg", @".webp", @".heic", @".png"]) if ([path containsString:ext]) { isImage = YES; break; }
        if (!isImage) continue;
        if ([path containsString:@"-19/"]) continue;
        NSInteger sc = TPImageScore(u);
        if (sc > bs) { best = u; bs = sc; }
    }
    return best;
}

+ (NSURL *)bestImageURLHarvestedFromObject:(id)obj { return TPBestImageURLIn(obj); }

+ (NSURL *)bestVideoURLNearView:(UIView *)view {
    int level = 0;
    for (UIView *v = view; v && level < 8; v = v.superview, level++) {
        NSMutableArray *models = [NSMutableArray array];
        for (Class c = object_getClass(v); c && c != [UIView class]; c = class_getSuperclass(c)) {
            unsigned int n = 0;
            Ivar *ivars = class_copyIvarList(c, &n);
            for (unsigned int i = 0; i < n; i++) {
                const char *enc = ivar_getTypeEncoding(ivars[i]);
                if (!enc || enc[0] != '@' || enc[1] == '?') continue;
                id o = object_getIvar(v, ivars[i]);
                if (o && ![o isKindOfClass:[UIResponder class]] && ![o isKindOfClass:[CALayer class]]) [models addObject:o];
            }
            free(ivars);
        }
        NSURL *u = models.count ? [self bestVideoURLHarvestedFromObject:models] : nil;
        if (u) return u;
    }
    return nil;
}


#pragma mark - DASH



static NSData *TPManifestDataIn(id obj) {
    for (NSString *key in @[@"dashManifestData", @"dashManifest", @"videoDashManifest", @"currentMPD"]) {
        id v = TPSafeValue(obj, key);
        if ([v isKindOfClass:[NSData class]] && [(NSData *)v length] > 32) return v;
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 32) return [(NSString *)v dataUsingEncoding:NSUTF8StringEncoding];
    }
    return nil;
}

static NSData *TPFindManifest(id obj) {
    if (!obj) return nil;
    NSData *d = TPManifestDataIn(obj);
    if (d) return d;
    for (NSString *key in @[@"video", @"computedVideo"]) {
        d = TPManifestDataIn(TPSafeValue(obj, key));
        if (d) return d;
    }
    return nil;
}

// Largest progressive (video+audio) MP4 in videoVersions, in pixels; 0 if unknown.
static NSInteger TPProgressivePixels(id obj) {
    NSArray *versions = TPSafeValue(obj, @"videoVersions");
    if (![versions isKindOfClass:[NSArray class]] || !versions.count) versions = TPSafeValue(TPSafeValue(obj, @"video"), @"videoVersions");
    if (![versions isKindOfClass:[NSArray class]] || !versions.count) versions = TPSafeValue(TPSafeValue(obj, @"computedVideo"), @"videoVersions");
    NSInteger best = 0;
    if (![versions isKindOfClass:[NSArray class]]) return 0;
    for (id v in versions) best = MAX(best, TPInt(TPSafeValue(v, @"width")) * TPInt(TPSafeValue(v, @"height")));
    return best;
}

// Only H.264 / HEVC can be muxed by passthrough into an MP4 that Photos accepts on every device.
static BOOL TPCodecOK(NSString *codecs) {
    NSString *c = codecs.lowercaseString;
    if (!c.length) return YES;
    for (NSString *ok in @[@"avc1", @"avc3", @"hvc1", @"hev1"]) if ([c hasPrefix:ok]) return YES;
    return NO;
}

// HLG (18) or PQ (16) in the codec string's transfer field:
// vp09.PP.LL.DD.CC.cp.tc.mc.FF   av01.P.LLT.DD.M.CCC.cp.tc.mc.F
static BOOL TPCodecIsHDR(NSString *codec) {
    NSArray<NSString *> *f = [codec.lowercaseString componentsSeparatedByString:@"."];
    NSInteger tc = 0;
    if ([codec.lowercaseString hasPrefix:@"vp09"] && f.count >= 7) tc = f[6].integerValue;
    else if ([codec.lowercaseString hasPrefix:@"av01"] && f.count >= 8) tc = f[7].integerValue;
    return tc == 16 || tc == 18;
}

static NSDictionary *TPDashInfoFromManifest(NSData *mpd, NSInteger progressivePixels) {
    if (!mpd.length) return nil;
    NSXMLParser *xp = [[NSXMLParser alloc] initWithData:mpd];
    TPMPDParser *mp = [TPMPDParser new];
    xp.delegate = mp;
    if (![xp parse] && !mp.reps.count) return nil;

    NSDictionary *bestV = nil, *bestA = nil;
    NSInteger bestPx = 0, bestVBw = 0, bestABw = -1;
    BOOL bestPass = NO;
    for (NSDictionary *r in mp.reps) {
        NSString *ct = [r[@"contentType"] lowercaseString] ?: @"";
        NSString *mime = [r[@"mimeType"] lowercaseString] ?: @"";
        NSInteger bw = [r[@"bandwidth"] integerValue];
        if ([ct isEqualToString:@"audio"] || [mime hasPrefix:@"audio/"]) {
            // Prefer AAC (copied as-is) over Opus etc. (re-encoded to AAC).
            BOOL aac = [[r[@"codecs"] lowercaseString] hasPrefix:@"mp4a"];
            BOOL bestAAC = [[bestA[@"codecs"] lowercaseString] hasPrefix:@"mp4a"];
            if (!bestA || (aac && !bestAAC) || (aac == bestAAC && bw > bestABw)) { bestA = r; bestABw = bw; }
            continue;
        }
        if (!([ct isEqualToString:@"video"] || [mime hasPrefix:@"video/"])) continue;
        // H.264/HEVC are merged as-is; VP9/AV1 are decoded and re-encoded to H.264.
        BOOL pass = TPCodecOK(r[@"codecs"]);
        NSString *lc = [r[@"codecs"] lowercaseString];
        if (!pass && !([lc hasPrefix:@"vp09"] || [lc hasPrefix:@"av01"])) continue;
        NSInteger px = [r[@"width"] integerValue] * [r[@"height"] integerValue];
        BOOL better = px > bestPx
                   || (px == bestPx && pass && !bestPass)
                   || (px == bestPx && pass == bestPass && bw > bestVBw);
        if (better) { bestV = r; bestPx = px; bestVBw = bw; bestPass = pass; }
    }
    if (!bestV) return nil;
    // Use DASH when it's sharper than the progressive MP4 — or, with "Keep HDR", when it's the same
    // size but HDR: the progressive MP4 is SDR, so it would lose the HDR look.
    BOOL hdr = TPCodecIsHDR(bestV[@"codecs"] ?: @"");
    BOOL keepHDR = hdr && [TPPrefs integerForKey:TPKeyVideoFormat] == 0;
    if (bestPx < progressivePixels || (bestPx == progressivePixels && !keepHDR)) return nil;

    NSURL *vu = [NSURL URLWithString:bestV[@"BaseURL"]];
    if (!vu) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"dashVideo"] = vu;
    NSURL *au = bestA ? [NSURL URLWithString:bestA[@"BaseURL"]] : nil;
    if (au) out[@"dashAudio"] = au;
    if (au && bestA[@"codecs"]) out[@"dashAudioCodec"] = [bestA[@"codecs"] lowercaseString];
    NSInteger w = [bestV[@"width"] integerValue], h = [bestV[@"height"] integerValue];
    NSString *label = bestV[@"FBQualityLabel"];
    if (!label.length && w && h) label = [NSString stringWithFormat:@"%ldp", (long)MIN(w, h)];
    if (keepHDR && label.length && ![label.uppercaseString containsString:@"HDR"]) label = [label stringByAppendingString:@" HDR"];
    if (label.length) out[@"dashLabel"] = label;
    out[@"dashSize"] = [NSString stringWithFormat:@"%ldx%ld %@", (long)w, (long)h, bestV[@"codecs"] ?: @""];
    if (!bestPass) out[@"dashTranscode"] = @YES;
    if (bestV[@"codecs"]) out[@"dashCodec"] = [bestV[@"codecs"] lowercaseString];
    return out;
}


// Debug-only: explains why DASH was or wasn't used for an object.
static void TPDashNames(id obj, NSMutableSet<NSString *> *out) {
    if (!obj) return;
    for (Class c = object_getClass(obj); c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *nm = @(ivar_getName(ivars[i]) ?: "");
            NSString *l = nm.lowercaseString;
            if ([l containsString:@"dash"] || [l containsString:@"mpd"] || [l containsString:@"manifest"])
                [out addObject:[NSString stringWithFormat:@"%@.%@", NSStringFromClass(c), nm]];
        }
        free(ivars);
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *nm = NSStringFromSelector(method_getName(ms[i]));
            NSString *l = nm.lowercaseString;
            if ([nm containsString:@":"]) continue;
            if ([l containsString:@"dash"] || [l containsString:@"mpd"] || [l containsString:@"manifest"])
                [out addObject:[NSString stringWithFormat:@"%@ -%@", NSStringFromClass(c), nm]];
        }
        free(ms);
    }
}

static NSString *TPDashDiag(NSString *label, NSArray *objs, NSInteger prog) {
    NSMutableString *r = [NSMutableString stringWithFormat:@"[DASH %@]\n", label];
    [r appendFormat:@"  progressive px: %ld\n", (long)prog];
    NSData *mpd = nil;
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    for (id o in objs) {
        if (o == NSNull.null) continue;
        [r appendFormat:@"  obj: %@\n", NSStringFromClass([o class])];
        TPDashNames(o, names);
        for (NSString *k in @[@"video", @"computedVideo"]) TPDashNames(TPSafeValue(o, k), names);
        if (!mpd) mpd = TPFindManifest(o);
    }
    if (names.count) [r appendFormat:@"  members: %@\n", [[names.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]];
    if (!mpd) { [r appendString:@"  manifest: NOT FOUND\n"]; return r; }
    [r appendFormat:@"  manifest: %lu bytes\n", (unsigned long)mpd.length];
    NSXMLParser *xp = [[NSXMLParser alloc] initWithData:mpd];
    TPMPDParser *mp = [TPMPDParser new];
    xp.delegate = mp;
    BOOL ok = [xp parse];
    [r appendFormat:@"  parse: %@, reps with BaseURL: %lu\n", ok ? @"ok" : xp.parserError.localizedDescription, (unsigned long)mp.reps.count];
    for (NSDictionary *rep in mp.reps)
        [r appendFormat:@"  - %@ %@x%@ %@ bw=%@\n", rep[@"contentType"] ?: rep[@"mimeType"] ?: @"?",
             rep[@"width"] ?: @"?", rep[@"height"] ?: @"?", rep[@"codecs"] ?: @"?", rep[@"bandwidth"] ?: @"?"];
    if (!mp.reps.count) {
        NSString *x = [[NSString alloc] initWithData:mpd encoding:NSUTF8StringEncoding] ?: @"(not UTF-8)";
        [r appendFormat:@"  head: %@\n", x.length > 600 ? [x substringToIndex:600] : x];
    }
    NSDictionary *best = TPDashInfoFromManifest(mpd, prog);
    [r appendFormat:@"  chosen: %@%@\n", best ? best[@"dashSize"] : @"none (not larger, not HDR / codec)",
         [best[@"dashTranscode"] boolValue] ? [@" → " stringByAppendingString:TPTranscodeTarget(best[@"dashCodec"])] : @""];
    [r appendFormat:@"  HW decode vp09 %@ · av01 %@\n",
         VTIsHardwareDecodeSupported('vp09') ? @"yes" : @"no", VTIsHardwareDecodeSupported('av01') ? @"yes" : @"no"];
    return r;
}

+ (NSDictionary *)dashInfoFromObject:(id)obj {
    if (!obj || [TPPrefs integerForKey:TPKeyVideoQuality] == 1) return nil;
    NSInteger prog = TPProgressivePixels(obj);
    if ([TPPrefs boolForKey:TPKeyDebugToast]) [self appendPendingReport:TPDashDiag(@"model", @[obj], prog)];
    return TPDashInfoFromManifest(TPFindManifest(obj), prog);
}

+ (NSDictionary *)dashInfoFromVideoView:(UIView *)view player:(id)hint {
    if (!view || [TPPrefs integerForKey:TPKeyVideoQuality] == 1) return nil;
    id player = TPResolvePlayer(view, hint);
    id provider = TPFindProvider(player);
    id inner = TPInnerPlayer(player);
    NSInteger prog = TPProgressivePixels(provider);
    if ([TPPrefs boolForKey:TPKeyDebugToast])
        [self appendPendingReport:TPDashDiag(@"player", @[provider ?: NSNull.null, inner ?: NSNull.null, player ?: NSNull.null], prog)];
    for (id o in @[provider ?: NSNull.null, inner ?: NSNull.null, player ?: NSNull.null]) {
        if (o == NSNull.null) continue;
        NSDictionary *d = TPDashInfoFromManifest(TPFindManifest(o), prog);
        if (d) return d;
    }
    return nil;
}

+ (id)safeValue:(id)obj key:(NSString *)key { return TPSafeValue(obj, key); }

+ (double)imageAreaFromURL:(NSURL *)url { return (double)TPImageScore(url); }


+ (void)appendPendingReport:(NSString *)report {
    if (![TPPrefs boolForKey:TPKeyDebugToast] || !report.length) return;
    sPendingReport = sPendingReport ? [sPendingReport stringByAppendingString:report] : [report copy];
}

+ (id)ivarValue:(id)obj name:(NSString *)name {
    if (!obj || !name.length) return nil;
    for (Class c = [obj class]; c; c = class_getSuperclass(c)) {
        Ivar iv = class_getInstanceVariable(c, name.UTF8String);
        if (iv) return TPCheckedIvar(obj, iv);
    }
    return nil;
}

static NSArray<NSDictionary *> *TPStripDash(NSArray<NSDictionary *> *items) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in items) {
        if (!d[@"dashVideo"]) { [out addObject:d]; continue; }
        NSMutableDictionary *m = [d mutableCopy];
        [m removeObjectsForKeys:@[@"dashVideo", @"dashAudio", @"dashTranscode", @"dashCodec", @"dashAudioCodec", @"dashLabel", @"dashSize"]];
        [out addObject:m];
    }
    return out;
}

+ (void)downloadItems:(NSArray<NSDictionary *> *)items { [self downloadItems:items context:nil]; }

+ (void)downloadItems:(NSArray<NSDictionary *> *)items context:(NSDictionary *)context {
    if (!items.count) return;
    BOOL retry = [context[@"retry"] boolValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^run)(NSArray *) = ^(NSArray *list) {
            // Retries already carry their record; new downloads get one here.
            if (!retry) list = [TPDownloadStore addRecordForItems:list context:context];
            if (!sQueue) sQueue = [NSMutableArray array];
            [sQueue addObject:list];
            if (sJobs.count || sQueuePaused) {
                if (![context[@"quiet"] boolValue])
                    [TPHUD toast:sQueuePaused ? TPL(@"Added to queue (paused)") : TPL(@"Added to download queue")];
                [NSNotificationCenter.defaultCenter postNotificationName:@"TPQueueChanged" object:nil];
                return;
            }
            TPStartNextJob();
        };
        void (^proceed)(void) = ^{
        NSDictionary *dashItem = nil;
        for (NSDictionary *d in items) if (d[@"dashVideo"]) { dashItem = d; break; }
        if (!dashItem || retry || [TPPrefs integerForKey:TPKeyVideoQuality] != 2) { run(items); return; }

        UIViewController *top = [self topViewController];
        if (!top) { run(items); return; }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:TPL(@"Choose video quality") message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
        NSString *label = dashItem[@"dashLabel"] ?: @"1080p";
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:TPL(@"Highest (%@)"), label]
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { run(items); }]];
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"720p (faster)")
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { run(TPStripDash(items)); }]];
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
        // Show the menu next to the download button that was tapped (like the profile picture menu).
        UIView *src = TPMenuAnchor();
        if (src) {
            a.popoverPresentationController.sourceView = src;
            a.popoverPresentationController.sourceRect = src.bounds;
        } else {
            a.popoverPresentationController.sourceView = top.view;
            a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMaxY(top.view.bounds) - 40, 1, 1);
        }
        [top presentViewController:a animated:YES completion:nil];
        };

        // Duplicate check: a post already in the download history (queued, running or saved).
        NSString *code = [context[@"code"] isKindOfClass:[NSString class]] ? context[@"code"] : nil;
        NSDictionary *dup = (!retry && ![context[@"quiet"] boolValue] && ![context[@"kind"] isEqualToString:@"avatar"] && ![context[@"kind"] isEqualToString:@"cover"]
                             && [TPPrefs boolForKey:TPKeyDuplicateWarn]) ? [TPDownloadStore existingRecordForCode:code] : nil;
        if (!dup) { proceed(); return; }
        NSInteger st = [dup[@"status"] integerValue];
        NSString *msg;
        if (st == 0 || st == 1) {
            msg = TPL(@"This post is already in the download queue.");
        } else {
            NSDate *when = [dup[@"date"] isKindOfClass:[NSDate class]] ? dup[@"date"] : nil;
            NSString *ds = when ? [NSDateFormatter localizedStringFromDate:when dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle] : @"";
            msg = [NSString stringWithFormat:TPL(@"You downloaded this post on %@."), ds];
        }
        UIViewController *top = [self topViewController];
        if (!top) { proceed(); return; }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:TPL(@"Already Downloaded") message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"Download Again") style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) { proceed(); }]];
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"Open Download Manager") style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) { [TPDownloadManagerViewController present]; }]];
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
    });
}

static NSString *TPFileSafe(NSString *s);

static NSArray<NSString *> *TPNamePartIDs(void) { return @[@"author", @"date", @"time", @"code", @"index", @"country", @"threads"]; }

+ (NSArray<NSDictionary *> *)fileNameParts {
    NSString *raw = [TPPrefs stringForKey:TPKeyNameParts];
    if (!raw.length) raw = @"author,date,time,code,index,!country,!threads";
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *t in [raw componentsSeparatedByString:@","]) {
        BOOL off = [t hasPrefix:@"!"];
        NSString *ident = off ? [t substringFromIndex:1] : t;
        if (![TPNamePartIDs() containsObject:ident] || [seen containsObject:ident]) continue;
        [seen addObject:ident];
        [out addObject:@{ @"id": ident, @"on": @(!off) }];
    }
    for (NSString *ident in TPNamePartIDs()) if (![seen containsObject:ident]) [out addObject:@{ @"id": ident, @"on": @NO }];
    return out;
}

+ (void)setFileNameParts:(NSArray<NSDictionary *> *)parts {
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSDictionary *p in parts) [tokens addObject:[p[@"on"] boolValue] ? p[@"id"] : [@"!" stringByAppendingString:p[@"id"]]];
    [TPPrefs setString:parts ? [tokens componentsJoinedByString:@","] : @"" forKey:TPKeyNameParts];
}

+ (NSString *)fileNameWithAuthor:(NSString *)author country:(NSString *)country date:(NSDate *)date
                            code:(NSString *)code index:(NSInteger)index count:(NSInteger)count
                           label:(NSString *)label extension:(NSString *)ext {
    NSInteger sepIdx = [TPPrefs integerForKey:TPKeyNameSeparator];
    NSString *sep = sepIdx == 1 ? @"-" : (sepIdx == 2 ? @" " : @"_");
    BOOL dashed = [TPPrefs integerForKey:TPKeyNameDateStyle] == 1;
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSMutableArray *parts = [NSMutableArray array];
    BOOL labelAdded = NO;
    for (NSDictionary *p in [self fileNameParts]) {
        if (![p[@"on"] boolValue]) continue;
        NSString *ident = p[@"id"], *v = nil;
        if ([ident isEqualToString:@"author"]) {
            NSString *a = TPFileSafe(author);
            v = a.length ? [@"@" stringByAppendingString:a] : nil;
        } else if ([ident isEqualToString:@"country"]) v = TPFileSafe(country);
        else if ([ident isEqualToString:@"date"]) { f.dateFormat = dashed ? @"yyyy-MM-dd" : @"yyyyMMdd"; v = [f stringFromDate:date ?: NSDate.date]; }
        else if ([ident isEqualToString:@"time"]) { f.dateFormat = dashed ? @"HH-mm-ss" : @"HHmmss"; v = [f stringFromDate:date ?: NSDate.date]; }
        else if ([ident isEqualToString:@"code"]) v = TPFileSafe(code);
        else if ([ident isEqualToString:@"index"]) v = count > 1 ? [NSString stringWithFormat:@"%ld", (long)index + 1] : nil;
        else if ([ident isEqualToString:@"threads"]) v = @"Threads";
        if (v.length) [parts addObject:v];
        if (label.length && !labelAdded && [ident isEqualToString:@"author"]) { [parts addObject:label]; labelAdded = YES; }
    }
    if (label.length && !labelAdded) [parts insertObject:label atIndex:0];
    if (!parts.count) {
        f.dateFormat = @"yyyyMMdd_HHmmss";
        [parts addObjectsFromArray:@[@"Threads", [f stringFromDate:date ?: NSDate.date]]];
    }
    return [[parts componentsJoinedByString:sep] stringByAppendingPathExtension:ext.length ? ext : @"jpg"];
}

+ (BOOL)queuePaused { return sQueuePaused; }

+ (void)setQueuePaused:(BOOL)paused {
    sQueuePaused = paused;
    [NSNotificationCenter.defaultCenter postNotificationName:@"TPQueueChanged" object:nil];
    if (!paused) TPStartNextJob();
}

+ (NSString *)activeRecordID { return [self activeRecordIDs].firstObject; }

+ (NSArray<NSString *> *)activeRecordIDs {
    NSMutableArray *ids = [NSMutableArray array];
    for (TPDownloadJob *j in sJobs) { NSString *r = [j recordID]; if (r) [ids addObject:r]; }
    return ids;
}

+ (NSArray<NSString *> *)queuedRecordIDs {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSArray *list in sQueue) { NSString *r = list.firstObject[@"tp_record"]; if (r) [ids addObject:r]; }
    return ids;
}

+ (void)removeQueuedRecord:(NSString *)rid {
    for (NSArray *list in [sQueue copy]) {
        if (![list.firstObject[@"tp_record"] isEqualToString:rid]) continue;
        [sQueue removeObject:list];
        [TPDownloadStore setRecord:rid status:4];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"TPQueueChanged" object:nil];
}

+ (void)moveQueuedRecordFrom:(NSInteger)from to:(NSInteger)to {
    if (from < 0 || to < 0 || from >= (NSInteger)sQueue.count || to >= (NSInteger)sQueue.count) return;
    NSArray *x = sQueue[from];
    [sQueue removeObjectAtIndex:from];
    [sQueue insertObject:x atIndex:to];
    [NSNotificationCenter.defaultCenter postNotificationName:@"TPQueueChanged" object:nil];
}

+ (void)cancelRecord:(NSString *)recordID {
    for (TPDownloadJob *j in [sJobs copy]) if ([[j recordID] isEqualToString:recordID]) [j cancelFromManager];
}

+ (void)downloadVideoURL:(NSURL *)url { [self downloadVideoURL:url dash:nil]; }

+ (void)downloadVideoURL:(NSURL *)url dash:(NSDictionary *)dash { [self downloadVideoURL:url dash:dash context:nil]; }

+ (void)downloadVideoURL:(NSURL *)url dash:(NSDictionary *)dash context:(NSDictionary *)context {
    if (!url && !dash[@"dashVideo"]) return;
    NSMutableDictionary *item = [NSMutableDictionary dictionaryWithDictionary:dash ?: @{}];
    item[@"urls"] = url ? @[url] : @[];
    item[@"video"] = @YES;
    [self downloadItems:@[item] context:context];
}

@end



// Adds saved assets to a named album (e.g. "Threads" or "@author"), creating it once.
// Needs read/write Photos access; failures are ignored because the files are already in the library.
static void TPAddToAlbumNamed(NSString *albumTitle, NSArray<NSString *> *assetIDs) {
    if (!assetIDs.count) return;
    NSString *title = albumTitle.length ? albumTitle : @"Threads";
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("tp.album", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(q, ^{
        NSUserDefaults *ud = [TPPrefs defaults];
        NSMutableDictionary *idMap = [[ud dictionaryForKey:@"tp_album_ids_by_name"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSString *savedID = idMap[title] ?: ([title isEqualToString:@"Threads"] ? [ud stringForKey:@"tp_album_id"] : nil);
        PHAssetCollection *album = nil;
        if (savedID.length)
            album = [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[savedID] options:nil].firstObject;
        if (!album) {
            PHFetchOptions *o = [PHFetchOptions new];
            o.predicate = [NSPredicate predicateWithFormat:@"title == %@", title];
            album = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                             subtype:PHAssetCollectionSubtypeAlbumRegular options:o].firstObject;
        }
        if (!album) {
            __block NSString *newID = nil;
            [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
                newID = [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:title]
                            .placeholderForCreatedAssetCollection.localIdentifier;
            } error:nil];
            if (newID) album = [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[newID] options:nil].firstObject;
        }
        if (!album) return;
        if (![album.localIdentifier isEqualToString:savedID]) {
            idMap[title] = album.localIdentifier;
            [ud setObject:idMap forKey:@"tp_album_ids_by_name"];
            if ([title isEqualToString:@"Threads"]) [ud setObject:album.localIdentifier forKey:@"tp_album_id"];
        }
        PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithLocalIdentifiers:assetIDs options:nil];
        if (!assets.count) return;
        [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
            [[PHAssetCollectionChangeRequest changeRequestForAssetCollection:album] addAssets:assets];
        } error:nil];
    });
}

// Only formats Photos always accepts (jpg, png, heic) are saved as-is; AVIF and WebP are
// decoded and re-encoded instead.
static NSString *TPImageExtension(NSURL *file) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:file error:nil];
    NSData *d = [fh readDataOfLength:16];
    [fh closeFile];
    if (d.length < 12) return nil;
    const uint8_t *b = d.bytes;
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return @"jpg";
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return @"png";
    if (b[4] == 'f' && b[5] == 't' && b[6] == 'y' && b[7] == 'p') {
        NSString *brand = [[NSString alloc] initWithBytes:b + 8 length:4 encoding:NSASCIIStringEncoding];
        if ([@[@"heic", @"heix", @"hevc", @"heim", @"heis", @"mif1", @"msf1"] containsObject:brand]) return @"heic";
    }
    return nil;
}

static NSString *TPMagicString(NSURL *file) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:file error:nil];
    NSData *d = [fh readDataOfLength:16];
    [fh closeFile];
    if (d.length < 12) return [NSString stringWithFormat:@"%lu bytes", (unsigned long)d.length];
    const uint8_t *b = d.bytes;
    if (b[4] == 'f' && b[5] == 't' && b[6] == 'y' && b[7] == 'p')
        return [@"ftyp/" stringByAppendingString:[[NSString alloc] initWithBytes:b + 8 length:4 encoding:NSASCIIStringEncoding] ?: @"?"];
    if (b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F')
        return [@"RIFF/" stringByAppendingString:[[NSString alloc] initWithBytes:b + 8 length:4 encoding:NSASCIIStringEncoding] ?: @"?"];
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < 4; i++) [hex appendFormat:@"%02X", b[i]];
    return hex;
}

// Some decoded pixel formats are rejected by Photos with PHPhotosErrorDomain 3302. Redrawing
// into 8-bit sRGB before encoding JPEG avoids that.
static NSData *TPJPEGData(UIImage *img) {
    if (!img) return nil;
    CGSize px = CGSizeMake(img.size.width * img.scale, img.size.height * img.scale);
    if (px.width < 1 || px.height < 1) return nil;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = 1;
    fmt.opaque = YES;
    fmt.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    UIImage *flat = [[[UIGraphicsImageRenderer alloc] initWithSize:px format:fmt] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [UIColor.whiteColor setFill];
        UIRectFill(CGRectMake(0, 0, px.width, px.height));
        [img drawInRect:CGRectMake(0, 0, px.width, px.height)];
    }];
    return UIImageJPEGRepresentation(flat, 0.95);
}

// Threads post IDs carry their creation time: (milliseconds since 2011-08-24 21:07:01.721 UTC) << 23.
// The shortcode is the ID in base 64 (A–Z a–z 0–9 - _).
static NSDate *TPDateFromShortcode(NSString *code) {
    if (code.length < 6 || code.length > 11) return nil;
    static NSString *const alphabet = @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    unsigned long long pk = 0;
    for (NSUInteger i = 0; i < code.length; i++) {
        NSRange r = [alphabet rangeOfString:[code substringWithRange:NSMakeRange(i, 1)]];
        if (r.location == NSNotFound) return nil;
        if (pk > (ULLONG_MAX >> 6)) return nil;
        pk = (pk << 6) | r.location;
    }
    double ms = (double)(pk >> 23) + 1314220021721.0;
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:ms / 1000.0];
    // Only trust a date between Threads' launch and a day from now.
    if (d.timeIntervalSince1970 < 1688083200 || d.timeIntervalSinceNow > 86400) return nil;
    return d;
}

static NSString *TPFileSafe(NSString *s) {
    if (!s.length) return nil;
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|\n\r\t"];
    NSString *out = [[s componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"-"];
    out = [out stringByReplacingOccurrencesOfString:@" " withString:@"-"];
    return out.length > 40 ? [out substringToIndex:40] : out;
}

static void TPStartNextJob(void) {
    if (!sQueue.count || sQueuePaused) return;
    for (TPDownloadJob *j in sJobs) if ([j isDownloading]) return;
    NSArray *list = sQueue.firstObject;
    [sQueue removeObjectAtIndex:0];
    TPDownloadJob *job = [[TPDownloadJob alloc] initWithItems:list];
    [job start];
}

@implementation TPDownloadJob {
    UIBackgroundTaskIdentifier _bgTask;
    BOOL _wentBackground;
    NSInteger _resumeTries;
    id _bgObserver;
    NSArray<NSDictionary *> *_items;
    NSInteger _index, _urlIndex, _saved, _failed;
    NSURLSession *_session;
    NSURLSessionDownloadTask *_task;
    TPCapsule *_hud;
    BOOL _cancelled, _allowPhotos;
    NSURL *_pendingFile;
    NSMutableArray<NSURL *> *_leftovers;
    NSMutableArray<NSString *> *_log;
    NSString *_extraReport;
    NSMutableArray<NSString *> *_savedSizes;
    // DASH: 0 = not in use, 1 = downloading video stream, 2 = downloading audio stream, 3 = merging
    NSInteger _dashStage;
    BOOL _dashTried;
    NSURL *_dashVideoFile, *_dashAudioFile;
    AVAssetExportSession *_export;
    // Parallel downloads: items after the current one are fetched ahead on a second session.
    // Values: NSURLSessionTask (running), NSURL (file ready), NSNull (failed → normal retry).
    NSURLSession *_prefetchSession;
    NSMutableDictionary<NSNumber *, id> *_prefetch;
    BOOL _waitingPrefetch;
    NSMutableArray<NSURLSessionTask *> *_allTasks;
    NSTimer *_speedTimer;
    int64_t _lastBytes;
    CFAbsoluteTime _lastTick;
    double _speed;
    NSString *_speedText;
    // "Threads" album
    BOOL _useAlbum, _albumDenied;
    // Per-item results for the capsule's file list: 2 saved, 3 failed.
    NSMutableDictionary<NSNumber *, NSNumber *> *_states;
    NSInteger _savedAtItemStart, _failedAtItemStart;
    CGFloat _itemFrac;
    NSMutableArray<NSString *> *_savedIDs;
    NSString *_recordID;
    NSString *_stageDetail;
    BOOL _didTranscode;
}

- (instancetype)initWithItems:(NSArray<NSDictionary *> *)items {
    if ((self = [super init])) {
        _items = items;
        _leftovers = [NSMutableArray array];
        _log = [NSMutableArray array];
        _savedSizes = [NSMutableArray array];
        _prefetch = [NSMutableDictionary dictionary];
        _states = [NSMutableDictionary dictionary];
        _allTasks = [NSMutableArray array];
        _savedIDs = [NSMutableArray array];
        _useAlbum = [TPPrefs boolForKey:TPKeySaveToAlbum] || [TPPrefs boolForKey:TPKeyAlbumByAuthor];
        _extraReport = sPendingReport;
        sPendingReport = nil;
        _recordID = items.firstObject[@"tp_record"];
    }
    return self;
}

- (void)start {
    if (!sJobs) sJobs = [NSMutableSet set];
    [sJobs addObject:self];
    [TPDownloadStore setRecord:_recordID status:1];
    [NSNotificationCenter.defaultCenter postNotificationName:@"TPQueueChanged" object:nil];

    // Requesting read/write access without NSPhotoLibraryUsageDescription in Info.plist kills the app.
    if (_useAlbum && ![NSBundle.mainBundle objectForInfoDictionaryKey:@"NSPhotoLibraryUsageDescription"]) {
        _useAlbum = NO;
        _albumDenied = YES;
    }
    if (_useAlbum) {
        // The album needs read/write access; without it, still save normally (add-only).
        void (^decide)(PHAuthorizationStatus) = ^(PHAuthorizationStatus rw) {
            if (rw == PHAuthorizationStatusAuthorized || rw == PHAuthorizationStatusLimited) {
                self->_allowPhotos = YES;
                [self begin];
            } else {
                self->_useAlbum = NO;
                self->_albumDenied = YES;
                [self startAddOnly];
            }
        };
        PHAuthorizationStatus rw = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
        if (rw == PHAuthorizationStatusNotDetermined) {
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus s2) {
                dispatch_async(dispatch_get_main_queue(), ^{ decide(s2); });
            }];
        } else {
            decide(rw);
        }
        return;
    }
    [self startAddOnly];
}

- (void)startAddOnly {
    PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    if (st == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus s2) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_allowPhotos = (s2 == PHAuthorizationStatusAuthorized || s2 == PHAuthorizationStatusLimited);
                [self begin];
            });
        }];
    } else {
        _allowPhotos = (st == PHAuthorizationStatusAuthorized || st == PHAuthorizationStatusLimited);
        [self begin];
    }
}

- (void)begin {
    __weak typeof(self) weak = self;
    // Keep running for a while if the user leaves Threads mid-download or mid-conversion.
    _bgTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"ThreadsPulse download" expirationHandler:^{
        typeof(self) s = weak;
        if (!s || s->_bgTask == UIBackgroundTaskInvalid) return;
        [UIApplication.sharedApplication endBackgroundTask:s->_bgTask];
        s->_bgTask = UIBackgroundTaskInvalid;
    }];
    _bgObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                                                                    queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        typeof(self) s = weak;
        if (s) s->_wentBackground = YES;
    }];
    _hud = [TPCapsule showWithTitle:[self titleForCurrent] cancel:^{ [weak cancel]; }];
    _hud.tag = [TPDownloadStore recordWithID:_recordID][@"tag"];
    _hud.queueCount = ^NSInteger { return (NSInteger)sQueue.count; };
    _hud.cancelAll = ^{
        for (NSArray *list in sQueue) [TPDownloadStore setRecord:list.firstObject[@"tp_record"] status:4];
        [sQueue removeAllObjects];
        [weak cancel];
    };
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(queueChanged) name:@"TPQueueChanged" object:nil];
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:NSOperationQueue.mainQueue];
    [self startPrefetch];
    [_hud setRows:[self rows]];
    _lastTick = CFAbsoluteTimeGetCurrent();
    _speedTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self tryCurrent];
}

- (void)startPrefetch {
    if (_items.count < 2) return;
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.HTTPMaximumConnectionsPerHost = 3;  // + the main session's one = up to 4 at once
    _prefetchSession = [NSURLSession sessionWithConfiguration:cfg];
    __weak typeof(self) weak = self;
    for (NSInteger i = 1; i < (NSInteger)_items.count; i++) {
        NSDictionary *item = _items[i];
        NSArray<NSURL *> *urls = item[@"urls"];
        if (item[@"dashVideo"] || ![urls.firstObject isKindOfClass:[NSURL class]]) continue;  // DASH items fetch their own streams
        NSNumber *key = @(i);
        NSURLSessionDownloadTask *t = [_prefetchSession downloadTaskWithURL:urls.firstObject
                                                         completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *err) {
            NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
            NSURL *dst = nil;
            if (!err && loc && code >= 200 && code < 300) {
                dst = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                              [NSString stringWithFormat:@"tp_%@", NSUUID.UUID.UUIDString]]];
                if (![NSFileManager.defaultManager moveItemAtURL:loc toURL:dst error:nil]) dst = nil;
            }
            dispatch_async(dispatch_get_main_queue(), ^{ [weak prefetchDone:key file:dst]; });
        }];
        _prefetch[key] = t;
        [_allTasks addObject:t];
        [t resume];
    }
}

- (void)prefetchDone:(NSNumber *)key file:(NSURL *)file {
    if (_cancelled) { if (file) [NSFileManager.defaultManager removeItemAtURL:file error:nil]; return; }
    _prefetch[key] = file ?: (id)NSNull.null;
    if (_waitingPrefetch && _index == key.integerValue) {
        _waitingPrefetch = NO;
        [self tryCurrent];
    }
}

- (void)notifyManagerProgress:(NSString *)detail {
    if (!_recordID) return;
    CGFloat overall = ((CGFloat)_index + MAX(0, MIN(1, _itemFrac))) / (CGFloat)MAX((NSInteger)1, (NSInteger)_items.count);
    NSString *text = detail.length ? detail : (_stageDetail.length ? _stageDetail : (_dashStage == 3
        ? TPL([_items[_index][@"dashTranscode"] boolValue] ? @"Converting video…" : @"Merging video and audio…")
        : _speedText));
    [NSNotificationCenter.defaultCenter postNotificationName:TPDownloadProgressNotification object:nil
        userInfo:@{ @"record": _recordID, @"progress": @(MIN(1, overall)), @"speed": text ?: @"" }];
}

- (void)tick {
    int64_t total = 0;
    for (NSURLSessionTask *t in _allTasks) total += t.countOfBytesReceived;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double dt = now - _lastTick;
    if (dt <= 0) return;
    double inst = MAX(0, (double)(total - _lastBytes)) / dt;
    _speed = _speed > 0 ? _speed * 0.6 + inst * 0.4 : inst;
    _lastBytes = total;
    _lastTick = now;
    _speedText = _speed >= 1048576 * 0.1 ? [NSString stringWithFormat:@"%.1f MB/s", _speed / 1048576.0]
               : (_speed > 0 ? [NSString stringWithFormat:@"%.0f KB/s", _speed / 1024.0] : nil);
    [_hud setSpeed:_speedText];
    [self notifyManagerProgress:nil];
    if (_waitingPrefetch) {
        CGFloat overall = (CGFloat)_index / (CGFloat)MAX((NSInteger)1, (NSInteger)_items.count);
        [_hud setProgress:overall subtitle:TPL(@"Waiting for downloads…")];
    }
}

- (void)stopTimersAndPrefetch {
    [_speedTimer invalidate];
    _speedTimer = nil;
    [_prefetchSession invalidateAndCancel];
    for (id v in _prefetch.allValues) if ([v isKindOfClass:[NSURL class]]) [NSFileManager.defaultManager removeItemAtURL:v error:nil];
    [_prefetch removeAllObjects];
}

- (void)queueChanged { [_hud setRows:[self rows]]; }

- (void)jobEnded {
    if (_didTranscode && _saved > 0 && !_cancelled) TPPostTranscodeNotification(_saved);
    [NSNotificationCenter.defaultCenter removeObserver:self name:@"TPQueueChanged" object:nil];
    if (_bgObserver) { [NSNotificationCenter.defaultCenter removeObserver:_bgObserver]; _bgObserver = nil; }
    if (_bgTask != UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:_bgTask]; _bgTask = UIBackgroundTaskInvalid; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TPStartNextJob();
    });
}

- (void)cancel {
    if (_cancelled) return;
    _cancelled = YES;
    [self jobEnded];
    [self stopTimersAndPrefetch];
    [_export cancelExport];
    [self cleanupDash];
    [_session invalidateAndCancel];
    for (NSURL *f in _leftovers) [NSFileManager.defaultManager removeItemAtURL:f error:nil];
    [sJobs removeObject:self];
    [TPDownloadStore setRecord:_recordID status:4];
    [NSNotificationCenter.defaultCenter postNotificationName:@"TPQueueChanged" object:nil];
}

- (NSString *)recordID { return _cancelled ? nil : _recordID; }

- (void)cancelFromManager {
    [_hud dismiss];
    [self cancel];
}

// The history's index of the current item (retries download only some of a record's items).
- (NSInteger)recordIndex {
    id i = _items[MIN(_index, (NSInteger)_items.count - 1)][@"tp_index"];
    return i ? [i integerValue] : _index;
}

- (NSString *)titleForCurrent {
    // Kept short so the pill stays clear of the buttons at the top of the screen ("5/35 · 14%");
    // a single file shows only its percentage.
    NSString *t = _items.count <= 1 ? @""
        : [NSString stringWithFormat:@"%ld/%ld", (long)MIN(_index + 1, (NSInteger)_items.count), (long)_items.count];
    return t;
}

// The capsule's file list: one row per item, consecutive waiting items of the same kind grouped
// ("Photos 3–5"), at most 6 rows.
- (NSArray<NSDictionary *> *)rows {
    NSMutableArray *rows = [NSMutableArray array];
    NSInteger n = (NSInteger)_items.count, i = 0;
    while (i < n) {
        BOOL video = [_items[i][@"video"] boolValue];
        NSInteger state = i < _index ? [_states[@(i)] integerValue] ?: 2 : (i == _index ? 1 : 0);
        if (state == 0) {
            NSInteger j = i;
            while (j + 1 < n && [_items[j + 1][@"video"] boolValue] == video) j++;
            NSString *title = j > i
                ? [NSString stringWithFormat:TPL(video ? @"Videos %ld–%ld" : @"Photos %ld–%ld"), (long)i + 1, (long)j + 1]
                : [NSString stringWithFormat:TPL(video ? @"Video %ld" : @"Photo %ld"), (long)i + 1];
            [rows addObject:@{ @"title": title, @"status": TPL(@"Waiting"), @"state": @0 }];
            i = j + 1;
            continue;
        }
        NSString *title = [NSString stringWithFormat:TPL(video ? @"Video %ld" : @"Photo %ld"), (long)i + 1];
        NSString *label = state == 1 && _dashStage ? _items[i][@"dashLabel"] : nil;
        if (label.length) title = [title stringByAppendingFormat:@" · %@", label];
        NSString *status = state == 2 ? TPL(@"Saved") : state == 3 ? TPL(@"Failed")
                         : [NSString stringWithFormat:@"%.0f%%", floor(MAX(0, MIN(1, _itemFrac)) * 100)];
        [rows addObject:@{ @"title": title, @"status": status, @"state": @(state) }];
        i++;
    }
    // Keep the card short: completed rows beyond the last few collapse into the first row.
    if (rows.count > 6) {
        NSInteger drop = (NSInteger)rows.count - 6;
        NSInteger done = 0;
        for (NSDictionary *r in rows) if ([r[@"state"] integerValue] >= 2) done++;
        if (done > drop) {
            NSMutableArray *kept = [NSMutableArray array];
            NSInteger dropped = 0, failed = 0;
            for (NSDictionary *r in rows) {
                if (dropped < drop + 1 && [r[@"state"] integerValue] >= 2) {
                    dropped++;
                    if ([r[@"state"] integerValue] == 3) failed++;
                    continue;
                }
                [kept addObject:r];
            }
            NSString *t = [NSString stringWithFormat:TPL(@"%ld items done"), (long)dropped];
            [kept insertObject:@{ @"title": t, @"status": failed ? [NSString stringWithFormat:TPL(@"%ld failed"), (long)failed] : TPL(@"Saved"),
                                  @"state": @(failed ? 3 : 2) } atIndex:0];
            rows = kept;
        }
    }
    return rows;
}

- (void)nextItem {
    if (_index < (NSInteger)_items.count) {
        BOOL failedMore = _failed > _failedAtItemStart;
        _states[@(_index)] = @(failedMore ? 3 : 2);
        [TPDownloadStore setRecord:_recordID item:[self recordIndex] saved:!failedMore];
    }
    _savedAtItemStart = _saved;
    _failedAtItemStart = _failed;
    _itemFrac = 0;
    _stageDetail = nil;
    [self cleanupDash];
    _dashTried = NO;
    _index++;
    _urlIndex = 0;
    if (_index >= (NSInteger)_items.count) { [self finish]; return; }
    [_hud setTitle:[self titleForCurrent]];
    [_hud setRows:[self rows]];
    [self tryCurrent];
}

- (void)tryCurrent {
    if (_cancelled) return;
    NSDictionary *item = _items[_index];
    if (!_dashTried && [item[@"dashVideo"] isKindOfClass:[NSURL class]]) {
        _dashTried = YES;
        [self startDash];
        return;
    }
    NSArray<NSURL *> *urls = item[@"urls"];
    if (_urlIndex == 0) {
        id pf = _prefetch[@(_index)];
        if ([pf isKindOfClass:[NSURLSessionTask class]]) { _waitingPrefetch = YES; return; }
        if (pf) [_prefetch removeObjectForKey:@(_index)];
        if ([pf isKindOfClass:[NSURL class]]) { [self handleDownloadedFile:pf]; return; }
        // NSNull: the parallel fetch failed — fall through and retry it normally.
    }
    if (_urlIndex >= (NSInteger)urls.count) {
        UIImage *fallback = item[@"image"];
        if ([fallback isKindOfClass:[UIImage class]] && _allowPhotos) {
            [self saveImage:fallback];
        } else {
            if (!urls.count) [self note:@"no URL"];
            _failed++;
            [self nextItem];
        }
        return;
    }
    _pendingFile = nil;
    _task = [_session downloadTaskWithURL:urls[_urlIndex]];
    [_allTasks addObject:_task];
    [_task resume];
}

- (void)finish {
    [_session finishTasksAndInvalidate];
    [self stopTimersAndPrefetch];
    [sJobs removeObject:self];
    [TPDownloadStore setRecord:_recordID status:2];
    [self jobEnded];
    [NSNotificationCenter.defaultCenter postNotificationName:@"TPQueueChanged" object:nil];
    if (_useAlbum && _savedIDs.count) {
        NSString *albumTitle = @"Threads";
        if ([TPPrefs boolForKey:TPKeyAlbumByAuthor]) {
            NSString *author = _recordID.length ? [TPDownloadStore recordWithID:_recordID][@"author"] : nil;
            if (author.length) albumTitle = [@"@" stringByAppendingString:author];
        }
        TPAddToAlbumNamed(albumTitle, _savedIDs);
    }
    if (_albumDenied && _saved > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [TPHUD toast:TPL(@"Photos access needed to add to the Threads album")];
        });
    }

    if (_leftovers.count) {
        [_hud dismiss];
        UIViewController *top = TPTopViewController();
        UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:_leftovers applicationActivities:nil];
        av.popoverPresentationController.sourceView = top.view;
        av.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
        [top presentViewController:av animated:YES completion:nil];
        [TPHUD toast:TPL(@"Photos access denied — choose where to save")];
        return;
    }

    if (_extraReport && [TPPrefs boolForKey:TPKeyDebugToast]) {
        NSMutableString *r = [NSMutableString stringWithFormat:@"ThreadsPulse %@\n%@", TP_VERSION, _extraReport];
        if (_savedSizes.count) [r appendFormat:@"\n[downloaded]\n%@\n", [_savedSizes componentsJoinedByString:@"\n"]];
        if (_log.count) [r appendFormat:@"\n[errors]\n%@", [_log componentsJoinedByString:@"\n"]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [TPDownloader showReport:r];
        });
    } else if (_failed > 0 && _log.count && [TPPrefs boolForKey:TPKeyDebugToast]) {
        NSString *report = [NSString stringWithFormat:@"ThreadsPulse %@\n%@", TP_VERSION,
                            [_log componentsJoinedByString:@"\n"]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [TPDownloader showReport:report];
        });
    }
    if (_saved == 0) { [_hud finishFailure:TPL(@"Download failed, please try again later")]; return; }
    if (_failed > 0) {
        [_hud finishSuccess:[NSString stringWithFormat:TPL(@"Saved %ld, failed %ld"), (long)_saved, (long)_failed]];
    } else if (_saved == 1) {
        [_hud finishSuccess:TPL(@"Saved to Photos")];
    } else {
        [_hud finishSuccess:[NSString stringWithFormat:TPL(@"Saved %ld items to Photos"), (long)_saved]];
    }
}

- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didWriteData:(int64_t)w
 totalBytesWritten:(int64_t)tw totalBytesExpectedToWrite:(int64_t)te {
    if (t != _task || _cancelled) return;
    double mb = tw / 1048576.0;
    CGFloat frac = te > 0 ? (CGFloat)tw / (CGFloat)te : 0;
    CGFloat itemFrac = frac;
    BOOL willTranscode = _dashStage && [_items[_index][@"dashTranscode"] boolValue];
    if (_dashStage == 1) itemFrac = frac * (willTranscode ? 0.42 : 0.85);
    else if (_dashStage == 2) itemFrac = willTranscode ? (0.42 + frac * 0.08) : (0.85 + frac * 0.12);
    CGFloat overall = ((CGFloat)_index + itemFrac) / (CGFloat)_items.count;
    // Ring: overall percentage. Line 1: quality · which stream · size. Line 2: speed.
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *label = _dashStage ? _items[_index][@"dashLabel"] : nil;
    if (label.length) [parts addObject:label];
    NSString *size = te > 0 ? [NSString stringWithFormat:@"%.1f/%.1f MB", mb, te / 1048576.0]
                            : [NSString stringWithFormat:@"%.1f MB", mb];
    if (_dashStage == 1) size = [NSString stringWithFormat:@"%@ %@", TPL(@"Video stream"), size];
    else if (_dashStage == 2) size = [NSString stringWithFormat:@"%@ %@", TPL(@"Audio stream"), size];
    [parts addObject:size];
    NSString *sub = [parts componentsJoinedByString:@" · "];
    _itemFrac = itemFrac;
    [_hud setProgress:overall subtitle:sub];
    [_hud setRows:[self rows]];
}

- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didFinishDownloadingToURL:(NSURL *)loc {
    if (t != _task) return;
    NSInteger code = [t.response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)t.response statusCode] : 200;
    if (code < 200 || code >= 300) return;
    NSURL *dst = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                         [NSString stringWithFormat:@"tp_%@", NSUUID.UUID.UUIDString]]];
    if ([NSFileManager.defaultManager moveItemAtURL:loc toURL:dst error:nil]) _pendingFile = dst;
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error {
    if (t != _task || _cancelled) return;
    if (_dashStage) { [self dashTask:t completedWithError:error]; return; }
    if (!error && _pendingFile) {
        NSURL *f = _pendingFile;
        _pendingFile = nil;
        [self handleDownloadedFile:f];
    } else {
        NSInteger code = [t.response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)t.response statusCode] : 0;
        [self note:[NSString stringWithFormat:@"HTTP %ld %@", (long)code, error.localizedDescription ?: @""]];
        _urlIndex++;
        [self tryCurrent];
    }
}

- (void)note:(NSString *)msg {
    NSArray<NSURL *> *urls = _items[_index][@"urls"];
    NSString *which = _urlIndex < (NSInteger)urls.count ? urls[_urlIndex].lastPathComponent : @"(image)";
    if (which.length > 28) which = [[which substringToIndex:28] stringByAppendingString:@"…"];
    [_log addObject:[NSString stringWithFormat:@"#%ld #%ld %@\n  %@", (long)_index + 1, (long)_urlIndex + 1, which, msg]];
}

- (void)handleDownloadedFile:(NSURL *)file {
    BOOL isVideo = [_items[_index][@"video"] boolValue];

    if (!_allowPhotos) {
        NSString *ext = isVideo ? @"mp4" : (TPImageExtension(file) ?: @"jpg");
        NSURL *named = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                               [NSString stringWithFormat:@"threads_%@.%@", NSUUID.UUID.UUIDString, ext]]];
        if ([NSFileManager.defaultManager moveItemAtURL:file toURL:named error:nil]) {
            [TPDownloadStore keepFile:named record:_recordID item:[self recordIndex]];
            [_leftovers addObject:named]; _saved++;
        } else { _failed++; }
        [self nextItem];
        return;
    }

    if (isVideo) {
        NSURL *mp4 = [NSURL fileURLWithPath:[file.path stringByAppendingPathExtension:@"mp4"]];
        [NSFileManager.defaultManager moveItemAtURL:file toURL:mp4 error:nil];
        // Threads now also serves the plain (progressive) MP4 as AV1 or VP9, which Photos refuses
        // (error 3302). Convert those with the same decoder path the DASH streams use.
        NSString *fourcc = TPVideoFourCC(mp4);
        if (([fourcc isEqualToString:@"av01"] || [fourcc isEqualToString:@"vp09"]) && ![_items[_index][@"progressiveConvert"] boolValue]) {
            NSMutableArray *items = [_items mutableCopy];
            NSMutableDictionary *it = [items[_index] mutableCopy];
            it[@"progressiveConvert"] = @YES;
            it[@"dashTranscode"] = @YES;
            it[@"dashCodec"] = [fourcc isEqualToString:@"av01"] ? @"av01" : @"vp09";
            [it removeObjectForKey:@"dashAudioCodec"];
            items[_index] = it;
            _items = items;
            [self note:[NSString stringWithFormat:@"progressive %@ → converting", fourcc]];
            _dashVideoFile = mp4;
            _dashAudioFile = TPFileHasAudio(mp4) ? mp4 : nil;
            _dashStage = 3;
            [self whenConverterFree:^{ [self transcodeDash]; }];
            return;
        }
        [self saveVideoFile:mp4 completion:^(BOOL ok) { [self itemDone:ok]; }];
        return;
    }

    NSString *magic = TPMagicString(file);
    if (_extraReport) {
        UIImage *probe = [UIImage imageWithContentsOfFile:file.path];
        NSDictionary *attr = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
        [_savedSizes addObject:[NSString stringWithFormat:@"#%ld %.0fx%.0f %@ %.0f KB", (long)_index + 1,
                                probe.size.width * probe.scale, probe.size.height * probe.scale, magic,
                                [attr fileSize] / 1024.0]];
    }
    NSString *ext = TPImageExtension(file);
    if (ext) {
        NSURL *img = [NSURL fileURLWithPath:[file.path stringByAppendingPathExtension:ext]];
        [NSFileManager.defaultManager moveItemAtURL:file toURL:img error:nil];
        [TPDownloadStore keepFile:img record:_recordID item:[self recordIndex]];
        [self performSave:^PHAssetChangeRequest *{ return [self creationRequestWithType:PHAssetResourceTypePhoto file:img data:nil ext:ext]; } completion:^(BOOL ok, NSError *e) {
            if (ok) { [NSFileManager.defaultManager removeItemAtURL:img error:nil]; [self itemDone:YES]; return; }
            [self note:[NSString stringWithFormat:@"%@ save file: %@", magic, e.localizedDescription ?: @"?"]];
            [self saveDecodedImageAt:img magic:magic];
        }];
    } else {
        [self saveDecodedImageAt:file magic:magic];
    }
}


#pragma mark DASH download + merge

- (void)saveVideoFile:(NSURL *)file completion:(void (^)(BOOL ok))completion {
    [self saveVideoFile:file attempt:0 completion:completion];
}

// Photos refuses or interrupts a save while the app is in the background (error 3301). The
// converted file is kept and saved again once Threads is back in front.
- (void)saveVideoFile:(NSURL *)file attempt:(NSInteger)attempt completion:(void (^)(BOOL ok))completion {
    if (attempt == 0) [TPDownloadStore keepFile:file record:_recordID item:[self recordIndex]];
    [self performSave:^PHAssetChangeRequest *{
        return [self creationRequestWithType:PHAssetResourceTypeVideo file:file data:nil ext:file.pathExtension.length ? file.pathExtension.lowercaseString : @"mp4"];
    } completion:^(BOOL ok, NSError *e) {
        BOOL interrupted = !ok && attempt < 2 &&
            (([e.domain isEqualToString:@"PHPhotosErrorDomain"] && (e.code == 3301 || e.code == 3300)) ||
             UIApplication.sharedApplication.applicationState != UIApplicationStateActive);
        if (interrupted && !self->_cancelled) {
            [self note:[NSString stringWithFormat:@"save video interrupted (%ld), retry when active", (long)e.code]];
            void (^retry)(void) = ^{ [self saveVideoFile:file attempt:attempt + 1 completion:completion]; };
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), retry);
            } else {
                [self->_hud setProgress:-1 subtitle:TPL(@"Paused — continues when you return to Threads")];
                __block id obs = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                                                                                  queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                    [NSNotificationCenter.defaultCenter removeObserver:obs];
                    obs = nil;
                    retry();
                }];
            }
            return;
        }
        [NSFileManager.defaultManager removeItemAtURL:file error:nil];
        if (!ok) [self note:[NSString stringWithFormat:@"save video: %@", e.localizedDescription ?: @"?"]];
        completion(ok);
    }];
}

// Conversion stage: true while converting or waiting for the converter, when nothing downloads.
- (BOOL)isDownloading { return !_cancelled && _dashStage != 3; }

static BOOL sTPDisabledIdleTimer = NO;

static void TPSetTranscodeIdleDisabled(BOOL disabled) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = UIApplication.sharedApplication;
        if (disabled) {
            if (!app.idleTimerDisabled) {
                app.idleTimerDisabled = YES;
                sTPDisabledIdleTimer = YES;
            }
        } else {
            if (sTPDisabledIdleTimer) {
                app.idleTimerDisabled = NO;
                sTPDisabledIdleTimer = NO;
            }
        }
    });
}

static void TPPostTranscodeNotification(NSInteger savedCount) {
    if (savedCount <= 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Only post a system notification when the app is not active in the foreground.
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) return;
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            void (^deliver)(void) = ^{
                UNMutableNotificationContent *content = [UNMutableNotificationContent new];
                content.title = @"ThreadsPulse";
                content.body = [NSString stringWithFormat:TPL(@"Video conversion finished (%ld saved)"), (long)savedCount];
                content.sound = [UNNotificationSound defaultSound];
                UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:content trigger:nil];
                [center addNotificationRequest:req withCompletionHandler:nil];
            };
            if (settings.authorizationStatus == UNAuthorizationStatusAuthorized ||
                settings.authorizationStatus == UNAuthorizationStatusProvisional) {
                deliver();
            } else if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
                [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                                      completionHandler:^(BOOL granted, NSError *err) {
                    if (granted) deliver();
                }];
            }
        }];
    });
}

- (void)whenConverterFree:(void (^)(void))go {
    // This job stops downloading now: let the next queued post start.
    dispatch_async(dispatch_get_main_queue(), ^{ TPStartNextJob(); });
    if (sConvertingJob && sConvertingJob != self) {
        if (!sConvertWaiters) sConvertWaiters = [NSMutableArray array];
        _stageDetail = TPL(@"Waiting to convert…");
        [_hud setProgress:-1 subtitle:_stageDetail];
        [self notifyManagerProgress:_stageDetail];
        __weak typeof(self) weak = self;
        [sConvertWaiters addObject:^{
            typeof(self) s = weak;
            if (!s || s->_cancelled) return;
            sConvertingJob = s;
            TPSetTranscodeIdleDisabled(YES);
            go();
        }];
        return;
    }
    sConvertingJob = self;
    TPSetTranscodeIdleDisabled(YES);
    go();
}

- (void)releaseConverter {
    if (sConvertingJob != self) return;
    sConvertingJob = nil;
    while (sConvertWaiters.count && !sConvertingJob) {
        void (^next)(void) = sConvertWaiters.firstObject;
        [sConvertWaiters removeObjectAtIndex:0];
        next();
    }
    if (!sConvertingJob) TPSetTranscodeIdleDisabled(NO);
}

- (void)cleanupDash {
    [self releaseConverter];
    if (_dashVideoFile) [NSFileManager.defaultManager removeItemAtURL:_dashVideoFile error:nil];
    if (_dashAudioFile) [NSFileManager.defaultManager removeItemAtURL:_dashAudioFile error:nil];
    _dashVideoFile = _dashAudioFile = nil;
    _dashStage = 0;
    _stageDetail = nil;
    _export = nil;
}

- (void)startDash {
    _dashStage = 1;
    _pendingFile = nil;
    _task = [_session downloadTaskWithURL:_items[_index][@"dashVideo"]];
    [_allTasks addObject:_task];
    [_task resume];
}

// Any DASH failure drops back to the progressive (720p) URLs of the same item.
- (void)dashFailed:(NSString *)why {
    if (_cancelled) return;
    if ([_items[_index][@"progressiveConvert"] boolValue]) {
        // The progressive file itself needed converting; downloading it again won't help.
        [self note:[@"convert: " stringByAppendingString:why]];
        [self cleanupDash];
        [self itemDone:NO];
        return;
    }
    [self note:[@"DASH → 720p: " stringByAppendingString:why]];
    [self cleanupDash];
    _urlIndex = 0;
    [self tryCurrent];
}

- (NSURL *)renamedPending:(NSString *)ext {
    NSURL *f = _pendingFile;
    _pendingFile = nil;
    if (!f) return nil;
    NSURL *dst = [NSURL fileURLWithPath:[f.path stringByAppendingPathExtension:ext]];
    return [NSFileManager.defaultManager moveItemAtURL:f toURL:dst error:nil] ? dst : nil;
}

- (void)dashTask:(NSURLSessionTask *)t completedWithError:(NSError *)error {
    if (error || !_pendingFile) {
        NSInteger code = [t.response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)t.response statusCode] : 0;
        [self dashFailed:[NSString stringWithFormat:@"%@ HTTP %ld %@", _dashStage == 1 ? @"video" : @"audio",
                          (long)code, error.localizedDescription ?: @""]];
        return;
    }
    if (_dashStage == 1) {
        _dashVideoFile = [self renamedPending:@"mp4"];
        if (!_dashVideoFile) { [self dashFailed:@"video file"]; return; }
        NSURL *audio = _items[_index][@"dashAudio"];
        if ([audio isKindOfClass:[NSURL class]]) {
            _dashStage = 2;
            _task = [_session downloadTaskWithURL:audio];
            [_allTasks addObject:_task];
            [_task resume];
            return;
        }
    } else if (_dashStage == 2) {
        _dashAudioFile = [self renamedPending:@"m4a"];
        if (!_dashAudioFile) { [self dashFailed:@"audio file"]; return; }
    }
    _dashStage = 3;
    [self whenConverterFree:^{ [self mergeDash]; }];
}

- (void)mergeDash {
    _dashStage = 3;
    NSString *audioCodec = _items[_index][@"dashAudioCodec"];
    BOOL audioNeedsEncode = _dashAudioFile && audioCodec.length && ![audioCodec hasPrefix:@"mp4a"];
    if ([_items[_index][@"dashTranscode"] boolValue] || audioNeedsEncode) { [self transcodeDash]; return; }
    CGFloat overall = ((CGFloat)_index + 0.98) / (CGFloat)_items.count;
    _itemFrac = 0.98;
    [_hud setProgress:overall subtitle:TPL(@"Merging video and audio…")];
    [_hud setRows:[self rows]];

    NSURL *vFile = _dashVideoFile, *aFile = _dashAudioFile;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        AVURLAsset *va = [AVURLAsset URLAssetWithURL:vFile options:@{ AVURLAssetPreferPreciseDurationAndTimingKey: @YES }];
        AVAssetTrack *vt = [va tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (!vt) { dispatch_async(dispatch_get_main_queue(), ^{ [self dashFailed:@"no video track"]; }); return; }

        AVMutableComposition *comp = [AVMutableComposition composition];
        AVMutableCompositionTrack *cv = [comp addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        CMTimeRange vr = vt.timeRange;
        if (![cv insertTimeRange:vr ofTrack:vt atTime:kCMTimeZero error:&err]) {
            NSString *why = [@"insert video: " stringByAppendingString:err.localizedDescription ?: @"?"];
            dispatch_async(dispatch_get_main_queue(), ^{ [self dashFailed:why]; });
            return;
        }
        cv.preferredTransform = vt.preferredTransform;

        if (aFile) {
            AVURLAsset *aa = [AVURLAsset URLAssetWithURL:aFile options:@{ AVURLAssetPreferPreciseDurationAndTimingKey: @YES }];
            AVAssetTrack *at = [aa tracksWithMediaType:AVMediaTypeAudio].firstObject;
            if (!at) { dispatch_async(dispatch_get_main_queue(), ^{ [self dashFailed:@"audio: no readable track"]; }); return; }
            CMTimeRange ar = at.timeRange;
            ar.duration = CMTimeMinimum(ar.duration, vr.duration);
            AVMutableCompositionTrack *ca = [comp addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            NSError *aerr = nil;
            if (![ca insertTimeRange:ar ofTrack:at atTime:kCMTimeZero error:&aerr]) {
                NSString *why = [@"insert audio: " stringByAppendingString:aerr.localizedDescription ?: @"?"];
                dispatch_async(dispatch_get_main_queue(), ^{ [self dashFailed:why]; });
                return;
            }
        }

        AVAssetExportSession *ex = [[AVAssetExportSession alloc] initWithAsset:comp presetName:AVAssetExportPresetPassthrough];
        NSString *type = [ex.supportedFileTypes containsObject:AVFileTypeMPEG4] ? AVFileTypeMPEG4 : AVFileTypeQuickTimeMovie;
        NSString *ext = [type isEqualToString:AVFileTypeMPEG4] ? @"mp4" : @"mov";
        NSURL *out = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                             [NSString stringWithFormat:@"threads_%@.%@", NSUUID.UUID.UUIDString, ext]]];
        ex.outputURL = out;
        ex.outputFileType = type;
        ex.shouldOptimizeForNetworkUse = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_cancelled) return;
            self->_export = ex;
            [ex exportAsynchronouslyWithCompletionHandler:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self->_cancelled) { [NSFileManager.defaultManager removeItemAtURL:out error:nil]; return; }
                    if (ex.status != AVAssetExportSessionStatusCompleted) {
                        [NSFileManager.defaultManager removeItemAtURL:out error:nil];
                        [self dashFailed:[@"export: " stringByAppendingString:ex.error.localizedDescription ?: @"?"]];
                        return;
                    }
                    [self dashMerged:out];
                });
            }];
        });
    });
}



- (void)dashMerged:(NSURL *)file {
    NSDictionary *item = _items[_index];
    if (_extraReport || [TPPrefs boolForKey:TPKeyDebugToast]) {
        NSDictionary *attr = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
        [_savedSizes addObject:[NSString stringWithFormat:@"#%ld DASH %@%@%@ %.1f MB", (long)_index + 1,
                                item[@"dashSize"] ?: @"?", [item[@"dashTranscode"] boolValue] ? [@" →" stringByAppendingString:TPTranscodeTarget(item[@"dashCodec"])] : @"", _dashAudioFile ? @" +audio" : @"", [attr fileSize] / 1048576.0]];
        if (!_extraReport) _extraReport = @"";
    }
    [self cleanupDash];
    if (!_allowPhotos) {
        [TPDownloadStore keepFile:file record:_recordID item:[self recordIndex]];
        [_leftovers addObject:file];
        _saved++;
        [self nextItem];
        return;
    }
    [self saveVideoFile:file completion:^(BOOL ok) {
        if (ok) { [self itemDone:YES]; return; }
        // Photos rejected the merged file: try the progressive MP4 instead.
        self->_urlIndex = 0;
        [self tryCurrent];
    }];
}

- (void)saveDecodedImageAt:(NSURL *)file magic:(NSString *)magic {
    UIImage *ui = [UIImage imageWithContentsOfFile:file.path];
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    NSData *jpeg = TPJPEGData(ui);
    if (!jpeg) {
        [self note:[NSString stringWithFormat:@"%@ can't decode", magic]];
        [self tryNextURL];
        return;
    }
    [self saveJPEGData:jpeg completion:^(BOOL ok, NSError *e) {
        if (ok) { [self itemDone:YES]; return; }
        [self note:[NSString stringWithFormat:@"%@ save jpeg: %@", magic, e.localizedDescription ?: @"?"]];
        [self tryNextURL];
    }];
}

- (void)saveJPEGData:(NSData *)jpeg completion:(void (^)(BOOL ok, NSError *e))completion {
    [TPDownloadStore keepData:jpeg extension:@"jpg" record:_recordID item:[self recordIndex]];
    [self performSave:^PHAssetChangeRequest *{
        return [self creationRequestWithType:PHAssetResourceTypePhoto file:nil data:jpeg ext:@"jpg"];
    } completion:completion];
}

- (void)tryNextURL {
    if (_cancelled) return;
    _urlIndex++;
    [self tryCurrent];
}

- (void)saveImage:(UIImage *)image {
    NSData *jpeg = TPJPEGData(image);
    if (!jpeg) { [self note:@"shown image: can't encode"]; [self itemDone:NO]; return; }
    [self saveJPEGData:jpeg completion:^(BOOL ok, NSError *e) {
        if (!ok) [self note:[NSString stringWithFormat:@"save shown image: %@", e.localizedDescription ?: @"?"]];
        [self itemDone:ok];
    }];
}

- (void)itemDone:(BOOL)ok {
    if (_cancelled) return;
    if (ok) _saved++; else _failed++;
    [self nextItem];
}

- (NSDate *)postDate {
    NSDictionary *rec = [TPDownloadStore recordWithID:_recordID];
    return TPDateFromShortcode([rec[@"code"] isKindOfClass:[NSString class]] ? rec[@"code"] : nil);
}

- (NSString *)fileNameWithExtension:(NSString *)ext {
    if (![TPPrefs boolForKey:TPKeyNameFromPost]) return nil;
    NSDictionary *rec = [TPDownloadStore recordWithID:_recordID];
    NSString *author = [rec[@"author"] isKindOfClass:[NSString class]] ? rec[@"author"] : nil;
    return [TPDownloader fileNameWithAuthor:author country:[TPAuthorInfo locationForUsername:author]
                                       date:[self postDate] ?: NSDate.date
                                       code:[rec[@"code"] isKindOfClass:[NSString class]] ? rec[@"code"] : nil
                                      index:[self recordIndex] count:(NSInteger)[rec[@"items"] count]
                                      label:([rec[@"kind"] isEqualToString:@"avatar"] || [rec[@"kind"] isEqualToString:@"cover"]) ? rec[@"kind"] : nil extension:ext];
}

- (PHAssetCreationRequest *)creationRequestWithType:(PHAssetResourceType)type file:(NSURL *)file data:(NSData *)data ext:(NSString *)ext {
    PHAssetCreationRequest *r = [PHAssetCreationRequest creationRequestForAsset];
    PHAssetResourceCreationOptions *o = nil;
    NSString *name = [self fileNameWithExtension:ext];
    if (name) { o = [PHAssetResourceCreationOptions new]; o.originalFilename = name; }
    if (file) [r addResourceWithType:type fileURL:file options:o];
    else [r addResourceWithType:type data:data options:o];
    return r;
}

- (void)performSave:(PHAssetChangeRequest *(^)(void))changes completion:(void (^)(BOOL ok, NSError *e))completion {
    __block NSString *assetID = nil;
    NSDate *postDate = [TPPrefs boolForKey:TPKeyPostDate] ? [self postDate] : nil;
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetChangeRequest *r = changes();
        if (postDate) r.creationDate = postDate;
        assetID = r.placeholderForCreatedAsset.localIdentifier;
    } completionHandler:^(BOOL ok, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_cancelled) return;
            if (ok && assetID) [self->_savedIDs addObject:assetID];
            completion(ok, e);
        });
    }];
}
@end

// ---- Software decode (VP9 via libvpx, AV1 via dav1d) + hardware re-encode ----
//
// Threads serves 1080p mostly as VP9 or AV1, which iPhones without those hardware decoders can't
// play from Photos. Frames are decoded in software and re-encoded with VideoToolbox:
// SDR → H.264 8-bit, HDR (HLG/PQ) → HEVC Main10 so the HDR look is kept. Audio is copied as-is.

typedef struct {
    BOOL hdr, tenBit;
    int cp, tc, mc;
} TPColorInfo;

// vp09.PP.LL.DD.CC.cp.tc.mc.FF   av01.P.LLT.DD.M.CCC.cp.tc.mc.F
static TPColorInfo TPColorFromCodec(NSString *codec) {
    TPColorInfo c = { NO, NO, 1, 1, 1 };
    NSArray<NSString *> *f = [codec componentsSeparatedByString:@"."];
    if ([codec hasPrefix:@"vp09"] && f.count >= 8) {
        c.tenBit = f[3].intValue > 8; c.cp = f[5].intValue; c.tc = f[6].intValue; c.mc = f[7].intValue;
    } else if ([codec hasPrefix:@"av01"] && f.count >= 9) {
        c.tenBit = f[3].intValue > 8; c.cp = f[6].intValue; c.tc = f[7].intValue; c.mc = f[8].intValue;
    }
    c.hdr = (c.tc == 16 || c.tc == 18);
    return c;
}

// Reads colour info from the downloaded file itself, for when the manifest's codec string is the
// short form without it (e.g. "vp09.00.40.08"). Looks in the MP4 init segment for, in order:
//   vpcC (VP9 config: primaries / transfer / matrix / bit depth)
//   av1C (AV1 config: its sequence header OBU, parsed with dav1d)
//   colr 'nclx' (generic colour box)
// Returns NO when none of them carry usable values (2 = "unspecified").
static BOOL TPColorFromFile(NSURL *file, TPColorInfo *out) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:file error:nil];
    NSData *head = [fh readDataOfLength:256 * 1024];
    [fh closeFile];
    const uint8_t *b = head.bytes;
    NSUInteger n = head.length;
    if (n < 16) return NO;

    __block int cp = 2, tc = 2, mc = 2, bits = 0;
    BOOL (^find)(const char *, NSUInteger *, NSUInteger *) = ^BOOL(const char *type, NSUInteger *payload, NSUInteger *len) {
        for (NSUInteger i = 4; i + 4 <= n; i++) {
            if (memcmp(b + i, type, 4) != 0) continue;
            uint32_t size = ((uint32_t)b[i - 4] << 24) | ((uint32_t)b[i - 3] << 16) | ((uint32_t)b[i - 2] << 8) | b[i - 1];
            if (size < 8 || i - 4 + size > n) continue;
            *payload = i + 4;
            *len = size - 8;
            return YES;
        }
        return NO;
    };

    NSUInteger p = 0, len = 0;
    if (find("vpcC", &p, &len) && len >= 10) {
        // version(1) flags(3) profile level bitDepth|chroma|range primaries transfer matrix
        bits = b[p + 6] >> 4;
        cp = b[p + 7]; tc = b[p + 8]; mc = b[p + 9];
    }
    if ((cp == 2 || tc == 2) && find("av1C", &p, &len) && len > 4) {
        Dav1dSequenceHeader seq;
        if (dav1d_parse_sequence_header(&seq, b + p + 4, len - 4) == 0) {
            cp = seq.pri; tc = seq.trc; mc = seq.mtrx;
            bits = seq.hbd == 0 ? 8 : (seq.hbd == 1 ? 10 : 12);
        } else {
            bits = (b[p + 2] & 0x40) ? ((b[p + 2] & 0x20) ? 12 : 10) : 8;
        }
    }
    if ((cp == 2 || tc == 2) && find("colr", &p, &len) && len >= 10 && memcmp(b + p, "nclx", 4) == 0) {
        cp = (b[p + 4] << 8) | b[p + 5];
        tc = (b[p + 6] << 8) | b[p + 7];
        mc = (b[p + 8] << 8) | b[p + 9];
    }
    if (cp == 2 && tc == 2 && mc == 2) return NO;
    TPColorInfo c = { NO, bits > 8, cp == 2 ? 1 : cp, tc == 2 ? 1 : tc, mc == 2 ? 1 : mc };
    c.hdr = (c.tc == 16 || c.tc == 18);
    *out = c;
    return YES;
}

// Colour for a downloaded DASH stream: the file's own boxes win when they say something, since
// they describe the actual bitstream; otherwise the manifest's codec string.
static TPColorInfo TPColorForDash(NSString *codec, NSURL *file, NSString **source) {
    TPColorInfo fromFile;
    if (file && TPColorFromFile(file, &fromFile)) { if (source) *source = @"file"; return fromFile; }
    if (source) *source = @"codec string";
    return TPColorFromCodec(codec ?: @"");
}

static NSString *TPTranscodeTarget(NSString *codec) {
    TPColorInfo c = TPColorFromCodec(codec ?: @"");
    if (c.hdr && [TPPrefs integerForKey:TPKeyVideoFormat] == 1) return @"H.264 SDR (from HDR)";
    return c.hdr ? [NSString stringWithFormat:@"HEVC 10-bit HDR (%@)", c.tc == 18 ? @"HLG" : @"PQ"] : @"H.264";
}

static NSDictionary *TPAVColorProps(TPColorInfo c) {
    NSString *prim = c.cp == 9 ? AVVideoColorPrimaries_ITU_R_2020 : (c.cp == 6 ? AVVideoColorPrimaries_SMPTE_C : AVVideoColorPrimaries_ITU_R_709_2);
    NSString *tf = c.tc == 18 ? AVVideoTransferFunction_ITU_R_2100_HLG
                 : c.tc == 16 ? AVVideoTransferFunction_SMPTE_ST_2084_PQ : AVVideoTransferFunction_ITU_R_709_2;
    NSString *mat = (c.mc == 9 || c.mc == 10) ? AVVideoYCbCrMatrix_ITU_R_2020 : (c.mc == 6 ? AVVideoYCbCrMatrix_ITU_R_601_4 : AVVideoYCbCrMatrix_ITU_R_709_2);
    return @{ AVVideoColorPrimariesKey: prim, AVVideoTransferFunctionKey: tf, AVVideoYCbCrMatrixKey: mat };
}

static void TPAttachColor(CVPixelBufferRef pb, TPColorInfo c) {
    CFStringRef prim = c.cp == 9 ? kCVImageBufferColorPrimaries_ITU_R_2020 : (c.cp == 6 ? kCVImageBufferColorPrimaries_SMPTE_C : kCVImageBufferColorPrimaries_ITU_R_709_2);
    CFStringRef tf = c.tc == 18 ? kCVImageBufferTransferFunction_ITU_R_2100_HLG
                   : c.tc == 16 ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2;
    CFStringRef mat = (c.mc == 9 || c.mc == 10) ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : (c.mc == 6 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, prim, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, tf, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, mat, kCVAttachmentMode_ShouldPropagate);
}

// Copies planar 4:2:0 (8-bit, or 16-bit storage holding srcBits) into an NV12 (8-bit) or
// x420 (10-bit in the high bits of 16) pixel buffer and appends it.
static void TPFillPlanar(CVPixelBufferRef pb, BOOL dst10,
                         const uint8_t *py, const uint8_t *pu, const uint8_t *pv,
                         ptrdiff_t sy, ptrdiff_t suv, int w, int h, int srcBits) {
    CVPixelBufferLockBaseAddress(pb, 0);
    size_t W = MIN((size_t)w, CVPixelBufferGetWidth(pb));
    size_t H = MIN((size_t)h, CVPixelBufferGetHeight(pb));
    size_t cw = (W + 1) / 2, ch = (H + 1) / 2;
    uint8_t *dY = CVPixelBufferGetBaseAddressOfPlane(pb, 0), *dUV = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t dsY = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), dsUV = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    BOOL src16 = srcBits > 8;

    if (!dst10 && !src16) {
        for (size_t y = 0; y < H; y++) memcpy(dY + y * dsY, py + y * sy, W);
        for (size_t y = 0; y < ch; y++) {
            const uint8_t *u = pu + y * suv, *v = pv + y * suv;
            uint8_t *d = dUV + y * dsUV;
            for (size_t x = 0; x < cw; x++) { d[2 * x] = u[x]; d[2 * x + 1] = v[x]; }
        }
    } else if (!dst10 && src16) {
        int sh = srcBits - 8;
        for (size_t y = 0; y < H; y++) {
            const uint16_t *s = (const uint16_t *)(py + y * sy); uint8_t *d = dY + y * dsY;
            for (size_t x = 0; x < W; x++) d[x] = (uint8_t)(s[x] >> sh);
        }
        for (size_t y = 0; y < ch; y++) {
            const uint16_t *u = (const uint16_t *)(pu + y * suv), *v = (const uint16_t *)(pv + y * suv);
            uint8_t *d = dUV + y * dsUV;
            for (size_t x = 0; x < cw; x++) { d[2 * x] = (uint8_t)(u[x] >> sh); d[2 * x + 1] = (uint8_t)(v[x] >> sh); }
        }
    } else {
        // x420: 10 significant bits in the top of each 16-bit sample.
        int sh = 16 - srcBits;
        for (size_t y = 0; y < H; y++) {
            uint16_t *d = (uint16_t *)(dY + y * dsY);
            if (src16) { const uint16_t *s = (const uint16_t *)(py + y * sy); for (size_t x = 0; x < W; x++) d[x] = (uint16_t)(s[x] << sh); }
            else       { const uint8_t  *s = py + y * sy;                     for (size_t x = 0; x < W; x++) d[x] = (uint16_t)(s[x] << 8); }
        }
        for (size_t y = 0; y < ch; y++) {
            uint16_t *d = (uint16_t *)(dUV + y * dsUV);
            if (src16) {
                const uint16_t *u = (const uint16_t *)(pu + y * suv), *v = (const uint16_t *)(pv + y * suv);
                for (size_t x = 0; x < cw; x++) { d[2 * x] = (uint16_t)(u[x] << sh); d[2 * x + 1] = (uint16_t)(v[x] << sh); }
            } else {
                const uint8_t *u = pu + y * suv, *v = pv + y * suv;
                for (size_t x = 0; x < cw; x++) { d[2 * x] = (uint16_t)(u[x] << 8); d[2 * x + 1] = (uint16_t)(v[x] << 8); }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

static BOOL TPAppendPB(AVAssetWriterInputPixelBufferAdaptor *adaptor, CVPixelBufferRef pb, CMTime pts, NSString **why) {
    BOOL ok = NO;
    @try {
        ok = [adaptor appendPixelBuffer:pb withPresentationTime:pts];
        if (!ok) *why = @"encode: append frame";
    } @catch (NSException *e) {
        *why = [@"encode: " stringByAppendingString:e.reason ?: e.name];
    }
    return ok;
}

// One software decoder instance, either libvpx (VP9) or dav1d (AV1).
@interface TPSoftDecoder : NSObject
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property (nonatomic, assign) BOOL dst10;
@property (nonatomic, assign) TPColorInfo color;
// "Compatible" output: HDR frames are converted to BT.709 SDR (8-bit) before H.264 encoding.
@property (nonatomic, assign) BOOL toneMap;
@property (nonatomic, assign) int32_t timescale;
@property (nonatomic, copy) NSString *error;
@property (nonatomic, weak) AVAssetWriter *writer;
@property (nonatomic, copy) BOOL (^shouldStop)(void);
- (instancetype)initWithCodec:(NSString *)codec;
// Hardware mode: the asset reader already decodes (VideoToolbox), samples carry pixel buffers.
- (instancetype)initHardware;
@property (nonatomic, readonly) BOOL hardware;
- (BOOL)decodeSample:(CMSampleBufferRef)sb;   // NO on error
- (BOOL)flush;
@end

@implementation TPSoftDecoder {
    BOOL _isAV1, _open, _hw;
    vpx_codec_ctx_t _vpx;
    Dav1dContext *_dav1d;
    int64_t _lastPTS;
    CVPixelBufferPoolRef _hdrPool;
    VTPixelTransferSessionRef _xfer;
}

- (instancetype)initWithCodec:(NSString *)codec {
    if (!(self = [super init])) return nil;
    _isAV1 = [codec hasPrefix:@"av01"];
    _lastPTS = INT64_MIN;
    int threads = (int)MIN(4, (NSInteger)NSProcessInfo.processInfo.activeProcessorCount);
    if (_isAV1) {
        Dav1dSettings s;
        dav1d_default_settings(&s);
        s.n_threads = threads;
        s.max_frame_delay = 2;
        if (dav1d_open(&_dav1d, &s) < 0) return nil;
    } else {
        vpx_codec_dec_cfg_t cfg = { .threads = (unsigned int)threads, .w = 0, .h = 0 };
        if (vpx_codec_dec_init(&_vpx, vpx_codec_vp9_dx(), &cfg, 0) != VPX_CODEC_OK) return nil;
    }
    _open = YES;
    return self;
}

- (instancetype)initHardware {
    if (!(self = [super init])) return nil;
    _hw = YES;
    _lastPTS = INT64_MIN;
    return self;
}
- (BOOL)hardware { return _hw; }

// Appends a frame the system decoder produced: colour-tagged as is when the format already fits
// the encoder, otherwise converted (bit depth, or HDR → SDR for the compatible format).
- (BOOL)emitPixelBuffer:(CVPixelBufferRef)src pts:(int64_t)pts {
    if (pts <= _lastPTS) pts = _lastPTS + 1;
    _lastPTS = pts;
    AVAssetWriterInput *input = _adaptor.assetWriterInput;
    for (int waited = 0; !input.isReadyForMoreMediaData; waited++) {
        if (_writer && _writer.status != AVAssetWriterStatusWriting) {
            _error = [NSString stringWithFormat:@"encode: writer status %ld %@", (long)_writer.status, _writer.error.localizedDescription ?: @""];
            return NO;
        }
        if (_shouldStop && _shouldStop()) { _error = @"cancelled"; return NO; }
        if (waited > 7500) { _error = @"encode: writer not ready (timeout)"; return NO; }
        usleep(2000);
    }
    TPAttachColor(src, _color);
    OSType want = _dst10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CVPixelBufferRef out = NULL;
    if (!_toneMap && CVPixelBufferGetPixelFormatType(src) == want) {
        out = CVPixelBufferRetain(src);
    } else {
        if (!_adaptor.pixelBufferPool || CVPixelBufferPoolCreatePixelBuffer(NULL, _adaptor.pixelBufferPool, &out) != kCVReturnSuccess) {
            _error = @"pixel buffer"; return NO;
        }
        if (!_xfer) {
            if (VTPixelTransferSessionCreate(NULL, &_xfer) != noErr) { CVPixelBufferRelease(out); _error = @"convert: session"; return NO; }
            if (_toneMap) {
                VTSessionSetProperty(_xfer, kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
                VTSessionSetProperty(_xfer, kVTPixelTransferPropertyKey_DestinationTransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
                VTSessionSetProperty(_xfer, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
            }
        }
        OSStatus st = VTPixelTransferSessionTransferImage(_xfer, src, out);
        if (st != noErr) { CVPixelBufferRelease(out); _error = [NSString stringWithFormat:@"convert: %d", (int)st]; return NO; }
        if (_toneMap) { TPColorInfo sdr = { NO, NO, 1, 1, 1 }; TPAttachColor(out, sdr); }
        else TPAttachColor(out, _color);
    }
    NSString *why = nil;
    BOOL ok = TPAppendPB(_adaptor, out, CMTimeMake(pts, _timescale), &why);
    CVPixelBufferRelease(out);
    if (!ok) _error = why;
    return ok;
}

- (void)dealloc {
    if (_xfer) { VTPixelTransferSessionInvalidate(_xfer); CFRelease(_xfer); }
    if (_hdrPool) CVPixelBufferPoolRelease(_hdrPool);
    if (!_open) return;
    if (_isAV1) dav1d_close(&_dav1d); else vpx_codec_destroy(&_vpx);
}

- (BOOL)emit:(const uint8_t *)y u:(const uint8_t *)u v:(const uint8_t *)v sy:(ptrdiff_t)sy suv:(ptrdiff_t)suv
           w:(int)w h:(int)h bits:(int)bits pts:(int64_t)pts {
    if (pts <= _lastPTS) pts = _lastPTS + 1;  // keep timestamps strictly increasing
    _lastPTS = pts;
    // A decoder can return several frames for one input (dav1d frame threading, flush), so the
    // writer may not be ready yet. Appending then throws, so wait for it here; audio is fed on its
    // own queue, which lets AVAssetWriter's interleaving make progress meanwhile.
    AVAssetWriterInput *input = _adaptor.assetWriterInput;
    for (int waited = 0; !input.isReadyForMoreMediaData; waited++) {
        if (_writer && _writer.status != AVAssetWriterStatusWriting) {
            _error = [NSString stringWithFormat:@"encode: writer status %ld %@", (long)_writer.status, _writer.error.localizedDescription ?: @""];
            return NO;
        }
        if (_shouldStop && _shouldStop()) { _error = @"cancelled"; return NO; }
        if (waited > 7500) { _error = @"encode: writer not ready (timeout)"; return NO; }  // ~15 s
        usleep(2000);
    }
    NSString *why = nil;
    CMTime t = CMTimeMake(pts, _timescale);
    CVPixelBufferRef out = NULL;
    if (!_adaptor.pixelBufferPool || CVPixelBufferPoolCreatePixelBuffer(NULL, _adaptor.pixelBufferPool, &out) != kCVReturnSuccess) {
        _error = @"pixel buffer"; return NO;
    }
    if (!_toneMap) {
        TPFillPlanar(out, _dst10, y, u, v, sy, suv, w, h, bits);
        TPAttachColor(out, _color);
    } else {
        // Fill a 10-bit buffer tagged with the source HDR colour, then let VideoToolbox convert
        // it into the 8-bit BT.709 buffer the H.264 encoder takes.
        if (!_hdrPool) {
            NSDictionary *attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                                     (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h),
                                     (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
            CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &_hdrPool);
        }
        if (!_xfer) {
            if (VTPixelTransferSessionCreate(NULL, &_xfer) != noErr) { CVPixelBufferRelease(out); _error = @"tone map: session"; return NO; }
            VTSessionSetProperty(_xfer, kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
            VTSessionSetProperty(_xfer, kVTPixelTransferPropertyKey_DestinationTransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
            VTSessionSetProperty(_xfer, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
        }
        CVPixelBufferRef hdr = NULL;
        if (!_hdrPool || CVPixelBufferPoolCreatePixelBuffer(NULL, _hdrPool, &hdr) != kCVReturnSuccess) {
            CVPixelBufferRelease(out); _error = @"tone map: buffer"; return NO;
        }
        TPFillPlanar(hdr, YES, y, u, v, sy, suv, w, h, bits);
        TPAttachColor(hdr, _color);
        OSStatus st = VTPixelTransferSessionTransferImage(_xfer, hdr, out);
        CVPixelBufferRelease(hdr);
        if (st != noErr) { CVPixelBufferRelease(out); _error = [NSString stringWithFormat:@"tone map: %d", (int)st]; return NO; }
        TPColorInfo sdr = { NO, NO, 1, 1, 1 };
        TPAttachColor(out, sdr);
    }
    BOOL ok = TPAppendPB(_adaptor, out, t, &why);
    CVPixelBufferRelease(out);
    if (!ok) _error = why;
    return ok;
}

- (BOOL)drainDav1d {
    for (;;) {
        Dav1dPicture p = {0};
        int r = dav1d_get_picture(_dav1d, &p);
        if (r == DAV1D_ERR(EAGAIN)) return YES;
        if (r < 0) { _error = [NSString stringWithFormat:@"dav1d: get_picture %d", r]; return NO; }
        BOOL ok = YES;
        if (p.p.layout != DAV1D_PIXEL_LAYOUT_I420) { _error = [NSString stringWithFormat:@"dav1d: layout %d", p.p.layout]; ok = NO; }
        else ok = [self emit:p.data[0] u:p.data[1] v:p.data[2] sy:p.stride[0] suv:p.stride[1]
                           w:p.p.w h:p.p.h bits:p.p.bpc pts:p.m.timestamp];
        dav1d_picture_unref(&p);
        if (!ok) return NO;
    }
}

- (BOOL)decodeSample:(CMSampleBufferRef)sb {
    if (_hw) {
        CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
        if (!pb) return YES;
        CMTime pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sb), _timescale, kCMTimeRoundingMethod_Default);
        return [self emitPixelBuffer:pb pts:pts.value];
    }
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
    if (!len) return YES;
    CMTime pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sb), _timescale, kCMTimeRoundingMethod_Default);

    if (_isAV1) {
        Dav1dData d = {0};
        uint8_t *dst = dav1d_data_create(&d, len);
        if (!dst || CMBlockBufferCopyDataBytes(bb, 0, len, dst) != kCMBlockBufferNoErr) {
            dav1d_data_unref(&d); _error = @"dav1d: read sample"; return NO;
        }
        d.m.timestamp = pts.value;
        do {
            int r = dav1d_send_data(_dav1d, &d);
            if (r < 0 && r != DAV1D_ERR(EAGAIN)) { dav1d_data_unref(&d); _error = [NSString stringWithFormat:@"dav1d: send %d", r]; return NO; }
            if (![self drainDav1d]) { dav1d_data_unref(&d); return NO; }
        } while (d.sz > 0);
        return YES;
    }

    NSMutableData *buf = [NSMutableData dataWithLength:len];
    if (CMBlockBufferCopyDataBytes(bb, 0, len, buf.mutableBytes) != kCMBlockBufferNoErr) { _error = @"libvpx: read sample"; return NO; }
    if (vpx_codec_decode(&_vpx, buf.bytes, (unsigned int)len, NULL, 0) != VPX_CODEC_OK) {
        _error = [NSString stringWithFormat:@"libvpx: %s", vpx_codec_error_detail(&_vpx) ?: vpx_codec_error(&_vpx)];
        return NO;
    }
    vpx_codec_iter_t iter = NULL;
    vpx_image_t *img;
    while ((img = vpx_codec_get_frame(&_vpx, &iter))) {
        int bits;
        if (img->fmt == VPX_IMG_FMT_I420) bits = 8;
        else if (img->fmt == VPX_IMG_FMT_I42016) bits = img->bit_depth > 8 ? (int)img->bit_depth : 16;
        else { _error = [NSString stringWithFormat:@"libvpx: format 0x%x", img->fmt]; return NO; }
        if (![self emit:img->planes[0] u:img->planes[1] v:img->planes[2] sy:img->stride[0] suv:img->stride[1]
                      w:(int)img->d_w h:(int)img->d_h bits:bits pts:pts.value]) return NO;
    }
    return YES;
}

- (BOOL)flush {
    if (_hw || !_isAV1) return YES;
    // dav1d may still hold frames; keep pulling until it has nothing left.
    for (int i = 0; i < 64; i++) {
        Dav1dPicture p = {0};
        int r = dav1d_get_picture(_dav1d, &p);
        if (r == DAV1D_ERR(EAGAIN)) return YES;
        if (r < 0) return YES;
        BOOL ok = p.p.layout == DAV1D_PIXEL_LAYOUT_I420 &&
                  [self emit:p.data[0] u:p.data[1] v:p.data[2] sy:p.stride[0] suv:p.stride[1] w:p.p.w h:p.p.h bits:p.p.bpc pts:p.m.timestamp];
        dav1d_picture_unref(&p);
        if (!ok) return NO;
    }
    return YES;
}
@end

static NSDictionary *TPHardwareOutputSettings(BOOL tenBit) {
    return @{ (id)kCVPixelBufferPixelFormatTypeKey: @(tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                                            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
              (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
}

// Whether the system decodes this track: hardware support reported, and a trial read yields a frame.
static BOOL TPCanHardwareDecode(AVAsset *asset, AVAssetTrack *track, BOOL tenBit) {
    if (![NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){ 17, 0, 0 }]) return NO;
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) return NO;
    AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:nil];
    AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:TPHardwareOutputSettings(tenBit)];
    if (!r || ![r canAddOutput:o]) return NO;
    [r addOutput:o];
    if (![r startReading]) return NO;
    BOOL ok = NO;
    for (int i = 0; i < 4 && !ok; i++) {
        CMSampleBufferRef sb = [o copyNextSampleBuffer];
        if (!sb) break;
        ok = CMSampleBufferGetImageBuffer(sb) != NULL;
        CFRelease(sb);
    }
    [r cancelReading];
    return ok;
}

@implementation TPDownloadJob (Transcode)

- (void)transcodeDash {
    NSURL *vFile = _dashVideoFile, *aFile = _dashAudioFile;
    NSInteger index = _index;
    NSString *codec = _items[_index][@"dashCodec"] ?: @"";
    // softVideo: VP9/AV1 decoded + re-encoded. Otherwise H.264/HEVC samples are copied as-is and
    // only the audio needs work (e.g. Opus → AAC).
    BOOL softVideo = [_items[_index][@"dashTranscode"] boolValue];
    if (softVideo) _didTranscode = YES;
    NSString *stepLabel = softVideo ? TPL(@"Converting video…") : TPL(@"Merging video and audio…");
    if (softVideo && _itemFrac > 0.5) _itemFrac = 0.5;
    _stageDetail = [NSString stringWithFormat:@"%@ 0%%", stepLabel];
    [self notifyManagerProgress:_stageDetail];
    __weak typeof(self) weak = self;
    _wentBackground = UIApplication.sharedApplication.applicationState == UIApplicationStateBackground;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        void (^fail)(NSString *) = ^(NSString *why) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) s = weak;
                if (!s) return;
                // iOS stops hardware video encoding once Threads is in the background. If that's
                // what broke the conversion, pick it up again when the user returns.
                if (s->_wentBackground && s->_resumeTries < 2 && !s->_cancelled) {
                    s->_resumeTries++;
                    [s note:[@"paused in background: " stringByAppendingString:why]];
                    s->_stageDetail = TPL(@"Paused — continues when you return to Threads");
                    [s->_hud setProgress:-1 subtitle:s->_stageDetail];
                    [s notifyManagerProgress:s->_stageDetail];
                    __block id obs = nil;
                    obs = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                                                                           queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                        [NSNotificationCenter.defaultCenter removeObserver:obs];
                        obs = nil;
                        typeof(self) s2 = weak;
                        if (s2 && !s2->_cancelled) [s2 transcodeDash];
                    }];
                    return;
                }
                [s dashFailed:why];
            });
        };
        NSError *err = nil;
        NSString *colorSource = nil;
        TPColorInfo color = TPColorForDash(codec, vFile, &colorSource);
        TPColorInfo fromCodec = TPColorFromCodec(codec);
        if (color.hdr != fromCodec.hdr || color.tc != fromCodec.tc) {
            NSString *msg = [NSString stringWithFormat:@"color from %@: cp %d tc %d mc %d (codec string: tc %d)",
                             colorSource, color.cp, color.tc, color.mc, fromCodec.tc];
            dispatch_async(dispatch_get_main_queue(), ^{ typeof(self) s0 = weak; if (s0) [s0->_savedSizes addObject:msg]; });
        }
        BOOL compat = [TPPrefs integerForKey:TPKeyVideoFormat] == 1;
        BOOL toneMap = softVideo && color.hdr && compat;
        BOOL hevc10 = softVideo && color.hdr && !compat;
        TPColorInfo outColor = color;
        if (toneMap) outColor = (TPColorInfo){ NO, NO, 1, 1, 1 };

        AVURLAsset *va = [AVURLAsset URLAssetWithURL:vFile options:@{ AVURLAssetPreferPreciseDurationAndTimingKey: @YES }];
        AVAssetTrack *vt = [va tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (!vt) { fail(@"transcode: no video track"); return; }

        TPSoftDecoder *dec = nil;
        NSDictionary *hwOutput = nil;
        if (softVideo && [codec hasPrefix:@"av01"] && TPCanHardwareDecode(va, vt, hevc10 || toneMap)) {
            // iPhone 15 Pro and later decode AV1 in hardware: much faster than dav1d, and cooler.
            dec = [[TPSoftDecoder alloc] initHardware];
            hwOutput = TPHardwareOutputSettings(hevc10 || toneMap);
        } else if (softVideo) {
            dec = [[TPSoftDecoder alloc] initWithCodec:codec];
            if (!dec) { fail([codec hasPrefix:@"av01"] ? @"dav1d: open" : @"libvpx: init"); return; }
        }
        if (dec.hardware) dispatch_async(dispatch_get_main_queue(), ^{ typeof(self) s0 = weak; if (s0) [s0->_savedSizes addObject:@"AV1: hardware decode"]; });
        dec.color = color;
        dec.dst10 = hevc10;
        dec.toneMap = toneMap;
        dec.timescale = vt.naturalTimeScale > 0 ? vt.naturalTimeScale : 90000;

        AVAssetReader *vr = [AVAssetReader assetReaderWithAsset:va error:&err];
        if (!vr) { fail([@"reader: " stringByAppendingString:err.localizedDescription ?: @"?"]); return; }
        AVAssetReaderTrackOutput *vo = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:vt outputSettings:hwOutput];
        vo.alwaysCopiesSampleData = NO;
        if (![vr canAddOutput:vo]) { fail(@"reader: can't add video output"); return; }
        [vr addOutput:vo];

        AVAssetReader *ar = nil;
        AVAssetReaderTrackOutput *ao = nil;
        AVAssetTrack *at = nil;
        // Audio: AAC is copied; anything else (Opus…) is decoded to PCM and encoded to AAC.
        // Never silently drop the audio — if it can't be handled, the whole DASH attempt falls back.
        BOOL audioCopy = YES;
        NSDictionary *aacSettings = nil;
        if (aFile) {
            AVURLAsset *aa = [AVURLAsset URLAssetWithURL:aFile options:nil];
            at = [aa tracksWithMediaType:AVMediaTypeAudio].firstObject;
            if (!at) { fail(@"audio: no readable track"); return; }
            CMAudioFormatDescriptionRef afd = (__bridge CMAudioFormatDescriptionRef)at.formatDescriptions.firstObject;
            FourCharCode sub = afd ? CMFormatDescriptionGetMediaSubType(afd) : 0;
            audioCopy = sub == kAudioFormatMPEG4AAC || sub == kAudioFormatMPEG4AAC_HE || sub == kAudioFormatMPEG4AAC_HE_V2
                     || sub == kAudioFormatMPEG4AAC_LD || sub == kAudioFormatMPEG4AAC_ELD;
            NSDictionary *pcm = nil;
            if (!audioCopy) {
                const AudioStreamBasicDescription *asbd = afd ? CMAudioFormatDescriptionGetStreamBasicDescription(afd) : NULL;
                NSInteger ch = asbd && asbd->mChannelsPerFrame > 0 ? MIN(2, (NSInteger)asbd->mChannelsPerFrame) : 2;
                double sr = asbd && asbd->mSampleRate > 0 ? MIN(48000.0, asbd->mSampleRate) : 48000.0;
                pcm = @{ AVFormatIDKey: @(kAudioFormatLinearPCM), AVNumberOfChannelsKey: @(ch), AVSampleRateKey: @(sr) };
                aacSettings = @{ AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVNumberOfChannelsKey: @(ch),
                                 AVSampleRateKey: @(sr), AVEncoderBitRateKey: @(ch > 1 ? 160000 : 96000) };
            }
            ar = [AVAssetReader assetReaderWithAsset:aa error:nil];
            ao = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:at outputSettings:pcm];
            if (!ar || ![ar canAddOutput:ao]) {
                fail([NSString stringWithFormat:@"audio: can't read '%c%c%c%c'", (char)(sub >> 24), (char)(sub >> 16), (char)(sub >> 8), (char)sub]);
                return;
            }
            [ar addOutput:ao];
        }

        NSURL *out = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                             [NSString stringWithFormat:@"threads_%@.%@", NSUUID.UUID.UUIDString, hevc10 ? @"mov" : @"mp4"]]];
        AVAssetWriter *w = [AVAssetWriter assetWriterWithURL:out fileType:hevc10 ? AVFileTypeQuickTimeMovie : AVFileTypeMPEG4 error:&err];
        if (!w) { fail([@"writer: " stringByAppendingString:err.localizedDescription ?: @"?"]); return; }
        w.shouldOptimizeForNetworkUse = YES;

        CGSize sz = vt.naturalSize;
        NSInteger W = (NSInteger)fabs(sz.width), H = (NSInteger)fabs(sz.height);
        NSInteger pixels = W * H;
        // ~7 Mbps (H.264) / ~5.5 Mbps (HEVC) at 1080x1920 — far above the 1.5–8 Mbps source.
        NSInteger bitrate = (NSInteger)(pixels * (hevc10 ? 2.7 : 3.5));
        bitrate = MAX(4000000, MIN(14000000, bitrate));
        float fps = vt.nominalFrameRate > 0 ? vt.nominalFrameRate : 30;
        NSMutableDictionary *compression = [@{
            AVVideoAverageBitRateKey: @(bitrate),
            AVVideoExpectedSourceFrameRateKey: @(fps),
            AVVideoMaxKeyFrameIntervalKey: @((NSInteger)(fps * 2)),
        } mutableCopy];
        compression[AVVideoProfileLevelKey] = hevc10 ? (__bridge NSString *)kVTProfileLevel_HEVC_Main10_AutoLevel
                                                     : AVVideoProfileLevelH264HighAutoLevel;
        AVAssetWriterInput *wv = softVideo
            ? [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
                  AVVideoCodecKey: hevc10 ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264,
                  AVVideoWidthKey: @(W),
                  AVVideoHeightKey: @(H),
                  AVVideoColorPropertiesKey: TPAVColorProps(outColor),
                  AVVideoCompressionPropertiesKey: compression,
              }]
            : [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:nil
                                               sourceFormatHint:(__bridge CMFormatDescriptionRef)vt.formatDescriptions.firstObject];
        wv.expectsMediaDataInRealTime = NO;
        wv.transform = vt.preferredTransform;
        if (![w canAddInput:wv]) { fail(@"writer: can't add video input"); return; }
        [w addInput:wv];
        if (dec) dec.adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:wv sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(hevc10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                                           : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(W),
            (id)kCVPixelBufferHeightKey: @(H),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        }];

        AVAssetWriterInput *wa = nil;
        if (ao) {
            CMFormatDescriptionRef hint = (__bridge CMFormatDescriptionRef)at.formatDescriptions.firstObject;
            wa = audioCopy ? [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:nil sourceFormatHint:hint]
                           : [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:aacSettings];
            wa.expectsMediaDataInRealTime = NO;
            if (![w canAddInput:wa]) { fail(audioCopy ? @"audio: writer rejected AAC copy" : @"audio: writer rejected AAC encode"); return; }
            [w addInput:wa];
        }

        if (![vr startReading]) { fail([@"read: " stringByAppendingString:vr.error.localizedDescription ?: @"?"]); return; }
        if (ar && ![ar startReading]) { fail([@"audio read: " stringByAppendingString:ar.error.localizedDescription ?: @"?"]); return; }
        if (![w startWriting]) { [vr cancelReading]; fail([@"encode: " stringByAppendingString:w.error.localizedDescription ?: @"?"]); return; }
        dec.writer = w;
        dec.shouldStop = ^BOOL { typeof(self) s3 = weak; return !s3 || s3->_cancelled; };
        [w startSessionAtSourceTime:vt.timeRange.start];

        double total = CMTimeGetSeconds(vt.timeRange.duration);
        double start = CMTimeGetSeconds(vt.timeRange.start);
        CMTime videoEnd = CMTimeRangeGetEnd(vt.timeRange);
        dispatch_group_t g = dispatch_group_create();
        __block BOOL aborted = NO;
        __block NSString *audioError = nil;
        __block CFAbsoluteTime lastUI = 0;

        dispatch_queue_t qv = dispatch_queue_create("tp.transcode.video", DISPATCH_QUEUE_SERIAL);
        dispatch_group_enter(g);
        __block BOOL videoDone = NO;
        void (^finishVideo)(BOOL) = ^(BOOL bad) {
            if (videoDone) return;
            videoDone = YES;
            if (bad) { aborted = YES; [vr cancelReading]; }
            [wv markAsFinished];
            dispatch_group_leave(g);
        };
        [wv requestMediaDataWhenReadyOnQueue:qv usingBlock:^{
            while (!videoDone && wv.isReadyForMoreMediaData) {
                typeof(self) strong = weak;
                if (!strong || strong->_cancelled) { finishVideo(YES); return; }
                CMSampleBufferRef sb = [vo copyNextSampleBuffer];
                if (!sb) { finishVideo(dec ? ![dec flush] : NO); return; }
                double t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb));
                BOOL ok = dec ? [dec decodeSample:sb] : [wv appendSampleBuffer:sb];
                CFRelease(sb);
                if (!ok) { finishVideo(YES); return; }
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (total > 0 && now - lastUI > 0.2) {
                    lastUI = now;
                    double f = MIN(1, MAX(0, (t - start) / total));
                    dispatch_async(dispatch_get_main_queue(), ^{
                        typeof(self) s2 = weak;
                        if (!s2 || s2->_cancelled) return;
                        CGFloat itemF = softVideo ? (0.50 + 0.50 * f) : (0.97 + 0.03 * f);
                        CGFloat overall = ((CGFloat)index + itemF) / (CGFloat)s2->_items.count;
                        s2->_itemFrac = itemF;
                        NSString *sub = [NSString stringWithFormat:@"%@ %.0f%%", stepLabel, f * 100];
                        s2->_stageDetail = sub;
                        [s2->_hud setProgress:overall subtitle:sub];
                        [s2->_hud setRows:[s2 rows]];
                        [s2 notifyManagerProgress:sub];
                    });
                }
            }
        }];

        if (wa) {
            dispatch_queue_t qa = dispatch_queue_create("tp.transcode.audio", DISPATCH_QUEUE_SERIAL);
            dispatch_group_enter(g);
            __block BOOL audioDone = NO;
            [wa requestMediaDataWhenReadyOnQueue:qa usingBlock:^{
                while (!audioDone && wa.isReadyForMoreMediaData) {
                    CMSampleBufferRef sb = aborted ? NULL : [ao copyNextSampleBuffer];
                    if (!sb && !aborted && ar.status == AVAssetReaderStatusFailed)
                        audioError = [@"audio decode: " stringByAppendingString:ar.error.localizedDescription ?: @"?"];
                    if (sb && CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb), videoEnd) >= 0) { CFRelease(sb); sb = NULL; }
                    BOOL ok = NO;
                    if (sb) {
                        ok = [wa appendSampleBuffer:sb];
                        if (!ok) audioError = [@"audio write: " stringByAppendingString:w.error.localizedDescription ?: @"?"];
                        CFRelease(sb);
                    }
                    if (!ok) { audioDone = YES; [ar cancelReading]; [wa markAsFinished]; dispatch_group_leave(g); return; }
                }
            }];
        }

        dispatch_group_notify(g, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (aborted || audioError || vr.status == AVAssetReaderStatusFailed || w.status == AVAssetWriterStatusFailed) {
                NSString *why = dec.error ?: audioError ?: vr.error.localizedDescription ?: w.error.localizedDescription ?: @"cancelled";
                [w cancelWriting];
                [NSFileManager.defaultManager removeItemAtURL:out error:nil];
                fail([@"transcode: " stringByAppendingString:why]);
                return;
            }
            [w finishWritingWithCompletionHandler:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) strong = weak;
                    if (!strong || strong->_cancelled) { [NSFileManager.defaultManager removeItemAtURL:out error:nil]; return; }
                    if (w.status != AVAssetWriterStatusCompleted) {
                        [NSFileManager.defaultManager removeItemAtURL:out error:nil];
                        [strong dashFailed:[@"finish: " stringByAppendingString:w.error.localizedDescription ?: @"?"]];
                        return;
                    }
                    [strong dashMerged:out];
                });
            }];
        });
    });
}
@end
