#import "TPDownloadManager.h"
#import "TPDownloader.h"
#import "TPLocalization.h"
#import "TPPrefs.h"
#import "TPHUD.h"
#import "TPUI.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>
#import <QuickLook/QuickLook.h>

NSString *const TPDownloadStoreDidChangeNotification = @"TPDownloadStoreDidChangeNotification";
NSString *const TPDownloadProgressNotification = @"TPDownloadProgressNotification";
void (^TPDownloadOpenPost)(NSString *code, NSString *author);

static const NSInteger kTPMaxRecords = 500;

#pragma mark - Store

static NSMutableArray<NSMutableDictionary *> *sRecords;   // oldest first
static BOOL sSaveScheduled, sNotifyScheduled;
static NSCache<NSString *, UIImage *> *sThumbs;

static NSString *TPDMDir(NSString *sub) {
    static NSString *base;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *as = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        base = [as stringByAppendingPathComponent:@"ThreadsPulse/Downloads"];
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *d in @[@"Files", @"Thumbs"])
            [fm createDirectoryAtPath:[base stringByAppendingPathComponent:d] withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *files = [NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"Files"]];
        [files setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    });
    return sub ? [base stringByAppendingPathComponent:sub] : base;
}

static dispatch_queue_t TPDMQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("tp.downloads", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static void TPDMNotify(void) {
    if (sNotifyScheduled) return;
    sNotifyScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        sNotifyScheduled = NO;
        [NSNotificationCenter.defaultCenter postNotificationName:TPDownloadStoreDidChangeNotification object:nil];
    });
}

static void TPDMSave(void) {
    TPDMNotify();
    if (sSaveScheduled) return;
    sSaveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        sSaveScheduled = NO;
        NSData *d = [NSPropertyListSerialization dataWithPropertyList:sRecords ?: @[] format:NSPropertyListBinaryFormat_v1_0
                                                              options:0 error:nil];
        NSString *path = [TPDMDir(nil) stringByAppendingPathComponent:@"history.plist"];
        dispatch_async(TPDMQueue(), ^{ [d writeToFile:path atomically:YES]; });
    });
}

static NSString *TPDMFilePath(NSString *name) { return name.length ? [TPDMDir(@"Files") stringByAppendingPathComponent:name] : nil; }
static NSString *TPDMThumbPath(NSString *name) { return name.length ? [TPDMDir(@"Thumbs") stringByAppendingPathComponent:name] : nil; }

static void TPDMResolveAuthor(NSString *rid, NSString *code);
static BOOL TPDMTrim(void);

static void TPDMLoad(void) {
    if (sRecords) return;
    sRecords = [NSMutableArray array];
    sThumbs = [NSCache new];
    NSData *d = [NSData dataWithContentsOfFile:[TPDMDir(nil) stringByAppendingPathComponent:@"history.plist"]];
    NSArray *list = d ? [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListMutableContainers format:NULL error:nil] : nil;
    if (![list isKindOfClass:[NSArray class]]) return;
    BOOL changed = NO;
    for (NSMutableDictionary *r in list) {
        if (![r isKindOfClass:[NSMutableDictionary class]] || ![r[@"id"] length]) continue;
        // A download that was still queued or running when Threads closed: whatever didn't finish failed.
        NSInteger st = [r[@"status"] integerValue];
        if (st == 0 || st == 1) {
            r[@"status"] = @2;
            for (NSMutableDictionary *it in r[@"items"]) if ([it[@"state"] integerValue] == 0) it[@"state"] = @3;
            changed = YES;
        }
        [sRecords addObject:r];
    }
    if (TPDMTrim()) changed = YES;
    if (changed) TPDMSave();
    static dispatch_once_t trimObsOnce;
    dispatch_once(&trimObsOnce, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:TPPrefsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if ([n.userInfo[@"key"] isEqualToString:TPKeyDownloadHistoryLimit]) {
                if (TPDMTrim()) TPDMSave();
            }
        }];
    });
    // Records saved before their author was known: look up the newest few once.
    NSInteger lookups = 0;
    for (NSMutableDictionary *r in sRecords.reverseObjectEnumerator) {
        if (lookups >= 30) break;
        if (![r[@"code"] length] || [r[@"author"] length] || [r[@"authorTried"] boolValue]) continue;
        TPDMResolveAuthor(r[@"id"], r[@"code"]);
        lookups++;
    }
}

static NSMutableDictionary *TPDMRecord(NSString *rid) {
    TPDMLoad();
    if (!rid.length) return nil;
    for (NSMutableDictionary *r in sRecords.reverseObjectEnumerator) if ([r[@"id"] isEqualToString:rid]) return r;
    return nil;
}

static NSMutableDictionary *TPDMItem(NSString *rid, NSInteger index) {
    NSArray *items = TPDMRecord(rid)[@"items"];
    return index >= 0 && index < (NSInteger)items.count ? items[index] : nil;
}

static void TPDMDeleteFilesOfItem(NSMutableDictionary *it) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([it[@"file"] length]) [fm removeItemAtPath:TPDMFilePath(it[@"file"]) error:nil];
    if ([it[@"thumb"] length]) { [fm removeItemAtPath:TPDMThumbPath(it[@"thumb"]) error:nil]; [sThumbs removeObjectForKey:it[@"thumb"]]; }
    [it removeObjectForKey:@"file"];
    [it removeObjectForKey:@"thumb"];
}

// Plist-safe copy of an item: links become strings, runtime-only values are dropped.
static NSMutableDictionary *TPDMStoredItem(NSDictionary *d) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    m[@"video"] = @([d[@"video"] boolValue]);
    NSMutableArray *urls = [NSMutableArray array];
    for (id u in d[@"urls"]) if ([u isKindOfClass:[NSURL class]]) [urls addObject:[(NSURL *)u absoluteString]];
    m[@"urls"] = urls;
    for (NSString *k in @[@"dashVideo", @"dashAudio"]) if ([d[k] isKindOfClass:[NSURL class]]) m[k] = [d[k] absoluteString];
    for (NSString *k in @[@"key", @"dashCodec", @"dashAudioCodec", @"dashLabel", @"dashSize"])
        if ([d[k] isKindOfClass:[NSString class]]) m[k] = d[k];
    if ([d[@"dashTranscode"] boolValue]) m[@"dashTranscode"] = @YES;
    m[@"state"] = @0;
    return m;
}

static NSDictionary *TPDMLiveItem(NSDictionary *s, NSString *rid, NSInteger index) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    m[@"video"] = @([s[@"video"] boolValue]);
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *u in s[@"urls"]) { NSURL *x = [NSURL URLWithString:u]; if (x) [urls addObject:x]; }
    m[@"urls"] = urls;
    for (NSString *k in @[@"dashVideo", @"dashAudio"]) { NSURL *x = [s[k] length] ? [NSURL URLWithString:s[k]] : nil; if (x) m[k] = x; }
    for (NSString *k in @[@"key", @"dashCodec", @"dashAudioCodec", @"dashLabel", @"dashSize", @"dashTranscode"]) if (s[k]) m[k] = s[k];
    m[@"tp_record"] = rid;
    m[@"tp_index"] = @(index);
    return m;
}

static BOOL TPDMTrim(void) {
    BOOL removed = NO;
    NSInteger mode = [TPPrefs integerForKey:TPKeyDownloadHistoryLimit];
    NSInteger maxCount = kTPMaxRecords;
    NSTimeInterval maxAge = 0;
    if (mode == 1) maxCount = 50;
    else if (mode == 2) maxCount = 100;
    else if (mode == 3) maxAge = 30.0 * 86400.0;

    if (maxAge > 0) {
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-maxAge];
        NSMutableIndexSet *toRemove = [NSMutableIndexSet indexSet];
        [sRecords enumerateObjectsUsingBlock:^(NSMutableDictionary *rec, NSUInteger idx, BOOL *stop) {
            NSInteger st = [rec[@"status"] integerValue];
            if (st == 0 || st == 1) return;
            NSDate *dt = rec[@"date"];
            if ([dt isKindOfClass:[NSDate class]] && [dt compare:cutoff] == NSOrderedAscending) {
                for (NSMutableDictionary *it in rec[@"items"]) TPDMDeleteFilesOfItem(it);
                [toRemove addIndex:idx];
            }
        }];
        if (toRemove.count) {
            [sRecords removeObjectsAtIndexes:toRemove];
            removed = YES;
        }
    }

    while ((NSInteger)sRecords.count > maxCount) {
        NSMutableDictionary *old = sRecords.firstObject;
        NSInteger st = [old[@"status"] integerValue];
        if (st == 0 || st == 1) break;
        for (NSMutableDictionary *it in old[@"items"]) TPDMDeleteFilesOfItem(it);
        [sRecords removeObjectAtIndex:0];
        removed = YES;
    }
    return removed;
}

