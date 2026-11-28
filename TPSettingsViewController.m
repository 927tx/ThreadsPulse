#import "TPSettingsViewController.h"
#import <objc/runtime.h>
#import "TPPrefs.h"
#import "TPDownloader.h"
#import "TPLocalization.h"
#import "TPHUD.h"
#import "TPUI.h"
#import "TPWelcomeViewController.h"
#import "TPAuthorInfo.h"
#import "TPAuthorStatsViewController.h"
#import "TPUpdateChecker.h"
#import "TPDownloadManager.h"
#import <SafariServices/SafariServices.h>
#import <sys/sysctl.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "TPVersion.h"

extern NSString *TPAnalyticsLogReport(void);
static NSString *const kTPDonateURL = @"https://ko-fi.com/mumuisdog";
static NSString *const kTPRepoURL   = @"https://github.com/mumuisdog/ThreadsPulse";
static NSArray<NSArray<NSString *> *> *TPAboutRows(void);

static UIColor *TPDyn(UIColor *light, UIColor *dark) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
}
static UIColor *TPPageColor(void) { return [TPUI pageColor]; }
static UIColor *TPCardColor(void) { return [TPUI cardColor]; }
static UIColor *TPHairlineColor(void) {
    return TPDyn([UIColor colorWithWhite:0 alpha:0.08], [UIColor colorWithWhite:1 alpha:0.10]);
}
static UIColor *TPKofiColor(void) {
    return [UIColor colorWithRed:1.00 green:0.37 blue:0.36 alpha:1];
}
static NSString *sTPCacheSize;   // last measured cache size, shown on the Clear Cache row
static UIColor *TPAccent(void) { return [TPUI accent]; }
static UIColor *TPAccentIcon(void) { return [TPUI accentIcon]; }

static UIImage *TPLineIcon(NSString *symbol) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightRegular];
    return [UIImage systemImageNamed:symbol withConfiguration:cfg] ?: [UIImage systemImageNamed:@"circle" withConfiguration:cfg];
}

static void TPApplyIcon(UIListContentConfiguration *c, NSString *symbol, UIColor *tint) {
    c.image = TPLineIcon(symbol);
    c.imageProperties.tintColor = tint ?: TPAccentIcon();
    c.imageProperties.reservedLayoutSize = CGSizeMake(26, 26);
    c.imageToTextPadding = 12;
}

static void TPApplyCardBackground(UITableViewCell *cell) {
    UIBackgroundConfiguration *bg = [UIBackgroundConfiguration listGroupedCellConfiguration];
    bg.backgroundColor = TPCardColor();
    cell.backgroundConfiguration = bg;
}

// What a post from 3 hours ago looks like in the current Post Time Format.
static NSString *TPPostTimeExample(void) {
    NSDate *sample = [NSDate dateWithTimeIntervalSinceNow:-3 * 3600 - 17 * 60 - 42];
    return [TPPrefs postTimeForDate:sample relative:TPL(@"3h")] ?: TPL(@"3h");
}

@interface TPSettingsHeaderView : UIView
- (void)setEnabledCount:(NSInteger)count;
@property (nonatomic, copy) void (^onThemeChange)(void);
@property (nonatomic, copy) void (^onLanguageChange)(void);
@end

@implementation TPSettingsHeaderView {
    UIView *_card;
    CAGradientLayer *_gradient;
    UIView *_badge;
    UIImageView *_glyph;
    UILabel *_title;
    UILabel *_subtitle;
    UIView *_dot;
    UIView *_sep;
    NSArray<UILabel *> *_statLabels;
    NSArray<UILabel *> *_statValues;
    UIView *_statDivider;
    UIView *_sep1;
    UILabel *_themeLabel;
    NSArray<UIButton *> *_swatches;
    UIView *_sep2;
    UILabel *_langLabel;
    UIButton *_langButton;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        UIColor *accent = TPAccent();
        _card = [UIView new];
        _card.layer.cornerRadius = 18;
        _card.layer.cornerCurve = kCACornerCurveContinuous;
        _card.layer.borderWidth = 1;
        _card.layer.borderColor = [accent colorWithAlphaComponent:0.35].CGColor;
        _card.clipsToBounds = YES;
        _gradient = [CAGradientLayer layer];
        _gradient.colors = @[(id)[accent colorWithAlphaComponent:0.28].CGColor, (id)[accent colorWithAlphaComponent:0.07].CGColor];
        _gradient.startPoint = CGPointMake(0, 0);
        _gradient.endPoint = CGPointMake(1, 1);
        [_card.layer addSublayer:_gradient];
        [self addSubview:_card];

        _badge = [UIView new];
        _badge.backgroundColor = accent;
        _badge.layer.cornerRadius = 12;
        _badge.layer.cornerCurve = kCACornerCurveContinuous;
        [_card addSubview:_badge];

        _glyph = [[UIImageView alloc] initWithImage:
                  [UIImage systemImageNamed:@"waveform.path.ecg"
                          withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightSemibold]]];
        _glyph.tintColor = UIColor.whiteColor;
        _glyph.contentMode = UIViewContentModeCenter;
        [_badge addSubview:_glyph];

        _title = [UILabel new];
        NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:@"ThreadsPulse"
            attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:18 weight:UIFontWeightBold], NSForegroundColorAttributeName: UIColor.labelColor }];
        [t appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:TP_VERSION]
            attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightMedium], NSForegroundColorAttributeName: TPAccentIcon() }]];
        _title.attributedText = t;
        [_card addSubview:_title];

        _dot = [UIView new];
        _dot.backgroundColor = UIColor.systemGreenColor;
        _dot.layer.cornerRadius = 3.5;
        [_card addSubview:_dot];

        _subtitle = [UILabel new];
        _subtitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        _subtitle.textColor = UIColor.secondaryLabelColor;
        [_card addSubview:_subtitle];

        _sep = [UIView new];
        _sep.backgroundColor = [accent colorWithAlphaComponent:0.30];
        [_card addSubview:_sep];

        // Today's numbers: ads kept out of the feed and replies ("Off" while ad blocking is off),
        // and posts hidden by the muted rules.
        BOOL blocking = [TPPrefs boolForKey:TPKeyBlockAds];
        NSArray *stats = @[ @[TPL(@"Ads blocked today"), blocking ? [NSString stringWithFormat:@"%ld", (long)[TPPrefs blockedAdsToday]] : TPL(@"Off")],
                            @[TPL(@"Posts hidden today"), [NSString stringWithFormat:@"%ld", (long)[[TPPrefs filterStatsToday][@"count"] integerValue]]] ];
        NSMutableArray *labels = [NSMutableArray array], *values = [NSMutableArray array];
        for (NSUInteger i = 0; i < stats.count; i++) {
            UILabel *k = [UILabel new];
            k.text = stats[i][0];
            k.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
            k.textColor = UIColor.secondaryLabelColor;
            k.adjustsFontSizeToFitWidth = YES;
            k.minimumScaleFactor = 0.75;
            [_card addSubview:k];
            UILabel *v = [UILabel new];
            v.text = stats[i][1];
            BOOL off = i == 0 && !blocking;
            v.font = off ? [UIFont systemFontOfSize:15 weight:UIFontWeightMedium] : [UIFont monospacedDigitSystemFontOfSize:19 weight:UIFontWeightBold];
            v.textColor = off ? UIColor.secondaryLabelColor : UIColor.labelColor;
            [_card addSubview:v];
            [labels addObject:k];
            [values addObject:v];
        }
        _statLabels = labels;
        _statValues = values;
        _statDivider = [UIView new];
        _statDivider.backgroundColor = [accent colorWithAlphaComponent:0.30];
        [_card addSubview:_statDivider];
        _sep1 = [UIView new];
        _sep1.backgroundColor = [accent colorWithAlphaComponent:0.30];
        [_card addSubview:_sep1];
        _themeLabel = [UILabel new];
        _themeLabel.text = TPL(@"Theme");
        _themeLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        _themeLabel.textColor = UIColor.secondaryLabelColor;
        [_card addSubview:_themeLabel];
        NSInteger cur = [TPPrefs integerForKey:TPKeyTheme];
        NSMutableArray *sw = [NSMutableArray array];
        __weak typeof(self) weakSelf = self;
        for (NSInteger i = 0; i < [TPUI themeCount]; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.backgroundColor = [TPUI themeColorAtIndex:i];
            b.layer.cornerRadius = 12;
            b.accessibilityLabel = TPL([TPUI themeNameAtIndex:i]);
            if (i == cur) {
                b.layer.borderWidth = 2;
                b.layer.borderColor = UIColor.labelColor.CGColor;
                [b setImage:[[UIImage systemImageNamed:@"checkmark"
                                      withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightBold]]
                             imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal]
                   forState:UIControlStateNormal];
            }
            [b addAction:[UIAction actionWithHandler:^(UIAction *a) {
                if ([TPPrefs integerForKey:TPKeyTheme] == i) return;
                [TPPrefs setInteger:i forKey:TPKeyTheme];
                [TPUI hapticLight];
                [[NSNotificationCenter defaultCenter] postNotificationName:TPThemeDidChangeNotification object:nil];
                if (weakSelf.onThemeChange) weakSelf.onThemeChange();
            }] forControlEvents:UIControlEventTouchUpInside];
            [_card addSubview:b];
            [sw addObject:b];
        }
        _swatches = sw;

        // Language: follow the system, or force English / Traditional Chinese.
        _sep2 = [UIView new];
        _sep2.backgroundColor = [accent colorWithAlphaComponent:0.30];
        [_card addSubview:_sep2];
        _langLabel = [UILabel new];
        _langLabel.text = TPL(@"Language");
        _langLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        _langLabel.textColor = UIColor.secondaryLabelColor;
        [_card addSubview:_langLabel];
        // Each language is listed in its own script so anyone can find theirs.
        NSArray<NSString *> *names = @[TPL(@"Follow System"), @"English", @"繁體中文", @"简体中文", @"日本語", @"한국어", @"Tiếng Việt"];
        NSInteger curLang = [TPPrefs integerForKey:TPKeyLanguage];
        if (curLang < 0 || curLang >= (NSInteger)names.count) curLang = 0;
        UIButtonConfiguration *c = [UIButtonConfiguration plainButtonConfiguration];
        c.image = [UIImage systemImageNamed:@"chevron.up.chevron.down"
                          withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightSemibold]];
        c.imagePlacement = NSDirectionalRectEdgeTrailing;
        c.imagePadding = 5;
        c.contentInsets = NSDirectionalEdgeInsetsMake(6, 6, 6, 0);
        c.attributedTitle = [[NSAttributedString alloc] initWithString:names[curLang] attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightMedium] }];
        _langButton = [UIButton buttonWithConfiguration:c primaryAction:nil];
        _langButton.tintColor = TPAccentIcon();
        _langButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentTrailing;
        NSMutableArray *acts = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
            UIAction *a = [UIAction actionWithTitle:names[i] image:nil identifier:nil handler:^(UIAction *x) {
                if ([TPPrefs integerForKey:TPKeyLanguage] == i) return;
                [TPPrefs setInteger:i forKey:TPKeyLanguage];
                [TPUI hapticLight];
                if (weakSelf.onLanguageChange) weakSelf.onLanguageChange();
            }];
            if (i == curLang) a.state = UIMenuElementStateOn;
            [acts addObject:a];
        }
        _langButton.menu = [UIMenu menuWithChildren:acts];
        _langButton.showsMenuAsPrimaryAction = YES;
        [_card addSubview:_langButton];
    }
    return self;
}

- (void)setEnabledCount:(NSInteger)count {
    _subtitle.text = [NSString stringWithFormat:TPL(@"Running · %ld features on"), (long)count];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, inset = 16, d = 46;
    _card.frame = CGRectMake(inset, 6, w - inset * 2, self.bounds.size.height - 12);
    _gradient.frame = _card.bounds;
    CGFloat cw = _card.bounds.size.width, h = 80;
    _sep.frame = CGRectMake(14, h, cw - 28, 0.5);
    CGFloat half = (cw - 28) / 2;
    for (NSUInteger i = 0; i < _statLabels.count; i++) {
        CGFloat x0 = 14 + i * half + (i ? 12 : 0);
        _statLabels[i].frame = CGRectMake(x0, h + 7, half - 12, 16);
        _statValues[i].frame = CGRectMake(x0, h + 24, half - 12, 24);
    }
    _statDivider.frame = CGRectMake(14 + half, h + 10, 0.5, 34);
    _sep1.frame = CGRectMake(14, h + 54, cw - 28, 0.5);
    CGFloat t = h + 54;   // theme row
    CGFloat sd = 24, gap = 10, sx = cw - 14 - (sd * _swatches.count + gap * (_swatches.count - 1));
    _themeLabel.frame = CGRectMake(14, t + 1, MAX(0, sx - 22), 43);
    for (NSUInteger i = 0; i < _swatches.count; i++)
        _swatches[i].frame = CGRectMake(sx + i * (sd + gap), t + 1 + (43 - sd) / 2, sd, sd);
    _sep2.frame = CGRectMake(14, t + 44, cw - 28, 0.5);
    _langLabel.frame = CGRectMake(14, t + 45, cw / 2 - 14, 43);
    _langButton.frame = CGRectMake(cw / 2, t + 45, cw / 2 - 14, 43);
    _badge.frame = CGRectMake(14, (h - d) / 2, d, d);
    _glyph.frame = _badge.bounds;
    CGFloat x = CGRectGetMaxX(_badge.frame) + 12, tw = _card.bounds.size.width - x - 14;
    _title.frame = CGRectMake(x, h / 2 - 23, tw, 24);
    _dot.frame = CGRectMake(x, h / 2 + 8, 7, 7);
    _subtitle.frame = CGRectMake(x + 13, h / 2 + 2, tw - 13, 18);
}
@end

static BOOL TPConditionMet(NSArray *cond);

@interface TPMutedKeywordsViewController : UITableViewController
@end

// "File Name Format": which parts make up a saved file's name, their order, the separator and
// the date style, with a live preview at the top.
@interface TPFileNameFormatViewController : UITableViewController
@end

@interface TPCacheCleanerViewController : UITableViewController
@end

@interface TPPostTimeFormatViewController : UITableViewController
@end

// A preview that stays at the top of a format page while the options below it scroll, so a
// change made further down can be seen right away.
@interface TPPinnedPreview : UIView
@property (nonatomic, readonly) UILabel *textLabel;
@property (nonatomic, readonly) UILabel *captionLabel;   // "Preview" unless changed
+ (instancetype)attachTo:(UITableView *)tv font:(UIFont *)font;
- (void)follow:(UIScrollView *)sv;
@end

@implementation TPPinnedPreview {
    UIView *_box;
}
static const CGFloat kTPPinHeight = 92;

+ (instancetype)attachTo:(UITableView *)tv font:(UIFont *)font {
    TPPinnedPreview *v = [[TPPinnedPreview alloc] initWithFrame:CGRectMake(0, 0, tv.bounds.size.width, kTPPinHeight)];
    v.textLabel.font = font;
    v.layer.zPosition = 100;
    [tv addSubview:v];
    UIEdgeInsets in = tv.contentInset;
    in.top += kTPPinHeight;
    tv.contentInset = in;
    UIEdgeInsets si = tv.verticalScrollIndicatorInsets;
    si.top += kTPPinHeight;
    tv.verticalScrollIndicatorInsets = si;
    return v;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [TPUI pageColor];
        _captionLabel = [UILabel new];
        _captionLabel.text = TPL(@"Preview");
        _captionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _captionLabel.textColor = UIColor.secondaryLabelColor;
        [self addSubview:_captionLabel];
        _box = [UIView new];
        _box.backgroundColor = TPCardColor();
        _box.layer.cornerRadius = 12;
        _box.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:_box];
        _textLabel = [UILabel new];
        _textLabel.numberOfLines = 2;
        _textLabel.adjustsFontSizeToFitWidth = YES;
        _textLabel.minimumScaleFactor = 0.7;
        _textLabel.lineBreakMode = NSLineBreakByCharWrapping;
        [_box addSubview:_textLabel];
    }
    return self;
}

