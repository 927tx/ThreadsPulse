#import <SafariServices/SafariServices.h>
// ThreadsPulse: hooks for Threads (com.burbn.barcelona).
//
// Class and selector names come from a class-dump of the Threads executable. Many of them
// are Swift classes, hooked by their mangled names. When Threads renames something the hook
// simply stops matching, so a broken feature fails quietly instead of crashing. Debug Hints
// in the settings shows which hooks are still firing.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <malloc/malloc.h>
#import "TPPrefs.h"
#import "TPURLCleaner.h"
#import "TPDownloader.h"
#import "TPDownloadManager.h"
#import "TPSettingsViewController.h"
#import "TPLocalization.h"
#import "TPUI.h"
#import "TPHUD.h"
#import "TPCapsule.h"
#import "TPVersion.h"
#import "TPSideloadFix.h"
#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import "TPWelcomeViewController.h"
#import "TPUpdateChecker.h"
#import "TPAuthorInfo.h"

// Swift classes have no usable headers, so methods called on them are declared here and
// `self` is cast to id or UIView * before use.
@interface NSObject (TPDecl)
- (void)tp_threeFingerLongPress:(id)gesture;
- (void)setPlaybackSpeed:(float)speed;
- (BOOL)isPlaying;
- (void)play;
- (void)pause;
- (void)setVolume:(float)volume rampTime:(float)time;
- (id)videoPlayer;
- (id)imageURLForWidth:(double)width;
@end

static NSURL *TPBestImageURLFromPhoto(id photo);
static NSMutableString *gTPSizeLog;
static NSInteger gTPSizeIndex;

static NSInteger gTPOwnPasteboardChange = -1;

static void TPDebugNow(NSString *msg) {
    if (![TPPrefs boolForKey:TPKeyDebugToast]) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [TPHUD toast:[@"[TP] " stringByAppendingString:msg]]; });
}

static void TPDebug(NSString *msg) {
    if (![TPPrefs boolForKey:TPKeyDebugToast]) return;
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 2.0) return;
    last = now;
    [TPHUD toast:[@"[TP] " stringByAppendingString:msg]];
}

static UIView *TPFindView(UIView *root, Class cls, int maxDepth) {
    if (!root || !cls || maxDepth < 0) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *f = TPFindView(sub, cls, maxDepth - 1);
        if (f) return f;
    }
    return nil;
}

static NSArray *TPCleanItems(NSArray *items) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];
    for (id it in items) {
        if ([it isKindOfClass:[NSURL class]])         [out addObject:[TPURLCleaner cleanURL:it]];
        else if ([it isKindOfClass:[NSString class]]) [out addObject:[TPURLCleaner cleanString:it]];
        else                                          [out addObject:it];
    }
    return out;
}

// Ads are blocked at three stages: the ad request, the sponsored items that come back, and
// the insertion into the feed. Any one stage is enough; the others cover Threads changing
// which path it uses.
// Today's count of ads kept out, for the card at the top of the settings page.
static void TPCountAds(id items) {
    NSInteger n = [items respondsToSelector:@selector(count)] ? (NSInteger)[items count] : 1;
    [TPPrefs recordBlockedAds:n];
}

%group Ads

%hook _TtC15IGBCNAdsManager15IGBCNAdsManager
- (void)startNewAdDeliveryWithSurfaceDelegate:(id)delegate sessionId:(id)sid analyticsModule:(id)module {
    if ([TPPrefs boolForKey:TPKeyBlockAds]) { TPDebug(TPL(@"Blocked an ad request")); return; }
    %orig;
}
- (void)processSponsoredItems:(id)items projectedItems:(id)projected analyticsModule:(id)module {
    if ([TPPrefs boolForKey:TPKeyBlockAds]) { TPCountAds(items); TPDebug(TPL(@"Dropped sponsored items")); return; }
    %orig;
}
%end

%hook _TtC15IGBCNAdsManager37BCNMainFeedAdsInsertionSurfaceHandler
- (void)adInsertionHandler:(id)handler shouldTryToInsertSponsoredItem:(id)item
          atInsertionIndex:(long long)index focusedIndex:(long long)focused insertionContext:(id)ctx {
    if ([TPPrefs boolForKey:TPKeyBlockAds]) { [TPPrefs recordBlockedAds:1]; TPDebug(TPL(@"Blocked ad insertion")); return; }
    %orig;
}
- (void)receivedSponsoredItems:(id)items intentAwareData:(id)data {
    if ([TPPrefs boolForKey:TPKeyBlockAds]) { TPCountAds(items); return; }
    %orig;
}
- (void)adPlatformDidDeliverSponsoredItem:(id)item atAdRequestIndex:(long long)index {
    if ([TPPrefs boolForKey:TPKeyBlockAds]) { [TPPrefs recordBlockedAds:1]; return; }
    %orig;
}
%end

// Ads between the replies of a thread page come through a separate path: the permalink's
// insertion interceptor (its name carries a file hash, the same in Threads 456 and 457).
%hook _TtC17BCNAdInsertionKitP33_E97DB50748E84759A32BD09B8A3DB09246BCNPermalinkAdsSynchronousInsertionInterceptor
- (void)fetchSponsoredItemsForHostUnitItemId:(id)itemId hostPosition:(long long)position adRequestType:(long long)type {
    if ([TPPrefs boolForKey:TPKeyBlockAds]) { TPDebug(TPL(@"Blocked an ad request")); return; }
    %orig;
}
- (void)receivedSponsoredItems:(id)items intentAwareData:(id)data {
    if ([TPPrefs boolForKey:TPKeyBlockAds]) { TPCountAds(items); TPDebug(TPL(@"Dropped sponsored items")); return; }
    %orig;
}
- (void)adPlatformDidDeliverSponsoredItem:(id)item atAdRequestIndex:(long long)index {
    if ([TPPrefs boolForKey:TPKeyBlockAds]) { [TPPrefs recordBlockedAds:1]; return; }
    %orig;
}
- (void)adInsertionHandler:(id)handler shouldTryToInsertSponsoredItem:(id)item
          atInsertionIndex:(long long)index focusedIndex:(long long)focused insertionContext:(id)ctx {
    if ([TPPrefs boolForKey:TPKeyBlockAds]) { [TPPrefs recordBlockedAds:1]; TPDebug(TPL(@"Blocked ad insertion")); return; }
    %orig;
}
%end

%hook IGAdFetcherManager
- (void)adFetcher:(id)fetcher didReturnAdsResponse:(id)response paginationInfo:(id)info
  requestMetadata:(id)meta isFromCache:(BOOL)cache adRequestExtraInfo:(id)extra {
    if ([TPPrefs boolForKey:TPKeyBlockAds]) return;
    %orig;
}
%end

%end

%group Tracking

%hook UIPasteboard
- (void)setURL:(NSURL *)url {
    NSURL *c = [TPURLCleaner cleanURL:url];
    if (![c isEqual:url]) TPDebug(TPL(@"Cleaned tracking from copied link"));
    %orig(c);
    gTPOwnPasteboardChange = [(UIPasteboard *)self changeCount];
}
- (void)setString:(NSString *)string {
    %orig([TPURLCleaner cleanString:string]);
    gTPOwnPasteboardChange = [(UIPasteboard *)self changeCount];
}
- (void)setItems:(NSArray<NSDictionary<NSString *, id> *> *)items {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in items) {
        NSMutableDictionary *nd = [NSMutableDictionary dictionary];
        [d enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
            if ([v isKindOfClass:[NSURL class]])         nd[k] = [TPURLCleaner cleanURL:v];
            else if ([v isKindOfClass:[NSString class]]) nd[k] = [TPURLCleaner cleanString:v];
            else                                         nd[k] = v;
        }];
        [out addObject:nd];
    }
    %orig(out);
    gTPOwnPasteboardChange = [(UIPasteboard *)self changeCount];
}
%end

%hook UIActivityViewController
- (instancetype)initWithActivityItems:(NSArray *)items applicationActivities:(NSArray *)acts {
    return %orig(TPCleanItems(items), acts);
}
%end

%hook IGExternalURLIntentTarget
- (id)initWithTargetURL:(NSURL *)url mediaPk:(id)mediaPk authorPk:(id)authorPk {
    return %orig([TPURLCleaner cleanURL:url], mediaPk, authorPk);
}
%end

%hook UIApplication
- (void)openURL:(NSURL *)url options:(NSDictionary *)opts completionHandler:(void (^)(BOOL))handler {
    %orig([TPURLCleaner cleanURL:url], opts, handler);
}
%end

%end

static Class TPFeedMediaCellClass(void) {
    static Class c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"_TtC16BCNFeedMediaCell16BCNFeedMediaCell"); });
    return c;
}

static Class TPVideoViewClass(void) {
    static Class c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"_TtC11IGVideoView11IGVideoView"); });
    return c;
}

static BOOL TPInsideFeedMediaCell(UIView *v) {
    Class c = TPFeedMediaCellClass();
    if (!c) return NO;
    for (UIView *s = v.superview; s; s = s.superview) if ([s isKindOfClass:c]) return YES;
    return NO;
}

// Single-video download button.
// IGVideoView is a Swift class whose methods Threads calls directly, bypassing ObjC dispatch.
// The button is attached from UIKit methods that always go through ObjC (didMoveToWindow,
// layoutSubviews), and the video URL is only resolved when the button is tapped.
static const void *kTPButtonKey = &kTPButtonKey;
static const void *kTPPlayerKey = &kTPPlayerKey;

static const void *kTPPlayerViewKey = &kTPPlayerViewKey;

@interface TPWeakBox : NSObject
@property (nonatomic, weak) id object;
@end
@implementation TPWeakBox
@end

static void TPPauseIfHeld(id player);

static id TPInnerPlayer(id player) {
    if (![player respondsToSelector:@selector(videoPlayer)]) return player;
    id inner = [player videoPlayer];
    return inner ?: player;
}

static inline void TPRememberPlayer(id view, id player) {
    if (!player || objc_getAssociatedObject(view, kTPPlayerKey) == player) return;
    objc_setAssociatedObject(view, kTPPlayerKey, player, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TPWeakBox *box = [TPWeakBox new];
    box.object = view;
    objc_setAssociatedObject(player, kTPPlayerViewKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id inner = TPInnerPlayer(player);
    if (inner != player) objc_setAssociatedObject(inner, kTPPlayerViewKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIViewController *TPLightboxController(UIView *v);
static NSDictionary *TPPostContextForView(UIView *v);
static void TPShowPostTextActions(UIView *cell, NSString *author, UIView *anchor);

// Long-press menu entry shared by every download button.
static TPMenuItem *TPManagerMenuItem(void) {
    return [TPMenuItem itemWithKey:@"Download Manager" symbol:@"tray.full" handler:^{ [TPDownloadManagerViewController present]; }];
}

static void TPEnsureVideoButton(UIView *host) {
    UIButton *b = objc_getAssociatedObject(host, kTPButtonKey);
    CGSize sz = host.bounds.size;
    // Full-screen (lightbox) pages have their own button in the top bar, next to Threads' controls.
    BOOL want = host.window && [TPPrefs boolForKey:TPKeyShowDownloadBtn] && sz.width >= 120 && sz.height >= 120
                && !TPInsideFeedMediaCell(host) && !TPLightboxController(host);
    if (!want) { b.hidden = YES; return; }

    const CGFloat d = 38;
    if (!b) {
        __weak UIView *weakHost = host;
        b = [TPUI circleButtonWithSymbol:@"arrow.down.to.line" diameter:d onTap:^{
            UIView *v = weakHost;
            if (!v) return;
            id player = objc_getAssociatedObject(v, kTPPlayerKey);
            NSURL *url = [TPDownloader bestVideoURLNearView:v];
            if (!url) url = [TPDownloader bestURLFromVideoView:v player:player];
            NSDictionary *dash = [TPDownloader dashInfoFromVideoView:v player:player];
            if (!url && !dash) {
                if ([TPPrefs boolForKey:TPKeyDebugToast])
                    [TPDownloader showReport:[TPDownloader debugReportForVideoView:v player:player]];
                else
                    [TPHUD toast:TPL(@"No download link found. Play the video for a moment, then try again.")];
                return;
            }
            [TPDownloader downloadVideoURL:url dash:dash context:TPPostContextForView(v)];
        } menuItems:@[TPManagerMenuItem()]];
        [host addSubview:b];
        objc_setAssociatedObject(host, kTPButtonKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TPDebug(TPL(@"Download button added"));
    }
    b.hidden = NO;
    b.frame = CGRectMake(sz.width - d - 10, 10, d, d);
    if (host.subviews.lastObject != b) [host bringSubviewToFront:b];
}

%group Download

%hook _TtC11IGVideoView11IGVideoView

- (void)videoPlayerDidPrepare:(id)player { %orig; TPRememberPlayer(self, player); }
- (void)videoPlayerDidInitialPlay:(id)player { %orig; TPRememberPlayer(self, player); TPPauseIfHeld(player); }
- (void)videoPlayerDidReadyToDisplay:(id)player { %orig; TPRememberPlayer(self, player); }
- (void)videoPlayer:(id)player didLoadVideoInView:(id)view playbackReason:(long long)reason { %orig; TPRememberPlayer(self, player); }
- (void)videoPlayer:(id)player didUpdateLoadingProgress:(double)progress { %orig; TPRememberPlayer(self, player); }
- (void)videoPlayer:(id)player didUpdatePlaybackProgress:(double)progress { %orig; TPRememberPlayer(self, player); }

- (void)didMoveToWindow {
    %orig;
    TPEnsureVideoButton((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    TPEnsureVideoButton((UIView *)self);
}

%end

%end

// Batch download for a whole post (photos and videos).
static const void *kTPBatchBtnKey = &kTPBatchBtnKey;

static void TPCollectImageViews(UIView *v, NSMutableArray<UIImageView *> *out, int depth) {
    if (v.hidden || v.alpha < 0.01 || depth > 30) return;
    if ([v isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)v;
        // Wide strips (e.g. a 1080×150 text banner, ~55 pt tall on screen) count too, while
        // avatars and icons (small on both sides) don't.
        CGFloat w = iv.bounds.size.width, h = iv.bounds.size.height;
        if (iv.image && ((w >= 100 && h >= 100) || (MAX(w, h) >= 200 && MIN(w, h) >= 30))) [out addObject:iv];
    }
    for (UIView *s in v.subviews) TPCollectImageViews(s, out, depth + 1);
}

static UIImageView *TPLargestImageView(UIView *host) {
    NSMutableArray<UIImageView *> *all = [NSMutableArray array];
    TPCollectImageViews(host, all, 0);
    UIImageView *best = nil;
    CGFloat bestArea = 0;
    for (UIImageView *iv in all) {
        CGFloat a = iv.bounds.size.width * iv.bounds.size.height;
        if (a > bestArea) { best = iv; bestArea = a; }
    }
    return best;
}

static NSURL *TPURLForImageView(UIImageView *iv) {
    id spec = [TPDownloader safeValue:iv key:@"imageSpecifier"];
    if (!spec) return nil;
    id imgURL = [TPDownloader ivarValue:spec name:@"_remoteImage_imageURL"];
    if (!imgURL) imgURL = [TPDownloader ivarValue:spec name:@"_prefetchedAdaptiveRemoteImageDEPRECATED_imageURL"];
    id u = [TPDownloader safeValue:imgURL key:@"url"];
    return [u isKindOfClass:[NSURL class]] ? u : nil;
}

static NSString *TPDedupeKey(NSURL *u) {
    return [[u.path lastPathComponent] stringByDeletingPathExtension];
}

static NSURL *TPVideoURLFromMedia(id media) {
    if (!media) return nil;
    for (NSString *key in @[@"video", @"computedVideo"]) {
        id video = [TPDownloader safeValue:media key:key];
        NSURL *u = [TPDownloader bestURLFromObject:video];
        if (u) return u;
    }
    return [TPDownloader bestURLFromObject:media];
}

static NSDictionary *TPVideoItem(NSURL *url, NSDictionary *dash) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:dash ?: @{}];
    d[@"video"] = @YES;
    d[@"urls"] = url ? @[url] : @[];
    d[@"key"] = url ? TPDedupeKey(url) : [(NSURL *)dash[@"dashVideo"] absoluteString];
    return d;
}

static NSURL *TPImageURLFromMedia(id media) {
    if (!media) return nil;
    for (NSString *key in @[@"photo", @"computedPhoto"]) {
        id photo = [TPDownloader safeValue:media key:key];
        NSURL *best = TPBestImageURLFromPhoto(photo);
        if (best) return best;
        if (!photo || ![photo respondsToSelector:@selector(imageURLForWidth:)]) continue;

        double w = 4096;
        id sizeVal = [TPDownloader safeValue:photo key:@"size"];
        if ([sizeVal isKindOfClass:[NSValue class]]) {
            CGSize sz = [(NSValue *)sizeVal CGSizeValue];
            if (sz.width > 0) w = sz.width;
        }
        id imgURL = nil;
        @try { imgURL = [photo imageURLForWidth:w]; } @catch (__unused id e) {}
        id u = [imgURL isKindOfClass:[NSURL class]] ? imgURL : [TPDownloader safeValue:imgURL key:@"url"];
        if ([u isKindOfClass:[NSURL class]]) return u;
    }
    return nil;
}

static NSDictionary *TPItemForMediaCell(UIView *cell) {
    id fragment = [TPDownloader ivarValue:cell name:@"mediaFragment"];

    static Class videoCellClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ videoCellClass = NSClassFromString(@"_TtC16BCNFeedMediaCell21BCNFeedMediaVideoCell"); });
    UIView *vv = TPFindView(cell, TPVideoViewClass(), 30);
    BOOL isVideo = vv != nil || (videoCellClass && [cell isKindOfClass:videoCellClass]);

    if (isVideo) {
        NSURL *url = nil;
        NSDictionary *dash = nil;
        if (vv) {
            id player = objc_getAssociatedObject(vv, kTPPlayerKey);
            url = [TPDownloader bestURLFromVideoView:vv player:player];
            dash = [TPDownloader dashInfoFromVideoView:vv player:player];
        }
        if (!dash) dash = [TPDownloader dashInfoFromObject:fragment];
        if (!url) url = TPVideoURLFromMedia(fragment);
        if (!url && fragment) url = [TPDownloader bestVideoURLHarvestedFromObject:fragment];
        if (!url && !dash) {
            TPDebug([NSString stringWithFormat:@"video fragment: %@", fragment ? NSStringFromClass([fragment class]) : @"nil"]);
            return @{ @"video": @YES, @"failed": @YES };
        }
        return TPVideoItem(url, dash);
    }

    UIImageView *iv = TPLargestImageView(cell);
    NSURL *url = TPImageURLFromMedia(fragment);
    if (!url && iv) url = TPURLForImageView(iv);
    if (!url && fragment) url = [TPDownloader bestImageURLHarvestedFromObject:fragment];
    if (!url && !iv.image) {
        TPDebug([NSString stringWithFormat:@"photo fragment: %@", fragment ? NSStringFromClass([fragment class]) : @"nil"]);
        return nil;
    }

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"video"] = @NO;
    d[@"urls"] = url ? @[url] : @[];
    if (iv.image) d[@"image"] = iv.image;
    d[@"key"] = url ? TPDedupeKey(url) : [NSString stringWithFormat:@"img%p", iv.image];
    return d;
}

static NSDictionary *TPItemForMedia(id media) {
    if (!media) return nil;
    id video = [TPDownloader safeValue:media key:@"video"];
    if (!video) video = [TPDownloader safeValue:media key:@"computedVideo"];
    if (video) {
        NSURL *u = TPVideoURLFromMedia(media);
        if (!u) u = [TPDownloader bestVideoURLHarvestedFromObject:media];
        NSDictionary *dash = [TPDownloader dashInfoFromObject:media];
        if (!u && !dash) return @{ @"video": @YES, @"failed": @YES };
        return TPVideoItem(u, dash);
    }
    NSURL *u = TPImageURLFromMedia(media);
    if (!u) u = [TPDownloader bestImageURLHarvestedFromObject:media];
    if (!u) return @{ @"video": @NO, @"failed": @YES };
    return @{ @"video": @NO, @"urls": (u ? @[u] : @[]), @"key": TPDedupeKey(u) };
}

static NSString *gTPLastMediaDiag;

static void TPCollectMediaItemCells(UIView *v, NSMutableArray<UIView *> *out, int depth) {
    if (!v || depth > 12) return;
    if ([TPDownloader ivarValue:v name:@"mediaFragment"]) { [out addObject:v]; return; }
    for (UIView *s in v.subviews) TPCollectMediaItemCells(s, out, depth + 1);
}

static NSString *TPDescribeCount(id obj) {
    if (!obj) return @"nil";
    if ([obj respondsToSelector:@selector(count)]) return [NSString stringWithFormat:@"%lu", (unsigned long)[obj count]];
    return NSStringFromClass([obj class]);
}

static NSString *TPDiagForMedia(id media, NSInteger index) {
    id video = [TPDownloader safeValue:media key:@"video"] ?: [TPDownloader safeValue:media key:@"computedVideo"];
    NSData *dash = [TPDownloader safeValue:video key:@"dashManifestData"];
    NSMutableString *r = [NSMutableString string];
    [r appendFormat:@"#%ld %@\n", (long)index + 1, media ? NSStringFromClass([media class]) : @"nil"];
    [r appendFormat:@"  video: %@\n", video ? NSStringFromClass([video class]) : @"nil"];
    [r appendFormat:@"  videoVersions: %@\n", TPDescribeCount([TPDownloader safeValue:video key:@"videoVersions"])];
    [r appendFormat:@"  allVideoURLs: %@\n", TPDescribeCount([TPDownloader safeValue:video key:@"allVideoURLs"])];
    [r appendFormat:@"  dash: %@\n", [dash isKindOfClass:[NSData class]] ? [NSString stringWithFormat:@"%lu bytes", (unsigned long)dash.length] : @"nil"];
    [r appendFormat:@"  photo: %@\n", [TPDownloader safeValue:media key:@"photo"] ? @"yes" : @"nil"];
    return r;
}

static NSArray<NSDictionary *> *TPCollectPostMediaFromModel(UIView *cellRoot) {
    NSMutableArray<UIView *> *itemCells = [NSMutableArray array];
    TPCollectMediaItemCells(cellRoot, itemCells, 0);
    UIView *itemCell = itemCells.firstObject;
    if (!itemCell) return nil;

    id frag   = [TPDownloader ivarValue:itemCell name:@"mediaFragment"];
    id parent = [TPDownloader ivarValue:itemCell name:@"parentMediaFragment"];
    if (!parent) parent = [TPDownloader safeValue:frag key:@"carouselParent"];

    NSArray *children = [TPDownloader safeValue:parent key:@"carouselMedia"];
    if (![children isKindOfClass:[NSArray class]] || !children.count) children = [TPDownloader safeValue:frag key:@"carouselMedia"];
    if (![children isKindOfClass:[NSArray class]] || !children.count) children = frag ? @[frag] : @[];

    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableString *diag = [NSMutableString string];
    NSInteger idx = 0;
    for (id child in children) {
        NSDictionary *d = TPItemForMedia(child);

        if ([d[@"failed"] boolValue]) {
            for (UIView *c in itemCells) {
                if ([TPDownloader ivarValue:c name:@"mediaFragment"] != child) continue;
                NSDictionary *fromCell = TPItemForMediaCell(c);
                if (fromCell && ![fromCell[@"failed"] boolValue]) d = fromCell;
                break;
            }
        }
        if ([d[@"failed"] boolValue]) [diag appendString:TPDiagForMedia(child, idx)];
        idx++;

        if (!d) continue;
        NSString *key = d[@"key"];
        if (key) { if ([seen containsObject:key]) continue; [seen addObject:key]; }
        [items addObject:d];
    }
    gTPLastMediaDiag = diag.length
        ? [NSString stringWithFormat:@"ThreadsPulse %@\nparent: %@\nchildren: %lu\n\n%@",
           [TP_VERSION stringByAppendingString:@" [model]"], parent ? NSStringFromClass([parent class]) : @"nil", (unsigned long)children.count, diag]
        : nil;
    TPDebug([NSString stringWithFormat:TPL(@"Found %ld of %ld items"), (long)items.count, (long)children.count]);
    return items;
}

// Media is read from the carousel cell's `items` (BCNFeedMediaViewModel -> IGPhoto / IGVideo)
// rather than from visible cells, so items that are scrolled away or reused are still found.
// The view model's `kind` is a Swift enum; pointers and classes are validated before reading it.
// Whether a class pointer read from memory is `base` or a subclass of it. Every class on the
// chain must lie inside a loaded image, so a stray pointer is never followed.
// objc_copyClassList is avoided: it loads every class in Threads at once, and on iOS 16 some of
// them need newer system code and crash while loading.
static BOOL TPIsaInFamily(uintptr_t isa, Class base) {
    if (!base || !isa) return NO;
    static CFMutableDictionaryRef cache;
    if (!cache) cache = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    const void *key = (const void *)(isa ^ (uintptr_t)(__bridge void *)base);
    const void *hit = CFDictionaryGetValue(cache, key);
    if (hit) return hit == (const void *)2;
    BOOL found = NO;
    Class k = (__bridge Class)(void *)isa;
    for (int i = 0; k && i < 64; i++) {
        Dl_info info;
        if (!dladdr((__bridge const void *)k, &info) || !info.dli_fname) break;
        if (k == base) { found = YES; break; }
        k = class_getSuperclass(k);
    }
    if (CFDictionaryGetCount(cache) > 4096) CFDictionaryRemoveAllValues(cache);
    CFDictionarySetValue(cache, key, found ? (const void *)2 : (const void *)1);
    return found;
}

static Class TPPhotoClasses(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"IGPhoto"); });
    return c;
}
static Class TPVideoClasses(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"IGVideo"); });
    return c;
}

static id TPObjectFromWord(uintptr_t w, Class base) {
    uintptr_t p = w & 0x0000000FFFFFFFF8ULL;
    if (p < 0x100000000ULL || !base) return nil;
    if (!malloc_zone_from_ptr((const void *)p)) return nil;
    uintptr_t isa = *(const uintptr_t *)p & 0x0000000FFFFFFFF8ULL;
    if (!TPIsaInFamily(isa, base)) return nil;
    return (__bridge id)(void *)p;
}

static uint8_t *TPIvarAddress(id obj, const char *name) {
    if (!obj) return NULL;
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) return (uint8_t *)(__bridge void *)obj + ivar_getOffset(iv);
    }
    return NULL;
}

static double TPNumber(id v) {
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0;
}

static NSURL *TPBestImageURLFromPhoto(id photo) {
    if (!photo) return nil;
    NSURL *best = nil;
    double bestArea = -1;
    NSMutableArray<NSString *> *sizes = [NSMutableArray array];
    for (NSString *ivar in @[@"_originalImageVersions", @"_processedImageVersions"]) {
        NSArray *vers = [TPDownloader ivarValue:photo name:ivar];
        if (![vers isKindOfClass:[NSArray class]]) continue;
        for (id v in vers) {
            NSURL *u = [v isKindOfClass:[NSURL class]] ? v : [TPDownloader safeValue:v key:@"url"];
            if (![u isKindOfClass:[NSURL class]]) continue;
            double w = TPNumber([TPDownloader safeValue:v key:@"width"]);
            double h = TPNumber([TPDownloader safeValue:v key:@"height"]);
            if (w <= 0 || h <= 0) {
                id info = [TPDownloader safeValue:v key:@"imageURLInfo"];
                w = TPNumber([TPDownloader safeValue:info key:@"width"]);
                h = TPNumber([TPDownloader safeValue:info key:@"height"]);
            }
            double area = (w > 0 && h > 0) ? w * h : [TPDownloader imageAreaFromURL:u];
            if (area > bestArea) { best = u; bestArea = area; }
            if (gTPSizeLog) {
                [sizes addObject:(w > 0 ? [NSString stringWithFormat:@"%.0fx%.0f", w, h]
                                        : [NSString stringWithFormat:@"?(%@)", NSStringFromClass([v class])])];
            }
        }
    }
    if (gTPSizeLog && sizes.count) {
        [gTPSizeLog appendFormat:@"#%ld %@\n", (long)++gTPSizeIndex, [sizes componentsJoinedByString:@", "]];
    }
    return best;
}

static NSURL *TPImageURLFromPhoto(id photo) {
    NSURL *best = TPBestImageURLFromPhoto(photo);
    if (best) return best;
    if (!photo || ![photo respondsToSelector:@selector(imageURLForWidth:)]) return nil;
    double w = 4096;
    id sizeVal = [TPDownloader safeValue:photo key:@"size"];
    if ([sizeVal isKindOfClass:[NSValue class]]) {
        CGSize sz = [(NSValue *)sizeVal CGSizeValue];
        if (sz.width > 0) w = sz.width;
    }
    id imgURL = nil;
    @try { imgURL = [photo imageURLForWidth:w]; } @catch (__unused id e) {}
    id u = [imgURL isKindOfClass:[NSURL class]] ? imgURL : [TPDownloader safeValue:imgURL key:@"url"];
    return [u isKindOfClass:[NSURL class]] ? u : nil;
}

static NSString *TPDiagForVideo(id video, NSInteger index) {
    NSData *dash = [TPDownloader safeValue:video key:@"dashManifestData"];
    return [NSString stringWithFormat:@"#%ld video: %@\n  videoVersions: %@\n  allVideoURLs: %@\n  dash: %@\n",
            (long)index + 1, video ? NSStringFromClass([video class]) : @"nil",
            TPDescribeCount([TPDownloader safeValue:video key:@"videoVersions"]),
            TPDescribeCount([TPDownloader safeValue:video key:@"allVideoURLs"]),
            [dash isKindOfClass:[NSData class]] ? [NSString stringWithFormat:@"%lu bytes", (unsigned long)dash.length] : @"nil"];
}

static NSArray<NSDictionary *> *TPCollectPostMediaFromViewModels(UIView *cellRoot) {
    id vms = [TPDownloader ivarValue:cellRoot name:@"items"];
    if (![vms isKindOfClass:[NSArray class]] || ![(NSArray *)vms count]) return nil;

    NSMutableArray<UIView *> *itemCells = [NSMutableArray array];
    TPCollectMediaItemCells(cellRoot, itemCells, 0);

    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableString *diag = [NSMutableString string];
    NSInteger idx = -1, recognized = 0;

    for (id vm in (NSArray *)vms) {
        idx++;
        uint8_t *kind = TPIvarAddress(vm, "kind");
        if (!kind) continue;
        uintptr_t w0 = ((uintptr_t *)kind)[0], w1 = ((uintptr_t *)kind)[1];
        id video = TPObjectFromWord(w0, TPVideoClasses()) ?: TPObjectFromWord(w1, TPVideoClasses());
        id photo = video ? nil : (TPObjectFromWord(w0, TPPhotoClasses()) ?: TPObjectFromWord(w1, TPPhotoClasses()));
        if (!video && !photo) continue;
        recognized++;

        NSDictionary *d = nil;
        if (video) {
            NSURL *u = [TPDownloader bestURLFromObject:video] ?: [TPDownloader bestVideoURLHarvestedFromObject:video];
            NSDictionary *dash = [TPDownloader dashInfoFromObject:video];
            if (!u && dash) {
                d = TPVideoItem(nil, dash);
            } else if (!u) {
                for (UIView *c in itemCells) {
                    uint8_t *mi = TPIvarAddress(c, "mediaIndex");
                    if (!mi || mi[8] != 0 || *(NSInteger *)mi != idx) continue;
                    NSDictionary *fromCell = TPItemForMediaCell(c);
                    if (fromCell && ![fromCell[@"failed"] boolValue]) d = fromCell;
                    break;
                }
                if (!d) { d = @{ @"video": @YES, @"failed": @YES }; [diag appendString:TPDiagForVideo(video, idx)]; }
            } else {
                d = TPVideoItem(u, dash);
            }
        } else {
            NSURL *u = TPImageURLFromPhoto(photo);
            d = u ? @{ @"video": @NO, @"urls": (u ? @[u] : @[]), @"key": TPDedupeKey(u) }
                  : @{ @"video": @NO, @"failed": @YES };
        }

        NSString *key = d[@"key"];
        if (key) { if ([seen containsObject:key]) continue; [seen addObject:key]; }
        [items addObject:d];
    }
    if (!recognized) return nil;

    gTPLastMediaDiag = diag.length
        ? [NSString stringWithFormat:@"ThreadsPulse %@ [items]\nitems: %lu\n\n%@", TP_VERSION, (unsigned long)[(NSArray *)vms count], diag]
        : nil;
    TPDebug([NSString stringWithFormat:TPL(@"Found %ld of %ld items"), (long)items.count, (long)[(NSArray *)vms count]]);
    return items;
}

static NSArray<NSDictionary *> *TPCollectPostMedia(UIView *cellRoot) {
    NSArray *items = TPCollectPostMediaFromViewModels(cellRoot);
    return items.count ? items : TPCollectPostMediaFromModel(cellRoot);
}

// Original-size photos: the app only receives resized versions, so the post page on
// threads.com is fetched and the largest candidate is matched by file name.
static NSString *TPShortcodeFromPK(NSString *pk) {
    pk = [[pk componentsSeparatedByString:@"_"] firstObject];
    unsigned long long n = strtoull(pk.UTF8String, NULL, 10);
    if (!n) return nil;
    static const char *alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    NSMutableString *s = [NSMutableString string];
    while (n) { [s insertString:[NSString stringWithFormat:@"%c", alpha[n % 64]] atIndex:0]; n /= 64; }
    return s;
}

static NSString *TPCodeFromMedia(id media) {
    if (!media) return nil;
    id code = [TPDownloader safeValue:media key:@"code"];
    if ([code isKindOfClass:[NSString class]] && [code length]) return code;
    return nil;
}

static NSString *TPPostCodeForCell(UIView *cellRoot) {
    NSMutableArray<UIView *> *itemCells = [NSMutableArray array];
    TPCollectMediaItemCells(cellRoot, itemCells, 0);
    for (UIView *c in itemCells) {
        id frag = [TPDownloader ivarValue:c name:@"mediaFragment"];
        id parent = [TPDownloader ivarValue:c name:@"parentMediaFragment"] ?: [TPDownloader safeValue:frag key:@"carouselParent"];
        NSString *code = TPCodeFromMedia(parent);
        if (code) return code;
        id parentId = [TPDownloader safeValue:frag key:@"carouselParentId"];
        if ([parentId isKindOfClass:[NSString class]] && [parentId length]) return TPShortcodeFromPK(parentId);
        if (!parent) { code = TPCodeFromMedia(frag); if (code) return code; }
    }

    UICollectionViewCell *curCell = [cellRoot isKindOfClass:[UICollectionViewCell class]] ? (UICollectionViewCell *)cellRoot : nil;
    for (UIView *v = cellRoot.superview; v; v = v.superview) {
        if ([v isKindOfClass:[UICollectionViewCell class]]) { curCell = (UICollectionViewCell *)v; continue; }
        if (![v isKindOfClass:[UICollectionView class]] || !curCell) continue;
        UICollectionView *feed = (UICollectionView *)v;
        NSIndexPath *ip = [feed indexPathForCell:curCell];
        if (!ip) continue;
        for (UICollectionViewCell *c in feed.visibleCells) {
            NSIndexPath *cip = [feed indexPathForCell:c];
            if (!cip || cip.section != ip.section) continue;
            for (NSString *ivarName in @[@"parentMediaFragment", @"cellMediaFragment", @"mediaFragment"]) {
                id m = [TPDownloader ivarValue:c name:ivarName];
                if (!m) continue;
                id parent = [TPDownloader safeValue:m key:@"carouselParent"];
                NSString *code = TPCodeFromMedia(parent) ?: TPCodeFromMedia(m);
                if (code) return code;
                id pid = [TPDownloader safeValue:m key:@"carouselParentId"] ?: [TPDownloader safeValue:parent key:@"pk"] ?: [TPDownloader safeValue:m key:@"pk"];
                if ([pid isKindOfClass:[NSString class]] && [pid length]) {
                    NSString *sc = TPShortcodeFromPK(pid);
                    if (sc.length) return sc;
                }
            }
        }
    }

    id vms = [TPDownloader ivarValue:cellRoot name:@"items"];
    if ([vms isKindOfClass:[NSArray class]] && [(NSArray *)vms count] == 1) {
        uint8_t *kind = TPIvarAddress([(NSArray *)vms firstObject], "kind");
        if (kind) {
            uintptr_t w0 = ((uintptr_t *)kind)[0], w1 = ((uintptr_t *)kind)[1];
            id photo = TPObjectFromWord(w0, TPPhotoClasses()) ?: TPObjectFromWord(w1, TPPhotoClasses());
            id mid = [TPDownloader safeValue:photo key:@"mediaID"];
            if ([mid isKindOfClass:[NSString class]]) return TPShortcodeFromPK(mid);
        }
    }
    return nil;
}