static UIImage *TPDMMakeThumb(NSString *path, BOOL video) {
    if (!path) return nil;
    if (video) {
        AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        AVAssetImageGenerator *g = [AVAssetImageGenerator assetImageGeneratorWithAsset:a];
        g.appliesPreferredTrackTransform = YES;
        g.maximumSize = CGSizeMake(320, 320);
        CGImageRef cg = [g copyCGImageAtTime:CMTimeMakeWithSeconds(0.2, 600) actualTime:NULL error:nil];
        if (!cg) cg = [g copyCGImageAtTime:kCMTimeZero actualTime:NULL error:nil];
        if (!cg) return nil;
        UIImage *img = [UIImage imageWithCGImage:cg];
        CGImageRelease(cg);
        return img;
    }
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!src) return nil;
    NSDictionary *opt = @{ (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                           (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                           (id)kCGImageSourceThumbnailMaxPixelSize: @320 };
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opt);
    CFRelease(src);
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return img;
}

// When the app didn't give the author, the post's web page does: its address and links read
// threads.com/@author/post/CODE.
static BOOL TPDMIsValidAuthorHandle(NSString *handle) {
    if (!handle.length || handle.length > 30) return NO;
    NSString *low = handle.lowercaseString;
    if ([low isEqualToString:@"threads"] || [low isEqualToString:@"t"] || [low isEqualToString:@"share"]) return NO;
    return YES;
}

static NSString *TPDMExtractAuthorFromResponse(NSString *code, NSString *finalURL, NSString *html) {
    NSString *c = [NSRegularExpression escapedPatternForString:code];
    NSArray<NSString *> *patterns = @[
        [NSString stringWithFormat:@"\\\\?/@([A-Za-z0-9._]{1,30})\\\\?/post\\\\?/%@", c],
        [NSString stringWithFormat:@"%%40([A-Za-z0-9._]{1,30})%%2Fpost%%2F%@", c],
        @"property=\"og:url\"[^>]*content=\"[^\"]*/@([A-Za-z0-9._]{1,30})/post/",
        @"rel=\"canonical\"[^>]*href=\"[^\"]*/@([A-Za-z0-9._]{1,30})/post/",
        @"og:title\"[^>]*content=\"[^\"]*\\((?:@|&#064;|&#x40;)([A-Za-z0-9._]{1,30})\\)",
        @"<title>[^<]*\\((?:@|&#064;|&#x40;)([A-Za-z0-9._]{1,30})\\)",
        [NSString stringWithFormat:@"\"code\"\\s*:\\s*\"%@\"[\\s\\S]{0,1200}?\"username\"\\s*:\\s*\"([A-Za-z0-9._]{1,30})\"", c],
        [NSString stringWithFormat:@"\"username\"\\s*:\\s*\"([A-Za-z0-9._]{1,30})\"[\\s\\S]{0,1200}?\"code\"\\s*:\\s*\"%@\"", c],
    ];
    NSArray<NSString *> *sources = @[finalURL ?: @"", html ?: @""];
    for (NSString *pattern in patterns) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        if (!re) continue;
        for (NSString *text in sources) {
            if (!text.length) continue;
            NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
            if (m && m.numberOfRanges > 1) {
                NSString *cand = [text substringWithRange:[m rangeAtIndex:1]];
                if (TPDMIsValidAuthorHandle(cand)) return cand;
            }
        }
    }
    return nil;
}

static void TPDMFetchAuthorFromURLs(NSArray<NSURL *> *urls, NSUInteger idx, NSString *code, void (^completion)(NSString *author, BOOL gotHTTPResponse)) {
    if (idx >= urls.count) {
        if (completion) completion(nil, NO);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:urls[idx]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:10];
    // Alternate Mobile Safari and Desktop UA across attempts to bypass login walls.
    if (idx == 0) {
        [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            forHTTPHeaderField:@"User-Agent"];
    } else {
        [req setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
            forHTTPHeaderField:@"User-Agent"];
    }
    [req setValue:@"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
    [req setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"Accept-Language"];

    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *html = data ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"") : @"";
        NSString *author = TPDMExtractAuthorFromResponse(code, resp.URL.absoluteString, html);
        BOOL gotHTTP = [resp isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)resp).statusCode >= 200;
        [session finishTasksAndInvalidate];
        if (author.length) {
            if (completion) completion(author, YES);
            return;
        }
        if (idx + 1 < urls.count) {
            TPDMFetchAuthorFromURLs(urls, idx + 1, code, completion);
        } else {
            if (completion) completion(nil, gotHTTP);
        }
    }] resume];
}

static void TPDMResolveAuthorWithCompletion(NSString *rid, NSString *code, void (^completion)(NSString *author)) {
    if (!code.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSURL *u1 = [NSURL URLWithString:[@"https://www.threads.com/t/" stringByAppendingString:code]];
    NSURL *u2 = [NSURL URLWithString:[@"https://www.threads.net/t/" stringByAppendingString:code]];
    if (u1) [urls addObject:u1];
    if (u2) [urls addObject:u2];
    if (!urls.count) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    TPDMFetchAuthorFromURLs(urls, 0, code, ^(NSString *author, BOOL gotHTTPResponse) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (rid.length) {
                NSMutableDictionary *r = TPDMRecord(rid);
                if (r) {
                    BOOL changed = NO;
                    if (author.length && ![r[@"author"] length]) {
                        r[@"author"] = author;
                        changed = YES;
                    }
                    if (gotHTTPResponse && ![r[@"authorTried"] boolValue]) {
                        r[@"authorTried"] = @YES;
                        changed = YES;
                    }
                    if (changed) TPDMSave();
                }
            }
            if (completion) completion(author);
        });
    });
}

static void TPDMResolveAuthor(NSString *rid, NSString *code) {
    TPDMResolveAuthorWithCompletion(rid, code, nil);
}

@implementation TPDownloadStore

+ (NSArray<NSDictionary *> *)addRecordForItems:(NSArray<NSDictionary *> *)items context:(NSDictionary *)context {
    TPDMLoad();
    NSString *rid = NSUUID.UUID.UUIDString;
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    r[@"id"] = rid;
    r[@"date"] = NSDate.date;
    r[@"status"] = @0;
    for (NSString *k in @[@"code", @"author", @"kind", @"tag"]) if ([context[k] isKindOfClass:[NSString class]] && [context[k] length]) r[k] = context[k];
    NSMutableArray *stored = [NSMutableArray array];
    NSMutableArray *live = [NSMutableArray array];
    [items enumerateObjectsUsingBlock:^(NSDictionary *d, NSUInteger i, BOOL *stop) {
        [stored addObject:TPDMStoredItem(d)];
        NSMutableDictionary *m = [d mutableCopy];
        m[@"tp_record"] = rid;
        m[@"tp_index"] = @(i);
        [live addObject:m];
    }];
    r[@"items"] = stored;
    [sRecords addObject:r];
    TPDMTrim();
    TPDMSave();
    if ([r[@"code"] length] && ![r[@"author"] length]) TPDMResolveAuthor(rid, r[@"code"]);
    return live;
}

+ (NSArray<NSDictionary *> *)retryItemsForRecord:(NSString *)rid failedOnly:(BOOL)failedOnly {
    NSMutableDictionary *r = TPDMRecord(rid);
    NSInteger st = [r[@"status"] integerValue];
    if (!r || st == 0 || st == 1) return nil;
    NSMutableArray *live = [NSMutableArray array];
    NSArray *items = r[@"items"];
    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
        NSMutableDictionary *it = items[i];
        if (failedOnly && [it[@"state"] integerValue] == 2) continue;
        if (!failedOnly) TPDMDeleteFilesOfItem(it);
        it[@"state"] = @0;
        [live addObject:TPDMLiveItem(it, rid, i)];
    }
    if (!live.count) return nil;
    r[@"status"] = @0;
    r[@"retried"] = @YES;
    // Retried downloads move to the top of the history.
    r[@"date"] = NSDate.date;
    [sRecords removeObject:r];
    [sRecords addObject:r];
    TPDMSave();
    return live;
}

+ (void)setRecord:(NSString *)rid status:(NSInteger)status {
    NSMutableDictionary *r = TPDMRecord(rid);
    if (!r) return;
    // A cancelled retry goes back to the failed list.
    if (status == 4 && [r[@"retried"] boolValue]) status = 2;
    if (status == 2) {
        for (NSMutableDictionary *it in r[@"items"]) if ([it[@"state"] integerValue] == 0) it[@"state"] = @3;
    } else if (status == 4) {
        // A cancelled download that saved nothing leaves no record.
        BOOL any = NO;
        for (NSDictionary *it in r[@"items"]) if ([it[@"state"] integerValue] == 2) { any = YES; break; }
        if (!any) { [self removeRecord:rid]; return; }
    }
    r[@"status"] = @(status);
    TPDMSave();
}

+ (void)setRecord:(NSString *)rid item:(NSInteger)index saved:(BOOL)saved {
    NSMutableDictionary *it = TPDMItem(rid, index);
    if (!it) return;
    it[@"state"] = saved ? @2 : @3;
    if (!saved && [it[@"file"] length]) {
        [NSFileManager.defaultManager removeItemAtPath:TPDMFilePath(it[@"file"]) error:nil];
        [it removeObjectForKey:@"file"];
    }
    TPDMSave();
}

