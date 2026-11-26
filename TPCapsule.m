#import "TPCapsule.h"
#import "TPDownloadManager.h"
#import "TPUI.h"
#import "TPPrefs.h"
#import "TPLocalization.h"

static NSMutableArray<TPCapsule *> *sCapsules;
static const CGFloat kPillH = 34, kGap = 8, kCardW = 290, kRowH = 26;

// Dynamic Island black with white text; the percentage uses the theme colour, the speed is gray.
static UIColor *TPCapsuleBG(void) { return UIColor.blackColor; }
static UIColor *TPCapsuleBorder(void) { return [UIColor colorWithWhite:1 alpha:0.10]; }
static UIColor *TPMuted(void) { return [UIColor colorWithRed:0.557 green:0.557 blue:0.576 alpha:1]; }  // #8E8E93

// A container whose contents can be left out of screenshots ("Hide Buttons in Screenshots").
static UIView *TPHolder(CGRect frame) {
    UIView *h = [TPPrefs boolForKey:TPKeyHideInCaptures] ? TPCaptureProtectedView() : nil;
    if (!h) h = [UIView new];
    h.frame = frame;
    h.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    h.userInteractionEnabled = NO;
    h.clipsToBounds = NO;
    return h;
}

@implementation TPCapsule {
    UIView *_pill, *_pillContent;
    UILabel *_pillLabel;
    UIActivityIndicatorView *_spinner;
    UIImageView *_mark;
    UIView *_card, *_cardContent;
    CGRect _cancelRect, _cancelAllRect;
    NSString *_title, *_speed, *_detail;
    NSArray<NSDictionary *> *_rows;
    CGFloat _progress;
    BOOL _expanded, _finished, _gone;
    void (^_cancel)(void);
}

static NSMutableSet<NSString *> *sHostedTags;

static void TPLayoutCapsules(BOOL animated) {
    UIWindow *win = TPKeyWindow();
    if (!win) return;
    CGFloat y = win.safeAreaInsets.top + 4;
    for (TPCapsule *c in sCapsules) {
        UIView *p = c->_pill;
        BOOL hosted = c.tag.length && [sHostedTags containsObject:c.tag];
        p.hidden = hosted;
        c->_card.hidden = hosted;
        if (hosted) continue;
        CGSize sz = p.bounds.size;
        CGRect pf = CGRectMake(round((win.bounds.size.width - sz.width) / 2), y, sz.width, kPillH);
        CGRect cf = CGRectZero;
        y += kPillH + kGap;
        if (c->_card) {
            CGFloat h = c->_card.bounds.size.height;
            cf = CGRectMake(round((win.bounds.size.width - kCardW) / 2), y, kCardW, h);
            y += h + kGap;
        }
        void (^apply)(void) = ^{ p.frame = pf; if (c->_card) c->_card.frame = cf; };
        if (animated) [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0 options:0 animations:apply completion:nil];
        else apply();
    }
}

+ (void)setHostedTag:(NSString *)tag hosted:(BOOL)hosted {
    if (!tag.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sHostedTags) sHostedTags = [NSMutableSet set];
        if (hosted) [sHostedTags addObject:tag]; else [sHostedTags removeObject:tag];
        TPLayoutCapsules(NO);
    });
}

+ (instancetype)showWithTitle:(NSString *)title cancel:(void (^)(void))cancel {
    TPCapsule *c = [TPCapsule new];
    c->_cancel = [cancel copy];
    c->_title = title;
    c->_progress = 0;
    dispatch_async(dispatch_get_main_queue(), ^{ [c build]; });
    return c;
}