- (void)follow:(UIScrollView *)sv {
    self.frame = CGRectMake(0, sv.contentOffset.y + sv.adjustedContentInset.top - kTPPinHeight, sv.bounds.size.width, kTPPinHeight);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, x = MAX(16, self.layoutMargins.left);
    _captionLabel.frame = CGRectMake(x + 4, 8, w - 2 * x, 18);
    _box.frame = CGRectMake(x, 30, w - 2 * x, kTPPinHeight - 38);
    _textLabel.frame = CGRectInset(_box.bounds, 14, 6);
}
@end

@implementation TPFileNameFormatViewController {
    NSMutableArray<NSMutableDictionary *> *_parts;
    TPPinnedPreview *_pin;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = TPL(@"File Name Format");
    self.tableView.backgroundColor = [TPUI pageColor];
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = YES;
    _pin = [TPPinnedPreview attachTo:self.tableView font:[UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular]];
    [self loadParts];
    [self reloadPreview];
}

- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [_pin follow:self.tableView]; }
- (void)scrollViewDidScroll:(UIScrollView *)sv { [_pin follow:sv]; }

- (void)loadParts {
    _parts = [NSMutableArray array];
    for (NSDictionary *p in [TPDownloader fileNameParts]) [_parts addObject:[p mutableCopy]];
}

- (void)saveParts {
    [TPDownloader setFileNameParts:_parts];
    [self reloadPreview];
}

- (void)reloadPreview {
    _pin.textLabel.text = [TPDownloader fileNameWithAuthor:@"threads.user" country:TPL(@"Taiwan") date:NSDate.date code:@"DMx7Qk2Lp9A"
                                                     index:0 count:2 label:nil extension:@"jpg"];
}

static NSString *TPNamePartTitle(NSString *ident) {
    NSDictionary *t = @{ @"author": @"@Author", @"date": @"Post Date", @"time": @"Post Time", @"code": @"Post Code",
                         @"index": @"Number", @"country": @"Country", @"threads": @"\"Threads\"" };
    return TPL(t[ident] ?: ident);
}
static NSString *TPNamePartDetail(NSString *ident) {
    if ([ident isEqualToString:@"index"]) return TPL(@"Only when a post has more than one file");
    if ([ident isEqualToString:@"country"]) return TPL(@"Only when Author Info has already read it");
    return nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 5; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 0;   // the preview is pinned above the list
    return section == 1 ? (NSInteger)_parts.count : 1;
}
// The empty first section takes no room, so the list starts right under the pinned preview.
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)section { return section == 0 ? CGFLOAT_MIN : UITableViewAutomaticDimension; }
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)section { return section == 0 ? CGFLOAT_MIN : UITableViewAutomaticDimension; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 1: return TPL(@"Parts");
        case 2: return TPL(@"Separator");
        case 3: return TPL(@"Date Format");
    }
    return nil;
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == 1) return TPL(@"Tap a part to turn it on or off, and drag ≡ to change the order.");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    if (ip.section == 1) {
        NSDictionary *p = _parts[ip.row];
        BOOL on = [p[@"on"] boolValue];
        c.text = TPNamePartTitle(p[@"id"]);
        c.secondaryText = TPNamePartDetail(p[@"id"]);
        c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        c.textProperties.color = on ? UIColor.labelColor : UIColor.secondaryLabelColor;
        c.image = [UIImage systemImageNamed:on ? @"checkmark.circle.fill" : @"circle"];
        c.imageProperties.tintColor = on ? TPAccent() : UIColor.tertiaryLabelColor;
    } else if (ip.section == 2 || ip.section == 3) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        NSArray *items = ip.section == 2 ? @[@"_", @"-", TPL(@"Space")] : @[@"20261126", @"2026-11-26"];
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:items];
        seg.selectedSegmentIndex = [TPPrefs integerForKey:ip.section == 2 ? TPKeyNameSeparator : TPKeyNameDateStyle];
        seg.tag = ip.section;
        [seg addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
        seg.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:seg];
        [NSLayoutConstraint activateConstraints:@[
            [seg.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [seg.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [seg.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [seg.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
        ]];
        return cell;
    } else {
        c.text = TPL(@"Reset to Default");
        c.textProperties.color = TPAccent();
        c.textProperties.alignment = UIListContentTextAlignmentCenter;
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)segmentChanged:(UISegmentedControl *)seg {
    [TPPrefs setInteger:seg.selectedSegmentIndex forKey:seg.tag == 2 ? TPKeyNameSeparator : TPKeyNameDateStyle];
    [self reloadPreview];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 1; }
- (BOOL)tableView:(UITableView *)tv canMoveRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 1; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip { return UITableViewCellEditingStyleNone; }
- (BOOL)tableView:(UITableView *)tv shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)ip { return NO; }
- (NSIndexPath *)tableView:(UITableView *)tv targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from toProposedIndexPath:(NSIndexPath *)to {
    if (to.section < 1) return [NSIndexPath indexPathForRow:0 inSection:1];
    if (to.section > 1) return [NSIndexPath indexPathForRow:(NSInteger)_parts.count - 1 inSection:1];
    return to;
}
- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSMutableDictionary *p = _parts[from.row];
    [_parts removeObjectAtIndex:from.row];
    [_parts insertObject:p atIndex:to.row];
    dispatch_async(dispatch_get_main_queue(), ^{ [self saveParts]; });
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) {
        NSMutableDictionary *p = _parts[ip.row];
        p[@"on"] = @(![p[@"on"] boolValue]);
        [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        [self saveParts];
    } else if (ip.section == 4) {
        [TPDownloader setFileNameParts:nil];
        [TPPrefs setInteger:0 forKey:TPKeyNameSeparator];
        [TPPrefs setInteger:0 forKey:TPKeyNameDateStyle];
        [self loadParts];
        [tv reloadData];
        [self reloadPreview];
    }
}
@end

// Post Time Format: the parts of a post's time, each turned on or off and dragged into order,
// with the separator, when to show the year and whether to show seconds.
@implementation TPPostTimeFormatViewController {
    NSMutableArray<NSMutableDictionary *> *_parts;
    TPPinnedPreview *_pin;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = TPL(@"Post Time Format");
    self.tableView.backgroundColor = [TPUI pageColor];
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = YES;
    _pin = [TPPinnedPreview attachTo:self.tableView font:[UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightRegular]];
    [self loadParts];
    [self reloadPreview];
}

- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [_pin follow:self.tableView]; }
- (void)scrollViewDidScroll:(UIScrollView *)sv { [_pin follow:sv]; }

- (void)loadParts {
    _parts = [NSMutableArray array];
    for (NSDictionary *p in [TPPrefs timeParts]) [_parts addObject:[p mutableCopy]];
}

- (void)saveParts {
    [TPPrefs setTimeParts:_parts];
    [self reloadPreview];
}

- (void)reloadPreview {
    _pin.textLabel.text = TPPostTimeExample();
}

static NSString *TPTimePartTitle(NSString *ident) {
    NSDictionary *t = @{ @"relative": @"Relative Time", @"weekday": @"Weekday", @"date": @"Date", @"time": @"Time" };
    return TPL(t[ident] ?: ident);
}
static NSString *TPTimePartDetail(NSString *ident) {
    if ([ident isEqualToString:@"relative"]) return TPL(@"Threads' own time, like 3h");
    if ([ident isEqualToString:@"date"]) return TPL(@"Right before or after Time, the two are shown together");
    return nil;
}

// Section 0 is empty: the preview is pinned above the list.
enum { kTPTSParts = 1, kTPTSSeparator, kTPTSYear, kTPTSWeekday, kTPTSTime, kTPTSReset, kTPTSCount };

// Today's weekday, short or full, as it shows for the device's language ("週六" / "星期六").
static NSString *TPWeekdaySample(BOOL full) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = NSLocale.currentLocale;
    [f setLocalizedDateFormatFromTemplate:full ? @"EEEE" : @"EEE"];
    return [f stringFromDate:NSDate.date];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return kTPTSCount; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 0;
    return section == kTPTSParts ? (NSInteger)_parts.count : 1;
}
// The empty first section takes no room, so the list starts right under the pinned preview.
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)section { return section == 0 ? CGFLOAT_MIN : UITableViewAutomaticDimension; }
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)section { return section == 0 ? CGFLOAT_MIN : UITableViewAutomaticDimension; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case kTPTSParts: return TPL(@"Parts");
        case kTPTSSeparator: return TPL(@"Separator");
        case kTPTSYear: return TPL(@"Year");
        case kTPTSWeekday: return TPL(@"Weekday");
        case kTPTSTime: return TPL(@"Time");
    }
    return nil;
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == kTPTSParts) return TPL(@"Tap a part to turn it on or off, and drag ≡ to change the order. With only Relative Time on, Threads shows its own time.");
    // Times already on screen were worked out before the change.
    if (section == kTPTSTime) return TPL(@"After a change, reopen Threads to apply it to every post.");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    if (ip.section == kTPTSParts) {
        NSDictionary *p = _parts[ip.row];
        BOOL on = [p[@"on"] boolValue];
        c.text = TPTimePartTitle(p[@"id"]);
        c.secondaryText = TPTimePartDetail(p[@"id"]);
        c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        c.textProperties.color = on ? UIColor.labelColor : UIColor.secondaryLabelColor;
        c.image = [UIImage systemImageNamed:on ? @"checkmark.circle.fill" : @"circle"];
        c.imageProperties.tintColor = on ? TPAccent() : UIColor.tertiaryLabelColor;
    } else if (ip.section >= kTPTSSeparator && ip.section <= kTPTSTime) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        NSArray *items; NSInteger cur;
        switch (ip.section) {
            case kTPTSSeparator: items = @[@"·", @"-", @"|", TPL(@"Space")]; cur = [TPPrefs integerForKey:TPKeyTimeSeparator]; break;
            case kTPTSYear: items = @[TPL(@"Never"), TPL(@"Earlier Years"), TPL(@"Always")]; cur = [TPPrefs integerForKey:TPKeyTimeYear]; break;
            case kTPTSWeekday: items = @[TPWeekdaySample(NO), TPWeekdaySample(YES)]; cur = [TPPrefs boolForKey:TPKeyTimeWeekdayFull] ? 1 : 0; break;
            default: items = @[@"15:59", @"15:59:42"]; cur = [TPPrefs boolForKey:TPKeyTimeSeconds] ? 1 : 0; break;
        }
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:items];
        seg.selectedSegmentIndex = cur;
        seg.tag = ip.section;
        [seg addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
        seg.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:seg];
        [NSLayoutConstraint activateConstraints:@[
            [seg.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [seg.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [seg.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [seg.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
        ]];
        return cell;
    } else {
        c.text = TPL(@"Reset to Default");
        c.textProperties.color = TPAccent();
        c.textProperties.alignment = UIListContentTextAlignmentCenter;
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)segmentChanged:(UISegmentedControl *)seg {
    NSInteger i = seg.selectedSegmentIndex;
    switch (seg.tag) {
        case kTPTSSeparator: [TPPrefs setInteger:i forKey:TPKeyTimeSeparator]; break;
        case kTPTSYear: [TPPrefs setInteger:i forKey:TPKeyTimeYear]; break;
        case kTPTSWeekday: [TPPrefs setBool:i == 1 forKey:TPKeyTimeWeekdayFull]; break;
        default: [TPPrefs setBool:i == 1 forKey:TPKeyTimeSeconds]; break;
    }
    [self reloadPreview];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 1; }
- (BOOL)tableView:(UITableView *)tv canMoveRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 1; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip { return UITableViewCellEditingStyleNone; }
- (BOOL)tableView:(UITableView *)tv shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)ip { return NO; }
- (NSIndexPath *)tableView:(UITableView *)tv targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from toProposedIndexPath:(NSIndexPath *)to {
    if (to.section < 1) return [NSIndexPath indexPathForRow:0 inSection:1];
    if (to.section > 1) return [NSIndexPath indexPathForRow:(NSInteger)_parts.count - 1 inSection:1];
    return to;
}
- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSMutableDictionary *p = _parts[from.row];
    [_parts removeObjectAtIndex:from.row];
    [_parts insertObject:p atIndex:to.row];
    dispatch_async(dispatch_get_main_queue(), ^{ [self saveParts]; });
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) {
        NSMutableDictionary *p = _parts[ip.row];
        p[@"on"] = @(![p[@"on"] boolValue]);
        [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        [self saveParts];
    } else if (ip.section == kTPTSReset) {
        [TPPrefs setTimeParts:nil];
        [TPPrefs setInteger:0 forKey:TPKeyTimeSeparator];
        [TPPrefs setInteger:1 forKey:TPKeyTimeYear];
        [TPPrefs setBool:NO forKey:TPKeyTimeWeekdayFull];
        [TPPrefs setBool:NO forKey:TPKeyTimeSeconds];
        [self loadParts];
        [tv reloadData];
        [self reloadPreview];
    }
}
@end

@interface UINavigationController (TPClose)
- (void)tp_close;
@end
@implementation UINavigationController (TPClose)
- (void)tp_close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

@implementation TPMutedKeywordsViewController {
    NSMutableArray<NSString *> *_rules;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = TPL(@"Muted Keywords");
    self.tableView.backgroundColor = [TPUI pageColor];
    UIBarButtonItem *addBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                            target:self action:@selector(addRule)];
    __weak typeof(self) weak = self;
    UIMenu *moreMenu = [UIMenu menuWithChildren:@[
        [UIAction actionWithTitle:TPL(@"Reset Hit Counts") image:[UIImage systemImageNamed:@"arrow.counterclockwise"] identifier:nil handler:^(UIAction *a) {
            [[TPPrefs defaults] removeObjectForKey:@"tp_filter_hit_counts"];
            [weak.tableView reloadData];
        }],
        [UIAction actionWithTitle:TPL(@"Clear All Rules") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) {
            [weak confirmClearAll];
        }]
    ]];
    UIBarButtonItem *moreBtn = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:moreMenu];
    self.navigationItem.rightBarButtonItems = @[addBtn, moreBtn];
    [self loadRules];
}

- (void)loadRules {
    _rules = [[TPPrefs mutedRules] mutableCopy];
    [self.tableView reloadData];
}

- (void)saveRules {
    [TPPrefs setMutedRules:_rules];
}

// Regex examples, tap one to add it. Each language has its own example words; the English
// strings are the keys.
static NSArray<NSArray<NSString *> *> *TPRegexExamples(void) {
    return @[
        @[@"/giveaway|free gift|DM me/", @"Any one of these words (| means \"or\")"],
        @[@"/DM.{0,5}(earn|income)/", @"\"DM\" followed within 5 characters by \"earn\" or \"income\""],
        @[@"/(LINE|WhatsApp)\\s*ID/", @"\"LINE ID\" or \"WhatsApp ID\", with or without a space"],
        @[@"/save\\s*\\d+/", @"\"save\" followed by a number, e.g. \"save 50\", \"save50\""],
        @[@"/https?:\\/\\/\\S+/", @"Posts that contain a link"],
    ];
}

static NSString *TPRegexError(NSString *rule) {
    if (!([rule hasPrefix:@"/"] && [rule hasSuffix:@"/"] && rule.length > 2)) return nil;
    NSError *err = nil;
    [NSRegularExpression regularExpressionWithPattern:[rule substringWithRange:NSMakeRange(1, rule.length - 2)] options:0 error:&err];
    return err ? rule : nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 1) return TPL(@"Regex Examples");
    NSInteger n = [[TPPrefs filterStatsToday][@"count"] integerValue];
    return n > 0 ? [NSString stringWithFormat:TPL(@"Hidden today: %ld"), (long)n] : nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) return _rules.count ? nil : TPL(@"No muted rules yet.\nTap + to add a keyword, @username, or /regex/.");
    return TPL(@"Tap an example to add it. A regex goes between two slashes; | means \"or\".");
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 1) return;
    NSString *rule = TPL(TPRegexExamples()[ip.row][0]);
    if ([_rules containsObject:rule]) { [TPHUD toast:TPL(@"Already added")]; return; }
    [_rules insertObject:rule atIndex:0];
    [self saveRules];
    [tv reloadData];
    [TPUI hapticLight];
    [TPHUD toast:[NSString stringWithFormat:TPL(@"Muted %@"), rule]];
}