// Thumbnail always; a copy in Files only with Keep Copies on. The staged file is a hard link (or
// a copy), so the caller can go on and delete its own file right away.
+ (void)processStaged:(NSString *)staged record:(NSString *)rid item:(NSInteger)index ext:(NSString *)ext {
    BOOL keep = [TPPrefs boolForKey:TPKeyKeepDownloadCopies];
    BOOL video = [TPDMItem(rid, index)[@"video"] boolValue];
    NSString *base = [NSString stringWithFormat:@"%@_%ld", rid, (long)index];
    dispatch_async(TPDMQueue(), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        UIImage *thumb = TPDMMakeThumb(staged, video);
        double duration = 0;
        if (video) {
            CMTime t = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:staged] options:nil].duration;
            if (CMTIME_IS_NUMERIC(t)) duration = CMTimeGetSeconds(t);
        }
        NSData *jpeg = thumb ? UIImageJPEGRepresentation(thumb, 0.8) : nil;
        NSString *thumbName = jpeg ? [base stringByAppendingPathExtension:@"jpg"] : nil;
        if (jpeg) [jpeg writeToFile:TPDMThumbPath(thumbName) atomically:YES];
        NSString *fileName = nil;
        if (keep) {
            fileName = [base stringByAppendingPathExtension:ext.length ? ext : (video ? @"mp4" : @"jpg")];
            [fm removeItemAtPath:TPDMFilePath(fileName) error:nil];
            if (![fm moveItemAtPath:staged toPath:TPDMFilePath(fileName) error:nil]) fileName = nil;
        }
        if (!fileName) [fm removeItemAtPath:staged error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableDictionary *it = TPDMItem(rid, index);
            if (!it || [it[@"state"] integerValue] == 3) {
                if (fileName) [fm removeItemAtPath:TPDMFilePath(fileName) error:nil];
                return;
            }
            if (thumbName) { it[@"thumb"] = thumbName; [sThumbs removeObjectForKey:thumbName]; }
            if (duration > 0) it[@"duration"] = @(duration);
            if (fileName) {
                if ([it[@"file"] length] && ![it[@"file"] isEqualToString:fileName]) [fm removeItemAtPath:TPDMFilePath(it[@"file"]) error:nil];
                it[@"file"] = fileName;
            }
            TPDMSave();
        });
    });
}

static NSString *TPDMStagePath(NSString *ext) {
    return [TPDMDir(@"Thumbs") stringByAppendingPathComponent:
            [NSString stringWithFormat:@"stage_%@.%@", NSUUID.UUID.UUIDString, ext.length ? ext : @"bin"]];
}

+ (void)keepFile:(NSURL *)file record:(NSString *)rid item:(NSInteger)index {
    if (!file || !TPDMItem(rid, index)) return;
    NSString *ext = file.pathExtension.lowercaseString;
    NSString *staged = TPDMStagePath(ext);
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm linkItemAtPath:file.path toPath:staged error:nil] && ![fm copyItemAtPath:file.path toPath:staged error:nil]) return;
    [self processStaged:staged record:rid item:index ext:ext];
}

+ (void)keepData:(NSData *)data extension:(NSString *)ext record:(NSString *)rid item:(NSInteger)index {
    if (!data.length || !TPDMItem(rid, index)) return;
    NSString *staged = TPDMStagePath(ext);
    dispatch_async(TPDMQueue(), ^{
        if (![data writeToFile:staged atomically:NO]) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [self processStaged:staged record:rid item:index ext:ext]; });
    });
}

+ (void)removeRecord:(NSString *)rid {
    NSMutableDictionary *r = TPDMRecord(rid);
    if (!r) return;
    for (NSMutableDictionary *it in r[@"items"]) TPDMDeleteFilesOfItem(it);
    [sRecords removeObject:r];
    TPDMSave();
}

+ (NSArray<NSDictionary *> *)records {
    TPDMLoad();
    return sRecords.reverseObjectEnumerator.allObjects;
}

+ (NSDictionary *)recordWithID:(NSString *)rid { return TPDMRecord(rid); }

+ (NSDictionary *)existingRecordForCode:(NSString *)code {
    TPDMLoad();
    if (!code.length) return nil;
    for (NSDictionary *r in sRecords.reverseObjectEnumerator) {
        if (![r[@"code"] isEqualToString:code] || [r[@"kind"] isEqualToString:@"avatar"] || [r[@"kind"] isEqualToString:@"cover"]) continue;
        NSInteger st = [r[@"status"] integerValue];
        if (st == 0 || st == 1) return r;
        for (NSDictionary *it in r[@"items"]) if ([it[@"state"] integerValue] == 2) return r;
    }
    return nil;
}

+ (NSInteger)failedRecordCount {
    TPDMLoad();
    NSInteger n = 0;
    for (NSDictionary *r in sRecords) {
        if ([r[@"status"] integerValue] != 2) continue;
        for (NSDictionary *it in r[@"items"]) if ([it[@"state"] integerValue] == 3) { n++; break; }
    }
    return n;
}

+ (NSArray<NSDictionary *> *)libraryFiles {
    NSMutableArray *out = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSDictionary *r in [self records]) {
        NSArray *items = r[@"items"];
        for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
            NSString *p = TPDMFilePath(items[i][@"file"]);
            if (!p || ![fm fileExistsAtPath:p]) continue;
            [out addObject:@{ @"path": p, @"record": r[@"id"], @"item": @(i), @"video": items[i][@"video"] ?: @NO, @"date": r[@"date"] ?: NSDate.date }];
        }
    }
    return out;
}

+ (unsigned long long)libraryBytes {
    unsigned long long total = 0;
    for (NSDictionary *f in [self libraryFiles])
        total += [[NSFileManager.defaultManager attributesOfItemAtPath:f[@"path"] error:nil] fileSize];
    return total;
}

+ (void)deleteLibraryFile:(NSString *)path {
    for (NSDictionary *r in sRecords)
        for (NSMutableDictionary *it in r[@"items"])
            if ([TPDMFilePath(it[@"file"]) isEqualToString:path]) [it removeObjectForKey:@"file"];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    TPDMSave();
}

+ (void)deleteAllLibraryFiles {
    TPDMLoad();
    for (NSDictionary *r in sRecords) for (NSMutableDictionary *it in r[@"items"]) [it removeObjectForKey:@"file"];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *f in [fm contentsOfDirectoryAtPath:TPDMDir(@"Files") error:nil])
        [fm removeItemAtPath:[TPDMDir(@"Files") stringByAppendingPathComponent:f] error:nil];
    TPDMSave();
}

+ (void)clearHistory {
    TPDMLoad();
    for (NSMutableDictionary *r in [sRecords copy]) {
        NSInteger st = [r[@"status"] integerValue];
        if (st == 0 || st == 1) continue;
        for (NSMutableDictionary *it in r[@"items"]) TPDMDeleteFilesOfItem(it);
        [sRecords removeObject:r];
    }
    TPDMSave();
}

+ (UIImage *)thumbnailForRecord:(NSDictionary *)record item:(NSInteger)index {
    NSArray *items = record[@"items"];
    NSString *name = nil;
    if (index >= 0 && index < (NSInteger)items.count) name = items[index][@"thumb"];
    else for (NSDictionary *it in items) if ([it[@"thumb"] length]) { name = it[@"thumb"]; break; }
    if (!name.length) return nil;
    UIImage *img = [sThumbs objectForKey:name];
    if (!img) {
        img = [UIImage imageWithContentsOfFile:TPDMThumbPath(name)];
        if (img) [sThumbs setObject:img forKey:name];
    }
    return img;
}

@end

#pragma mark - Shared UI bits

static UINavigationController *TPDMNav(UIViewController *root) {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.navigationBar.tintColor = [TPUI accent];
    nav.view.tintColor = [TPUI accent];
    UINavigationBarAppearance *ap = [UINavigationBarAppearance new];
    [ap configureWithOpaqueBackground];
    ap.backgroundColor = [TPUI pageColor];
    ap.shadowColor = UIColor.clearColor;
    nav.navigationBar.standardAppearance = ap;
    nav.navigationBar.scrollEdgeAppearance = ap;
    nav.navigationBar.compactAppearance = ap;
    if (@available(iOS 15.0, *)) {
        nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
        nav.sheetPresentationController.prefersGrabberVisible = YES;
    }
    return nav;
}

static NSString *TPDMDateText(NSDate *d) {
    if (!d) return @"";
    NSCalendar *cal = NSCalendar.currentCalendar;
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    if ([cal isDateInToday:d]) { f.dateFormat = @"HH:mm"; return [f stringFromDate:d]; }
    if ([cal isDateInYesterday:d]) { f.dateFormat = @"HH:mm"; return [NSString stringWithFormat:@"%@ %@", TPL(@"Yesterday"), [f stringFromDate:d]]; }
    BOOL sameYear = [cal component:NSCalendarUnitYear fromDate:d] == [cal component:NSCalendarUnitYear fromDate:NSDate.date];
    f.dateFormat = sameYear ? @"M/d HH:mm" : @"yyyy/M/d";
    return [f stringFromDate:d];
}