static NSString *TPUnescapeJSONText(NSString *s) {
    for (int i = 0; i < 3; i++) {
        NSString *before = s;
        s = [s stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
        s = [s stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
        s = [s stringByReplacingOccurrencesOfString:@"\\u0026" withString:@"&"];
        s = [s stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
        if ([s isEqualToString:before]) break;
    }
    return [s stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
}

static NSString *TPHTMLSummary(NSString *html) {
    NSMutableString *r = [NSMutableString string];
    for (NSString *k in @[@"image_versions2", @"candidates", @"cdninstagram", @"fbcdn", @"og:image", @"\"width\"", @"login"]) {
        NSUInteger n = [html componentsSeparatedByString:k].count - 1;
        [r appendFormat:@"%@:%lu ", k, (unsigned long)n];
    }
    NSRange cdn = [html rangeOfString:@"cdninstagram"];
    if (cdn.location == NSNotFound) cdn = [html rangeOfString:@"fbcdn"];
    if (cdn.location != NSNotFound) {
        NSUInteger start = cdn.location > 160 ? cdn.location - 160 : 0;
        NSUInteger len = MIN((NSUInteger)360, html.length - start);
        NSString *snip = [[html substringWithRange:NSMakeRange(start, len)] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        [r appendFormat:@"\n  …%@…", snip];
    }
    return r;
}

static NSDictionary<NSString *, NSURL *> *TPOriginalsFromHTML(NSString *rawHTML, NSInteger *candidateCount, BOOL avatars) {
    NSString *html = TPUnescapeJSONText(rawHTML);
    NSMutableDictionary<NSString *, NSURL *> *best = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *area = [NSMutableDictionary dictionary];
    static NSRegularExpression *objRe, *wRe, *hRe, *uRe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        objRe = [NSRegularExpression regularExpressionWithPattern:@"\\{[^{}]{0,2000}?\"url\":\"https:[^\"]+\"[^{}]{0,2000}?\\}" options:0 error:nil];
        wRe = [NSRegularExpression regularExpressionWithPattern:@"\"width\":(\\d+)" options:0 error:nil];
        hRe = [NSRegularExpression regularExpressionWithPattern:@"\"height\":(\\d+)" options:0 error:nil];
        uRe = [NSRegularExpression regularExpressionWithPattern:@"\"url\":\"(https:[^\"]+)\"" options:0 error:nil];
    });
    NSInteger count = 0;
    for (NSTextCheckingResult *m in [objRe matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *obj = [html substringWithRange:m.range];
        NSTextCheckingResult *w = [wRe firstMatchInString:obj options:0 range:NSMakeRange(0, obj.length)];
        NSTextCheckingResult *h = [hRe firstMatchInString:obj options:0 range:NSMakeRange(0, obj.length)];
        NSTextCheckingResult *u = [uRe firstMatchInString:obj options:0 range:NSMakeRange(0, obj.length)];
        if (!w || !h || !u) continue;
        NSString *raw = [obj substringWithRange:[u rangeAtIndex:1]];
        raw = [raw stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
        raw = [raw stringByReplacingOccurrencesOfString:@"\\u0026" withString:@"&"];
        raw = [raw stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
        NSURL *url = [NSURL URLWithString:raw];
        if (!url) continue;
        NSString *path = url.path.lowercaseString;
        if ([path hasSuffix:@".mp4"]) continue;
        if ([path containsString:@"-19/"] != avatars) continue;
        double a = [[obj substringWithRange:[w rangeAtIndex:1]] doubleValue] * [[obj substringWithRange:[h rangeAtIndex:1]] doubleValue];
        count++;
        NSString *key = TPDedupeKey(url);
        if (a > [area[key] doubleValue]) { area[key] = @(a); best[key] = url; }
    }
    static NSRegularExpression *ogRe, *ogW, *ogH;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{
        ogRe = [NSRegularExpression regularExpressionWithPattern:@"<meta[^>]+property=\"og:image\"[^>]+content=\"([^\"]+)\"" options:NSRegularExpressionCaseInsensitive error:nil];
        ogW  = [NSRegularExpression regularExpressionWithPattern:@"property=\"og:image:width\"[^>]+content=\"(\\d+)\"" options:NSRegularExpressionCaseInsensitive error:nil];
        ogH  = [NSRegularExpression regularExpressionWithPattern:@"property=\"og:image:height\"[^>]+content=\"(\\d+)\"" options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSTextCheckingResult *og = [ogRe firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (og) {
        NSURL *url = [NSURL URLWithString:[html substringWithRange:[og rangeAtIndex:1]]];
        if (url && [url.path.lowercaseString containsString:@"-19/"] == avatars) {
            NSTextCheckingResult *w = [ogW firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
            NSTextCheckingResult *h = [ogH firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
            double a = (w && h) ? [[html substringWithRange:[w rangeAtIndex:1]] doubleValue] * [[html substringWithRange:[h rangeAtIndex:1]] doubleValue] : 1;
            NSString *key = TPDedupeKey(url);
            count++;
            if (a > [area[key] doubleValue]) { area[key] = @(a); best[key] = url; }
        }
    }
    if (candidateCount) *candidateCount = count;
    return best;
}

static BOOL TPItemsHaveImage(NSArray<NSDictionary *> *items) {
    for (NSDictionary *d in items) if (![d[@"video"] boolValue]) return YES;
    return NO;
}

static void TPUpgradeFromPage(NSURL *page, BOOL avatars, NSString *label, NSString *hudTitle,
                              NSArray<NSDictionary *> *items, void (^done)(NSArray<NSDictionary *> *));

static void TPUpgradeToOriginals(NSString *code, NSArray<NSDictionary *> *items, void (^done)(NSArray<NSDictionary *> *)) {
    BOOL hasImage = TPItemsHaveImage(items);
    if (!hasImage) { done(items); return; }
    if (!code) {
        [TPDownloader appendPendingReport:@"[original] post code not found\n"];
        done(items);
        return;
    }
    NSURL *page = [NSURL URLWithString:[@"https://www.threads.com/t/" stringByAppendingString:code]];
    TPUpgradeFromPage(page, NO, [@"code " stringByAppendingString:code], TPL(@"Getting original photos…"), items, done);
}

static void TPUpgradeFromPage(NSURL *page, BOOL avatars, NSString *label, NSString *hudTitle,
                              NSArray<NSDictionary *> *items, void (^done)(NSArray<NSDictionary *> *)) {
    __block BOOL finished = NO;
    __block NSURLSessionDataTask *task = nil;
    TPCapsule *hud = [TPCapsule showWithTitle:hudTitle cancel:^{
        finished = YES;
        [task cancel];
    }];
    [hud setProgress:-1 subtitle:@""];
    void (^finish)(NSArray *) = ^(NSArray *result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (finished) return;
            finished = YES;
            [hud dismiss];
            done(result);
        });
    };

    NSArray<NSString *> *agents = @[
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
        @"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
    ];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    NSMutableString *log = [NSMutableString string];

    __block void (^attempt)(NSUInteger) = nil;
    attempt = ^(NSUInteger idx) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:page cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
        [req setValue:agents[idx] forHTTPHeaderField:@"User-Agent"];
        [req setValue:@"text/html,application/xhtml+xml" forHTTPHeaderField:@"Accept"];
        [req setValue:@"zh-TW,zh;q=0.9,en;q=0.8" forHTTPHeaderField:@"Accept-Language"];
        [req setValue:@"navigate" forHTTPHeaderField:@"Sec-Fetch-Mode"];
        task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (finished) { attempt = nil; return; }
            NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
            NSString *html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            NSInteger cands = 0;
            NSDictionary<NSString *, NSURL *> *originals = html ? TPOriginalsFromHTML(html, &cands, avatars) : @{};
            [log appendFormat:@"[original] %@ · HTTP %ld · %lu KB · candidates %ld%@\n",
                 idx == 0 ? @"desktop" : @"mobile", (long)status, (unsigned long)data.length / 1024, (long)cands,
                 err ? [@" · " stringByAppendingString:err.localizedDescription] : @""];
            if (html && !cands) [log appendFormat:@"  %@\n", TPHTMLSummary(html)];

            if (!originals.count && idx + 1 < agents.count) {
                attempt(idx + 1);
                return;
            }
            attempt = nil;

            NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
            NSInteger upgraded = 0, images = 0;
            for (NSDictionary *d in items) {
                if ([d[@"video"] boolValue]) { [out addObject:d]; continue; }
                images++;
                NSURL *orig = d[@"key"] ? originals[d[@"key"]] : nil;
                if (!orig && !avatars && originals.count == 1 && items.count == 1) orig = originals.allValues.firstObject;
                NSArray *urls = d[@"urls"];
                if (orig && ![urls containsObject:orig]) {
                    NSMutableDictionary *nd = [d mutableCopy];
                    nd[@"urls"] = [@[orig] arrayByAddingObjectsFromArray:urls ?: @[]];
                    [out addObject:nd];
                    upgraded++;
                } else {
                    [out addObject:d];
                }
            }
            [log appendFormat:@"[original] %@ · matched %ld/%ld\n", label, (long)upgraded, (long)images];
            [TPDownloader appendPendingReport:log];
            finish(out);
        }];
        [task resume];
    };
    attempt(0);
}

static NSString *TPAuthorFromMedia(id media) {
    if (!media) return nil;
    for (NSString *k in @[@"user", @"owner"]) {
        id owner = [TPDownloader safeValue:media key:k];
        id u = [TPDownloader safeValue:owner key:@"username"];
        if ([u isKindOfClass:[NSString class]] && [u length]) return u;
        for (NSString *pkKey in @[@"pk", @"userPk", @"id"]) {
            id pk = [TPDownloader safeValue:owner key:pkKey];
            NSString *pkStr = [pk isKindOfClass:[NSString class]] ? pk : ([pk isKindOfClass:[NSNumber class]] ? [pk stringValue] : nil);
            NSString *cached = pkStr.length ? [TPAuthorInfo usernameForPk:pkStr] : nil;
            if (cached.length) return cached;
        }
    }
    for (NSString *pkKey in @[@"userPk", @"ownerPk", @"userId"]) {
        id pk = [TPDownloader safeValue:media key:pkKey];
        NSString *pkStr = [pk isKindOfClass:[NSString class]] ? pk : ([pk isKindOfClass:[NSNumber class]] ? [pk stringValue] : nil);
        NSString *cached = pkStr.length ? [TPAuthorInfo usernameForPk:pkStr] : nil;
        if (cached.length) return cached;
    }
    return nil;
}

static Class TPFeedHeaderClass(void) {
    static Class c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"_TtC21BCNFeedItemHeaderCell32BCNFeedItemHeaderCellContentView"); });
    return c;
}

static void TPCollectHeaders(UIView *v, NSMutableArray<UIView *> *out, int depth) {
    if (!v || depth > 9) return;
    if ([v isKindOfClass:TPFeedHeaderClass()]) { [out addObject:v]; return; }
    for (UIView *s in v.subviews) TPCollectHeaders(s, out, depth + 1);
}

// The post header (avatar + @author) closest above the media: a post's header always sits right
// above its photos or video, whichever cells the feed splits them into.
static UIView *TPHeaderAboveView(UIView *media) {
    UIWindow *w = media.window;
    if (!w || !TPFeedHeaderClass()) return nil;
    CGFloat top = CGRectGetMinY([media convertRect:media.bounds toView:w]);
    for (UIView *p = media.superview; p; p = p.superview) {
        if (![p isKindOfClass:[UICollectionView class]]) continue;
        NSMutableArray<UIView *> *headers = [NSMutableArray array];
        for (UICollectionViewCell *c in [(UICollectionView *)p visibleCells]) TPCollectHeaders(c, headers, 0);
        UIView *best = nil;
        CGFloat bestGap = CGFLOAT_MAX;
        for (UIView *h in headers) {
            if (!h.window || h.hidden) continue;
            CGFloat bottom = CGRectGetMaxY([h convertRect:h.bounds toView:w]);
            CGFloat gap = top - bottom;
            if (gap >= -4 && gap < bestGap) { bestGap = gap; best = h; }
        }
        // Beyond a screen's height it belongs to another post.
        if (best && bestGap < w.bounds.size.height) return best;
    }
    return nil;
}

// A quoted post inside another post (BCNFeedNestedPostCell) has its own author, text and code.
// Media downloaded from inside the quote belongs to the quoted post, not the one quoting it.
static UIView *TPNestedPostAncestor(UIView *v) {
    static Class nestedCls, quoteCls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        nestedCls = objc_getClass("_TtC21BCNFeedNestedPostCell21BCNFeedNestedPostCell");
        quoteCls = objc_getClass("_TtC21BCNFeedNestedPostCell22BCNFeedNestedQuoteCell");
    });
    int depth = 0;
    for (UIView *p = v; p && depth < 14; p = p.superview, depth++) {
        if ((nestedCls && [p isKindOfClass:nestedCls]) || (quoteCls && [p isKindOfClass:quoteCls])) return p;
        if ([p isKindOfClass:[UICollectionView class]] && depth > 0 && !p.superview) break;
    }
    return nil;
}

// @{ author, code, text } of the quoted post (any may be missing).
static NSDictionary *TPNestedPostInfo(UIView *nested) {
    if (!nested) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    id media = [TPDownloader ivarValue:nested name:@"media"];
    if (media) {
        id user = [TPDownloader safeValue:media key:@"user"];
        id name = user ? [TPDownloader safeValue:user key:@"username"] : nil;
        if ([name isKindOfClass:[NSString class]] && [name length]) out[@"author"] = name;
        id code = [TPDownloader safeValue:media key:@"code"];
        if ([code isKindOfClass:[NSString class]] && [code length]) out[@"code"] = code;
        id cap = [TPDownloader safeValue:media key:@"caption"];
        id text = [cap isKindOfClass:[NSString class]] ? cap : [TPDownloader safeValue:cap key:@"text"];
        if ([text isKindOfClass:[NSString class]] && [text length]) out[@"text"] = text;
    }
    return out;
}

// Post code and author for the download history (either may be missing).
static NSDictionary *TPPostContextForCell(UIView *cellRoot) {
    NSMutableDictionary *ctx = [NSMutableDictionary dictionaryWithObject:@"post" forKey:@"kind"];
    if (!cellRoot) return ctx;
    NSDictionary *quoted = TPNestedPostInfo(TPNestedPostAncestor(cellRoot));
    if ([quoted[@"author"] length]) {
        ctx[@"author"] = quoted[@"author"];
        if ([quoted[@"code"] length]) ctx[@"code"] = quoted[@"code"];
        return ctx;
    }
    NSString *code = TPPostCodeForCell(cellRoot);
    UIView *header = TPHeaderAboveView(cellRoot);
    NSDictionary *info = header ? [TPAuthorInfo postInfoInHeader:header] : nil;

    // Check if header shares the same outer feed section (carousel/child media can have a different
    // media code from the outer post header, so don't discard a same-section header's author).
    BOOL headerSameSection = NO;
    if (header) {
        UICollectionViewCell *curCell = [cellRoot isKindOfClass:[UICollectionViewCell class]] ? (UICollectionViewCell *)cellRoot : nil;
        for (UIView *v = cellRoot.superview; v; v = v.superview) {
            if ([v isKindOfClass:[UICollectionViewCell class]]) { curCell = (UICollectionViewCell *)v; continue; }
            if ([v isKindOfClass:[UICollectionView class]] && curCell) {
                UICollectionView *cv = (UICollectionView *)v;
                NSIndexPath *ip = [cv indexPathForCell:curCell];
                if (ip && [header isDescendantOfView:cv]) {
                    for (UIView *hv = header; hv && hv != cv; hv = hv.superview) {
                        if ([hv isKindOfClass:[UICollectionViewCell class]]) {
                            NSIndexPath *hip = [cv indexPathForCell:(UICollectionViewCell *)hv];
                            if (hip && hip.section == ip.section) headerSameSection = YES;
                            break;
                        }
                    }
                }
            }
        }
    }

    NSString *headerCode = info[@"code"] ?: ([info[@"mediaId"] length] ? TPShortcodeFromPK(info[@"mediaId"]) : nil);
    if (code && headerCode && ![code isEqualToString:headerCode] && !headerSameSection) info = nil;
    if (!code) code = info[@"code"];
    if (!code && [info[@"mediaId"] length]) code = TPShortcodeFromPK(info[@"mediaId"]);
    if (code) ctx[@"code"] = code;

    NSString *author = info[@"author"];
    if (!author) {
        NSMutableArray<UIView *> *itemCells = [NSMutableArray array];
        TPCollectMediaItemCells(cellRoot, itemCells, 0);
        for (UIView *c in itemCells) {
            id frag = [TPDownloader ivarValue:c name:@"mediaFragment"];
            id parent = [TPDownloader ivarValue:c name:@"parentMediaFragment"] ?: [TPDownloader safeValue:frag key:@"carouselParent"];
            author = TPAuthorFromMedia(parent) ?: TPAuthorFromMedia(frag);
            if (author) break;
        }
    }
    // Walk ALL ancestor UICollectionViews (not just an inner horizontal carousel) to inspect
    // same-section visible cells and headers in the outer feed.
    if (!author || !code.length) {
        UICollectionViewCell *curCell = [cellRoot isKindOfClass:[UICollectionViewCell class]] ? (UICollectionViewCell *)cellRoot : nil;
        for (UIView *v = cellRoot.superview; v && (!author || !code.length); v = v.superview) {
            if ([v isKindOfClass:[UICollectionViewCell class]]) { curCell = (UICollectionViewCell *)v; continue; }
            if (![v isKindOfClass:[UICollectionView class]] || !curCell) continue;
            UICollectionView *feed = (UICollectionView *)v;
            NSIndexPath *ip = [feed indexPathForCell:curCell];
            if (!ip) continue;
            for (UICollectionViewCell *c in feed.visibleCells) {
                NSIndexPath *cip = [feed indexPathForCell:c];
                if (!cip || cip.section != ip.section) continue;
                for (NSString *ivarName in @[@"parentMediaFragment", @"cellMediaFragment", @"mediaFragment"]) {
                    id m = [TPDownloader ivarValue:c name:ivarName];
                    author = TPAuthorFromMedia([TPDownloader safeValue:m key:@"carouselParent"]) ?: TPAuthorFromMedia(m);
                    if (author) break;
                }
                if (author) break;
                NSMutableArray<UIView *> *hdrs = [NSMutableArray array];
                TPCollectHeaders(c, hdrs, 0);
                for (UIView *h in hdrs) {
                    NSDictionary *hi = [TPAuthorInfo postInfoInHeader:h];
                    if (!code.length) {
                        code = hi[@"code"] ?: ([hi[@"mediaId"] length] ? TPShortcodeFromPK(hi[@"mediaId"]) : nil);
                        if (code.length) ctx[@"code"] = code;
                    }
                    NSString *ha = hi[@"author"];
                    if (ha.length) { author = ha; break; }
                }
                if (author) break;
            }
        }
    }
    if (!author && code.length) author = [TPAuthorInfo authorForPostCode:code];
    if (author) ctx[@"author"] = author;
    if ([TPPrefs boolForKey:TPKeyDebugToast])
        [TPDownloader appendPendingReport:[NSString stringWithFormat:@"[history] code %@ · author %@ (%@ · %@ · media %@)\n",
                                           code ?: @"-", author ?: @"-", header ? @"header" : @"no header",
                                           info[@"via"] ?: @"-", info[@"mediaId"] ?: @"-"]];
    return ctx;
}

static NSDictionary *TPPostContextForView(UIView *v) {
    for (UIView *p = v; p; p = p.superview)
        if ([p isKindOfClass:[UICollectionViewCell class]]) return TPPostContextForCell(p);
    // Non-cell fallback (e.g. fullscreen player or lightbox overlay).
    NSMutableDictionary *ctx = [NSMutableDictionary dictionaryWithObject:@"post" forKey:@"kind"];
    NSString *code = nil, *author = nil;
    for (UIView *p = v; p && (!code || !author); p = p.superview) {
        for (NSString *ivarName in @[@"postItem", @"parentMediaFragment", @"cellMediaFragment", @"mediaFragment"]) {
            id m = [TPDownloader ivarValue:p name:ivarName];
            if (!m) continue;
            if (!code) {
                code = TPCodeFromMedia([TPDownloader safeValue:m key:@"carouselParent"])
                    ?: TPCodeFromMedia([TPDownloader safeValue:m key:@"topLevelPost"])
                    ?: TPCodeFromMedia(m);
                if (!code) {
                    id pk = [TPDownloader safeValue:m key:@"pk"] ?: [TPDownloader safeValue:m key:@"mediaID"];
                    if ([pk isKindOfClass:[NSString class]] && [pk length]) code = TPShortcodeFromPK(pk);
                }
            }
            if (!author) {
                author = TPAuthorFromMedia([TPDownloader safeValue:m key:@"carouselParent"])
                      ?: TPAuthorFromMedia([TPDownloader safeValue:m key:@"topLevelPost"])
                      ?: TPAuthorFromMedia(m);
            }
        }
    }
    if (!author && code.length) author = [TPAuthorInfo authorForPostCode:code];
    if (code) ctx[@"code"] = code;
    if (author) ctx[@"author"] = author;
    if ([TPPrefs boolForKey:TPKeyDebugToast])
        [TPDownloader appendPendingReport:[NSString stringWithFormat:@"[history] view code %@ · author %@\n",
                                           code ?: @"-", author ?: @"-"]];
    return ctx;
}

static void TPBatchDownload(UIView *cell, NSInteger filter) {
    BOOL debug = [TPPrefs boolForKey:TPKeyDebugToast];
    gTPSizeLog = debug ? [NSMutableString string] : nil;
    gTPSizeIndex = 0;
    NSArray<NSDictionary *> *raw = TPCollectPostMedia(cell);
    if (gTPSizeLog.length) [TPDownloader appendPendingReport:[@"[photo sizes in app]\n" stringByAppendingString:gTPSizeLog]];
    gTPSizeLog = nil;
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSInteger skipped = 0;
    for (NSDictionary *d in raw) {
        BOOL isVideo = [d[@"video"] boolValue];
        if (filter == 1 && isVideo) continue;
        if (filter == 2 && !isVideo) continue;
        if ([d[@"failed"] boolValue]) { skipped++; continue; }
        [items addObject:d];
    }
    if (skipped && gTPLastMediaDiag && [TPPrefs boolForKey:TPKeyDebugToast]) {
        [TPDownloader showReport:gTPLastMediaDiag];
        if (!items.count) return;
    }
    if (!items.count) {
        [TPHUD toast:skipped ? TPL(@"No download link found. Play the video for a moment, then try again.") : TPL(@"No media found")];
        return;
    }
    if (skipped) [TPHUD toast:[NSString stringWithFormat:TPL(@"%ld items skipped (no download link)"), (long)skipped]];
    NSDictionary *ctx = TPPostContextForCell(cell);
    if ([TPPrefs boolForKey:TPKeyOriginalImage]) {
        NSString *code = TPItemsHaveImage(items) ? ctx[@"code"] : nil;
        TPUpgradeToOriginals(code, items, ^(NSArray<NSDictionary *> *upgraded) { [TPDownloader downloadItems:upgraded context:ctx]; });
    } else {
        [TPDownloader downloadItems:items context:ctx];
    }
}

// =============================================================================
// One-time tips: a small bubble next to a control whose long-press does something, shown once
// per control ever and at most one per launch. It sits in its own pass-through layer on the
// window: any touch, a move of the control (scrolling), or 5 seconds removes it.
// =============================================================================
@interface TPTipLayer : UIView
@property (nonatomic, weak) UIView *anchor;
@property (nonatomic) CGRect anchorFrame;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) CFTimeInterval shownAt;
- (void)dismiss;
@end

@implementation TPTipLayer
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    // Never takes the touch: the touch goes on to whatever is underneath, and the tip leaves.
    if (e.type == UIEventTypeTouches) dispatch_async(dispatch_get_main_queue(), ^{ [self dismiss]; });
    return nil;
}
- (void)check {
    UIView *a = self.anchor;
    BOOL gone = !a || !a.window || a.hidden || a.alpha < 0.05;
    BOOL moved = !gone && !CGRectEqualToRect(CGRectIntegral([a convertRect:a.bounds toView:nil]), self.anchorFrame);
    if (gone || moved || CACurrentMediaTime() - self.shownAt > 5) [self dismiss];
}
- (void)dismiss {
    [self.timer invalidate];
    self.timer = nil;
    if (!self.superview) return;
    [UIView animateWithDuration:0.18 animations:^{ self.alpha = 0; } completion:^(BOOL f) { [self removeFromSuperview]; }];
}
@end

static BOOL gTPTipShownThisLaunch;

static void TPShowTipOnce(NSString *ident, UIView *anchor, NSString *text) {
    if (gTPTipShownThisLaunch || !anchor.window || anchor.hidden) return;
    NSString *key = [@"tp_tip_seen_" stringByAppendingString:ident];
    NSUserDefaults *d = [TPPrefs defaults];
    if ([d boolForKey:key]) return;
    UIWindow *win = anchor.window;
    // Not over another screen (welcome, settings, a sheet).
    if (win.rootViewController.presentedViewController) return;
    CGRect af = CGRectIntegral([anchor convertRect:anchor.bounds toView:nil]);
    UIEdgeInsets safe = win.safeAreaInsets;
    if (CGRectGetMinY(af) < 0 || CGRectGetMaxY(af) > win.bounds.size.height - safe.bottom - 140) return;
    gTPTipShownThisLaunch = YES;
    [d setBool:YES forKey:key];

    TPTipLayer *layer = [[TPTipLayer alloc] initWithFrame:win.bounds];
    layer.anchor = anchor;
    layer.anchorFrame = af;
    UIColor *accent = [TPUI accent];
    CGFloat maxW = MIN(260, win.bounds.size.width - 32);
    UILabel *l = [UILabel new];
    l.text = text;
    l.numberOfLines = 0;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    l.textColor = UIColor.whiteColor;
    CGSize ts = [l sizeThatFits:CGSizeMake(maxW - 24, CGFLOAT_MAX)];
    CGFloat bw = ceil(ts.width) + 24, bh = ceil(ts.height) + 18, arrow = 7;
    // Below the control when there's room, else above; right edges lined up where possible.
    BOOL below = CGRectGetMaxY(af) + arrow + bh + 8 < win.bounds.size.height - safe.bottom - 80;
    CGFloat bx = MIN(MAX(12, CGRectGetMidX(af) - bw + 22), win.bounds.size.width - bw - 12);
    CGFloat by = below ? CGRectGetMaxY(af) + arrow + 2 : CGRectGetMinY(af) - arrow - 2 - bh;
    UIView *bubble = [[UIView alloc] initWithFrame:CGRectMake(bx, by, bw, bh)];
    bubble.backgroundColor = accent;
    bubble.layer.cornerRadius = 10;
    bubble.layer.cornerCurve = kCACornerCurveContinuous;
    l.frame = CGRectMake(12, 9, bw - 24, bh - 18);
    [bubble addSubview:l];
    CAShapeLayer *tri = [CAShapeLayer layer];
    CGFloat ax = MIN(MAX(CGRectGetMidX(af), bx + 14), bx + bw - 14);
    UIBezierPath *path = [UIBezierPath bezierPath];
    if (below) { [path moveToPoint:CGPointMake(ax - arrow, by)]; [path addLineToPoint:CGPointMake(ax, by - arrow)]; [path addLineToPoint:CGPointMake(ax + arrow, by)]; }
    else { [path moveToPoint:CGPointMake(ax - arrow, by + bh)]; [path addLineToPoint:CGPointMake(ax, by + bh + arrow)]; [path addLineToPoint:CGPointMake(ax + arrow, by + bh)]; }
    [path closePath];
    tri.path = path.CGPath;
    tri.fillColor = accent.CGColor;
    [layer.layer addSublayer:tri];
    [layer addSubview:bubble];
    bubble.isAccessibilityElement = YES;
    bubble.accessibilityLabel = text;

    layer.alpha = 0;
    [win addSubview:layer];
    layer.shownAt = CACurrentMediaTime();
    [UIView animateWithDuration:0.2 animations:^{ layer.alpha = 1; }];
    __weak TPTipLayer *wl = layer;
    layer.timer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) {
        TPTipLayer *s = wl;
        if (!s) { [t invalidate]; return; }
        [s check];
    }];
}

// Offer a tip a moment after a control appears, once it has settled on screen.
static void TPOfferTip(NSString *ident, UIView *anchor, NSString *textKey, double delay) {
    if (gTPTipShownThisLaunch || [[TPPrefs defaults] boolForKey:[@"tp_tip_seen_" stringByAppendingString:ident]]) return;
    __weak UIView *wa = anchor;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *a = wa;
        if (a) TPShowTipOnce(ident, a, TPL(textKey));
    });
}

static void TPEnsureBatchButton(UIView *cell) {
    UIButton *b = objc_getAssociatedObject(cell, kTPBatchBtnKey);
    CGSize sz = cell.bounds.size;
    // Wide, short media (e.g. a panorama strip ~60 pt tall) still gets a button: anything at least
    // as tall as the button plus a little margin qualifies.
    const CGFloat d = 38;
    BOOL want = cell.window && [TPPrefs boolForKey:TPKeyShowDownloadBtn] && sz.width >= 150 && sz.height >= d + 6;
    if (!want) { b.hidden = YES; return; }

    if (!b) {
        __weak UIView *wc = cell;
        TPMenuItem *all  = [TPMenuItem itemWithKey:@"Download All Media" symbol:@"square.and.arrow.down.on.square"
                                              handler:^{ if (wc) TPBatchDownload(wc, 0); }];
        TPMenuItem *imgs = [TPMenuItem itemWithKey:@"Download Images Only" symbol:@"photo"
                                              handler:^{ if (wc) TPBatchDownload(wc, 1); }];
        TPMenuItem *vids = [TPMenuItem itemWithKey:@"Download Videos Only" symbol:@"video"
                                              handler:^{ if (wc) TPBatchDownload(wc, 2); }];
        TPMenuItem *text = [TPMenuItem itemWithKey:@"Post Text" symbol:@"text.quote"
                                              handler:^{ UIView *c = wc; if (c) TPShowPostTextActions(c, nil, objc_getAssociatedObject(c, kTPBatchBtnKey)); }];
        b = [TPUI circleButtonWithSymbol:@"arrow.down.to.line" diameter:d onTap:^{
            if (wc) TPBatchDownload(wc, 0);
        } menuItems:@[all, imgs, vids, text, TPManagerMenuItem()]];
        [cell addSubview:b];
        objc_setAssociatedObject(cell, kTPBatchBtnKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TPDebug(TPL(@"Download button added"));
    }
    b.hidden = NO;

    UICollectionView *cv = (UICollectionView *)TPFindView(cell, [UICollectionView class], 7);
    CGRect r = cv ? [cell convertRect:cv.bounds fromView:cv] : cell.bounds;
    r = CGRectIntersection(r, cell.bounds);
    if (CGRectIsNull(r) || CGRectIsEmpty(r)) r = cell.bounds;
    if (CGRectGetHeight(r) < d + 6) r = cell.bounds;
    // Top-right corner normally; on short media, vertically centred at the right edge.
    CGFloat y = CGRectGetHeight(r) >= d + 20 ? CGRectGetMinY(r) + 10 : CGRectGetMidY(r) - d / 2;
    b.frame = CGRectMake(CGRectGetMaxX(r) - d - 10, y, d, d);
    if (cell.subviews.lastObject != b) [cell bringSubviewToFront:b];
    TPOfferTip(@"download_btn", b, @"Long-press for photos only, videos only, the post text or the download manager", 1.2);
}

static Class TPMediaClasses(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"IGMedia"); });
    return c;
}

static NSString *TPPostCodeForLightbox(UIView *cell) {
    id item = [TPDownloader ivarValue:cell name:@"postItem"];
    if (item) {
        id parent = [TPDownloader safeValue:item key:@"carouselParent"];
        NSString *code = TPCodeFromMedia(parent);
        if (code) return code;
        id parentId = [TPDownloader safeValue:item key:@"carouselParentId"];
        if ([parentId isKindOfClass:[NSString class]] && [parentId length]) return TPShortcodeFromPK(parentId);
        id top = [TPDownloader safeValue:item key:@"topLevelPost"];
        code = TPCodeFromMedia(top);
        if (code) return code;
        if (!parent) { code = TPCodeFromMedia(item); if (code) return code; }
    }

    static Class lbClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lbClass = NSClassFromString(@"_TtC11BCNLightbox25BCNLightboxViewController"); });
    for (UIResponder *r = cell; r; r = r.nextResponder) {
        if (!lbClass || ![r isKindOfClass:lbClass]) continue;
        id content = [TPDownloader ivarValue:r name:@"content"];
        uint8_t *body = TPIvarAddress(content, "body");
        if (!body) break;
        for (int i = 0; i < 4; i++) {
            id media = TPObjectFromWord(((uintptr_t *)body)[i], TPMediaClasses());
            NSString *code = TPCodeFromMedia(media);
            if (code) return code;
        }
        break;
    }
    return nil;
}

// All photos of the post behind a lightbox page, from the media model (pages that were never
// shown have no image views, so scanning the screen misses them).
static NSArray<NSDictionary *> *TPLightboxPagesPhotos(UIView *host, NSMutableString *diag) {
    // The lightbox pages come from its IGListAdapter: one object per page, including pages that
    // were never shown.
    UIViewController *vc = nil;
    Class lb = NSClassFromString(@"_TtC11BCNLightbox25BCNLightboxViewController");
    for (UIResponder *r = host; r; r = r.nextResponder) if (lb && [r isKindOfClass:lb]) { vc = (UIViewController *)r; break; }
    id adapter = vc ? [TPDownloader ivarValue:vc name:@"$__lazy_storage_$_listAdapter"] : nil;
    NSArray *objs = [adapter respondsToSelector:@selector(objects)] ? [adapter performSelector:@selector(objects)] : nil;
    [diag appendFormat:@"adapter %@ objects %lu\n", adapter ? NSStringFromClass([adapter class]) : @"nil", (unsigned long)objs.count];
    if (![objs isKindOfClass:[NSArray class]] || objs.count < 2) return nil;
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id o in objs) {
        NSDictionary *d = nil;
        id media = TPMediaClasses() && [o isKindOfClass:TPMediaClasses()] ? o : nil;
        if (!media) media = [TPDownloader safeValue:o key:@"media"] ?: [TPDownloader safeValue:o key:@"postItem"];
        if (media) d = TPItemForMedia(media);
        if (!d || [d[@"failed"] boolValue]) {
            NSURL *u = [TPDownloader bestImageURLHarvestedFromObject:o];
            NSURL *v = [TPDownloader bestVideoURLHarvestedFromObject:o];
            if (v && !u) continue;
            d = u ? @{ @"video": @NO, @"urls": @[u], @"key": TPDedupeKey(u) } : nil;
        }
        [diag appendFormat:@"  %@ → %@\n", NSStringFromClass([o class]), d ? ([d[@"video"] boolValue] ? @"video" : @"photo") : @"-"];
        if (!d || [d[@"video"] boolValue] || [d[@"failed"] boolValue]) continue;
        if (d[@"key"] && [seen containsObject:d[@"key"]]) continue;
        if (d[@"key"]) [seen addObject:d[@"key"]];
        [items addObject:d];
    }
    return items;
}

// The carousel children of the post behind a lightbox page (nil for a single-media post).
static NSArray *TPLightboxCarouselChildren(UIView *host) {
    id item = [TPDownloader ivarValue:host name:@"postItem"];
    id parent = [TPDownloader safeValue:item key:@"carouselParent"];
    NSArray *children = [TPDownloader safeValue:parent key:@"carouselMedia"];
    if (![children isKindOfClass:[NSArray class]] || !children.count) children = [TPDownloader safeValue:item key:@"carouselMedia"];
    if (![children isKindOfClass:[NSArray class]] || children.count < 2) {
        // Fall back to the post the lightbox was opened for.
        UIViewController *vc = nil;
        Class lb = NSClassFromString(@"_TtC11BCNLightbox25BCNLightboxViewController");
        for (UIResponder *r = host; r; r = r.nextResponder) if (lb && [r isKindOfClass:lb]) { vc = (UIViewController *)r; break; }
        id content = vc ? [TPDownloader ivarValue:vc name:@"content"] : nil;
        uint8_t *body = TPIvarAddress(content, "body");
        for (int i = 0; body && i < 4 && (![children isKindOfClass:[NSArray class]] || children.count < 2); i++) {
            id media = TPObjectFromWord(((uintptr_t *)body)[i], TPMediaClasses());
            NSArray *c = [TPDownloader safeValue:media key:@"carouselMedia"];
            if ([c isKindOfClass:[NSArray class]] && c.count) children = c;
        }
    }
    return [children isKindOfClass:[NSArray class]] && children.count ? children : nil;
}

// IGMedia answers "video" even for photos, so go by media type and the video URL instead.
static BOOL TPChildIsVideo(id child) {
    id type = [TPDownloader safeValue:child key:@"mediaType"];
    if ([type respondsToSelector:@selector(integerValue)] && [type integerValue] == 2) return YES;
    return TPVideoURLFromMedia(child) != nil;
}

static NSArray<NSDictionary *> *TPLightboxPostVideos(UIView *host) {
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id child in TPLightboxCarouselChildren(host)) {
        if (!TPChildIsVideo(child)) continue;
        NSURL *u = TPVideoURLFromMedia(child) ?: [TPDownloader bestVideoURLHarvestedFromObject:child];
        NSDictionary *dash = [TPDownloader dashInfoFromObject:child];
        if (!u && !dash) continue;
        NSDictionary *d = TPVideoItem(u, dash);
        if (d[@"key"] && [seen containsObject:d[@"key"]]) continue;
        if (d[@"key"]) [seen addObject:d[@"key"]];
        [items addObject:d];
    }
    return items;
}

static NSDictionary *TPPostContextForLightbox(UIView *host) {
    NSMutableDictionary *ctx = [NSMutableDictionary dictionaryWithObject:@"post" forKey:@"kind"];
    NSString *code = TPPostCodeForLightbox(host);
    if (code) ctx[@"code"] = code;
    id item = [TPDownloader ivarValue:host name:@"postItem"];
    NSString *a = TPAuthorFromMedia([TPDownloader safeValue:item key:@"carouselParent"])
               ?: TPAuthorFromMedia([TPDownloader safeValue:item key:@"topLevelPost"]) ?: TPAuthorFromMedia(item);
    if (!a && code.length) a = [TPAuthorInfo authorForPostCode:code];
    if (a) ctx[@"author"] = a;
    if ([TPPrefs boolForKey:TPKeyDebugToast])
        [TPDownloader appendPendingReport:[NSString stringWithFormat:@"[history] lightbox code %@ · author %@\n",
                                           code ?: @"-", a ?: @"-"]];
    return ctx;
}

static NSArray<NSDictionary *> *TPLightboxPostPhotos(UIView *host) {
    NSMutableString *diag = [NSMutableString stringWithString:@"[lightbox all]\n"];
    NSArray *pages = TPLightboxPagesPhotos(host, diag);
    [TPDownloader appendPendingReport:diag];
    if (pages.count > 1) return pages;
    NSArray *children = TPLightboxCarouselChildren(host);
    if (!children.count) return nil;
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id child in children) {
        // IGMedia answers "video" even for photos, so go by media type and the image URL instead.
        id type = [TPDownloader safeValue:child key:@"mediaType"];
        if ([type respondsToSelector:@selector(integerValue)] && [type integerValue] == 2) continue;
        if (TPVideoURLFromMedia(child)) continue;   // video page: its image is just the cover
        NSURL *u = TPImageURLFromMedia(child) ?: [TPDownloader bestImageURLHarvestedFromObject:child];
        if (!u) continue;
        NSString *key = TPDedupeKey(u);
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [items addObject:@{ @"video": @NO, @"urls": @[u], @"key": key }];
    }
    return items;
}