- (void)addRule {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:TPL(@"Add Muted Rule")
                                                               message:TPL(@"Supports plain keywords, @username to mute an author, or /regex/ patterns. Separate several with commas to add them at once.")
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = TPL(@"e.g. giveaway, @spammer, /promo\\d+/");
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    // How long: permanent, or a temporary mute for a passing topic that lifts itself.
    __weak UIAlertController *wa = a;
    NSArray *choices = @[@[@"Mute Permanently", @0], @[@"Mute for 24 Hours", @(24 * 3600)], @[@"Mute for 7 Days", @(7 * 24 * 3600)]];
    for (NSArray *c in choices) {
        NSTimeInterval secs = [c[1] doubleValue];
        [a addAction:[UIAlertAction actionWithTitle:TPL(c[0]) style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act) {
            [self addRulesFromText:wa.textFields.firstObject.text duration:secs];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)addRulesFromText:(NSString *)text duration:(NSTimeInterval)secs {
    NSString *val = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!val.length) return;
    BOOL added = NO;
    for (NSString *t in [TPPrefs parseMutedRules:val]) {
        NSString *bad = TPRegexError(t);
        if (bad) { [TPHUD toast:[NSString stringWithFormat:TPL(@"Invalid regex: %@"), bad]]; continue; }
        if (![_rules containsObject:t]) [_rules insertObject:t atIndex:0];
        // Adding an existing rule again sets its new time limit.
        [TPPrefs setExpiry:secs > 0 ? [NSDate dateWithTimeIntervalSinceNow:secs] : nil forMutedRule:t];
        added = YES;
    }
    if (added) {
        [self saveRules];
        [self.tableView reloadData];
        [TPUI hapticLight];
    }
}

// "5 h left" / "3 d left" for a temporary rule, nil for a permanent one.
static NSString *TPRuleTimeLeft(NSString *rule) {
    NSDate *end = [TPPrefs expiryForMutedRule:rule];
    if (!end) return nil;
    NSTimeInterval left = end.timeIntervalSinceNow;
    if (left <= 0) return nil;
    if (left < 3600) return [NSString stringWithFormat:TPL(@"%ld min left"), (long)MAX(1, ceil(left / 60))];
    if (left < 48 * 3600) return [NSString stringWithFormat:TPL(@"%ld h left"), (long)ceil(left / 3600)];
    return [NSString stringWithFormat:TPL(@"%ld d left"), (long)ceil(left / 86400)];
}

- (void)confirmClearAll {
    if (!_rules.count) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:TPL(@"Clear All Rules?")
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Delete") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *act) {
        [self->_rules removeAllObjects];
        [self saveRules];
        [self.tableView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 1 ? TPRegexExamples().count : _rules.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"kw"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"kw"];
    if (ip.section == 1) {
        NSArray<NSString *> *ex = TPRegexExamples()[ip.row];
        UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
        c.text = TPL(ex[0]);
        c.textProperties.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
        c.secondaryText = TPL(ex[1]);
        c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        c.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        c.image = [UIImage systemImageNamed:@"plus.circle"];
        cell.contentConfiguration = c;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    NSString *rule = _rules[ip.row];
    NSDictionary *hits = [[TPPrefs defaults] dictionaryForKey:@"tp_filter_hit_counts"];
    NSInteger count = [hits[rule] integerValue];
    NSString *kind = TPL(@"Keyword");
    if ([rule hasPrefix:@"@"] && rule.length > 1) kind = TPL(@"Author");
    else if ([rule hasPrefix:@"/"] && [rule hasSuffix:@"/"] && rule.length > 2) kind = TPL(@"Regex");

    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.text = rule;
    NSString *sub = [NSString stringWithFormat:TPL(@"%@ · %ld hits"), kind, (long)count];
    NSString *left = TPRuleTimeLeft(rule);
    c.secondaryText = left ? [NSString stringWithFormat:@"%@ · %@", sub, left] : sub;
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    c.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.contentConfiguration = c;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != 0) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:TPL(@"Delete")
                                                                    handler:^(UIContextualAction *act, UIView *src, void (^done)(BOOL)) {
        [self->_rules removeObjectAtIndex:ip.row];
        [self saveRules];
        [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
        if (!self->_rules.count) [tv reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end

@interface TPSettingsViewController () <UIDocumentPickerDelegate, UISearchBarDelegate>
- (void)refreshCacheSize;
@end

@implementation TPSettingsViewController {
    NSString *_downloadPercent;
    BOOL _watchingDownloads;
    NSArray<NSDictionary *> *_sections;
    CGFloat _headerWidth;
    UIButton *_doneButton;
    TPSettingsHeaderView *_header;
    NSArray<NSDictionary *> *_allSections;
    NSInteger _category;
    BOOL _showAbout;
    NSMutableDictionary<NSNumber *, NSArray *> *_shownRows;
    // A plain search bar at the top of the list rather than a navigation-bar search controller:
    // it looks and behaves the same on iOS 16–27 and doesn't jump or linger during push/pop
    // (iOS 26 moves navigation search bars to the bottom and animates them between pages).
    UISearchBar *_searchBar;
    UIView *_headerBox;
    NSArray<NSDictionary *> *_searchResults;
}

static NSArray<NSArray<NSString *> *> *TPRootGroups(void) {
    return @[ @[@"Download Manager"],
              @[@"Ads & Privacy", @"Media Download", @"Player", @"Home Feed"],
              @[@"Author Info", @"Hidden Items", @"Links", @"Messages", @"Interface & Interactions"],
              @[@"Backup", @"Advanced", @"About"],
              @[@"Telegram", @"Donate"] ];
}

static NSString *const kTPTelegramURL = @"https://t.me/h4x_0x30vmChat";

static NSString *TPCategoryIcon(NSString *header) {
    NSDictionary *m = @{ @"Download Manager": @"tray.full", @"Ads & Privacy": @"shield", @"Media Download": @"arrow.down", @"Player": @"play.rectangle",
                         @"Home Feed": @"house", @"Author Info": @"person.text.rectangle", @"Hidden Items": @"eye.slash", @"Links": @"link",
                         @"Messages": @"bubble.left.and.bubble.right", @"Interface & Interactions": @"slider.horizontal.3",
                         @"Backup": @"archivebox", @"Advanced": @"wrench.and.screwdriver", @"About": @"info.circle", @"Donate": @"cup.and.saucer" };
    return m[header] ?: @"circle";
}

static UIImage *TPSquareIconWith(NSString *symbol, UIColor *bg, UIColor *fg);
static UIImage *TPSquareIcon(NSString *symbol, UIColor *bg) { return TPSquareIconWith(symbol, bg, UIColor.whiteColor); }

static UIImage *TPSquareIconWith(NSString *symbol, UIColor *bg, UIColor *fg) {
    CGFloat d = 30;
    UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:
                       [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]]
                      imageWithTintColor:fg renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(d, d)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [bg setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, d, d) cornerRadius:8] fill];
        CGSize g = glyph.size;
        [glyph drawInRect:CGRectMake((d - g.width) / 2, (d - g.height) / 2, g.width, g.height)];
    }];
}

- (instancetype)initWithCategory:(NSInteger)category {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _category = category;
    return self;
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) _category = -1;
    return self;
}

- (BOOL)isRoot { return _category < 0; }

- (NSDictionary *)sectionWithHeader:(NSString *)h {
    for (NSDictionary *sec in _allSections) if ([sec[@"header"] isEqualToString:h]) return sec;
    return nil;
}

- (NSString *)summaryForSection:(NSDictionary *)sec {
    if ([sec[@"header"] isEqualToString:@"Advanced"]) return nil;
    NSInteger on = 0, total = 0;
    for (NSDictionary *row in sec[@"rows"]) {
        if (![row[@"type"] isEqualToString:@"switch"]) continue;
        total++;
        if ([TPPrefs boolForKey:row[@"key"]]) on++;
    }
    return total ? [NSString stringWithFormat:@"%ld／%ld", (long)on, (long)total] : nil;
}

+ (void)presentMutedRules {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = TPTopViewController();
        if (!top) return;
        TPMutedKeywordsViewController *vc = [TPMutedKeywordsViewController new];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        nav.navigationBar.tintColor = TPAccent();
        nav.view.tintColor = TPAccent();
        vc.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                             target:nav action:@selector(tp_close)];
        [top presentViewController:nav animated:YES completion:nil];
    });
}