// "0:42", "12:05", "1:02:33"
static NSString *TPDMDurationText(double sec) {
    long t = lround(sec);
    if (t >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", t / 3600, (t / 60) % 60, t % 60];
    return [NSString stringWithFormat:@"%ld:%02ld", t / 60, t % 60];
}

static double TPDMTotalDuration(NSDictionary *r) {
    double total = 0;
    for (NSDictionary *it in r[@"items"]) total += [it[@"duration"] doubleValue];
    return total;
}

static NSString *TPDMTimeText(NSDate *d) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"HH:mm";
    return d ? [f stringFromDate:d] : @"";
}

// History group titles: Today, Yesterday, 11/20 (with the year when it isn't this year).
static NSString *TPDMDayTitle(NSDate *d) {
    NSCalendar *cal = NSCalendar.currentCalendar;
    if ([cal isDateInToday:d]) return TPL(@"Today");
    if ([cal isDateInYesterday:d]) return TPL(@"Yesterday");
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    BOOL sameYear = [cal component:NSCalendarUnitYear fromDate:d] == [cal component:NSCalendarUnitYear fromDate:NSDate.date];
    f.dateFormat = sameYear ? @"M/d" : @"yyyy/M/d";
    return [f stringFromDate:d];
}

static NSString *TPDMCountsText(NSDictionary *r) {
    NSInteger photos = 0, videos = 0;
    for (NSDictionary *it in r[@"items"]) { if ([it[@"video"] boolValue]) videos++; else photos++; }
    NSMutableArray *parts = [NSMutableArray array];
    if (photos) [parts addObject:photos == 1 ? TPL(@"1 photo") : [NSString stringWithFormat:TPL(@"%ld photos"), (long)photos]];
    if (videos) [parts addObject:videos == 1 ? TPL(@"1 video") : [NSString stringWithFormat:TPL(@"%ld videos"), (long)videos]];
    return [parts componentsJoinedByString:@" · "];
}

static NSInteger TPDMCount(NSDictionary *r, NSInteger state) {
    NSInteger n = 0;
    for (NSDictionary *it in r[@"items"]) if ([it[@"state"] integerValue] == state) n++;
    return n;
}

static NSString *TPDMTitle(NSDictionary *r) {
    if ([r[@"author"] length]) return [@"@" stringByAppendingString:r[@"author"]];
    if ([r[@"kind"] isEqualToString:@"avatar"]) return TPL(@"Profile Picture");
    if ([r[@"kind"] isEqualToString:@"cover"]) return TPL(@"Cover Photo");
    if ([r[@"code"] length]) return [NSString stringWithFormat:TPL(@"Post %@"), r[@"code"]];
    return TPDMCountsText(r);
}

static void TPDMOpenPost(UIViewController *from, NSDictionary *r) {
    NSString *code = r[@"code"], *author = r[@"author"], *rid = r[@"id"];
    if ((!code.length && !author.length) || !TPDownloadOpenPost) return;
    void (^launch)(void) = ^{
        if (!code.length || author.length) {
            TPDownloadOpenPost(code, author);
            return;
        }
        TPDMResolveAuthorWithCompletion(rid, code, ^(NSString *resolved) {
            TPDownloadOpenPost(code, resolved);
        });
    };
    UIViewController *sheet = from.navigationController ?: from;
    UIViewController *presenter = sheet.presentingViewController;
    if (presenter) [presenter dismissViewControllerAnimated:YES completion:launch];
    else launch();
}

static void TPDMConfirm(UIViewController *vc, NSString *title, NSString *message, NSString *action, void (^go)(void)) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:action style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { go(); }]];
    [vc presentViewController:a animated:YES completion:nil];
}

#pragma mark - Record row

// Video length on a thumbnail's bottom-right corner, as in Photos.
static UILabel *TPDMDurationBadge(void) {
    UILabel *l = [UILabel new];
    l.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightSemibold];
    l.textColor = UIColor.whiteColor;
    l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    l.layer.cornerRadius = 4;
    l.clipsToBounds = YES;
    l.hidden = YES;
    return l;
}

@interface TPDMRecordCell : UITableViewCell
@property (nonatomic, strong) UIImageView *thumb;
@property (nonatomic, strong) UIImageView *badge;
@property (nonatomic, strong) UILabel *titleLabel, *subLabel, *statusLabel;
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, strong) UIButton *more;
@property (nonatomic, strong) UILabel *duration;
@end

@implementation TPDMRecordCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        self.backgroundColor = [TPUI cardColor];
        _thumb = [UIImageView new];
        _thumb.contentMode = UIViewContentModeScaleAspectFill;
        _thumb.clipsToBounds = YES;
        _thumb.layer.cornerRadius = 8;
        _thumb.backgroundColor = UIColor.tertiarySystemFillColor;
        _thumb.tintColor = UIColor.secondaryLabelColor;
        _badge = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"play.fill"]];
        _badge.tintColor = UIColor.whiteColor;
        _badge.contentMode = UIViewContentModeScaleAspectFit;
        _badge.layer.shadowOpacity = 0.5;
        _badge.layer.shadowRadius = 2;
        _badge.layer.shadowOffset = CGSizeZero;
        [_thumb addSubview:_badge];
        _duration = TPDMDurationBadge();
        [_thumb addSubview:_duration];
        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        _subLabel = [UILabel new];
        _subLabel.font = [UIFont systemFontOfSize:13];
        _subLabel.textColor = UIColor.secondaryLabelColor;
        _statusLabel = [UILabel new];
        _statusLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
        _statusLabel.textAlignment = NSTextAlignmentRight;
        _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _bar.progressTintColor = [TPUI accent];
        _more = [UIButton buttonWithType:UIButtonTypeSystem];
        [_more setImage:[UIImage systemImageNamed:@"ellipsis.circle" withConfiguration:
                         [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular]] forState:UIControlStateNormal];
        _more.tintColor = [TPUI accent];
        _more.showsMenuAsPrimaryAction = YES;
        for (UIView *v in @[_thumb, _titleLabel, _subLabel, _statusLabel, _bar, _more]) [self.contentView addSubview:v];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat x = 14, s = 46;
    _thumb.frame = CGRectMake(x, (b.size.height - s) / 2, s, s);
    _badge.frame = CGRectMake(s - 17, s - 17, 12, 12);
    CGSize ds = [_duration sizeThatFits:CGSizeMake(s, 14)];
    _duration.frame = CGRectMake(s - ds.width - 8 - 2, s - 14 - 2, ds.width + 8, 14);
    _more.frame = CGRectMake(b.size.width - 44, (b.size.height - 44) / 2, 40, 44);
    CGFloat right = b.size.width - 44;
    CGFloat tx = x + s + 12, sw = [_statusLabel sizeThatFits:CGSizeMake(140, 20)].width;
    _statusLabel.frame = CGRectMake(right - 2 - sw, 0, sw, 20);
    _statusLabel.center = CGPointMake(_statusLabel.center.x, _bar.hidden ? b.size.height / 2 : b.size.height / 2 - 8);
    CGFloat tw = CGRectGetMinX(_statusLabel.frame) - 8 - tx;
    _titleLabel.frame = CGRectMake(tx, b.size.height / 2 - 21, tw, 21);
    _subLabel.frame = CGRectMake(tx, b.size.height / 2 + 1, _bar.hidden ? right - 2 - tx : tw, 18);
    if (!_bar.hidden) _bar.frame = CGRectMake(tx, b.size.height - 9, right - 2 - tx, 4);
}
@end

#pragma mark - Library

@interface TPDMLibraryViewController : UICollectionViewController <QLPreviewControllerDataSource>
@end

@interface TPDMFileCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *image, *badge;
@property (nonatomic, strong) UILabel *duration;
@end
@implementation TPDMFileCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _image = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
        _image.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _image.contentMode = UIViewContentModeScaleAspectFill;
        _image.clipsToBounds = YES;
        _image.backgroundColor = UIColor.tertiarySystemFillColor;
        _badge = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"play.fill"]];
        _badge.tintColor = UIColor.whiteColor;
        _badge.contentMode = UIViewContentModeScaleAspectFit;
        _badge.layer.shadowOpacity = 0.6;
        _badge.layer.shadowRadius = 2;
        _badge.layer.shadowOffset = CGSizeZero;
        [self.contentView addSubview:_image];
        [self.contentView addSubview:_badge];
        _duration = TPDMDurationBadge();
        _duration.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
        [self.contentView addSubview:_duration];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _badge.frame = CGRectMake(6, self.bounds.size.height - 20, 14, 14);
    CGSize ds = [_duration sizeThatFits:CGSizeMake(80, 16)];
    _duration.frame = CGRectMake(self.bounds.size.width - ds.width - 10 - 4, self.bounds.size.height - 16 - 4, ds.width + 10, 16);
}
@end

