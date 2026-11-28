#import "TPWelcomeViewController.h"
#import "TPSettingsViewController.h"
#import "TPLocalization.h"
#import "TPPrefs.h"
#import "TPUI.h"

static NSString *const kTPWelcomeShownKey = @"tp_welcome_shown";
static NSString *const kTPWhatsNewKey     = @"tp_whats_new_seen";
static NSString *const kTPWhatsNewVersion = @"1.33";   // bump with each release that has a What's New

@interface TPWelcomeViewController ()
@property (nonatomic) BOOL whatsNew;
@end

@implementation TPWelcomeViewController {
    UIView *_badge;
    NSMutableArray<UIView *> *_animated;
    NSHashTable<UILabel *> *_wrapping;
    BOOL _didAnimateIn;
}

+ (void)present { [self presentMarkingShown:NO whatsNew:NO attempt:0]; }
+ (void)presentWhatsNew { [self presentMarkingShown:NO whatsNew:YES attempt:0]; }

// Shown once: the welcome screen on a new install, otherwise What's New once per release.
// Retries a few times if another view controller is being presented at launch.
+ (void)presentIfNeeded {
    NSUserDefaults *d = [TPPrefs defaults];
    // Updated from a version before 1.33 (the welcome was already seen on an earlier install):
    // mark this release's new settings in the settings until they've been seen. Not on a new
    // install, where everything is new. Decided once, on the first launch of this version.
    if (![d objectForKey:@"tp_new_badges_1_33"])
        [d setBool:[TPPrefs boolForKey:kTPWelcomeShownKey] forKey:@"tp_new_badges_1_33"];
    BOOL whatsNew = NO;
    if ([TPPrefs boolForKey:kTPWelcomeShownKey]) {
        if ([[d stringForKey:kTPWhatsNewKey] isEqualToString:kTPWhatsNewVersion]) return;
        whatsNew = YES;
    } else {
        [d setObject:kTPWhatsNewVersion forKey:kTPWhatsNewKey];   // a new install doesn't need What's New too
    }
    static BOOL scheduled;
    if (scheduled) return;
    scheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        scheduled = NO;
        [self presentMarkingShown:YES whatsNew:whatsNew attempt:0];
    });
}