+ (void)present {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = TPTopViewController();
        if (!top) return;
        if ([top isKindOfClass:[UINavigationController class]] &&
            [[(UINavigationController *)top viewControllers].firstObject isKindOfClass:self]) return;
        TPSettingsViewController *vc = [[self alloc] initWithStyle:UITableViewStyleInsetGrouped];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        nav.navigationBar.tintColor = TPAccent();
        nav.view.tintColor = TPAccent();
        UINavigationBarAppearance *ap = [UINavigationBarAppearance new];
        [ap configureWithOpaqueBackground];
        ap.backgroundColor = TPPageColor();
        ap.shadowColor = UIColor.clearColor;
        ap.titleTextAttributes = @{ NSForegroundColorAttributeName: UIColor.labelColor };
        ap.largeTitleTextAttributes = @{ NSForegroundColorAttributeName: UIColor.labelColor };
        nav.navigationBar.standardAppearance = ap;
        nav.navigationBar.scrollEdgeAppearance = ap;
        nav.navigationBar.compactAppearance = ap;
        if (@available(iOS 15.0, *)) {
            nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
            nav.sheetPresentationController.prefersGrabberVisible = YES;
        }
        [top presentViewController:nav animated:YES completion:nil];
    });
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIButton *doneButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _doneButton = doneButton;
    doneButton.frame = CGRectMake(0, 0, 32, 32);
    doneButton.backgroundColor = TPAccent();
    doneButton.layer.cornerRadius = 16;
    UIImage *check = [[UIImage systemImageNamed:@"checkmark"
                               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightBold]]
                      imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    [doneButton setImage:check forState:UIControlStateNormal];
    doneButton.accessibilityLabel = TPL(@"Done");
    [doneButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [doneButton.widthAnchor constraintEqualToConstant:32].active = YES;
    [doneButton.heightAnchor constraintEqualToConstant:32].active = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:doneButton];
    self.navigationController.navigationBar.tintColor = TPAccent();
    self.view.tintColor = TPAccent();
    self.tableView.backgroundColor = TPPageColor();
    self.tableView.separatorColor = TPHairlineColor();
    self.tableView.sectionHeaderTopPadding = 6;

    _sections = @[
        @{ @"header": @"Ads & Privacy",
           @"footer": @"Turning ad blocking on or off takes effect after refreshing the feed or restarting the app.",
           @"rows": @[
               @{ @"type": @"switch", @"key": TPKeyBlockAds, @"title": @"Block Ads",
                  @"detail": @"Hide sponsored posts in the feed and between replies",
                  @"icon": @"shield" },
               @{ @"type": @"switch", @"key": TPKeyBlockScreenshotDetect, @"title": @"Block Screenshot Detection",
                  @"detail": @"Threads won't know when you take a screenshot or record the screen",
                  @"icon": @"camera.viewfinder" },
               @{ @"type": @"switch", @"key": TPKeyBlockAnalytics, @"title": @"Block Analytics",
                  @"detail": @"Stop Threads from sending usage data such as what you view, how long you stay and what you tap. Recommendations may become less accurate",
                  @"icon": @"eye.slash" },
               @{ @"type": @"switch", @"key": TPKeyStripTracking, @"title": @"Remove URL Tracking",
                  @"detail": @"Automatically strip xmt, igshid, utm_* and more when copying, sharing or opening links",
                  @"icon": @"scissors" },
               @{ @"type": @"switch", @"key": TPKeyHideInCaptures, @"title": @"Hide Buttons in Screenshots",
                  @"detail": @"ThreadsPulse buttons don't appear in screenshots or screen recordings",
                  @"icon": @"square.dashed" },
           ]},
        @{ @"header": @"Media Download",
           @"groups": @[@"Download Options", @"Saved Files", @"Video Downloads", @"Photo Downloads"],
           @"rows": @[
               @{ @"type": @"switch", @"group": @"Download Options", @"key": TPKeyShowDownloadBtn, @"title": @"Download Button",
                  @"detail": @"Shows a download button on posts. Tap to download all photos and videos; long-press to download only photos or only videos.",
                  @"icon": @"arrow.down" },
               @{ @"type": @"switch", @"group": @"Download Options", @"key": TPKeyThreadDownloadBtn, @"title": @"Thread Download Button",
                  @"detail": @"Adds a button to the top-right of a thread page. Tap it to collect every photo and video in the thread, replies included, and download them. Progress shows under the top bar; tap the button or the progress label while working to stop or cancel. Long-press the button to open the download manager.",
                  @"icon": @"square.and.arrow.down.on.square", @"showIf": @[TPKeyShowDownloadBtn, @1] },
               @{ @"type": @"switch", @"group": @"Download Options", @"key": TPKeySaveToAlbum, @"title": @"Save to \"Threads\" Album",
                  @"detail": @"Downloaded items are also added to a \"Threads\" album in Photos. Full Photos access is required the first time.",
                  @"icon": @"rectangle.stack.badge.plus" },
               @{ @"type": @"switch", @"group": @"Download Options", @"key": TPKeyAlbumByAuthor, @"title": @"Organize Albums by @Author",
                  @"detail": @"Create a separate Photos album for each @author instead of a single \"Threads\" album.",
                  @"icon": @"folder.badge.person.crop" },
               @{ @"type": @"switch", @"group": @"Download Options", @"key": TPKeyKeepDownloadCopies, @"title": @"Keep Copies in ThreadsPulse",
                  @"detail": @"Downloaded files are also kept here, so you can preview, share or save them again. Uses storage on your iPhone.",
                  @"icon": @"externaldrive" },
               @{ @"type": @"segment", @"group": @"Download Options", @"key": TPKeyDownloadHistoryLimit, @"title": @"History Retention", @"detail": @"",
                  @"icon": @"clock.arrow.circlepath",
                  @"segments": @[@"Unlimited", @"50 Items", @"100 Items", @"30 Days"],
                  @"note": @"Automatically cleans oldest download history, thumbnails & copies kept in ThreadsPulse. Never deletes files saved in Photos." },
               @{ @"type": @"switch", @"group": @"Saved Files", @"key": TPKeyDuplicateWarn, @"title": @"Warn About Duplicates",
                  @"detail": @"Before downloading a post that's already in the download history, ask whether to download it again",
                  @"icon": @"doc.on.doc" },
               @{ @"type": @"switch", @"group": @"Saved Files", @"key": TPKeyNameFromPost, @"title": @"Name Files From Post",
                  @"detail": @"Files are named from the post's author, time and code. The name shows in Photos info and when you share or export",
                  @"icon": @"textformat" },
               @{ @"type": @"action", @"group": @"Saved Files", @"action": @"nameFormat", @"title": @"File Name Format",
                  @"icon": @"slider.horizontal.3", @"showIf": @[TPKeyNameFromPost, @1] },
               @{ @"type": @"switch", @"group": @"Saved Files", @"key": TPKeyPostDate, @"title": @"Use Post Time as Date",
                  @"detail": @"Photos and videos are dated when the post was published, so they sort by post time in Photos",
                  @"icon": @"calendar" },
               @{ @"type": @"segment", @"group": @"Video Downloads", @"key": TPKeyVideoQuality, @"title": @"Video Quality", @"detail": @"",
                  @"icon": @"film",
                  @"segments": @[@"Highest", @"720p", @"Ask"],
                  @"note": @"Highest downloads videos at up to 1080p; some videos are converted on the device, which takes a few seconds. 720p is the fastest and needs no conversion." },
               @{ @"type": @"segment", @"group": @"Video Downloads", @"key": TPKeyVideoFormat, @"title": @"Video Format", @"detail": @"",
                  @"icon": @"sparkles.tv",
                  @"segments": @[@"Keep HDR", @"Compatible"], @"showIf": @[TPKeyVideoQuality, @1, @"!="],
                  @"note": @"Keep HDR preserves the original brightness and color. Compatible converts to H.264 (SDR), suited to sharing on LINE, Windows or older devices." },
               @{ @"type": @"switch", @"group": @"Photo Downloads", @"key": TPKeyOriginalImage, @"title": @"Download Original Size",
                  @"detail": @"Retrieves the highest resolution from the web version. If unavailable, the standard size is downloaded.",
                  @"icon": @"photo" },
               @{ @"type": @"switch", @"group": @"Photo Downloads", @"key": TPKeyOriginalAvatar, @"title": @"Download Original Profile Pictures",
                  @"detail": @"To save, long-press a profile picture on a profile, or view it full screen and tap ↓ in the bottom-right corner.",
                  @"icon": @"person.crop.circle" },
           ]},
        @{ @"header": @"Player",
           @"footer": @"Videos play at the selected speed, and return to it after you release a long-press 2x.",
           @"rows": @[
               @{ @"type": @"switch", @"key": TPKeyNoAutoplay, @"title": @"Disable Autoplay",
                  @"detail": @"Videos in the feed won't play until you tap them",
                  @"icon": @"play.slash" },
               @{ @"type": @"switch", @"key": TPKeyNoMusicAutoplay, @"title": @"Disable Music Autoplay",
                  @"detail": @"Music added to posts won't play by itself; tap the music to play it",
                  @"icon": @"speaker.slash" },
               @{ @"type": @"segment", @"key": TPKeyPlaySpeed, @"title": @"Default Playback Speed", @"detail": @"",
                  @"icon": @"speedometer",
                  @"segments": @[@"1x", @"1.25x", @"1.5x", @"2x"] },
           ]},
        @{ @"header": @"Home Feed",
           @"footer": @"With everything here turned on, new posts only load after you fully close and reopen Threads.",
           @"rows": @[
               @{ @"type": @"switch", @"key": TPKeyKeepFeed, @"title": @"Keep Feed Position",
                  @"detail": @"Coming back from the background won't refresh the home feed, jump to the top or switch tabs",
                  @"icon": @"pin" },
               @{ @"type": @"segment", @"key": TPKeyKeepFeedLimit, @"title": @"Keep For", @"detail": @"",
                  @"icon": @"timer",
                  @"segments": @[@"10 min", @"30 min", @"No Limit"], @"showIf": @[TPKeyKeepFeed, @1],
                  @"note": @"Come back within this time to keep your place; after that, the feed refreshes as usual" },
               @{ @"type": @"switch", @"key": TPKeyNoPullRefresh, @"title": @"Disable Pull to Refresh",
                  @"detail": @"Pulling down at the top of the home feed won't refresh it, and the feed stops at the top without bouncing",
                  @"icon": @"arrow.down.to.line" },
               @{ @"type": @"switch", @"key": TPKeyMuteRefreshSound, @"title": @"Mute Refresh Sound",
                  @"detail": @"No sound when the home feed refreshes, even if Threads turns its own sound setting back on",
                  @"icon": @"speaker.slash" },
               @{ @"type": @"caption", @"title": @"When Tapping the Home Tab" },
               @{ @"type": @"switch", @"key": TPKeyTabNoScrollTop, @"title": @"Don't Scroll to Top",
                  @"detail": @"When you're scrolled down the home feed, tapping the Home tab won't jump back to the top, so you stay where you were",
                  @"icon": @"arrow.up.to.line" },
               @{ @"type": @"switch", @"key": TPKeyTabNoRefresh, @"title": @"Don't Refresh",
                  @"detail": @"When you're already at the top of the home feed, tapping the Home tab won't refresh or load new posts",
                  @"icon": @"arrow.clockwise" },
           ]},
        @{ @"header": @"Author Info",
           @"footer": @"To avoid limits from Threads, authors are read one at a time and cached for up to 21 days, pausing for 1 hour when needed. Layout changes apply as you scroll.",
           @"rows": @[
               @{ @"type": @"switch", @"key": TPKeyAuthorInfo, @"title": @"Show Author Info",
                  @"detail": @"Shows details from the author's \"About this profile\" with their name in the feed.",
                  @"icon": @"person.text.rectangle" },
               @{ @"type": @"action", @"action": @"authorStats", @"title": @"Location Stats",
                  @"detail": @"See which countries and regions the authors you've read are from.",
                  @"icon": @"chart.bar.xaxis", @"showIf": @[TPKeyAuthorInfo, @1] },
               @{ @"type": @"action", @"action": @"authorStatus", @"title": @"Read Status & Cache",
                  @"detail": @"See how many authors are cached and whether reading is paused, or clear the cache.",
                  @"icon": @"gauge.with.dots.needle.33percent", @"showIf": @[TPKeyAuthorInfo, @1] },
               @{ @"type": @"caption", @"title": @"Read Automatically", @"showIf": @[TPKeyAuthorInfo, @1] },
               @{ @"type": @"switch", @"key": TPKeyAuthorLocation, @"title": @"Location",
                  @"detail": @"The country or region where the account is based, shown with its flag. Shows \"Not shared\" if the author keeps it private.",
                  @"icon": @"mappin.and.ellipse", @"showIf": @[TPKeyAuthorInfo, @1] },
               @{ @"type": @"switch", @"key": TPKeyAuthorJoined, @"title": @"Join Date",
                  @"detail": @"The month the account joined Threads.",
                  @"icon": @"calendar", @"showIf": @[TPKeyAuthorInfo, @1] },
               @{ @"type": @"switch", @"key": TPKeyAuthorJoinNumber, @"title": @"Join Number",
                  @"detail": @"Shows which user number the account was when it joined, such as #7,551,963 or 100M+.",
                  @"icon": @"number", @"showIf": @[@[TPKeyAuthorInfo, @1], @[TPKeyAuthorJoined, @1]] },
               @{ @"type": @"switch", @"key": TPKeyAuthorNewBadge, @"title": @"New Account Badge",
                  @"detail": @"Marks accounts that joined within the last 2 months.",
                  @"icon": @"sparkles", @"showIf": @[TPKeyAuthorInfo, @1] },
               @{ @"type": @"switch", @"key": TPKeyAuthorDefaultName, @"title": @"Default Name Badge",
                  @"detail": @"Marks accounts that never changed the username Threads assigned at sign-up, such as camel.253044. This doesn't mean the account is fake.",
                  @"icon": @"person.crop.circle.badge.questionmark", @"showIf": @[TPKeyAuthorInfo, @1] },
               @{ @"type": @"caption", @"title": @"Layout", @"showIf": @[TPKeyAuthorInfo, @1] },
               @{ @"type": @"switch", @"key": TPKeyAuthorOwnLine, @"title": @"Show on Its Own Line",
                  @"detail": @"Adds a line under the name so the info always shows in full. When off, it sits next to the name and is shortened or hidden if there isn't enough room.",
                  @"icon": @"text.line.last.and.arrowtriangle.forward", @"showIf": @[TPKeyAuthorInfo, @1] },
           ]},
        @{ @"header": @"Hidden Items",
           @"groups": @[@"Suggested Content", @"Content Filters", @"Interface Buttons"],
           @"rows": @[
               @{ @"type": @"switch", @"group": @"Suggested Content", @"key": TPKeyHideFeedSuggest, @"title": @"Suggested Accounts",
                  @"detail": @"Hide \"Suggested for you\" in the feed & on profiles",
                  @"icon": @"person.badge.minus" },
               @{ @"type": @"switch", @"group": @"Suggested Content", @"key": TPKeyHideSearchSuggest, @"title": @"Search Suggestions",
                  @"detail": @"Hide \"Suggested to follow\" on the search page",
                  @"icon": @"person.badge.plus" },
               @{ @"type": @"switch", @"group": @"Suggested Content", @"key": TPKeyHideFollowSuggest, @"title": @"Follow Suggestion Pop-ups",
                  @"detail": @"Stop \"Follow suggestions\" from popping up automatically",
                  @"icon": @"person.crop.circle.badge.xmark" },
               @{ @"type": @"switch", @"group": @"Suggested Content", @"key": TPKeyHideIGConnections, @"title": @"Instagram Connections Pop-ups",
                  @"detail": @"Stop \"Follow your Instagram connections\" from popping up automatically",
                  @"icon": @"person.2.slash" },
               @{ @"type": @"switch", @"group": @"Content Filters", @"key": TPKeyHideNewAccounts, @"title": @"Hide New Accounts",
                  @"detail": @"Hide feed posts from accounts joined within the last 2 months (requires Author Info)",
                  @"icon": @"person.crop.circle.badge.xmark" },
               @{ @"type": @"action", @"group": @"Content Filters", @"action": @"editKeywords", @"title": @"Muted Keywords",
                  @"detail": @"Hide feed posts and replies containing these words, from these @authors or matching /regex/ patterns",
                  @"icon": @"text.badge.minus" },
               @{ @"type": @"switch", @"group": @"Suggested Content", @"key": TPKeyHidePostFeedback, @"title": @"Post Interest Prompts",
                  @"detail": @"Stop asking if you're interested in posts",
                  @"icon": @"hand.thumbsup" },
               @{ @"type": @"switch", @"group": @"Interface Buttons", @"key": TPKeyHideProfileSearch, @"title": @"Search Button",
                  @"detail": @"Hide the search button on profiles",
                  @"icon": @"magnifyingglass" },
               @{ @"type": @"switch", @"group": @"Interface Buttons", @"key": TPKeyHideIGButton, @"title": @"Instagram Button",
                  @"detail": @"Hide the Instagram button on profiles",
                  @"icon": @"minus.square" },
           ]},
        @{ @"header": @"Links",
           @"footer": @"Auto-open reads the clipboard directly. If iOS asks to allow pasting every time, go to Settings › Threads › Paste from Other Apps and choose Allow.",
           @"footerIf": @[@[TPKeyClipboardLinks, @1], @[TPKeyClipboardMode, @1]],
           @"rows": @[
               @{ @"type": @"switch", @"key": TPKeyClipboardLinks, @"title": @"Detect Copied Links",
                  @"detail": @"When you come back or switch accounts, detect a copied Threads link and open it",
                  @"icon": @"doc.on.clipboard" },
               @{ @"type": @"segment", @"key": TPKeyClipboardMode, @"title": @"When a Link Is Found", @"detail": @"",
                  @"icon": @"hand.tap",
                  @"segments": @[@"Ask", @"Auto-open"], @"showIf": @[TPKeyClipboardLinks, @1] },
               @{ @"type": @"segment", @"key": TPKeyBannerPosition, @"title": @"Prompt Position", @"detail": @"",
                  @"icon": @"arrow.up.arrow.down",
                  @"segments": @[@"Top", @"Middle", @"Bottom"], @"showIf": @[@[TPKeyClipboardLinks, @1], @[TPKeyClipboardMode, @0]] },
               @{ @"type": @"switch", @"key": TPKeyExternalBrowser, @"title": @"Open Links in External Browser",
                  @"detail": @"Links in posts and bios open in Safari (or your default browser) instead of the in-app browser. Threads links still open in the app",
                  @"icon": @"safari" },
           ]},
        @{ @"header": @"Messages",
           @"rows": @[
               @{ @"type": @"switch", @"key": TPKeyNoSeen, @"title": @"Hide Seen Status",
                  @"detail": @"Viewing messages won't notify the other person. To show \"Seen\" normally in a specific chat, tap the eye icon at the top right of that chat.",
                  @"icon": @"eye.slash" },
               @{ @"type": @"switch", @"key": TPKeySeenOnReply, @"title": @"Show Seen When You Reply",
                  @"detail": @"Let the other person see \"Seen\" once you reply",
                  @"icon": @"arrowshape.turn.up.left", @"showIf": @[TPKeyNoSeen, @1] },
               @{ @"type": @"action", @"action": @"resetSeenChats", @"title": @"Reset Chats",
                  @"detail": @"Chats where you tapped the eye to show \"Seen\" go back to hiding it",
                  @"icon": @"arrow.counterclockwise", @"showIf": @[TPKeyNoSeen, @1] },
               @{ @"type": @"switch", @"key": TPKeyNoTyping, @"title": @"Hide Typing Status",
                  @"detail": @"The other person won't see \"typing…\" while you write a message",
                  @"icon": @"ellipsis.bubble" },
               @{ @"type": @"switch", @"key": TPKeyKeepUnsent, @"title": @"Keep Unsent Messages",
                  @"detail": @"When someone unsends a message, it stays in your chat marked \"Unsent\"",
                  @"icon": @"arrow.uturn.backward" },
           ]},
        @{ @"header": @"Interface & Interactions",
           @"rows": @[
               @{ @"type": @"switch", @"key": TPKeyConfirmLike, @"title": @"Like Confirmation",
                  @"detail": @"Ask before a like is sent, to prevent accidental taps. Removing a like won't ask.",
                  @"icon": @"heart" },
               @{ @"type": @"action", @"action": @"timeFormat", @"title": @"Post Time Format", @"detail": @"",
                  @"icon": @"clock" },
               @{ @"type": @"switch", @"key": TPKeyPinTabBar, @"title": @"Keep Tab Bar Visible",
                  @"detail": @"Scrolling won't hide the tab bar at the bottom; it always stays on screen",
                  @"icon": @"dock.rectangle" },
               @{ @"type": @"switch", @"key": TPKeyCopyProfile, @"title": @"Copy Profile Info",
                  @"detail": @"On a profile, long-press the name, username, bio or profile picture to copy the name, username or bio",
                  @"icon": @"doc.on.doc" },
               @{ @"type": @"switch", @"key": TPKeyHomeLongPress, @"title": @"Long-Press Home Tab for Settings",
                  @"detail": @"Long-pressing the Home tab at the bottom opens ThreadsPulse settings instead",
                  @"icon": @"hand.point.up.left" },
           ]},
        @{ @"header": @"Backup",
           @"footer": @"Export your settings to a file, and import it after reinstalling or on another device.",
           @"rows": @[
               @{ @"type": @"action", @"action": @"export", @"title": @"Export Settings", @"detail": @"",
                  @"icon": @"square.and.arrow.up" },
               @{ @"type": @"action", @"action": @"import", @"title": @"Import Settings", @"detail": @"",
                  @"icon": @"square.and.arrow.down" },
               @{ @"type": @"caption", @"title": @"Also Include When Exporting" },
               @{ @"type": @"switch", @"key": TPKeyBackupMutedRules, @"title": @"Muted Rules",
                  @"detail": @"Keywords, @authors and /regex/ rules, with how long each is muted",
                  @"icon": @"text.badge.minus" },
               @{ @"type": @"switch", @"key": TPKeyBackupAuthors, @"title": @"Author Info",
                  @"detail": @"Authors already read, so they don't have to be read again after reinstalling",
                  @"icon": @"person.text.rectangle" },
           ]},
        @{ @"header": @"Advanced",
           @"rows": @[
               @{ @"type": @"switch", @"key": TPKeyDebugToast, @"title": @"Debug Hints",
                  @"detail": @"Turn on when a feature stops working. Hints show which features are active, to help report problems.",
                  @"icon": @"ladybug" },
               @{ @"type": @"action", @"action": @"clearCache", @"title": @"Clear Cache",
                  @"detail": @"Frees space used by images and videos. Your login and settings are kept",
                  @"icon": @"trash" },
               @{ @"type": @"action", @"action": @"welcome", @"title": @"Welcome Screen",
                  @"detail": @"See how to open ThreadsPulse settings again",
                  @"icon": @"hand.wave" },
               @{ @"type": @"action", @"action": @"whatsNew", @"title": @"What's New",
                  @"detail": @"See what's new in this version",
                  @"icon": @"newspaper" },
               @{ @"type": @"action", @"action": @"analyticsLog", @"title": @"Analytics Log",
                  @"detail": @"Shows the usage data Threads collects and what it contains. The log never leaves your device",
                  @"icon": @"chart.bar.doc.horizontal" },
               @{ @"type": @"switch", @"key": TPKeyAutoUpdateCheck, @"title": @"Check for Updates Automatically",
                  @"detail": @"Checks GitHub once a day and lets you know when a new version is out",
                  @"icon": @"arrow.triangle.2.circlepath" },
               @{ @"type": @"switch", @"key": TPKeySideloadFix, @"title": @"Sideload Compatibility Fix",
                  @"detail": @"Keeps you signed in and app group data working after re-signing. Only active on re-signed apps; takes effect after reopening Threads",
                  @"icon": @"key" },
           ]},
        // Opened from the main page. The plugin version is in the page header.
        @{ @"header": @"About",
           @"groups": @[@"Environment", @"Links"],
           @"rows": @[
               @{ @"type": @"info", @"group": @"Environment", @"title": @"Threads Version", @"value": TPAboutRows()[1][1], @"icon": @"at" },
               @{ @"type": @"info", @"group": @"Environment", @"title": @"Bundle ID", @"value": TPAboutRows()[2][1], @"icon": @"shippingbox" },
               @{ @"type": @"info", @"group": @"Environment", @"title": @"Device", @"value": TPAboutRows()[4][1], @"icon": @"iphone" },
               @{ @"type": @"info", @"group": @"Environment", @"title": @"iOS Version", @"value": TPAboutRows()[3][1], @"icon": @"gear" },
               @{ @"type": @"action", @"group": @"Environment", @"action": @"copyAbout", @"title": @"Copy All Info", @"detail": @"",
                  @"icon": @"doc.on.doc" },
               @{ @"type": @"action", @"group": @"Links", @"action": @"checkUpdate", @"title": @"Check for Updates", @"detail": @"",
                  @"icon": @"arrow.down.circle" },
               @{ @"type": @"weblink", @"group": @"Links", @"url": kTPRepoURL, @"title": @"Source Code on GitHub", @"icon": @"chevron.left.forwardslash.chevron.right" },
               @{ @"type": @"weblink", @"group": @"Links", @"action": @"report", @"title": @"Report a Problem", @"icon": @"exclamationmark.bubble" },
               @{ @"type": @"weblink", @"group": @"Links", @"url": @"https://github.com/meettomorrow/lee-su-threads",
                  @"title": @"Author Info draws on lee-su-threads (MIT)", @"icon": @"person.2" },
           ]},
        @{ @"header": @"Donate",
           @"footer": @"Your support keeps ThreadsPulse updated. Thank you!",
           @"rows": @[
               @{ @"type": @"link", @"url": kTPDonateURL, @"title": @"Buy Me a Coffee",
                  @"detail": @"Support ThreadsPulse on Ko-fi",
                  @"icon": @"cup.and.saucer" },
           ]},
    ];
    _allSections = _sections;
    if (self.isRoot) {
        _searchBar = [UISearchBar new];
        _searchBar.searchBarStyle = UISearchBarStyleMinimal;
        _searchBar.placeholder = TPL(@"Search settings");
        _searchBar.delegate = self;
        _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
        self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
        _sections = @[];
        self.navigationItem.title = @"Pulse";
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
        self.navigationItem.backButtonTitle = @"Pulse";
    } else {
        NSDictionary *sec = _allSections[_category];
        _sections = @[sec];
        NSArray *groups = sec[@"groups"];
        if (groups.count) {
            NSMutableArray *parts = [NSMutableArray array];
            for (NSString *g in groups) {
                NSMutableArray *rows = [NSMutableArray array];
                for (NSDictionary *row in sec[@"rows"]) if ([row[@"group"] isEqualToString:g]) [rows addObject:row];
                if (rows.count) [parts addObject:@{ @"header": sec[@"header"], @"groupTitle": g, @"rows": rows }];
            }
            if (parts.count) _sections = parts;
        }
        _showAbout = [sec[@"header"] isEqualToString:@"About"];   // adds Reset All Settings at the bottom
        self.navigationItem.title = TPL(sec[@"header"]);
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Leaving a page (back to the list, not deeper into it) counts as having seen its new options.
    if (!self.isRoot && (self.isMovingFromParentViewController || self.navigationController.isBeingDismissed))
        TPMarkPageSeen(_allSections[_category][@"header"]);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.isRoot) [self applyTheme];
    else { [self refreshCacheSize]; [self.tableView reloadData]; }   // e.g. the muted rule count
    if (self.isRoot && !_watchingDownloads) {
        _watchingDownloads = YES;
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        for (NSString *name in @[TPDownloadStoreDidChangeNotification, TPDownloadProgressNotification, @"TPQueueChanged"])
            [nc addObserver:self selector:@selector(downloadsChanged:) name:name object:nil];
    }
    if (self.isRoot) [self downloadsChanged:[NSNotification notificationWithName:@"refresh" object:nil]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.tableView.bounds.size.width;
    if (!self.isRoot && w > 0 && w != _headerWidth && [_allSections[_category][@"header"] isEqualToString:@"About"]) {
        _headerWidth = w;
        UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 150)];
        CGFloat d = 64;
        UIView *tile = [[UIView alloc] initWithFrame:CGRectMake((w - d) / 2, 12, d, d)];
        tile.backgroundColor = TPAccent();
        tile.layer.cornerRadius = 16;
        tile.layer.cornerCurve = kCACornerCurveContinuous;
        UIImageView *g = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform.path.ecg"
            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightSemibold]]];
        g.tintColor = UIColor.whiteColor;
        g.contentMode = UIViewContentModeCenter;
        g.frame = tile.bounds;
        [tile addSubview:g];
        [box addSubview:tile];
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(20, 86, w - 40, 26)];
        name.text = @"ThreadsPulse";
        name.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        name.textAlignment = NSTextAlignmentCenter;
        [box addSubview:name];
        UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(20, 112, w - 40, 20)];
        ver.text = [NSString stringWithFormat:@"%@ %@", TPL(@"Version"), TP_VERSION];
        ver.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
        ver.textColor = UIColor.secondaryLabelColor;
        ver.textAlignment = NSTextAlignmentCenter;
        [box addSubview:ver];
        self.tableView.tableHeaderView = box;
    }
    if (!self.isRoot && w > 0 && w != _headerWidth) {
        _headerWidth = w;
        UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 56)];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, 4, w - 40, 44)];
        l.text = self.navigationItem.title;
        l.font = [UIFont systemFontOfSize:30 weight:UIFontWeightHeavy];
        l.textColor = UIColor.labelColor;
        [box addSubview:l];
        self.tableView.tableHeaderView = box;
    }
    if (self.isRoot && w > 0 && w != _headerWidth) {
        _headerWidth = w;
        _header = [[TPSettingsHeaderView alloc] initWithFrame:CGRectMake(0, 0, w, 234)];
        [_header setEnabledCount:[self enabledFeatureCount]];
        __weak typeof(self) weakSelf = self;
        _header.onThemeChange = ^{ [weakSelf applyTheme]; };
        // Every label in the settings is built once, so reopen them in the new language.
        _header.onLanguageChange = ^{
            UIViewController *nav = weakSelf.navigationController ?: weakSelf;
            [nav.presentingViewController dismissViewControllerAnimated:YES completion:^{ [TPSettingsViewController present]; }];
        };
        [_headerBox removeFromSuperview];
        _headerBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 0)];
        _searchBar.frame = CGRectMake(8, 0, w - 16, 52);
        [_headerBox addSubview:_searchBar];
        [_headerBox addSubview:_header];
        [self layoutHeaderBox];
    }
}