@interface TPDMLibraryHeader : UICollectionReusableView
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, strong) UILabel *title, *detail, *usage;
@property (nonatomic, strong) UIView *card;
@end
@implementation TPDMLibraryHeader
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _card = [UIView new];
        _card.backgroundColor = [TPUI cardColor];
        _card.layer.cornerRadius = 12;
        _title = [UILabel new];
        _title.font = [UIFont systemFontOfSize:16];
        _title.text = TPL(@"Keep Copies in ThreadsPulse");
        _detail = [UILabel new];
        _detail.font = [UIFont systemFontOfSize:13];
        _detail.textColor = UIColor.secondaryLabelColor;
        _detail.numberOfLines = 0;
        _detail.text = TPL(@"Downloaded files are also kept here, so you can preview, share or save them again. Uses storage on your iPhone.");
        _toggle = [UISwitch new];
        _toggle.onTintColor = [TPUI accent];
        _usage = [UILabel new];
        _usage.font = [UIFont systemFontOfSize:13];
        _usage.textColor = UIColor.secondaryLabelColor;
        [self addSubview:_card];
        for (UIView *v in @[_title, _detail, _toggle]) [_card addSubview:v];
        [self addSubview:_usage];
    }
    return self;
}
+ (CGFloat)heightForWidth:(CGFloat)w {
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:13];
    l.numberOfLines = 0;
    l.text = TPL(@"Downloaded files are also kept here, so you can preview, share or save them again. Uses storage on your iPhone.");
    CGFloat dh = [l sizeThatFits:CGSizeMake(w - 32 - 32, CGFLOAT_MAX)].height;
    return 8 + 12 + 22 + 4 + dh + 12 + 10 + 18 + 8;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat cw = w - 32;
    CGSize ts = _toggle.intrinsicContentSize;
    CGFloat dh = [_detail sizeThatFits:CGSizeMake(cw - 32, CGFLOAT_MAX)].height;
    _title.frame = CGRectMake(16, 12, cw - 32 - ts.width - 8, 22);
    _toggle.frame = CGRectMake(cw - 16 - ts.width, 7, ts.width, ts.height);
    _detail.frame = CGRectMake(16, 38, cw - 32, dh);
    _card.frame = CGRectMake(16, 8, cw, 38 + dh + 12);
    _usage.frame = CGRectMake(28, CGRectGetMaxY(_card.frame) + 10, w - 56, 18);
}
@end

@implementation TPDMLibraryViewController {
    NSArray<NSDictionary *> *_files;
    NSInteger _previewStart;
}

- (instancetype)init {
    UICollectionViewFlowLayout *l = [UICollectionViewFlowLayout new];
    l.minimumInteritemSpacing = 2;
    l.minimumLineSpacing = 2;
    return [super initWithCollectionViewLayout:l];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = TPL(@"Library");
    self.collectionView.backgroundColor = [TPUI pageColor];
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:[TPDMFileCell class] forCellWithReuseIdentifier:@"f"];
    [self.collectionView registerClass:[TPDMLibraryHeader class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"h"];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:TPDownloadStoreDidChangeNotification object:nil];
    [self reload];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)reload {
    _files = [TPDownloadStore libraryFiles];
    [self.collectionView reloadData];
    __weak typeof(self) weak = self;
    UIAction *delAll = [UIAction actionWithTitle:TPL(@"Delete All Files") image:[UIImage systemImageNamed:@"trash"] identifier:nil
                                         handler:^(UIAction *a) { [weak confirmDeleteAll]; }];
    delAll.attributes = _files.count ? UIMenuElementAttributesDestructive : UIMenuElementAttributesDisabled;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                                               menu:[UIMenu menuWithChildren:@[delAll]]];
    [self updateEmpty];
}

- (void)updateEmpty {
    if (_files.count) { self.collectionView.backgroundView = nil; return; }
    UILabel *l = [UILabel new];
    l.numberOfLines = 0;
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = UIColor.secondaryLabelColor;
    l.font = [UIFont systemFontOfSize:15];
    BOOL on = [TPPrefs boolForKey:TPKeyKeepDownloadCopies];
    l.text = on ? TPL(@"No files yet") : TPL(@"Turn on Keep Copies to save files here as you download.");
    UIView *bg = [UIView new];
    [bg addSubview:l];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [l.centerXAnchor constraintEqualToAnchor:bg.centerXAnchor],
        [l.centerYAnchor constraintEqualToAnchor:bg.centerYAnchor constant:40],
        [l.widthAnchor constraintLessThanOrEqualToAnchor:bg.widthAnchor constant:-60],
    ]];
    self.collectionView.backgroundView = bg;
}

- (void)confirmDeleteAll {
    TPDMConfirm(self, TPL(@"Delete All Files?"), TPL(@"Download history stays. Photos is not affected."), TPL(@"Delete"), ^{
        [TPDownloadStore deleteAllLibraryFiles];
    });
}

- (void)toggled:(UISwitch *)s {
    [TPPrefs setBool:s.on forKey:TPKeyKeepDownloadCopies];
    [self updateEmpty];
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return _files.count; }

- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)l sizeForItemAtIndexPath:(NSIndexPath *)ip {
    CGFloat w = cv.bounds.size.width - cv.safeAreaInsets.left - cv.safeAreaInsets.right;
    NSInteger cols = w > 600 ? 5 : 3;
    CGFloat side = floor((w - 2 * (cols - 1)) / cols);
    return CGSizeMake(side, side);
}

- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)l referenceSizeForHeaderInSection:(NSInteger)s {
    return CGSizeMake(cv.bounds.size.width, [TPDMLibraryHeader heightForWidth:cv.bounds.size.width]);
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)cv viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)ip {
    TPDMLibraryHeader *h = [cv dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"h" forIndexPath:ip];
    h.toggle.on = [TPPrefs boolForKey:TPKeyKeepDownloadCopies];
    [h.toggle removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
    [h.toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
    NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)[TPDownloadStore libraryBytes] countStyle:NSByteCountFormatterCountStyleFile];
    h.usage.text = _files.count ? [NSString stringWithFormat:TPL(@"%ld items · %@"), (long)_files.count, size] : nil;
    return h;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    TPDMFileCell *c = [cv dequeueReusableCellWithReuseIdentifier:@"f" forIndexPath:ip];
    NSDictionary *f = _files[ip.item];
    c.image.image = [TPDownloadStore thumbnailForRecord:[TPDownloadStore recordWithID:f[@"record"]] item:[f[@"item"] integerValue]];
    double dur = [[TPDownloadStore recordWithID:f[@"record"]][@"items"][[f[@"item"] integerValue]][@"duration"] doubleValue];
    c.duration.hidden = dur <= 0;
    c.duration.text = dur > 0 ? TPDMDurationText(dur) : nil;
    c.badge.hidden = ![f[@"video"] boolValue] || dur > 0;
    [c setNeedsLayout];
    return c;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    _previewStart = ip.item;
    QLPreviewController *q = [QLPreviewController new];
    q.dataSource = self;
    q.currentPreviewItemIndex = ip.item;
    [self presentViewController:q animated:YES completion:nil];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)c { return _files.count; }
- (id<QLPreviewItem>)previewController:(QLPreviewController *)c previewItemAtIndex:(NSInteger)i {
    return [NSURL fileURLWithPath:_files[i][@"path"]];
}

- (void)saveToPhotos:(NSDictionary *)f {
    NSURL *url = [NSURL fileURLWithPath:f[@"path"]];
    BOOL video = [f[@"video"] boolValue];
    void (^save)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            if (video) [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url];
            else [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:url];
        } completionHandler:^(BOOL ok, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) { [TPUI hapticSuccess]; [TPHUD toast:TPL(@"Saved to Photos")]; }
                else { [TPUI hapticError]; [TPHUD toast:TPL(@"Download failed, please try again later")]; }
            });
        }];
    };
    PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    if (st == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus s) {
            if (s == PHAuthorizationStatusAuthorized || s == PHAuthorizationStatusLimited) save();
        }];
    } else if (st == PHAuthorizationStatusAuthorized || st == PHAuthorizationStatusLimited) {
        save();
    } else {
        [TPHUD toast:TPL(@"Photos access denied — choose where to save")];
    }
}

// Remove the cell at once; the menu's closing animation would otherwise hold back a plain reload.
- (void)deleteFile:(NSDictionary *)f {
    [TPDownloadStore deleteLibraryFile:f[@"path"]];
    NSUInteger i = [_files indexOfObject:f];
    if (i == NSNotFound) { [self reload]; return; }
    NSMutableArray *m = [_files mutableCopy];
    [m removeObjectAtIndex:i];
    _files = m;
    [self.collectionView performBatchUpdates:^{
        [self.collectionView deleteItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:(NSInteger)i inSection:0]]];
    } completion:^(BOOL done) { [self reload]; }];
}