// The full-size image URL of a lightbox photo page, from its post item.
static NSURL *TPLightboxPhotoURL(UIView *host) {
    id item = [TPDownloader ivarValue:host name:@"postItem"];
    if (!item) return nil;
    return TPBestImageURLFromPhoto([TPDownloader safeValue:item key:@"photo"]) ?: TPImageURLFromMedia(item);
}

static void TPDownloadLightboxImages(UIView *host, BOOL all) {
    if (all) {
        NSArray *fromModel = TPLightboxPostPhotos(host);
        if (fromModel.count > 1) {
            NSDictionary *ctx = TPPostContextForLightbox(host);
            if ([TPPrefs boolForKey:TPKeyOriginalImage]) {
                TPUpgradeToOriginals(ctx[@"code"], fromModel, ^(NSArray<NSDictionary *> *upgraded) {
                    [TPDownloader downloadItems:upgraded context:ctx];
                });
            } else {
                [TPDownloader downloadItems:fromModel context:ctx];
            }
            return;
        }
    }
    NSMutableArray<UIImageView *> *ivs = [NSMutableArray array];
    if (all) {
        UIView *root = host;
        for (UIView *v = host.superview; v; v = v.superview) {
            if ([v isKindOfClass:[UIScrollView class]]) {
                UIScrollView *sv = (UIScrollView *)v;
                if (sv.contentSize.width > sv.bounds.size.width * 1.2) { root = sv; break; }
            }
        }
        NSMutableArray<UIImageView *> *found = [NSMutableArray array];
        TPCollectImageViews(root, found, 0);
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (UIImageView *iv in found) {
            NSURL *u = TPURLForImageView(iv);
            NSString *key = u ? TPDedupeKey(u) : [NSString stringWithFormat:@"%p", iv.image];
            if ([seen containsObject:key]) continue;
            [seen addObject:key];
            [ivs addObject:iv];
        }
        UIView *rootView = root;
        [ivs sortUsingComparator:^NSComparisonResult(UIImageView *a, UIImageView *b) {
            CGFloat ax = [rootView convertPoint:CGPointZero fromView:a].x, bx = [rootView convertPoint:CGPointZero fromView:b].x;
            return ax < bx ? NSOrderedAscending : (ax > bx ? NSOrderedDescending : NSOrderedSame);
        }];
    } else {
        UIImageView *iv = TPLargestImageView(host);
        if (iv) [ivs addObject:iv];
    }

    NSURL *bestOfItem = nil;
    if (!all) bestOfItem = TPLightboxPhotoURL(host);

    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for (UIImageView *iv in ivs) {
        NSURL *u = TPURLForImageView(iv);
        if (bestOfItem && (!u || [TPDedupeKey(u) isEqualToString:TPDedupeKey(bestOfItem)])) u = bestOfItem;
        if (!u && !iv.image) continue;
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"video"] = @NO;
        item[@"urls"] = u ? @[u] : @[];
        if (u) item[@"key"] = TPDedupeKey(u);
        if (iv.image) item[@"image"] = iv.image;
        [items addObject:item];
    }
    if (!items.count && bestOfItem) [items addObject:@{ @"video": @NO, @"urls": @[bestOfItem], @"key": TPDedupeKey(bestOfItem) }];
    if (!items.count) { [TPHUD toast:TPL(@"No image found")]; return; }

    NSDictionary *ctx = TPPostContextForLightbox(host);
    if ([TPPrefs boolForKey:TPKeyOriginalImage]) {
        TPUpgradeToOriginals(ctx[@"code"], items, ^(NSArray<NSDictionary *> *upgraded) {
            [TPDownloader downloadItems:upgraded context:ctx];
        });
    } else {
        [TPDownloader downloadItems:items context:ctx];
    }
}

// The video on a lightbox video page: from the player on screen first (it knows the DASH manifest),
// then from the page's post item.
static NSDictionary *TPLightboxVideoItem(UIView *host) {
    NSURL *url = nil;
    NSDictionary *dash = nil;
    UIView *vv = TPFindView(host, TPVideoViewClass(), 30);
    if (vv) {
        id player = objc_getAssociatedObject(vv, kTPPlayerKey);
        url = [TPDownloader bestURLFromVideoView:vv player:player];
        dash = [TPDownloader dashInfoFromVideoView:vv player:player];
    }
    id item = [TPDownloader ivarValue:host name:@"postItem"];
    if (!dash && item) dash = [TPDownloader dashInfoFromObject:item];
    if (!url && item) url = TPVideoURLFromMedia(item) ?: [TPDownloader bestVideoURLHarvestedFromObject:item];
    if (!url && !dash) return nil;
    return TPVideoItem(url, dash);
}

static void TPDownloadLightboxVideos(UIView *host, BOOL all) {
    NSMutableArray *items = [NSMutableArray array];
    if (all) [items addObjectsFromArray:TPLightboxPostVideos(host)];
    if (!items.count) {
        // Single-video post, or only this page's video was asked for.
        NSDictionary *d = TPLightboxVideoItem(host);
        if (d) [items addObject:d];
    }
    if (!items.count) { [TPHUD toast:TPL(@"No video found")]; return; }
    [TPDownloader downloadItems:items context:TPPostContextForLightbox(host)];
}

// Lightbox download button: lives in the top bar next to Threads' "⋯" button (outside the image)
// and follows the fade of Threads' own top controls.
static const void *kTPLBBarBtnKey = &kTPLBBarBtnKey;
static const void *kTPLBHostKey = &kTPLBHostKey;

static UIView *TPLBFindMoreButton(UIView *root, UIView *skip, BOOL wantClose);

static CGFloat TPLBSubtreeOpacity(UIView *v, int depth) {
    CALayer *l = v.layer.presentationLayer ?: v.layer;
    if (v.hidden || l.hidden) return 0;
    CGFloat own = l.opacity;
    if (depth > 5 || !v.subviews.count || own <= 0.01) return own;
    CGFloat best = 0;
    for (UIView *c in v.subviews) best = MAX(best, TPLBSubtreeOpacity(c, depth + 1));
    return own * best;
}

@interface TPLBFollower : NSObject
@property (nonatomic, weak) UIView *source;   // Threads' "⋯" (or another top control)
@property (nonatomic, weak) UIView *target;   // our button
@property (nonatomic, weak) UIView *root;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic) NSInteger searchSkip;
@property (nonatomic) BOOL followClose;       // video pages: Threads keeps an invisible "⋯" there
@property (nonatomic) CGPoint lastWant;       // last computed position
@property (nonatomic) NSInteger stable;       // frames the position has stayed put (shown once settled)
@end

// How far a view is drawn from where its frame says: an offset or animation Threads applies to
// some container shows up in the presentation layers but not in the frames.
static CGPoint TPLBDrawOffset(UIView *v) {
    UIWindow *w = v.window;
    if (!w) return CGPointZero;
    CALayer *pl = v.layer.presentationLayer, *wl = w.layer.presentationLayer;
    if (!pl || !wl) return CGPointZero;
    CGRect drawn = [pl convertRect:pl.bounds toLayer:wl];
    CGRect model = [v convertRect:v.bounds toView:nil];
    return CGPointMake(CGRectGetMidX(drawn) - CGRectGetMidX(model), CGRectGetMidY(drawn) - CGRectGetMidY(model));
}

static BOOL TPLBDesiredCenter(UIView *src, BOOL isClose, UIView *b, UIView *root, CGPoint *out);

// Any position/size/transform animation on the source or its ancestors (lightbox open/close).
static BOOL TPLBChainAnimating(UIView *v) {
    for (int i = 0; v && i < 20; v = v.superview, i++) {
        for (NSString *k in v.layer.animationKeys) {
            NSString *l = k.lowercaseString;
            if ([l containsString:@"position"] || [l containsString:@"bounds"] || [l containsString:@"transform"] || [l containsString:@"frame"]) return YES;
        }
    }
    return NO;
}

@implementation TPLBFollower
- (void)start {
    if (self.link) return;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    self.link.preferredFramesPerSecond = 60;
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)tick {
    UIView *t = self.target, *s = self.source, *r = self.root;
    if (!t || !t.window) { [self.link invalidate]; self.link = nil; return; }
    // When the top controls hide, Threads may remove (or rebuild) them; look again, and stay hidden
    // while there's nothing to follow.
    if (!s || !s.window) {
        if (self.searchSkip-- > 0) { if (t.alpha > 0) t.alpha = 0; return; }
        self.searchSkip = 12;  // look ~5 times a second while hidden
        self.stable = 0;
        s = TPLBFindMoreButton(r, t, self.followClose);
        self.source = s;
        if (!s) { if (t.alpha > 0) t.alpha = 0; return; }
    }
    // Threads fades its top controls with layer animations, sometimes on an inner view of the
    // button rather than the button itself, so read what's on screen: the presentation-layer
    // opacity between the button and the container we share, times the most visible path down
    // through the button's own subviews. (The shared container's own fade applies to us already.)
    CGFloat a = s.window ? 1 : 0;
    for (UIView *v = s.superview; v && a > 0 && v != t.superview; v = v.superview) {
        CALayer *l = v.layer.presentationLayer ?: v.layer;
        a *= (v.hidden || l.hidden) ? 0 : l.opacity;
        if (v == r) break;
    }
    a *= TPLBSubtreeOpacity(s, 0);

    // Recompute where we belong from the source's current geometry every frame, so a top bar that
    // moves or settles after we were placed is followed (nothing is cached or accumulated).
    CGPoint c;
    BOOL ok = TPLBDesiredCenter(s, self.followClose, t, r, &c);
    if (ok) {
        if (fabs(c.x - self.lastWant.x) > 0.5 || fabs(c.y - self.lastWant.y) > 0.5) { self.stable = 0; self.lastWant = c; }
        else self.stable++;
        if (fabs(c.x - t.center.x) > 0.25 || fabs(c.y - t.center.y) > 0.25) t.center = c;
    } else self.stable = 0;
    // Threads' top bar can still be moving into place right after the lightbox opens (or while it
    // closes). Stay invisible until the position has held for ~0.15 s and nothing up the source's
    // chain is animating, then fade in over ~0.15 s. Avoids ever showing a misplaced button.
    if (TPLBChainAnimating(s)) self.stable = MIN(self.stable, 0);
    const NSInteger settle = 9, fade = 9;
    CGFloat k = self.stable < settle ? 0 : MIN(1.0, (CGFloat)(self.stable - settle + 1) / fade);
    a *= k;
    if (fabs(t.alpha - a) > 0.01) t.alpha = a;
}
@end
static const void *kTPLBFollowerKey = &kTPLBFollowerKey;

// Small tappable views in the top band of the lightbox (✕, ⋯), in root coordinates.
static void TPLBCollectTop(UIView *v, UIView *root, CGFloat band, UIView *skip, int depth, NSMutableArray *out) {
    if (depth > 8 || v.hidden || v == skip) return;
    CGRect r = [v convertRect:v.bounds toView:root];
    if (r.origin.y > band) return;
    BOOL small = r.size.width >= 20 && r.size.width <= 72 && r.size.height >= 20 && r.size.height <= 72;
    if (small && ([v isKindOfClass:[UIControl class]] || v.gestureRecognizers.count)) {
        [out addObject:v];
        return;
    }
    for (UIView *s in v.subviews) TPLBCollectTop(s, root, band, skip, depth + 1, out);
}

// Threads' "✕" (leftmost top control below the status bar), or the rightmost control on its row
// (the "⋯"), falling back to the "✕".
static UIView *TPLBFindMoreButton(UIView *root, UIView *skip, BOOL wantClose) {
    if (!root) return nil;
    CGFloat safeTop = root.safeAreaInsets.top, half = root.bounds.size.width / 2;
    NSMutableArray<UIView *> *top = [NSMutableArray array];
    TPLBCollectTop(root, root, safeTop + 90, skip, 0, top);
    UIView *close = nil, *more = nil;
    CGRect closeR = CGRectNull, moreR = CGRectNull;
    for (UIView *v in top) {
        CGRect r = [v convertRect:v.bounds toView:root];
        if (r.origin.y < safeTop - 4) continue;
        if (CGRectGetMidX(r) < half && (!close || r.origin.x < closeR.origin.x)) { close = v; closeR = r; }
    }
    if (wantClose) return close;
    for (UIView *v in top) {
        CGRect r = [v convertRect:v.bounds toView:root];
        if (r.origin.y < safeTop - 4 || CGRectGetMidX(r) < half) continue;
        if (close && fabs(CGRectGetMidY(r) - CGRectGetMidY(closeR)) > 10) continue;
        if (!more || CGRectGetMaxX(r) > CGRectGetMaxX(moreR)) { more = v; moreR = r; }
    }
    return more ?: close;
}

// The drawn circle inside one of Threads' top buttons (its tap area can be larger and offset).
static CGRect TPLBVisualFrame(UIView *v, UIView *root, int depth) {
    if (!v || v.hidden || depth > 6) return CGRectNull;
    CGRect r = [v convertRect:v.bounds toView:root];
    CGFloat w = r.size.width, h = r.size.height;
    BOOL roundish = w >= 22 && w <= 48 && fabs(w - h) <= 3 &&
                    (v.layer.cornerRadius >= w / 2 - 2 || v.layer.mask || [v isKindOfClass:[UIVisualEffectView class]] || v.backgroundColor);
    for (UIView *s in v.subviews) {
        CGRect inner = TPLBVisualFrame(s, root, depth + 1);
        if (!CGRectIsNull(inner)) return inner;
    }
    return roundish ? r : CGRectNull;
}