+ (void)presentMarkingShown:(BOOL)mark whatsNew:(BOOL)whatsNew attempt:(NSInteger)attempt {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (mark && !whatsNew && [TPPrefs boolForKey:kTPWelcomeShownKey]) return;
        UIViewController *top = TPTopViewController();
        if ([top isKindOfClass:self]) return;
        BOOL busy = !top || !top.view.window || top.isBeingPresented || top.isBeingDismissed
                 || [top isKindOfClass:[UIAlertController class]];
        if (busy) {
            if (attempt >= 5) return;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self presentMarkingShown:mark whatsNew:whatsNew attempt:attempt + 1];
            });
            return;
        }
        TPWelcomeViewController *vc = [self new];
        vc.whatsNew = whatsNew;
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        [top presentViewController:vc animated:YES completion:^{
            if (!mark) return;
            if (whatsNew) [[TPPrefs defaults] setObject:kTPWhatsNewVersion forKey:kTPWhatsNewKey];
            else [TPPrefs setBool:YES forKey:kTPWelcomeShownKey];
        }];
    });
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [TPUI pageColor];
    self.view.tintColor = [TPUI accent];
    _animated = [NSMutableArray array];
    _wrapping = [NSHashTable weakObjectsHashTable];

    UIScrollView *scroll = [UIScrollView new];
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = NO;
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    UIView *bottom = [UIView new];
    for (UIView *v in @[scroll, stack, bottom]) v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    [self.view addSubview:bottom];

    UIView *hero = [self heroView];
    [stack addArrangedSubview:hero];
    [stack setCustomSpacing:28 afterView:hero];

    if (self.whatsNew) {
        [stack addArrangedSubview:[self cardWithSymbol:@"clock" title:TPL(@"Post Time Format")
            detail:TPL(@"Build your own post time from relative time, weekday, date and time, in any order") accessory:nil]];
        [stack addArrangedSubview:[self cardWithSymbol:@"trash" title:TPL(@"Clear Cache")
            detail:TPL(@"See each kind of cache with its size and choose what to clear") accessory:nil]];
        [stack addArrangedSubview:[self cardWithSymbol:@"chart.bar" title:TPL(@"Today's Numbers")
            detail:TPL(@"The card at the top of the settings shows today's blocked ads and hidden posts") accessory:nil]];
        [stack addArrangedSubview:[self cardWithSymbol:@"shield" title:TPL(@"Block Ads")
            detail:TPL(@"Ads between the replies of a thread are blocked too") accessory:nil]];
    } else {
    UILabel *heading = [UILabel new];
    heading.text = TPL(@"How to Open Settings");
    heading.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    heading.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:[self inset:heading by:4]];
    [stack setCustomSpacing:8 afterView:stack.arrangedSubviews.lastObject];

    [stack addArrangedSubview:[self cardWithSymbol:@"gearshape"
                                             title:TPL(@"From Threads Settings")
                                            detail:TPL(@"Open Threads settings, then tap “Pulse” at the top right")
                                         accessory:nil]];
    [stack addArrangedSubview:[self cardWithSymbol:@"hand.raised"
                                             title:TPL(@"Three-Finger Long Press")
                                            detail:TPL(@"Press anywhere with three fingers for 1 second")
                                         accessory:nil]];
    [stack addArrangedSubview:[self cardWithSymbol:@"house"
                                             title:TPL(@"Long-Press the Home Tab")
                                            detail:TPL(@"Long-press the Home tab at the bottom")
                                         accessory:nil]];

    UILabel *note = [UILabel new];
    note.text = TPL(@"You can see this screen again under Advanced");
    note.font = [UIFont systemFontOfSize:13];
    note.textColor = UIColor.tertiaryLabelColor;
    note.numberOfLines = 0;
    [self wrap:note];
    note.textAlignment = NSTextAlignmentCenter;
    [stack setCustomSpacing:16 afterView:stack.arrangedSubviews.lastObject];
    [stack addArrangedSubview:note];
    [_animated addObject:note];
    }

    UIButton *primary = [UIButton buttonWithType:UIButtonTypeCustom];
    [primary setTitle:TPL(self.whatsNew ? @"Get Started" : @"Open ThreadsPulse Settings")
             forState:UIControlStateNormal];
    [primary setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [primary setTitleColor:[UIColor colorWithWhite:1 alpha:0.6] forState:UIControlStateHighlighted];
    primary.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    primary.backgroundColor = [TPUI accent];
    primary.layer.cornerRadius = 14;
    primary.layer.cornerCurve = kCACornerCurveContinuous;
    __weak typeof(self) weakSelf = self;
    BOOL whatsNew = self.whatsNew;
    [primary addAction:[UIAction actionWithHandler:^(UIAction *a) {
        [TPUI hapticLight];
        if (whatsNew) {
            [weakSelf dismissViewControllerAnimated:YES completion:nil];
            return;
        }
        [weakSelf dismissViewControllerAnimated:YES completion:^{ [TPSettingsViewController present]; }];
    }] forControlEvents:UIControlEventTouchUpInside];

    UIButton *later = [UIButton buttonWithType:UIButtonTypeCustom];
    [later setTitle:TPL(@"Maybe Later") forState:UIControlStateNormal];
    [later setTitleColor:[TPUI accentIcon] forState:UIControlStateNormal];
    [later setTitleColor:[[TPUI accentIcon] colorWithAlphaComponent:0.5] forState:UIControlStateHighlighted];
    later.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [later addAction:[UIAction actionWithHandler:^(UIAction *a) {
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    }] forControlEvents:UIControlEventTouchUpInside];

    if (self.whatsNew) later.hidden = YES;
    for (UIView *v in @[primary, later]) { v.translatesAutoresizingMaskIntoConstraints = NO; [bottom addSubview:v]; }
    [_animated addObject:bottom];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    // Just below required: only the 520 pt cap (iPad) may make them narrower. At the default high
    // priority a long line of text could push the cards wider than the screen.
    NSLayoutConstraint *fill = [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40];
    fill.priority = UILayoutPriorityRequired - 1;
    NSLayoutConstraint *bottomFill = [bottom.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-40];
    bottomFill.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:bottom.topAnchor constant:-8],

        [scroll.contentLayoutGuide.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:36],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [stack.centerXAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerXAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:520],
        fill,

        [bottom.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [bottom.widthAnchor constraintLessThanOrEqualToConstant:520],
        bottomFill,
        [bottom.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],

        [primary.topAnchor constraintEqualToAnchor:bottom.topAnchor],
        [primary.leadingAnchor constraintEqualToAnchor:bottom.leadingAnchor],
        [primary.trailingAnchor constraintEqualToAnchor:bottom.trailingAnchor],
        [primary.heightAnchor constraintEqualToConstant:52],
        [later.topAnchor constraintEqualToAnchor:primary.bottomAnchor constant:4],
        [later.centerXAnchor constraintEqualToAnchor:bottom.centerXAnchor],
        [later.heightAnchor constraintEqualToConstant:44],
        [later.bottomAnchor constraintEqualToAnchor:bottom.bottomAnchor],
    ]];
}