- (void)share:(NSDictionary *)f from:(UIView *)src {
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:f[@"path"]]]
                                                                     applicationActivities:nil];
    av.popoverPresentationController.sourceView = src ?: self.view;
    av.popoverPresentationController.sourceRect = src ? src.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:av animated:YES completion:nil];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)cv contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)ip point:(CGPoint)p {
    NSDictionary *f = _files[ip.item];
    NSDictionary *r = [TPDownloadStore recordWithID:f[@"record"]];
    __weak typeof(self) weak = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        NSMutableArray *acts = [NSMutableArray array];
        [acts addObject:[UIAction actionWithTitle:TPL(@"Share") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil
                                          handler:^(UIAction *a) { [weak share:f from:[cv cellForItemAtIndexPath:ip]]; }]];
        [acts addObject:[UIAction actionWithTitle:TPL(@"Save to Photos") image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil
                                          handler:^(UIAction *a) { [weak saveToPhotos:f]; }]];
        if ([r[@"code"] length] && TPDownloadOpenPost)
            [acts addObject:[UIAction actionWithTitle:TPL(@"Open Post") image:[UIImage systemImageNamed:@"bubble.left.and.text.bubble.right"] identifier:nil
                                              handler:^(UIAction *a) { TPDMOpenPost(weak, r); }]];
        else if ([r[@"author"] length] && TPDownloadOpenPost)
            [acts addObject:[UIAction actionWithTitle:TPL(@"Open Profile") image:[UIImage systemImageNamed:@"person.crop.circle"] identifier:nil
                                              handler:^(UIAction *a) { TPDMOpenPost(weak, r); }]];
        UIAction *del = [UIAction actionWithTitle:TPL(@"Delete") image:[UIImage systemImageNamed:@"trash"] identifier:nil
                                          handler:^(UIAction *a) { [weak deleteFile:f]; }];
        del.attributes = UIMenuElementAttributesDestructive;
        [acts addObject:del];
        return [UIMenu menuWithChildren:acts];
    }];
}

@end

#pragma mark - Manager

typedef NS_ENUM(NSInteger, TPDMSection) { TPDMSecLibrary, TPDMSecActive, TPDMSecQueue, TPDMSecFailed, TPDMSecHistory };
static const NSInteger kTPDMDayBase = 100;

static NSArray<NSURL *> *TPDMKeptFileURLsForRecord(NSDictionary *r) {
    if (!r) return nil;
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSDictionary *it in r[@"items"]) {
        NSString *name = it[@"file"];
        NSString *path = name.length ? TPDMFilePath(name) : nil;
        if (path.length && [fm fileExistsAtPath:path]) {
            [urls addObject:[NSURL fileURLWithPath:path]];
        }
    }
    return urls.count ? urls : nil;
}

static NSString *TPDMPostURLStringForRecord(NSDictionary *r) {
    NSString *code = r[@"code"];
    NSString *author = r[@"author"];
    if (code.length && author.length) {
        return [NSString stringWithFormat:@"https://www.threads.com/@%@/post/%@", author, code];
    }
    if (code.length) {
        return [@"https://www.threads.com/t/" stringByAppendingString:code];
    }
    if (author.length) {
        return [@"https://www.threads.com/@" stringByAppendingString:author];
    }
    return nil;
}

@interface TPDownloadManagerViewController () <UISearchBarDelegate>
@end

@implementation TPDownloadManagerViewController {
    NSArray<NSNumber *> *_sections;
    NSArray<NSDictionary *> *_active;
    NSArray<NSDictionary *> *_queue, *_failed, *_history;
    NSArray<NSDictionary *> *_historyDays;   // @{ title, rows }, newest day first
    NSMutableDictionary<NSString *, NSDictionary *> *_progress;   // record id -> latest progress
    BOOL _moving, _reordering;
    UISearchBar *_searchBar;   // in the list header, not the navigation bar: same on iOS 16–27
    UISegmentedControl *_filterSeg;
    NSInteger _filterMode; // 0 All, 1 Videos, 2 Photos, 3 Failed
    NSString *_searchQuery;
}

+ (void)present {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = TPTopViewController();
        if (!top) return;
        if ([top isKindOfClass:[UINavigationController class]]) {
            for (UIViewController *vc in [(UINavigationController *)top viewControllers]) if ([vc isKindOfClass:self]) return;
        }
        [top presentViewController:TPDMNav([self new]) animated:YES completion:nil];
    });
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = TPL(@"Download Manager");
    self.tableView.backgroundColor = [TPUI pageColor];
    self.tableView.rowHeight = 66;
    self.tableView.sectionHeaderTopPadding = 6;
    CGFloat w = self.view.bounds.size.width ?: 360;
    UIView *hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 96)];
    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(8, 0, w - 16, 52)];
    _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.placeholder = TPL(@"Search @author or post code");
    _searchBar.delegate = self;
    _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    [hdr addSubview:_searchBar];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _filterSeg = [[UISegmentedControl alloc] initWithItems:@[TPL(@"All"), TPL(@"Videos"), TPL(@"Photos"), TPL(@"Failed")]];
    _filterSeg.selectedSegmentIndex = 0;
    _filterSeg.translatesAutoresizingMaskIntoConstraints = NO;
    [_filterSeg addTarget:self action:@selector(filterChanged:) forControlEvents:UIControlEventValueChanged];
    [hdr addSubview:_filterSeg];
    [NSLayoutConstraint activateConstraints:@[
        [_filterSeg.leadingAnchor constraintEqualToAnchor:hdr.leadingAnchor constant:16],
        [_filterSeg.trailingAnchor constraintEqualToAnchor:hdr.trailingAnchor constant:-16],
        [_filterSeg.topAnchor constraintEqualToAnchor:hdr.topAnchor constant:56],
    ]];
    self.tableView.tableHeaderView = hdr;

    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                              target:self action:@selector(close)];
    }
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(reload) name:TPDownloadStoreDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(reload) name:@"TPQueueChanged" object:nil];
    [nc addObserver:self selector:@selector(progressed:) name:TPDownloadProgressNotification object:nil];
    [self reload];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)filterChanged:(UISegmentedControl *)seg {
    _filterMode = seg.selectedSegmentIndex;
    [self reload];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)bar { [bar setShowsCancelButton:YES animated:YES]; }
- (void)searchBarTextDidEndEditing:(UISearchBar *)bar { [bar setShowsCancelButton:bar.text.length > 0 animated:YES]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)bar { [bar resignFirstResponder]; }
- (void)searchBarCancelButtonClicked:(UISearchBar *)bar {
    bar.text = @"";
    [bar resignFirstResponder];
    [bar setShowsCancelButton:NO animated:YES];
    [self searchBar:bar textDidChange:@""];
}

- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)text {
    NSString *q = [bar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if ([q hasPrefix:@"@"]) q = [q substringFromIndex:1];
    if ([q isEqualToString:_searchQuery ?: @""]) return;
    _searchQuery = q;
    [self reload];
}

- (BOOL)recordMatchesFilter:(NSDictionary *)r isFailed:(BOOL)isFailed {
    if (_searchQuery.length) {
        NSString *author = r[@"author"] ?: @"";
        NSString *code = r[@"code"] ?: @"";
        BOOL hit = ([author rangeOfString:_searchQuery options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                   ([code rangeOfString:_searchQuery options:NSCaseInsensitiveSearch].location != NSNotFound);
        if (!hit) return NO;
    }
    if (_filterMode == 3) return isFailed;
    if (_filterMode == 1 || _filterMode == 2) {
        BOOL wantVideo = (_filterMode == 1);
        for (NSDictionary *it in r[@"items"]) {
            if ([it[@"video"] boolValue] == wantVideo) return YES;
        }
        return NO;
    }
    return YES;
}

- (void)reload {
    if (_moving) return;
    NSArray *activeIDs = [TPDownloader activeRecordIDs];
    NSArray *queuedIDs = [TPDownloader queuedRecordIDs];
    // While reordering, leave the table alone unless the queue itself changed.
    if (_reordering) {
        NSMutableArray *shown = [NSMutableArray array];
        for (NSDictionary *r in _queue) [shown addObject:r[@"id"]];
        if ([shown isEqualToArray:queuedIDs]) return;
    }
    NSMutableArray *queue = [NSMutableArray array], *failed = [NSMutableArray array], *history = [NSMutableArray array];
    NSMutableArray *active = [NSMutableArray array];
    for (NSString *rid in activeIDs) {
        NSDictionary *r = [TPDownloadStore recordWithID:rid];
        if (r && [self recordMatchesFilter:r isFailed:NO]) [active addObject:r];
    }
    for (NSString *rid in queuedIDs) {
        NSDictionary *r = [TPDownloadStore recordWithID:rid];
        if (r && [self recordMatchesFilter:r isFailed:NO]) [queue addObject:r];
    }
    for (NSDictionary *r in [TPDownloadStore records]) {
        NSInteger st = [r[@"status"] integerValue];
        if (st == 0 || st == 1) continue;
        BOOL isFailed = (st == 2 && TPDMCount(r, 3) > 0);
        if (![self recordMatchesFilter:r isFailed:isFailed]) continue;
        if (isFailed) [failed addObject:r];
        else [history addObject:r];
    }
    if (!_progress) _progress = [NSMutableDictionary dictionary];
    for (NSString *k in _progress.allKeys) if (![activeIDs containsObject:k]) [_progress removeObjectForKey:k];
    _active = active; _queue = queue; _failed = failed; _history = history;
    NSMutableArray *secs = [NSMutableArray arrayWithObject:@(TPDMSecLibrary)];
    if (active.count) [secs addObject:@(TPDMSecActive)];
    if (queue.count) [secs addObject:@(TPDMSecQueue)];
    if (failed.count) [secs addObject:@(TPDMSecFailed)];
    NSMutableArray *days = [NSMutableArray array];
    for (NSDictionary *r in history) {
        NSString *title = TPDMDayTitle(r[@"date"] ?: NSDate.date);
        if (![days.lastObject[@"title"] isEqualToString:title]) [days addObject:@{ @"title": title, @"rows": [NSMutableArray array] }];
        [days.lastObject[@"rows"] addObject:r];
    }
    _historyDays = days;
    // History days are numbered from kTPDMDayBase so each day is its own section.
    for (NSUInteger i = 0; i < days.count; i++) [secs addObject:@(kTPDMDayBase + (NSInteger)i)];
    _sections = secs;
    // The queue changed under the reorder handles (a download started or finished): stop reordering.
    if (_reordering) { _reordering = NO; [self.tableView setEditing:NO animated:NO]; }
    [self.tableView reloadData];
    [self updateMenu];
    [self updateEmpty];
}

- (void)updateEmpty {
    BOOL empty = !_active.count && !_queue.count && !_failed.count && !_history.count;
    if (!empty) { self.tableView.backgroundView = nil; return; }
    UILabel *l = [UILabel new];
    l.numberOfLines = 0;
    l.textAlignment = NSTextAlignmentCenter;
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:TPL(@"No downloads yet")
        attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: UIColor.labelColor }];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:TPL(@"Downloads appear here, including failed ones you can retry.")]
        attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:14], NSForegroundColorAttributeName: UIColor.secondaryLabelColor }]];
    l.attributedText = s;
    UIView *bg = [UIView new];
    [bg addSubview:l];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [l.centerXAnchor constraintEqualToAnchor:bg.centerXAnchor],
        [l.centerYAnchor constraintEqualToAnchor:bg.centerYAnchor],
        [l.widthAnchor constraintLessThanOrEqualToAnchor:bg.widthAnchor constant:-60],
    ]];
    self.tableView.backgroundView = bg;
}