// The "⋯" glyph itself: Threads centres its icons in their circles, so the glyph's centre is the
// most reliable row line (a background view can be taller or shifted by its shadow inset).
static CGRect TPLBGlyphFrame(UIView *v, UIView *root, int depth) {
    if (!v || v.hidden || v.alpha < 0.01 || depth > 8) return CGRectNull;
    BOOL glyph = ([v isKindOfClass:[UIImageView class]] && ((UIImageView *)v).image) ||
                 ([v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length);
    if (glyph) {
        CGRect r = [v convertRect:v.bounds toView:root];
        if (r.size.width > 0 && r.size.width <= 30 && r.size.height <= 30) return r;
    }
    for (UIView *s in v.subviews) {
        CGRect r = TPLBGlyphFrame(s, root, depth + 1);
        if (!CGRectIsNull(r)) return r;
    }
    return CGRectNull;
}

static UIViewController *TPLightboxController(UIView *v) {
    static Class lb;
    if (!lb) lb = NSClassFromString(@"_TtC11BCNLightbox25BCNLightboxViewController");
    for (UIResponder *r = v; r; r = r.nextResponder) if (lb && [r isKindOfClass:lb]) return (UIViewController *)r;
    return nil;
}

static BOOL TPCellIsCentered(UIView *cell) {
    UIWindow *w = cell.window;
    if (!w) return NO;
    CGRect r = [cell convertRect:cell.bounds toView:w];
    return CGRectContainsPoint(r, CGPointMake(CGRectGetMidX(w.bounds), CGRectGetMidY(w.bounds)));
}

static const void *kTPLBMenusKey = &kTPLBMenusKey;

// Long-press menu for the page on screen: this item first, then "all images" / "all videos" for
// whatever the post actually contains.
// Where our button's center belongs, in its superview's coordinates: 10 pt left of Threads' "⋯"
// (or, on video pages, mirroring the "✕"), at the position the source is actually drawn.
static BOOL TPLBDesiredCenter(UIView *src, BOOL isClose, UIView *b, UIView *root, CGPoint *out) {
    UIView *sv = b.superview;
    if (!src || !src.window || !sv || !sv.window || !root) return NO;
    CGFloat d = b.bounds.size.width;
    CGRect mr = [src convertRect:src.bounds toView:root];
    CGPoint p;
    if (!isClose) {
        CGRect vis = TPLBVisualFrame(src, root, 0), glyph = TPLBGlyphFrame(src, root, 0);
        CGFloat cy = !CGRectIsNull(glyph) ? CGRectGetMidY(glyph) : CGRectIsNull(vis) ? CGRectGetMidY(mr) : CGRectGetMidY(vis);
        CGFloat left = CGRectIsNull(vis) ? mr.origin.x : vis.origin.x;
        p = CGPointMake(left - 10 - d / 2, cy);
    } else {
        p = CGPointMake(root.bounds.size.width - CGRectGetMidX(mr), CGRectGetMidY(mr));
    }
    CGPoint win = [root convertPoint:p toView:nil];
    CGPoint so = TPLBDrawOffset(src), po = TPLBDrawOffset(sv);
    win.x += so.x - po.x; win.y += so.y - po.y;
    CGPoint c = [sv convertPoint:win fromView:nil];
    if (!isfinite(c.x) || !isfinite(c.y)) return NO;
    *out = c;
    return YES;
}

static void TPLBUpdateMenu(UIButton *b, UIView *host, BOOL isVideo) {
    NSArray *menus = objc_getAssociatedObject(b, kTPLBMenusKey);
    if (menus.count != 2) return;
    NSArray *photo = menus[0], *video = menus[1];
    NSArray *children = TPLightboxCarouselChildren(host);
    BOOL hasVideo = isVideo, hasPhoto = !isVideo;
    for (id c in children) { if (TPChildIsVideo(c)) hasVideo = YES; else hasPhoto = YES; }
    NSMutableArray *items = [NSMutableArray arrayWithObject:isVideo ? video[0] : photo[0]];
    if (children.count > 1) {
        if (isVideo) { if (hasVideo) [items addObject:video[1]]; if (hasPhoto) [items addObject:photo[1]]; }
        else         { if (hasPhoto) [items addObject:photo[1]]; if (hasVideo) [items addObject:video[1]]; }
    }
    [items addObject:TPManagerMenuItem()];
    [TPUI setMenuItems:items forButton:b];
}

// Nearest view containing both of Threads' top buttons (the top bar), within the lightbox root.
static UIView *TPLBCommonAncestor(UIView *a, UIView *b, UIView *root) {
    UIView *start = a ?: b;
    if (!start) return root;
    for (UIView *v = start.superview; v; v = v.superview) {
        if (v == root) return root;
        if ((!a || [a isDescendantOfView:v]) && (!b || [b isDescendantOfView:v]) && v.bounds.size.width >= root.bounds.size.width * 0.8)
            return v;
    }
    return root;
}


static void TPEnsureLightboxButton(UIView *host) {
    UIViewController *vc = TPLightboxController(host);
    UIView *root = vc.view;
    if (!root || !host.window) return;
    UIButton *b = objc_getAssociatedObject(vc, kTPLBBarBtnKey);
    BOOL enabled = [TPPrefs boolForKey:TPKeyShowDownloadBtn];
    BOOL isPhoto = [host isKindOfClass:objc_getClass("_TtC11BCNLightbox20BCNLightboxPhotoCell")];
    BOOL isVideo = [host isKindOfClass:objc_getClass("_TtC11BCNLightbox20BCNLightboxVideoCell")];
    if (!TPCellIsCentered(host)) return;   // only the page on screen decides
    // A photo page counts if its data has an image URL, even when the picture is tiny or still
    // loading; the on-screen image view is only a fallback.
    if (!enabled || (!isPhoto && !isVideo) || (isPhoto && !TPLightboxPhotoURL(host) && !TPLargestImageView(host))) { b.hidden = YES; return; }

    // Threads' "✕", and the "⋯" on its row. Video pages have no visible "⋯" (Threads keeps one
    // there at alpha 0): sit in its place and follow the "✕" instead.
    CGFloat safeTop = root.safeAreaInsets.top;
    UIView *close = TPLBFindMoreButton(root, b, YES);
    UIView *more = isVideo ? nil : TPLBFindMoreButton(root, b, NO);
    if (more == close) more = nil;

    // Fixed size: resizing the button after creation leaves its inner circle at the old size.
    const CGFloat d = 32;
    if (!b) {
        __weak UIViewController *wvc = vc;
        UIView *(^current)(void) = ^UIView *{ return wvc ? objc_getAssociatedObject(wvc, kTPLBHostKey) : nil; };
        TPMenuItem *one = [TPMenuItem itemWithKey:@"Download This Image" symbol:@"photo"
                                             handler:^{ UIView *h = current(); if (h) TPDownloadLightboxImages(h, NO); }];
        TPMenuItem *all = [TPMenuItem itemWithKey:@"Download All Images in Post" symbol:@"photo.on.rectangle.angled"
                                             handler:^{ UIView *h = current(); if (h) TPDownloadLightboxImages(h, YES); }];
        TPMenuItem *oneV = [TPMenuItem itemWithKey:@"Download This Video" symbol:@"video"
                                              handler:^{ UIView *h = current(); if (h) TPDownloadLightboxVideos(h, NO); }];
        TPMenuItem *allV = [TPMenuItem itemWithKey:@"Download All Videos in Post" symbol:@"play.rectangle.on.rectangle"
                                              handler:^{ UIView *h = current(); if (h) TPDownloadLightboxVideos(h, YES); }];
        b = [TPUI circleButtonWithSymbol:@"arrow.down.to.line" diameter:d onTap:^{
            UIView *h = current();
            if (!h) return;
            if ([h isKindOfClass:objc_getClass("_TtC11BCNLightbox20BCNLightboxVideoCell")]) TPDownloadLightboxVideos(h, NO);
            else TPDownloadLightboxImages(h, NO);
        } menuItems:@[one, all, TPManagerMenuItem()]];
        objc_setAssociatedObject(b, kTPLBMenusKey, @[@[one, all], @[oneV, allV]], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, kTPLBBarBtnKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        b.alpha = 0;   // the follower fades it in once the top bar has settled
    }
    if (objc_getAssociatedObject(vc, kTPLBHostKey) != host) TPLBUpdateMenu(b, host, isVideo);
    objc_setAssociatedObject(vc, kTPLBHostKey, host, OBJC_ASSOCIATION_ASSIGN);

    // Live in the same container as Threads' "✕" and "⋯" so we share its fades and offsets.
    UIView *container = TPLBCommonAncestor(close, more, root);
    BOOL fresh = b.hidden || b.superview != container;
    if (b.superview != container) [container addSubview:b];
    TPLBFollower *f = objc_getAssociatedObject(b, kTPLBFollowerKey);
    if (!f) { f = [TPLBFollower new]; f.target = b; objc_setAssociatedObject(b, kTPLBFollowerKey, f, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    if (fresh) { f.stable = 0; b.alpha = 0; }
    b.bounds = CGRectMake(0, 0, d, d);
    // Next to the "⋯", or in its place on video pages (mirroring the "✕"). Without either, leave
    // room for a "⋯" under the status bar.
    CGPoint c;
    UIView *ref = more ?: close;
    if (!ref || !TPLBDesiredCenter(ref, !more, b, root, &c)) {
        CGRect fr = CGRectMake(root.bounds.size.width - 16 - d - 10 - 36, safeTop + 8, d, d);
        c = [root convertPoint:CGPointMake(CGRectGetMidX(fr), CGRectGetMidY(fr)) toView:container];
    }
    b.center = c;
    b.hidden = NO;
    if (container.subviews.lastObject != b) [container bringSubviewToFront:b];

    f.root = root;
    if (f.followClose != isVideo) { f.followClose = isVideo; f.source = nil; }
    f.source = more ?: close;
    [f start];
}

%group Images

%hook _TtC16BCNFeedMediaCell16BCNFeedMediaCell
- (void)layoutSubviews { %orig; TPEnsureBatchButton((UIView *)self); }
- (void)didMoveToWindow { %orig; TPEnsureBatchButton((UIView *)self); }
%end

%hook _TtC11BCNLightbox20BCNLightboxPhotoCell
- (void)layoutSubviews { %orig; TPEnsureLightboxButton((UIView *)self); }
%end

// Video and other pages hide the image button while they're on screen.
%hook _TtC11BCNLightbox15BCNLightboxCell
- (void)layoutSubviews { %orig; TPEnsureLightboxButton((UIView *)self); }
%end

%end

// Default playback speed. Threads resets the rate to 1.0 when a long-press 2x ends;
// that reset is redirected to the chosen speed.
static float TPSpeedForIndex(NSInteger i) {
    static const float table[] = {1.0f, 1.25f, 1.5f, 2.0f};
    return (i >= 0 && i <= 3) ? table[i] : 1.0f;
}

static const void *kTPPlayerInitKey = &kTPPlayerInitKey;

static BOOL gTPApplyingDefault;       // ThreadsPulse is applying the default speed itself

// Disable Autoplay.
// Simply refusing to play leaves the cell without its sound icon and playback UI. Instead,
// Threads is allowed to start (reason 1 = scrolled into view), the underlying FNFPlayer plays
// muted until the first frame and pauses, and later play calls are ignored. A tap (a touch
// that barely moved) releases the hold. Other reasons, such as full screen, play normally.
static const void *kTPUserStartedKey = &kTPUserStartedKey;
static const void *kTPTouchStartKey  = &kTPTouchStartKey;
static const void *kTPHeldKey = &kTPHeldKey;
static CFAbsoluteTime gTPLastTapAt = 0;

static id TPFNFPlayer(id inner) {
    Ivar iv = class_getInstanceVariable(object_getClass(inner), "_player");
    return iv ? object_getIvar(inner, iv) : nil;
}

static const void *kTPPrimedKey = &kTPPrimedKey;

static void TPSetHeld(id inner, BOOL held) {
    id v = held ? @YES : nil;
    objc_setAssociatedObject(inner, kTPHeldKey, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id fnf = TPFNFPlayer(inner);
    if (!fnf) return;
    objc_setAssociatedObject(fnf, kTPHeldKey, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!held && objc_getAssociatedObject(fnf, kTPPrimedKey)) {
        objc_setAssociatedObject(fnf, kTPPrimedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if ([fnf respondsToSelector:@selector(setVolume:rampTime:)]) [fnf setVolume:1.0f rampTime:0];
    }
}

static void TPPauseIfHeld(id player) {
    id inner = TPInnerPlayer(player);
    if (!inner || !objc_getAssociatedObject(inner, kTPHeldKey)) return;
    id fnf = TPFNFPlayer(inner);
    if ([fnf respondsToSelector:@selector(pause)]) [fnf pause];
}

static BOOL TPPlayerMayPlay(id player, long long reason) {
    if (![TPPrefs boolForKey:TPKeyNoAutoplay]) return YES;
    if (objc_getAssociatedObject(player, kTPUserStartedKey)) return YES;
    UIView *view = ((TPWeakBox *)objc_getAssociatedObject(player, kTPPlayerViewKey)).object;
    BOOL tapped = CFAbsoluteTimeGetCurrent() - gTPLastTapAt < 1.5;
    BOOL inFeed = !view || TPInsideFeedMediaCell(view);
    if (reason != 1 || tapped || !inFeed) {
        objc_setAssociatedObject(player, kTPUserStartedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (reason != 1) TPDebug([NSString stringWithFormat:@"%@ (%lld)", TPL(@"Playback allowed"), reason]);
        return YES;
    }
    TPDebug([NSString stringWithFormat:@"%@ (%lld)", TPL(@"Autoplay blocked"), reason]);
    return NO;
}

static void TPPlayVideoAtTouch(UITouch *t) {
    UIView *hit = t.view;
    Class vcls = TPVideoViewClass();
    if (!hit || !vcls) return;
    UIView *video = nil;
    for (UIView *v = hit; v; v = v.superview) if ([v isKindOfClass:vcls]) { video = v; break; }
    if (!video) {
        UIView *cell = hit;
        Class cellCls = TPFeedMediaCellClass();
        while (cell && !(cellCls && [cell isKindOfClass:cellCls])) cell = cell.superview;
        if (cell) video = TPFindView(cell, vcls, 30);
    }
    if (!video) return;
    id player = TPInnerPlayer(objc_getAssociatedObject(video, kTPPlayerKey));
    if (!player) { TPDebug(TPL(@"Tap: no video player found")); return; }
    objc_setAssociatedObject(player, kTPUserStartedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(player, kTPHeldKey)) return;
    TPSetHeld(player, NO);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id fnf = TPFNFPlayer(player);
        if (![fnf respondsToSelector:@selector(play)]) { TPDebug(TPL(@"Tap: no video player found")); return; }
        TPDebug(TPL(@"Tap: replaying video"));
        [fnf play];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (![player respondsToSelector:@selector(isPlaying)]) return;
            TPDebug(TPL([(id)player isPlaying] ? @"Tap: video is playing" : @"Tap: video still not playing"));
        });
    });
}

%group VideoSettings

%hook IGFNFVideoPlayer

- (void)playWithReason:(long long)reason callsiteContext:(id)context {
    BOOL may = TPPlayerMayPlay(self, reason);
    if ([TPPrefs boolForKey:TPKeyNoAutoplay]) TPSetHeld(self, !may);
    if (!objc_getAssociatedObject(self, kTPPlayerInitKey)) {
        objc_setAssociatedObject(self, kTPPlayerInitKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        float sp = TPSpeedForIndex([TPPrefs integerForKey:TPKeyPlaySpeed]);
        if (sp != 1.0f) { gTPApplyingDefault = YES; [(id)self setPlaybackSpeed:sp]; gTPApplyingDefault = NO; }
    }
    %orig;
}

- (void)stopWithReason:(long long)reason callsiteContext:(id)context {
    objc_setAssociatedObject(self, kTPUserStartedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (objc_getAssociatedObject(self, kTPHeldKey)) TPSetHeld(self, NO);
    %orig;
}

// Long-press 2x (and locking it) is Threads' own. Its release asks for 1x; with a default speed
// set, go back to that speed instead.
- (void)setPlaybackSpeed:(float)speed {
    float def = TPSpeedForIndex([TPPrefs integerForKey:TPKeyPlaySpeed]);
    if (!gTPApplyingDefault && def != 1.0f && speed == 1.0f) speed = def;
    %orig(speed);
}

%end

static BOOL TPFNFShouldSkipPlay(id fnf) {
    if (!objc_getAssociatedObject(fnf, kTPHeldKey)) return NO;
    if (objc_getAssociatedObject(fnf, kTPPrimedKey)) return YES;
    objc_setAssociatedObject(fnf, kTPPrimedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([fnf respondsToSelector:@selector(setVolume:rampTime:)]) [fnf setVolume:0 rampTime:0];
    return NO;
}

%hook FNFPlayer
- (void)play {
    if (TPFNFShouldSkipPlay(self)) return;
    %orig;
}
- (void)playWithContext:(id)context {
    if (TPFNFShouldSkipPlay(self)) return;
    %orig;
}
%end

// Disable Music Autoplay: music attached to posts plays through IGAudioPlayer or
// IGStatelessAudioPlayer. A start is let through only right after a tap on the music (or once the
// user has started that player); scrolling a post into view no longer starts it. Tapping the
// speaker icon turns the sound on through setAudioEnabled:, so that also starts a held player.
static const void *kTPMusicUserKey = &kTPMusicUserKey;
static const void *kTPMusicHeldKey = &kTPMusicHeldKey;
static CFAbsoluteTime gTPLastMusicTapAt = 0;

// Post music views are BCNFeedMusic… (the speaker icon sits inside them); audio posts are
// BCNFeedAudioAttachment…. Generic "Audio"/"Mute" names would also match a video's speaker button.
static BOOL TPIsMusicClassName(NSString *n) {
    return [n containsString:@"Music"] || [n containsString:@"AudioAttachment"];
}

// A tap on a post's music row or card, or its speaker icon.
static BOOL TPTouchIsOnMusic(UITouch *t) {
    int depth = 0;
    for (UIView *v = t.view; v && depth < 16; v = v.superview, depth++) {
        if (TPIsMusicClassName(NSStringFromClass(v.class))) return YES;
        if ([v isKindOfClass:[UICollectionViewCell class]]) break;
    }
    return NO;
}

static BOOL TPMusicMayStart(id player, long long reason) {
    if (![TPPrefs boolForKey:TPKeyNoMusicAutoplay] || objc_getAssociatedObject(player, kTPMusicUserKey)) return YES;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL tapped = now - gTPLastMusicTapAt < 1.5;
    if (!tapped) {
        // Keep the start reason: a held player is started later with the same (valid) reason.
        objc_setAssociatedObject(player, kTPMusicHeldKey, @(reason), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TPDebug([NSString stringWithFormat:@"%@ (%lld)", TPL(@"Music autoplay blocked"), reason]);
        return NO;
    }
    objc_setAssociatedObject(player, kTPMusicUserKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(player, kTPMusicHeldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static BOOL TPMusicAudioEnabled(id player) {
    return [player respondsToSelector:@selector(isAudioEnabled)] && ((BOOL (*)(id, SEL))objc_msgSend)(player, @selector(isAudioEnabled));
}

// The speaker icon was switched from off to on right after a tap on the music: start a held player, with the
// reason its own start had (the sound call's reason is a different kind of value).
static void TPMusicSoundTurnedOn(id player, BOOL enabled, BOOL wasEnabled) {
    if (!enabled || wasEnabled || ![TPPrefs boolForKey:TPKeyNoMusicAutoplay]) return;
    NSNumber *held = objc_getAssociatedObject(player, kTPMusicHeldKey);
    if (![held isKindOfClass:[NSNumber class]] || CFAbsoluteTimeGetCurrent() - gTPLastMusicTapAt > 1.5) return;
    objc_setAssociatedObject(player, kTPMusicUserKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(player, kTPMusicHeldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TPDebug(TPL(@"Tap: playing music"));
    ((void (*)(id, SEL, long long))objc_msgSend)(player, @selector(startPlaybackWith:), held.longLongValue);
}

%hook _TtC13IGAudioPlayer13IGAudioPlayer
- (void)startPlaybackWith:(long long)reason {
    if (!TPMusicMayStart(self, reason)) return;
    %orig;
}
- (void)stopPlaybackWith:(long long)reason {
    objc_setAssociatedObject(self, kTPMusicUserKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kTPMusicHeldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}
- (void)setAudioEnabled:(BOOL)enabled with:(long long)reason {
    BOOL was = TPMusicAudioEnabled(self);
    %orig;
    TPMusicSoundTurnedOn(self, enabled, was);
}
%end

%hook _TtC13IGAudioPlayer22IGStatelessAudioPlayer
- (void)startPlaybackWith:(long long)reason {
    if (!TPMusicMayStart(self, reason)) return;
    %orig;
}
- (void)stopPlaybackWith:(long long)reason {
    objc_setAssociatedObject(self, kTPMusicUserKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kTPMusicHeldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}
- (void)setAudioEnabled:(BOOL)enabled with:(long long)reason {
    BOOL was = TPMusicAudioEnabled(self);
    %orig;
    TPMusicSoundTurnedOn(self, enabled, was);
}
%end

%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    BOOL noAuto = [TPPrefs boolForKey:TPKeyNoAutoplay] || [TPPrefs boolForKey:TPKeyNoMusicAutoplay];
    if (event.type == UIEventTypeTouches && noAuto) {
        for (UITouch *t in event.allTouches) {
            if (t.phase == UITouchPhaseBegan) {
                CGPoint p = [t locationInView:nil];
                objc_setAssociatedObject(t, kTPTouchStartKey,
                    @[@(p.x), @(p.y), @(CFAbsoluteTimeGetCurrent())], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else if (t.phase == UITouchPhaseEnded) {
                NSArray *s = objc_getAssociatedObject(t, kTPTouchStartKey);
                if (s.count == 3) {
                    CGPoint p = [t locationInView:nil];
                    CGFloat dx = p.x - [s[0] doubleValue], dy = p.y - [s[1] doubleValue];
                    if (dx * dx + dy * dy < 15 * 15 && CFAbsoluteTimeGetCurrent() - [s[2] doubleValue] < 0.6) {
                        gTPLastTapAt = CFAbsoluteTimeGetCurrent();
                        if ([TPPrefs boolForKey:TPKeyNoAutoplay]) TPPlayVideoAtTouch(t);
                        if ([TPPrefs boolForKey:TPKeyNoMusicAutoplay] && TPTouchIsOnMusic(t)) gTPLastMusicTapAt = gTPLastTapAt;
                    }
                }
            }
        }
    }
    %orig;
}
%end

%end

// Post time format: Threads builds "3h" style labels through NSDate's relative-date category, so
// those methods return the format set in Post Time Format, which can include Threads' own text.
// These methods call one another (one shortened form is built from another). Only the outermost
// call is formatted: an inner call returns Threads' own text, or the outer call would take an
// already formatted time as its relative part and repeat the date.
static __thread int gTPTimeDepth;

static NSString *TPExactString(NSDate *date, id relative) {
    if (![date isKindOfClass:[NSDate class]]) return nil;
    return [TPPrefs postTimeForDate:date relative:[relative isKindOfClass:[NSString class]] ? relative : nil];
}

%group Time

%hook NSDate
- (id)formattedDateRelativeToNow {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
- (id)shortenedFormattedDateRelativeToNow {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
- (id)partiallyShortenedFormattedDateRelativeToNow {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
- (id)shortenedFormattedDateRelativeToNowIncludeYears {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
- (id)shortenedFormattedDateRelativeToNowWithOptions:(unsigned long long)o {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
- (id)partiallyShortenedFormattedDateRelativeToNowHideSeconds:(BOOL)s options:(unsigned long long)o {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
- (id)shortenedFormattedDateRelativeToNowWithFloorDaysWeeks:(BOOL)w {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
- (id)formattedDateRelativeToNowHideSeconds:(BOOL)s {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
- (id)formattedDateRelativeToNowHideSeconds:(BOOL)s shouldFloorDaysWeeks:(BOOL)w {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
- (id)shortenedFormattedDateRelativeToNowHideSeconds:(BOOL)s {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
- (id)shortenedFormattedDateRelativeToNowHideSeconds:(BOOL)s shouldFloorDaysWeeks:(BOOL)w {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
- (id)shortenedFormattedDateRelativeToNowHideSeconds:(BOOL)s shouldFloorDaysWeeks:(BOOL)w options:(unsigned long long)o {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
- (id)shortenedFormattedDateRelativeToNowHideSeconds:(BOOL)s shouldFloorDaysWeeks:(BOOL)w includeYears:(BOOL)y options:(unsigned long long)o {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
- (id)formattedDateRelativeToNowIncludingYearsHideSeconds:(BOOL)s {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
- (id)formattedDateRelativeToNowIncludingYearsHideSeconds:(BOOL)s shouldFloorDaysWeeks:(BOOL)w {
    gTPTimeDepth++;
    id orig = %orig;
    gTPTimeDepth--;
    if (gTPTimeDepth > 0) return orig;
    return TPExactString((NSDate *)self, orig) ?: orig;
}
%end

%end

// Like Confirmation. The UFI row is the Swift BCNUFIButton, but taps reach it through an ObjC
// target-action, so they can be intercepted. Its `type` is a payload-free enum stored in one
// byte: comment = 0, repost = 1, like = 2. `toggledState` is YES when already liked, and
// unliking is never confirmed.
static void TPConfirm(NSString *title, NSString *actionTitle, void (^go)(void)) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    UIAlertAction *ok = [UIAlertAction actionWithTitle:actionTitle style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *x) { if (go) go(); }];
    [a addAction:ok];
    a.preferredAction = ok;
    [TPTopViewController() presentViewController:a animated:YES completion:nil];
}

%group Interactions

%hook _TtC6BCNUFI12BCNUFIButton
- (void)didEndTappingButtonOnPurpose:(id)sender {
    if (![TPPrefs boolForKey:TPKeyConfirmLike]) { %orig; return; }
    uint8_t *type = TPIvarAddress(self, "type");
    uint8_t *toggled = TPIvarAddress(self, "toggledState");
    BOOL isLike = type && *type == 2;
    BOOL alreadyLiked = toggled && *toggled != 0;
    if (!isLike || alreadyLiked) { %orig; return; }
    TPDebug(TPL(@"Like confirmation shown"));
    TPConfirm(TPL(@"Like this post?"), TPL(@"Like"), ^{ %orig; });
}
%end

%end

static const void *kTPAvatarBtnKey = &kTPAvatarBtnKey;

static NSURL *TPURLFromImageSpecifier(id spec) {
    if (!spec) return nil;
    id imgURL = [TPDownloader ivarValue:spec name:@"_remoteImage_imageURL"];
    if (!imgURL) imgURL = [TPDownloader ivarValue:spec name:@"_prefetchedAdaptiveRemoteImageDEPRECATED_imageURL"];
    id u = [TPDownloader safeValue:imgURL key:@"url"];
    return [u isKindOfClass:[NSURL class]] ? u : nil;
}

static NSURL *TPURLFromString(id s) {
    if ([s isKindOfClass:[NSURL class]]) return s;
    if ([s isKindOfClass:[NSString class]] && [s length]) return [NSURL URLWithString:s];
    return nil;
}

static void TPDownloadAvatarFromPictureView(UIView *pic);

static void TPDownloadAvatar(UIViewController *vc) {
    TPDownloadAvatarFromPictureView([TPDownloader ivarValue:vc name:@"profilePictureView"]);
}

static void TPDownloadAvatarFromPictureView(UIView *pic) {
    id profileImage = [TPDownloader safeValue:pic key:@"image"];
    id user = [TPDownloader ivarValue:profileImage name:@"_profileImageModel_user"];

    NSURL *hd = nil;
    for (NSString *frag in @[@"asIGUserHDProfilePicURLFragment", @"asIGUserHDProfilePicImageURLFragment"]) {
        id info = [TPDownloader safeValue:[TPDownloader safeValue:user key:frag] key:@"hdProfilePicUrlInfo"];
        hd = TPURLFromString([TPDownloader safeValue:info key:@"urlString"]);
        if (hd) break;
    }
    NSURL *shown = TPURLFromImageSpecifier([TPDownloader ivarValue:profileImage name:@"_imageSpecifier"]);
    id derived = [TPDownloader safeValue:user key:@"asIGUserDerivedProfilePicURLFragment"];
    NSURL *normal = TPURLFromString([TPDownloader safeValue:derived key:@"computedProfilePicURLString"])
                 ?: TPURLFromString([TPDownloader safeValue:derived key:@"profilePicURLString"]);

    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSURL *u in @[hd ?: (id)NSNull.null, shown ?: (id)NSNull.null, normal ?: (id)NSNull.null]) {
        if ([u isKindOfClass:[NSURL class]] && ![urls containsObject:u]) [urls addObject:u];
    }
    UIImageView *shownView = pic ? TPLargestImageView(pic) : nil;
    if (!urls.count && !shownView.image) { [TPHUD toast:TPL(@"No image found")]; return; }

    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[@"video"] = @NO;
    item[@"urls"] = urls;
    if (urls.firstObject) item[@"key"] = TPDedupeKey(urls.firstObject);
    if (shownView.image) item[@"image"] = shownView.image;

    id username = [TPDownloader safeValue:user key:@"username"];
    [TPDownloader appendPendingReport:[NSString stringWithFormat:@"[avatar] @%@ · hd %@ · shown %@\n",
                                       username ?: @"?", hd ? @"yes" : @"no", shown ? @"yes" : @"no"]];

    NSMutableDictionary *ctx = [NSMutableDictionary dictionaryWithObject:@"avatar" forKey:@"kind"];
    if ([username isKindOfClass:[NSString class]] && [username length]) ctx[@"author"] = username;
    if ([TPPrefs boolForKey:TPKeyOriginalAvatar] && [username isKindOfClass:[NSString class]] && [username length] && item[@"key"]) {
        NSURL *page = [NSURL URLWithString:[@"https://www.threads.com/@" stringByAppendingString:username]];
        TPUpgradeFromPage(page, YES, [@"@" stringByAppendingString:username], TPL(@"Getting original photo…"), @[item],
                          ^(NSArray<NSDictionary *> *upgraded) { [TPDownloader downloadItems:upgraded context:ctx]; });
    } else {
        [TPDownloader downloadItems:@[item] context:ctx];
    }
}

static void TPEnsureAvatarButton(UIViewController *vc) {
    UIView *host = vc.view;
    if (!host.window) return;
    UIButton *b = objc_getAssociatedObject(vc, kTPAvatarBtnKey);
    if (![TPPrefs boolForKey:TPKeyShowDownloadBtn]) { b.hidden = YES; return; }

    const CGFloat d = 46;
    if (!b) {
        __weak UIViewController *wvc = vc;
        b = [TPUI circleButtonWithSymbol:@"arrow.down.to.line" diameter:d onTap:^{
            if (wvc) TPDownloadAvatar(wvc);
        } menuItems:@[TPManagerMenuItem()]];
        b.accessibilityLabel = TPL(@"Save Profile Picture");
        [host addSubview:b];
        objc_setAssociatedObject(vc, kTPAvatarBtnKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    b.hidden = NO;
    CGRect bounds = host.bounds;
    b.frame = CGRectMake(CGRectGetMaxX(bounds) - d - 24,
                         CGRectGetMaxY(bounds) - host.safeAreaInsets.bottom - d - 28, d, d);
    if (host.subviews.lastObject != b) [host bringSubviewToFront:b];
}

// Copy Profile Info: long-press gestures on the profile picture, name, username and bio.
// When the feature is off the gestures refuse to begin, so Threads' own long-presses still work.
static const void *kTPProfilePressKey = &kTPProfilePressKey;
static Class gTPProfileHeaderClass;

static UIView *TPProfileHeaderFor(UIView *v) {
    for (; v; v = v.superview) if (gTPProfileHeaderClass && [v isKindOfClass:gTPProfileHeaderClass]) return v;
    return nil;
}

static NSString *TPStyledText(id styled) {
    id attr = [TPDownloader safeValue:styled key:@"attributedString"];
    return [attr isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString *)attr string] : nil;
}

static NSString *TPTrimmed(NSString *s) {
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length ? s : nil;
}

static NSString *TPProfileName(UIView *header) {
    UILabel *l = [TPDownloader ivarValue:header name:@"fullNameLabel"];
    return [l isKindOfClass:[UILabel class]] ? TPTrimmed(l.text) : nil;
}

static NSString *TPProfileUsername(UIView *header) {
    UILabel *l = [TPDownloader ivarValue:header name:@"usernameLabel"];
    NSString *u = [l isKindOfClass:[UILabel class]] ? TPTrimmed(l.text) : nil;
    return [u hasPrefix:@"@"] ? [u substringFromIndex:1] : u;
}

static NSString *TPProfileBio(UIView *header) {
    UIView *bio = TPFindView(header, objc_getClass("IGProfileBioView"), 8);
    if (!bio) return nil;
    NSString *t = TPTrimmed(TPStyledText([TPDownloader ivarValue:bio name:@"_fullCollapsibleBioString"]));
    if (!t) t = TPTrimmed(TPStyledText([TPDownloader ivarValue:bio name:@"_stringForView"]));
    if (!t) {
        id c = [TPDownloader safeValue:bio key:@"contentString"];
        t = TPTrimmed([c isKindOfClass:[NSString class]] ? c : TPStyledText(c));
    }
    return t;
}

static void TPCopyText(NSString *text) {
    UIPasteboard.generalPasteboard.string = text;
    [TPUI hapticLight];
    [TPHUD toast:TPL(@"Copied")];
}

@interface TPProfilePressHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)pressed:(UILongPressGestureRecognizer *)g;
@end

@implementation TPProfilePressHandler
+ (instancetype)shared {
    static TPProfilePressHandler *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [TPProfilePressHandler new]; });
    return h;
}

static void TPAddSheetAction(UIAlertController *sheet, NSString *title, NSString *symbol, void (^handler)(void)) {
    UIAlertAction *a = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction *x) { handler(); }];
    @try { [a setValue:[UIImage systemImageNamed:symbol] forKey:@"image"]; } @catch (__unused id e) {}
    [sheet addAction:a];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    UIView *header = TPProfileHeaderFor(g.view);
    BOOL isPicture = [g.view isEqual:[TPDownloader ivarValue:header name:@"profilePictureView"]];
    return [TPPrefs boolForKey:TPKeyCopyProfile] || (isPicture && [TPPrefs boolForKey:TPKeyShowDownloadBtn]);
}

- (void)pressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIView *src = g.view;
    UIView *header = TPProfileHeaderFor(src);
    BOOL isPicture = [src isEqual:[TPDownloader ivarValue:header name:@"profilePictureView"]];
    BOOL canSave = isPicture && [TPPrefs boolForKey:TPKeyShowDownloadBtn];
    BOOL canCopy = [TPPrefs boolForKey:TPKeyCopyProfile];
    NSString *name = canCopy ? TPProfileName(header) : nil;
    NSString *username = canCopy ? TPProfileUsername(header) : nil;
    NSString *bio = canCopy ? TPProfileBio(header) : nil;
    if (!canSave && !name && !username && !bio) return;

    [TPUI hapticLight];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak UIView *wsrc = src;
    if (canSave) TPAddSheetAction(sheet, TPL(@"Save Profile Picture"), @"arrow.down.to.line", ^{ if (wsrc) TPDownloadAvatarFromPictureView(wsrc); });
    if (name)     TPAddSheetAction(sheet, TPL(@"Copy Name"), @"person.text.rectangle", ^{ TPCopyText(name); });
    if (username) TPAddSheetAction(sheet, TPL(@"Copy Username"), @"at", ^{ TPCopyText(username); });
    if (bio)      TPAddSheetAction(sheet, TPL(@"Copy Bio"), @"text.quote", ^{ TPCopyText(bio); });
    [sheet addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = src;
    sheet.popoverPresentationController.sourceRect = src.bounds;
    [TPTopViewController() presentViewController:sheet animated:YES completion:nil];
}
@end

static void TPAddProfilePress(UIView *v, BOOL takeOverExisting) {
    if (![v isKindOfClass:[UIView class]] || objc_getAssociatedObject(v, kTPProfilePressKey)) return;
    UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:[TPProfilePressHandler shared]
                                                                                    action:@selector(pressed:)];
    g.minimumPressDuration = 0.45;
    g.delegate = [TPProfilePressHandler shared];
    if (takeOverExisting) {
        for (UIGestureRecognizer *other in v.gestureRecognizers)
            if ([other isKindOfClass:[UILongPressGestureRecognizer class]]) [other requireGestureRecognizerToFail:g];
    }
    v.userInteractionEnabled = YES;
    [v addGestureRecognizer:g];
    objc_setAssociatedObject(v, kTPProfilePressKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void TPEnsureProfilePress(UIView *header) {
    TPAddProfilePress([TPDownloader ivarValue:header name:@"profilePictureView"], NO);
    if (![TPPrefs boolForKey:TPKeyCopyProfile]) return;
    TPAddProfilePress([TPDownloader ivarValue:header name:@"usernameLabel"], NO);
    TPAddProfilePress([TPDownloader ivarValue:header name:@"fullNameLabel"], NO);
    TPAddProfilePress(TPFindView(header, objc_getClass("IGProfileBioView"), 8), YES);
}

// Profile cover photo (BCNProfileCoverPhotoView → coverPhotoView: BCNCoverPhotoView → imageView:
// IGImageView). Long-press it to save the photo. Only active while a cover photo is shown, so the
// "add cover photo" button on your own profile keeps working.
static const void *kTPCoverPressKey = &kTPCoverPressKey;

static UIView *TPCoverImageView(UIView *coverHost) {
    UIView *cover = [TPDownloader ivarValue:coverHost name:@"coverPhotoView"];
    id iv = [TPDownloader ivarValue:cover name:@"imageView"];
    return [iv isKindOfClass:[UIView class]] ? iv : nil;
}

static NSString *TPUsernameNearCover(UIView *coverHost) {
    for (UIResponder *r = coverHost; r; r = r.nextResponder) {
        if (![r isKindOfClass:[UIViewController class]]) continue;
        UIView *header = gTPProfileHeaderClass ? TPFindView(((UIViewController *)r).view, gTPProfileHeaderClass, 14) : nil;
        NSString *u = header ? TPProfileUsername(header) : nil;
        if (u.length) return u;
    }
    return nil;
}

static void TPDownloadCoverPhoto(UIView *coverHost) {
    UIView *iv = TPCoverImageView(coverHost);
    NSURL *url = TPURLFromImageSpecifier([TPDownloader safeValue:iv key:@"imageSpecifier"]);
    id img = [TPDownloader safeValue:iv key:@"image"];
    UIImage *shown = [img isKindOfClass:[UIImage class]] ? img : nil;
    if (!url && !shown) { [TPHUD toast:TPL(@"No image found")]; return; }
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[@"video"] = @NO;
    item[@"urls"] = url ? @[url] : @[];
    if (url) item[@"key"] = TPDedupeKey(url);
    if (shown) item[@"image"] = shown;
    NSMutableDictionary *ctx = [NSMutableDictionary dictionaryWithObject:@"cover" forKey:@"kind"];
    NSString *u = TPUsernameNearCover(coverHost);
    if (u.length) ctx[@"author"] = u;
    [TPDownloader appendPendingReport:[NSString stringWithFormat:@"[cover] @%@ · url %@ · shown %@\n",
                                       u ?: @"?", url ? @"yes" : @"no", shown ? @"yes" : @"no"]];
    [TPDownloader downloadItems:@[item] context:ctx];
}

@interface TPCoverPressHandler : NSObject <UIGestureRecognizerDelegate>
@end
@implementation TPCoverPressHandler
+ (instancetype)shared {
    static TPCoverPressHandler *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [self new]; });
    return h;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (![TPPrefs boolForKey:TPKeyShowDownloadBtn]) return NO;
    UIView *iv = TPCoverImageView(g.view);
    id img = [TPDownloader safeValue:iv key:@"image"];
    return [img isKindOfClass:[UIImage class]] && !iv.hidden && iv.alpha > 0.01;
}
- (void)pressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIView *src = g.view;
    [TPUI hapticLight];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak UIView *wsrc = src;
    TPAddSheetAction(sheet, TPL(@"Save Cover Photo"), @"arrow.down.to.line", ^{ if (wsrc) TPDownloadCoverPhoto(wsrc); });
    [sheet addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    CGPoint pt = [g locationInView:src];
    sheet.popoverPresentationController.sourceView = src;
    sheet.popoverPresentationController.sourceRect = CGRectMake(pt.x, pt.y, 1, 1);
    [TPTopViewController() presentViewController:sheet animated:YES completion:nil];
}
@end

%group Avatar

%hook _TtC10BCNProfile24BCNProfileCoverPhotoView
- (void)willMoveToWindow:(UIWindow *)window {
    %orig;
    UIView *v = (UIView *)self;
    if (!window || objc_getAssociatedObject(v, kTPCoverPressKey)) return;
    UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:[TPCoverPressHandler shared]
                                                                                    action:@selector(pressed:)];
    g.minimumPressDuration = 0.45;
    g.delegate = [TPCoverPressHandler shared];
    [v addGestureRecognizer:g];
    objc_setAssociatedObject(v, kTPCoverPressKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end

%hook _TtC17BCNProfilePicture41BCNProfilePictureFullscreenViewController
- (void)viewDidLayoutSubviews {
    %orig;
    TPEnsureAvatarButton((UIViewController *)self);
}
%end

%hook _TtC10BCNProfile20BCNProfileHeaderView
- (void)layoutSubviews {
    %orig;
    TPEnsureProfilePress((UIView *)self);
}
%end

%end

// Ways to open the settings: the Pulse button in Threads' settings, a three-finger long-press,
// and a long-press on the Home tab.
static const void *kTPGestureKey3 = &kTPGestureKey3;

// The three-finger gesture recognizes alongside everything else. Once it begins, the other
// recognizers on the same touches are disabled and re-enabled, which cancels them; otherwise
// lifting the fingers would also trigger whatever button was touched first.
@interface TPThreeFingerHelper : NSObject <UIGestureRecognizerDelegate>
@end

@implementation TPThreeFingerHelper {
    NSHashTable<UITouch *> *_touches;
}
+ (instancetype)shared {
    static TPThreeFingerHelper *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [self new]; });
    return h;
}
- (instancetype)init {
    if ((self = [super init])) _touches = [NSHashTable weakObjectsHashTable];
    return self;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    for (UITouch *t in _touches.allObjects)
        if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) [_touches removeObject:t];
    [_touches addObject:touch];
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (void)cancelOtherGesturesExcept:(UIGestureRecognizer *)mine {
    for (UITouch *t in _touches.allObjects) {
        for (UIGestureRecognizer *g in t.gestureRecognizers) {
            if (g == mine || !g.enabled) continue;
            g.enabled = NO;
            g.enabled = YES;
        }
    }
    [_touches removeAllObjects];
}
@end

%group Menu

static NSString *const kTPEntryID = @"ThreadsPulseEntry";

static void TPTintEntryButton(UIButton *b) {
    if (![b isKindOfClass:[UIButton class]] || !b.configuration) return;
    UIButtonConfiguration *cfg = b.configuration;
    cfg.baseForegroundColor = [TPUI accentIcon];
    b.configuration = cfg;
}

%hook _TtC11BCNSettings25BCNSettingsViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIViewController *vc = (UIViewController *)self;
    NSMutableArray *items = [vc.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    for (UIBarButtonItem *i in items) if ([i.customView.accessibilityIdentifier isEqualToString:kTPEntryID]) {
        TPTintEntryButton((UIButton *)i.customView);
        return;
    }

    UIColor *tint = [TPUI accentIcon];
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.title = @"Pulse";
    cfg.image = [UIImage systemImageNamed:@"waveform.path.ecg"
                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]];
    cfg.imagePadding = 4;
    cfg.baseForegroundColor = tint;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(4, 4, 4, 0);
    cfg.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) {
        NSMutableDictionary *m = [a mutableCopy];
        m[NSFontAttributeName] = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        return m;
    };
    __weak UIViewController *wvc = vc;
    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
        if (wvc) [TPSettingsViewController present];
    }]];
    b.accessibilityIdentifier = kTPEntryID;
    b.accessibilityLabel = @"ThreadsPulse";
    [b sizeToFit];
    __weak UIButton *wb = b;
    [[NSNotificationCenter defaultCenter] addObserverForName:TPThemeDidChangeNotification object:nil
                                                       queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (wb) TPTintEntryButton(wb);
    }];
    [items addObject:[[UIBarButtonItem alloc] initWithCustomView:b]];
    vc.navigationItem.rightBarButtonItems = items;
}
%end

%hook UIWindow

- (void)becomeKeyWindow {
    %orig;
    if (!objc_getAssociatedObject(self, kTPGestureKey3)) {
        UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(tp_threeFingerLongPress:)];
        g.numberOfTouchesRequired = 3;
        g.minimumPressDuration = 1.0;
        g.cancelsTouchesInView = YES;
        g.delegate = [TPThreeFingerHelper shared];
        [(UIWindow *)self addGestureRecognizer:g];
        objc_setAssociatedObject(self, kTPGestureKey3, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%new
- (void)tp_threeFingerLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [[TPThreeFingerHelper shared] cancelOtherGesturesExcept:g];
    [TPUI hapticLight];
    [TPSettingsViewController present];
}

%end

%end

// Copied-link detection. detectPatternsForPatterns: only reports whether the clipboard holds a
// URL, so no paste prompt appears until the user taps Open (or chose Auto-open). The link is
// handed to Threads as an NSUserActivity so Threads routes it itself.
static BOOL TPIsThreadsURL(NSURL *u) {
    NSString *host = u.host.lowercaseString;
    if (![u.scheme.lowercaseString hasPrefix:@"http"]) return NO;
    BOOL threads = [host isEqualToString:@"threads.com"] || [host hasSuffix:@".threads.com"] ||
                   [host isEqualToString:@"threads.net"] || [host hasSuffix:@".threads.net"];
    return threads && u.path.length > 1;
}

static void TPOpenInThreads(NSURL *url) {
    NSUserActivity *act = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    act.webpageURL = url;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        id<UISceneDelegate> d = scene.delegate;
        if ([d respondsToSelector:@selector(scene:continueUserActivity:)]) {
            [d scene:scene continueUserActivity:act];
            TPDebug(TPL(@"Opened link from clipboard"));
            return;
        }
    }
    id<UIApplicationDelegate> ad = UIApplication.sharedApplication.delegate;
    if ([ad respondsToSelector:@selector(application:continueUserActivity:restorationHandler:)]) {
        [ad application:UIApplication.sharedApplication continueUserActivity:act restorationHandler:^(NSArray *r) {}];
        return;
    }
    [UIApplication.sharedApplication openURL:url options:@{ UIApplicationOpenURLOptionUniversalLinksOnly: @YES } completionHandler:nil];
}

static void TPOpenClipboardLinkSilently(BOOL silent);
static void TPOpenClipboardLink(void) { TPOpenClipboardLinkSilently(NO); }

static void TPOpenClipboardLinkSilently(BOOL silent) {
    UIPasteboard *pb = UIPasteboard.generalPasteboard;
    NSURL *url = pb.hasURLs ? pb.URL : nil;
    if (!TPIsThreadsURL(url)) {
        url = nil;
        NSString *text = pb.hasStrings ? pb.string : nil;
        if (text.length) {
            NSDataDetector *det = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
            for (NSTextCheckingResult *m in [det matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
                if (TPIsThreadsURL(m.URL)) { url = m.URL; break; }
            }
        }
    }
    if (!url) { if (!silent) [TPHUD toast:TPL(@"The copied link isn't a Threads link")]; return; }
    TPOpenInThreads([TPURLCleaner cleanURL:url]);
}

// Last time the keyboard came up over a sheet (the add-account / login screens are such a sheet).
static CFAbsoluteTime gTPSheetKeyboardAt = 0;
static BOOL gTPKeyboardVisible = NO;

static void TPCheckClipboardForced(BOOL force) {
    if (![TPPrefs boolForKey:TPKeyClipboardLinks]) return;
    UIPasteboard *pb = UIPasteboard.generalPasteboard;
    NSInteger cc = pb.changeCount;
    if (!force) {
        if (cc == gTPOwnPasteboardChange) return;
        if (cc == [TPPrefs integerForKey:@"tp_clip_last_change"]) return;
    }
    [TPPrefs setInteger:cc forKey:@"tp_clip_last_change"];

    NSSet *patterns = [NSSet setWithObject:UIPasteboardDetectionPatternProbableWebURL];
    [pb detectPatternsForPatterns:patterns completionHandler:^(NSSet *found, NSError *err) {
        if (![found containsObject:UIPasteboardDetectionPatternProbableWebURL]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([TPPrefs integerForKey:TPKeyClipboardMode] == 1) {
                // Never jump away from a screen being filled in (login, posting, replying): the
                // keyboard is up or a sheet covers the app. Show the prompt instead, so the link
                // is one tap away once done.
                UIViewController *root = UIApplication.sharedApplication.keyWindow.rootViewController;
                if (!gTPKeyboardVisible && !root.presentedViewController) {
                    TPOpenClipboardLinkSilently(YES);
                    return;
                }
            }
            [TPHUD bannerWithText:TPL(@"Link copied") symbol:@"link" action:TPL(@"Open")
                         position:[TPPrefs integerForKey:TPKeyBannerPosition]
                          handler:^{ TPOpenClipboardLink(); }];
        });
    }];
}

static void TPCheckClipboard(void) { TPCheckClipboardForced(NO); }

// Instead of a fixed delay, check the clipboard as soon as the home feed is on screen: after a
// cold launch, and after switching accounts (where it waits for the *new* account's home feed, so
// the link never opens in the old account or gets covered by the rebuilt UI). If the home feed
// doesn't show up within the timeout (e.g. the switch lands on another tab), check anyway.
static NSUInteger gTPReadyGen;
static BOOL gTPWaitHome, gTPWaitForce;
static __weak UIViewController *gTPHomeVC;          // last home feed that appeared
static __weak UIViewController *gTPHomeVCAtRequest; // must not count as "ready" after a switch

static void TPFireReadyCheck(void) {
    if (!gTPWaitHome) return;
    gTPWaitHome = NO;
    BOOL force = gTPWaitForce;
    gTPWaitForce = NO;
    gTPHomeVCAtRequest = nil;
    // Logging in to a new account rebuilds the UI like a switch does. Don't open the copied link
    // then: opening a post Threads associates with another of the user's accounts makes it switch
    // straight back, undoing the login.
    if (force && CFAbsoluteTimeGetCurrent() - gTPSheetKeyboardAt < 180) {
        gTPSheetKeyboardAt = 0;
        TPDebug(TPL(@"Account switched"));
        return;
    }
    if (force) TPDebug(TPL(@"Account switched"));
    TPCheckClipboardForced(force);
}

static void TPCheckClipboardWhenHomeReady(BOOL force, BOOL needNewHome, double timeout) {
    if (![TPPrefs boolForKey:TPKeyClipboardLinks]) return;
    // A switch fires several events; remember the home feed from before the first one only.
    if (needNewHome && !(gTPWaitHome && gTPWaitForce)) gTPHomeVCAtRequest = gTPHomeVC;
    gTPWaitHome = YES;
    gTPWaitForce = gTPWaitForce || force;
    NSUInteger mine = ++gTPReadyGen;
    if (!needNewHome && gTPHomeVC.viewIfLoaded.window) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (mine == gTPReadyGen) TPFireReadyCheck();
        });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine != gTPReadyGen) return;
        // Adding or logging in to an account rebuilds the UI too, but shows the login screens
        // instead of a home feed. Only open the link once a home feed is actually on screen:
        // until then keep waiting for it (TPHomeFeedAppeared fires the check), and give up
        // after a couple of minutes.
        UIViewController *root = gTPHomeVC.viewIfLoaded.window.rootViewController;
        BOOL homeReady = gTPHomeVC.viewIfLoaded.window && gTPHomeVC != gTPHomeVCAtRequest && !root.presentedViewController;
        if (needNewHome && !homeReady) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (mine == gTPReadyGen && gTPWaitHome) { gTPWaitHome = NO; gTPWaitForce = NO; gTPHomeVCAtRequest = nil; }
            });
            return;
        }
        TPFireReadyCheck();
    });
}

static void TPHomeFeedAppeared(UIViewController *vc) {
    gTPHomeVC = vc;
    if (!gTPWaitHome) return;
    if (gTPHomeVCAtRequest && vc == gTPHomeVCAtRequest) return;  // still the old account's feed
    NSUInteger mine = gTPReadyGen;
    // A short beat so the first layout pass finishes before Threads is asked to open a link.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine == gTPReadyGen) TPFireReadyCheck();
    });
}

static void TPScheduleClipboardCheckAfterSwitch(void) {
    TPCheckClipboardWhenHomeReady(YES, YES, 3.0);
}

%group ClipboardReady
%hook _TtC11BCNMainFeed25BCNMainFeedViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    TPHomeFeedAppeared((UIViewController *)self);
}
%end
%end

// Mute Refresh Sound. Threads plays the refresh sound (BCNRefreshSounds.bundle) as a system
// sound. Its own on/off switch can be lost on re-signed installs, so the sound IDs created from
// that bundle are noted and not played while this is on.
static OSStatus (*orig_AudioServicesCreateSystemSoundID)(CFURLRef, SystemSoundID *);
static void (*orig_AudioServicesPlaySystemSound)(SystemSoundID);
static void (*orig_AudioServicesPlaySystemSoundWithCompletion)(SystemSoundID, void (^)(void));
static NSMutableSet<NSNumber *> *gTPRefreshSoundIDs;

static BOOL TPIsMutedRefreshSound(SystemSoundID sid) {
    if (![TPPrefs boolForKey:TPKeyMuteRefreshSound]) return NO;
    @synchronized (gTPRefreshSoundIDs) { return [gTPRefreshSoundIDs containsObject:@(sid)]; }
}
static OSStatus tp_AudioServicesCreateSystemSoundID(CFURLRef url, SystemSoundID *outID) {
    OSStatus st = orig_AudioServicesCreateSystemSoundID(url, outID);
    NSString *path = [(__bridge NSURL *)url path];
    if (st == noErr && outID && [path rangeOfString:@"RefreshSound"].location != NSNotFound) {
        @synchronized (gTPRefreshSoundIDs) { [gTPRefreshSoundIDs addObject:@(*outID)]; }
    }
    return st;
}
static void tp_AudioServicesPlaySystemSound(SystemSoundID sid) {
    if (TPIsMutedRefreshSound(sid)) return;
    orig_AudioServicesPlaySystemSound(sid);
}
static void tp_AudioServicesPlaySystemSoundWithCompletion(SystemSoundID sid, void (^done)(void)) {
    if (TPIsMutedRefreshSound(sid)) { if (done) dispatch_async(dispatch_get_main_queue(), done); return; }
    orig_AudioServicesPlaySystemSoundWithCompletion(sid, done);
}
static void TPInstallMuteRefreshSound(void) {
    gTPRefreshSoundIDs = [NSMutableSet set];
    orig_AudioServicesCreateSystemSoundID = dlsym(RTLD_DEFAULT, "AudioServicesCreateSystemSoundID");
    orig_AudioServicesPlaySystemSound = dlsym(RTLD_DEFAULT, "AudioServicesPlaySystemSound");
    orig_AudioServicesPlaySystemSoundWithCompletion = dlsym(RTLD_DEFAULT, "AudioServicesPlaySystemSoundWithCompletion");
    if (!orig_AudioServicesCreateSystemSoundID || !orig_AudioServicesPlaySystemSound || !orig_AudioServicesPlaySystemSoundWithCompletion) return;
    TPRebindSymbols((const char *[]){ "AudioServicesCreateSystemSoundID", "AudioServicesPlaySystemSound", "AudioServicesPlaySystemSoundWithCompletion" },
                    (void *[]){ (void *)tp_AudioServicesCreateSystemSoundID, (void *)tp_AudioServicesPlaySystemSound,
                                (void *)tp_AudioServicesPlaySystemSoundWithCompletion }, 3);
}

%group AccountSwitch

%hook IGAccountSwitcher
- (long long)switchToUser:(id)user destinationAppSurface:(id)surface destinationURL:(id)url entryPoint:(long long)point loggingData:(id)data {
    long long r = %orig;
    TPScheduleClipboardCheckAfterSwitch();
    return r;
}
- (long long)switchToUserWithPK:(id)pk destinationAppSurface:(id)surface destinationURL:(id)url entryPoint:(long long)point loggingData:(id)data {
    long long r = %orig;
    TPScheduleClipboardCheckAfterSwitch();
    return r;
}
- (void)recreateViewHierarchyForCurrentUserWithDestinationAppSurface:(id)surface {
    %orig;
    TPScheduleClipboardCheckAfterSwitch();
}
%end

%end

// Keep Feed Position. Coming back from the background, Threads decides how long the app was
// away from three places: IGWarmStartListener's applicationWillWarmStartWithTimeInterval...
// (home feed and BCNAppViewController), the feed's own lastBgTime, and the server thresholds
// in IGFeedRefreshInstructionsStore. Within the keep time all three report a short absence.
// Pull to refresh and cold launches are unaffected.
static CFAbsoluteTime gTPBackgroundedAt = 0;
static BOOL gTPWentBackground = NO;   // the app really went to the background since it was last active

static double TPKeepFeedLimitSeconds(void) {
    switch ([TPPrefs integerForKey:TPKeyKeepFeedLimit]) {
        case 0:  return 10 * 60;
        case 1:  return 30 * 60;
        default: return 0;
    }
}

static BOOL TPShouldKeepFeed(void) {
    static CFAbsoluteTime decidedAt = 0;
    static BOOL decided = NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - decidedAt < 10.0) return decided;

    BOOL keep = NO;
    if ([TPPrefs boolForKey:TPKeyKeepFeed] && gTPBackgroundedAt > 0) {
        double limit = TPKeepFeedLimitSeconds();
        keep = (limit == 0 || now - gTPBackgroundedAt < limit);
    }
    decidedAt = now;
    decided = keep;
    if (keep) TPDebug(TPL(@"Feed position kept"));
    return keep;
}

static void TPSetOptionalDateNow(id obj, const char *name) {
    Class cls = object_getClass(obj);
    Ivar iv = class_getInstanceVariable(cls, name);
    if (!iv) return;
    ptrdiff_t off = ivar_getOffset(iv);
    ptrdiff_t next = (ptrdiff_t)class_getInstanceSize(cls);
    unsigned int n = 0;
    Ivar *list = class_copyIvarList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        ptrdiff_t o = ivar_getOffset(list[i]);
        if (o > off && o < next) next = o;
    }
    free(list);
    if (next - off < 9) return;
    uint8_t *p = (uint8_t *)(__bridge void *)obj + off;
    double t = CFAbsoluteTimeGetCurrent();
    memcpy(p, &t, sizeof(double));
    p[8] = 0;
}

static NSNumber *TPKeepFeedThreshold(NSNumber *orig) {
    if (![TPPrefs boolForKey:TPKeyKeepFeed]) return orig;
    double limit = TPKeepFeedLimitSeconds();
    if (limit == 0) return @(1.0e9);
    return (orig && orig.doubleValue >= limit) ? orig : @(limit);
}

%group KeepFeed

%hook _TtC11BCNMainFeed25BCNMainFeedViewController
- (void)applicationWillWarmStartWithTimeIntervalSinceBackgrounded:(double)backgrounded {
    %orig(TPShouldKeepFeed() ? 0.0 : backgrounded);
}
- (void)willEnterForeground {
    if (TPShouldKeepFeed()) TPSetOptionalDateNow(self, "lastBgTime");
    %orig;
}
%end

%hook BCNAppViewController
- (void)applicationWillWarmStartWithTimeIntervalSinceBackgrounded:(double)backgrounded {
    %orig(TPShouldKeepFeed() ? 0.0 : backgrounded);
}
%end

%hook _TtC30IGFeedRefreshInstructionsStore30IGFeedRefreshInstructionsStore
- (NSNumber *)warmStartRefreshInterval                   { return TPKeepFeedThreshold(%orig); }
- (NSNumber *)warmStartRefreshIntervalOnPeak             { return TPKeepFeedThreshold(%orig); }
- (NSNumber *)minimumWarmStartBackgroundedInterval       { return TPKeepFeedThreshold(%orig); }
- (NSNumber *)minimumWarmStartBackgroundedIntervalOnPeak { return TPKeepFeedThreshold(%orig); }
%end

%end

// Home tab taps: Threads scrolls to top when the feed is scrolled down, and refreshes when it
// is already at the top.
// - New tab bar (BCNLucentTabBarCoordinator): the decision happens in ObjC methods, so the tap
//   is simply not passed on.
// - Legacy tab bar (BCNLegacyTabBarController): the decision is in Swift and can't be reached.
//   The tap time is recorded and upward scrolls / refreshes of the feed are blocked for 1 s.
//   These fallback hooks are only installed the first time the legacy tab bar is tapped.
static Class gTPMainFeedClass;
static __weak UIViewController *gTPMainFeedVC;

static CGFloat TPTopOffset(UIScrollView *sv) { return -sv.adjustedContentInset.top; }

static BOOL TPIsMainFeedScrollView(UIScrollView *sv) {
    if (!gTPMainFeedClass) return NO;
    for (UIResponder *r = sv.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) return [r isKindOfClass:gTPMainFeedClass];
    }
    return NO;
}

static UIScrollView *TPVisibleMainFeedScrollView(void) {
    UIViewController *vc = gTPMainFeedVC;
    if (!vc || !vc.isViewLoaded || !vc.view.window) return nil;
    UIScrollView *best = nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:vc.view];
    while (queue.count) {
        UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UICollectionView class]] && TPIsMainFeedScrollView((UIScrollView *)v)
            && (!best || v.bounds.size.height > best.bounds.size.height)) best = (UIScrollView *)v;
        [queue addObjectsFromArray:v.subviews];
    }
    return best;
}

static BOOL TPShouldBlockHomeReselect(void) {
    BOOL noTop = [TPPrefs boolForKey:TPKeyTabNoScrollTop], noRefresh = [TPPrefs boolForKey:TPKeyTabNoRefresh];
    if (!noTop && !noRefresh) return NO;
    UIScrollView *sv = TPVisibleMainFeedScrollView();
    if (!sv) return NO;
    BOOL atTop = sv.contentOffset.y <= TPTopOffset(sv) + 1.0;
    if (!atTop && noTop)    { TPDebug(TPL(@"Scroll to top blocked"));    return YES; }
    if (atTop && noRefresh) { TPDebug(TPL(@"Home tab refresh blocked")); return YES; }
    return NO;
}

static id TPSelectedTab(id controller) {
    SEL sel = sel_registerName("selectedTab");
    return [controller respondsToSelector:sel] ? ((id (*)(id, SEL))objc_msgSend)(controller, sel) : nil;
}

static CFAbsoluteTime gTPTabTapAt = 0;

static BOOL TPInTabTapWindow(void) {
    return gTPTabTapAt > 0 && CFAbsoluteTimeGetCurrent() - gTPTabTapAt < 1.0;
}

static BOOL TPShouldBlockFeedScroll(UIScrollView *sv, CGFloat targetY) {
    if (!TPInTabTapWindow() || sv.isTracking) return NO;
    if (targetY >= sv.contentOffset.y - 0.5) return NO;
    if (!TPIsMainFeedScrollView(sv)) return NO;
    BOOL atTop = sv.contentOffset.y <= TPTopOffset(sv) + 1.0;
    if ((!atTop && [TPPrefs boolForKey:TPKeyTabNoScrollTop]) || (atTop && [TPPrefs boolForKey:TPKeyTabNoRefresh])) {
        TPDebug(TPL(atTop ? @"Home tab refresh blocked" : @"Scroll to top blocked"));
        gTPTabTapAt = CFAbsoluteTimeGetCurrent();
        return YES;
    }
    return NO;
}

