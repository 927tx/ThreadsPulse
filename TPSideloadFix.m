// Sideload Compatibility Fix.
//
// Threads is signed by Meta (team MH9GU9K5PX) with keychain groups MH9GU9K5PX.platformFamily /
// .shared and app groups such as group.com.facebook.family. After re-signing those groups no
// longer match: keychain calls fail with errSecMissingEntitlement, so the login can't be stored,
// and app group containers come back nil.
//
// SecItem* calls in the app's own images are rebound to wrappers that swap the requested access
// group for the one the system actually assigned. App group containers and group
// NSUserDefaults suites are redirected into Library/ThreadsPulseAppGroups/<group>.
// Nothing is changed when the app still carries Meta's signature.

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <pthread.h>
#import "TPPrefs.h"
#import "TPSideloadFix.h"

static NSString *const kTPOriginalTeam = @"MH9GU9K5PX";

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef);

static NSString *gTPAccessGroup;
static NSString *gTPFixStatus;

static volatile int32_t gTPCalls, gTPRewrites, gTPErrors;
static OSStatus gTPLastError;
static char gTPLastErrorWhere[96];

static void TPRecord(const char *op, CFDictionaryRef query, BOOL rewritten, OSStatus s) {
    __sync_fetch_and_add(&gTPCalls, 1);
    if (rewritten) __sync_fetch_and_add(&gTPRewrites, 1);
    if (s == errSecSuccess || s == errSecItemNotFound) return;
    __sync_fetch_and_add(&gTPErrors, 1);
    gTPLastError = s;
    char group[64] = "-";
    CFTypeRef g = query ? CFDictionaryGetValue(query, kSecAttrAccessGroup) : NULL;
    if (g && CFGetTypeID(g) == CFStringGetTypeID()) CFStringGetCString(g, group, sizeof(group), kCFStringEncodingUTF8);
    snprintf(gTPLastErrorWhere, sizeof(gTPLastErrorWhere), "%s %s", op, group);
}

NSString *TPSideloadFixStats(void) {
    NSMutableString *r = [NSMutableString stringWithFormat:@"calls %d · rewrites %d · errors %d", gTPCalls, gTPRewrites, gTPErrors];
    if (gTPErrors) [r appendFormat:@" (last %d: %s)", (int)gTPLastError, gTPLastErrorWhere];
    return r;
}

static NSString *TPResolveAccessGroup(void);
static BOOL gTPNativeSignature;

// com.apple.* groups are left alone. If the usable group can't be resolved yet, the foreign
// group is removed so the item lands in the default group instead of failing.
static CFDictionaryRef TPFixQuery(CFDictionaryRef query, CFMutableDictionaryRef *owned) {
    *owned = NULL;
    if (!query) return query;
    CFTypeRef group = CFDictionaryGetValue(query, kSecAttrAccessGroup);
    if (!group || CFGetTypeID(group) != CFStringGetTypeID()) return query;
    if (CFStringHasPrefix(group, CFSTR("com.apple."))) return query;
    NSString *ours = TPResolveAccessGroup();
    if (!ours && gTPNativeSignature) return query;
    if (ours && CFEqual(group, (__bridge CFStringRef)ours)) return query;
    CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    if (ours) CFDictionarySetValue(copy, kSecAttrAccessGroup, (__bridge CFStringRef)ours);
    else CFDictionaryRemoveValue(copy, kSecAttrAccessGroup);
    *owned = copy;
    return copy;
}

static OSStatus tp_SecItemAdd(CFDictionaryRef attrs, CFTypeRef *result) {
    CFMutableDictionaryRef owned;
    OSStatus s = orig_SecItemAdd(TPFixQuery(attrs, &owned), result);
    TPRecord("Add", attrs, owned != NULL, s);
    if (owned) CFRelease(owned);
    return s;
}

static OSStatus tp_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    CFMutableDictionaryRef owned;
    OSStatus s = orig_SecItemCopyMatching(TPFixQuery(query, &owned), result);
    TPRecord("Copy", query, owned != NULL, s);
    if (owned) CFRelease(owned);
    return s;
}

static OSStatus tp_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attrs) {
    CFMutableDictionaryRef owned1, owned2;
    OSStatus s = orig_SecItemUpdate(TPFixQuery(query, &owned1), TPFixQuery(attrs, &owned2));
    TPRecord("Update", query, owned1 != NULL || owned2 != NULL, s);
    if (owned1) CFRelease(owned1);
    if (owned2) CFRelease(owned2);
    return s;
}

static OSStatus tp_SecItemDelete(CFDictionaryRef query) {
    CFMutableDictionaryRef owned;
    OSStatus s = orig_SecItemDelete(TPFixQuery(query, &owned));
    TPRecord("Delete", query, owned != NULL, s);
    if (owned) CFRelease(owned);
    return s;
}