- (void)updateMenu {
    if (_reordering) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                               target:self action:@selector(endEditingQueue)];
        return;
    }
    __weak typeof(self) weak = self;
    NSMutableArray *acts = [NSMutableArray array];
    BOOL paused = [TPDownloader queuePaused];
    [acts addObject:[UIAction actionWithTitle:paused ? TPL(@"Resume Queue") : TPL(@"Pause Queue")
                                        image:[UIImage systemImageNamed:paused ? @"play.circle" : @"pause.circle"] identifier:nil
                                      handler:^(UIAction *a) { [TPDownloader setQueuePaused:!paused]; [weak reload]; }]];
    UIAction *edit = [UIAction actionWithTitle:TPL(@"Reorder Queue") image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil
                                       handler:^(UIAction *a) { [weak beginEditingQueue]; }];
    if (_queue.count < 2) edit.attributes = UIMenuElementAttributesDisabled;
    [acts addObject:edit];
    UIAction *retry = [UIAction actionWithTitle:TPL(@"Retry All Failed") image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil
                                        handler:^(UIAction *a) { [weak retryAll]; }];
    if (!_failed.count) retry.attributes = UIMenuElementAttributesDisabled;
    [acts addObject:retry];
    UIAction *clear = [UIAction actionWithTitle:TPL(@"Clear History") image:[UIImage systemImageNamed:@"trash"] identifier:nil
                                        handler:^(UIAction *a) { [weak confirmClear]; }];
    clear.attributes = (_failed.count || _history.count) ? UIMenuElementAttributesDestructive : UIMenuElementAttributesDisabled;
    UIMenu *danger = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[clear]];
    [acts addObject:danger];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                                               menu:[UIMenu menuWithChildren:acts]];
}

- (void)beginEditingQueue { _reordering = YES; [self.tableView setEditing:YES animated:YES]; [self updateMenu]; }
- (void)endEditingQueue { _reordering = NO; [self.tableView setEditing:NO animated:YES]; [self reload]; }

- (void)retryAll {
    for (NSDictionary *r in _failed) [self retry:r failedOnly:YES quiet:YES];
    [TPHUD toast:TPL(@"Added to download queue")];
}

- (void)retry:(NSDictionary *)r failedOnly:(BOOL)failedOnly quiet:(BOOL)quiet {
    NSArray *items = [TPDownloadStore retryItemsForRecord:r[@"id"] failedOnly:failedOnly];
    if (!items.count) return;
    [TPDownloader downloadItems:items context:@{ @"retry": @YES, @"quiet": @(quiet) }];
}

- (void)confirmClear {
    TPDMConfirm(self, TPL(@"Clear History?"), TPL(@"Files kept in the Library are deleted too. Photos is not affected."), TPL(@"Clear"), ^{
        [TPDownloadStore clearHistory];
    });
}

- (void)progressed:(NSNotification *)n {
    NSString *rid = n.userInfo[@"record"];
    if (!rid) return;
    if (!_progress) _progress = [NSMutableDictionary dictionary];
    _progress[rid] = n.userInfo;
    NSUInteger s = [_sections indexOfObject:@(TPDMSecActive)];
    NSUInteger row = NSNotFound;
    for (NSUInteger i = 0; i < _active.count; i++) if ([_active[i][@"id"] isEqualToString:rid]) row = i;
    if (s == NSNotFound || row == NSNotFound) { [self reload]; return; }   // a download that just started
    TPDMRecordCell *c = (TPDMRecordCell *)[self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)row inSection:(NSInteger)s]];
    if (![c isKindOfClass:[TPDMRecordCell class]]) return;
    // Only the progress parts: leave the ⋯ menu alone so an open menu stays open.
    [self applyProgress:n.userInfo cell:c record:_active[row]];
}

- (void)applyProgress:(NSDictionary *)prog cell:(TPDMRecordCell *)c record:(NSDictionary *)r {
    CGFloat p = [prog[@"progress"] doubleValue];
    c.bar.progress = p;
    c.statusLabel.text = [NSString stringWithFormat:@"%.0f%%", floor(p * 100)];
    c.statusLabel.textColor = [TPUI accent];
    NSString *speed = prog[@"speed"];
    if (speed.length) c.subLabel.text = [NSString stringWithFormat:@"%@ · %@", TPDMCountsText(r), speed];
    [c setNeedsLayout];
}

- (NSArray<NSDictionary *> *)rowsFor:(TPDMSection)sec {
    switch (sec) {
        case TPDMSecActive: return _active ?: @[];
        case TPDMSecQueue: return _queue;
        case TPDMSecFailed: return _failed;
        case TPDMSecHistory: return _history;
        default: return @[];
    }
}

- (TPDMSection)secAt:(NSInteger)s {
    NSInteger v = [_sections[s] integerValue];
    return v >= kTPDMDayBase ? TPDMSecHistory : (TPDMSection)v;
}