- (UIView *)heroView {
    UIView *hero = [UIView new];
    _badge = [UIView new];
    _badge.backgroundColor = [TPUI accent];
    _badge.layer.cornerRadius = 22;
    _badge.layer.cornerCurve = kCACornerCurveContinuous;
    _badge.layer.shadowColor = [TPUI accent].CGColor;
    _badge.layer.shadowOpacity = 0.45;
    _badge.layer.shadowRadius = 18;
    _badge.layer.shadowOffset = CGSizeMake(0, 8);
    UIImageView *glyph = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"waveform.path.ecg"
                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:36 weight:UIImageSymbolWeightSemibold]]];
    glyph.tintColor = UIColor.whiteColor;
    glyph.contentMode = UIViewContentModeCenter;

    UILabel *title = [UILabel new];
    title.text = self.whatsNew ? [NSString stringWithFormat:TPL(@"What's New in ThreadsPulse %@"), kTPWhatsNewVersion]
                               : TPL(@"Welcome to ThreadsPulse");
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.8;

    UILabel *subtitle = [UILabel new];
    subtitle.text = TPL(self.whatsNew ? @"Updated to the latest version" : @"ThreadsPulse is installed and running");
    subtitle.font = [UIFont systemFontOfSize:16];
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;
    for (UILabel *l in @[title, subtitle]) [self wrap:l];

    for (UIView *v in @[_badge, glyph, title, subtitle]) v.translatesAutoresizingMaskIntoConstraints = NO;
    [hero addSubview:_badge];
    [_badge addSubview:glyph];
    [hero addSubview:title];
    [hero addSubview:subtitle];
    [NSLayoutConstraint activateConstraints:@[
        [_badge.topAnchor constraintEqualToAnchor:hero.topAnchor],
        [_badge.centerXAnchor constraintEqualToAnchor:hero.centerXAnchor],
        [_badge.widthAnchor constraintEqualToConstant:84],
        [_badge.heightAnchor constraintEqualToConstant:84],
        [glyph.centerXAnchor constraintEqualToAnchor:_badge.centerXAnchor],
        [glyph.centerYAnchor constraintEqualToAnchor:_badge.centerYAnchor],
        [title.topAnchor constraintEqualToAnchor:_badge.bottomAnchor constant:24],
        [title.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [subtitle.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],
        [subtitle.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
    ]];
    [_animated addObject:hero];
    return hero;
}

- (UIView *)cardWithSymbol:(NSString *)symbol title:(NSString *)titleText detail:(NSString *)detailText accessory:(UIView *)accessory {
    UIView *card = [UIView new];
    card.backgroundColor = [TPUI cardColor];
    card.layer.cornerRadius = 16;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    UIView *tile = [UIView new];
    tile.backgroundColor = [[TPUI accent] colorWithAlphaComponent:0.16];
    tile.layer.cornerRadius = 11;
    tile.layer.cornerCurve = kCACornerCurveContinuous;
    UIImageView *icon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:symbol
                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightMedium]]];
    icon.tintColor = [TPUI accentIcon];
    icon.contentMode = UIViewContentModeCenter;

    UILabel *title = [UILabel new];
    title.text = titleText;
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    title.textColor = UIColor.labelColor;
    title.numberOfLines = 0;
    UILabel *detail = [UILabel new];
    detail.text = detailText;
    detail.font = [UIFont systemFontOfSize:14];
    detail.textColor = UIColor.secondaryLabelColor;
    detail.numberOfLines = 0;
    for (UILabel *l in @[title, detail]) [self wrap:l];

    NSMutableArray<UIView *> *views = [@[tile, icon, title, detail] mutableCopy];
    if (accessory) [views addObject:accessory];
    for (UIView *v in views) v.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:tile];
    [tile addSubview:icon];
    [card addSubview:title];
    [card addSubview:detail];

    NSLayoutAnchor *textTrailing = card.trailingAnchor;
    CGFloat trailingGap = -16;
    if (accessory) {
        [card addSubview:accessory];
        [accessory setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [accessory setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [accessory.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
            [accessory.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        ]];
        textTrailing = accessory.leadingAnchor;
        trailingGap = -12;
    }
    [NSLayoutConstraint activateConstraints:@[
        [tile.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [tile.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [tile.widthAnchor constraintEqualToConstant:42],
        [tile.heightAnchor constraintEqualToConstant:42],
        [icon.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:14],
        [title.trailingAnchor constraintEqualToAnchor:textTrailing constant:trailingGap],
        [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3],
        [detail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [detail.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [detail.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [card.heightAnchor constraintGreaterThanOrEqualToConstant:70],
    ]];
    [_animated addObject:card];
    return card;
}

- (UIView *)inset:(UIView *)view by:(CGFloat)inset {
    UIView *wrap = [UIView new];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [wrap addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.topAnchor constraintEqualToAnchor:wrap.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor],
        [view.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:inset],
        [view.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-inset],
    ]];
    [_animated addObject:wrap];
    return wrap;
}

// preferredMaxLayoutWidth is updated on every layout pass so multi-line text wraps correctly on
// every screen width instead of being truncated.
- (void)wrap:(UILabel *)label {
    label.numberOfLines = 0;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [_wrapping addObject:label];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    BOOL changed = NO;
    for (UILabel *l in _wrapping.allObjects) {
        CGFloat w = CGRectGetWidth(l.bounds);
        if (w > 0 && fabs(l.preferredMaxLayoutWidth - w) > 0.5) { l.preferredMaxLayoutWidth = w; changed = YES; }
    }
    if (changed) [self.view layoutIfNeeded];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_didAnimateIn || UIAccessibilityIsReduceMotionEnabled()) return;
    for (UIView *v in _animated) {
        v.alpha = 0;
        v.transform = CGAffineTransformMakeTranslation(0, 18);
    }
    _badge.transform = CGAffineTransformMakeScale(0.6, 0.6);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_didAnimateIn) return;
    _didAnimateIn = YES;
    if (UIAccessibilityIsReduceMotionEnabled()) return;
    [_animated enumerateObjectsUsingBlock:^(UIView *v, NSUInteger i, BOOL *stop) {
        [UIView animateWithDuration:0.5 delay:0.06 * i usingSpringWithDamping:0.85 initialSpringVelocity:0.3 options:0
                         animations:^{ v.alpha = 1; v.transform = CGAffineTransformIdentity; } completion:nil];
    }];
    [UIView animateWithDuration:0.7 delay:0.05 usingSpringWithDamping:0.55 initialSpringVelocity:0.6 options:0
                     animations:^{ self->_badge.transform = CGAffineTransformIdentity; } completion:nil];
}

@end