static BOOL TPShouldBlockTabRefresh(void) {
    if (!TPInTabTapWindow() || ![TPPrefs boolForKey:TPKeyTabNoRefresh]) return NO;
    TPDebug(TPL(@"Home tab refresh blocked"));
    return YES;
}

%group LegacyTabFallback

%hook _TtC11BCNMainFeed25BCNMainFeedViewController
- (void)didRequestedFeedRefresh {
    if (TPShouldBlockTabRefresh()) return;
    %orig;
}
%end

%hook IGRefreshControl
- (void)startLoadingAnimated:(BOOL)animated {
    if (TPShouldBlockTabRefresh()) return;
    %orig;
}
%end

%hook UIScrollView
- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    if (TPInTabTapWindow() && TPShouldBlockFeedScroll((UIScrollView *)self, offset.y)) return;
    %orig;
}
- (void)setContentOffset:(CGPoint)offset {
    if (TPInTabTapWindow() && TPShouldBlockFeedScroll((UIScrollView *)self, offset.y)) return;
    %orig;
}
- (void)setBounds:(CGRect)bounds {
    if (TPInTabTapWindow() && bounds.origin.y != ((UIScrollView *)self).bounds.origin.y
        && TPShouldBlockFeedScroll((UIScrollView *)self, bounds.origin.y)) return;
    %orig;
}
- (void)scrollRectToVisible:(CGRect)rect animated:(BOOL)animated {
    if (TPInTabTapWindow() && TPShouldBlockFeedScroll((UIScrollView *)self, rect.origin.y)) return;
    %orig;
}
%end

%hook UICollectionView
- (void)scrollToItemAtIndexPath:(NSIndexPath *)ip atScrollPosition:(UICollectionViewScrollPosition)pos animated:(BOOL)animated {
    if (TPInTabTapWindow() && ip.section == 0 && ip.item == 0
        && TPShouldBlockFeedScroll((UIScrollView *)self, -CGFLOAT_MAX)) return;
    %orig;
}
%end

%end

static void TPMarkLegacyTabTap(void) {
    if (![TPPrefs boolForKey:TPKeyTabNoScrollTop] && ![TPPrefs boolForKey:TPKeyTabNoRefresh]) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ %init(LegacyTabFallback); });
    gTPTabTapAt = CFAbsoluteTimeGetCurrent();
}

static CFAbsoluteTime gTPSuppressTabSelectUntil = 0;
static BOOL TPTabSelectSuppressed(void) { return CFAbsoluteTimeGetCurrent() < gTPSuppressTabSelectUntil; }

%group HomeFeedControls

%hook _TtC21BCNRootViewController25BCNLegacyTabBarController
- (void)didTapTabBarButton:(id)button       { TPMarkLegacyTabTap(); %orig; }
- (void)didDoubleTapTabBarButton:(id)button { TPMarkLegacyTabTap(); %orig; }
%end

%hook _TtC26BCNLucentTabBarCoordinator26BCNLucentTabBarCoordinator
- (BOOL)tabBarController:(id)controller shouldSelectTab:(id)tab {
    if (TPTabSelectSuppressed()) return NO;
    if (tab && tab == TPSelectedTab(controller) && TPShouldBlockHomeReselect()) return NO;
    return %orig;
}
- (void)tabBarController:(id)controller didSelectTab:(id)tab previousTab:(id)prev {
    if (tab && tab == prev && (TPTabSelectSuppressed() || TPShouldBlockHomeReselect())) return;
    %orig;
}
- (void)handleTabBarDoubleTap:(id)tap {
    if (TPTabSelectSuppressed() || TPShouldBlockHomeReselect()) return;
    %orig;
}
%end

%hook _TtC11BCNMainFeed25BCNMainFeedViewController
- (void)scrollViewDidScroll:(UIScrollView *)sv {
    if ([TPPrefs boolForKey:TPKeyNoPullRefresh] && [sv isKindOfClass:[UIScrollView class]]
        && (sv.isTracking || sv.isDragging || sv.isDecelerating)) {
        CGFloat top = TPTopOffset(sv);
        if (sv.contentOffset.y < top) {
            sv.contentOffset = CGPointMake(sv.contentOffset.x, top);
            TPDebug(TPL(@"Pull to refresh blocked"));
        }
    }
    %orig;
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    gTPMainFeedVC = (UIViewController *)self;
}
%end

%end

// The follow-suggestion sheet is BCNUserRecommendationsViewController, and the "Follow your
// Instagram connections" interstitial is BCNRecommendedAccountsViewController. Only the presented
// (sheet) form is blocked; the same controllers pushed from a profile or settings still open.
static Class gTPUserRecsClass;
static Class gTPRecAccountsClass;
static Class gTPPrefollowClass, gTPPrefollowListClass, gTPFollowListPrefollowClass;

static BOOL TPTreeContainsClass(UIViewController *vc, Class cls, int depth) {
    if (!vc || !cls || depth > 4) return NO;
    if ([vc isKindOfClass:cls]) return YES;
    if ([vc isKindOfClass:[UINavigationController class]])
        for (UIViewController *c in ((UINavigationController *)vc).viewControllers) if (TPTreeContainsClass(c, cls, depth + 1)) return YES;
    for (UIViewController *c in vc.childViewControllers) if (TPTreeContainsClass(c, cls, depth + 1)) return YES;
    return NO;
}

// Dismisses a blocked controller that was presented in a way the present hook did not see.
static void TPDismissIfPresented(UIViewController *me) {
    UIViewController *top = me;
    while (top.parentViewController) top = top.parentViewController;
    if (!top.presentingViewController) return;
    TPDebug(TPL(@"Follow suggestions hidden"));
    dispatch_async(dispatch_get_main_queue(), ^{ [top dismissViewControllerAnimated:NO completion:nil]; });
}

%group HideFollowSuggest

%hook UIViewController
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    if (([TPPrefs boolForKey:TPKeyHideFollowSuggest] && TPTreeContainsClass(vc, gTPUserRecsClass, 0))
        || ([TPPrefs boolForKey:TPKeyHideIGConnections] && (TPTreeContainsClass(vc, gTPRecAccountsClass, 0)
            || TPTreeContainsClass(vc, gTPPrefollowClass, 0) || TPTreeContainsClass(vc, gTPPrefollowListClass, 0)
            || TPTreeContainsClass(vc, gTPFollowListPrefollowClass, 0)))) {
        TPDebug(TPL(@"Follow suggestions hidden"));
        return;
    }
    if ([TPPrefs boolForKey:TPKeyDebugToast] && vc && ![vc isKindOfClass:[UIAlertController class]]) {
        UIViewController *shown = [vc isKindOfClass:[UINavigationController class]] ? ((UINavigationController *)vc).viewControllers.firstObject ?: vc : vc;
        TPDebug([@"present: " stringByAppendingString:NSStringFromClass(shown.class)]);
    }
    %orig;
}
%end

%hook _TtC22BCNUserRecommendations36BCNUserRecommendationsViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if ([TPPrefs boolForKey:TPKeyHideFollowSuggest]) TPDismissIfPresented((UIViewController *)self);
}
%end

%hook _TtC22BCNRecommendedAccounts36BCNRecommendedAccountsViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if ([TPPrefs boolForKey:TPKeyHideIGConnections]) TPDismissIfPresented((UIViewController *)self);
}
%end

// "Follow your Instagram connections" (with "How it works" and a search bar) is presented as
// BCNFollowListPrefollowViewController in Threads 457; the BCNPrefollowing screens are its siblings.
%hook _TtC13BCNFollowList36BCNFollowListPrefollowViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if ([TPPrefs boolForKey:TPKeyHideIGConnections]) TPDismissIfPresented((UIViewController *)self);
}
%end

%hook _TtC15BCNPrefollowing29BCNPrefollowingViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if ([TPPrefs boolForKey:TPKeyHideIGConnections]) TPDismissIfPresented((UIViewController *)self);
}
%end

%hook _TtC15BCNPrefollowing33BCNPrefollowingListViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if ([TPPrefs boolForKey:TPKeyHideIGConnections]) TPDismissIfPresented((UIViewController *)self);
}
%end

%end

// The new tab bar slides away based on the distance accumulated in scrollViewDidScroll: and
// scrollViewDidEndScrolling:. Those calls are withheld from the coordinator. The native iOS 26
// tab bar's minimize behavior is also set to never.
%group PinTabBar

%hook _TtC26BCNLucentTabBarCoordinator26BCNLucentTabBarCoordinator
- (void)scrollViewDidScroll:(id)scroll {
    if ([TPPrefs boolForKey:TPKeyPinTabBar]) return;
    %orig;
}
- (void)scrollViewDidEndScrolling:(id)scrolling {
    if ([TPPrefs boolForKey:TPKeyPinTabBar]) return;
    %orig;
}
%end

%hook _TtC26BCNLucentTabBarCoordinator31BCNLucentNativeTabBarController
- (void)viewIsAppearing:(BOOL)appearing {
    %orig;
    SEL sel = sel_registerName("setTabBarMinimizeBehavior:");
    if ([TPPrefs boolForKey:TPKeyPinTabBar] && [(id)self respondsToSelector:sel])
        ((void (*)(id, SEL, NSInteger))objc_msgSend)((id)self, sel, 1);
}
%end

%end

// Suggestions are IGListKit sections; returning 0 items hides a section without leaving a gap.
// BCNAYMFSectionController ("Suggested for you") is split by its `placement`:
// 0 home feed, 1 activity, 2 search, 3 profile chaining, 4 / 5 communities.
// 0 and 3 follow Suggested Accounts, 2 follows Search Suggestions, the rest are left alone.
// BCNSuggestedUser is only hidden for surface 1 (shown after following someone).
%group HideFeedSuggestions

%hook _TtC26BCNVerticalsSuggestionUnit43BCNVerticalsSuggestionUnitSectionController
- (long long)numberOfItems { return [TPPrefs boolForKey:TPKeyHideFeedSuggest] ? 0 : %orig; }
%end

%hook _TtC11BCNAYMFUnit24BCNAYMFSectionController
- (long long)numberOfItems {
    if ([TPPrefs boolForKey:TPKeyHideFeedSuggest]) {
        uint8_t *placement = TPIvarAddress(self, "placement");
        if (placement && (*placement == 0 || *placement == 3)) return 0;
    }
    if ([TPPrefs boolForKey:TPKeyHideSearchSuggest]) {
        uint8_t *placement = TPIvarAddress(self, "placement");
        if (placement && *placement == 2) return 0;
    }
    return %orig;
}
%end

%hook _TtC28BCNInterestFeedSuggestedUnit45BCNInterestFeedSuggestedUnitSectionController
- (long long)numberOfItems { return [TPPrefs boolForKey:TPKeyHideFeedSuggest] ? 0 : %orig; }
%end

%hook _TtC16BCNSuggestedUser33BCNSuggestedUserSectionController
- (long long)numberOfItems {
    if ([TPPrefs boolForKey:TPKeyHideFeedSuggest]) {
        uint8_t *surface = TPIvarAddress(self, "surface");
        if (surface && *surface == 1) return 0;
    }
    return %orig;
}
%end

%hook _TtC10BCNProfile20BCNProfileHeaderView
- (CGSize)sizeThatFits:(CGSize)fits {
    if ([TPPrefs boolForKey:TPKeyHideFeedSuggest]) {
        uint8_t *show = TPIvarAddress(self, "showProfileChain");
        if (show) *show = 0;
    }
    return %orig;
}
- (void)layoutSubviews {
    if ([TPPrefs boolForKey:TPKeyHideFeedSuggest]) {
        uint8_t *show = TPIvarAddress(self, "showProfileChain");
        if (show) *show = 0;
    }
    %orig;
}
%end

%hook _TtC18BCNProfileChaining22BCNProfileChainingView
- (CGSize)sizeThatFits:(CGSize)fits {
    if ([TPPrefs boolForKey:TPKeyHideFeedSuggest]) return CGSizeMake(fits.width, 0);
    return %orig;
}
- (void)layoutSubviews {
    %orig;
    ((UIView *)self).hidden = [TPPrefs boolForKey:TPKeyHideFeedSuggest];
}
%end

// "Are you interested in this post?" appears as a row under a post and as a batched section.
%hook _TtC29BCNFeedItemSeeMoreSeeLessCell29BCNFeedItemSeeMoreSeeLessCell
- (CGSize)sizeThatFits:(CGSize)fits {
    if ([TPPrefs boolForKey:TPKeyHidePostFeedback]) return CGSizeMake(fits.width, 0);
    return %orig;
}
- (void)layoutSubviews {
    %orig;
    ((UIView *)self).hidden = [TPPrefs boolForKey:TPKeyHidePostFeedback];
}
%end

// Hiding the row's cell still left its height in the feed: the section keeps the row. The post's
// own view model has a flag that leaves the row out altogether; IGListKit reads the model's
// diff identifier before the rows are built, so the flag is set there.
static void TPForceHideSeeMoreSeeLess(id vm) {
    if (![TPPrefs boolForKey:TPKeyHidePostFeedback]) return;
    uint8_t *hide = TPIvarAddress(vm, "shouldForceHideSeeMoreSeeLessUnit");
    if (hide) *hide = 1;
}

%hook _TtC16BCNPostViewModel16BCNPostViewModel
- (id)diffIdentifier {
    TPForceHideSeeMoreSeeLess(self);
    return %orig;
}
- (BOOL)isEqualToDiffableObject:(id)object {
    TPForceHideSeeMoreSeeLess(self);
    TPForceHideSeeMoreSeeLess(object);
    return %orig;
}
%end

%hook _TtC39BCNFeedBatchedSeeMoreSeeLessSessionUnit56BCNFeedBatchedSeeMoreSeeLessSessionUnitSectionController
- (long long)numberOfItems { return [TPPrefs boolForKey:TPKeyHidePostFeedback] ? 0 : %orig; }
%end

%end

// Threads learns about screenshots and screen recordings through IGScreenshotObserver.
%group BlockScreenshotDetection

%hook IGScreenshotObserver
- (void)_onTakenScreenshot {
    if ([TPPrefs boolForKey:TPKeyBlockScreenshotDetect]) { TPDebug(TPL(@"Screenshot detection blocked")); return; }
    %orig;
}
- (void)_screenCaptureStateDidChange:(id)change {
    if ([TPPrefs boolForKey:TPKeyBlockScreenshotDetect]) return;
    %orig;
}
%end

%end

// Block Analytics. Usage events are collected by FBAnalyticsCoreLogger and uploaded by
// IGAnalyticsNetworkConfigurator. New events are dropped at collection, and anything already
// stored is uploaded through Meta's own FBAnalyticsNoOpNetworkConfigurator, which sends nothing.
// Normal API traffic (login, posting, loading the feed) does not use this path.
static int gTPAnalyticsDropped;

static NSMutableDictionary<NSString *, NSNumber *> *gTPAnaCounts;
static NSMutableDictionary<NSString *, NSDictionary *> *gTPAnaLast;
static NSUInteger gTPAnaTotal;
static const NSUInteger kTPAnaRecentMax = 10;

// Analytics Log. Only names are counted for every event; the latest event object of each kind
// is kept and its payload is only read when the log is opened. Nothing is written to disk.
static void TPRecordAnalytics(id event, BOOL blocked) {
    if (!event) return;
    NSString *name = nil;
    @try { if ([event respondsToSelector:@selector(eventName)]) name = [event performSelector:@selector(eventName)]; } @catch (__unused id e) {}
    if (![name isKindOfClass:[NSString class]] || !name.length) name = @"(unnamed)";
    @synchronized ([TPPrefs class]) {
        if (!gTPAnaCounts) { gTPAnaCounts = [NSMutableDictionary new]; gTPAnaLast = [NSMutableDictionary new]; }
        gTPAnaTotal++;
        gTPAnaCounts[name] = @(gTPAnaCounts[name].unsignedIntegerValue + 1);
        if (gTPAnaLast[name] || gTPAnaLast.count < 100)
            gTPAnaLast[name] = @{ @"t": [NSDate date], @"n": name, @"e": event, @"b": @(blocked) };
    }
}

static NSString *TPAnaPayloadString(id event) {
    id payload = nil;
    @try { if ([event respondsToSelector:@selector(eventPayload)]) payload = [event performSelector:@selector(eventPayload)]; } @catch (__unused id e) {}
    if (!payload) return @"{}";
    NSString *s = nil;
    if ([NSJSONSerialization isValidJSONObject:payload]) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingSortedKeys error:nil];
        if (d) s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    }
    if (!s) s = [payload description];
    if (s.length > 600) s = [[s substringToIndex:600] stringByAppendingString:@"…"];
    return s;
}

// Plain-language descriptions, observed from real Threads traffic. Unknown names fall back to a
// word-by-word translation, which is skipped when more than half the words are unknown.
static NSDictionary<NSString *, NSArray<NSString *> *> *TPAnaKnownEvents(void) {
    static NSDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = @{
        @"navigation":                       @[@"切換頁面", @"Page navigation"],
        @"time_spent_bit_array":             @[@"使用時長（逐秒記錄）", @"Time spent (per second)"],
        @"time_spent":                       @[@"使用時長", @"Time spent"],
        @"app_state":                        @[@"App 前景／背景切換", @"App foreground/background"],
        @"perf":                             @[@"效能紀錄（圖片、影片、動態的載入速度與網路狀況）", @"Performance (load times of images, videos, feed, and network)"],
        @"client_event":                     @[@"一般操作紀錄", @"General client event"],
        @"impression":                       @[@"內容出現在畫面上", @"Content shown on screen"],
        @"vpv":                              @[@"內容在畫面上停留的時間", @"How long content stayed on screen"],
        @"video_should_start":               @[@"影片準備播放", @"Video about to play"],
        @"video_started_playing":            @[@"影片開始播放", @"Video started"],
        @"video_paused":                     @[@"影片暫停", @"Video paused"],
        @"video_exited":                     @[@"離開影片", @"Left video"],
        @"video_displayed":                  @[@"影片出現在畫面上", @"Video shown on screen"],
        @"qe_exposure":                      @[@"實驗分組紀錄（你被分到哪個測試版本）", @"Experiment exposure (which test group you're in)"],
        @"ig_qe_exposure":                   @[@"實驗分組紀錄（你被分到哪個測試版本）", @"Experiment exposure (which test group you're in)"],
        @"gk_exposure":                      @[@"功能開關檢查紀錄", @"Feature gate check"],
        @"mobile_network_stats":             @[@"網路連線品質", @"Network quality"],
        @"cold_start":                       @[@"App 冷啟動速度", @"App cold start time"],
        @"warm_start":                       @[@"App 熱啟動速度", @"App warm start time"],
        @"memory_warning":                   @[@"記憶體不足警告", @"Low memory warning"],
        @"push_notification_received":       @[@"收到推播通知", @"Push notification received"],
        @"notification_open":                @[@"點開通知", @"Notification opened"],
        @"search":                           @[@"搜尋", @"Search"],
        @"like":                             @[@"按讚", @"Like"],
        @"unlike":                           @[@"收回讚", @"Unlike"],
        @"follow_button_tapped":             @[@"點了追蹤按鈕", @"Follow button tapped"],
        @"mobile_config_exposure_log":       @[@"伺服器設定值讀取紀錄（記錄 App 套用了哪些遠端設定）", @"Remote config exposure (which server settings the app used)"],
        @"mobile_config_param_access_without_exposure": @[@"伺服器設定值讀取（未分組）", @"Remote config read (no exposure)"],
        @"privacy_flow_trigger_event":       @[@"隱私相關流程觸發紀錄", @"Privacy flow triggered"],
        @"ig_time_spent_action":             @[@"使用時長（依操作記錄）", @"Time spent (by action)"],
        @"ig_time_spent_screen_time":        @[@"使用時長（各畫面停留時間）", @"Time spent (per screen)"],
        @"instagram_ad_delivery":            @[@"廣告投放紀錄", @"Ad delivery"],
        @"enigma_ios_event":                 @[@"廣告成效追蹤", @"Ad performance tracking"],
        @"odin_features":                    @[@"裝置與使用狀態數值（網路、啟動方式等，用於預測與推薦）", @"Device and usage signals (network, launch type, used for prediction)"],
        @"app_installations":                @[@"已安裝的 Meta App（是否裝了 Instagram、Facebook 等）", @"Installed Meta apps (Instagram, Facebook, etc.)"],
        @"badging_event":                    @[@"通知紅點／數字標記", @"Notification badge"],
        @"push_notification_setting":        @[@"推播通知設定狀態", @"Push notification settings"],
        @"instagram_organic_impression":    @[@"一般串文（非廣告）出現在畫面上", @"Regular (non-ad) post shown on screen"],
        @"instagram_organic_vpvd_imp":      @[@"一般串文在畫面上停留的時間", @"How long a regular post stayed on screen"],
        @"threads_media_header_context_impression": @[@"串文上方的話題標籤（例如相關熱門話題）出現在畫面上", @"Topic label above a post (e.g. related trend) shown"],
        @"client_registration_initiated":   @[@"App 向伺服器登記裝置", @"App registering the device with the server"],
        @"fx_upsells_product":              @[@"帳號管理中心的跨 App 推廣（例如連結 Instagram、Facebook）", @"Accounts Center cross-app promotion (e.g. linking Instagram, Facebook)"],
        @"instagram_two_measurement_debugging_signal": @[@"串文曝光追蹤訊號（含追蹤碼與串文編號）", @"Post impression tracking signal (tracking token, post ID)"],
        @"media_playback_compound":         @[@"影片播放過程紀錄（準備、開始、暫停、緩衝等）", @"Video playback log (prepare, start, pause, buffering)"],
        @"media_playback_compound_fast":    @[@"影片播放過程紀錄（即時版）", @"Video playback log (real-time)"],
        @"barcelona_permalink_action":      @[@"串文頁的操作（進入、離開、看到哪裡）", @"Post page actions (enter, exit, how far you read)"],
        @"barcelona_media_viewer_entry":    @[@"進入全螢幕檢視圖片或影片", @"Opened full-screen media viewer"],
        @"barcelona_media_viewer_exit":     @[@"離開全螢幕檢視圖片或影片", @"Closed full-screen media viewer"],
        @"barcelona_post_tap":              @[@"點擊串文", @"Tapped a post"],
        @"client_registration_request_sent": @[@"裝置登記：請求已送出", @"Device registration: request sent"],
        @"client_registration_response_received": @[@"裝置登記：收到回應", @"Device registration: response received"],
        @"client_registration_failure":     @[@"裝置登記失敗", @"Device registration failed"],
        @"client_registration_token_obtained_from_provider": @[@"裝置登記：從系統取得推播權杖", @"Device registration: push token obtained"],
        @"instagram_media_metrics":         @[@"圖片與影片的載入、顯示數據", @"Media load and display metrics"],
        @"instagram_client_delivery_funnel_start": @[@"動態內容載入流程開始（這次送來哪些串文）", @"Feed delivery started (which posts were served)"],
        @"instagram_client_delivery_funnel_end": @[@"動態內容載入流程結束", @"Feed delivery finished"],
        @"bcn_press_location_event":        @[@"點擊位置紀錄（點了畫面哪裡）", @"Tap location (where on screen you tapped)"],
        @"ads_tracking_status":             @[@"廣告追蹤授權狀態（iOS「允許 App 要求追蹤」）", @"Ad tracking permission (iOS App Tracking Transparency)"],
        @"apple_ad_services_token":         @[@"Apple 廣告歸因權杖（是否透過廣告安裝 Threads）", @"Apple ad attribution token (whether you installed via an ad)"],
        @"fx_access_library":               @[@"帳號管理中心存取紀錄", @"Accounts Center access"],
        @"threads_recommended_entity_impression": @[@"推薦內容（例如相關標籤）出現在畫面上", @"Recommended item (e.g. related tags) shown"],
        @"threads_badge_click":             @[@"點擊通知紅點", @"Tapped a notification badge"],
        @"save_sso_nonce_key_chain_success": @[@"登入憑證已存入鑰匙圈", @"Login token saved to Keychain"],
        @"cats_device_identifiers_reliability_ig": @[@"裝置識別碼一致性檢查", @"Device identifier consistency check"],
        @"instagram_device_ids":            @[@"裝置識別碼回報", @"Device identifiers"],
        @"appjobs_ios_job_finished":        @[@"背景工作完成", @"Background job finished"],
        @"screen_time_service_init":        @[@"使用時長統計服務啟動", @"Screen time tracking started"],
        @"device_permissions_external":     @[@"系統權限狀態（相機、相簿、定位等）", @"System permissions (camera, photos, location, etc.)"],
        @"threads_author_badge_impression": @[@"作者旁的標章（例如認證徽章）出現在畫面上", @"Author badge (e.g. verified) shown"],
        @"instagram_organic_carousel_vpvd_imp": @[@"多圖串文在畫面上停留的時間", @"How long a multi-photo post stayed on screen"],
        @"instagram_organic_sub_impression": @[@"多圖串文裡的單張圖片出現在畫面上", @"Single photo in a multi-photo post shown"],
        @"instagram_organic_like":          @[@"按讚（一般串文）", @"Liked a regular post"],
        @"instagram_organic_unlike":        @[@"收回讚（一般串文）", @"Unliked a regular post"],
        @"instagram_organic_brand_profile": @[@"瀏覽品牌或創作者帳號", @"Viewed a brand or creator account"],
        @"ig_profile_action":               @[@"個人檔案頁的操作（進入、追蹤、點擊等）", @"Profile page actions (open, follow, taps)"],
        @"threads_profile_tag_impression":  @[@"個人檔案上的標籤出現在畫面上", @"Profile tag shown"],
        @"threads_profile_tag_unit_impression": @[@"個人檔案的標籤區塊出現在畫面上", @"Profile tag section shown"],
        @"threads_monthly_views_impression": @[@"個人檔案的每月瀏覽次數出現在畫面上", @"Monthly views on a profile shown"],
        @"threads_message_cta_impression":  @[@"「傳送訊息」按鈕出現在畫面上", @"Message button shown"],
        @"threads_spoiler_reveal_tap":      @[@"點開被遮住的防雷內容", @"Revealed spoiler content"],
        @"barcelona_growth_integration_impression": @[@"推廣區塊出現在畫面上（例如邀請好友、跨 App 推廣）", @"Growth promotion shown (e.g. invite friends, cross-app)"],
        @"instagram_session_throughput":    @[@"本次使用期間的資料傳輸量", @"Data transferred this session"],
        @"igfeeditemtracker_igusersession_leak_analysis_event_reported": @[@"記憶體洩漏檢測回報（開發除錯用）", @"Memory leak check (debugging)"],
        @"threads_feed_menu_button_impression": @[@"動態串文的「⋯」選單按鈕出現在畫面上", @"Post \"…\" menu button shown in feed"],
    }; });
    return d;
}

static NSDictionary<NSString *, NSArray<NSString *> *> *TPAnaWords(void) {
    static NSDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = @{
        @"feed": @[@"動態", @"feed"], @"timeline": @[@"動態", @"feed"], @"home": @[@"首頁", @"home"],
        @"item": @[@"項目", @"item"], @"post": @[@"串文", @"post"], @"posts": @[@"串文", @"posts"],
        @"thread": @[@"串文", @"thread"], @"text": @[@"文字", @"text"], @"reply": @[@"回覆", @"reply"],
        @"replies": @[@"回覆", @"replies"], @"comment": @[@"留言", @"comment"], @"repost": @[@"轉發", @"repost"],
        @"quote": @[@"引用", @"quote"], @"profile": @[@"個人檔案", @"profile"], @"user": @[@"使用者", @"user"],
        @"account": @[@"帳號", @"account"], @"search": @[@"搜尋", @"search"], @"activity": @[@"動態通知頁", @"activity"],
        @"notification": @[@"通知", @"notification"], @"notifications": @[@"通知", @"notifications"],
        @"push": @[@"推播", @"push"], @"inbox": @[@"收件匣", @"inbox"], @"direct": @[@"私訊", @"DM"],
        @"dm": @[@"私訊", @"DM"], @"message": @[@"訊息", @"message"], @"messaging": @[@"訊息", @"messaging"],
        @"slide": @[@"私訊", @"DM"], @"media": @[@"媒體", @"media"], @"image": @[@"圖片", @"image"],
        @"photo": @[@"相片", @"photo"], @"video": @[@"影片", @"video"], @"carousel": @[@"多圖", @"carousel"],
        @"link": @[@"連結", @"link"], @"url": @[@"網址", @"URL"], @"tab": @[@"分頁", @"tab"],
        @"composer": @[@"發文畫面", @"composer"], @"compose": @[@"發文", @"compose"], @"camera": @[@"相機", @"camera"],
        @"keyboard": @[@"鍵盤", @"keyboard"], @"sheet": @[@"選單", @"sheet"], @"menu": @[@"選單", @"menu"],
        @"button": @[@"按鈕", @"button"], @"dialog": @[@"對話框", @"dialog"], @"nux": @[@"新手提示", @"onboarding tip"],
        @"suggested": @[@"推薦", @"suggested"], @"recommendation": @[@"推薦", @"recommendation"], @"recs": @[@"推薦", @"recs"],
        @"aymf": @[@"為你推薦", @"suggested for you"], @"community": @[@"社群", @"community"], @"topic": @[@"主題", @"topic"],
        @"tag": @[@"標籤", @"tag"], @"hashtag": @[@"主題標籤", @"hashtag"], @"ad": @[@"廣告", @"ad"], @"ads": @[@"廣告", @"ads"],
        @"sponsored": @[@"贊助內容", @"sponsored"], @"story": @[@"限時動態", @"story"], @"reel": @[@"短片", @"reel"],
        @"session": @[@"使用期間", @"session"], @"app": @[@"App", @"app"], @"page": @[@"頁面", @"page"],
        @"screen": @[@"畫面", @"screen"], @"view": @[@"畫面", @"view"], @"settings": @[@"設定", @"settings"],
        @"impression": @[@"曝光（出現在畫面上）", @"impression"], @"impressions": @[@"曝光", @"impressions"],
        @"vpv": @[@"停留時間", @"view time"], @"viewport": @[@"可見範圍", @"viewport"], @"visible": @[@"可見", @"visible"],
        @"tap": @[@"點擊", @"tap"], @"tapped": @[@"點擊", @"tapped"], @"click": @[@"點擊", @"click"], @"clicked": @[@"點擊", @"clicked"],
        @"press": @[@"按下", @"press"], @"long": @[@"長", @"long"], @"swipe": @[@"滑動", @"swipe"], @"scroll": @[@"捲動", @"scroll"],
        @"open": @[@"開啟", @"open"], @"opened": @[@"開啟", @"opened"], @"close": @[@"關閉", @"close"], @"closed": @[@"關閉", @"closed"],
        @"dismiss": @[@"關閉", @"dismiss"], @"show": @[@"顯示", @"show"], @"shown": @[@"顯示", @"shown"], @"hide": @[@"隱藏", @"hide"],
        @"display": @[@"顯示", @"display"], @"displayed": @[@"顯示", @"displayed"], @"render": @[@"繪製", @"render"],
        @"like": @[@"按讚", @"like"], @"unlike": @[@"收回讚", @"unlike"], @"share": @[@"分享", @"share"], @"copy": @[@"複製", @"copy"],
        @"follow": @[@"追蹤", @"follow"], @"unfollow": @[@"取消追蹤", @"unfollow"], @"mute": @[@"靜音", @"mute"], @"block": @[@"封鎖", @"block"],
        @"save": @[@"儲存", @"save"], @"send": @[@"送出", @"send"], @"sent": @[@"已送出", @"sent"], @"receive": @[@"收到", @"receive"],
        @"received": @[@"收到", @"received"], @"read": @[@"已讀", @"read"], @"seen": @[@"看過", @"seen"], @"typing": @[@"輸入中", @"typing"],
        @"play": @[@"播放", @"play"], @"playing": @[@"播放", @"playing"], @"pause": @[@"暫停", @"pause"], @"paused": @[@"暫停", @"paused"],
        @"start": @[@"開始", @"start"], @"started": @[@"開始", @"started"], @"end": @[@"結束", @"end"], @"ended": @[@"結束", @"ended"],
        @"exit": @[@"離開", @"exit"], @"exited": @[@"離開", @"exited"], @"enter": @[@"進入", @"enter"], @"navigation": @[@"切換頁面", @"navigation"],
        @"load": @[@"載入", @"load"], @"loaded": @[@"載入完成", @"loaded"], @"loading": @[@"載入中", @"loading"], @"fetch": @[@"讀取", @"fetch"],
        @"refresh": @[@"重新整理", @"refresh"], @"prefetch": @[@"預先載入", @"prefetch"], @"download": @[@"下載", @"download"],
        @"upload": @[@"上傳", @"upload"], @"request": @[@"請求", @"request"], @"response": @[@"回應", @"response"],
        @"success": @[@"成功", @"success"], @"succeeded": @[@"成功", @"succeeded"], @"fail": @[@"失敗", @"fail"],
        @"failed": @[@"失敗", @"failed"], @"failure": @[@"失敗", @"failure"], @"error": @[@"錯誤", @"error"], @"cancel": @[@"取消", @"cancel"],
        @"login": @[@"登入", @"login"], @"logout": @[@"登出", @"logout"], @"switch": @[@"切換", @"switch"], @"edit": @[@"編輯", @"edit"],
        @"delete": @[@"刪除", @"delete"], @"report": @[@"檢舉", @"report"], @"translate": @[@"翻譯", @"translate"],
        @"time": @[@"時間", @"time"], @"spent": @[@"花費", @"spent"], @"duration": @[@"時長", @"duration"], @"perf": @[@"效能", @"performance"],
        @"performance": @[@"效能", @"performance"], @"latency": @[@"延遲", @"latency"], @"frame": @[@"畫面格", @"frame"],
        @"frames": @[@"畫面格", @"frames"], @"drop": @[@"掉格", @"drop"], @"dropped": @[@"掉格", @"dropped"], @"memory": @[@"記憶體", @"memory"],
        @"network": @[@"網路", @"network"], @"cache": @[@"快取", @"cache"], @"cold": @[@"冷", @"cold"], @"warm": @[@"熱", @"warm"],
        @"startup": @[@"啟動", @"startup"], @"launch": @[@"啟動", @"launch"], @"foreground": @[@"回到前景", @"foreground"],
        @"background": @[@"進入背景", @"background"], @"state": @[@"狀態", @"state"], @"battery": @[@"電池", @"battery"],
        @"device": @[@"裝置", @"device"], @"bandwidth": @[@"頻寬", @"bandwidth"], @"connection": @[@"連線", @"connection"],
        @"qe": @[@"實驗", @"experiment"], @"exposure": @[@"分組紀錄", @"exposure"], @"experiment": @[@"實驗", @"experiment"],
        @"gk": @[@"功能開關", @"feature gate"], @"config": @[@"設定值", @"config"], @"sync": @[@"同步", @"sync"],
        @"count": @[@"次數", @"count"], @"stats": @[@"統計", @"stats"], @"event": @[@"事件", @"event"], @"events": @[@"事件", @"events"],
        @"bit": @[@"逐秒", @"bit"], @"array": @[@"記錄", @"array"], @"client": @[@"用戶端", @"client"], @"server": @[@"伺服器", @"server"],
        @"bloks": @[@"介面元件", @"UI component"], @"mobile": @[@"行動裝置", @"mobile"], @"log": @[@"紀錄", @"log"],
        @"param": @[@"參數", @"parameter"], @"access": @[@"讀取", @"access"], @"without": @[@"未", @"without"],
        @"trigger": @[@"觸發", @"trigger"], @"flow": @[@"流程", @"flow"], @"privacy": @[@"隱私", @"privacy"],
        @"installations": @[@"安裝", @"installations"], @"install": @[@"安裝", @"install"], @"badging": @[@"紅點標記", @"badge"],
        @"badge": @[@"紅點標記", @"badge"], @"setting": @[@"設定", @"setting"], @"delivery": @[@"投放", @"delivery"],
        @"action": @[@"操作", @"action"],
        @"organic": @[@"一般內容", @"organic"], @"vpvd": @[@"停留時間", @"view time"], @"imp": @[@"曝光", @"impression"],
        @"registration": @[@"登記", @"registration"], @"initiated": @[@"開始", @"initiated"], @"upsells": @[@"推廣", @"promotion"],
        @"upsell": @[@"推廣", @"promotion"], @"product": @[@"產品", @"product"], @"header": @[@"上方標籤", @"header"],
        @"context": @[@"情境", @"context"], @"trend": @[@"熱門話題", @"trend"], @"trends": @[@"熱門話題", @"trends"], @"component": @[@"元件", @"component"], @"graphql": @[@"資料請求", @"data request"],
    }; });
    return d;
}

static NSString *TPAnaDescribe(NSString *name, BOOL zh) {
    NSUInteger li = zh ? 0 : 1;
    NSString *low = name.lowercaseString;
    NSArray *known = TPAnaKnownEvents()[low];
    if (known) return known[li];
    NSArray *parts = [low componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"_:.-/ "]];
    NSMutableArray *out = [NSMutableArray new];
    NSUInteger hit = 0, total = 0;
    for (NSString *w in parts) {
        if (!w.length) continue;
        if ([@[@"ig", @"instagram", @"barcelona", @"bcn", @"xth", @"fb", @"meta", @"textapp", @"ios", @"threads"] containsObject:w]) continue;
        total++;
        NSArray *t = TPAnaWords()[w];
        if (t) { hit++; if (![out.lastObject isEqualToString:t[li]]) [out addObject:t[li]]; }
    }
    if (!hit || hit * 2 < total) return nil;
    return [out componentsJoinedByString:zh ? @"・" : @" · "];
}