// The search bar stays on top; the ThreadsPulse card under it hides while searching. The box is
// resized in place (not replaced) so the search bar keeps the keyboard.
- (void)layoutHeaderBox {
    if (!_headerBox) return;
    BOOL searching = self.isSearching;
    _header.hidden = searching;
    _header.frame = CGRectMake(0, 52, _headerBox.bounds.size.width, _header.bounds.size.height);
    CGRect f = _headerBox.frame;
    f.size.height = searching ? 52 : 52 + _header.bounds.size.height;
    _headerBox.frame = f;
    self.tableView.tableHeaderView = _headerBox;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)enabledFeatureCount {
    NSInteger n = 0;
    for (NSDictionary *sec in _allSections)
        for (NSDictionary *row in sec[@"rows"])
            if ([row[@"type"] isEqualToString:@"switch"] && ![row[@"key"] isEqualToString:TPKeyDebugToast]
                && ![row[@"key"] isEqualToString:TPKeyAutoUpdateCheck]
                && ![row[@"key"] isEqualToString:TPKeyBackupMutedRules] && ![row[@"key"] isEqualToString:TPKeyBackupAuthors]
                && [TPPrefs boolForKey:row[@"key"]]) n++;
    return n;
}

- (void)applyTheme {
    self.navigationController.navigationBar.tintColor = TPAccent();
    self.navigationController.view.tintColor = TPAccent();
    self.view.tintColor = TPAccent();
    _doneButton.backgroundColor = TPAccent();
    _headerWidth = 0;
    [self.view setNeedsLayout];
    [self.tableView reloadData];
}

- (BOOL)isSearching {
    return self.isRoot && _searchBar.text.length > 0;
}

- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)text { [self runSearch]; }
- (void)searchBarTextDidBeginEditing:(UISearchBar *)bar { [bar setShowsCancelButton:YES animated:YES]; }
- (void)searchBarTextDidEndEditing:(UISearchBar *)bar { [bar setShowsCancelButton:bar.text.length > 0 animated:YES]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)bar { [bar resignFirstResponder]; }
- (void)searchBarCancelButtonClicked:(UISearchBar *)bar {
    bar.text = @"";
    [bar resignFirstResponder];
    [bar setShowsCancelButton:NO animated:YES];
    [self runSearch];
}

- (void)runSearch {
    NSString *q = [_searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (!q.length) {
        _searchResults = nil;
    } else {
        NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
        for (NSDictionary *sec in _allSections) {
            NSString *hdr = sec[@"header"] ?: @"";
            NSString *locHdr = hdr.length ? TPL(hdr) : @"";
            for (NSDictionary *row in sec[@"rows"]) {
                NSString *type = row[@"type"];
                if ([type isEqualToString:@"caption"] || [type isEqualToString:@"info"]) continue;
                // Rows hidden on their own page (their main switch is off) stay hidden here too.
                if (!TPConditionMet(row[@"showIf"])) continue;
                NSString *t = row[@"title"] ? TPL(row[@"title"]) : @"";
                NSString *d = row[@"detail"] ? TPL(row[@"detail"]) : @"";
                BOOL hit = ([t rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                           ([d rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                           ([locHdr rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound);
                if (hit) [matches addObject:row];
            }
        }
        _searchResults = matches;
    }
    [self layoutHeaderBox];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    if (self.isSearching) return 1;
    if (self.isRoot) return TPRootGroups().count;
    return _sections.count + (_showAbout ? 1 : 0);
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (self.isSearching) return _searchResults.count;
    if (self.isRoot) return TPRootGroups()[s].count;
    if (s >= (NSInteger)_sections.count) return 1;   // Reset All Settings (the version moved to the main page)
    NSArray *rows = [self visibleRowsInSection:s];
    if (!_shownRows) _shownRows = [NSMutableDictionary dictionary];
    _shownRows[@(s)] = rows;
    return rows.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (self.isSearching) return _searchResults.count ? TPL(@"Search Results") : TPL(@"No matching settings");
    if (self.isRoot) return nil;
    if (s >= (NSInteger)_sections.count) return nil;
    NSString *g = _sections[s][@"groupTitle"];
    return g.length ? TPL(g) : nil;
}

- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)view forSection:(NSInteger)s {
    if (self.isSearching || self.isRoot || s >= (NSInteger)_sections.count || ![_sections[s][@"groupTitle"] length]) return;
    if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
    UITableViewHeaderFooterView *h = (UITableViewHeaderFooterView *)view;
    h.textLabel.textColor = TPAccentIcon();
    h.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
}

// "Today N posts were hidden, most often for <reason>." under Content Filters (nothing on a day
// without any).
static NSString *TPFilterStatsFooter(void) {
    NSDictionary *st = [TPPrefs filterStatsToday];
    NSInteger n = [st[@"count"] integerValue];
    if (n <= 0) return nil;
    NSString *top = st[@"top"];
    return top.length ? [NSString stringWithFormat:TPL(@"Today %ld posts were hidden, most often for %@."), (long)n, top]
                      : [NSString stringWithFormat:TPL(@"Today %ld posts were hidden."), (long)n];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (self.isSearching) return nil;
    if (self.isRoot) {
        if (s != (NSInteger)TPRootGroups().count - 1) return nil;
        NSString *f = [self sectionWithHeader:@"Donate"][@"footer"];
        return [NSString stringWithFormat:@"%@\n\nMade by h4x_0x30vm", f.length ? TPL(f) : @""];
    }
    if (s >= (NSInteger)_sections.count) return nil;
    if ([_sections[s][@"groupTitle"] isEqualToString:@"Content Filters"]) return TPFilterStatsFooter();
    NSString *f = _sections[s][@"footer"];
    if (!TPConditionMet(_sections[s][@"footerIf"])) return nil;
    return f.length ? TPL(f) : nil;
}

static NSArray<NSArray *> *TPConditions(NSArray *cond) {
    if ((cond.count == 2 || cond.count == 3) && [cond[0] isKindOfClass:[NSString class]]) return @[cond];
    return cond ?: @[];
}
static BOOL TPConditionMet(NSArray *cond) {
    for (NSArray *c in TPConditions(cond))
    {
        BOOL equal = [TPPrefs integerForKey:c[0]] == [c[1] integerValue];
        BOOL negate = c.count == 3 && [c[2] isEqual:@"!="];
        if (equal == negate) return NO;
    }
    return YES;
}
static BOOL TPConditionUsesKey(NSArray *cond, NSString *key) {
    for (NSArray *c in TPConditions(cond)) if ([c[0] isEqualToString:key]) return YES;
    return NO;
}

- (NSArray<NSDictionary *> *)visibleRowsInSection:(NSInteger)s {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *row in _sections[s][@"rows"]) {
        if (!TPConditionMet(row[@"showIf"])) continue;
        [out addObject:row];
    }
    return out;
}

- (NSDictionary *)rowAt:(NSIndexPath *)ip {
    if (self.isSearching) return _searchResults[ip.row]; return [self visibleRowsInSection:ip.section][ip.row]; }

// Rows that depend on a setting are inserted or removed individually. Reloading the whole
// section cross-fades the old and new rows and leaves a visible ghost.
- (void)refreshConditionalRowsForKey:(NSString *)key {
    if (self.isSearching) { [self runSearch]; return; }
    for (NSInteger sec = 0; sec < (NSInteger)_sections.count; sec++) {
        BOOL footerAffected = TPConditionUsesKey(_sections[sec][@"footerIf"], key);
        BOOL rowsAffected = NO;
        for (NSDictionary *row in _sections[sec][@"rows"])
            if (TPConditionUsesKey(row[@"showIf"], key)) rowsAffected = YES;
        if (!rowsAffected && !footerAffected) continue;

        NSArray *before = _shownRows[@(sec)] ?: [self visibleRowsInSection:sec];
        NSArray *after = [self visibleRowsInSection:sec];
        NSMutableArray *deletes = [NSMutableArray array], *inserts = [NSMutableArray array];
        [before enumerateObjectsUsingBlock:^(id row, NSUInteger i, BOOL *stop) {
            if ([after indexOfObjectIdenticalTo:row] == NSNotFound) [deletes addObject:[NSIndexPath indexPathForRow:i inSection:sec]];
        }];
        [after enumerateObjectsUsingBlock:^(id row, NSUInteger i, BOOL *stop) {
            if ([before indexOfObjectIdenticalTo:row] == NSNotFound) [inserts addObject:[NSIndexPath indexPathForRow:i inSection:sec]];
        }];
        NSString *footer = [self tableView:self.tableView titleForFooterInSection:sec];
        UITableViewHeaderFooterView *fv = [self.tableView footerViewForSection:sec];
        BOOL footerNeedsReload = footerAffected && !fv && footer.length;
        [self.tableView performBatchUpdates:^{
            if (deletes.count) [self.tableView deleteRowsAtIndexPaths:deletes withRowAnimation:UITableViewRowAnimationFade];
            if (inserts.count) [self.tableView insertRowsAtIndexPaths:inserts withRowAnimation:UITableViewRowAnimationFade];
            if (footerAffected && fv) { fv.textLabel.text = footer; [fv setNeedsLayout]; }
        } completion:^(BOOL finished) {
            if (footerNeedsReload)
                [UIView performWithoutAnimation:^{ [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:sec] withRowAnimation:UITableViewRowAnimationNone]; }];
        }];
    }
}

- (UITableViewCell *)captionCellForRow:(NSDictionary *)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    TPApplyCardBackground(cell);
    UILabel *l = [UILabel new];
    l.text = TPL(row[@"title"]);
    l.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    l.textColor = UIColor.secondaryLabelColor;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:l];
    UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [l.leadingAnchor constraintEqualToAnchor:m.leadingAnchor constant:38],
        [l.trailingAnchor constraintLessThanOrEqualToAnchor:m.trailingAnchor],
        [l.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
        [l.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4],
    ]];
    return cell;
}