- (void)build {
    UIWindow *win = TPKeyWindow();
    if (!win || _gone) return;
    if (!sCapsules) sCapsules = [NSMutableArray array];

    _pill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 120, kPillH)];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(pillTapped)];
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pillHeld:)];
    hold.minimumPressDuration = 0.4;
    [tap requireGestureRecognizerToFail:hold];
    [_pill addGestureRecognizer:tap];
    [_pill addGestureRecognizer:hold];
    UISwipeGestureRecognizer *up = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipedUp)];
    up.direction = UISwipeGestureRecognizerDirectionUp;
    [_pill addGestureRecognizer:up];

    UIView *holder = TPHolder(_pill.bounds);
    _pillContent = [[UIView alloc] initWithFrame:_pill.bounds];
    _pillContent.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _pillContent.backgroundColor = TPCapsuleBG();
    _pillContent.layer.cornerRadius = kPillH / 2;
    _pillContent.layer.borderWidth = 0.5;
    _pillContent.layer.borderColor = TPCapsuleBorder().CGColor;
    _pillContent.layer.shadowColor = UIColor.blackColor.CGColor;
    _pillContent.layer.shadowOpacity = 0.25;
    _pillContent.layer.shadowRadius = 10;
    _pillContent.layer.shadowOffset = CGSizeMake(0, 3);

    _pillLabel = [UILabel new];
    _pillLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    _pillLabel.textColor = UIColor.whiteColor;
    [_pillContent addSubview:_pillLabel];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.color = UIColor.whiteColor;
    _spinner.transform = CGAffineTransformMakeScale(0.75, 0.75);
    _spinner.hidesWhenStopped = YES;
    [_pillContent addSubview:_spinner];

    _mark = [UIImageView new];
    _mark.contentMode = UIViewContentModeScaleAspectFit;
    _mark.hidden = YES;
    [_pillContent addSubview:_mark];

    [holder addSubview:_pillContent];
    [_pill addSubview:holder];

    [sCapsules addObject:self];
    [self refreshPill];
    TPLayoutCapsules(NO);
    [win addSubview:_pill];
    CGRect end = _pill.frame;
    _pill.frame = CGRectOffset(end, 0, -(end.origin.y + kPillH + 10));
    [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.4 options:0
                     animations:^{ self->_pill.frame = end; } completion:nil];
}

// Pill text: "<title> · 54% · 2.3 MB/s"; it grows or shrinks to fit, centred.
- (void)refreshPill {
    if (!_pill) return;
    UIFont *font = _pillLabel.font;
    NSString *title = _title ?: @"";
    if (!title.length && (_finished || _progress < 0)) title = TPL(@"Downloading…");
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:title
        attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.whiteColor }];
    if (!_finished && _progress >= 0) {
        if (text.length) [text appendAttributedString:[[NSAttributedString alloc] initWithString:@" · "
            attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.whiteColor }]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%.0f%%", floor(_progress * 100)]
            attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: [TPUI accentOnDark] }]];
    }
    // The speed is shown in the expanded card, under the file being downloaded, not in the pill:
    // a wider pill covers the buttons at the top of the screen.
    _pillLabel.attributedText = text;
    UIWindow *win = TPKeyWindow();
    CGFloat maxW = (win ? win.bounds.size.width : 390) - 40;
    BOOL lead = _spinner.isAnimating || !_mark.hidden;
    CGFloat leadW = lead ? 22 : 0;
    CGFloat textW = ceil([_pillLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, kPillH)].width);
    CGFloat w = MIN(maxW, MAX(110, textW + leadW + 28));
    CGRect f = _pill.frame;
    f.size.width = w;
    f.origin.x = round(((win ? win.bounds.size.width : w) - w) / 2);
    _pill.frame = f;
    CGFloat x = 14;
    if (lead) {
        _spinner.center = CGPointMake(x + 8, kPillH / 2);
        _mark.frame = CGRectMake(x, (kPillH - 16) / 2, 16, 16);
        x += leadW;
    }
    _pillLabel.frame = CGRectMake(x, 0, w - x - 14, kPillH);
    _pillLabel.adjustsFontSizeToFitWidth = YES;
    _pillLabel.minimumScaleFactor = 0.75;
}

- (void)setTitle:(NSString *)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_finished) return;
        self->_title = title;
        [self refreshPill];
    });
}

- (void)setProgress:(CGFloat)progress subtitle:(NSString *)subtitle {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_finished) return;
        self->_progress = progress < 0 ? -1 : MAX(0, MIN(1, progress));
        if (progress < 0) [self->_spinner startAnimating]; else [self->_spinner stopAnimating];
        if (subtitle) self->_detail = [subtitle stringByReplacingOccurrencesOfString:@"\n" withString:@" · "];
        [self refreshPill];
        if (self->_expanded) [self rebuildCard];
    });
}

- (void)setSpeed:(NSString *)speed {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_finished) return;
        self->_speed = speed;
        if (self->_expanded) [self rebuildCard];
    });
}

- (void)setRows:(NSArray<NSDictionary *> *)rows {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_finished) return;
        self->_rows = [rows copy];
        if (self->_expanded) [self rebuildCard];
    });
}

#pragma mark Card