NSString *TPAnalyticsLogReport(void) {
    NSDictionary *counts; NSArray *recent; NSUInteger total;
    @synchronized ([TPPrefs class]) { counts = [gTPAnaCounts copy]; recent = [gTPAnaLast.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"t"] compare:a[@"t"]]; }]; total = gTPAnaTotal; }
    if (!total) return nil;
    // Event descriptions exist in Traditional Chinese and English. Traditional Chinese is used for
    // zh-Hant, converted for zh-Hans; Japanese, Korean and the rest get English.
    NSString *te = TPL(@"Top Events");
    BOOL zh = [te isEqualToString:@"事件排行"];
    BOOL hans = zh && [TPL(@"Unknown") isEqualToString:@"无法识别"];
    BOOL blocking = [TPPrefs boolForKey:TPKeyBlockAnalytics];
    NSMutableString *r = [NSMutableString stringWithFormat:@"ThreadsPulse %@\n\n", TP_VERSION];
    [r appendFormat:@"%@\n", blocking ? TPL(@"Block Analytics: On") : TPL(@"Block Analytics: Off")];
    [r appendFormat:@"%@\n", blocking ? TPL(@"Nothing below was sent") : TPL(@"Everything below was sent")];
    [r appendFormat:TPL(@"%lu events while using the app (%lu types)"), (unsigned long)total, (unsigned long)counts.count];
    [r appendFormat:@"\n\n【%@】\n", TPL(@"Top Events")];
    NSArray *names = [counts keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
    NSUInteger i = 0;
    for (NSString *n in names) {
        if (i++ >= 60) { [r appendFormat:TPL(@"…and %lu more types"), (unsigned long)(names.count - 60)]; [r appendString:@"\n"]; break; }
        NSString *desc = TPAnaDescribe(n, zh);
        if (desc && hans) desc = [desc stringByApplyingTransform:@"Hant-Hans" reverse:NO] ?: desc;
        if (!desc) desc = TPL(@"Unknown");
        [r appendFormat:@"\n%@\n%@ · %@\n", desc, [NSString stringWithFormat:TPL(@"%@ times"), counts[n]], n];
    }
    [r appendFormat:@"\n【%@】\n%@\n", TPL(@"Recent Events"), TPL(@"Latest one of each type")];
    NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss";
    for (NSDictionary *it in [recent subarrayWithRange:NSMakeRange(0, MIN(recent.count, kTPAnaRecentMax))]) {
        NSString *desc = TPAnaDescribe(it[@"n"], zh);
        if (desc && hans) desc = [desc stringByApplyingTransform:@"Hant-Hans" reverse:NO] ?: desc;
        [r appendFormat:@"\n%@ %@\n%@%@\n", [f stringFromDate:it[@"t"]], desc ?: it[@"n"],
                        desc ? [it[@"n"] stringByAppendingString:@"\n"] : @"", TPAnaPayloadString(it[@"e"])];
    }
    [r appendFormat:@"\n%@", TPL(@"Contains your user ID and post IDs. Check before sharing.")];
    return r;
}

%group BlockAnalytics

%hook FBAnalyticsCoreLogger
- (void)_captureAnalyticsEvent:(id)event {
    BOOL block = [TPPrefs boolForKey:TPKeyBlockAnalytics];
    TPRecordAnalytics(event, block);
    if (block) { __sync_fetch_and_add(&gTPAnalyticsDropped, 1); return; }
    %orig;
}
- (BOOL)_captureAnalyticsEventForBatchUpload:(id)event {
    if ([TPPrefs boolForKey:TPKeyBlockAnalytics]) return YES;
    return %orig;
}
- (BOOL)_shouldStreamEvent:(id)event {
    if ([TPPrefs boolForKey:TPKeyBlockAnalytics]) return NO;
    return %orig;
}
%end

%end

typedef BOOL (*TPPerformIMP)(id, SEL, id, void *);
static TPPerformIMP orig_TPAnalyticsPerform, noop_TPAnalyticsPerform;
static BOOL tp_AnalyticsPerform(id self, SEL _cmd, id context, void *requestContext) {
    if (noop_TPAnalyticsPerform && [TPPrefs boolForKey:TPKeyBlockAnalytics])
        return noop_TPAnalyticsPerform(self, _cmd, context, requestContext);
    return orig_TPAnalyticsPerform(self, _cmd, context, requestContext);
}

// The upload method takes a large struct, passed by pointer on arm64, so the replacement is
// only installed when both implementations have identical type encodings.
static void TPInstallAnalyticsUploadBlock(void) {
    SEL sel = NSSelectorFromString(@"performRequestWithContext:requestContext:");
    Class noop = objc_getClass("FBAnalyticsNoOpNetworkConfigurator");
    Class real = objc_getClass("IGAnalyticsNetworkConfigurator");
    Method nm = noop ? class_getInstanceMethod(noop, sel) : NULL;
    Method rm = real ? class_getInstanceMethod(real, sel) : NULL;
    if (!nm || !rm || method_getImplementation(nm) == method_getImplementation(rm)) return;
    if (strcmp(method_getTypeEncoding(nm), method_getTypeEncoding(rm)) != 0) return;
    noop_TPAnalyticsPerform = (TPPerformIMP)method_getImplementation(nm);
    orig_TPAnalyticsPerform = (TPPerformIMP)method_setImplementation(rm, (IMP)tp_AnalyticsPerform);
}

// Links in posts and bios go through BCNLinkHandlerImpl (an ObjC protocol, so calls use ObjC
// dispatch). threads.com / threads.net and non-web links keep the default behavior.
static NSURL *TPExternalBrowserURL(id url) {
    if (![TPPrefs boolForKey:TPKeyExternalBrowser] || ![url isKindOfClass:[NSURL class]]) return nil;
    NSURL *target = url;
    NSURLComponents *c = [NSURLComponents componentsWithURL:target resolvingAgainstBaseURL:NO];
    if (c && [TPURLCleaner isRedirectHost:c.host]) {
        for (NSURLQueryItem *q in c.queryItems)
            if ([q.name isEqualToString:@"u"] && q.value.length) { NSURL *inner = [NSURL URLWithString:q.value]; if (inner) target = inner; break; }
    }
    NSString *scheme = target.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
    NSString *host = target.host.lowercaseString ?: @"";
    for (NSString *own in @[@"threads.net", @"threads.com"])
        if ([host isEqualToString:own] || [host hasSuffix:[@"." stringByAppendingString:own]]) return nil;
    return [TPURLCleaner cleanURL:target];
}

static BOOL TPOpenExternally(id url) {
    NSURL *target = TPExternalBrowserURL(url);
    if (!target) return NO;
    [[UIApplication sharedApplication] openURL:target options:@{} completionHandler:nil];
    return YES;
}

%group ExternalBrowser

%hook _TtC20BCNLinkHandlerPlugin18BCNLinkHandlerImpl
- (void)handleLinkWithURL:(id)url containerModule:(id)module presenter:(id)presenter {
    if (TPOpenExternally(url)) return;
    %orig;
}
- (void)handleLinkWithURL:(id)url rawURL:(id)rawURL linkProtectionMetadata:(id)metadata mediaPk:(id)pk mediaAuthorPk:(id)authorPk linkTapLocation:(long long)location containerModule:(id)module sponsoredPostInfo:(id)info rankingInfoToken:(id)token presenter:(id)presenter contextualLoggingParameters:(id)parameters clickSource:(unsigned long long)source animationViewProvider:(id)provider {
    if (TPOpenExternally(url)) return;
    %orig;
}
%end

%end

// Profile header buttons are lazy properties of BCNProfileViewController:
// $__lazy_storage_$_searchButton and $__lazy_storage_$_appSwitcherButton (Instagram).
// Outside a stack view the remaining buttons are shifted with a transform. When both are
// hidden, a button that would be shifted twice takes the larger shift, not the sum.
static const void *kTPHiddenProfileViewsKey = &kTPHiddenProfileViewsKey;

static UIView *TPIGButtonSlot(UIView *button) {
    UIView *v = button;
    while (v.superview && ![v.superview isKindOfClass:[UIStackView class]] && v.superview.subviews.count == 1) v = v.superview;
    return v;
}

static const void *kTPShiftedViewsKey = &kTPShiftedViewsKey;

static void TPResetShifted(UIViewController *vc) {
    for (TPWeakBox *box in (NSArray *)objc_getAssociatedObject(vc, kTPShiftedViewsKey)) {
        UIView *v = box.object;
        if (v) v.transform = CGAffineTransformIdentity;
    }
    objc_setAssociatedObject(vc, kTPShiftedViewsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *TPProfileButton(UIViewController *vc, const char *ivar) {
    Ivar iv = class_getInstanceVariable(object_getClass(vc), ivar);
    UIView *b = iv ? object_getIvar(vc, iv) : nil;
    return [b isKindOfClass:[UIView class]] && b.superview ? b : nil;
}

static void TPApplyHideIGButton(UIViewController *vc) {
    for (TPWeakBox *box in (NSArray *)objc_getAssociatedObject(vc, kTPHiddenProfileViewsKey)) ((UIView *)box.object).hidden = NO;
    objc_setAssociatedObject(vc, kTPHiddenProfileViewsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TPResetShifted(vc);

    NSMutableArray<UIView *> *slots = [NSMutableArray array];
    if ([TPPrefs boolForKey:TPKeyHideIGButton]) { UIView *b = TPProfileButton(vc, "$__lazy_storage_$_appSwitcherButton"); if (b) [slots addObject:TPIGButtonSlot(b)]; }
    if ([TPPrefs boolForKey:TPKeyHideProfileSearch]) { UIView *b = TPProfileButton(vc, "$__lazy_storage_$_searchButton"); if (b) [slots addObject:TPIGButtonSlot(b)]; }
    if (!slots.count) return;

    NSMutableArray *hiddenBoxes = [NSMutableArray array];
    for (UIView *slot in slots) {
        slot.hidden = YES;
        TPWeakBox *box = [TPWeakBox new]; box.object = slot; [hiddenBoxes addObject:box];
    }
    objc_setAssociatedObject(vc, kTPHiddenProfileViewsKey, hiddenBoxes, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSMapTable<UIView *, NSNumber *> *shift = [NSMapTable weakToStrongObjectsMapTable];
    for (UIView *slot in slots) {
        if (!slot.superview || [slot.superview isKindOfClass:[UIStackView class]]) continue;
        CGRect f = slot.frame;
        NSMutableArray<UIView *> *left = [NSMutableArray array], *right = [NSMutableArray array];
        CGFloat leftEdge = -CGFLOAT_MAX, rightEdge = CGFLOAT_MAX;
        for (UIView *v in slot.superview.subviews) {
            if ([slots containsObject:v] || v.hidden || v.alpha < 0.01) continue;
            CGRect g = v.frame;
            if (g.size.width > 100 || g.size.height > 100) continue;
            if (CGRectGetMaxY(g) <= CGRectGetMinY(f) || CGRectGetMinY(g) >= CGRectGetMaxY(f)) continue;
            if (CGRectGetMaxX(g) <= CGRectGetMinX(f) + 1) { [left addObject:v]; leftEdge = MAX(leftEdge, CGRectGetMaxX(g)); }
            else if (CGRectGetMinX(g) >= CGRectGetMaxX(f) - 1) { [right addObject:v]; rightEdge = MIN(rightEdge, CGRectGetMinX(g)); }
        }
        NSArray *movers; CGFloat dx;
        if (left.count) { movers = left; dx = CGRectGetMaxX(f) - leftEdge; }
        else if (right.count) { movers = right; dx = CGRectGetMinX(f) - rightEdge; }
        else continue;
        for (UIView *v in movers) {
            double prev = [[shift objectForKey:v] doubleValue];
            if (fabs(dx) > fabs(prev)) [shift setObject:@(dx) forKey:v];
        }
    }
    NSMutableArray *boxes = [NSMutableArray array];
    for (UIView *v in shift) {
        v.transform = CGAffineTransformMakeTranslation([[shift objectForKey:v] doubleValue], 0);
        TPWeakBox *b = [TPWeakBox new]; b.object = v; [boxes addObject:b];
    }
    objc_setAssociatedObject(vc, kTPShiftedViewsKey, boxes, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%group HideIGButton

%hook _TtC10BCNProfile24BCNProfileViewController
- (void)viewDidLayoutSubviews {
    %orig;
    TPApplyHideIGButton((UIViewController *)self);
}
%end

%end

// Long-press on the Home tab. Every tab long-press (e.g. switching accounts on the profile tab)
// goes through handleTabBarLongPress:; only presses that begin on the first tab are taken.
static void TPCollectTabButtons(UIView *v, NSMutableArray<UIView *> *out, int depth) {
    if (depth > 8) return;
    for (UIView *s in v.subviews) {
        NSString *cls = NSStringFromClass([s class]);
        if (!s.hidden && s.alpha > 0.01 && ([cls containsString:@"TabButton"] || [cls containsString:@"TabBarButton"])) [out addObject:s];
        else TPCollectTabButtons(s, out, depth + 1);
    }
}

static BOOL TPIsHomeTabPress(UIGestureRecognizer *g) {
    UIView *bar = g.view;
    if (!bar) return NO;
    CGPoint p = [g locationInView:bar];
    BOOL rtl = bar.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    TPCollectTabButtons(bar, buttons, 0);
    if (buttons.count >= 2) {
        [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            CGFloat ax = [a convertPoint:CGPointZero toView:bar].x, bx = [b convertPoint:CGPointZero toView:bar].x;
            return ax < bx ? NSOrderedAscending : ax > bx ? NSOrderedDescending : NSOrderedSame;
        }];
        UIView *home = rtl ? buttons.lastObject : buttons.firstObject;
        CGRect f = [home convertRect:home.bounds toView:bar];
        return p.x >= CGRectGetMinX(f) && p.x <= CGRectGetMaxX(f);
    }
    NSUInteger n = [bar isKindOfClass:[UITabBar class]] && ((UITabBar *)bar).items.count ? ((UITabBar *)bar).items.count : 5;
    CGFloat cell = bar.bounds.size.width / n;
    return rtl ? p.x >= bar.bounds.size.width - cell : p.x <= cell;
}

static const void *kTPHomePressKey = &kTPHomePressKey;

%group HomeLongPress

%hook _TtC26BCNLucentTabBarCoordinator26BCNLucentTabBarCoordinator
- (void)handleTabBarLongPress:(UIGestureRecognizer *)press {
    BOOL began = [press isKindOfClass:[UIGestureRecognizer class]] && press.state == UIGestureRecognizerStateBegan;
    if (![TPPrefs boolForKey:TPKeyHomeLongPress] || ![press isKindOfClass:[UIGestureRecognizer class]]) {
        if (began) TPDebug([NSString stringWithFormat:@"%@: %@", TPL(@"Long-press tab"), TPL(@"feature is off")]);
        %orig; return;
    }
    if (began) {
        NSMutableArray<UIView *> *buttons = [NSMutableArray array];
        TPCollectTabButtons(press.view, buttons, 0);
        BOOL home = TPIsHomeTabPress(press);
        TPDebug([NSString stringWithFormat:@"%@: %@ (%@ %lu · x %.0f / %.0f)", TPL(@"Long-press tab"),
                 TPL(home ? @"Home tab" : @"not the Home tab"), NSStringFromClass([press.view class]),
                 (unsigned long)buttons.count, [press locationInView:press.view].x, press.view.bounds.size.width]);
        objc_setAssociatedObject(press, kTPHomePressKey, home ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!home) { %orig; return; }
        gTPSuppressTabSelectUntil = CFAbsoluteTimeGetCurrent() + 10;
        [TPUI hapticLight];
        [TPSettingsViewController present];
        return;
    }
    BOOL mine = objc_getAssociatedObject(press, kTPHomePressKey) != nil;
    if (press.state == UIGestureRecognizerStateEnded || press.state == UIGestureRecognizerStateCancelled
        || press.state == UIGestureRecognizerStateFailed) {
        objc_setAssociatedObject(press, kTPHomePressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (mine) gTPSuppressTabSelectUntil = CFAbsoluteTimeGetCurrent() + 0.6;
    }
    if (!mine) %orig;
}
%end

// The older tab bar, which Threads can still use (e.g. on the first launch after installing).
// Its long-press arrives per button, as the button or its gesture recognizer.
%hook _TtC21BCNRootViewController25BCNLegacyTabBarController
- (void)didLongPressTabBarButton:(id)sender {
    UIGestureRecognizer *g = [sender isKindOfClass:[UIGestureRecognizer class]] ? sender : nil;
    UIView *btn = g ? g.view : ([sender isKindOfClass:[UIView class]] ? sender : nil);
    if (![TPPrefs boolForKey:TPKeyHomeLongPress] || !btn || (g && g.state != UIGestureRecognizerStateBegan)) {
        if (g && g.state != UIGestureRecognizerStateBegan && objc_getAssociatedObject(g, kTPHomePressKey)) {
            if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
                objc_setAssociatedObject(g, kTPHomePressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                gTPSuppressTabSelectUntil = CFAbsoluteTimeGetCurrent() + 0.6;
            }
            return;
        }
        %orig; return;
    }
    // The bar: the nearest ancestor holding several tab buttons.
    UIView *bar = btn.superview;
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (int i = 0; bar && i < 6; bar = bar.superview, i++) {
        [buttons removeAllObjects];
        TPCollectTabButtons(bar, buttons, 0);
        if (buttons.count >= 3) break;
    }
    BOOL home = NO;
    if (bar && buttons.count >= 3) {
        BOOL rtl = bar.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
        UIView *first = nil; CGFloat best = rtl ? -CGFLOAT_MAX : CGFLOAT_MAX;
        for (UIView *b in buttons) {
            CGFloat x = CGRectGetMidX([b convertRect:b.bounds toView:bar]);
            if (rtl ? x > best : x < best) { best = x; first = b; }
        }
        home = first && (first == btn || [btn isDescendantOfView:first] || [first isDescendantOfView:btn]);
    }
    TPDebug([NSString stringWithFormat:@"%@: %@ (legacy %lu)", TPL(@"Long-press tab"), TPL(home ? @"Home tab" : @"not the Home tab"), (unsigned long)buttons.count]);
    if (!home) { %orig; return; }
    if (g) objc_setAssociatedObject(g, kTPHomePressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gTPSuppressTabSelectUntil = CFAbsoluteTimeGetCurrent() + (g ? 10 : 0.6);
    [TPUI hapticLight];
    [TPSettingsViewController present];
}
%end

%end

// Hide Seen Status.
// Threads marks a chat as read with BCNSlideMDCoreMarkThreadReadMutationBuilder, carrying the
// timestamp read up to. When blocked, that timestamp is replaced with the position this chat
// has already shown to the other person (the watermark), or 0. Sending 0 after a Seen was
// shown would move the server's read position backwards and make that Seen disappear.
// Chat ids arrive as NSString, NSNumber or wrapped values, so they are normalized here.
static NSString *TPThreadKey(id fbid) {
    if (!fbid) return nil;
    if ([fbid isKindOfClass:[NSString class]]) return fbid;
    if ([fbid isKindOfClass:[NSNumber class]]) return [fbid stringValue];
    id raw = [TPDownloader safeValue:fbid key:@"rawValue"];
    if ([raw isKindOfClass:[NSString class]]) return raw;
    if ([raw isKindOfClass:[NSNumber class]]) return [raw stringValue];
    NSString *best = nil;
    for (NSString *part in [[fbid description] componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]])
        if (part.length > best.length) best = part;
    return best.length >= 6 ? best : [fbid description];
}

static NSString *gTPOpenChatKey;
static BOOL gTPOpenChatShowsSeen;

static void TPSendSeenNow(NSString *k);
static BOOL TPChatShowsSeen(NSString *key);

static void TPAllowSeenAfterReply(id fbid) {
    NSString *k = TPThreadKey(fbid);
    if (!k.length) return;
    if (TPChatShowsSeen(k)) return;
    if (![TPPrefs boolForKey:TPKeySeenOnReply]) return;
    static NSMutableDictionary<NSString *, NSNumber *> *lastReply;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    @synchronized ([TPPrefs class]) {
        if (!lastReply) lastReply = [NSMutableDictionary dictionary];
        if (now - [lastReply[k] doubleValue] < 1.5) return;
        lastReply[k] = @(now);
    }
    if ([NSThread isMainThread]) TPSendSeenNow(k);
    else dispatch_async(dispatch_get_main_queue(), ^{ TPSendSeenNow(k); });
}

static NSString *const kTPSeenChatsKey = @"tp_seen_allowed_chats";

static BOOL TPChatShowsSeen(NSString *key) {
    if (!key.length) return NO;
    NSArray *list = [[NSUserDefaults standardUserDefaults] arrayForKey:kTPSeenChatsKey];
    return [list containsObject:key];
}

static void TPSetChatShowsSeen(NSString *key, BOOL show) {
    if (!key.length) return;
    NSMutableArray *list = [[[NSUserDefaults standardUserDefaults] arrayForKey:kTPSeenChatsKey] mutableCopy] ?: [NSMutableArray array];
    [list removeObject:key];
    if (show) [list addObject:key];
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:kTPSeenChatsKey];
}

// Sending Seen on reply (or when the eye is turned on) rebuilds the read request from the last
// blocked arguments and sends it through the same GraphQL service and method Threads used,
// which are recorded from Threads' own read requests below.
static const void *kTPMarkReadTag = &kTPMarkReadTag;
static NSMutableDictionary<NSString *, NSDictionary *> *gTPLastReadArgs;
static __weak id gTPGQLService;
static int gTPMarkReadVia;
static BOOL gTPForceSeen;

static id TPTagMarkRead(id b) {
    if (b) objc_setAssociatedObject(b, kTPMarkReadTag, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return b;
}

static NSMutableDictionary<NSString *, NSNumber *> *gTPSeenSentAt;
static NSMutableDictionary<NSString *, NSNumber *> *gTPSeenWatermark;

// Messages held until the server accepts the Seen (released on response, at most 0.8 s).
static NSMutableDictionary<NSString *, NSMutableArray *> *gTPHeldMessages;

static void TPReleaseHeldMessages(NSString *k) {
    NSArray *blocks;
    @synchronized ([TPPrefs class]) { blocks = gTPHeldMessages[k]; [gTPHeldMessages removeObjectForKey:k]; }
    for (dispatch_block_t b in blocks) b();
}

static void TPRecordWatermark(NSString *k, id ms) {
    long long v = [ms respondsToSelector:@selector(longLongValue)] ? [ms longLongValue] : 0;
    if (!k.length || v <= 0) return;
    @synchronized ([TPPrefs class]) {
        if (!gTPSeenWatermark) gTPSeenWatermark = [NSMutableDictionary dictionary];
        if (v > [gTPSeenWatermark[k] longLongValue]) gTPSeenWatermark[k] = @(v);
    }
}

static void TPSendSeenNow(NSString *k) {
    NSDictionary *args;
    @synchronized ([TPPrefs class]) { args = gTPLastReadArgs[k]; }
    id service = gTPGQLService;
    if (!args) { TPDebugNow(@"Seen: no read to resend for this chat yet"); return; }
    if (!service || !gTPMarkReadVia) { TPDebugNow(@"Seen: GraphQL service not found"); return; }
    long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
    long long otidVal = (nowMs << 22) | arc4random_uniform(1 << 22);
    BOOL otidStr = [args[@"otidStr"] boolValue], msStr = [args[@"msStr"] boolValue];
    id otid = otidStr ? [NSString stringWithFormat:@"%lld", otidVal] : @(otidVal);
    id ms = args[@"ms"] ?: (msStr ? [NSString stringWithFormat:@"%lld", nowMs] : @(nowMs));
    Class cls = objc_getClass("BCNSlideMDCoreMarkThreadReadMutationBuilder");
    gTPForceSeen = YES;
    id b = ((id (*)(id, SEL, id, id, id))objc_msgSend)(cls, @selector(builderWithOfflineThreadingId:threadFbid:timestampMs:), otid, args[@"fbid"], ms);
    gTPForceSeen = NO;
    if (!b) { TPDebugNow(@"Seen: builder failed"); return; }
    TPRecordWatermark(k, ms);
    @synchronized ([TPPrefs class]) {
        if (!gTPSeenSentAt) gTPSeenSentAt = [NSMutableDictionary dictionary];
        gTPSeenSentAt[k] = @(CFAbsoluteTimeGetCurrent());
    }
    void (^update)(id) = ^(id x) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TPReleaseHeldMessages(k); });
    };
    void (^failure)(id) = ^(id e) {
        TPDebugNow([NSString stringWithFormat:@"Seen: send failed %@", e]);
        TPReleaseHeldMessages(k);
    };
    dispatch_queue_t q = dispatch_get_main_queue();
    @try {
        switch (gTPMarkReadVia) {
            case 1: ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(b, @selector(handleWithService:updateCallback:failureCallback:callbackQueue:), service, update, failure, q); break;
            case 2: ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(b, @selector(handleFiniteWithService:updateCallback:failureCallback:callbackQueue:), service, update, failure, q); break;
            case 3: ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(service, @selector(initiateRequest:initialData:updateCallback:failureCallback:callbackQueue:), [b request], nil, update, failure, q); break;
            case 4: ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(service, @selector(initiateFiniteRequest:initialData:updateCallback:failureCallback:callbackQueue:), [b request], nil, update, failure, q); break;
        }
        TPDebugNow(TPL(@"Seen sent"));
    } @catch (NSException *e) {
        TPDebugNow([NSString stringWithFormat:@"Seen: %@", e.reason]);
        TPReleaseHeldMessages(k);
    }
}

%group NoSeen
%hook BCNSlideMDCoreMarkThreadReadMutationBuilder
+ (id)builderWithOfflineThreadingId:(id)otid threadFbid:(id)fbid timestampMs:(id)ms {
    if (gTPForceSeen) return TPTagMarkRead(%orig);
    if (![TPPrefs boolForKey:TPKeyNoSeen]) return TPTagMarkRead(%orig);
    NSString *argKey = TPThreadKey(fbid);
    if (argKey.length && fbid) @synchronized ([TPPrefs class]) {
        if (!gTPLastReadArgs) gTPLastReadArgs = [NSMutableDictionary dictionary];
        NSMutableDictionary *d = [@{ @"fbid": fbid, @"otidStr": @([otid isKindOfClass:[NSString class]]),
                                     @"msStr": @([ms isKindOfClass:[NSString class]]) } mutableCopy];
        if (ms && [ms longLongValue] > 0) d[@"ms"] = ms;
        gTPLastReadArgs[argKey] = d;
    }
    if (TPChatShowsSeen(TPThreadKey(fbid))) { TPRecordWatermark(argKey, ms); return TPTagMarkRead(%orig); }
    if (gTPOpenChatShowsSeen && gTPOpenChatKey.length) {
        NSString *k = TPThreadKey(fbid), *otidKey = TPThreadKey(otid);
        if (!k.length || [k isEqualToString:gTPOpenChatKey] || [gTPOpenChatKey containsString:k] || [k containsString:gTPOpenChatKey]
            || [otidKey isEqualToString:gTPOpenChatKey]) { TPRecordWatermark(argKey, ms); return TPTagMarkRead(%orig); }
        TPDebug([NSString stringWithFormat:@"Seen: %@ ≠ %@", k, gTPOpenChatKey]);
    }
    long long wm;
    @synchronized ([TPPrefs class]) { wm = [gTPSeenWatermark[argKey] longLongValue]; }
    id zero = [ms isKindOfClass:[NSString class]] ? [NSString stringWithFormat:@"%lld", wm] : @(wm);
    static NSMutableDictionary<NSString *, NSNumber *> *lastToast;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lastToast = [NSMutableDictionary dictionary]; });
    NSString *k = TPThreadKey(fbid) ?: @"";
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    @synchronized ([TPPrefs class]) {
        if (now - [lastToast[k] doubleValue] > 60) { lastToast[k] = @(now); TPDebug(TPL(@"Seen status blocked")); }
    }
    return TPTagMarkRead(%orig(otid, fbid, zero));
}
%end

%hook PNGraphQLQueryBuilder
- (id)handleWithService:(id)service updateCallback:(id)u failureCallback:(id)f callbackQueue:(id)q {
    if (objc_getAssociatedObject(self, kTPMarkReadTag)) { gTPGQLService = service; gTPMarkReadVia = 1; }
    return %orig;
}
- (id)handleFiniteWithService:(id)service updateCallback:(id)u failureCallback:(id)f callbackQueue:(id)q {
    if (objc_getAssociatedObject(self, kTPMarkReadTag)) { gTPGQLService = service; gTPMarkReadVia = 2; }
    return %orig;
}
- (id)request {
    id r = %orig;
    if (r && objc_getAssociatedObject(self, kTPMarkReadTag)) objc_setAssociatedObject(r, kTPMarkReadTag, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return r;
}
%end

%hook PNPandoGraphQLService
- (id)initiateRequest:(id)req initialData:(id)d updateCallback:(id)u failureCallback:(id)f callbackQueue:(id)q {
    if (req && objc_getAssociatedObject(req, kTPMarkReadTag) && gTPMarkReadVia < 1) { gTPGQLService = self; gTPMarkReadVia = 3; }
    return %orig;
}
- (id)initiateFiniteRequest:(id)req initialData:(id)d updateCallback:(id)u failureCallback:(id)f callbackQueue:(id)q {
    if (req && objc_getAssociatedObject(req, kTPMarkReadTag) && gTPMarkReadVia < 1) { gTPGQLService = self; gTPMarkReadVia = 4; }
    return %orig;
}
%end

// If Seen arrives together with the reply, the reply becomes the last message on the other
// person's screen and Seen has nowhere to show. A message sent right after a Seen is held
// until the server accepts the Seen.
%hook MDCoreSendService
- (void)sendMutationWithAppDataModel:(id)model offlineThreadingId:(id)otid optimisticImages:(id)images syncGroupId:(int)group {
    Ivar iv = model && [TPPrefs boolForKey:TPKeyNoSeen] ? class_getInstanceVariable(object_getClass(model), "_outgoingMessagePayload") : NULL;
    id payload = iv ? object_getIvar(model, iv) : nil;
    NSString *k = payload ? TPThreadKey([TPDownloader safeValue:payload key:@"threadFbid"]) : nil;
    BOOL hold = NO;
    if (k.length) @synchronized ([TPPrefs class]) { hold = CFAbsoluteTimeGetCurrent() - [gTPSeenSentAt[k] doubleValue] < 2; }
    if (!hold) { %orig; return; }
    TPDebug(TPL(@"Seen sent first, message follows"));
    dispatch_block_t send = ^{ %orig(model, otid, images, group); };
    __block BOOL done = NO;
    dispatch_block_t once = ^{ if (done) return; done = YES; send(); };
    @synchronized ([TPPrefs class]) {
        if (!gTPHeldMessages) gTPHeldMessages = [NSMutableDictionary dictionary];
        if (!gTPHeldMessages[k]) gTPHeldMessages[k] = [NSMutableArray array];
        [gTPHeldMessages[k] addObject:[once copy]];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), once);
}
%end

// A reply is detected when Threads builds an outgoing message or a message action. Detecting it
// in MDCoreSendService was wrong: most mutations there are thread updates such as reads.
%hook BCNSlideOutgoingMessagePayload
- (id)initWithOfflineThreadingId:(id)otid threadFbid:(id)fbid senderFbid:(id)sender sendDate:(id)date content:(id)content navChain:(id)chain forwardedMessageId:(id)fwd sendAttribution:(id)attr promptSessionId:(id)ps qnaQuestionId:(id)qid qnaQuestion:(id)q {
    id me = %orig;
    if (me && [TPPrefs boolForKey:TPKeyNoSeen]) {
        TPAllowSeenAfterReply(fbid);
    }
    return me;
}
%end
%hook BCNSlideOutgoingMessageUpdatePayload
- (id)initWithOfflineThreadingId:(id)otid messageId:(id)mid threadFbid:(id)fbid sendDate:(id)date action:(id)action navChain:(id)chain {
    id me = %orig;
    if (me && [TPPrefs boolForKey:TPKeyNoSeen]) {
        TPAllowSeenAfterReply(fbid);
    }
    return me;
}
%end

static const void *kTPSeenButtonKey = &kTPSeenButtonKey;

static void TPSetSeenButtonState(UIButton *b, BOOL showsSeen) {
    [b setImage:[UIImage systemImageNamed:showsSeen ? @"eye" : @"eye.slash"
                         withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium]]
       forState:UIControlStateNormal];
    b.tintColor = showsSeen ? [TPUI accentIcon] : UIColor.secondaryLabelColor;
    b.accessibilityValue = TPL(showsSeen ? @"This chat shows Seen" : @"This chat hides Seen");
}

static UIViewController *TPChatViewControllerOf(UIView *v) {
    Class chat = objc_getClass("_TtC21BCNSlideMessageListUI33BCNSlideMessageListViewController");
    for (UIResponder *r = v; r; r = r.nextResponder) if (chat && [r isKindOfClass:chat]) return (UIViewController *)r;
    return nil;
}

static NSString *TPChatKeyOf(UIViewController *chat) {
    uint8_t *slot = chat ? TPIvarAddress(chat, "threadId") : NULL;
    uintptr_t p = 0; if (slot) memcpy(&p, slot, 8);
    id thread = p ? (__bridge id)(void *)p : nil;
    return thread ? TPThreadKey(thread) : nil;
}

// Per-chat eye button, placed left of the "..." (moreButton) in
// BCNSlideMessageListNavBarTitleView so it appears and transitions with the title bar.
static UIButton *TPMakeSeenButton(void) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    objc_setAssociatedObject(btn, kTPSeenButtonKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    btn.accessibilityLabel = TPL(@"Seen for This Chat");
    TPSetSeenButtonState(btn, NO);
    __weak UIButton *wb = btn;
    [btn addAction:[UIAction actionWithHandler:^(UIAction *a) {
        UIViewController *chat = TPChatViewControllerOf(wb);
        NSString *key = TPChatKeyOf(chat);
        if (!key.length) { [TPHUD toast:TPL(@"Couldn't find this chat")]; return; }
        BOOL show = !TPChatShowsSeen(key);
        TPSetChatShowsSeen(key, show);
        gTPOpenChatKey = key; gTPOpenChatShowsSeen = show;
        [TPUI hapticLight];
        TPSetSeenButtonState(wb, show);
        [TPHUD toast:TPL(show ? @"This chat shows Seen" : @"This chat hides Seen")];
        if (show) TPSendSeenNow(key);
    }] forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

%hook _TtC21BCNSlideMessageListUI34BCNSlideMessageListNavBarTitleView
- (void)layoutSubviews {
    %orig;
    UIView *me = (UIView *)self;
    UIButton *btn = objc_getAssociatedObject(me, kTPSeenButtonKey);
    if (![TPPrefs boolForKey:TPKeyNoSeen]) { btn.hidden = YES; return; }
    uint8_t *slot = TPIvarAddress(me, "$__lazy_storage_$_moreButton");
    uintptr_t p = 0; if (slot) memcpy(&p, slot, 8);
    UIView *more = p ? (__bridge UIView *)(void *)p : nil;
    if (![more isKindOfClass:[UIView class]] || !more.superview || more.hidden) { btn.hidden = YES; return; }
    if (!btn) {
        btn = TPMakeSeenButton();
        objc_setAssociatedObject(me, kTPSeenButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (btn.superview != more.superview) [more.superview addSubview:btn];
    CGRect m = more.frame;
    btn.frame = CGRectMake(CGRectGetMinX(m) - 8 - 36, CGRectGetMidY(m) - 18, 36, 36);
    NSString *key = TPChatKeyOf(TPChatViewControllerOf(me));
    BOOL shows = TPChatShowsSeen(key);
    if (key.length && me.window) { gTPOpenChatKey = key; gTPOpenChatShowsSeen = shows; }
    TPSetSeenButtonState(btn, shows);
    btn.hidden = NO;
}
- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) gTPOpenChatShowsSeen = NO;
}
%end
%end

// Hide Typing Status. The activity status is always sent as 0 (stopped typing). Changing the
// thread id instead made the request fail and broke live delivery of new messages.
%group NoTyping
%hook BCNTypingIndicatorPublishEventMutationBuilder
+ (id)builderWithActivityStatus:(id)status threadId:(id)tid {
    if (![TPPrefs boolForKey:TPKeyNoTyping] || ![status isKindOfClass:[NSNumber class]] || [status integerValue] == 0) return %orig;
    static CFAbsoluteTime last;
    if (CFAbsoluteTimeGetCurrent() - last > 60) { last = CFAbsoluteTimeGetCurrent(); TPDebug(TPL(@"Typing status blocked")); }
    return %orig(@0, tid);
}
%end
%end


// Keep Unsent Messages. An unsend is applied by the Swift BCNSlideDeleteMessageHandler through
// MDCoreDeltaApplyingBridge, which is created with the handler's type name. Delete commands
// produced for that handler are dropped, so the message stays in the local store.
// MDCoreMutationCommand is an enum wrapper; its match method exposes the delete payload.
static id TPDeleteCommandPayload(id cmd) {
    SEL sel = NSSelectorFromString(@"matchUpsertCommand:deleteCommand:updateCommand:deleteAllCommand:deleteFolderCommand:");
    if (![cmd respondsToSelector:sel]) return nil;
    __block id payload = nil;
    __block BOOL del = NO;
    void (^none)(id) = ^(id x) {};
    void (^hit)(id) = ^(id x) { del = YES; payload = x; };
    ((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(cmd, sel, none, hit, none, none, none);
    return del ? (payload ?: (id)kCFNull) : nil;
}

static NSString *const kTPUnsentKey = @"tp_unsent_messages";
static NSMutableArray<NSString *> *gTPUnsent;

static NSMutableArray<NSString *> *TPUnsentList(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kTPUnsentKey];
        gTPUnsent = [saved isKindOfClass:[NSArray class]] ? [saved mutableCopy] : [NSMutableArray array];
    });
    return gTPUnsent;
}

static NSHashTable<UIView *> *gTPMessageCells;

// Visible message cells are tracked weakly so the "Unsent" label appears immediately, without
// leaving and reopening the chat. The label is shown even after the setting is turned off.
static void TPRefreshMessageCells(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIView *cell in gTPMessageCells.allObjects) if (cell.window) [cell setNeedsLayout];
    });
}

static void TPRememberUnsent(id deletePayload) {
    id ids = [TPDownloader safeValue:deletePayload key:@"messageAndThreadIds"];
    if (![ids respondsToSelector:@selector(allObjects)] && ![ids isKindOfClass:[NSArray class]]) return;
    NSArray *items = [ids isKindOfClass:[NSArray class]] ? ids : [ids allObjects];
    @synchronized (TPUnsentList()) {
        for (id e in items) {
            NSString *d = [e description];
            if (d.length && ![gTPUnsent containsObject:d]) [gTPUnsent addObject:d];
        }
        while (gTPUnsent.count > 500) [gTPUnsent removeObjectAtIndex:0];
        [[NSUserDefaults standardUserDefaults] setObject:[gTPUnsent copy] forKey:kTPUnsentKey];
    }
    TPRefreshMessageCells();
}