- (UITableViewCell *)segmentCellForRow:(NSDictionary *)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    TPApplyCardBackground(cell);
    UIView *cv = cell.contentView;

    UIImageView *icon = [[UIImageView alloc] initWithImage:TPLineIcon(row[@"icon"])];
    icon.tintColor = TPAccentIcon();
    icon.contentMode = UIViewContentModeCenter;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:icon];

    UILabel *title = [UILabel new];
    title.text = TPL(row[@"title"]);
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    title.textColor = UIColor.labelColor;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:title];

    NSArray<NSString *> *segs = row[@"segments"];
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (NSString *seg in segs) [labels addObject:TPL(seg)];
    UISegmentedControl *sc = [[UISegmentedControl alloc] initWithItems:labels];
    NSInteger cur = MAX(0, MIN([TPPrefs integerForKey:row[@"key"]], (NSInteger)segs.count - 1));
    sc.selectedSegmentIndex = cur;
    sc.backgroundColor = TPDyn([UIColor colorWithWhite:0 alpha:0.05], [UIColor colorWithWhite:1 alpha:0.06]);
    sc.selectedSegmentTintColor = TPAccent();
    [sc setTitleTextAttributes:@{ NSForegroundColorAttributeName: UIColor.secondaryLabelColor,
                                  NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightMedium] }
                      forState:UIControlStateNormal];
    [sc setTitleTextAttributes:@{ NSForegroundColorAttributeName: UIColor.whiteColor,
                                  NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold] }
                      forState:UIControlStateSelected];
    NSString *key = row[@"key"];
    UILabel *preview = nil;
    if ([row[@"note"] length]) {
        preview = [UILabel new];
        preview.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        preview.textColor = UIColor.secondaryLabelColor;
        preview.numberOfLines = 0;
        preview.text = TPL(row[@"note"]);
        preview.translatesAutoresizingMaskIntoConstraints = NO;
        [cv addSubview:preview];
    }
    __weak typeof(self) weakSelf = self;
    [sc addAction:[UIAction actionWithHandler:^(UIAction *a) {
        NSInteger idx = ((UISegmentedControl *)a.sender).selectedSegmentIndex;
        [TPPrefs setInteger:idx forKey:key];
        [TPUI hapticLight];
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refreshConditionalRowsForKey:key]; });
    }] forControlEvents:UIControlEventValueChanged];
    sc.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:sc];

    UILayoutGuide *m = cv.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [icon.widthAnchor constraintEqualToConstant:26],
        [icon.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:m.trailingAnchor],
        [title.topAnchor constraintEqualToAnchor:cv.topAnchor constant:14],
        [sc.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [sc.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [sc.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [sc.heightAnchor constraintEqualToConstant:32],
    ]];
    if (preview) {
        [NSLayoutConstraint activateConstraints:@[
            [preview.topAnchor constraintEqualToAnchor:sc.bottomAnchor constant:10],
            [preview.leadingAnchor constraintEqualToAnchor:m.leadingAnchor constant:2],
            [preview.trailingAnchor constraintLessThanOrEqualToAnchor:m.trailingAnchor],
            [preview.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-14],
        ]];
    } else {
        [sc.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-14].active = YES;
    }
    return cell;
}

// "26.1 (23B85)": the build number tells betas and point releases apart.
static NSString *TPOSVersionWithBuild(void) {
    NSString *v = UIDevice.currentDevice.systemVersion ?: @"?";
    char buf[32] = {0};
    size_t len = sizeof(buf);
    if (sysctlbyname("kern.osversion", buf, &len, NULL, 0) == 0 && buf[0]) v = [NSString stringWithFormat:@"%@ (%s)", v, buf];
    return v;
}

// "iPhone 15 Pro (iPhone16,1)". Unknown or newer models show the identifier alone.
static NSString *TPDeviceModel(void) {
    char buf[64] = {0};
    size_t len = sizeof(buf);
    if (sysctlbyname("hw.machine", buf, &len, NULL, 0) != 0 || !buf[0]) return UIDevice.currentDevice.model ?: @"?";
    NSString *idf = [NSString stringWithUTF8String:buf];
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            @"iPhone11,2": @"iPhone XS", @"iPhone11,4": @"iPhone XS Max", @"iPhone11,6": @"iPhone XS Max", @"iPhone11,8": @"iPhone XR",
            @"iPhone12,1": @"iPhone 11", @"iPhone12,3": @"iPhone 11 Pro", @"iPhone12,5": @"iPhone 11 Pro Max", @"iPhone12,8": @"iPhone SE (2nd generation)",
            @"iPhone13,1": @"iPhone 12 mini", @"iPhone13,2": @"iPhone 12", @"iPhone13,3": @"iPhone 12 Pro", @"iPhone13,4": @"iPhone 12 Pro Max",
            @"iPhone14,4": @"iPhone 13 mini", @"iPhone14,5": @"iPhone 13", @"iPhone14,2": @"iPhone 13 Pro", @"iPhone14,3": @"iPhone 13 Pro Max",
            @"iPhone14,6": @"iPhone SE (3rd generation)", @"iPhone14,7": @"iPhone 14", @"iPhone14,8": @"iPhone 14 Plus",
            @"iPhone15,2": @"iPhone 14 Pro", @"iPhone15,3": @"iPhone 14 Pro Max", @"iPhone15,4": @"iPhone 15", @"iPhone15,5": @"iPhone 15 Plus",
            @"iPhone16,1": @"iPhone 15 Pro", @"iPhone16,2": @"iPhone 15 Pro Max",
            @"iPhone17,3": @"iPhone 16", @"iPhone17,4": @"iPhone 16 Plus", @"iPhone17,1": @"iPhone 16 Pro", @"iPhone17,2": @"iPhone 16 Pro Max",
            @"iPhone17,5": @"iPhone 16e",
            @"iPhone18,3": @"iPhone 17", @"iPhone18,4": @"iPhone Air", @"iPhone18,1": @"iPhone 17 Pro", @"iPhone18,2": @"iPhone 17 Pro Max",
            @"iPhone18,5": @"iPhone 17e",
            // 2026. iPhone19,1/19,5/19,6 aren't confirmed yet, so they show as the identifier alone.
            @"iPhone19,2": @"iPhone 18 Pro", @"iPhone19,3": @"iPhone 18 Pro Max", @"iPhone19,7": @"iPhone 18 Pro Max",
            @"iPhone19,4": @"iPhone Duo",
        };
    });
    NSString *name = names[idf];
    return name ? [NSString stringWithFormat:@"%@ (%@)", name, idf] : idf;
}

// Facts that help when reporting a problem (About page, Copy All Info, issue template).
static NSArray<NSArray<NSString *> *> *TPAboutRows(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *ver = info[@"CFBundleShortVersionString"] ?: @"?", *build = info[@"CFBundleVersion"];
    NSString *threads = build.length && ![build isEqualToString:ver] ? [NSString stringWithFormat:@"%@ (%@)", ver, build] : ver;
    return @[ @[@"Plugin Version", TP_VERSION, @"waveform.path.ecg"],
              @[@"Threads Version", threads, @"at"],
              @[@"Bundle ID", NSBundle.mainBundle.bundleIdentifier ?: @"?", @"shippingbox"],
              @[@"iOS Version", TPOSVersionWithBuild(), @"gear"],
              @[@"Device", TPDeviceModel(), @"iphone"] ];
}

- (void)copyAbout:(id)sender {
    if ([sender isKindOfClass:[UIGestureRecognizer class]] && [(UIGestureRecognizer *)sender state] != UIGestureRecognizerStateBegan) return;
    NSMutableArray *lines = [NSMutableArray array];
    for (NSArray *r in TPAboutRows()) [lines addObject:[NSString stringWithFormat:@"%@: %@", r[0], r[1]]];
    UIPasteboard.generalPasteboard.string = [lines componentsJoinedByString:@"\n"];
    [TPUI hapticLight];
    [TPHUD toast:TPL(@"Copied")];
}

// Download Manager row: the live state on the right (downloading %, queue, failures in red).
- (NSAttributedString *)downloadStatusText {
    NSMutableArray<NSAttributedString *> *parts = [NSMutableArray array];
    NSDictionary *plain = @{ NSForegroundColorAttributeName: UIColor.secondaryLabelColor };
    if ([TPDownloader activeRecordID]) {
        NSString *t = _downloadPercent ? [NSString stringWithFormat:@"%@ %@", TPL(@"Downloading"), _downloadPercent] : TPL(@"Downloading");
        [parts addObject:[[NSAttributedString alloc] initWithString:t attributes:@{ NSForegroundColorAttributeName: TPAccent() }]];
    }
    NSInteger queued = (NSInteger)[TPDownloader queuedRecordIDs].count;
    if (queued) [parts addObject:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:TPL(@"%ld in queue"), (long)queued] attributes:plain]];
    NSInteger failed = [TPDownloadStore failedRecordCount];
    if (failed) [parts addObject:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:TPL(@"%ld failed"), (long)failed]
                                                                  attributes:@{ NSForegroundColorAttributeName: UIColor.systemRedColor }]];
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    for (NSAttributedString *p in parts) {
        if (out.length) [out appendAttributedString:[[NSAttributedString alloc] initWithString:@" · " attributes:plain]];
        [out appendAttributedString:p];
    }
    return out;
}

- (void)downloadsChanged:(NSNotification *)n {
    if ([n.name isEqualToString:TPDownloadProgressNotification]) {
        NSString *p = [NSString stringWithFormat:@"%.0f%%", floor([n.userInfo[@"progress"] doubleValue] * 100)];
        if ([p isEqualToString:_downloadPercent]) return;
        _downloadPercent = p;
    } else if (![TPDownloader activeRecordID]) {
        _downloadPercent = nil;
    }
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    UIListContentConfiguration *c = (UIListContentConfiguration *)cell.contentConfiguration;
    if (![c isKindOfClass:[UIListContentConfiguration class]]) return;
    c = [c copy];
    c.secondaryAttributedText = [self downloadStatusText];
    cell.contentConfiguration = c;
}

// "New" marks after an update: a pill on a new page, a dot on a page with new options, and a
// pill after each new option's name, until that page has been opened and left. Only after an
// update (the What's New check sets the flag): on a new install everything is new.
static NSDictionary<NSString *, NSArray<NSString *> *> *TPNewInThisRelease(void) {
    return @{ @"Ads & Privacy": @[TPKeyBlockAds],
              @"Interface & Interactions": @[@"timeFormat"],
              @"Advanced": @[@"clearCache"] };
}
static NSString *const kTPNewSeenKey = @"tp_new_seen_1_33";
static BOOL TPPageHasNew(NSString *header) {
    NSUserDefaults *d = [TPPrefs defaults];
    if (![d boolForKey:@"tp_new_badges_1_33"] || !TPNewInThisRelease()[header]) return NO;
    return ![[d arrayForKey:kTPNewSeenKey] containsObject:header];
}
static BOOL TPRowIsNew(NSString *header, NSDictionary *row) {
    if (!TPPageHasNew(header)) return NO;
    NSString *ident = row[@"key"] ?: row[@"action"];
    return ident && [TPNewInThisRelease()[header] containsObject:ident];
}
static void TPMarkPageSeen(NSString *header) {
    if (!TPPageHasNew(header)) return;
    NSUserDefaults *d = [TPPrefs defaults];
    NSMutableArray *seen = [[d arrayForKey:kTPNewSeenKey] mutableCopy] ?: [NSMutableArray array];
    [seen addObject:header];
    [d setObject:seen forKey:kTPNewSeenKey];
}

// A small accent "New" pill, or a dot, then a chevron.
static UIView *TPNewAccessory(BOOL pill) {
    UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]]];
    arrow.tintColor = UIColor.tertiaryLabelColor;
    [arrow sizeToFit];
    UIView *mark;
    if (pill) {
        UILabel *l = [UILabel new];
        l.text = TPL(@"New");
        l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        l.textColor = TPAccent();
        l.textAlignment = NSTextAlignmentCenter;
        l.backgroundColor = [TPAccent() colorWithAlphaComponent:0.16];
        l.layer.cornerRadius = 6;
        l.layer.masksToBounds = YES;
        [l sizeToFit];
        l.frame = CGRectMake(0, 0, l.bounds.size.width + 12, 20);
        mark = l;
    } else {
        mark = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
        mark.backgroundColor = TPAccent();
        mark.layer.cornerRadius = 4;
    }
    CGFloat h = MAX(mark.bounds.size.height, arrow.bounds.size.height);
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, mark.bounds.size.width + 8 + arrow.bounds.size.width, h)];
    mark.center = CGPointMake(mark.bounds.size.width / 2, h / 2);
    arrow.center = CGPointMake(box.bounds.size.width - arrow.bounds.size.width / 2, h / 2);
    [box addSubview:mark];
    [box addSubview:arrow];
    return box;
}

- (UITableViewCell *)rootCellAt:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSString *h = TPRootGroups()[ip.section][ip.row];
    if ([h isEqualToString:@"Download Manager"]) {
        UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
        c.text = TPL(h);
        c.secondaryAttributedText = [self downloadStatusText];
        c.image = TPSquareIcon(TPCategoryIcon(h), TPAccent());
        c.imageToTextPadding = 14;
        cell.contentConfiguration = c;
        TPApplyCardBackground(cell);
        if (TPPageHasNew(h)) cell.accessoryView = TPNewAccessory(YES);
        else cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if ([h isEqualToString:@"Telegram"]) {
        // Opens outside the settings (the Telegram app when installed), hence the arrow.
        UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
        c.text = TPL(@"Join the Telegram Group");
        c.image = TPSquareIcon(@"paperplane", TPAccent());
        c.imageToTextPadding = 14;
        cell.contentConfiguration = c;
        TPApplyCardBackground(cell);
        UIImageView *ext = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.right"
            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold]]];
        ext.tintColor = UIColor.tertiaryLabelColor;
        cell.accessoryView = ext;
        return cell;
    }
    NSDictionary *sec = [self sectionWithHeader:h];
    BOOL donate = [h isEqualToString:@"Donate"];
    NSDictionary *link = donate ? [sec[@"rows"] firstObject] : nil;
    UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
    c.text = TPL(donate ? link[@"title"] : h);
    c.secondaryText = donate ? nil : [h isEqualToString:@"About"] ? TP_VERSION : [self summaryForSection:sec];
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    c.image = TPSquareIcon(TPCategoryIcon(h), donate ? TPKofiColor() : TPAccent());
    c.imageToTextPadding = 14;
    cell.contentConfiguration = c;
    TPApplyCardBackground(cell);
    if (donate) {
        UIBackgroundConfiguration *bg = [UIBackgroundConfiguration listGroupedCellConfiguration];
        bg.backgroundColor = [TPKofiColor() colorWithAlphaComponent:0.12];
        bg.strokeColor = [TPKofiColor() colorWithAlphaComponent:0.40];
        bg.strokeWidth = 0.5;
        cell.backgroundConfiguration = bg;
    }
    if (TPPageHasNew(h)) cell.accessoryView = TPNewAccessory(NO);
    else cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

// Optional grey value, then a chevron, as in iOS Settings.
// The cache size in an accent pill, then a chevron: it opens a page and the size should stand out.
static UIView *TPSizePillAccessory(NSString *value) {
    UILabel *l = [UILabel new];
    l.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
    l.textColor = TPAccentIcon();
    l.text = value;
    [l sizeToFit];
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, l.bounds.size.width + 20, 28)];
    pill.backgroundColor = [TPAccent() colorWithAlphaComponent:0.16];
    pill.layer.cornerRadius = 14;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    l.center = CGPointMake(pill.bounds.size.width / 2, 14);
    [pill addSubview:l];
    UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]]];
    arrow.tintColor = UIColor.tertiaryLabelColor;
    [arrow sizeToFit];
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pill.bounds.size.width + 8 + arrow.bounds.size.width, 28)];
    [box addSubview:pill];
    arrow.center = CGPointMake(box.bounds.size.width - arrow.bounds.size.width / 2, 14);
    [box addSubview:arrow];
    return box;
}