// Long-press: open the download manager.
- (void)pillHeld:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [TPUI hapticLight];
    [TPDownloadManagerViewController present];
}

- (void)pillTapped {
    if (_finished) { [self dismiss]; return; }
    [TPUI hapticLight];
    _expanded = !_expanded;
    if (_expanded) {
        [self rebuildCard];
    } else {
        UIView *c = _card;
        _card = nil;
        [UIView animateWithDuration:0.18 animations:^{ c.alpha = 0; c.transform = CGAffineTransformMakeScale(0.96, 0.96); }
                         completion:^(BOOL f) { [c removeFromSuperview]; }];
        TPLayoutCapsules(YES);
    }
}

- (UILabel *)label:(NSString *)text frame:(CGRect)f muted:(BOOL)muted right:(BOOL)right color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.text = text;
    l.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    l.textColor = color ?: (muted ? TPMuted() : UIColor.whiteColor);
    l.textAlignment = right ? NSTextAlignmentRight : NSTextAlignmentLeft;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.75;
    return l;
}

- (void)rebuildCard {
    UIWindow *win = TPKeyWindow();
    if (!win || !_pill) return;
    BOOL isNew = _card == nil;
    if (isNew) {
        _card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kCardW, 60)];
        [_card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cardTapped:)]];
        [win addSubview:_card];
    }
    for (UIView *v in _card.subviews) [v removeFromSuperview];

    UIView *holder = TPHolder(_card.bounds);
    UIView *content = [[UIView alloc] init];
    content.backgroundColor = TPCapsuleBG();
    content.layer.cornerRadius = 16;
    content.layer.cornerCurve = kCACornerCurveContinuous;
    content.layer.borderWidth = 0.5;
    content.layer.borderColor = TPCapsuleBorder().CGColor;
    content.layer.shadowColor = UIColor.blackColor.CGColor;
    content.layer.shadowOpacity = 0.25;
    content.layer.shadowRadius = 12;
    content.layer.shadowOffset = CGSizeMake(0, 4);

    CGFloat y = 8, inset = 14, w = kCardW - inset * 2;
    for (NSDictionary *r in _rows) {
        NSInteger st = [r[@"state"] integerValue];
        NSString *sym = st == 2 ? @"checkmark.circle" : st == 3 ? @"xmark.circle" : st == 1 ? @"arrow.down.circle" : @"clock";
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:sym withConfiguration:
                             [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]]];
        icon.tintColor = st == 2 ? UIColor.systemGreenColor : st == 3 ? UIColor.systemRedColor : st == 1 ? UIColor.whiteColor : TPMuted();
        icon.contentMode = UIViewContentModeCenter;
        icon.frame = CGRectMake(inset, y, 18, kRowH);
        [content addSubview:icon];
        BOOL muted = st == 0;
        [content addSubview:[self label:r[@"title"] frame:CGRectMake(inset + 24, y, w * 0.62 - 24, kRowH) muted:muted right:NO color:nil]];
        [content addSubview:[self label:r[@"status"] frame:CGRectMake(inset + w * 0.62, y, w * 0.38, kRowH) muted:st != 1 right:YES
                                  color:st == 3 ? UIColor.systemRedColor : (st == 1 ? [TPUI accentOnDark] : nil)]];
        y += kRowH;
        NSString *detail = _detail.length && _speed.length ? [NSString stringWithFormat:@"%@ · %@", _detail, _speed]
                         : (_detail.length ? _detail : _speed);
        if (st == 1 && detail.length) {
            UILabel *d = [self label:detail frame:CGRectMake(inset + 24, y - 4, w - 24, 18) muted:YES right:NO color:nil];
            d.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
            [content addSubview:d];
            y += 16;
        }
    }
    NSInteger queued = self.queueCount ? self.queueCount() : 0;
    if (queued > 0) {
        [content addSubview:[self label:[NSString stringWithFormat:TPL(@"%ld more posts waiting"), (long)queued]
                                  frame:CGRectMake(inset + 24, y, w - 24, kRowH) muted:YES right:NO color:nil]];
        y += kRowH;
    }

    // Divider + Cancel / Cancel All
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, y + 4, kCardW, 0.5)];
    line.backgroundColor = TPCapsuleBorder();
    [content addSubview:line];
    y += 5;
    UIColor *red = [UIColor colorWithRed:1 green:0.41 blue:0.38 alpha:1];
    if (queued > 0 && self.cancelAll) {
        _cancelRect = CGRectMake(0, y, kCardW / 2, 40);
        _cancelAllRect = CGRectMake(kCardW / 2, y, kCardW / 2, 40);
        UILabel *a = [self label:TPL(@"Cancel Download") frame:_cancelRect muted:NO right:NO color:red];
        a.textAlignment = NSTextAlignmentCenter;
        UILabel *b = [self label:TPL(@"Cancel All") frame:_cancelAllRect muted:NO right:NO color:red];
        b.textAlignment = NSTextAlignmentCenter;
        UIView *mid = [[UIView alloc] initWithFrame:CGRectMake(kCardW / 2, y + 8, 0.5, 24)];
        mid.backgroundColor = TPCapsuleBorder();
        [content addSubview:a]; [content addSubview:b]; [content addSubview:mid];
    } else {
        _cancelRect = CGRectMake(0, y, kCardW, 40);
        _cancelAllRect = CGRectNull;
        UILabel *a = [self label:TPL(@"Cancel Download") frame:_cancelRect muted:NO right:NO color:red];
        a.textAlignment = NSTextAlignmentCenter;
        [content addSubview:a];
    }
    y += 40;

    CGFloat h = y;
    CGRect f = _card.frame;
    f.size = CGSizeMake(kCardW, h);
    _card.frame = f;
    holder.frame = _card.bounds;
    content.frame = _card.bounds;
    [holder addSubview:content];
    [_card addSubview:holder];

    if (isNew) {
        TPLayoutCapsules(NO);
        _card.alpha = 0;
        _card.transform = CGAffineTransformMakeScale(0.96, 0.96);
        [UIView animateWithDuration:0.22 animations:^{ self->_card.alpha = 1; self->_card.transform = CGAffineTransformIdentity; }];
    } else {
        TPLayoutCapsules(YES);
    }
}