// The usable group is read back from a probe item. The probe is AfterFirstUnlock: with the
// default accessibility it can't be read while the device is locked, e.g. when the app is
// woken in the background, and the whole launch would run without a group.
static NSString *TPDetectAccessGroup(void) {
    NSDictionary *common = @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                              (__bridge id)kSecAttrAccount: @"ThreadsPulse.accessGroupProbe.afu",
                              (__bridge id)kSecAttrService: @"ThreadsPulse",
                              (__bridge id)kSecReturnAttributes: @YES };
    NSMutableDictionary *search = [common mutableCopy];
    search[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus s = orig_SecItemCopyMatching((__bridge CFDictionaryRef)search, &result);
    if (s == errSecItemNotFound) {
        NSMutableDictionary *add = [common mutableCopy];
        add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        add[(__bridge id)kSecValueData] = [NSData data];
        s = orig_SecItemAdd((__bridge CFDictionaryRef)add, &result);
    }
    if (s != errSecSuccess || !result) { if (result) CFRelease(result); return nil; }
    NSDictionary *attrs = (__bridge_transfer NSDictionary *)result;
    id group = [attrs isKindOfClass:[NSDictionary class]] ? attrs[(__bridge id)kSecAttrAccessGroup] : nil;
    return [group isKindOfClass:[NSString class]] ? group : nil;
}

// Cached only on success, so a failed attempt (device locked) is retried on the next call.
static NSString *TPResolveAccessGroup(void) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    if (gTPAccessGroup || gTPNativeSignature) return gTPAccessGroup;
    pthread_mutex_lock(&lock);
    if (!gTPAccessGroup && !gTPNativeSignature) {
        NSString *group = TPDetectAccessGroup();
        NSString *team = [group componentsSeparatedByString:@"."].firstObject;
        if (group.length && team.length) {
            if ([team isEqualToString:kTPOriginalTeam]) { gTPNativeSignature = YES; gTPFixStatus = @"original signature, not needed"; }
            else {
                gTPAccessGroup = [group copy];
                gTPFixStatus = [NSString stringWithFormat:@"active (%@)%@", team, gTPFixStatus.length && [gTPFixStatus hasSuffix:@"+defaults"] ? @" +defaults" : @""];
            }
        }
    }
    pthread_mutex_unlock(&lock);
    return gTPAccessGroup;
}

typedef struct { const char *name; void *replacement; } TPRebinding;
static TPRebinding gTPRebindings[8];
static size_t gTPRebindingCount;
static char *gTPAppPath;

// Symbol pointers in __DATA_CONST / __AUTH_CONST are read-only and are made writable only for
// the duration of the write.
static void TPRebindSection(const struct section_64 *sect, intptr_t slide, BOOL readOnly,
                            const struct nlist_64 *symtab, const char *strtab, const uint32_t *indirect) {
    uint32_t *indices = (uint32_t *)indirect + sect->reserved1;
    void **slots = (void **)((uintptr_t)slide + sect->addr);
    size_t count = sect->size / sizeof(void *);
    for (size_t i = 0; i < count; i++) {
        uint32_t idx = indices[i];
        if (idx == INDIRECT_SYMBOL_ABS || idx == INDIRECT_SYMBOL_LOCAL ||
            idx == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
        const char *name = strtab + symtab[idx].n_un.n_strx;
        if (name[0] != '_') continue;
        for (size_t r = 0; r < gTPRebindingCount; r++) {
            if (strcmp(name + 1, gTPRebindings[r].name) != 0) continue;
            if (slots[i] == gTPRebindings[r].replacement) break;
            if (!readOnly) { slots[i] = gTPRebindings[r].replacement; break; }
            vm_address_t page = (vm_address_t)&slots[i] & ~(vm_address_t)(PAGE_SIZE - 1);
            if (vm_protect(mach_task_self(), page, PAGE_SIZE, false,
                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) break;
            slots[i] = gTPRebindings[r].replacement;
            vm_protect(mach_task_self(), page, PAGE_SIZE, false, VM_PROT_READ);
            break;
        }
    }
}

static void TPRebindImage(const struct mach_header *header, intptr_t slide) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)header;
    if (mh->magic != MH_MAGIC_64) return;

    static const void *selfBase;
    if (!selfBase) { Dl_info me; if (dladdr((void *)TPRebindImage, &me)) selfBase = me.dli_fbase; }
    if ((const void *)mh == selfBase) return;
    Dl_info info;
    if (!gTPAppPath || !dladdr(mh, &info) || !info.dli_fname ||
        !strstr(info.dli_fname, gTPAppPath)) return;

    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtabCmd = NULL;
    const struct dysymtab_command *dysymtabCmd = NULL;
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT) == 0)
            linkedit = (const struct segment_command_64 *)lc;
        else if (lc->cmd == LC_SYMTAB) symtabCmd = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dysymtabCmd = (const struct dysymtab_command *)lc;
    }
    if (!linkedit || !symtabCmd || !dysymtabCmd || !dysymtabCmd->nindirectsyms) return;

    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symtab = (const struct nlist_64 *)(base + symtabCmd->symoff);
    const char *strtab = (const char *)(base + symtabCmd->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtabCmd->indirectsymoff);

    lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strncmp(seg->segname, "__DATA", 6) != 0 && strncmp(seg->segname, "__AUTH", 6) != 0) continue;
        BOOL readOnly = strstr(seg->segname, "_CONST") != NULL;
        const struct section_64 *sect = (const struct section_64 *)(seg + 1);
        for (uint32_t j = 0; j < seg->nsects; j++, sect++) {
            uint32_t type = sect->flags & SECTION_TYPE;
            if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS)
                TPRebindSection(sect, slide, readOnly, symtab, strtab, indirect);
        }
    }
}