- (NSArray<NSDictionary *> *)rowsAt:(NSInteger)s {
    NSInteger v = [_sections[s] integerValue];
    if (v >= kTPDMDayBase) return _historyDays[v - kTPDMDayBase][@"rows"];
    return [self rowsFor:(TPDMSection)v];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _sections.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    TPDMSection sec = [self secAt:s];
    return sec == TPDMSecLibrary ? 1 : [self rowsAt:s].count;
}
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return [self secAt:ip.section] == TPDMSecLibrary ? 50 : 66;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch ([self secAt:s]) {
        case TPDMSecActive: return TPL(@"Downloading");
        case TPDMSecQueue: return [TPDownloader queuePaused] ? [NSString stringWithFormat:@"%@ · %@", TPL(@"Queue"), TPL(@"Paused")] : TPL(@"Queue");
        case TPDMSecFailed: return TPL(@"Failed");
        case TPDMSecHistory: return _historyDays[[_sections[s] integerValue] - kTPDMDayBase][@"title"];
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    switch ([self secAt:s]) {
        case TPDMSecQueue: return [TPDownloader queuePaused] ? TPL(@"The queue is paused. The current download finishes first.") : nil;
        case TPDMSecFailed: return TPL(@"Download links can expire after a few days. If retrying fails, open the post and download it again.");
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    TPDMSection sec = [self secAt:ip.section];
    if (sec == TPDMSecLibrary) {
        UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"lib"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"lib"];
        c.backgroundColor = [TPUI cardColor];
        c.textLabel.text = TPL(@"Library");
        c.imageView.image = [UIImage systemImageNamed:@"photo.on.rectangle.angled"];
        c.imageView.tintColor = [TPUI accentIcon];
        NSInteger n = [TPDownloadStore libraryFiles].count;
        c.detailTextLabel.text = n ? [NSString stringWithFormat:@"%ld", (long)n] : ([TPPrefs boolForKey:TPKeyKeepDownloadCopies] ? @"0" : TPL(@"Off"));
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    TPDMRecordCell *c = [tv dequeueReusableCellWithIdentifier:@"r"] ?: [[TPDMRecordCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"r"];
    [self fill:c record:[self rowsAt:ip.section][ip.row] section:sec];
    return c;
}

- (void)fill:(TPDMRecordCell *)c record:(NSDictionary *)r section:(TPDMSection)sec {
    UIImage *t = [TPDownloadStore thumbnailForRecord:r item:-1];
    BOOL anyVideo = NO, allVideo = YES;
    for (NSDictionary *it in r[@"items"]) { if ([it[@"video"] boolValue]) anyVideo = YES; else allVideo = NO; }
    if (t) { c.thumb.image = t; c.thumb.contentMode = UIViewContentModeScaleAspectFill; }
    else {
        NSString *sym = [r[@"kind"] isEqualToString:@"avatar"] ? @"person.crop.circle" : [r[@"kind"] isEqualToString:@"cover"] ? @"photo.artframe" : (allVideo ? @"video" : @"photo");
        c.thumb.image = [UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17]];
        c.thumb.contentMode = UIViewContentModeCenter;
    }
    double total = TPDMTotalDuration(r);
    c.duration.hidden = !(t && total > 0);
    c.duration.text = total > 0 ? TPDMDurationText(total) : nil;
    c.badge.hidden = !(t && anyVideo) || total > 0;
    c.titleLabel.text = TPDMTitle(r);
    BOOL titled = [r[@"author"] length] || [r[@"code"] length] || [r[@"kind"] isEqualToString:@"avatar"] || [r[@"kind"] isEqualToString:@"cover"];
    // History rows sit under a day heading, so the time alone is enough.
    NSString *when = sec == TPDMSecHistory ? TPDMTimeText(r[@"date"]) : TPDMDateText(r[@"date"]);
    NSInteger videos = 0;
    for (NSDictionary *it in r[@"items"]) if ([it[@"video"] boolValue]) videos++;
    NSString *counts = TPDMCountsText(r);
    if (videos > 1 && total > 0) counts = [counts stringByAppendingFormat:@" · %@", [NSString stringWithFormat:TPL(@"%@ total"), TPDMDurationText(total)]];
    c.subLabel.text = titled ? [NSString stringWithFormat:@"%@ · %@", counts, when] : when;
    c.bar.hidden = sec != TPDMSecActive;
    c.statusLabel.textColor = UIColor.secondaryLabelColor;
    NSInteger failed = TPDMCount(r, 3);
    switch (sec) {
        case TPDMSecActive:
            [self applyProgress:_progress[r[@"id"]] cell:c record:r];
            break;
        case TPDMSecQueue: c.statusLabel.text = TPL(@"Waiting"); break;
        case TPDMSecFailed:
            c.statusLabel.text = [NSString stringWithFormat:TPL(@"%ld failed"), (long)failed];
            c.statusLabel.textColor = UIColor.systemRedColor;
            break;
        default:
            c.statusLabel.text = [r[@"status"] integerValue] == 4 ? TPL(@"Cancelled") : TPL(@"Saved");
            break;
    }
    c.showsReorderControl = sec == TPDMSecQueue;
    c.more.menu = [self menuFor:r section:sec];
    c.more.hidden = _reordering;
    [c setNeedsLayout];
}

// The actions for one record, used by the row's ⋯ menu and by tapping the row.
// Each entry: @[title, symbol, destructive, block].
- (NSArray<NSArray *> *)actionsFor:(NSDictionary *)r section:(TPDMSection)sec {
    __weak typeof(self) weak = self;
    NSMutableArray *acts = [NSMutableArray array];
    if ([r[@"code"] length] && TPDownloadOpenPost)
        [acts addObject:@[TPL(@"Open Post"), @"bubble.left.and.text.bubble.right", @NO, ^{ TPDMOpenPost(weak, r); }]];
    else if ([r[@"author"] length] && TPDownloadOpenPost)
        [acts addObject:@[TPL(@"Open Profile"), @"person.crop.circle", @NO, ^{ TPDMOpenPost(weak, r); }]];
    NSString *postLink = TPDMPostURLStringForRecord(r);
    if (postLink.length) {
        [acts addObject:@[TPL(@"Copy Post Link"), @"link", @NO, ^{
            UIPasteboard.generalPasteboard.string = postLink;
            [TPUI hapticLight];
            [TPHUD toast:TPL(@"Post link copied")];
        }]];
    }
    NSArray<NSURL *> *keptURLs = TPDMKeptFileURLsForRecord(r);
    if (keptURLs.count) {
        [acts addObject:@[TPL(@"Share Kept Files"), @"square.and.arrow.up", @NO, ^{
            TPDownloadManagerViewController *s = weak;
            if (!s) return;
            UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:keptURLs applicationActivities:nil];
            av.popoverPresentationController.sourceView = s.view;
            av.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(s.view.bounds), CGRectGetMidY(s.view.bounds), 1, 1);
            [s presentViewController:av animated:YES completion:nil];
        }]];
    }
    if (sec == TPDMSecActive) {
        [acts addObject:@[TPL(@"Cancel Download"), @"xmark.circle", @YES, ^{ [TPDownloader cancelRecord:r[@"id"]]; }]];
    } else if (sec == TPDMSecQueue) {
        [acts addObject:@[TPL(@"Remove from Queue"), @"minus.circle", @YES, ^{ [TPDownloader removeQueuedRecord:r[@"id"]]; }]];
    } else {
        if (sec == TPDMSecFailed)
            [acts addObject:@[TPL(@"Retry Failed Items"), @"arrow.clockwise", @NO, ^{ [weak retry:r failedOnly:YES quiet:NO]; }]];
        [acts addObject:@[TPL(@"Download Again"), @"arrow.down.circle", @NO, ^{ [weak retry:r failedOnly:NO quiet:NO]; }]];
        [acts addObject:@[TPL(@"Delete Record"), @"trash", @YES, ^{ [TPDownloadStore removeRecord:r[@"id"]]; }]];
    }
    return acts;
}

- (UIMenu *)menuFor:(NSDictionary *)r section:(TPDMSection)sec {
    NSMutableArray *normal = [NSMutableArray array], *danger = [NSMutableArray array];
    for (NSArray *a in [self actionsFor:r section:sec]) {
        void (^block)(void) = a[3];
        UIAction *x = [UIAction actionWithTitle:a[0] image:[UIImage systemImageNamed:a[1]] identifier:nil handler:^(UIAction *u) { block(); }];
        if ([a[2] boolValue]) { x.attributes = UIMenuElementAttributesDestructive; [danger addObject:x]; }
        else [normal addObject:x];
    }
    if (danger.count) [normal addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:danger]];
    return [UIMenu menuWithTitle:TPDMTitle(r) children:normal];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    TPDMSection sec = [self secAt:ip.section];
    if (sec == TPDMSecLibrary) { [self.navigationController pushViewController:[TPDMLibraryViewController new] animated:YES]; return; }
    NSDictionary *r = [self rowsAt:ip.section][ip.row];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:TPDMTitle(r) message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray *x in [self actionsFor:r section:sec]) {
        void (^block)(void) = x[3];
        [a addAction:[UIAlertAction actionWithTitle:x[0] style:[x[2] boolValue] ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *u) { block(); }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    UIView *cell = [tv cellForRowAtIndexPath:ip];
    a.popoverPresentationController.sourceView = cell ?: self.view;
    a.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), 100, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    TPDMSection sec = [self secAt:ip.section];
    if (sec == TPDMSecLibrary) return nil;
    NSDictionary *r = [self rowsAt:ip.section][ip.row];
    __weak typeof(self) weak = self;
    NSMutableArray *acts = [NSMutableArray array];
    if (sec == TPDMSecActive) {
        [acts addObject:[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:TPL(@"Cancel")
                                                               handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) { [TPDownloader cancelRecord:r[@"id"]]; done(YES); }]];
    } else if (sec == TPDMSecQueue) {
        [acts addObject:[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:TPL(@"Remove from Queue")
                                                               handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) { [TPDownloader removeQueuedRecord:r[@"id"]]; done(YES); }]];
    } else {
        [acts addObject:[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:TPL(@"Delete")
                                                               handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) { [TPDownloadStore removeRecord:r[@"id"]]; done(YES); }]];
        if (sec == TPDMSecFailed) {
            UIContextualAction *retry = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:TPL(@"Retry")
                                                                               handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) { [weak retry:r failedOnly:YES quiet:NO]; done(YES); }];
            retry.backgroundColor = [TPUI accent];
            [acts addObject:retry];
        }
    }
    return [UISwipeActionsConfiguration configurationWithActions:acts];
}

- (BOOL)tableView:(UITableView *)tv canMoveRowAtIndexPath:(NSIndexPath *)ip { return [self secAt:ip.section] == TPDMSecQueue; }
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return [self secAt:ip.section] != TPDMSecLibrary; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return _reordering ? UITableViewCellEditingStyleNone : UITableViewCellEditingStyleDelete;
}
- (BOOL)tableView:(UITableView *)tv shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)ip { return NO; }
- (NSIndexPath *)tableView:(UITableView *)tv targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from toProposedIndexPath:(NSIndexPath *)to {
    if (to.section != from.section) {
        NSInteger last = (NSInteger)_queue.count - 1;
        return [NSIndexPath indexPathForRow:to.section < from.section ? 0 : last inSection:from.section];
    }
    return to;
}
- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    _moving = YES;
    [TPDownloader moveQueuedRecordFrom:from.row to:to.row];
    _moving = NO;
    NSMutableArray *q = [_queue mutableCopy];
    id x = q[from.row];
    [q removeObjectAtIndex:from.row];
    [q insertObject:x atIndex:to.row];
    _queue = q;
}

@end