- (void)cardTapped:(UITapGestureRecognizer *)g {
    if (_finished) return;
    CGPoint p = [g locationInView:_card];
    if (CGRectContainsPoint(_cancelAllRect, p)) {
        void (^all)(void) = self.cancelAll;
        [self dismiss];
        if (all) all();
    } else if (CGRectContainsPoint(_cancelRect, p)) {
        void (^cb)(void) = _cancel;
        [self dismiss];
        if (cb) cb();
    }
}

// Swiping up hides a finished pill, or collapses the card.
- (void)swipedUp {
    if (_finished) { [self dismiss]; return; }
    if (_expanded) [self pillTapped];
}

#pragma mark Finish

- (void)finishWithSymbol:(NSString *)symbol color:(UIColor *)color message:(NSString *)message hold:(NSTimeInterval)hold {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_finished || !self->_pill) return;
        self->_finished = YES;
        if (self->_card) { UIView *c = self->_card; self->_card = nil; self->_expanded = NO; [c removeFromSuperview]; }
        [self->_spinner stopAnimating];
        self->_mark.image = [UIImage systemImageNamed:symbol withConfiguration:
                             [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold]];
        self->_mark.tintColor = color;
        self->_mark.hidden = NO;
        self->_title = message;
        self->_speed = nil;
        [UIView animateWithDuration:0.25 animations:^{ [self refreshPill]; }];
        TPLayoutCapsules(YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self dismiss];
        });
    });
}

- (void)finishSuccess:(NSString *)message {
    [TPUI hapticSuccess];
    [self finishWithSymbol:@"checkmark.circle.fill" color:UIColor.systemGreenColor message:message hold:1.5];
}

- (void)finishFailure:(NSString *)message {
    [TPUI hapticError];
    [self finishWithSymbol:@"xmark.circle.fill" color:UIColor.systemRedColor message:message hold:2.2];
}

- (void)dismiss {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_gone = YES;
        self->_finished = YES;
        UIView *p = self->_pill, *c = self->_card;
        self->_pill = nil;
        self->_card = nil;
        [sCapsules removeObject:self];
        if (p) {
            CGRect f = p.frame;
            [UIView animateWithDuration:0.25 animations:^{
                p.frame = CGRectOffset(f, 0, -(f.origin.y + kPillH + 10));
                p.alpha = 0;
                c.alpha = 0;
            } completion:^(BOOL done) { [p removeFromSuperview]; [c removeFromSuperview]; }];
        }
        TPLayoutCapsules(YES);
    });
}
@end