// Points calls to C functions from the app's own images (main executable and Frameworks) at
// replacements. Can be called more than once; each call rebinds the images already loaded and
// those loaded later.
void TPRebindSymbols(const char **names, void **replacements, size_t count) {
    if (!gTPAppPath)
        gTPAppPath = strdup([NSString stringWithFormat:@"/%@/", NSBundle.mainBundle.bundlePath.lastPathComponent].fileSystemRepresentation);
    for (size_t i = 0; i < count && gTPRebindingCount < sizeof(gTPRebindings) / sizeof(gTPRebindings[0]); i++)
        gTPRebindings[gTPRebindingCount++] = (TPRebinding){ names[i], replacements[i] };
    static BOOL registered;
    if (!registered) { registered = YES; _dyld_register_func_for_add_image(TPRebindImage); return; }
    for (uint32_t i = 0; i < _dyld_image_count(); i++) TPRebindImage(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
}

static IMP orig_containerURL;

static NSURL *tp_containerURL(id self, SEL _cmd, NSString *group) {
    NSURL *url = ((NSURL *(*)(id, SEL, NSString *))orig_containerURL)(self, _cmd, group);
    if (url || ![group isKindOfClass:[NSString class]] || !group.length) return url;
    NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/ThreadsPulseAppGroups"]
                      stringByAppendingPathComponent:group];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

// Group NSUserDefaults suites can't be written without the entitlement, so they read back
// empty after a relaunch. Multi-account state stored there then no longer matches the keychain,
// which is the likely cause of multi-account users being logged out at launch. The private
// _initWithSuiteName:container: initializer is redirected to the same replacement folder.
static IMP orig_initSuite;

static id tp_initSuite(id self, SEL _cmd, NSString *suite, NSURL *container) {
    if (!container && [suite isKindOfClass:[NSString class]] && [suite hasPrefix:@"group."] && orig_containerURL) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURL *real = ((NSURL *(*)(id, SEL, NSString *))orig_containerURL)(fm, @selector(containerURLForSecurityApplicationGroupIdentifier:), suite);
        if (!real) {
            container = tp_containerURL(fm, @selector(containerURLForSecurityApplicationGroupIdentifier:), suite);
            NSString *prefs = [container.path stringByAppendingPathComponent:@"Library/Preferences"];
            if (![fm createDirectoryAtPath:prefs withIntermediateDirectories:YES attributes:nil error:nil]) container = nil;
        }
    }
    return ((id (*)(id, SEL, NSString *, NSURL *))orig_initSuite)(self, _cmd, suite, container);
}

NSString *TPSideloadFixStatus(void) { return gTPFixStatus; }

void TPSideloadFixInstall(void) {
    if (![TPPrefs boolForKey:TPKeySideloadFix]) { gTPFixStatus = @"off"; return; }

    orig_SecItemAdd          = dlsym(RTLD_DEFAULT, "SecItemAdd");
    orig_SecItemCopyMatching = dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    orig_SecItemUpdate       = dlsym(RTLD_DEFAULT, "SecItemUpdate");
    orig_SecItemDelete       = dlsym(RTLD_DEFAULT, "SecItemDelete");
    if (!orig_SecItemAdd || !orig_SecItemCopyMatching || !orig_SecItemUpdate || !orig_SecItemDelete) {
        gTPFixStatus = @"Security functions not found";
        return;
    }

    TPResolveAccessGroup();
    if (gTPNativeSignature) return;

    TPRebindSymbols((const char *[]){ "SecItemAdd", "SecItemCopyMatching", "SecItemUpdate", "SecItemDelete" },
                    (void *[]){ (void *)tp_SecItemAdd, (void *)tp_SecItemCopyMatching, (void *)tp_SecItemUpdate, (void *)tp_SecItemDelete }, 4);

    Method m = class_getInstanceMethod([NSFileManager class], @selector(containerURLForSecurityApplicationGroupIdentifier:));
    if (m) orig_containerURL = method_setImplementation(m, (IMP)tp_containerURL);
    Method d = class_getInstanceMethod([NSUserDefaults class], NSSelectorFromString(@"_initWithSuiteName:container:"));
    if (d && orig_containerURL) orig_initSuite = method_setImplementation(d, (IMP)tp_initSuite);

    NSString *team = [gTPAccessGroup componentsSeparatedByString:@"."].firstObject;
    gTPFixStatus = [NSString stringWithFormat:@"active (%@) +defaults", team ?: @"group pending"];
    if (!orig_initSuite) gTPFixStatus = [gTPFixStatus stringByReplacingOccurrencesOfString:@" +defaults" withString:@""];
}