static BOOL TPIsUnsentMessageId(NSString *mid) {
    if (mid.length < 4) return NO;
    @synchronized (TPUnsentList()) {
        for (NSString *d in gTPUnsent) if ([d containsString:mid]) return YES;
    }
    return NO;
}

// Reads a 16-byte Swift String. Only small strings, native strings and bridged NSStrings are
// accepted, and every address is checked before it is read.
static NSString *TPReadSwiftString(const uint8_t *p) {
    if (!p) return nil;
    uint64_t w0, w1;
    memcpy(&w0, p, 8); memcpy(&w1, p + 8, 8);
    if (w1 & (1ULL << 61)) {
        NSUInteger n = (w1 >> 56) & 0xF;
        if (n > 15) return nil;
        char buf[16]; memcpy(buf, p, 16);
        return [[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding];
    }
    uintptr_t addr = (uintptr_t)(w1 & 0x0FFFFFFFFFFFFFFFULL);
    if (!addr || !malloc_zone_from_ptr((const void *)addr)) return nil;
    if ((w1 >> 60) == 0x4) {
        id obj = (__bridge id)(void *)addr;
        return [obj isKindOfClass:[NSString class]] ? obj : nil;
    }
    if ((w1 >> 60) != 0) return nil;
    NSUInteger n = (NSUInteger)(w0 & 0x0000FFFFFFFFFFFFULL);
    if (n == 0 || n > 512 || malloc_size((const void *)addr) < 32 + n) return nil;
    return [[NSString alloc] initWithBytes:(const void *)(addr + 32) length:n encoding:NSUTF8StringEncoding];
}

static NSString *TPMessageIdOfCell(UIView *cell) {
    uint8_t *m = TPIvarAddress(cell, "model");
    if (!m) return nil;
    uintptr_t thread; memcpy(&thread, m, 8);
    if (!thread) return nil;
    return TPReadSwiftString(m + 8);
}

static const void *kTPUnsentLabelKey = &kTPUnsentLabelKey;

static void TPUpdateUnsentLabel(UIView *cell) {
    UILabel *label = objc_getAssociatedObject(cell, kTPUnsentLabelKey);
    NSString *mid = TPMessageIdOfCell(cell);
    BOOL show = mid && TPIsUnsentMessageId(mid);
    if (!show) { label.hidden = YES; return; }
    uint8_t *slot = TPIvarAddress(cell, "$__lazy_storage_$_messageContentContainerView");
    UIView *bubble = nil;
    if (slot) { uintptr_t v; memcpy(&v, slot, 8); bubble = v ? (__bridge UIView *)(void *)v : nil; }
    if (![bubble isKindOfClass:[UIView class]] || !bubble.superview) return;
    if (!label) {
        label = [UILabel new];
        label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        label.textColor = UIColor.systemRedColor;
        label.text = TPL(@"Unsent");
        [label sizeToFit];
        objc_setAssociatedObject(cell, kTPUnsentLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *host = ((UICollectionViewCell *)cell).contentView;
    if (label.superview != host) [host addSubview:label];
    CGRect b = [bubble convertRect:bubble.bounds toView:host];
    CGSize s = label.bounds.size;
    BOOL bubbleOnLeft = CGRectGetMidX(b) < host.bounds.size.width / 2;
    CGFloat x = bubbleOnLeft ? CGRectGetMaxX(b) + 6 : CGRectGetMinX(b) - 6 - s.width;
    label.frame = CGRectMake(x, CGRectGetMaxY(b) - s.height - 4, s.width, s.height);
    label.hidden = NO;
}

%group KeepUnsent
%hook MDCoreDeltaApplyingBridge
- (id)mutationCommandsForDeltaWithRequestedState:(id)state currentUserFbid:(id)fbid shouldFallbackToInboxResnapshotOnDeltaHandlingError:(BOOL)fallback {
    id r = %orig;
    if (![TPPrefs boolForKey:TPKeyKeepUnsent]) return r;
    // The handler's type name, kept by the bridge itself (Threads 456 added an argument to the
    // initializer, so read the ivar rather than hooking init).
    Ivar nameIv = class_getInstanceVariable(object_getClass(self), "_wrappedTypeName");
    NSString *name = nameIv ? object_getIvar(self, nameIv) : nil;
    if (![name isKindOfClass:[NSString class]] || ![name containsString:@"DeleteMessage"]) return r;
    Class resultCls = objc_getClass("MDCoreDeltaApplicationResult");
    Ivar iv = resultCls && [r isKindOfClass:resultCls] ? class_getInstanceVariable(resultCls, "_mutationCommands_commands") : NULL;
    NSArray *cmds = iv ? object_getIvar(r, iv) : nil;
    if (![cmds isKindOfClass:[NSArray class]]) return r;
    NSMutableArray *kept = [NSMutableArray array];
    for (id cmd in cmds) {
        id payload = TPDeleteCommandPayload(cmd);
        if (!payload) { [kept addObject:cmd]; continue; }
        if (payload != (id)kCFNull) TPRememberUnsent(payload);
    }
    if (kept.count == cmds.count) return r;
    SEL make = NSSelectorFromString(@"mutationCommandsWithCommands:");
    if (![resultCls respondsToSelector:make]) return r;
    TPDebug(TPL(@"Unsent message kept"));
    return ((id (*)(id, SEL, id))objc_msgSend)(resultCls, make, kept);
}
%end

%hook _TtC21BCNSlideMessageListUI27BCNSlideMessageListViewCell
- (void)layoutSubviews {
    %orig;
    if (!gTPMessageCells) gTPMessageCells = [NSHashTable weakObjectsHashTable];
    [gTPMessageCells addObject:(UIView *)self];
    TPUpdateUnsentLabel((UIView *)self);
}
%end
%end

// ---------------------------------------------------------------------------------------------
// Author info: location / join date / new-account badge next to names in the feed.
// The Bloks fetcher needs an object set from the running app, captured from the first Bloks
// context Threads creates.
%group AuthorInfo

%hook _TtC21BCNFeedItemHeaderCell32BCNFeedItemHeaderCellContentView
- (void)layoutSubviews {
    %orig;
    [TPAuthorInfo layoutBadgeInHeader:(UIView *)self];
}
%end

@interface IGListAdapter : NSObject
- (id)sectionControllerForSection:(NSInteger)section;
@end

// "Own line" mode: a header row's height comes from its section controller via IGListAdapter.
// Which row is a header is only known once its cell is built, so remember it there (per section
// controller) and have the section re-measured once.
static const void *kTPHeaderRowsKey = &kTPHeaderRowsKey;

// A taller header row makes Threads centre its content vertically, pushing the name down into the
// new space. Give the content view back its natural height (top-aligned) so the extra line sits
// below it, where the author info goes.
static BOOL TPHeaderCellIsExtended(UICollectionViewCell *cell) {
    UIView *v = cell.superview;
    while (v && ![v isKindOfClass:[UICollectionView class]]) v = v.superview;
    UICollectionView *cv = (UICollectionView *)v;
    NSIndexPath *ip = cv ? [cv indexPathForCell:cell] : nil;
    if (!ip) return NO;
    id adapter = nil;
    for (id cand in @[cv.dataSource ?: (id)NSNull.null, cv.delegate ?: (id)NSNull.null])
        if ([cand respondsToSelector:@selector(sectionControllerForSection:)]) { adapter = cand; break; }
    id sc = adapter ? [adapter sectionControllerForSection:ip.section] : nil;
    NSIndexSet *rows = sc ? objc_getAssociatedObject(sc, kTPHeaderRowsKey) : nil;
    return [rows containsIndex:(NSUInteger)ip.item];
}

%hook _TtC21BCNFeedItemHeaderCell21BCNFeedItemHeaderCell
- (void)layoutSubviews {
    %orig;
    CGFloat extra = [TPAuthorInfo extraHeaderHeight];
    if (extra <= 0) return;
    UICollectionViewCell *cell = (UICollectionViewCell *)self;
    if (!TPHeaderCellIsExtended(cell)) return;
    static Class contentCls;
    if (!contentCls) contentCls = objc_getClass("_TtC21BCNFeedItemHeaderCell32BCNFeedItemHeaderCellContentView");
    NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if (contentCls && [v isKindOfClass:contentCls]) {
            CGRect f = v.frame;
            CGFloat natural = cell.bounds.size.height - extra - f.origin.y;
            if (f.size.height > natural + 1 && natural > 20) {
                f.size.height = natural;
                v.frame = f;
                [v layoutIfNeeded];
            }
            break;
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
}
%end

static const void *kTPFilteredSectionKey = &kTPFilteredSectionKey;
static NSMutableDictionary<NSString *, NSHashTable *> *gTPPendingNewAcctSections = nil;

static NSArray<NSString *> *TPMutedKeywordsList(void) {
    NSArray<NSString *> *out = [TPPrefs mutedRules];
    return out.count ? out : nil;
}

static void TPRecordFilterHit(NSString *rule) {
    if (!rule.length) return;
    NSUserDefaults *ud = [TPPrefs defaults];
    NSMutableDictionary *hits = [[ud dictionaryForKey:@"tp_filter_hit_counts"] mutableCopy] ?: [NSMutableDictionary dictionary];
    hits[rule] = @([hits[rule] integerValue] + 1);
    [ud setObject:hits forKey:@"tp_filter_hit_counts"];
}

// The keyword or /regex/ rule found in the text, or nil. (@username rules are checked on headers.)
static NSString *TPStringMatchesKeywords(NSString *text, NSArray<NSString *> *keywords) {
    if (!text.length || !keywords.count) return nil;
    for (NSString *kw in keywords) {
        if ([kw hasPrefix:@"@"] && kw.length > 1) continue;
        if ([kw hasPrefix:@"/"] && [kw hasSuffix:@"/"] && kw.length > 2) {
            // Compiled once per rule: this runs for every cell as the feed scrolls.
            static NSCache<NSString *, id> *cache;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ cache = [NSCache new]; });
            id re = [cache objectForKey:kw];
            if (!re) {
                NSString *pat = [kw substringWithRange:NSMakeRange(1, kw.length - 2)];
                re = [NSRegularExpression regularExpressionWithPattern:pat options:NSRegularExpressionCaseInsensitive error:nil] ?: NSNull.null;
                [cache setObject:re forKey:kw];
            }
            if (re == NSNull.null) continue;
            if ([(NSRegularExpression *)re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)]) return kw;
            continue;
        }
        if ([text rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) return kw;
    }
    return nil;
}

static NSString *TPAuthorMatchesMutedRules(NSString *author, NSArray<NSString *> *keywords) {
    if (!author.length || !keywords.count) return nil;
    for (NSString *kw in keywords) {
        if ([kw hasPrefix:@"@"] && kw.length > 1) {
            NSString *handle = [kw substringFromIndex:1];
            if ([author caseInsensitiveCompare:handle] == NSOrderedSame) return kw;
        }
    }
    return nil;
}

static NSString *TPCellModelContainsKeyword(UIView *cell, NSArray<NSString *> *keywords) {
    if (!cell || !keywords.count) return nil;
    for (NSString *ivarName in @[@"cellMediaFragment", @"mediaFragment", @"parentMediaFragment", @"postItem", @"viewModel"]) {
        id m = [TPDownloader ivarValue:cell name:ivarName];
        if (!m) continue;
        id cap = [TPDownloader safeValue:m key:@"caption"];
        NSString *capText = [cap isKindOfClass:[NSString class]] ? cap : [TPDownloader safeValue:cap key:@"text"];
        NSString *hit = [capText isKindOfClass:[NSString class]] ? TPStringMatchesKeywords(capText, keywords) : nil;
        if (hit) return hit;
        for (NSString *tk in @[@"captionText", @"text", @"bodyText", @"accessibilityLabel"]) {
            id v = [TPDownloader safeValue:m key:tk];
            hit = [v isKindOfClass:[NSString class]] ? TPStringMatchesKeywords(v, keywords) : nil;
            if (hit) return hit;
        }
    }
    return nil;
}

static NSString *TPViewContainsKeyword(UIView *v, NSArray<NSString *> *keywords, int depth) {
    if (!v || depth > 7 || v.hidden) return nil;
    NSString *text = nil;
    if ([v isKindOfClass:[UILabel class]]) {
        text = [(UILabel *)v text];
    } else if ([v isKindOfClass:[UITextView class]]) {
        text = [(UITextView *)v text];
    } else if ([v respondsToSelector:@selector(styledString)]) {
        id styled = nil;
        @try { styled = [v valueForKey:@"styledString"]; } @catch (__unused id e) {}
        id as = [styled respondsToSelector:@selector(attributedString)] ? [styled valueForKey:@"attributedString"] : nil;
        if ([as isKindOfClass:[NSAttributedString class]]) text = [(NSAttributedString *)as string];
    } else if ([v respondsToSelector:@selector(attributedText)]) {
        id at = nil;
        @try { at = [v valueForKey:@"attributedText"]; } @catch (__unused id e) {}
        if ([at isKindOfClass:[NSAttributedString class]]) text = [(NSAttributedString *)at string];
    }
    NSString *hit = TPStringMatchesKeywords(text, keywords);
    if (hit) return hit;
    for (UIView *s in v.subviews) {
        hit = TPViewContainsKeyword(s, keywords, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static BOOL TPIsThreadDetailVCClass(Class cls) {
    if (!cls) return NO;
    NSString *name = NSStringFromClass(cls).lowercaseString;
    if ([name containsString:@"direct"] || [name containsString:@"message"] ||
        [name containsString:@"setting"] || [name containsString:@"profile"] ||
        [name containsString:@"search"] || [name containsString:@"activity"] ||
        [name containsString:@"notif"] || [name containsString:@"sharesheet"]) return NO;
    return [name containsString:@"bcnpermalink"] ||
           [name containsString:@"permalinkviewcontroller"] ||
           [name containsString:@"threaddetailviewcontroller"] ||
           [name containsString:@"postdetailviewcontroller"];
}

static BOOL TPCollectionViewIsThreadDetail(UICollectionView *cv) {
    for (UIResponder *r = cv; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) {
            return TPIsThreadDetailVCClass(r.class);
        }
    }
    return NO;
}

static void TPInvalidateSectionController(id sc) {
    if (!sc) return;
    __weak id weakSC = sc;
    dispatch_async(dispatch_get_main_queue(), ^{
        id s = weakSC;
        id ctx = [s respondsToSelector:@selector(collectionContext)] ? [s performSelector:@selector(collectionContext)] : nil;
        SEL inv = NSSelectorFromString(@"invalidateLayoutForSectionController:completion:");
        if (ctx && [ctx respondsToSelector:inv])
            ((void (*)(id, SEL, id, id))objc_msgSend)(ctx, inv, s, nil);
    });
}

// A filtered post isn't removed without a trace: its first row becomes a thin "1 post hidden ·
// reason · Show" line, and the rest of its rows collapse. Tapping Show brings the post back.
static const void *kTPFilterReasonKey = &kTPFilterReasonKey;
static const void *kTPFilterRuleKey = &kTPFilterRuleKey;   // the muted rule that hid a section, if one did
static const void *kTPThreadFirstPostKey = &kTPThreadFirstPostKey;   // on a thread page's collection view
static const void *kTPRevealedKey = &kTPRevealedKey;
static const void *kTPHiddenLineKey = &kTPHiddenLineKey;
static const void *kTPCellClipsKey = &kTPCellClipsKey;
static const void *kTPCellCollapsedKey = &kTPCellCollapsedKey;   // TPWeakBox -> section controller
static const CGFloat kTPHiddenLineH = 36;

static BOOL TPSectionFiltered(id sc) {
    return sc && [objc_getAssociatedObject(sc, kTPFilteredSectionKey) boolValue] && ![objc_getAssociatedObject(sc, kTPRevealedKey) boolValue];
}

static void TPStyleFilteredCell(UICollectionViewCell *cell, NSInteger item, id sc);
static void TPRestyleSection(id sc);

@interface TPHiddenLine : UIControl <UIContextMenuInteractionDelegate>
@property (nonatomic, weak) id section;
@property (nonatomic, strong) UILabel *label, *show;
@end
@implementation TPHiddenLine
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _label = [UILabel new];
        _label.font = [UIFont systemFontOfSize:13];
        _label.textColor = UIColor.secondaryLabelColor;
        _show = [UILabel new];
        _show.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _show.textColor = [TPUI accent];
        _show.text = TPL(@"Show");
        _show.textAlignment = NSTextAlignmentRight;
        UIView *line = [UIView new];
        line.backgroundColor = UIColor.separatorColor;
        line.tag = 1;
        for (UIView *v in @[_label, _show, line]) { v.userInteractionEnabled = NO; [self addSubview:v]; }
        [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
        // Long-press: show it, or fix the rule that hid it right here.
        [self addInteraction:[[UIContextMenuInteraction alloc] initWithDelegate:self]];
    }
    return self;
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                        configurationForMenuAtLocation:(CGPoint)location {
    __weak typeof(self) weak = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        TPHiddenLine *s = weak;
        NSString *rule = s.section ? objc_getAssociatedObject(s.section, kTPFilterRuleKey) : nil;
        NSMutableArray *acts = [NSMutableArray array];
        [acts addObject:[UIAction actionWithTitle:TPL(@"Show This Post") image:[UIImage systemImageNamed:@"eye"] identifier:nil
                                          handler:^(UIAction *a) { [weak tapped]; }]];
        if (rule.length) {
            [acts addObject:[UIAction actionWithTitle:TPL(@"Mute for 24 Hours Only") image:[UIImage systemImageNamed:@"clock"] identifier:nil
                                              handler:^(UIAction *a) {
                [TPPrefs setExpiry:[NSDate dateWithTimeIntervalSinceNow:24 * 3600] forMutedRule:rule];
                [TPHUD toast:[NSString stringWithFormat:TPL(@"%@ is now muted for 24 hours"), rule]];
            }]];
        }
        [acts addObject:[UIAction actionWithTitle:TPL(@"Manage Muted Rules") image:[UIImage systemImageNamed:@"list.bullet"] identifier:nil
                                          handler:^(UIAction *a) { [TPSettingsViewController presentMutedRules]; }]];
        if (rule.length) {
            UIAction *del = [UIAction actionWithTitle:TPL(@"Delete This Rule") image:[UIImage systemImageNamed:@"trash"] identifier:nil
                                              handler:^(UIAction *a) {
                NSMutableArray *rules = [[TPPrefs mutedRules] mutableCopy];
                [rules removeObject:rule];
                [TPPrefs setMutedRules:rules];
                [weak tapped];   // this post comes back now; others hidden by it on the next refresh
                [TPHUD toast:TPL(@"Rule deleted. Other posts it hid come back when the feed refreshes.")];
            }];
            del.attributes = UIMenuElementAttributesDestructive;
            [acts addObject:del];
        }
        return [UIMenu menuWithTitle:rule.length ? rule : @"" children:acts];
    }];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat showW = [_show sizeThatFits:CGSizeMake(120, 20)].width;
    _show.frame = CGRectMake(b.size.width - 16 - showW, 0, showW, kTPHiddenLineH);
    _label.frame = CGRectMake(16, 0, CGRectGetMinX(_show.frame) - 24, kTPHiddenLineH);
    [self viewWithTag:1].frame = CGRectMake(0, kTPHiddenLineH - 0.5, b.size.width, 0.5);
}
- (void)tapped {
    id sc = self.section;
    if (!sc) return;
    [TPUI hapticLight];
    objc_setAssociatedObject(sc, kTPRevealedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TPRestyleSection(sc);
    TPInvalidateSectionController(sc);
}
@end

static UIColor *TPFeedBackground(UIView *v) {
    for (UIView *p = v.superview; p; p = p.superview) {
        UIColor *c = p.backgroundColor;
        if (c && CGColorGetAlpha(c.CGColor) > 0.9) return c;
    }
    return UIColor.systemBackgroundColor;
}

static void TPRemoveHiddenLine(UICollectionViewCell *cell) {
    TPHiddenLine *line = objc_getAssociatedObject(cell, kTPHiddenLineKey);
    if (line) {
        [line removeFromSuperview];
        objc_setAssociatedObject(cell, kTPHiddenLineKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSNumber *clips = objc_getAssociatedObject(cell, kTPCellClipsKey);
        if (clips) cell.clipsToBounds = clips.boolValue;
    }
    if (objc_getAssociatedObject(cell, kTPCellCollapsedKey)) {
        objc_setAssociatedObject(cell, kTPCellCollapsedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSNumber *clips = objc_getAssociatedObject(cell, kTPCellClipsKey);
        if (clips) cell.clipsToBounds = clips.boolValue;
        cell.hidden = NO;
    }
}

// Rows after the first are collapsed to almost no height. Hiding alone isn't enough: the
// collection view re-applies each row's layout (which un-hides it) without asking for the cell
// again, and an unclipped row then draws its full content over the next post. Clipping to the
// collapsed height keeps it invisible even when it's shown.
static void TPCollapseCell(UICollectionViewCell *cell, id sc) {
    if (!objc_getAssociatedObject(cell, kTPCellCollapsedKey)) {
        if (!objc_getAssociatedObject(cell, kTPHiddenLineKey))
            objc_setAssociatedObject(cell, kTPCellClipsKey, @(cell.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TPWeakBox *box = [TPWeakBox new];
        box.object = sc;
        objc_setAssociatedObject(cell, kTPCellCollapsedKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        ((TPWeakBox *)objc_getAssociatedObject(cell, kTPCellCollapsedKey)).object = sc;
    }
    cell.clipsToBounds = YES;
    cell.hidden = YES;
}

static void TPStyleFilteredCell(UICollectionViewCell *cell, NSInteger item, id sc) {
    TPHiddenLine *line = objc_getAssociatedObject(cell, kTPHiddenLineKey);
    if (!TPSectionFiltered(sc)) {
        TPRemoveHiddenLine(cell);
        cell.hidden = NO;
        return;
    }
    if (item != 0) {
        if (line) { TPRemoveHiddenLine(cell); line = nil; }
        TPCollapseCell(cell, sc);
        return;
    }
    if (objc_getAssociatedObject(cell, kTPCellCollapsedKey)) TPRemoveHiddenLine(cell);
    cell.hidden = NO;
    if (!line) {
        objc_setAssociatedObject(cell, kTPCellClipsKey, @(cell.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        line = [[TPHiddenLine alloc] initWithFrame:cell.bounds];
        objc_setAssociatedObject(cell, kTPHiddenLineKey, line, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    cell.clipsToBounds = YES;
    line.section = sc;
    line.frame = cell.bounds;
    line.backgroundColor = TPFeedBackground(cell);
    NSString *reason = objc_getAssociatedObject(sc, kTPFilterReasonKey);
    line.label.text = reason.length ? [NSString stringWithFormat:@"%@ · %@", TPL(@"1 post hidden"), reason] : TPL(@"1 post hidden");
    [cell addSubview:line];
    [cell bringSubviewToFront:line];
}

// Re-style the section's cells already on screen (a filter decided after they were shown, or Show).
static void TPRestyleSection(id sc) {
    id ctx = [sc respondsToSelector:@selector(collectionContext)] ? [sc performSelector:@selector(collectionContext)] : nil;
    SEL visSel = NSSelectorFromString(@"visibleCellsForSectionController:");
    SEL idxSel = NSSelectorFromString(@"indexForCell:sectionController:");
    if (!ctx || ![ctx respondsToSelector:visSel] || ![ctx respondsToSelector:idxSel]) return;
    NSArray *cells = ((id (*)(id, SEL, id))objc_msgSend)(ctx, visSel, sc);
    for (UICollectionViewCell *c in cells) {
        NSInteger idx = ((NSInteger (*)(id, SEL, id, id))objc_msgSend)(ctx, idxSel, c, sc);
        TPStyleFilteredCell(c, idx, sc);
    }
}

static void TPMarkFiltered(id sc, NSString *reason) {
    if (!sc || [objc_getAssociatedObject(sc, kTPRevealedKey) boolValue]) return;
    if ([objc_getAssociatedObject(sc, kTPFilteredSectionKey) boolValue]) return;
    objc_setAssociatedObject(sc, kTPFilteredSectionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(sc, kTPFilterReasonKey, reason, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [TPPrefs recordFilteredPostWithReason:reason];
    TPRestyleSection(sc);
    TPInvalidateSectionController(sc);
    // The match is often found while the post's rows are still being built (say in the text row),
    // when the rows built just before it (the header) don't count as on screen yet and so miss the
    // restyle above. Restyle again once they're in place, and after the section has shrunk.
    __weak id weakSC = sc;
    dispatch_async(dispatch_get_main_queue(), ^{ id s2 = weakSC; if (s2) TPRestyleSection(s2); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id s2 = weakSC; if (s2) TPRestyleSection(s2);
    });
}

static void TPTrackPendingNewAccountSection(NSString *pk, id sc) {
    if (!pk.length || !sc) return;
    if (!gTPPendingNewAcctSections) {
        gTPPendingNewAcctSections = [NSMutableDictionary dictionary];
        [NSNotificationCenter.defaultCenter addObserverForName:TPAuthorInfoDidUpdateNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *n) {
            if (![TPPrefs boolForKey:TPKeyHideNewAccounts]) return;
            NSString *updatedPk = n.userInfo[@"pk"];
            if (!updatedPk.length) return;
            NSHashTable *table = gTPPendingNewAcctSections[updatedPk];
            if (!table) return;
            [gTPPendingNewAcctSections removeObjectForKey:updatedPk];
            if (![TPAuthorInfo isNewAccountForPk:updatedPk]) return;
            for (id pendingSC in table.allObjects) TPMarkFiltered(pendingSC, TPL(@"New account"));
        }];
    }
    if (gTPPendingNewAcctSections.count > 300) [gTPPendingNewAcctSections removeAllObjects];
    NSHashTable *table = gTPPendingNewAcctSections[pk];
    if (!table) {
        table = [NSHashTable weakObjectsHashTable];
        gTPPendingNewAcctSections[pk] = table;
    }
    [table addObject:sc];
}

%hook IGListAdapter
- (CGSize)sizeForItemAtIndexPath:(NSIndexPath *)path {
    CGSize r = %orig;
    id sc = [self sectionControllerForSection:path.section];
    if (TPSectionFiltered(sc)) {
        return CGSizeMake(r.width, path.item == 0 ? kTPHiddenLineH : 0.01);
    }
    CGFloat extra = [TPAuthorInfo extraHeaderHeight];
    if (extra > 0 && r.height > 0) {
        NSIndexSet *rows = sc ? objc_getAssociatedObject(sc, kTPHeaderRowsKey) : nil;
        if ([rows containsIndex:(NSUInteger)path.item]) {
            r.height += extra;
        }
    }
    return r;
}
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)path {
    UICollectionViewCell *cell = %orig;
    id sc = [self sectionControllerForSection:path.section];
    if (!sc) return cell;

    static Class headerCls;
    if (!headerCls) headerCls = objc_getClass("_TtC21BCNFeedItemHeaderCell21BCNFeedItemHeaderCell");
    BOOL isHeader = (headerCls && [cell isKindOfClass:headerCls]);
    if (isHeader) {
        NSMutableIndexSet *rows = objc_getAssociatedObject(sc, kTPHeaderRowsKey);
        if (!rows) { rows = [NSMutableIndexSet indexSet]; objc_setAssociatedObject(sc, kTPHeaderRowsKey, rows, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        if (![rows containsIndex:(NSUInteger)path.item]) {
            [rows addIndex:(NSUInteger)path.item];
            if ([TPAuthorInfo extraHeaderHeight] > 0) TPInvalidateSectionController(sc);
        }
    }

    // Feed and replies auto-filter. On a thread page only muted rules apply (not New Accounts),
    // and never to the post the page is about: the first post section seen there, and anything
    // above it, is left alone.
    BOOL inThread = TPCollectionViewIsThreadDetail(cv);
    BOOL protectedPost = NO;
    if (inThread && isHeader) {
        NSNumber *first = objc_getAssociatedObject(cv, kTPThreadFirstPostKey);
        if (!first || path.section <= first.integerValue) {
            objc_setAssociatedObject(cv, kTPThreadFirstPostKey, @(path.section), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            protectedPost = YES;
        }
    } else if (inThread) {
        NSNumber *first = objc_getAssociatedObject(cv, kTPThreadFirstPostKey);
        protectedPost = !first || path.section <= first.integerValue;
    }
    if (!protectedPost) {
        BOOL revealed = [objc_getAssociatedObject(sc, kTPRevealedKey) boolValue];
        BOOL alreadyFiltered = [objc_getAssociatedObject(sc, kTPFilteredSectionKey) boolValue];
        BOOL shouldFilter = alreadyFiltered || revealed;
        NSString *reason = nil;
        if (!shouldFilter && isHeader && !inThread && [TPPrefs boolForKey:TPKeyHideNewAccounts]) {
            NSMutableArray<UIView *> *hdrs = [NSMutableArray array];
            TPCollectHeaders(cell, hdrs, 0);
            for (UIView *h in hdrs) {
                NSString *pk = [TPAuthorInfo pkForHeader:h];
                if (!pk.length) continue;
                if ([TPAuthorInfo infoForPk:pk]) {
                    if ([TPAuthorInfo isNewAccountForPk:pk]) {
                        shouldFilter = YES;
                        reason = TPL(@"New account");
                        break;
                    }
                } else {
                    TPTrackPendingNewAccountSection(pk, sc);
                    [TPAuthorInfo requestPk:pk];
                }
            }
        }
        NSString *matchedRule = nil;
        if (!shouldFilter && isHeader) {
            NSArray<NSString *> *kws = TPMutedKeywordsList();
            if (kws.count) {
                NSMutableArray<UIView *> *hdrs = [NSMutableArray array];
                TPCollectHeaders(cell, hdrs, 0);
                for (UIView *h in hdrs) {
                    NSString *author = [TPAuthorInfo postInfoInHeader:h][@"author"];
                    NSString *hit = TPAuthorMatchesMutedRules(author, kws);
                    if (hit) {
                        shouldFilter = YES;
                        matchedRule = hit;
                        reason = [NSString stringWithFormat:TPL(@"Muted %@"), hit];
                        break;
                    }
                }
            }
        }
        if (!shouldFilter) {
            NSArray<NSString *> *kws = TPMutedKeywordsList();
            NSString *kw = kws.count ? (TPCellModelContainsKeyword(cell, kws) ?: TPViewContainsKeyword(cell, kws, 0)) : nil;
            if (kw) {
                shouldFilter = YES;
                matchedRule = kw;
                reason = [NSString stringWithFormat:TPL(@"Keyword \"%@\""), kw];
            }
        }
        if (shouldFilter && !alreadyFiltered && !revealed) {
            if (matchedRule.length) TPRecordFilterHit(matchedRule);
            if (matchedRule.length) objc_setAssociatedObject(sc, kTPFilterRuleKey, matchedRule, OBJC_ASSOCIATION_COPY_NONATOMIC);
            TPMarkFiltered(sc, reason);
        }
        TPStyleFilteredCell(cell, path.item, sc);
    } else {
        TPStyleFilteredCell(cell, path.item, nil);
    }
    return cell;
}
%end

// The collection view re-applies a row's layout (position, size, hidden) without asking for the
// cell again, e.g. while a filtered post shrinks. Re-assert the filtered look each time, and drop
// it once the post has been shown again (Show).
%hook UICollectionViewCell
- (void)applyLayoutAttributes:(UICollectionViewLayoutAttributes *)attrs {
    %orig;
    UICollectionViewCell *cell = (UICollectionViewCell *)self;
    TPWeakBox *collapsed = objc_getAssociatedObject(cell, kTPCellCollapsedKey);
    TPHiddenLine *line = objc_getAssociatedObject(cell, kTPHiddenLineKey);
    if (!collapsed && !line) return;
    id sc = collapsed ? collapsed.object : line.section;
    if (!TPSectionFiltered(sc)) { TPRemoveHiddenLine(cell); return; }
    if (collapsed) { cell.clipsToBounds = YES; cell.hidden = YES; }
    else cell.clipsToBounds = YES;
}
%end

%hook IGUserSession
- (id)initWithUser:(id)user creationReason:(unsigned long long)reason deviceSession:(id)session {
    id r = %orig;
    [TPAuthorInfo noteUserSession:r];
    return r;
}
%end

%hook PNPandoGraphQLService
- (id)initWithService:(id)service {
    id r = %orig;
    [TPAuthorInfo noteService:r kind:@"pando"];
    return r;
}
%end

%hook PNPandoGraphQLConsistency
- (id)initWithUnderlyingConsistency:(id)c {
    id r = %orig;
    [TPAuthorInfo noteService:r kind:@"consistency"];
    return r;
}
// shared_ptr arguments are passed by reference on arm64, so a pointer stands in for them here.
- (id)initWithConsistency:(void *)c enableFlipperJsonEncoding:(BOOL)e enableLambdaSubscribeForNonQVSupportedModels:(BOOL)m {
    id r = %orig;
    [TPAuthorInfo noteService:r kind:@"consistency"];
    return r;
}
- (id)initWithConsistency:(void *)c enableFlipperJsonEncoding:(BOOL)e subscriptionBlocklist:(void *)b enableLambdaSubscribeForNonQVSupportedModels:(BOOL)m {
    id r = %orig;
    [TPAuthorInfo noteService:r kind:@"consistency"];
    return r;
}
%end

%hook IGApplicationAnalytics
- (void)handleApplicationDidBecomeActive {
    %orig;
    [TPAuthorInfo noteService:self kind:@"analytics"];
}
%end

%hook BKContext
- (id)initWithObjectSet:(id)set flags:(id)flags {
    id r = %orig;
    if (set) [TPAuthorInfo noteObjectSet:set source:@"BKContext"];
    return r;
}
%end

%hook BKSharedAsyncActionDataFetcher
+ (void)fetchWithObjectSet:(id)set appID:(id)appID params:(id)params timeoutOverride:(id)timeout successHandler:(id)ok errorHandler:(id)err callbackQueue:(id)queue {
    if (set) [TPAuthorInfo noteObjectSet:set source:@"AsyncFetcher"];
    %orig;
}
%end

%hook IGBloksAsyncActionHandler
- (id)initWithAppID:(id)appID params:(id)params context:(id)context successHandler:(id)ok errorHandler:(id)err {
    id r = %orig;
    @try {
        id os = [context respondsToSelector:@selector(objectSet)] ? [context performSelector:@selector(objectSet)] : nil;
        if (os) [TPAuthorInfo noteObjectSet:os source:@"AsyncActionHandler"];
    } @catch (__unused NSException *e) {}
    return r;
}
%end

%hook BKDataFetchGraphQL
+ (void)fetchRootAppWithObjectSet:(id)set appID:(id)appID params:(id)params purpose:(long long)purpose cacheTTL:(unsigned long long)ttl successHandler:(id)ok errorHandler:(id)err callbackQueue:(id)queue {
    if (set) [TPAuthorInfo noteObjectSet:set source:@"RootApp"];
    %orig;
}
+ (void)fetchRootActionWithObjectSet:(id)set appID:(id)appID params:(id)params purpose:(long long)purpose timeoutOverride:(id)timeout successHandler:(id)ok errorHandler:(id)err callbackQueue:(id)queue {
    if (set) [TPAuthorInfo noteObjectSet:set source:@"RootAction"];
    %orig;
}
+ (id)fetchComponentsWithObjectSet:(id)set appID:(id)appID params:(id)params purpose:(long long)purpose requestType:(long long)type successHandler:(id)ok errorHandler:(id)err callbackQueue:(id)queue {
    if (set) [TPAuthorInfo noteObjectSet:set source:@"Components"];
    return %orig;
}
%end


%end


// =============================================================================
// Whole-Thread One-Click Batch Download (Permalink / Thread Detail)
// =============================================================================
static const void *kTPThreadDLBtnKey = &kTPThreadDLBtnKey;
// When the button was last long-pressed: the finger lifting afterwards must not also count as a tap.
static CFTimeInterval gTPThreadLongPressAt;

static UICollectionView *TPFindPrimaryCollectionView(UIView *root, int depth) {
    if (!root || depth > 12) return nil;
    if ([root isKindOfClass:[UICollectionView class]]) {
        UICollectionView *cv = (UICollectionView *)root;
        if (cv.bounds.size.height > 200 && cv.visibleCells.count > 0) return cv;
    }
    for (UIView *s in root.subviews) {
        UICollectionView *found = TPFindPrimaryCollectionView(s, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void TPCollectThreadCells(UICollectionView *cv, NSMutableArray<NSDictionary *> *items,
                                 NSMutableSet<NSString *> *seen, NSMutableDictionary *ctxBox) {
    NSArray<UICollectionViewCell *> *cells = [cv.visibleCells sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ya = a.frame.origin.y, yb = b.frame.origin.y;
        return ya < yb ? NSOrderedAscending : (ya > yb ? NSOrderedDescending : NSOrderedSame);
    }];
    for (UICollectionViewCell *cell in cells) {
        if (cell.hidden) continue;   // a reply hidden by the muted rules
        NSArray<NSDictionary *> *raw = TPCollectPostMedia(cell);
        for (NSDictionary *d in raw) {
            if ([d[@"failed"] boolValue]) continue;
            NSString *k = d[@"key"];
            if (!k.length) k = [[d[@"urls"] firstObject] absoluteString];
            if (k.length && [seen containsObject:k]) continue;
            if (k.length) [seen addObject:k];
            [items addObject:d];
        }
        if (!ctxBox[@"ctx"] && raw.count) {
            NSDictionary *c = TPPostContextForCell(cell);
            if ([c[@"code"] length] || [c[@"author"] length]) ctxBox[@"ctx"] = c;
        }
    }
}

// Threads loads the next batch of replies when the user drags near the end, not when the offset
// is set from code: replay the delegate calls a finger drag and release would send.
static void TPNudgeLoadMore(UIScrollView *sv) {
    id<UIScrollViewDelegate> d = sv.delegate;
    if (!d) return;
    if ([d respondsToSelector:@selector(scrollViewWillBeginDragging:)]) [d scrollViewWillBeginDragging:sv];
    if ([d respondsToSelector:@selector(scrollViewDidScroll:)]) [d scrollViewDidScroll:sv];
    CGPoint target = sv.contentOffset;
    if ([d respondsToSelector:@selector(scrollViewWillEndDragging:withVelocity:targetContentOffset:)])
        [d scrollViewWillEndDragging:sv withVelocity:CGPointMake(0, 2.0) targetContentOffset:&target];
    if ([d respondsToSelector:@selector(scrollViewDidEndDragging:willDecelerate:)]) [d scrollViewDidEndDragging:sv willDecelerate:NO];
    if ([d respondsToSelector:@selector(scrollViewDidEndDecelerating:)]) [d scrollViewDidEndDecelerating:sv];
}

// Whole thread: Threads only builds cells for what's on screen, so scroll through the thread a
// screen at a time, collect each reply's media with the same code as the post download button,
// then scroll back to where the user was.
//
// Progress on the thread page: the top-right button always stays Threads' own plain image item
// (never swapped or redrawn, so it looks the same on iOS 16–27 and never triggers the iOS 26
// glass morph). Progress is a thin line just under the top bar plus a small status chip:
// "12 found" while collecting, "Downloading 40%" while downloading, then a short result.

typedef NS_ENUM(NSInteger, TPThreadBtnState) { TPThreadBtnIdle, TPThreadBtnCollecting, TPThreadBtnDownloading, TPThreadBtnDone };

static UIImage *TPThreadIdleImage(void) { return [UIImage systemImageNamed:@"square.and.arrow.down.on.square"]; }

@interface TPThreadStatusView : UIView
@property (nonatomic, readonly) TPThreadBtnState phase;
@property (nonatomic, copy) void (^onTap)(void);
// Off-screen pages keep their state but don't show the strip.
@property (nonatomic) BOOL suspended;
- (void)attachTo:(UIViewController *)vc;
- (void)showIdle;
- (void)showCollecting:(NSUInteger)found;
- (void)showProgress:(CGFloat)progress;
- (void)showDone:(BOOL)ok saved:(NSInteger)saved failed:(NSInteger)failed;
@end

@implementation TPThreadStatusView {
    UIView *_track, *_fill;
    UIVisualEffectView *_chip;
    UILabel *_label;
    CGFloat _progress;
    BOOL _indeterminate, _wantHidden;
    NSUInteger _doneToken;
}

static const CGFloat kTPLineH = 2.5, kTPChipH = 26, kTPChipGap = 6;

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.alpha = 0;
        self.hidden = YES;
        _track = [UIView new];
        _track.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.1];
        _track.clipsToBounds = YES;
        [self addSubview:_track];
        _fill = [UIView new];
        _fill.backgroundColor = [TPUI accent];
        [_track addSubview:_fill];
        _chip = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]];
        _chip.layer.cornerRadius = kTPChipH / 2;
        _chip.clipsToBounds = YES;
        [self addSubview:_chip];
        _label = [UILabel new];
        _label.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
        _label.textColor = UIColor.labelColor;
        _label.textAlignment = NSTextAlignmentCenter;
        [_chip.contentView addSubview:_label];
        [_chip addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(chipTapped)]];
        _chip.isAccessibilityElement = YES;
        _chip.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}

- (void)chipTapped { if (self.onTap) self.onTap(); }

// Only the chip takes touches; the rest of the strip lets the thread scroll underneath.
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e {
    return !self.hidden && !_suspended && self.alpha > 0.05 && CGRectContainsPoint(CGRectInset(_chip.frame, -6, -6), p);
}

// Pinned just under the top bar. If the page's own view scrolls, the strip goes on the
// navigation controller's view instead so it doesn't scroll away with the replies.
- (void)attachTo:(UIViewController *)vc {
    UIView *page = vc.view;
    UIView *host = [page isKindOfClass:[UIScrollView class]] && vc.navigationController ? vc.navigationController.view : page;
    if (!host || !page || self.superview == host) return;
    [self removeFromSuperview];
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self];
    [NSLayoutConstraint activateConstraints:@[
        [self.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [self.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [self.topAnchor constraintEqualToAnchor:page.safeAreaLayoutGuide.topAnchor],
        [self.heightAnchor constraintEqualToConstant:kTPLineH + kTPChipGap + kTPChipH],
    ]];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    _track.frame = CGRectMake(0, 0, w, kTPLineH);
    if (!_indeterminate) _fill.frame = CGRectMake(0, 0, w * _progress, kTPLineH);
    CGFloat lw = ceil([_label sizeThatFits:CGSizeMake(w - 40, kTPChipH)].width);
    CGFloat cw = MIN(w - 32, lw + 24);
    _chip.frame = CGRectMake(round((w - cw) / 2), kTPLineH + kTPChipGap, cw, kTPChipH);
    _label.frame = _chip.contentView.bounds;
}

- (void)setText:(NSString *)text color:(UIColor *)color {
    _label.text = text;
    _label.textColor = color ?: UIColor.labelColor;
    _chip.accessibilityLabel = text;
    [self setNeedsLayout];
}

- (void)setSuspended:(BOOL)suspended {
    _suspended = suspended;
    [super setHidden:suspended || _wantHidden];
}

- (void)setHidden:(BOOL)hidden {
    _wantHidden = hidden;
    [super setHidden:hidden || _suspended];
}

- (void)appear {
    _doneToken++;
    [self.superview bringSubviewToFront:self];
    if (!_wantHidden && self.alpha > 0.99) return;
    self.hidden = NO;
    [UIView animateWithDuration:0.2 animations:^{ self.alpha = 1; }];
}

- (void)disappear {
    [UIView animateWithDuration:0.25 animations:^{ self.alpha = 0; } completion:^(BOOL f) {
        if (self.alpha < 0.05) { self.hidden = YES; [self stopSweep]; }
    }];
}

- (void)stopSweep {
    _indeterminate = NO;
    [_fill.layer removeAnimationForKey:@"sweep"];
}

- (void)startSweep {
    if (_indeterminate) return;
    _indeterminate = YES;
    [self layoutIfNeeded];
    CGFloat w = MAX(1, self.bounds.size.width), seg = w * 0.3;
    _fill.frame = CGRectMake(0, 0, seg, kTPLineH);
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"position.x"];
    a.fromValue = @(-seg / 2);
    a.toValue = @(w + seg / 2);
    a.duration = 1.1;
    a.repeatCount = HUGE_VALF;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_fill.layer addAnimation:a forKey:@"sweep"];
}

- (void)showIdle {
    _phase = TPThreadBtnIdle;
    [self disappear];
}

- (void)showCollecting:(NSUInteger)found {
    _phase = TPThreadBtnCollecting;
    _fill.backgroundColor = [TPUI accent];
    [self startSweep];
    [self setText:[NSString stringWithFormat:TPL(@"%lu found"), (unsigned long)found] color:nil];
    [self appear];
}

- (void)showProgress:(CGFloat)progress {
    _phase = TPThreadBtnDownloading;
    _fill.backgroundColor = [TPUI accent];
    [self stopSweep];
    _progress = MAX(0.02, MIN(1, progress));
    [self setText:[NSString stringWithFormat:@"%@ %.0f%%", TPL(@"Downloading"), floor(MAX(0, MIN(1, progress)) * 100)] color:nil];
    [self appear];
    [UIView animateWithDuration:0.2 animations:^{ [self layoutIfNeeded]; }];
}

- (void)showDone:(BOOL)ok saved:(NSInteger)saved failed:(NSInteger)failed {
    _phase = TPThreadBtnDone;
    [self stopSweep];
    _progress = 1;
    _fill.backgroundColor = ok ? UIColor.systemGreenColor : UIColor.systemRedColor;
    NSString *text = !ok ? TPL(@"Download failed, please try again later")
                   : failed > 0 ? [NSString stringWithFormat:TPL(@"Saved %ld, failed %ld"), (long)saved, (long)failed]
                   : TPL(@"Done");
    [self setText:text color:ok && failed == 0 ? UIColor.systemGreenColor : (ok ? nil : UIColor.systemRedColor)];
    [self appear];
    NSUInteger token = _doneToken;
    __weak typeof(self) weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) s = weak;
        if (s && s->_doneToken == token && s.phase == TPThreadBtnDone) [s showIdle];
    });
}
@end

@interface TPThreadDLHandler : NSObject
@property (nonatomic, weak) UIViewController *vc;
@property (nonatomic, strong) TPThreadStatusView *button;
@property (nonatomic, weak) UIBarButtonItem *item;
@property (nonatomic, copy) NSString *tag;          // marks this page's downloads in the history
@property (nonatomic, copy) NSString *recordID;     // the download started from this page
@property (nonatomic) BOOL collecting, stopEarly, cancelled;
@property (nonatomic) NSUInteger found;
@property (nonatomic) CGFloat lastProgress;
// The open menu (if any) and the stage it was opened in: its title follows the button, and it
// closes when the stage changes so its choices never go stale.
@property (nonatomic, weak) UIAlertController *sheet;
@property (nonatomic) TPThreadBtnState sheetPhase;
- (void)syncSheet;
@end

static void TPDownloadWholeThread(TPThreadDLHandler *h);

@implementation TPThreadDLHandler

- (instancetype)init {
    if ((self = [super init])) {
        _tag = [@"thread-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(progressed:) name:TPDownloadProgressNotification object:nil];
        [nc addObserver:self selector:@selector(storeChanged) name:TPDownloadStoreDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [TPCapsule setHostedTag:_tag hosted:NO];
}

- (void)syncSheet {
    UIAlertController *a = self.sheet;
    if (!a) return;
    TPThreadBtnState now = self.button.phase;
    if (now != self.sheetPhase) {
        self.sheet = nil;
        [a dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (now == TPThreadBtnCollecting)
        a.title = [NSString stringWithFormat:TPL(@"%lu found"), (unsigned long)self.found];
    else if (now == TPThreadBtnDownloading)
        a.title = [NSString stringWithFormat:@"%@ %.0f%%", TPL(@"Downloading"), floor(self.lastProgress * 100)];
}

- (void)progressed:(NSNotification *)n {
    NSString *rid = n.userInfo[@"record"];
    if (!rid) return;
    if (!self.recordID) {
        if (![[TPDownloadStore recordWithID:rid][@"tag"] isEqualToString:self.tag]) return;
        self.recordID = rid;
    }
    if (![rid isEqualToString:self.recordID]) return;
    self.lastProgress = [n.userInfo[@"progress"] doubleValue];
    [self.button showProgress:self.lastProgress];
    [self syncSheet];
}

- (void)storeChanged {
    if (self.collecting) return;
    if (!self.recordID) {
        for (NSDictionary *r in [TPDownloadStore records]) if ([r[@"tag"] isEqualToString:self.tag]) { self.recordID = r[@"id"]; break; }
        if (!self.recordID) return;
    }
    NSDictionary *r = [TPDownloadStore recordWithID:self.recordID];
    NSInteger st = r ? [r[@"status"] integerValue] : 4;
    if (st == 0 || st == 1) {
        if (self.button.phase != TPThreadBtnDownloading) [self.button showProgress:self.lastProgress];
        return;
    }
    if (self.button.phase != TPThreadBtnDownloading) return;
    NSInteger saved = 0, failed = 0;
    for (NSDictionary *it in r[@"items"]) {
        NSInteger s = [it[@"state"] integerValue];
        if (s == 2) saved++; else if (s == 3) failed++;
    }
    self.recordID = nil;
    self.lastProgress = 0;
    if (st == 4 || !r) [self.button showIdle];
    else [self.button showDone:saved > 0 saved:saved failed:failed];
    [self syncSheet];
}

- (BOOL)downloading {
    NSInteger st = self.recordID ? [[TPDownloadStore recordWithID:self.recordID][@"status"] integerValue] : -1;
    return self.recordID && (st == 0 || st == 1);
}

- (void)present:(UIAlertController *)a {
    UIViewController *vc = self.vc;
    if (!vc) return;
    self.sheet = a;
    self.sheetPhase = self.button.phase;
    a.popoverPresentationController.barButtonItem = self.item;
    [vc presentViewController:a animated:YES completion:nil];
}

- (void)tapped:(id)sender {
    if (sender && CACurrentMediaTime() - gTPThreadLongPressAt < 2.0) return;
    [TPUI hapticLight];
    if (self.collecting) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:TPL(@"%lu found"), (unsigned long)self.found]
                                                                   message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"Stop and Download Found Items") style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) { self.stopEarly = YES; }]];
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel Download") style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *x) { self.cancelled = YES; }]];
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"Close") style:UIAlertActionStyleCancel handler:nil]];
        [self present:a];
        return;
    }
    if ([self downloading]) {
        NSString *title = [NSString stringWithFormat:@"%@ %.0f%%", TPL(@"Downloading"), floor(self.lastProgress * 100)];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"Download Manager") style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) { [TPDownloadManagerViewController present]; }]];
        NSString *rid = self.recordID;
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel Download") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            if ([[TPDownloader activeRecordIDs] containsObject:rid]) [TPDownloader cancelRecord:rid];
            else [TPDownloader removeQueuedRecord:rid];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"Close") style:UIAlertActionStyleCancel handler:nil]];
        [self present:a];
        return;
    }
    TPDownloadWholeThread(self);
}
@end