static UIView *TPChevronAccessory(NSString *value) {
    UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]]];
    arrow.tintColor = UIColor.tertiaryLabelColor;
    [arrow sizeToFit];
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:15];
    l.textColor = UIColor.secondaryLabelColor;
    l.text = value;
    [l sizeToFit];
    CGFloat gap = value.length ? 6 : 0;
    CGFloat h = MAX(l.bounds.size.height, arrow.bounds.size.height);
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, (value.length ? l.bounds.size.width : 0) + gap + arrow.bounds.size.width, h)];
    if (value.length) { l.frame = CGRectMake(0, (h - l.bounds.size.height) / 2, l.bounds.size.width, l.bounds.size.height); [box addSubview:l]; }
    arrow.frame = CGRectMake(box.bounds.size.width - arrow.bounds.size.width, (h - arrow.bounds.size.height) / 2, arrow.bounds.size.width, arrow.bounds.size.height);
    [box addSubview:arrow];
    return box;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.isRoot && !self.isSearching) return [self rootCellAt:ip];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];

    if (!self.isSearching && ip.section >= (NSInteger)_sections.count) {
        UIListContentConfiguration *c = [UIListContentConfiguration cellConfiguration];
        c.text = TPL(@"Reset All Settings");
        c.textProperties.color = UIColor.systemRedColor;
        TPApplyIcon(c, @"arrow.counterclockwise", UIColor.systemRedColor);
        cell.contentConfiguration = c;
        TPApplyCardBackground(cell);
        return cell;
    }

    NSDictionary *row = [self rowAt:ip];
    NSString *type = row[@"type"];
    if ([type isEqualToString:@"segment"]) return [self segmentCellForRow:row];
    if ([type isEqualToString:@"info"]) {
        UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
        c.text = TPL(row[@"title"]);
        c.secondaryText = row[@"value"];
        c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        c.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        c.secondaryTextProperties.numberOfLines = 1;
        c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
        TPApplyIcon(c, row[@"icon"], nil);
        cell.contentConfiguration = c;
        TPApplyCardBackground(cell);
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        [cell addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(copyAbout:)]];
        return cell;
    }
    if ([type isEqualToString:@"weblink"]) {
        UIListContentConfiguration *c = [UIListContentConfiguration cellConfiguration];
        c.text = TPL(row[@"title"]);
        TPApplyIcon(c, row[@"icon"], nil);
        cell.contentConfiguration = c;
        TPApplyCardBackground(cell);
        UIImageView *ext = [[UIImageView alloc] initWithImage:
            [UIImage systemImageNamed:@"arrow.up.right"
                    withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold]]];
        ext.tintColor = UIColor.tertiaryLabelColor;
        cell.accessoryView = ext;
        return cell;
    }
    if ([type isEqualToString:@"caption"]) return [self captionCellForRow:row];
    // Post Time Format shows what it currently looks like instead of a fixed description.
    BOOL liveDetail = [row[@"action"] isEqualToString:@"timeFormat"];
    NSString *detail = liveDetail ? [NSString stringWithFormat:TPL(@"Example: %@"), TPPostTimeExample()] : row[@"detail"];

    UIListContentConfiguration *c = detail.length ? [UIListContentConfiguration subtitleCellConfiguration]
                                                  : [UIListContentConfiguration cellConfiguration];
    c.text = TPL(row[@"title"]);
    if (!self.isRoot && !self.isSearching && TPRowIsNew(_allSections[_category][@"header"], row)) {
        NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:[TPL(row[@"title"]) stringByAppendingString:@"  "]
            attributes:@{ NSFontAttributeName: c.textProperties.font, NSForegroundColorAttributeName: UIColor.labelColor }];
        [t appendAttributedString:[[NSAttributedString alloc] initWithString:TPL(@"New") attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: TPAccent() }]];
        c.attributedText = t;
    }
    if (detail.length) {
        c.secondaryText = liveDetail ? detail : TPL(detail);
        c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        c.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        c.textToSecondaryTextVerticalPadding = 3;
    }
    TPApplyIcon(c, row[@"icon"], nil);
    TPApplyCardBackground(cell);
    if ([row[@"action"] isEqualToString:@"clearCache"]) cell.accessoryView = TPSizePillAccessory(sTPCacheSize ?: @"…");
    // Rows that open a page of their own get a chevron (and the muted rules their count), so
    // they read as something to tap into rather than plain text.
    NSString *act = row[@"action"];
    if ([act isEqualToString:@"editKeywords"] || [act isEqualToString:@"authorStats"] || [act isEqualToString:@"nameFormat"] || [act isEqualToString:@"timeFormat"]) {
        NSString *value = nil;
        if ([act isEqualToString:@"editKeywords"]) {
            NSUInteger n = [TPPrefs mutedRules].count;
            value = n ? [NSString stringWithFormat:TPL(@"%lu rules"), (unsigned long)n] : TPL(@"None");
        }
        cell.accessoryView = TPChevronAccessory(value);
    }

    if ([type isEqualToString:@"switch"]) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [UISwitch new];
        sw.onTintColor = TPAccent();
        sw.on = [TPPrefs boolForKey:row[@"key"]];
        // Keyed by the setting itself: rows above can be inserted or removed later, so a stored
        // index would point at the wrong row.
        objc_setAssociatedObject(sw, kTPSwitchKey, row[@"key"], OBJC_ASSOCIATION_COPY_NONATOMIC);
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if ([type isEqualToString:@"link"]) {
        UIBackgroundConfiguration *bg = [UIBackgroundConfiguration listGroupedCellConfiguration];
        bg.backgroundColor = [TPKofiColor() colorWithAlphaComponent:0.12];
        bg.strokeColor = [TPKofiColor() colorWithAlphaComponent:0.40];
        bg.strokeWidth = 0.5;
        cell.backgroundConfiguration = bg;
        c.imageProperties.tintColor = TPKofiColor();
        UIImageView *arrow = [[UIImageView alloc] initWithImage:
            [UIImage systemImageNamed:@"chevron.right"
                    withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold]]];
        arrow.tintColor = UIColor.tertiaryLabelColor;
        cell.accessoryView = arrow;
    }
    cell.contentConfiguration = c;
    return cell;
}

static const void *kTPSwitchKey = &kTPSwitchKey;


- (void)switchChanged:(UISwitch *)sw {
    NSString *key = objc_getAssociatedObject(sw, kTPSwitchKey);
    if (!key) return;
    [TPPrefs setBool:sw.on forKey:key];
    [TPUI hapticLight];
    [_header setEnabledCount:[self enabledFeatureCount]];
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshConditionalRowsForKey:key]; });
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.isRoot && !self.isSearching) {
        NSString *h = TPRootGroups()[ip.section][ip.row];
        if ([h isEqualToString:@"Download Manager"]) {
            TPMarkPageSeen(h);
            [self.navigationController pushViewController:[TPDownloadManagerViewController new] animated:YES];
            return;
        }
        if ([h isEqualToString:@"Telegram"]) {
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:kTPTelegramURL] options:@{} completionHandler:nil];
            return;
        }
        if ([h isEqualToString:@"Donate"]) { [self openLink:[[self sectionWithHeader:h][@"rows"] firstObject][@"url"]]; return; }
        NSUInteger idx = [_allSections indexOfObject:[self sectionWithHeader:h]];
        if (idx == NSNotFound) return;
        TPSettingsViewController *detail = [[TPSettingsViewController alloc] initWithCategory:idx];
        [self.navigationController pushViewController:detail animated:YES];
        return;
    }
    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];

    if (!self.isSearching && ip.section >= (NSInteger)_sections.count) {
        [self confirmReset];
        return;
    }
    NSDictionary *row = [self rowAt:ip];
    NSString *type = row[@"type"];
    if ([type isEqualToString:@"action"]) {
        if ([row[@"action"] isEqualToString:@"export"]) [self exportSettingsFrom:cell];
        else if ([row[@"action"] isEqualToString:@"resetSeenChats"]) [self confirmResetSeenChats];
        else if ([row[@"action"] isEqualToString:@"analyticsLog"]) [self showAnalyticsLog];
        else if ([row[@"action"] isEqualToString:@"clearCache"]) [self confirmClearCache];
        else if ([row[@"action"] isEqualToString:@"welcome"]) [TPWelcomeViewController present];
        else if ([row[@"action"] isEqualToString:@"whatsNew"]) [TPWelcomeViewController presentWhatsNew];
        else if ([row[@"action"] isEqualToString:@"authorStatus"]) [self showAuthorStatus];
        else if ([row[@"action"] isEqualToString:@"authorStats"]) [self.navigationController pushViewController:[TPAuthorStatsViewController new] animated:YES];
        else if ([row[@"action"] isEqualToString:@"copyAbout"]) [self copyAbout:nil];
        else if ([row[@"action"] isEqualToString:@"checkUpdate"]) [TPUpdateChecker checkNow];
        else if ([row[@"action"] isEqualToString:@"editKeywords"]) [self editMutedKeywords];
        else if ([row[@"action"] isEqualToString:@"nameFormat"]) [self.navigationController pushViewController:[TPFileNameFormatViewController new] animated:YES];
        else if ([row[@"action"] isEqualToString:@"timeFormat"]) [self.navigationController pushViewController:[TPPostTimeFormatViewController new] animated:YES];
        else [self importSettings];
    } else if ([type isEqualToString:@"link"]) {
        [self openLink:row[@"url"]];
    } else if ([type isEqualToString:@"weblink"]) {
        if ([row[@"action"] isEqualToString:@"report"]) {
            // A new GitHub issue with the environment filled in.
            NSMutableString *body = [NSMutableString stringWithString:@"**What happened**\n\n\n**Steps to reproduce**\n\n\n**Environment**\n"];
            for (NSArray *r in TPAboutRows()) [body appendFormat:@"- %@: %@\n", r[0], r[1]];
            NSURLComponents *u = [NSURLComponents componentsWithString:[kTPRepoURL stringByAppendingString:@"/issues/new"]];
            u.queryItems = @[[NSURLQueryItem queryItemWithName:@"body" value:body]];
            [self openLink:u.URL.absoluteString];
        } else {
            [self openLink:row[@"url"]];
        }
    }
}

- (void)openLink:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    SFSafariViewController *sf = [[SFSafariViewController alloc] initWithURL:url];
    sf.preferredControlTintColor = TPKofiColor();
    sf.dismissButtonStyle = SFSafariViewControllerDismissButtonStyleClose;
    [self presentViewController:sf animated:YES completion:nil];
}

- (void)confirmReset {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:TPL(@"Reset All Settings?") message:nil
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Reset") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [TPPrefs resetAll];
        [[NSNotificationCenter defaultCenter] postNotificationName:TPThemeDidChangeNotification object:nil];
        [self applyTheme];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showAnalyticsLog {
    NSString *r = TPAnalyticsLogReport();
    if (!r) { [TPHUD toast:TPL(@"No analytics recorded yet")]; return; }
    [TPDownloader showReport:r];
}

- (void)showAuthorStatus {
    NSTimeInterval left = [TPAuthorInfo pausedRemaining];
    NSMutableString *msg = [NSMutableString stringWithFormat:TPL(@"%lu authors cached · %lu read since launch"),
                            (unsigned long)[TPAuthorInfo cachedCount], (unsigned long)[TPAuthorInfo sessionRequestCount]];
    [msg appendString:@"\n"];
    if (left > 0) [msg appendFormat:TPL(@"Paused by rate limit protection, resumes in %ld min"), (long)ceil(left / 60.0)];
    else [msg appendString:TPL(@"Reading normally")];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:TPL(@"Read Status & Cache") message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    if (left > 0) {
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"Resume Now") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [TPAuthorInfo resume];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Clear Cache") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [TPAuthorInfo clearCache];
        [TPHUD toast:TPL(@"Cache cleared")];
    }]];
    if ([TPPrefs boolForKey:TPKeyDebugToast]) {
        [a addAction:[UIAlertAction actionWithTitle:TPL(@"Diagnostics") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [TPDownloader showReport:[TPAuthorInfo diagnostics]];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Close") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)confirmResetSeenChats {
    NSArray *list = [[NSUserDefaults standardUserDefaults] arrayForKey:@"tp_seen_allowed_chats"];
    if (!list.count) { [TPHUD toast:TPL(@"No chats set to show Seen")]; return; }
    NSString *msg = [NSString stringWithFormat:TPL(@"%lu chats will hide \"Seen\" again"), (unsigned long)list.count];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:TPL(@"Reset Chats") message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Reset") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"tp_seen_allowed_chats"];
        [TPHUD toast:TPL(@"All chats hide Seen")];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)exportSettingsFrom:(UIView *)source {
    NSData *data = [TPPrefs exportJSONData];
    NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"ThreadsPulse-Settings.json"]];
    if (!data || ![data writeToURL:file atomically:YES]) {
        [TPHUD toast:TPL(@"Export failed")];
        return;
    }
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    av.popoverPresentationController.sourceView = source;
    av.popoverPresentationController.sourceRect = source.bounds;
    [self presentViewController:av animated:YES completion:nil];
}

- (void)importSettings {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSData *data = urls.firstObject ? [NSData dataWithContentsOfURL:urls.firstObject] : nil;
    NSInteger rules = 0, authors = 0;
    NSInteger n = [TPPrefs importJSONData:data mutedRules:&rules authors:&authors];
    [[NSNotificationCenter defaultCenter] postNotificationName:TPThemeDidChangeNotification object:nil];
    [self applyTheme];
    if (n < 0) { [TPUI hapticError];   [TPHUD toast:TPL(@"Invalid settings file")]; }
    else {
        [TPUI hapticSuccess];
        NSMutableString *msg = [NSMutableString stringWithFormat:TPL(@"Imported %ld settings"), (long)n];
        if (rules) [msg appendFormat:@" · %@", [NSString stringWithFormat:TPL(@"%ld muted rules"), (long)rules]];
        if (authors) [msg appendFormat:@" · %@", [NSString stringWithFormat:TPL(@"%ld authors"), (long)authors]];
        [TPHUD toast:msg];
    }
}
#pragma mark - Clear cache

// The Clear Cache page lists each kind of cache with its size. Temporary files, the network cache
// and download leftovers are cleared right away. Image, video and other Threads caches are in use
// while Threads runs, so those are cleared at the next launch, before Threads opens any of them.
// Login, settings, drafts and the download history live elsewhere and are never touched.
static NSString *const kTPClearCachePending = @"tp_clear_cache_pending";
static NSString *const kTPClearCacheKinds   = @"tp_clear_cache_kinds";

static NSString *TPCachesDir(void) {
    return NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
}

static unsigned long long TPDirSize(NSString *dir) {
    unsigned long long total = 0;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:dir]
        includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey] options:0 errorHandler:nil];
    for (NSURL *u in e) {
        NSNumber *n = nil;
        [u getResourceValue:&n forKey:NSURLTotalFileAllocatedSizeKey error:nil];
        total += n.unsignedLongLongValue;
    }
    return total;
}

static unsigned long long TPItemSize(NSString *p) {
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&isDir]) return 0;
    if (isDir) return TPDirSize(p);
    NSNumber *n = nil;
    [[NSURL fileURLWithPath:p] getResourceValue:&n forKey:NSURLTotalFileAllocatedSizeKey error:nil];
    return n ? n.unsignedLongLongValue : [[NSFileManager.defaultManager attributesOfItemAtPath:p error:nil] fileSize];
}

// Which kind a top-level entry of Library/Caches is. "keep" is never cleared: iOS's own folders
// (dyld, background transfers), media for messages being sent, and per-account folders named
// with the account ID (seen state and the like).
static NSString *TPCacheKindForName(NSString *name) {
    NSString *n = name.lowercaseString;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier.lowercaseString;
    if ([n hasPrefix:@"com.apple."] || [n containsString:@"outgoing"]) return @"keep";
    if ([n rangeOfString:@"[0-9]{8,}" options:NSRegularExpressionSearch].location != NSNotFound) return @"keep";
    if ((bid.length && [n isEqualToString:bid]) || [n containsString:@"networking"] || [n containsString:@"igcache-"]) return @"url";
    if ([n containsString:@"image"]) return @"image";
    if ([n containsString:@"video"] || [n containsString:@"fnf"] || [n containsString:@"dash"] || [n containsString:@"media"]) return @"video";
    return @"other";
}