static void TPDownloadWholeThread(TPThreadDLHandler *h) {
    UIViewController *vc = h.vc;
    if (!vc || !vc.viewIfLoaded || h.collecting) return;
    UICollectionView *cv = TPFindPrimaryCollectionView(vc.view, 0);
    if (!cv) {
        [TPHUD toast:TPL(@"No media found")];
        return;
    }
    h.collecting = YES;
    h.stopEarly = h.cancelled = NO;
    h.found = 0;
    h.recordID = nil;
    h.lastProgress = 0;
    [h.button showCollecting:0];

    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableDictionary *ctxBox = [NSMutableDictionary dictionary];
    CGPoint start = cv.contentOffset;
    CGFloat top = -cv.adjustedContentInset.top;
    __weak UICollectionView *wcv = cv;
    __weak TPThreadDLHandler *wh = h;

    void (^finish)(void) = ^{
        TPThreadDLHandler *hh = wh;
        hh.collecting = NO;
        UICollectionView *c = wcv;
        if (c) [c setContentOffset:start animated:NO];
        if (!hh || hh.cancelled) { [hh.button showIdle]; [hh syncSheet]; return; }
        if (!items.count) {
            [hh.button showIdle];
            [hh syncSheet];
            [TPHUD toast:TPL(@"No media found")];
            return;
        }
        [hh.button showProgress:0];
        [hh syncSheet];
        NSMutableDictionary *ctx = [NSMutableDictionary dictionaryWithDictionary:ctxBox[@"ctx"] ?: @{ @"kind": @"post" }];
        ctx[@"tag"] = hh.tag;
        ctx[@"quiet"] = @YES;
        [TPHUD toast:[NSString stringWithFormat:TPL(@"Queued %lu media items from thread"), (unsigned long)items.count]];
        [TPDownloader downloadItems:items context:ctx];
    };

    __block NSInteger steps = 0, waits = 0;
    __block CGFloat waitHeight = 0;
    __block void (^step)(void) = nil;
    __block void (^stepRef)(void) = nil;
    step = ^{
        UICollectionView *c = wcv;
        TPThreadDLHandler *hh = wh;
        if (!hh || hh.cancelled || !c || !c.window) { stepRef = nil; finish(); return; }
        TPCollectThreadCells(c, items, seen, ctxBox);
        hh.found = items.count;
        [hh.button showCollecting:items.count];
        [hh syncSheet];
        if (hh.stopEarly) { stepRef = nil; finish(); return; }
        CGFloat page = MAX(200, c.bounds.size.height * 0.8);
        CGFloat bottom = c.contentSize.height + c.adjustedContentInset.bottom - c.bounds.size.height;
        void (^next)(void) = stepRef;
        void (^again)(double) = ^(double delay) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (next) next(); });
        };
        // 150 screens is plenty; very long threads stop there rather than scrolling forever.
        if (++steps > 150) { stepRef = nil; finish(); return; }
        if (c.contentOffset.y >= bottom - 1) {
            // At the bottom of what's loaded: Threads loads replies in batches, so wait for the
            // next batch (up to ~4 s) before calling it the end.
            if (c.contentSize.height > waitHeight + 1 && waitHeight > 0) waits = 0;
            if (waits == 0) waitHeight = c.contentSize.height;
            if (++waits > 10) { stepRef = nil; finish(); return; }
            [c setContentOffset:CGPointMake(c.contentOffset.x, bottom) animated:NO];
            TPNudgeLoadMore(c);
            again(0.4);
            return;
        }
        waits = 0;
        waitHeight = 0;
        [c setContentOffset:CGPointMake(c.contentOffset.x, MIN(bottom, c.contentOffset.y + page)) animated:NO];
        [c layoutIfNeeded];
        TPNudgeLoadMore(c);
        // A short pause lets Threads fill in the new cells (and images) before reading them.
        again(0.25);
    };
    stepRef = step;
    [cv setContentOffset:CGPointMake(cv.contentOffset.x, top) animated:NO];
    [cv layoutIfNeeded];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
}

// Long-press the thread download button: open the download manager directly. A plain image bar
// item has no long-press of its own on iOS 16–27, so one recognizer sits on the navigation bar
// and only starts when the press lands on this button (other buttons are left alone).
static UIView *TPFindViewWithLabel(UIView *v, NSString *label, int depth) {
    if (!v || v.hidden || depth > 14) return nil;
    if ([v.accessibilityLabel isEqualToString:label] && v.bounds.size.width >= 20) return v;
    for (UIView *s in v.subviews) { UIView *f = TPFindViewWithLabel(s, label, depth + 1); if (f) return f; }
    return nil;
}

static UIView *TPThreadItemView(UINavigationBar *bar, UIBarButtonItem *item) {
    if (!bar || !item) return nil;
    UIView *v = nil;
    @try { v = [item valueForKey:@"view"]; } @catch (__unused id e) {}
    if ([v isKindOfClass:[UIView class]] && v.window && v.window == bar.window && !v.hidden) return v;
    return TPFindViewWithLabel(bar, item.accessibilityLabel ?: TPL(@"Download Thread"), 0);
}

@interface TPThreadLongPress : NSObject <UIGestureRecognizerDelegate>
+ (void)installOn:(UINavigationController *)nav;
@end

@implementation TPThreadLongPress
static const void *kTPThreadLPKey = &kTPThreadLPKey;

+ (instancetype)shared { static TPThreadLongPress *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [self new]; }); return s; }

+ (void)installOn:(UINavigationController *)nav {
    UINavigationBar *bar = nav.navigationBar;
    if (!bar || objc_getAssociatedObject(bar, kTPThreadLPKey)) return;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[self shared] action:@selector(pressed:)];
    lp.minimumPressDuration = 0.45;
    lp.delegate = [self shared];
    [bar addGestureRecognizer:lp];
    objc_setAssociatedObject(bar, kTPThreadLPKey, lp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static TPThreadDLHandler *TPHandlerForBar(UINavigationBar *bar) {
    UIViewController *top = nil;
    for (UIResponder *r = bar.nextResponder; r; r = r.nextResponder)
        if ([r isKindOfClass:[UINavigationController class]]) { top = [(UINavigationController *)r topViewController]; break; }
    return top ? objc_getAssociatedObject(top, kTPThreadDLBtnKey) : nil;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    UINavigationBar *bar = (UINavigationBar *)g.view;
    if (![bar isKindOfClass:[UINavigationBar class]]) return NO;
    TPThreadDLHandler *h = TPHandlerForBar(bar);
    UIView *v = TPThreadItemView(bar, h.item);
    if (!v) return NO;
    CGRect r = CGRectInset([v convertRect:v.bounds toView:bar], -4, -4);
    return CGRectContainsPoint(r, [g locationInView:bar]);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return YES; }

- (void)pressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    gTPThreadLongPressAt = CACurrentMediaTime();
    [TPUI hapticLight];
    [TPDownloadManagerViewController present];
}
@end

%group ThreadBatchDownload
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!TPIsThreadDetailVCClass(self.class)) return;
    TPThreadDLHandler *h = objc_getAssociatedObject(self, kTPThreadDLBtnKey);
    if (h) { h.button.suspended = NO; [TPThreadLongPress installOn:self.navigationController]; [TPCapsule setHostedTag:h.tag hosted:YES]; return; }
    if (![TPPrefs boolForKey:TPKeyShowDownloadBtn] || ![TPPrefs boolForKey:TPKeyThreadDownloadBtn]) return;
    if (!self.navigationController || !self.navigationItem) return;

    h = [TPThreadDLHandler new];
    h.vc = self;
    h.button = [TPThreadStatusView new];
    __weak TPThreadDLHandler *wh = h;
    h.button.onTap = ^{ [wh tapped:nil]; };
    [h.button attachTo:self];
    objc_setAssociatedObject(self, kTPThreadDLBtnKey, h, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // A plain image item, like the bell and "⋯": the system sizes and spaces it.
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:TPThreadIdleImage() style:UIBarButtonItemStylePlain
                                                            target:h action:@selector(tapped:)];
    item.accessibilityLabel = TPL(@"Download Thread");
    h.item = item;
    NSMutableArray<UIBarButtonItem *> *right = [NSMutableArray arrayWithArray:self.navigationItem.rightBarButtonItems ?: @[]];
    [right addObject:item];
    self.navigationItem.rightBarButtonItems = right;
    [TPThreadLongPress installOn:self.navigationController];
    __weak UIViewController *wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *vc = wself;
        UIView *v = vc ? TPThreadItemView(vc.navigationController.navigationBar, item) : nil;
        if (v) TPShowTipOnce(@"thread_btn", v, TPL(@"Tap to download the whole thread. Long-press for the download manager"));
    });
    // While this page is open its button shows the progress, so the download pill stays hidden.
    [TPCapsule setHostedTag:h.tag hosted:YES];
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    TPThreadDLHandler *h = objc_getAssociatedObject(self, kTPThreadDLBtnKey);
    if (!h) return;
    h.button.suspended = YES;
    [TPCapsule setHostedTag:h.tag hosted:NO];
}
%end
%end


// =============================================================================
// Long-Press Post Text Menu: Selectable Text, Quick Translate, Copy, Quick Mute
// =============================================================================

@interface TPSelectableTextViewController : UIViewController
@property (nonatomic, copy) NSString *postText;
@end

@implementation TPSelectableTextViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = TPL(@"Select Text");
    self.view.backgroundColor = [TPUI pageColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                          target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:TPL(@"Copy All")
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self action:@selector(copyAll)];
    UITextView *tv = [UITextView new];
    tv.text = _postText ?: @"";
    tv.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    tv.textColor = UIColor.labelColor;
    tv.backgroundColor = UIColor.clearColor;
    tv.editable = NO;
    tv.selectable = YES;
    tv.textContainerInset = UIEdgeInsetsMake(16, 16, 24, 16);
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)copyAll {
    if (_postText.length) {
        UIPasteboard.generalPasteboard.string = _postText;
        [TPUI hapticLight];
        [TPHUD toast:TPL(@"Copied")];
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

static void TPAppendMutedRule(NSString *rule) {
    NSString *t = [rule stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!t.length) return;
    NSMutableArray<NSString *> *list = [[TPPrefs mutedRules] mutableCopy];
    if (![list containsObject:t]) {
        [list insertObject:t atIndex:0];
        [TPPrefs setMutedRules:list];
    }
}

static NSString *TPExtractPostTextFromView(UIView *v, int depth) {
    if (!v || depth > 6 || v.hidden) return nil;
    if ([v respondsToSelector:@selector(styledString)]) {
        id styled = nil;
        @try { styled = [v valueForKey:@"styledString"]; } @catch (__unused id e) {}
        id as = [styled respondsToSelector:@selector(attributedString)] ? [styled valueForKey:@"attributedString"] : nil;
        if ([as isKindOfClass:[NSAttributedString class]]) {
            NSString *s = [[(NSAttributedString *)as string] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (s.length >= 2) return s;
        }
    }
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *s = [[(UILabel *)v text] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (s.length >= 2) return s;
    } else if ([v isKindOfClass:[UITextView class]]) {
        NSString *s = [[(UITextView *)v text] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (s.length >= 2) return s;
    }
    NSString *best = nil;
    for (UIView *sub in v.subviews) {
        NSString *cand = TPExtractPostTextFromView(sub, depth + 1);
        if (cand.length > best.length) best = cand;
    }
    return best;
}

// The post's text, read from the text cells in the same post (section) as `cellRoot`, top to
// bottom. Media cells don't hold the caption; Threads draws it in its own BCNFeedTextCell.
static NSString *TPPostTextForCell(UIView *cellRoot) {
    Class textCls = objc_getClass("_TtC15BCNFeedTextCell15BCNFeedTextCell");
    if (!textCls) return nil;
    UICollectionViewCell *cur = nil;
    for (UIView *v = cellRoot; v; v = v.superview) {
        if ([v isKindOfClass:[UICollectionViewCell class]]) { cur = (UICollectionViewCell *)v; continue; }
        if (![v isKindOfClass:[UICollectionView class]] || !cur) continue;
        UICollectionView *cv = (UICollectionView *)v;
        NSIndexPath *ip = [cv indexPathForCell:cur];
        if (!ip) continue;
        NSMutableArray<UICollectionViewCell *> *texts = [NSMutableArray array];
        for (UICollectionViewCell *c in cv.visibleCells) {
            if (![c isKindOfClass:textCls]) continue;
            NSIndexPath *cip = [cv indexPathForCell:c];
            if (cip && cip.section == ip.section) [texts addObject:c];
        }
        if (!texts.count) continue;   // a carousel inside the post: try the feed around it
        [texts sortUsingComparator:^NSComparisonResult(UICollectionViewCell *x, UICollectionViewCell *y) {
            NSInteger a = [cv indexPathForCell:x].item, b = [cv indexPathForCell:y].item;
            return a < b ? NSOrderedAscending : (a > b ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (UICollectionViewCell *c in texts) {
            NSString *t = TPExtractPostTextFromView(c, 0);
            if (t.length) [parts addObject:t];
        }
        return parts.count ? [parts componentsJoinedByString:@"\n"] : nil;
    }
    return nil;
}

// "Post Text" in the post download button's menu, or a long-press on Threads' own "⋯" in
// the post header (text-only posts have no download button): select, translate, copy, or mute.
// It lives in our own menu instead of a long-press on the text, which Threads already uses for
// its own text selection and highlights.
static void TPShowPostTextActions(UIView *cell, NSString *author, UIView *anchor) {
    // From a download button inside a quoted post: that quoted post's text and author.
    UIView *nested = anchor ? TPNestedPostAncestor(anchor) : nil;
    NSDictionary *quoted = TPNestedPostInfo(nested);
    NSString *text = nested ? (quoted[@"text"] ?: TPExtractPostTextFromView(nested, 0)) : TPPostTextForCell(cell);
    if (nested && [quoted[@"author"] length]) author = quoted[@"author"];
    if (!text.length) { [TPHUD toast:TPL(@"This post has no text")]; return; }
    UIViewController *top = TPTopViewController();
    if (!top) return;
    if (!author.length) author = TPPostContextForCell(cell)[@"author"];
    [TPUI hapticLight];
    NSString *preview = text.length > 60 ? [[text substringToIndex:60] stringByAppendingString:@"…"] : text;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:preview message:nil preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:TPL(@"Select Text") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        TPSelectableTextViewController *vc = [TPSelectableTextViewController new];
        vc.postText = text;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [top presentViewController:nav animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:TPL(@"Quick Translate") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *lang = NSLocale.preferredLanguages.firstObject ?: @"zh-TW";
        NSString *tl = [lang hasPrefix:@"zh-Hans"] ? @"zh-CN" : ([lang hasPrefix:@"zh"] ? @"zh-TW" : ([lang hasPrefix:@"ja"] ? @"ja" : ([lang hasPrefix:@"ko"] ? @"ko" : ([lang hasPrefix:@"vi"] ? @"vi" : @"en"))));
        NSURLComponents *comps = [NSURLComponents componentsWithString:@"https://translate.google.com/"];
        comps.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"sl" value:@"auto"],
            [NSURLQueryItem queryItemWithName:@"tl" value:tl],
            [NSURLQueryItem queryItemWithName:@"text" value:text],
            [NSURLQueryItem queryItemWithName:@"op" value:@"translate"],
        ];
        if (comps.URL) {
            SFSafariViewController *sf = [[SFSafariViewController alloc] initWithURL:comps.URL];
            [top presentViewController:sf animated:YES completion:nil];
        }
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:TPL(@"Copy Text") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = text;
        [TPUI hapticLight];
        [TPHUD toast:TPL(@"Copied")];
    }]];

    if (author.length) {
        NSString *atAuthor = [@"@" stringByAppendingString:author];
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:TPL(@"Mute %@"), atAuthor]
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *a) {
            TPAppendMutedRule(atAuthor);
            [TPUI hapticLight];
            [TPHUD toast:[NSString stringWithFormat:TPL(@"Muted %@"), atAuthor]];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:TPL(@"Mute Keyword…") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:TPL(@"Add Muted Rule")
                                                                    message:TPL(@"Enter a keyword from this post to mute:")
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = TPL(@"Keyword or /regex/");
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [al addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
        [al addAction:[UIAlertAction actionWithTitle:TPL(@"Add") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act) {
            NSString *kw = al.textFields.firstObject.text;
            if (kw.length) {
                TPAppendMutedRule(kw);
                [TPUI hapticLight];
                [TPHUD toast:TPL(@"Muted keywords saved")];
            }
        }]];
        [top presentViewController:al animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    // Anchor the menu on the small control it came from (the download button or "⋯"). Anchored
    // on a whole tall media row, iOS squeezes it into the little space left above or below.
    UIView *src = anchor.window ? anchor : cell;
    sheet.popoverPresentationController.sourceView = src;
    sheet.popoverPresentationController.sourceRect = src.bounds;
    [top presentViewController:sheet animated:YES completion:nil];
}



// Long-press the "⋯" at the right of a post header: the post text actions. A tap still opens
// Threads' own menu. The button is found on screen (the rightmost small tap button in the
// header), not through Swift storage, so it works across Threads versions.
static const void *kTPMoreLPKey = &kTPMoreLPKey;

@interface TPMoreButtonPress : NSObject
+ (instancetype)shared;
@end

@implementation TPMoreButtonPress
+ (instancetype)shared { static TPMoreButtonPress *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [self new]; }); return s; }
- (void)pressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIView *header = g.view;
    while (header && ![header isKindOfClass:TPFeedHeaderClass()]) header = header.superview;
    if (!header) return;
    TPShowPostTextActions(header, [TPAuthorInfo postInfoInHeader:header][@"author"], g.view);
}
@end

static UIView *TPHeaderMoreButton(UIView *header) {
    Class tapCls = objc_getClass("IGTapButton");
    if (!tapCls) return nil;
    NSMutableArray<UIView *> *found = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:header];
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        for (UIView *sv in v.subviews) {
            if (sv.hidden || sv.alpha < 0.05) continue;
            if ([sv isKindOfClass:tapCls]) { [found addObject:sv]; continue; }
            [stack addObject:sv];
        }
    }
    UIView *best = nil;
    CGFloat bestX = -CGFLOAT_MAX;
    for (UIView *b in found) {
        CGRect f = [b convertRect:b.bounds toView:header];
        if (f.size.width < 10 || f.size.width > 60 || f.size.height > 60) continue;
        // Only the far right of the header: the "⋯" sits there, the name and badges don't.
        if (CGRectGetMaxX(f) < header.bounds.size.width * 0.75) continue;
        if (CGRectGetMaxX(f) > bestX) { bestX = CGRectGetMaxX(f); best = b; }
    }
    return best;
}

%group PostMoreLongPress
%hook _TtC21BCNFeedItemHeaderCell32BCNFeedItemHeaderCellContentView
- (void)layoutSubviews {
    %orig;
    UIView *header = (UIView *)self;
    // Headers lay out often while scrolling: once this header's "⋯" has the gesture, skip the search.
    UIView *known = ((TPWeakBox *)objc_getAssociatedObject(header, kTPMoreLPKey)).object;
    if (known && [known isDescendantOfView:header] && objc_getAssociatedObject(known, kTPMoreLPKey)) return;
    UIView *more = TPHeaderMoreButton(header);
    if (!more) return;
    TPWeakBox *box = [TPWeakBox new];
    box.object = more;
    objc_setAssociatedObject(header, kTPMoreLPKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TPOfferTip(@"more_btn", more, @"Long-press “⋯” to select, translate, copy or mute the post text", 1.5);
    if (objc_getAssociatedObject(more, kTPMoreLPKey)) return;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[TPMoreButtonPress shared] action:@selector(pressed:)];
    lp.minimumPressDuration = 0.45;
    [more addGestureRecognizer:lp];
    objc_setAssociatedObject(more, kTPMoreLPKey, lp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end
%end

%ctor {
    @autoreleasepool {
        // Before Threads opens any cached files.
        [TPSettingsViewController runPendingCacheClear];
        TPSideloadFixInstall();
        for (NSString *old in @[@"tp_last_logout", @"tp_logout_history", @"tp_logout_keychain", @"tp_swipe_lock_speed", @"tp_video_gestures", @"tp_parallel_download", @"tp_hide_reposts", @"tp_name_country", @"tp_new_settings_ui", @"tp_new_badges_1_32", @"tp_new_seen_1_32"])
            [[TPPrefs defaults] removeObjectForKey:old];
        // Post Time Format used to be 4 fixed options; it is now made of parts.
        [TPPrefs migrateExactTime];
        %init(Ads);
        %init(Tracking);
        %init(Download);
        %init(Images);
        %init(VideoSettings);
        %init(Time);
        %init(Interactions);
        gTPProfileHeaderClass = objc_getClass("_TtC10BCNProfile20BCNProfileHeaderView");
        %init(Avatar);
        %init(AccountSwitch);
        %init(ClipboardReady);
        %init(KeepFeed);
        gTPMainFeedClass = objc_getClass("_TtC11BCNMainFeed25BCNMainFeedViewController");
        %init(HomeFeedControls);
        gTPUserRecsClass = objc_getClass("_TtC22BCNUserRecommendations36BCNUserRecommendationsViewController");
        gTPRecAccountsClass = objc_getClass("_TtC22BCNRecommendedAccounts36BCNRecommendedAccountsViewController");
        gTPPrefollowClass = objc_getClass("_TtC15BCNPrefollowing29BCNPrefollowingViewController");
        gTPPrefollowListClass = objc_getClass("_TtC15BCNPrefollowing33BCNPrefollowingListViewController");
        gTPFollowListPrefollowClass = objc_getClass("_TtC13BCNFollowList36BCNFollowListPrefollowViewController");
        %init(HideFollowSuggest);
        %init(PinTabBar);
        %init(HideFeedSuggestions);
        %init(BlockScreenshotDetection);
        %init(BlockAnalytics);
        TPInstallAnalyticsUploadBlock();
        %init(ExternalBrowser);
        %init(HideIGButton);
        %init(HomeLongPress);
        TPInstallMuteRefreshSound();
        %init(NoSeen);
        %init(KeepUnsent);
        %init(NoTyping);
        %init(Menu);
        %init(AuthorInfo);
        %init(ThreadBatchDownload);
        %init(PostMoreLongPress);
        TPAuthorOpenProfile = ^(NSString *username) {
            NSURL *u = [NSURL URLWithString:[@"https://www.threads.com/@" stringByAppendingString:username]];
            if (u) TPOpenInThreads(u);
        };
        // Threads only routes post links shaped like /@author/post/CODE; a bogus placeholder handle
        // like "@threads" is ignored. When author is missing, resolve it first, then open; if
        // code is missing but author is known, open the author's profile.
        TPDownloadOpenPost = ^(NSString *code, NSString *author) {
            if (code.length && author.length) {
                NSString *path = [NSString stringWithFormat:@"@%@/post/%@", author, code];
                NSURL *u = [NSURL URLWithString:[@"https://www.threads.com/" stringByAppendingString:path]];
                if (u) TPOpenInThreads(u);
                return;
            }
            if (code.length) {
                NSURL *fallback = [NSURL URLWithString:[@"https://www.threads.com/t/" stringByAppendingString:code]];
                if (fallback) TPOpenInThreads(fallback);
                return;
            }
            if (author.length) {
                NSURL *u = [NSURL URLWithString:[@"https://www.threads.com/@" stringByAppendingString:author]];
                if (u) TPOpenInThreads(u);
            }
        };

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) {
            gTPBackgroundedAt = CFAbsoluteTimeGetCurrent();
            gTPWentBackground = YES;
            [[TPPrefs defaults] setObject:TPSideloadFixStats() forKey:@"tp_sf_last_stats"];
            [[TPPrefs defaults] setInteger:gTPAnalyticsDropped forKey:@"tp_analytics_last_dropped"];
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillShowNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) {
            gTPKeyboardVisible = YES;
            UIViewController *root = UIApplication.sharedApplication.keyWindow.rootViewController;
            if (root.presentedViewController) gTPSheetKeyboardAt = CFAbsoluteTimeGetCurrent();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillHideNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) { gTPKeyboardVisible = NO; }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) {
            // Coming back from another app the UI is already there, so check almost at once
            // (shorter still for Auto-open). On a cold launch, wait for Threads to build its UI first.
            static BOOL launched;
            BOOL cold = !launched;
            launched = YES;
            if (cold) { TPCheckClipboardWhenHomeReady(NO, NO, 3.0); return; }
            // Face ID (e.g. for password AutoFill on the login screen), Control Center and
            // system alerts also make the app inactive and active again without leaving it. Only
            // coming back from another app counts.
            if (!gTPWentBackground) return;
            gTPWentBackground = NO;
            BOOL autoOpen = [TPPrefs integerForKey:TPKeyClipboardMode] == 1;
            double delay = autoOpen ? 0.15 : 0.35;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                TPCheckClipboard();
            });
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                NSString *last = [[TPPrefs defaults] stringForKey:@"tp_sf_last_stats"];
                NSString *msg = [NSString stringWithFormat:@"%@: %@", TPL(@"Sideload Compatibility Fix"), TPSideloadFixStatus()];
                if (last.length) msg = [msg stringByAppendingFormat:@"\n%@: %@", TPL(@"Last session"), last];
                if ([TPPrefs boolForKey:TPKeyBlockAnalytics])
                    msg = [msg stringByAppendingFormat:@"\n%@: %ld", TPL(@"Analytics blocked last session"),
                           (long)[[TPPrefs defaults] integerForKey:@"tp_analytics_last_dropped"]];
                if ([TPPrefs boolForKey:TPKeyDebugToast]) [TPHUD toast:[@"[TP] " stringByAppendingString:msg]];
            });
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) {
            [TPWelcomeViewController presentIfNeeded];
            // After the welcome / What's New screen has had its turn.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [TPUpdateChecker checkAutomatically];
            });
        }];
    }
}