// Files ThreadsPulse itself leaves in tmp while downloading, converting or exporting settings.
static BOOL TPIsOwnTempName(NSString *name) {
    return [name hasPrefix:@"threads_"] || [name hasPrefix:@"tp_"] || [name hasPrefix:@"ThreadsPulse-"];
}

static NSString *TPStagingDir(void) {
    NSString *as = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [as stringByAppendingPathComponent:@"ThreadsPulse/Downloads/Thumbs"];
}

// Items that can be cleared while Threads runs. Anything changed in the last 2 minutes is left
// alone, in case Threads or a download is still writing it.
static NSArray<NSString *> *TPLiveCachePaths(NSString *kind) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *out = [NSMutableArray array];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-120];
    void (^add)(NSString *, NSString *) = ^(NSString *dir, NSString *name) {
        NSString *p = [dir stringByAppendingPathComponent:name];
        NSDate *m = [[fm attributesOfItemAtPath:p error:nil] fileModificationDate];
        if (m && [m compare:cutoff] == NSOrderedDescending) return;
        [out addObject:p];
    };
    NSString *tmp = NSTemporaryDirectory();
    if ([kind isEqualToString:@"tmp"] || [kind isEqualToString:@"tpdl"]) {
        BOOL own = [kind isEqualToString:@"tpdl"];
        for (NSString *name in [fm contentsOfDirectoryAtPath:tmp error:nil])
            if (TPIsOwnTempName(name) == own) add(tmp, name);
    }
    if ([kind isEqualToString:@"tpdl"]) {
        NSString *stage = TPStagingDir();
        for (NSString *name in [fm contentsOfDirectoryAtPath:stage error:nil])
            if ([name hasPrefix:@"stage_"]) add(stage, name);
    }
    return out;
}

static NSArray<NSString *> *TPRestartCachePaths(NSString *kind) {
    NSString *caches = TPCachesDir();
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:caches error:nil])
        if ([TPCacheKindForName(name) isEqualToString:kind]) [out addObject:[caches stringByAppendingPathComponent:name]];
    return out;
}

static unsigned long long TPRemovePaths(NSArray<NSString *> *paths) {
    unsigned long long freed = 0;
    for (NSString *p in paths) {
        unsigned long long sz = TPItemSize(p);
        if ([NSFileManager.defaultManager removeItemAtPath:p error:nil]) freed += sz;
    }
    return freed;
}

static NSArray<NSString *> *TPLiveKinds(void)    { return @[@"tmp", @"tpdl"]; }
static NSArray<NSString *> *TPRestartKinds(void) { return @[@"image", @"video", @"url", @"other"]; }

// Size of each kind of cache. Folders that are never cleared aren't counted, so the Clear Cache
// row and its page show the same total.
static NSDictionary<NSString *, NSNumber *> *TPCacheSizesByKind(void) {
    NSMutableDictionary *sizes = [NSMutableDictionary dictionary];
    for (NSString *k in TPLiveKinds()) {
        unsigned long long n = 0;
        for (NSString *p in TPLiveCachePaths(k)) n += TPItemSize(p);
        sizes[k] = @(n);
    }
    for (NSString *k in TPRestartKinds()) {
        unsigned long long n = 0;
        for (NSString *p in TPRestartCachePaths(k)) n += TPItemSize(p);
        sizes[k] = @(n);
    }
    return sizes;
}

static unsigned long long TPCacheTotal(NSDictionary<NSString *, NSNumber *> *sizes) {
    unsigned long long total = 0;
    for (NSNumber *n in sizes.allValues) total += n.unsignedLongLongValue;
    return total;
}

+ (void)runPendingCacheClear {
    NSUserDefaults *d = [TPPrefs defaults];
    if (![d boolForKey:kTPClearCachePending]) return;
    NSArray *kinds = [d arrayForKey:kTPClearCacheKinds];
    [d removeObjectForKey:kTPClearCachePending];
    [d removeObjectForKey:kTPClearCacheKinds];
    unsigned long long freed = 0;
    // Set by an older version, which cleared everything: clear every kind instead.
    if (!kinds.count) {
        kinds = @[@"image", @"video", @"url", @"other"];
        freed += TPRemovePaths(TPLiveCachePaths(@"tmp"));
    }
    for (NSString *kind in kinds) if ([kind isKindOfClass:NSString.class]) freed += TPRemovePaths(TPRestartCachePaths(kind));
    NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)freed countStyle:NSByteCountFormatterCountStyleFile];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [TPHUD toast:[NSString stringWithFormat:TPL(@"Cleared %@ of cache"), size]];
    });
}

// Measured when a page with the Clear Cache row opens, so the row shows the size before it's tapped.
- (void)refreshCacheSize {
    BOOL hasRow = NO;
    for (NSDictionary *sec in _sections) for (NSDictionary *r in sec[@"rows"]) if ([r[@"action"] isEqualToString:@"clearCache"]) hasRow = YES;
    if (!hasRow) return;
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long total = TPCacheTotal(TPCacheSizesByKind());
        NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)total countStyle:NSByteCountFormatterCountStyleFile];
        dispatch_async(dispatch_get_main_queue(), ^{
            sTPCacheSize = size;
            [weak.tableView reloadData];
        });
    });
}

- (void)confirmClearCache {
    [self.navigationController pushViewController:[TPCacheCleanerViewController new] animated:YES];
}

- (void)editMutedKeywords {
    [self.navigationController pushViewController:[TPMutedKeywordsViewController new] animated:YES];
}

@end

#pragma mark - Clear cache page

@implementation TPCacheCleanerViewController {
    NSMutableDictionary<NSString *, NSNumber *> *_sizes;   // nil until measured
    NSMutableSet<NSString *> *_selected;
    BOOL _downloading, _working;
    TPPinnedPreview *_pin;   // the selected size, kept in view while the list scrolls
}

static NSString *TPCacheKindTitle(NSString *k) {
    NSDictionary *t = @{ @"tmp": @"Temporary Files", @"url": @"Network Cache", @"tpdl": @"ThreadsPulse Download Leftovers",
                         @"image": @"Image Cache", @"video": @"Video Cache", @"other": @"Other Threads Cache" };
    return TPL(t[k]);
}
static NSString *TPCacheKindDetail(NSString *k) {
    NSDictionary *t = @{ @"tmp": @"Files Threads leaves behind while opening and sharing",
                         @"url": @"Server responses Threads has saved",
                         @"tpdl": @"Left over from downloads and conversions. Files kept in the download manager aren't touched",
                         @"image": @"Profile pictures and photos you've viewed",
                         @"video": @"Videos and audio you've played",
                         @"other": @"Feed data and other files Threads keeps" };
    return TPL(t[k]);
}
static NSString *TPBytes(unsigned long long n) {
    return [NSByteCountFormatter stringFromByteCount:(long long)n countStyle:NSByteCountFormatterCountStyleFile];
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = TPL(@"Clear Cache");
    self.tableView.backgroundColor = [TPUI pageColor];
    _selected = [NSMutableSet setWithArray:TPLiveKinds()];
    _pin = [TPPinnedPreview attachTo:self.tableView font:[UIFont systemFontOfSize:22 weight:UIFontWeightSemibold]];
    _pin.textLabel.numberOfLines = 1;
    [self reloadSummary];
    [self measure];
}

- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [_pin follow:self.tableView]; }
- (void)scrollViewDidScroll:(UIScrollView *)sv { [_pin follow:sv]; }

- (void)reloadSummary {
    _pin.captionLabel.text = _sizes ? [NSString stringWithFormat:TPL(@"%@ in total"), sTPCacheSize ?: @"…"] : TPL(@"Clear Cache");
    _pin.textLabel.text = _sizes ? [NSString stringWithFormat:TPL(@"%@ selected"), TPBytes(self.selectedBytes)] : TPL(@"Measuring…");
}

- (BOOL)kindBlocked:(NSString *)k {
    return _downloading && ([k isEqualToString:@"tmp"] || [k isEqualToString:@"tpdl"]);
}

- (void)measure {
    _downloading = [TPDownloader activeRecordIDs].count > 0;
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *sizes = TPCacheSizesByKind();
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weak;
            if (!s) return;
            s->_sizes = [sizes mutableCopy];
            sTPCacheSize = TPBytes(TPCacheTotal(sizes));
            [s reloadSummary];
            [s.tableView reloadData];
        });
    });
}

- (unsigned long long)selectedBytes {
    unsigned long long n = 0;
    for (NSString *k in _selected) if (![self kindBlocked:k]) n += _sizes[k].unsignedLongLongValue;
    return n;
}
- (BOOL)needsRestart {
    for (NSString *k in TPRestartKinds()) if ([_selected containsObject:k]) return YES;
    return NO;
}
// Something to clear: a kind is ticked and it isn't empty (nothing to do for "Clear 0 KB").
- (BOOL)hasSelection {
    return _sizes && self.selectedBytes > 0;
}

// 0 (empty: the summary is pinned above), 1 no reopen, 2 reopen, 3 notes, 4 button, 5 debug
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return [TPPrefs boolForKey:TPKeyDebugToast] ? 6 : 5; }
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)section { return section == 0 ? CGFLOAT_MIN : UITableViewAutomaticDimension; }
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)section { return section == 0 ? CGFLOAT_MIN : UITableViewAutomaticDimension; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 0;
    if (section == 1) return (NSInteger)TPLiveKinds().count;
    if (section == 2) return (NSInteger)TPRestartKinds().count;
    return 1;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (section == 1) return TPL(@"Cleared Right Away");
    if (section == 2) return TPL(@"Cleared After Reopening Threads");
    if (section == 3) return TPL(@"Good to Know");
    return nil;
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == 1 && _downloading) return TPL(@"Temporary files and download leftovers can't be cleared while a download is in progress.");
    if (section == 2) return TPL(@"Threads is using these while it runs, so it closes and finishes clearing them the next time you open it.");
    return nil;
}

- (NSString *)kindAt:(NSIndexPath *)ip {
    if (ip.section == 1) return TPLiveKinds()[ip.row];
    if (ip.section == 2) return TPRestartKinds()[ip.row];
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    c.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    NSString *kind = [self kindAt:ip];
    if (kind) {
        BOOL blocked = [self kindBlocked:kind];
        BOOL on = [_selected containsObject:kind] && !blocked;
        c.text = TPCacheKindTitle(kind);
        c.secondaryText = TPCacheKindDetail(kind);
        c.textToSecondaryTextVerticalPadding = 3;
        c.textProperties.color = blocked ? UIColor.tertiaryLabelColor : UIColor.labelColor;
        c.image = [UIImage systemImageNamed:on ? @"checkmark.circle.fill" : @"circle"];
        c.imageProperties.tintColor = on ? TPAccent() : UIColor.tertiaryLabelColor;
        c.imageProperties.reservedLayoutSize = CGSizeMake(26, 26);
        c.imageToTextPadding = 12;
        if (blocked) cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UILabel *size = [UILabel new];
        size.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        size.textColor = UIColor.secondaryLabelColor;
        size.text = _sizes ? TPBytes(_sizes[kind].unsignedLongLongValue) : @"…";
        [size sizeToFit];
        cell.accessoryView = size;
    } else if (ip.section == 3) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        c.text = TPL(@"Your login, settings, drafts and download history aren't cleared.");
        c.secondaryText = TPL(@"Right after clearing, images and videos load a little slower while Threads downloads them again.");
        c.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        c.textToSecondaryTextVerticalPadding = 6;
        TPApplyIcon(c, @"info.circle", nil);
    } else if (ip.section == 4) {
        BOOL ok = _sizes && !_working && self.hasSelection;
        c = [UIListContentConfiguration cellConfiguration];
        c.text = self.needsRestart ? TPL(@"Clear and Close")
                                   : [NSString stringWithFormat:TPL(@"Clear %@"), _sizes ? TPBytes(self.selectedBytes) : @""];
        c.textProperties.alignment = UIListContentTextAlignmentCenter;
        c.textProperties.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        c.textProperties.color = ok ? (self.needsRestart ? UIColor.systemRedColor : TPAccent()) : UIColor.tertiaryLabelColor;
        if (!ok) cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        c = [UIListContentConfiguration cellConfiguration];
        c.text = TPL(@"Copy Folder List");
        c.textProperties.color = TPAccent();
        TPApplyIcon(c, @"doc.on.clipboard", nil);
    }
    cell.contentConfiguration = c;
    TPApplyCardBackground(cell);
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *kind = [self kindAt:ip];
    if (kind) {
        if ([self kindBlocked:kind] || _working) return;
        if ([_selected containsObject:kind]) [_selected removeObject:kind]; else [_selected addObject:kind];
        [UIView performWithoutAnimation:^{
            [tv reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 5)] withRowAnimation:UITableViewRowAnimationNone];
            [self reloadSummary];
        }];
    } else if (ip.section == 4) {
        if (!_sizes || _working || !self.hasSelection) return;
        if (self.needsRestart) [self confirmRestart];
        else [self clearLiveThen:nil];
    } else if (ip.section == 5) {
        [self copyFolderList];
    }
}

// Clears the selected items that don't need a restart, then calls done on the main queue.
- (void)clearLiveThen:(void (^)(unsigned long long freed))done {
    _working = YES;
    NSMutableArray *kinds = [NSMutableArray array];
    // Checked again here: a download may have started since the page opened.
    BOOL downloading = [TPDownloader activeRecordIDs].count > 0;
    if (!downloading) for (NSString *k in TPLiveKinds()) if ([_selected containsObject:k]) [kinds addObject:k];
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long freed = 0;
        for (NSString *k in kinds) freed += TPRemovePaths(TPLiveCachePaths(k));
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weak;
            if (s) s->_working = NO;
            if (done) { done(freed); return; }
            [TPHUD toast:[NSString stringWithFormat:TPL(@"Cleared %@ of cache"), TPBytes(freed)]];
            [s measure];
        });
    });
}

- (void)confirmRestart {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:TPL(@"Clear %@ of Cache?"), TPBytes(self.selectedBytes)]
        message:TPL(@"Threads closes, and the cache is cleared when you open it again.")
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    NSMutableArray *kinds = [NSMutableArray array];
    for (NSString *k in TPRestartKinds()) if ([_selected containsObject:k]) [kinds addObject:k];
    [a addAction:[UIAlertAction actionWithTitle:TPL(@"Clear and Close") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [self clearLiveThen:^(unsigned long long freed) {
            NSUserDefaults *d = [TPPrefs defaults];
            [d setObject:kinds forKey:kTPClearCacheKinds];
            [d setBool:YES forKey:kTPClearCachePending];
            [d synchronize];
            // Back to the Home Screen first so it doesn't look like a crash, then quit.
            UIApplication *app = UIApplication.sharedApplication;
            if ([app respondsToSelector:@selector(suspend)]) [app performSelector:@selector(suspend)];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
        }];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// Debug: what's in Caches and tmp and which kind each entry counts as, to help sort new folders.
- (void)copyFolderList {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSMutableArray *lines = [NSMutableArray array];
        NSString *caches = TPCachesDir();
        [lines addObject:@"[Library/Caches]"];
        for (NSString *name in [[fm contentsOfDirectoryAtPath:caches error:nil] sortedArrayUsingSelector:@selector(compare:)])
            [lines addObject:[NSString stringWithFormat:@"%@\t%@\t%@", name, TPCacheKindForName(name), TPBytes(TPItemSize([caches stringByAppendingPathComponent:name]))]];
        NSString *tmp = NSTemporaryDirectory();
        [lines addObject:@"[tmp]"];
        for (NSString *name in [[fm contentsOfDirectoryAtPath:tmp error:nil] sortedArrayUsingSelector:@selector(compare:)])
            [lines addObject:[NSString stringWithFormat:@"%@\t%@\t%@", name, TPIsOwnTempName(name) ? @"tpdl" : @"tmp", TPBytes(TPItemSize([tmp stringByAppendingPathComponent:name]))]];
        NSString *text = [lines componentsJoinedByString:@"\n"];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIPasteboard.generalPasteboard.string = text;
            [TPHUD toast:TPL(@"Copied")];
        });
    });
}

@end
