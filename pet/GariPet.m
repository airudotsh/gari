// GariPet v0.3 — 가리의 몸. 화면에 상주하는 픽셀 펫 (살아있음 + 인터랙티브).
// 원칙: 무드는 실제 상태만 표시 (자는 모습 = 진짜 유휴). 잔동작은 장식이되 상태를 속이지 않는다.
// 본체와 분리: 이 앱이 죽어도 가리(수집·증류·보고)는 무사하다.
// 빌드: clang -fobjc-arc -framework Cocoa -O2 -o gari-pet GariPet.m
// 자가 스냅샷: ./gari-pet --snapshot <출력폴더>   (무드별 PNG 렌더 후 종료 — 시각 검증용)
#import <Cocoa/Cocoa.h>
#import <sys/file.h>

#define CELL 5.0
#define BCOLS 13
#define BROWS 10
#define TICK 0.12

typedef NS_ENUM(int, GariMood) { MoodSleep, MoodAwake, MoodWork, MoodAlert };

// ---------------------------------------------------------------- 몸 (레이어 1: 손도트 시트)
// 가리 = 가리발디 물고기. 레퍼런스 도트 문법: 3톤 음영 + 등지느러미 + 두 갈래 꼬리 + 가슴지느러미.
// D=진한 주황(등·지느러미 그늘) B=몸통 주황(쨍) H=배·볼(복숭아빛). 눈은 코드가 그린다(깜빡임·시선).
// 스프라이트: "Cute Fish Sprites" by chips8688 — https://opengameart.org/content/cute-fish-sprites
// 라이선스 OGA-BY 3.0 (출처 표기). 주황 변형 idle 1프레임을 격자로 이식 (눈은 코드 애니메이션으로 치환).
static NSString *BODY[BROWS] = {
    @"......AA.....",
    @"..AAAABBA....",
    @".ABBBCABA..AA",
    @"ABBBBBCAA.ACA",
    @"ABBBBBDCBACCA",
    @"ABBBBBDBBCBA.",
    @"ABBBBDDBBABBA",
    @".AAAAAAAA.AAA",
    @".....ACBA....",
    @"......AAA....",
};

static NSColor *fishCellColor(int c, int y) {
    if (y < 0 || y >= BROWS || c < 0 || c >= BCOLS) return nil;
    unichar ch = [BODY[y] characterAtIndex:c];
    switch (ch) {
        case 'A': return [NSColor colorWithCalibratedRed:1.000 green:0.400 blue:0.000 alpha:1]; // 몸 (외곽선 흡수) #FF6600
        case 'B': return [NSColor colorWithCalibratedRed:1.000 green:0.400 blue:0.000 alpha:1]; // 몸 #FF6600
        case 'C': return [NSColor colorWithCalibratedRed:1.000 green:0.560 blue:0.140 alpha:1]; // 음영 #FF8F24
        case 'D': return [NSColor colorWithCalibratedRed:1.000 green:0.700 blue:0.220 alpha:1]; // 밝은 배 #FFB338
        case 'E': return [NSColor colorWithCalibratedRed:1.000 green:0.400 blue:0.000 alpha:1]; // (미사용)
        default:  return nil;
    }
}

// 공식 Codex Pets 아틀라스 규격 — 스킨 장착 시
#define SHEET_COLS 8
#define SHEET_CELL_W 192.0
#define SHEET_CELL_H 208.0
static int sheetRowFor(GariMood m) {
    switch (m) { case MoodWork: return 7; case MoodAwake: return 8;
                 case MoodAlert: return 5; default: return 0; }
}

// ---------------------------------------------------------------- 상태 읽기 (가리 실제 상태)

@interface GariStateReader : NSObject
+ (NSString *)gariPath:(NSString *)rel;
+ (void)read:(GariMood *)mood badge:(int *)badge;
@end

@implementation GariStateReader
+ (NSString *)gariPath:(NSString *)rel {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"gari"]
            stringByAppendingPathComponent:rel];
}
+ (void)read:(GariMood *)mood badge:(int *)badge {
    NSFileManager *fm = NSFileManager.defaultManager;
    *mood = MoodSleep; *badge = 0;
    BOOL stale = YES;
    NSData *hd = [NSData dataWithContentsOfFile:[self gariPath:@"store/health.json"]];
    if (hd) {
        NSDictionary *h = [NSJSONSerialization JSONObjectWithData:hd options:0 error:nil];
        NSString *last = h[@"last_sweep"];
        if ([last isKindOfClass:NSString.class]) {
            NSDate *d = [[NSISO8601DateFormatter new] dateFromString:last];
            if (d && [NSDate.date timeIntervalSinceDate:d] < 30 * 60) stale = NO;
        }
    }
    NSData *pd = [NSData dataWithContentsOfFile:[self gariPath:@"pending-approvals.json"]];
    if (pd) {
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:pd options:0 error:nil];
        if ([arr isKindOfClass:NSArray.class]) *badge += (int)arr.count;
    }
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd";
    NSString *today = [df stringFromDate:NSDate.date];
    if ([fm fileExistsAtPath:[self gariPath:[NSString stringWithFormat:@"reports/%@.md", today]]]
        && ![fm fileExistsAtPath:[self gariPath:[NSString stringWithFormat:@"pet/seen-%@", today]]])
        *badge += 1;
    if (stale) *mood = MoodAlert;
    else if ([fm fileExistsAtPath:[self gariPath:@"store/sweep.lock"]]) *mood = MoodWork;
    else if (*badge > 0) *mood = MoodAwake;
}
@end

// ---------------------------------------------------------------- 하트 파티클

@interface Heart : NSObject
@property CGFloat x, y, vy, life;
@end
@implementation Heart @end

@interface AmbientBubble : NSObject
@property CGFloat x, y, vy, life, size, wobble;
@end
@implementation AmbientBubble @end

// 테두리 없는 패널이 키보드 입력을 받으려면 필요. ESC = 닫기 (팝오버 표준).
@interface KeyableWindow : NSWindow
@end
@implementation KeyableWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)cancelOperation:(id)sender { [self orderOut:nil]; }
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53) { [self orderOut:nil]; return; }  // ESC
    [super keyDown:event];
}
@end

// 위→아래로 쌓는 컨테이너 (수동 레이아웃용)
@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

// ---- 패널 UI 헬퍼 (라벨·행 카드) ----

static NSAttributedString *mdRender(NSString *text, CGFloat size, NSColor *color) {
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSFont *base = [NSFont systemFontOfSize:size];
    NSFont *bold = [NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
    NSFont *head = [NSFont systemFontOfSize:size + 1.5 weight:NSFontWeightBold];
    NSFont *mono = [NSFont monospacedSystemFontOfSize:size - 1 weight:NSFontWeightRegular];
    NSColor *codeBg = [NSColor colorWithCalibratedWhite:0 alpha:0.30];
    NSColor *accent = [NSColor colorWithCalibratedRed:1.00 green:0.58 blue:0.22 alpha:1];
    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    para.lineSpacing = 2.5;
    NSMutableParagraphStyle *headPara = [para mutableCopy];
    headPara.paragraphSpacingBefore = 7;
    BOOL inCode = NO;
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    for (NSUInteger li = 0; li < lines.count; li++) {
        NSString *line = lines[li];
        if ([line hasPrefix:@"```"]) { inCode = !inCode; continue; }   // 펜스 줄은 표시 안 함
        NSFont *lineFont = base;
        NSParagraphStyle *linePara = para;
        NSColor *lineColor = color;
        if (inCode) {
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:line
                attributes:@{NSFontAttributeName: mono, NSForegroundColorAttributeName: color,
                             NSBackgroundColorAttributeName: codeBg,
                             NSParagraphStyleAttributeName: para}]];
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                attributes:@{NSFontAttributeName: mono, NSParagraphStyleAttributeName: para}]];
            continue;
        }
        if ([line hasPrefix:@"### "]) { line = [line substringFromIndex:4]; lineFont = bold; linePara = headPara; }
        else if ([line hasPrefix:@"## "]) { line = [line substringFromIndex:3]; lineFont = head; linePara = headPara; }
        else if ([line hasPrefix:@"# "]) { line = [line substringFromIndex:2]; lineFont = head; linePara = headPara; }
        if ([line hasPrefix:@"- "]) line = [@"·  " stringByAppendingString:[line substringFromIndex:2]];
        if ([line containsString:@"\u00ab\ucc38\uacac"] || [line hasPrefix:@"\ucc38\uacac"])
            lineColor = accent;   // «참견 줄은 포인트 컬러
        NSArray *codeParts = [line componentsSeparatedByString:@"`"];
        for (NSUInteger ci = 0; ci < codeParts.count; ci++) {
            if (![codeParts[ci] length]) continue;
            if (ci % 2 == 1) {   // `인라인 코드`
                [out appendAttributedString:[[NSAttributedString alloc] initWithString:codeParts[ci]
                    attributes:@{NSFontAttributeName: mono, NSForegroundColorAttributeName: lineColor,
                                 NSBackgroundColorAttributeName: codeBg,
                                 NSParagraphStyleAttributeName: linePara}]];
                continue;
            }
            NSArray *parts = [codeParts[ci] componentsSeparatedByString:@"**"];
            for (NSUInteger i = 0; i < parts.count; i++) {
                if (![parts[i] length]) continue;
                [out appendAttributedString:[[NSAttributedString alloc] initWithString:parts[i]
                    attributes:@{NSFontAttributeName: (i % 2 == 1) ? bold : lineFont,
                                 NSForegroundColorAttributeName: lineColor,
                                 NSParagraphStyleAttributeName: linePara}]];
            }
        }
        if (li + 1 < lines.count)
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                attributes:@{NSFontAttributeName: base, NSParagraphStyleAttributeName: para,
                             NSForegroundColorAttributeName: color}]];
    }
    NSDataDetector *det = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
    [det enumerateMatchesInString:out.string options:0 range:NSMakeRange(0, out.length)
        usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags fl, BOOL *stop) {
        if (m.URL)
            [out addAttributes:@{NSLinkAttributeName: m.URL,
                NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:1.0 green:0.62 blue:0.30 alpha:1],
                NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)} range:m.range];
    }];
    return out;
}

static NSButton *flatBtn(NSString *title, NSColor *tint, id target, SEL action) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    b.bordered = NO;
    b.wantsLayer = YES;
    b.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:0.06].CGColor;
    b.layer.borderColor = [NSColor colorWithCalibratedWhite:1 alpha:0.14].CGColor;
    b.layer.borderWidth = 1;
    b.layer.cornerRadius = 6;
    b.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    b.contentTintColor = tint;
    return b;
}

static NSTextField *hudLabel(NSString *text, NSFont *font, NSColor *color,
                             NSInteger maxLines, CGFloat width) {
    NSTextField *l = [NSTextField wrappingLabelWithString:text ?: @""];
    l.font = font;
    l.textColor = color;
    l.selectable = NO;
    l.maximumNumberOfLines = maxLines;
    l.cell.truncatesLastVisibleLine = (maxLines > 0);   // 무제한 라벨은 절대 말줄임 금지
    l.preferredMaxLayoutWidth = width;
    l.frame = NSMakeRect(0, 0, width, 10);
    CGFloat h = ceil([l.cell cellSizeForBounds:NSMakeRect(0, 0, width, 20000)].height);  // 셀 실측
    CGFloat lineH = ceil(font.ascender - font.descender + font.leading) + 2;
    if (maxLines > 0) h = MIN(h, lineH * maxLines);
    l.frame = NSMakeRect(0, 0, width, h + 2);
    return l;
}

static NSView *hudRowCard(CGFloat width) {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 10)];
    row.wantsLayer = YES;
    row.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.055].CGColor;
    row.layer.cornerRadius = 10;
    return row;
}

// ---------------------------------------------------------------- 펫 뷰

@interface PetView : NSView
@property GariMood mood;
@property int badge;
@property long tick;
@property (strong) NSImage *sheet;
@property (strong) NSDate *moodChangedAt;
@property (strong) NSDate *happyUntil;      // 쓰다듬 반응 창 (표정)
@property (strong) NSString *bubbleOverride;
@property (strong) NSDate *bubbleUntil;     // 말풍선 유지 시한 (표정과 분리)
@property (strong) NSMutableArray<Heart *> *hearts;
@property (strong) NSMutableArray<AmbientBubble *> *ambient;
@property int bubbleCountdown;
// 살아있음 엔진
@property CGFloat breathPhase;
@property int blinkCountdown, blinkFrames;
@property CGFloat hopY, hopV;
@property NSPoint lookVec;                  // 눈동자 방향 (-1..1)
@property BOOL mouseInside;
@property int glanceCountdown;
@property NSPoint dragOffset;
@property BOOL dragged;
@property BOOL mouseIsDown;      // 드래그 중 클릭통과 토글 금지
@property BOOL cursorPushed;
@property NSPoint lookTarget;    // 두리번 목표 (lookVec이 이쪽으로 보간)
@property (strong) NSWindow *hudWindow;     // 현황판 — 클릭으로 토글
@property (strong) NSScrollView *hudScroll; // 콘텐츠 (JSON → 네이티브 행)
@property (strong) NSTextField *hudInput;   // 패널 하단 질문창
@property (strong) NSTextField *headerSub;  // 헤더 상태 줄
@property (strong) NSTextField *headerTime;
@property (strong) NSView *headerDot;       // 파이프라인 상태 점
@property (strong) NSDictionary *hudData;   // gari hud --json
@property int hudMode;                       // 0=현황판 1=대화
@property BOOL showAllPendings;              // 처리함 "그 외" 펼침
@property BOOL showRecords;                  // 오늘 기록 펼침
@property BOOL showSuggestions;              // 가리 정리 제안 펼침
@property BOOL showWorkItems;                // 실무급 미결 펼침
@property int wiggleFrames;                  // 씰룩 남은 프레임
@property NSInteger lastThreadCount;         // 페이드인 판정용
@property (strong) NSButton *tabA, *tabB;
@property (strong) NSView *tabLine;
@property (strong) NSPopUpButton *chatPopup;
@property (strong) NSArray *chatSessionIds;
@property (strong) NSArray *chatSessionTitles;
@property (strong) NSString *chatCurrentSid;
@property (strong) NSTimer *askTimer;
@property (strong) NSString *lastAskStatus;
@property (strong) NSString *lastQ, *lastA; // 마지막 문답
@property BOOL asking;
@end

@implementation PetView

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    self.hearts = [NSMutableArray array];
    self.ambient = [NSMutableArray array];
    self.bubbleCountdown = 30;
    self.blinkCountdown = 30;
    self.glanceCountdown = 40;
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                NSTrackingActiveAlways | NSTrackingInVisibleRect
        owner:self userInfo:nil]];
    return self;
}

- (BOOL)isHappy { return self.happyUntil && [self.happyUntil timeIntervalSinceNow] > 0; }

// 물고기 몸 위인가 (관대한 히트 영역 — 몸 타원 + 꼬리, 여유 6px)
- (BOOL)pointOverFish:(NSPoint)viewPt {
    CGFloat ox = (self.bounds.size.width - BCOLS * CELL) / 2;
    CGFloat oyBase = 16;
    int c = (int)floor((viewPt.x - ox) / CELL);
    int rBottom = (int)floor((viewPt.y - oyBase) / CELL);
    int y = BROWS - 1 - rBottom;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++)
            if (fishCellColor(c + dx, y + dy)) return YES;   // 1셀 여유
    return NO;
}

// 클릭 통과: 커서가 물고기 위일 때만 창이 마우스를 받는다 (틱마다 저비용 판정)
- (void)updateClickThrough {
    if (self.mouseIsDown) return;   // 드래그 중엔 유지
    NSPoint mouse = [NSEvent mouseLocation];
    NSRect wf = self.window.frame;
    BOOL over = NO;
    if (NSPointInRect(mouse, wf))
        over = [self pointOverFish:NSMakePoint(mouse.x - wf.origin.x,
                                               mouse.y - wf.origin.y)];
    self.window.ignoresMouseEvents = !over;
    if (over && !self.cursorPushed) { [NSCursor.pointingHandCursor push]; self.cursorPushed = YES; }
    else if (!over && self.cursorPushed) { [NSCursor pop]; self.cursorPushed = NO; }
}

// 다음 틱 간격 — 활동 없으면 느리게 (RunCat식 상시 고빈도 웨이크업 회피)
- (NSTimeInterval)desiredTickInterval {
    if (!self.window.isVisible) return 2.0;                      // 숨김 중
    BOOL active = (self.mood != MoodSleep) || self.hearts.count > 0
                  || self.ambient.count > 0
                  || self.hopY > 0 || self.bubbleOverride != nil
                  || self.mouseInside;
    return active ? 0.12 : 0.45;                                 // 잘 때 숨쉬기는 2fps면 족함
}

// ---------------- 살아있음 틱 (적응형)
- (void)animTick {
    self.tick += 1;
    [self updateClickThrough];
    self.breathPhase += 0.14;
    // 깜빡임 (잘 땐 안 함) — 1프레임만, 간격 넉넉히: "눈이 사라졌다 나온다" 체감 방지
    if (self.mood != MoodSleep) {
        if (self.blinkFrames > 0) self.blinkFrames -= 1;
        else if (--self.blinkCountdown <= 0) {
            self.blinkFrames = 1;
            self.blinkCountdown = 50 + arc4random_uniform(60);   // 6~13초에 한 번
        }
    }
    // 깡총 물리
    if (self.hopV != 0 || self.hopY > 0) {
        self.hopY += self.hopV; self.hopV -= 1.6;
        if (self.hopY <= 0) { self.hopY = 0; self.hopV = 0; }
    } else if (self.mood == MoodWork && self.tick % 10 == 0) {
        self.hopV = 4.2;   // 일할 땐 통통거림
    } else if (self.mood == MoodAwake && arc4random_uniform(90) == 0) {
        self.hopV = 5.0;   // 가끔 신나서 한 번
    }
    // 씰룩 — 깨어 있을 때 이따금 (자세 고쳐 앉기)
    if (self.wiggleFrames > 0) self.wiggleFrames -= 1;
    else if (self.mood == MoodAwake && self.hopY == 0 && arc4random_uniform(150) == 0)
        self.wiggleFrames = 12;
    // 시선: 마우스 없으면 가끔 두리번 — 목표점으로 부드럽게 (순간이동 금지)
    if (!self.mouseInside && self.mood != MoodSleep && --self.glanceCountdown <= 0) {
        self.lookTarget = NSMakePoint(((int)arc4random_uniform(3) - 1) * 0.8,
                                      ((int)arc4random_uniform(3) - 1) * 0.4);
        self.glanceCountdown = 30 + arc4random_uniform(50);
    }
    if (!self.mouseInside) {
        self.lookVec = NSMakePoint(self.lookVec.x + (self.lookTarget.x - self.lookVec.x) * 0.25,
                                   self.lookVec.y + (self.lookTarget.y - self.lookVec.y) * 0.25);
    }
    // 하트 부유
    for (Heart *h in [self.hearts copy]) {
        h.y += h.vy; h.life -= 0.045;
        if (h.life <= 0) [self.hearts removeObject:h];
    }
    // 물방울 앰비언트 — 사용자 지시로 비활성 (2026-07-06). 일할 때 기포(상태 신호)는 별도.
    if (NO && --self.bubbleCountdown <= 0) {
        AmbientBubble *b = [AmbientBubble new];
        CGFloat ox = (self.bounds.size.width - BCOLS * CELL) / 2;
        b.x = ox + CELL * (0.8 + arc4random_uniform(20) / 10.0);
        b.y = 16 + BROWS * CELL * 0.55;
        b.vy = 0.6 + arc4random_uniform(6) / 10.0;
        b.size = 2.5 + arc4random_uniform(25) / 10.0;
        b.life = 1.0;
        b.wobble = arc4random_uniform(100) / 100.0 * 6.28;
        [self.ambient addObject:b];
        self.bubbleCountdown = 34 + arc4random_uniform(56);   // 4~11초 간격
    }
    for (AmbientBubble *b in [self.ambient copy]) {
        b.y += b.vy;
        b.wobble += 0.18;
        b.x += sin(b.wobble) * 0.35;
        b.life -= 0.012;
        if (b.life <= 0 || b.y > self.bounds.size.height - 4) [self.ambient removeObject:b];
    }
    self.needsDisplay = YES;
}

// ---------------- 그리기
- (void)drawRect:(NSRect)dirtyRect {
    CGFloat ox = (self.bounds.size.width - BCOLS * CELL) / 2
               + (self.wiggleFrames > 0 ? sin(self.wiggleFrames * 1.1) * 2.4 : 0);
    CGFloat oy = 16 + self.hopY;
    CGFloat spriteTop, spriteRight;
    CGFloat breath = (self.mood == MoodSleep ? 1.6 : 0.9) * (1 + sin(self.breathPhase)) / 2;

    if (self.sheet) {
        int row = sheetRowFor(self.mood);
        int col = (int)(self.tick / 3) % SHEET_COLS;
        NSRect src = NSMakeRect(col * SHEET_CELL_W,
                                self.sheet.size.height - (row + 1) * SHEET_CELL_H,
                                SHEET_CELL_W, SHEET_CELL_H);
        NSRect dst = NSMakeRect((self.bounds.size.width - 96) / 2, 12 + self.hopY, 96, 104);
        [NSGraphicsContext.currentContext setImageInterpolation:NSImageInterpolationNone];
        [self.sheet drawInRect:dst fromRect:src
                     operation:NSCompositingOperationSourceOver fraction:1.0
                respectFlipped:YES hints:nil];
        spriteTop = NSMaxY(dst); spriteRight = NSMaxX(dst);
    } else {
        // 물고기는 물에 떠 있다 — 부유(bob)가 숨쉬기를 겸한다
        CGFloat bob = sin(self.breathPhase * (self.mood == MoodSleep ? 0.5 : 1.0))
                      * (self.mood == MoodSleep ? 1.5 : 2.5);
        oy += bob;
        BOOL flipped = (self.mood == MoodAlert);   // 배관 이상 = 배 뒤집힌 물고기
        // 꼬리 흔들기: 꼬리 열이 위아래로 (일할 땐 빠르게)
        long wagTick = self.mood == MoodWork ? self.tick : self.tick / 3;
        CGFloat wag = (wagTick % 2 == 0 ? 1 : -1) * (self.mood == MoodSleep ? 0 : 2);
        for (int r = 0; r < BROWS; r++) {
            int logicalY = flipped ? (BROWS - 1 - r) : r;
            for (int c = 0; c < BCOLS; c++) {
                NSColor *col = fishCellColor(c, logicalY);
                if (!col) continue;
                [col setFill];
                // 정수 좌표로 스냅 — 소수점 오프셋이 만드는 픽셀 사이 줄무늬 방지
                CGFloat y = floor(oy + (BROWS - 1 - r) * CELL + (c >= 10 ? wag : 0));
                NSRectFill(NSMakeRect(floor(ox + c * CELL), y, CELL, CELL));
            }
        }
        [self drawFaceAtX:ox y:oy flipped:flipped];
        spriteTop = oy + BROWS * CELL;
        spriteRight = ox + BCOLS * CELL;
    }

    // zzz (잘 때)
    if (self.mood == MoodSleep && (self.tick / 8) % 2 == 0) {
        NSString *z = (self.tick / 8) % 4 == 0 ? @"z" : @"zZ";
        [z drawAtPoint:NSMakePoint(spriteRight - 14, spriteTop + 2)
        withAttributes:@{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightBold],
                         NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.55 alpha:0.9]}];
    }
    // 물방울 (테두리만 있는 작은 원 — 픽셀 감성)
    for (AmbientBubble *b in self.ambient) {
        NSColor *bc = [NSColor colorWithCalibratedRed:0.55 green:0.80 blue:0.98
                                                alpha:MAX(0, MIN(0.8, b.life))];
        [bc setStroke];
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(b.x, b.y, b.size, b.size)];
        ring.lineWidth = 1.2;
        [ring stroke];
    }
    // 하트
    for (Heart *h in self.hearts) [self drawHeartAt:NSMakePoint(h.x, h.y) alpha:h.life];
    // 말풍선
    if (self.bubbleOverride && self.bubbleUntil &&
        [self.bubbleUntil timeIntervalSinceNow] <= 0) self.bubbleOverride = nil;
    NSString *bubble = self.bubbleOverride;
    if (!bubble && self.moodChangedAt && [NSDate.date timeIntervalSinceDate:self.moodChangedAt] < 12.0) {
        switch (self.mood) {
            case MoodWork:  bubble = @"정리 중…"; break;
            case MoodAwake: bubble = @"형님, 보고 나왔습니다"; break;
            case MoodAlert: bubble = @"배관 이상!"; break;
            default: break;
        }
    }
    if (bubble) [self drawBubble:bubble top:spriteTop];
    // 배지
    // 배지 제거 (2026-07-06 사용자 지시) — 대기 건수는 현황판·무드 표정이 전달
    (void)spriteRight;
}

// 얼굴 (레이어 2: 코드 — 흰자 없는 작은 까만 눈. 깜빡임·시선은 코드가 담당)
- (void)drawFaceAtX:(CGFloat)ox y:(CGFloat)oy flipped:(BOOL)flipped {
    // 눈 자리 = 머리 위쪽 (rows 4..5, cols 3..4 — 세로 중앙이라 뒤집혀도 같은 자리).
    int eyeRowTop = 3;
    CGFloat eyeY = oy + (BROWS - 1 - (eyeRowTop + 1)) * CELL - CELL * 0.5;   // 눈 영역 하단 y (반 칸 아래)
    CGFloat ex = ox + 2.5 * CELL;
    CGFloat eyeW = 1.2 * CELL;  // 아티스트 눈 = 세로 알약 (1x2셀)
    (void)flipped;
    BOOL closed = (self.mood == MoodSleep) || self.blinkFrames > 0;
    BOOL happy = [self isHappy];
    NSColor *ink = [NSColor colorWithCalibratedWhite:0.10 alpha:1];

    if (self.mood == MoodAlert) {  // X 눈 — 뒤집힌 물고기의 만국 공통 신호
        [ink setFill];
        for (int i = 0; i < 4; i++) {
            CGFloat d = i * CELL * 0.55;
            NSRectFill(NSMakeRect(ex + d, eyeY + d, CELL * 0.6, CELL * 0.6));
            NSRectFill(NSMakeRect(ex + CELL * 1.65 - d, eyeY + d, CELL * 0.6, CELL * 0.6));
        }
    } else if (happy) {  // ∩ 웃는 눈
        [ink setFill];
        NSRectFill(NSMakeRect(ex - CELL * 0.2, eyeY + CELL * 0.2, CELL * 0.7, CELL * 1.1));
        NSRectFill(NSMakeRect(ex + CELL * 0.5, eyeY + CELL * 1.0, CELL * 1.4, CELL * 0.7));
        NSRectFill(NSMakeRect(ex + CELL * 1.7, eyeY + CELL * 0.2, CELL * 0.7, CELL * 1.1));
    } else if (closed) {  // 감은 눈 — 같은 자리 막대 (사라진 느낌 금지)
        [ink setFill];
        NSRectFill(NSMakeRect(ex - CELL * 0.1, eyeY + CELL * 0.6, CELL * 2.4, CELL * 0.8));
    } else {  // 까만 세로 알약 눈 — 시선 추적
        [ink setFill];
        NSRectFill(NSMakeRect(ex + self.lookVec.x * CELL * 0.3,
                              eyeY + CELL * 0.05 + self.lookVec.y * CELL * 0.3,
                              CELL * 1.1, CELL * 1.9));
    }

    // 입 없음 — 일할 때만 머리 앞에서 기포가 뽀글 (상태 신호)
    if (self.mood == MoodWork) {
        [[NSColor colorWithCalibratedRed:0.55 green:0.80 blue:0.98 alpha:0.85] setFill];
        int phase = (int)(self.tick % 12);
        if (phase < 8) {
            CGFloat bs = 2.5 + phase * 0.3;
            [[NSBezierPath bezierPathWithOvalInRect:
                NSMakeRect(ox + CELL * 0.4, eyeY + CELL * (2.5 + phase * 0.7), bs, bs)] fill];
        }
    }
}

- (void)drawHeartAt:(NSPoint)p alpha:(CGFloat)a {
    NSColor *c = [NSColor colorWithCalibratedRed:0.95 green:0.42 blue:0.50 alpha:MAX(0, MIN(1, a))];
    [c setFill];
    CGFloat s = 3.2;  // 픽셀 하트 (5x4)
    int heart[4][5] = {{0,1,0,1,0},{1,1,1,1,1},{0,1,1,1,0},{0,0,1,0,0}};
    for (int r = 0; r < 4; r++)
        for (int col = 0; col < 5; col++)
            if (heart[r][col]) NSRectFill(NSMakeRect(p.x + col * s, p.y + (3 - r) * s, s, s));
}

- (void)drawBubble:(NSString *)text top:(CGFloat)spriteTop {
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.15 alpha:1]};
    NSSize ts = [text sizeWithAttributes:attrs];
    CGFloat bw = ts.width + 16, bh = ts.height + 8;
    CGFloat ox = (self.bounds.size.width - BCOLS * CELL) / 2;
    CGFloat headX = ox + 4 * CELL;                     // 머리 위 앵커
    CGFloat bx = MAX(4, MIN(headX - bw * 0.35, self.bounds.size.width - bw - 4));
    CGFloat by = MIN(spriteTop + 10, self.bounds.size.height - bh - 2);
    NSRect bub = NSMakeRect(bx, by, bw, bh);
    [[NSColor colorWithCalibratedWhite:0.98 alpha:0.96] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bub xRadius:8 yRadius:8] fill];
    NSBezierPath *tail = [NSBezierPath bezierPath];    // 말풍선 꼬리
    [tail moveToPoint:NSMakePoint(headX - 3, by)];
    [tail lineToPoint:NSMakePoint(headX + 7, by)];
    [tail lineToPoint:NSMakePoint(headX + 1, by - 6)];
    [tail closePath];
    [tail fill];
    [text drawAtPoint:NSMakePoint(bx + 8, by + 4) withAttributes:attrs];
}

// ---------------- 인터랙션
- (void)mouseEntered:(NSEvent *)e { self.mouseInside = YES; }
- (void)mouseExited:(NSEvent *)e { self.mouseInside = NO; self.lookVec = NSZeroPoint; }
- (void)mouseMoved:(NSEvent *)e {
    if (self.mood == MoodSleep) return;   // 자는 애는 시선 없음
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSPoint center = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
    CGFloat dx = (p.x - center.x) / (self.bounds.size.width / 2);
    CGFloat dy = (p.y - center.y) / (self.bounds.size.height / 2);
    self.lookVec = NSMakePoint(MAX(-1, MIN(1, dx)), MAX(-1, MIN(1, dy)));
}

- (void)mouseDown:(NSEvent *)e {
    self.dragged = NO;
    self.mouseIsDown = YES;
    self.dragOffset = e.locationInWindow;
}
- (void)mouseDragged:(NSEvent *)e {
    self.dragged = YES;
    NSPoint s = [NSEvent mouseLocation];
    [self.window setFrameOrigin:NSMakePoint(s.x - self.dragOffset.x, s.y - self.dragOffset.y)];
}

- (void)mouseUp:(NSEvent *)e {
    self.mouseIsDown = NO;
    if (self.dragged) {
        NSPoint o = self.window.frame.origin;
        NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"x": @(o.x), @"y": @(o.y)}
                                                    options:0 error:nil];
        [d writeToFile:[GariStateReader gariPath:@"pet/position.json"] atomically:YES];
        return;
    }
    // 싱글클릭 = 쓰다듬기 + 현황판 토글 (즉시 — 더블클릭 의미 없음, 지연 없음)
    [self petting];
}

- (void)petting {
    self.happyUntil = [NSDate dateWithTimeIntervalSinceNow:1.8];
    self.hopV = 5.5;
    for (int i = 0; i < 3 + arc4random_uniform(3); i++) {
        Heart *h = [Heart new];
        h.x = self.bounds.size.width / 2 - 30 + arc4random_uniform(60);
        h.y = 16 + BROWS * CELL - 8 + arc4random_uniform(14);
        h.vy = 1.2 + arc4random_uniform(10) / 10.0;
        h.life = 1.0;
        [self.hearts addObject:h];
    }
    NSArray *lines = self.badge > 0
        ? @[@"형님! 현황판 대령입니다", @"충성! 결재 대기 중입니다", @"헤헤, 형님 최고"]
        : @[@"충성!", @"헤헤", @"형님 오셨습니까!", @"오늘도 듣고 있습니다", @"카드 쌓는 중입니다"];
    self.bubbleOverride = lines[arc4random_uniform((uint32_t)lines.count)];
    self.bubbleUntil = [NSDate dateWithTimeIntervalSinceNow:2.5];
    [self toggleHud];   // 클릭 = 쓰다듬기 + 현황판 (가리의 모든 것이 가리 안에서 보인다)
    self.needsDisplay = YES;
}

static NSString *hudTimeShort(NSString *iso) {
    if (![iso isKindOfClass:NSString.class] || iso.length < 16) return @"";
    NSString *hm = [iso substringWithRange:NSMakeRange(11, 5)];
    NSString *day = [iso substringToIndex:10];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd";
    NSString *today = [df stringFromDate:NSDate.date];
    return [day isEqualToString:today] ? hm : [NSString stringWithFormat:@"%@ %@", [day substringFromIndex:5], hm];
}

// ---------------- 현황판 (HUD) — 보고·결재·미결·카드·상태를 펫 옆 패널로

- (void)toggleHud {
    if (self.hudWindow && self.hudWindow.isVisible) {
        [self.hudWindow orderOut:nil];
        return;
    }
    [self openHud];
}

// 패널 카드 조립 (창·스냅샷 공용) — 헤더 + 콘텐츠 스크롤 + 하단 질문 바
- (NSView *)makeHudCard:(NSSize)size {
    NSView *card = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    card.wantsLayer = YES;
    card.layer.cornerRadius = 18;
    card.layer.masksToBounds = YES;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.10].CGColor;

    // 뒤 배경 블러 (라이브) — 스냅샷/미지원 시에도 아래 틴트가 카드를 지탱
    NSVisualEffectView *fx = [[NSVisualEffectView alloc]
        initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    fx.material = NSVisualEffectMaterialHUDWindow;
    fx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    fx.state = NSVisualEffectStateActive;
    fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [card addSubview:fx];
    NSView *tint = [[NSView alloc] initWithFrame:fx.frame];
    tint.wantsLayer = YES;
    tint.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.10 alpha:0.88].CGColor;
    tint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [card addSubview:tint];

    // ---- 헤더 2단: ① 상태 한 줄 (점+요약+시각, 이름 없음 — 사용자 지시) ② 자체 탭 바 ----
    CGFloat headerH = 68;
    NSView *dot = [[NSView alloc]
        initWithFrame:NSMakeRect(22, size.height - 25, 8, 8)];
    dot.wantsLayer = YES;
    dot.layer.cornerRadius = 4;
    dot.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.30 green:0.82 blue:0.45 alpha:1].CGColor;
    [card addSubview:dot];
    self.headerDot = dot;

    NSTextField *sub = hudLabel(@"연결 중…", [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium],
                                [NSColor colorWithCalibratedWhite:0.70 alpha:1], 1, size.width - 44 - 66);
    sub.frame = NSMakeRect(38, size.height - 30, size.width - 44 - 66, 16);
    [card addSubview:sub];
    self.headerSub = sub;

    NSTextField *time = hudLabel(@"", [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                                 [NSColor colorWithCalibratedWhite:0.45 alpha:1], 1, 60);
    time.frame = NSMakeRect(size.width - 70, size.height - 30, 50, 16);
    time.alignment = NSTextAlignmentRight;
    [card addSubview:time];
    self.headerTime = time;

    // 자체 탭 바 — 시스템 부품은 떠 있는 반투명 패널에서 비활성 회색으로 렌더되므로 직접 그린다
    CGFloat halfW = size.width / 2;
    NSButton *ta = [NSButton buttonWithTitle:@"현황판" target:self action:@selector(tabTapped:)];
    ta.bordered = NO;
    ta.tag = 0;
    ta.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
    ta.frame = NSMakeRect(0, size.height - 64, halfW, 30);
    [card addSubview:ta];
    self.tabA = ta;
    NSButton *tb = [NSButton buttonWithTitle:@"대화" target:self action:@selector(tabTapped:)];
    tb.bordered = NO;
    tb.tag = 1;
    tb.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
    tb.frame = NSMakeRect(halfW, size.height - 64, halfW, 30);
    [card addSubview:tb];
    self.tabB = tb;

    NSView *headerLine = [[NSView alloc]
        initWithFrame:NSMakeRect(0, size.height - headerH, size.width, 1)];
    headerLine.wantsLayer = YES;
    headerLine.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.07].CGColor;
    [card addSubview:headerLine];

    NSView *tabLine = [[NSView alloc]
        initWithFrame:NSMakeRect(0, size.height - headerH, halfW, 2)];
    tabLine.wantsLayer = YES;
    tabLine.layer.backgroundColor = [NSColor colorWithCalibratedRed:1.00 green:0.48 blue:0.10 alpha:1].CGColor;
    [card addSubview:tabLine];
    self.tabLine = tabLine;

    // ---- 콘텐츠 스크롤 ----
    NSScrollView *sv = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(0, 57, size.width, size.height - headerH - 57)];
    sv.hasVerticalScroller = YES;
    sv.drawsBackground = NO;
    sv.autohidesScrollers = YES;
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [card addSubview:sv];
    self.hudScroll = sv;

    // ---- 하단 질문 바 ----
    NSView *divider = [[NSView alloc] initWithFrame:NSMakeRect(0, 56, size.width, 1)];
    divider.wantsLayer = YES;
    divider.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.07].CGColor;
    divider.autoresizingMask = NSViewWidthSizable;
    [card addSubview:divider];

    // 껍데기(스타일) + 순수 입력(글자만) 분리 — 텍스트필드에 직접 스타일을 주면
    // 글자 상단 붙음 + 편집기 이중 배경으로 깨진다
    CGFloat wrapH = 44;
    NSView *inputWrap = [[NSView alloc]
        initWithFrame:NSMakeRect(14, 9, size.width - 28, wrapH)];
    inputWrap.wantsLayer = YES;
    inputWrap.layer.cornerRadius = 10;
    inputWrap.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.08].CGColor;
    inputWrap.layer.borderWidth = 1;
    inputWrap.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.10].CGColor;
    [card addSubview:inputWrap];

    NSTextField *input = [[NSTextField alloc] init];
    input.bordered = NO;
    input.bezeled = NO;
    input.drawsBackground = NO;
    input.focusRingType = NSFocusRingTypeNone;
    input.font = [NSFont systemFontOfSize:13];
    input.textColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1];
    input.placeholderAttributedString = [[NSAttributedString alloc]
        initWithString:@"가리에게 물어보기…"
        attributes:@{NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.48 alpha:1],
                     NSFontAttributeName: [NSFont systemFontOfSize:13]}];
    input.target = self;
    input.action = @selector(hudAsk:);
    input.delegate = (id<NSTextFieldDelegate>)self;
    [input sizeToFit];
    CGFloat fieldH = input.frame.size.height;   // 글꼴 자연 높이 → 세로 중앙
    input.frame = NSMakeRect(12, (wrapH - fieldH) / 2,
                             inputWrap.frame.size.width - 24, fieldH);
    [inputWrap addSubview:input];
    self.hudInput = input;

    return card;
}

// 편집 시작 시 커서(삽입점)를 밝게 — 어두운 패널에서 기본 검정 커서는 안 보인다
- (void)controlTextDidBeginEditing:(NSNotification *)note {
    NSTextView *editor = (NSTextView *)[self.hudInput currentEditor];
    if ([editor isKindOfClass:NSTextView.class]) {
        editor.insertionPointColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1];
        editor.drawsBackground = NO;
    }
}

- (void)tabTapped:(NSButton *)btn {
    self.hudMode = (int)btn.tag;
    [self buildHud];
}

- (void)updateTabStyles {
    NSColor *on = [NSColor colorWithCalibratedWhite:0.96 alpha:1];
    NSColor *off = [NSColor colorWithCalibratedWhite:0.48 alpha:1];
    self.tabA.contentTintColor = self.hudMode == 0 ? on : off;
    self.tabB.contentTintColor = self.hudMode == 1 ? on : off;
    if (self.tabLine) {
        NSRect f = self.tabLine.frame;
        f.origin.x = self.hudMode == 0 ? 0 : f.size.width;
        self.tabLine.frame = f;
    }
}

// hudData(JSON) → 네이티브 행 구성. 반복 다듬기의 단일 지점.
- (void)buildHud {
    [self updateTabStyles];
    if (self.hudMode == 1) { [self buildChat]; return; }
    CGFloat W = self.hudScroll.frame.size.width;
    CGFloat pad = 22, contentW = W - pad * 2 - 14;   // 스크롤러 여유
    FlippedView *doc = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, W, 10)];
    __block CGFloat y = 16;

    NSColor *fg = [NSColor colorWithCalibratedWhite:0.94 alpha:1];
    NSColor *dim = [NSColor colorWithCalibratedWhite:0.52 alpha:1];
    NSColor *accent = [NSColor colorWithCalibratedRed:1.00 green:0.48 blue:0.10 alpha:1];

    NSDictionary *d = self.hudData;

    // 헤더 갱신
    NSDictionary *pipe = d[@"pipeline"];
    if (pipe) {
        BOOL ok = [pipe[@"ok"] boolValue];
        self.headerDot.layer.backgroundColor = (ok
            ? [NSColor colorWithCalibratedRed:0.30 green:0.82 blue:0.45 alpha:1]
            : [NSColor colorWithCalibratedRed:0.92 green:0.35 blue:0.30 alpha:1]).CGColor;
        NSDictionary *fresh = [d[@"freshness"] isKindOfClass:NSDictionary.class] ? d[@"freshness"] : @{};
        NSString *age = @"기록 없음";
        if (pipe[@"age_min"] != NSNull.null && pipe[@"age_min"]) {
            int interval = [fresh[@"sweep_interval_min"] intValue] ?: 10;
            int remain = interval - [pipe[@"age_min"] intValue];
            age = remain > 0
                ? [NSString stringWithFormat:@"%@분 전 정리, 다음 ~%d분", pipe[@"age_min"], remain]
                : [NSString stringWithFormat:@"%@분 전 정리, 곧 갱신", pipe[@"age_min"]];
        }
        NSNumber *cost = [pipe[@"cost_today"] isKindOfClass:NSNumber.class] ? pipe[@"cost_today"] : nil;
        self.headerSub.stringValue = [NSString stringWithFormat:@"%@ · %@ · 카드 %@%@",
            ok ? @"정상" : @"점검 필요", age, pipe[@"cards_today"] ?: @0,
            cost ? [NSString stringWithFormat:@" · $%.2f", cost.doubleValue] : @""];
        self.headerTime.stringValue = d[@"time"] ?: @"";
    } else {
        self.headerSub.stringValue = @"연결 실패 — 터미널에서 gari status";
    }

    NSDictionary *fr = [d[@"freshness"] isKindOfClass:NSDictionary.class] ? d[@"freshness"] : @{};
    NSString *mts = hudTimeShort(fr[@"morning_ts"]);
    void (^section)(NSString *) = ^(NSString *title) {
        NSTextField *l = hudLabel(title, [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                                  dim, 1, contentW);
        NSMutableAttributedString *a = [l.attributedStringValue mutableCopy];
        [a addAttribute:NSKernAttributeName value:@0.8 range:NSMakeRange(0, a.length)];
        l.attributedStringValue = a;
        l.frame = NSMakeRect(pad, y, contentW, l.frame.size.height);
        [doc addSubview:l];
        y += l.frame.size.height + 8;
    };

    // ═══ 그룹 1: 오늘 — 한 칸·참견·질문 합본 카드 (아침 산출, 하루 1회)
    NSDictionary *nsD = d[@"next_step"];
    NSString *nag = [d[@"nag"] isKindOfClass:NSString.class] ? d[@"nag"] : @"";
    NSString *question = [d[@"question"] isKindOfClass:NSString.class] ? d[@"question"] : @"";
    NSString *mentor = [d[@"mentor"] isKindOfClass:NSString.class] ? d[@"mentor"] : @"";
    if ([nsD[@"action"] length] || nag.length || question.length || mentor.length) {
        section(mts.length
            ? [NSString stringWithFormat:@"오늘 — %@ 산출 · 내일 %d시 갱신", mts, [fr[@"report_hour"] intValue] ?: 9]
            : @"오늘");
        FlippedView *today = [[FlippedView alloc] initWithFrame:NSZeroRect];
        today.wantsLayer = YES;
        today.layer.backgroundColor = [accent colorWithAlphaComponent:0.10].CGColor;
        today.layer.cornerRadius = 12;
        __block CGFloat cy = 13;
        CGFloat innerW = contentW - 28;
        if ([nsD[@"action"] length]) {
            NSTextField *act = hudLabel(nsD[@"action"],
                [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], fg, 0, innerW);
            act.frame = NSMakeRect(14, cy, innerW, act.frame.size.height);
            [today addSubview:act];
            cy += act.frame.size.height;
            if ([nsD[@"reason"] length]) {
                NSTextField *why = hudLabel(nsD[@"reason"],
                    [NSFont systemFontOfSize:12], [NSColor colorWithCalibratedWhite:0.72 alpha:1], 0, innerW);
                why.frame = NSMakeRect(14, cy + 4, innerW, why.frame.size.height);
                [today addSubview:why];
                cy += 4 + why.frame.size.height;
            }
        }
        void (^subRow)(NSString *, NSString *, NSColor *) = ^(NSString *prefix, NSString *text, NSColor *pc) {
            if (!text.length) return;
            NSView *div = [[NSView alloc] initWithFrame:NSMakeRect(14, cy + 10, innerW, 1)];
            div.wantsLayer = YES;
            div.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:0.09].CGColor;
            [today addSubview:div];
            cy += 20;
            NSTextField *pl = hudLabel(prefix, [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold], pc, 1, 34);
            pl.frame = NSMakeRect(14, cy + 1, 34, pl.frame.size.height);
            [today addSubview:pl];
            NSTextField *tl = hudLabel(text, [NSFont systemFontOfSize:12.5], fg, 0, innerW - 42);
            tl.frame = NSMakeRect(56, cy, innerW - 42, tl.frame.size.height);
            [today addSubview:tl];
            cy += tl.frame.size.height;
        };
        subRow(@"멘토", mentor, [NSColor colorWithCalibratedWhite:0.62 alpha:1]);
        subRow(@"참견", nag, accent);
        subRow(@"질문", question, dim);
        if (question.length) {
            NSTextField *hint = hudLabel(@"↳ 아래 입력창에 답하면 기록됩니다",
                [NSFont systemFontOfSize:10.5], dim, 1, innerW - 42);
            hint.frame = NSMakeRect(56, cy + 3, innerW - 42, hint.frame.size.height);
            [today addSubview:hint];
            cy += 3 + hint.frame.size.height;
        }
        today.frame = NSMakeRect(pad, y, contentW, cy + 13);
        [doc addSubview:today];
        y += cy + 13 + 22;
    }

    // ═══ 그룹 1.5: 프로젝트 방향판 — 어디로 가고 있는가 (위키 기반, 사용자 정의: "현황판은 방향 확인")
    NSArray *compass = [d[@"compass"] isKindOfClass:NSArray.class] ? d[@"compass"] : @[];
    if (compass.count) {
        section(@"프로젝트 방향판 — 위키 기준");
        for (NSDictionary *b in compass) {
            NSTextField *pj = hudLabel(b[@"project"],
                [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], fg, 1, contentW - 28);
            NSTextField *idl = hudLabel(b[@"identity"],
                [NSFont systemFontOfSize:10.5], dim, 1, contentW - 28);
            NSTextField *nx = hudLabel([b[@"next"] length]
                    ? [NSString stringWithFormat:@"다음: %@", b[@"next"]] : @"다음: (미결 없음)",
                [NSFont systemFontOfSize:11.5],
                [NSColor colorWithCalibratedWhite:0.82 alpha:1], 2, contentW - 28);
            CGFloat rh = 10 + pj.frame.size.height + 2 + idl.frame.size.height
                       + 4 + nx.frame.size.height + 10;
            NSView *row = hudRowCard(contentW);
            row.frame = NSMakeRect(pad, y, contentW, rh);
            pj.frame = NSMakeRect(14, rh - 10 - pj.frame.size.height, contentW - 28, pj.frame.size.height);
            idl.frame = NSMakeRect(14, rh - 10 - pj.frame.size.height - 2 - idl.frame.size.height,
                                   contentW - 28, idl.frame.size.height);
            nx.frame = NSMakeRect(14, 10, contentW - 28, nx.frame.size.height);
            pj.identifier = b[@"project"];
            NSClickGestureRecognizer *tap = [[NSClickGestureRecognizer alloc]
                initWithTarget:self action:@selector(compassRowTapped:)];
            [pj addGestureRecognizer:tap];
            [row addSubview:pj];
            [row addSubview:idl];
            [row addSubview:nx];
            [doc addSubview:row];
            y += rh + 8;
        }
        y += 14;
    }

    // ═══ 그룹 2: 처리함 — 형님 액션이 필요한 전부 (지금/끝난 듯/중복/결재/채점/그 외)
    NSArray *pendings = d[@"pendings"];
    NSDictionary *triage = [d[@"triage"] isKindOfClass:NSDictionary.class] ? d[@"triage"] : @{};
    NSArray *approvals = d[@"approvals"];
    NSArray *shadowItems = d[@"shadow"];
    NSUInteger inboxTotal = pendings.count + approvals.count + shadowItems.count;
    if (inboxTotal) {
        NSString *tts = hudTimeShort(triage[@"ts"]);
        section(tts.length
            ? [NSString stringWithFormat:@"처리함 %lu — %@ 가리 검토", inboxTotal, tts]
            : [NSString stringWithFormat:@"처리함 %lu", inboxTotal]);

        NSString *nowId = triage[@"now"][@"id"] ?: @"";
        NSString *nowWhy = triage[@"now"][@"why"] ?: @"";
        NSMutableDictionary *doneLike = [NSMutableDictionary dictionary];
        for (NSDictionary *dl in (triage[@"done_like"] ?: @[]))
            if (dl[@"id"]) doneLike[dl[@"id"]] = dl[@"evidence"] ?: @"";
        NSMutableSet *dupeDrop = [NSMutableSet set];
        for (NSDictionary *dp in (triage[@"dupes"] ?: @[]))
            for (NSString *dr in (dp[@"drop"] ?: @[])) [dupeDrop addObject:dr];

        // 미결 행 공통 (완료/나중에 버튼 포함)
        void (^pendRow)(NSDictionary *, NSString *, NSColor *, BOOL) =
            ^(NSDictionary *p, NSString *tag, NSColor *tagColor, BOOL highlight) {
            BOOL dimmed = !highlight && tag.length;
            NSTextField *t = hudLabel(p[@"text"],
                [NSFont systemFontOfSize:13 weight:highlight ? NSFontWeightSemibold : NSFontWeightRegular],
                dimmed ? dim : fg, 0, contentW - 126);
            NSString *origin = [p[@"restored"] boolValue]
                ? [NSString stringWithFormat:@"소급 복원 · %@/%@", p[@"tool"] ?: @"", p[@"project"] ?: @""]
                : [NSString stringWithFormat:@"%@/%@", p[@"tool"] ?: @"", p[@"project"] ?: @""];
            NSString *subTxt = tag.length
                ? [NSString stringWithFormat:@"%@ · %@", tag, origin]
                : [origin stringByAppendingString:@" · 눌러서 맥락 묻기"];
            NSTextField *sub2 = hudLabel(subTxt, [NSFont systemFontOfSize:10.5],
                tagColor ?: dim, 0, contentW - 126);
            CGFloat rh = 11 + t.frame.size.height + 3 + sub2.frame.size.height + 11;
            NSView *row = hudRowCard(contentW);
            if (highlight) {
                row.layer.borderColor = [accent colorWithAlphaComponent:0.5].CGColor;
                row.layer.borderWidth = 1;
            }
            row.frame = NSMakeRect(pad, y, contentW, rh);
            t.frame = NSMakeRect(14, rh - 11 - t.frame.size.height, contentW - 126, t.frame.size.height);
            [row addSubview:t];
            sub2.frame = NSMakeRect(14, 10, contentW - 126, sub2.frame.size.height);
            [row addSubview:sub2];
            t.identifier = p[@"id"] ?: @"";   // 본문 클릭 = 가리에게 이 미결의 맥락 질문
            NSClickGestureRecognizer *tap = [[NSClickGestureRecognizer alloc]
                initWithTarget:self action:@selector(pendingRowTapped:)];
            [t addGestureRecognizer:tap];
            NSButton *done = flatBtn(@"완료", accent, self, @selector(resolvePending:));
            done.identifier = p[@"id"] ?: @"";
            done.frame = NSMakeRect(contentW - 66, rh / 2 + 2, 52, 23);
            [row addSubview:done];
            NSButton *later = flatBtn(@"나중에", dim, self, @selector(snoozePending:));
            later.identifier = p[@"id"] ?: @"";
            later.frame = NSMakeRect(contentW - 66, rh / 2 - 25, 52, 23);
            [row addSubview:later];
            [doc addSubview:row];
            y += rh + 8;
        };

        NSDictionary *kinds = [triage[@"kinds"] isKindOfClass:NSDictionary.class] ? triage[@"kinds"] : @{};
        NSMutableArray *rest = [NSMutableArray array];       // 방향급 — 형님만 정할 수 있는 것
        NSMutableArray *workP = [NSMutableArray array];      // 실무급 — 파견으로 처리 가능
        NSDictionary *nowP = nil;
        NSMutableArray *doneP = [NSMutableArray array], *dupeP = [NSMutableArray array];
        for (NSDictionary *p in pendings) {
            NSString *pid = p[@"id"] ?: @"";
            if ([pid isEqualToString:nowId]) nowP = p;
            else if (doneLike[pid]) [doneP addObject:p];
            else if ([dupeDrop containsObject:pid]) [dupeP addObject:p];
            else if ([kinds[pid] isEqualToString:@"work"]) [workP addObject:p];
            else [rest addObject:p];
        }
        if (nowP) pendRow(nowP, [NSString stringWithFormat:@"▶ 지금 이거%@%@",
                                 nowWhy.length ? @" — " : @"", nowWhy], accent, YES);
        // 정리 제안(끝난 듯·중복)은 가리의 살림 — 기본 접힘, 형님 시야는 결정 대기만
        if (doneP.count + dupeP.count) {
            if (self.showSuggestions) {
                for (NSDictionary *p in doneP)
                    pendRow(p, [NSString stringWithFormat:@"끝난 듯 · %@", doneLike[p[@"id"]]],
                            [NSColor systemGreenColor], NO);
                for (NSDictionary *p in dupeP) pendRow(p, @"중복 — 접어도 됨", nil, NO);
            }
            NSButton *sg = [NSButton buttonWithTitle:
                self.showSuggestions ? @"정리 제안 접기 ▾"
                    : [NSString stringWithFormat:@"가리 정리 제안 %lu건 ▸ (끝난 듯·중복 — 확인만 하면 됨)",
                       doneP.count + dupeP.count]
                target:self action:@selector(toggleSuggestions:)];
            sg.bordered = NO;
            sg.controlSize = NSControlSizeSmall;
            sg.font = [NSFont systemFontOfSize:11.5];
            sg.contentTintColor = [NSColor systemGreenColor];
            sg.alignment = NSTextAlignmentLeft;
            sg.frame = NSMakeRect(pad, y, contentW, 24);
            [doc addSubview:sg];
            y += 30;
        }

        // 결재 — 입력창으로 답하면 기록됨
        for (NSString *a in approvals) {
            NSArray *parts = [a componentsSeparatedByString:@" — "];
            NSTextField *t = hudLabel(parts[0],
                [NSFont systemFontOfSize:13 weight:NSFontWeightMedium], fg, 0, contentW - 46);
            NSTextField *sub2 = hudLabel(parts.count > 1
                    ? [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" — "]
                    : @"결재 — 아래 입력창에 답하면 기록됩니다",
                [NSFont systemFontOfSize:10.5], dim, 2, contentW - 46);
            CGFloat rh = 11 + t.frame.size.height + 3 + sub2.frame.size.height + 11;
            NSView *row = hudRowCard(contentW);
            row.frame = NSMakeRect(pad, y, contentW, rh);
            NSTextField *mark = hudLabel(@"◇", [NSFont systemFontOfSize:12], accent, 1, 20);
            mark.frame = NSMakeRect(13, rh - 12 - mark.frame.size.height + 1, 20, mark.frame.size.height);
            [row addSubview:mark];
            t.frame = NSMakeRect(34, rh - 11 - t.frame.size.height, contentW - 46, t.frame.size.height);
            [row addSubview:t];
            sub2.frame = NSMakeRect(34, 10, contentW - 46, sub2.frame.size.height);
            [row addSubview:sub2];
            [doc addSubview:row];
            y += rh + 8;
        }

        // 채점 — 맞음/오발
        for (NSDictionary *s in shadowItems) {
            NSTextField *t = hudLabel(s[@"text"], [NSFont systemFontOfSize:12.5], fg, 0, contentW - 150);
            NSTextField *sub2 = hudLabel(@"코치 채점", [NSFont systemFontOfSize:10.5], dim, 1, contentW - 150);
            CGFloat rh = 11 + t.frame.size.height + 3 + sub2.frame.size.height + 11;
            NSView *row = hudRowCard(contentW);
            row.frame = NSMakeRect(pad, y, contentW, rh);
            t.frame = NSMakeRect(14, rh - 11 - t.frame.size.height, contentW - 150, t.frame.size.height);
            [row addSubview:t];
            sub2.frame = NSMakeRect(14, 10, contentW - 150, sub2.frame.size.height);
            [row addSubview:sub2];
            NSButton *ok = flatBtn(@"맞음", [NSColor systemGreenColor], self, @selector(gradeShadow:));
            ok.identifier = [NSString stringWithFormat:@"%@|right", s[@"id"]];
            ok.frame = NSMakeRect(contentW - 126, (rh - 23) / 2, 54, 23);
            [row addSubview:ok];
            NSButton *no = flatBtn(@"오발", dim, self, @selector(gradeShadow:));
            no.identifier = [NSString stringWithFormat:@"%@|wrong", s[@"id"]];
            no.frame = NSMakeRect(contentW - 66, (rh - 23) / 2, 54, 23);
            [row addSubview:no];
            [doc addSubview:row];
            y += rh + 8;
        }

        // 실무급 — 형님이 아니라 에이전트의 일 (기본 접힘)
        if (workP.count) {
            if (self.showWorkItems) {
                for (NSDictionary *p in workP) pendRow(p, @"실무 — 파견 가능", nil, NO);
            }
            NSButton *wk = [NSButton buttonWithTitle:
                self.showWorkItems ? @"실무 대기 접기 ▾"
                    : [NSString stringWithFormat:@"실무 대기 %lu건 ▸ (구현·검증 — 대화에서 파견 지시 가능)",
                       workP.count]
                target:self action:@selector(toggleWorkItems:)];
            wk.bordered = NO;
            wk.controlSize = NSControlSizeSmall;
            wk.font = [NSFont systemFontOfSize:11.5];
            wk.contentTintColor = dim;
            wk.alignment = NSTextAlignmentLeft;
            wk.frame = NSMakeRect(pad, y, contentW, 24);
            [doc addSubview:wk];
            y += 30;
        }

        // 그 외 미결 — 기본 접힘
        if (rest.count) {
            if (self.showAllPendings) {
                for (NSDictionary *p in rest) pendRow(p, @"", nil, NO);
            }
            NSButton *toggle = [NSButton buttonWithTitle:
                self.showAllPendings ? @"접기 ▾"
                    : [NSString stringWithFormat:@"그 외 미결 %lu ▸", rest.count]
                target:self action:@selector(toggleAllPendings:)];
            toggle.bordered = NO;
            toggle.controlSize = NSControlSizeSmall;
            toggle.font = [NSFont systemFontOfSize:11.5];
            toggle.contentTintColor = dim;
            toggle.alignment = NSTextAlignmentLeft;
            toggle.frame = NSMakeRect(pad, y, 200, 24);
            [doc addSubview:toggle];
            y += 30;
        }
        y += 14;
    }

    // ═══ 그룹 3: 오늘 기록 — 1줄 요약, 펼치면 상세
    NSArray *decs = d[@"decisions"], *cors = d[@"corrections"], *wins = d[@"wins"];
    NSUInteger recTotal = decs.count + cors.count + wins.count;
    if (recTotal) {
        NSButton *rec = [NSButton buttonWithTitle:
            [NSString stringWithFormat:@"오늘 기록: 결정 %lu · 교정 %lu · 연승 %lu %@",
             decs.count, cors.count, wins.count, self.showRecords ? @"▾" : @"▸"]
            target:self action:@selector(toggleRecords:)];
        rec.bordered = NO;
        rec.controlSize = NSControlSizeSmall;
        rec.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
        rec.contentTintColor = dim;
        rec.alignment = NSTextAlignmentLeft;
        rec.frame = NSMakeRect(pad, y, contentW, 24);
        [doc addSubview:rec];
        y += 30;
        if (self.showRecords) {
            void (^recs)(NSArray *, NSString *, NSColor *) = ^(NSArray *items, NSString *bullet, NSColor *bc) {
                NSUInteger shown = MIN(items.count, 4u);
                for (NSUInteger i = 0; i < shown; i++) {
                    NSTextField *b = hudLabel(bullet, [NSFont systemFontOfSize:12.5], bc, 1, 16);
                    b.frame = NSMakeRect(pad, y, 16, b.frame.size.height);
                    [doc addSubview:b];
                    NSTextField *t = hudLabel(items[i][@"text"], [NSFont systemFontOfSize:12.5],
                        [NSColor colorWithCalibratedWhite:0.80 alpha:1], 2, contentW - 20);
                    t.frame = NSMakeRect(pad + 18, y, contentW - 20, t.frame.size.height);
                    [doc addSubview:t];
                    y += t.frame.size.height + 7;
                }
                if (items.count > shown) {
                    NSTextField *more = hudLabel([NSString stringWithFormat:@"외 %lu건", items.count - shown],
                                                 [NSFont systemFontOfSize:11], dim, 1, contentW);
                    more.frame = NSMakeRect(pad + 18, y, contentW, more.frame.size.height);
                    [doc addSubview:more];
                    y += more.frame.size.height + 7;
                }
            };
            recs(decs, @"·", dim);
            recs(cors, @"↺", accent);
            recs(wins, @"▲", [NSColor systemGreenColor]);
        }
        y += 8;
    }

    doc.frame = NSMakeRect(0, 0, W, y + 12);
    self.hudScroll.documentView = doc;
    if (self.lastQ.length)   // 문답 중엔 그 지점이 보이게
        [doc scrollPoint:NSMakePoint(0, MAX(0, y - self.hudScroll.frame.size.height + 24))];
}

- (void)buildChat {
    CGFloat W = self.hudScroll.frame.size.width;
    CGFloat pad = 22, contentW = W - pad * 2;   // 좌우 대칭 (스크롤바는 오토하이드)
    FlippedView *doc = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, W, 10)];
    __block CGFloat y = 14;
    NSColor *fg = [NSColor colorWithCalibratedWhite:0.94 alpha:1];
    NSColor *dim = [NSColor colorWithCalibratedWhite:0.52 alpha:1];
    NSColor *accent = [NSColor colorWithCalibratedRed:1.00 green:0.48 blue:0.10 alpha:1];
    NSDictionary *chat = self.hudData[@"chat"];

    // 세션 바: 현재 세션(플랫 버튼, 누르면 다크 메뉴) + 새 대화
    NSArray *sessions = [chat[@"sessions"] isKindOfClass:NSArray.class] ? chat[@"sessions"] : @[];
    NSMutableArray *ids = [NSMutableArray array];
    NSMutableArray *titles = [NSMutableArray array];
    NSString *cur = chat[@"session"] ?: @"";
    for (NSDictionary *s in sessions) {
        [ids addObject:s[@"id"] ?: @""];
        [titles addObject:s[@"title"] ?: @"대화"];
    }
    self.chatSessionIds = ids;
    self.chatSessionTitles = titles;
    self.chatCurrentSid = cur;
    NSString *curTitle = chat[@"title"] ?: @"새 대화";
    if (curTitle.length > 26) curTitle = [[curTitle substringToIndex:26] stringByAppendingString:@"…"];
    NSButton *sess = [NSButton buttonWithTitle:
        [NSString stringWithFormat:@"%@  ▾", curTitle] target:self action:@selector(showSessionMenu:)];
    sess.bordered = NO;
    sess.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    sess.contentTintColor = [NSColor colorWithCalibratedWhite:0.62 alpha:1];
    sess.alignment = NSTextAlignmentLeft;
    sess.frame = NSMakeRect(pad - 4, y, contentW - 84, 24);
    [doc addSubview:sess];
    NSButton *nb = flatBtn(@"새 대화", accent, self, @selector(chatNew:));
    nb.frame = NSMakeRect(pad + contentW - 72, y, 72, 24);
    [doc addSubview:nb];
    y += 34;

    // 말풍선 스레드
    NSArray *thread = [chat[@"thread"] isKindOfClass:NSArray.class] ? chat[@"thread"] : @[];
    void (^bubble)(NSString *, BOOL) = ^(NSString *text, BOOL mine) {
        if (!text.length) return;
        CGFloat maxW = contentW * 0.82;
        NSTextField *l = [NSTextField wrappingLabelWithString:@""];
        l.attributedStringValue = mdRender(text, 13,
            mine ? [NSColor colorWithCalibratedWhite:1.0 alpha:0.98] : fg);
        l.selectable = YES;                    // 링크 클릭·본문 복사 가능
        l.allowsEditingTextAttributes = YES;
        l.frame = NSMakeRect(0, 0, maxW - 28, 10);
        CGFloat lh = ceil([l.cell cellSizeForBounds:NSMakeRect(0, 0, maxW - 28, 20000)].height);
        // 풍선은 말한 만큼만: 셀 실측 폭 (여러 줄이면 자동으로 최대폭)
        CGFloat tw = MIN(maxW - 28, ceil([l.cell cellSizeForBounds:
            NSMakeRect(0, 0, maxW - 28, 20000)].width) + 2);
        l.frame = NSMakeRect(0, 0, tw, lh + 2);
        CGFloat bw = tw + 28;
        CGFloat bh = l.frame.size.height + 20;
        NSView *b = [[NSView alloc] initWithFrame:
            NSMakeRect(mine ? pad + contentW - bw : pad, y, bw, bh)];
        b.wantsLayer = YES;
        b.layer.cornerRadius = 13;
        b.layer.backgroundColor = mine
            ? [accent colorWithAlphaComponent:0.88].CGColor
            : [NSColor colorWithCalibratedWhite:1.0 alpha:0.08].CGColor;
        l.frame = NSMakeRect(14, 10, tw, l.frame.size.height);
        [b addSubview:l];
        [doc addSubview:b];
        y += bh + 7;
    };
    if (!thread.count && !self.asking) {
        NSTextField *empty = hudLabel(@"무엇이든 물어보십시오, 형님 — 기억·문서·일반 지식·작업 파견까지.",
                                      [NSFont systemFontOfSize:12], dim, 2, contentW);
        empty.frame = NSMakeRect(pad, y + 6, contentW, empty.frame.size.height);
        [doc addSubview:empty];
        y += empty.frame.size.height + 14;
    }
    NSView *lastAnswer = nil;
    for (NSDictionary *t in thread) {
        bubble(t[@"q"], YES);
        bubble(t[@"a"], NO);
        lastAnswer = doc.subviews.lastObject;
        if ([t[@"ts"] length]) {   // 문답 시각 — 답변 아래 작게
            NSTextField *tm = hudLabel(t[@"ts"], [NSFont systemFontOfSize:9.5],
                [NSColor colorWithCalibratedWhite:0.40 alpha:1], 1, 60);
            tm.frame = NSMakeRect(pad + 4, y - 3, 60, tm.frame.size.height);
            [doc addSubview:tm];
            y += tm.frame.size.height + 4;
        }
    }
    // 새 답변 도착 시 페이드인 (스레드가 늘었을 때만)
    if (!self.asking && (NSInteger)thread.count > self.lastThreadCount && lastAnswer) {
        lastAnswer.alphaValue = 0;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.3;
            lastAnswer.animator.alphaValue = 1;
        }];
    }
    self.lastThreadCount = (NSInteger)thread.count;
    if (self.asking) {
        bubble(self.lastQ, YES);
        NSString *st = [NSString stringWithContentsOfFile:
            [GariStateReader gariPath:@"store/ask-status.txt"]
            encoding:NSUTF8StringEncoding error:nil];
        st = [st stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!st.length) st = @"생각하는 중…";
        NSTextField *sl = hudLabel(st, [NSFont systemFontOfSize:12], dim, 2, contentW * 0.82 - 52);
        CGFloat sw = MIN(contentW * 0.82 - 52, ceil([sl.cell cellSizeForBounds:
            NSMakeRect(0, 0, contentW * 0.82 - 52, 200)].width) + 2);
        sl.frame = NSMakeRect(0, 0, sw, sl.frame.size.height);
        CGFloat bh = MAX(sl.frame.size.height + 20, 36);
        NSView *b = [[NSView alloc] initWithFrame:NSMakeRect(pad, y, sw + 54, bh)];
        b.wantsLayer = YES;
        b.layer.cornerRadius = 13;
        b.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.06].CGColor;
        NSProgressIndicator *sp = [[NSProgressIndicator alloc]
            initWithFrame:NSMakeRect(14, (bh - 14) / 2, 14, 14)];
        sp.style = NSProgressIndicatorStyleSpinning;
        sp.controlSize = NSControlSizeSmall;
        sp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
        [sp startAnimation:nil];
        [b addSubview:sp];
        sl.frame = NSMakeRect(38, (bh - sl.frame.size.height) / 2, sw, sl.frame.size.height);
        [b addSubview:sl];
        [doc addSubview:b];
        y += bh + 7;
    }

    doc.frame = NSMakeRect(0, 0, W, y + 12);
    NSView *oldDoc = self.hudScroll.documentView;
    CGFloat oldY = self.hudScroll.contentView.bounds.origin.y;
    CGFloat viewH = self.hudScroll.frame.size.height;
    BOOL nearBottom = !oldDoc
        || oldDoc.frame.size.height <= viewH
        || (oldDoc.frame.size.height - (oldY + viewH)) < 80;
    self.hudScroll.documentView = doc;
    if (nearBottom) {
        [doc scrollPoint:NSMakePoint(0, MAX(0, y + 12 - viewH))];   // 바닥 유지 (새 메시지 따라감)
    } else {
        [doc scrollPoint:NSMakePoint(0, MIN(oldY, MAX(0, y + 12 - viewH)))];  // 읽던 자리 보존
    }
}

- (void)showSessionMenu:(NSButton *)btn {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    for (NSUInteger i = 0; i < self.chatSessionIds.count; i++) {
        NSString *t = self.chatSessionTitles[i];
        if (t.length > 40) t = [[t substringToIndex:40] stringByAppendingString:@"…"];
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:t
            action:@selector(chatSessionMenuPicked:) keyEquivalent:@""];
        it.target = self;
        it.tag = (NSInteger)i;
        if ([self.chatSessionIds[i] isEqualToString:self.chatCurrentSid])
            it.state = NSControlStateValueOn;
        [menu addItem:it];
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *fresh = [[NSMenuItem alloc] initWithTitle:@"새 대화 시작"
        action:@selector(chatNew:) keyEquivalent:@""];
    fresh.target = self;
    [menu addItem:fresh];
    [menu popUpMenuPositioningItem:nil
        atLocation:NSMakePoint(0, btn.bounds.size.height + 4) inView:btn];
}

- (void)chatSessionMenuPicked:(NSMenuItem *)item {
    NSInteger i = item.tag;
    if (i < 0 || i >= (NSInteger)self.chatSessionIds.count) return;
    NSTask *t = [NSTask new];
    t.launchPath = [GariStateReader gariPath:@"bin/gari"];
    t.arguments = @[@"chat", @"use", self.chatSessionIds[i]];
    __weak typeof(self) weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf fetchHud]; });
    };
    @try { [t launch]; } @catch (NSException *ex) {}
}

- (void)chatNew:(id)sender {
    NSTask *t = [NSTask new];
    t.launchPath = [GariStateReader gariPath:@"bin/gari"];
    t.arguments = @[@"chat", @"new"];
    __weak typeof(self) weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf fetchHud]; });
    };
    @try { [t launch]; } @catch (NSException *ex) {}
}

- (void)openHud {
    // 읽음 처리 (현황판이 보고 내용을 담으므로 배지 해제 근거가 된다)
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd";
    [NSFileManager.defaultManager createFileAtPath:
        [GariStateReader gariPath:[NSString stringWithFormat:@"pet/seen-%@",
                                   [df stringFromDate:NSDate.date]]]
        contents:nil attributes:nil];

    CGFloat W = 400, H = 500;
    if (!self.hudWindow) {
        // 저장된 크기 복원 (드래그로 조절 가능, 끝나면 기억)
        NSData *sd = [NSData dataWithContentsOfFile:[GariStateReader gariPath:@"pet/hud-size.json"]];
        if (sd) {
            NSDictionary *sj = [NSJSONSerialization JSONObjectWithData:sd options:0 error:nil];
            if ([sj[@"w"] doubleValue] >= 380) W = [sj[@"w"] doubleValue];
            if ([sj[@"h"] doubleValue] >= 430) H = [sj[@"h"] doubleValue];
        }
        self.hudWindow = [[KeyableWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, W, H)
            styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable)
            backing:NSBackingStoreBuffered defer:NO];
        self.hudWindow.minSize = NSMakeSize(380, 430);
        self.hudWindow.movableByWindowBackground = YES;   // 빈 곳 드래그로 패널 이동
        self.hudWindow.maxSize = NSMakeSize(1000, NSScreen.mainScreen.visibleFrame.size.height);
        [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidEndLiveResizeNotification
            object:self.hudWindow queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            NSSize s = self.hudWindow.frame.size;
            NSDictionary *j = @{@"w": @(s.width), @"h": @(s.height)};
            [[NSJSONSerialization dataWithJSONObject:j options:0 error:nil]
                writeToFile:[GariStateReader gariPath:@"pet/hud-size.json"] atomically:YES];
            NSString *typed = self.hudInput.stringValue ?: @"";
            self.hudWindow.contentView = [self makeHudCard:s];   // 새 크기로 레이아웃 재구성
            [self buildHud];
            self.hudInput.stringValue = typed;
            [self.hudWindow makeFirstResponder:self.hudInput];
        }];
        self.hudWindow.opaque = NO;
        self.hudWindow.backgroundColor = NSColor.clearColor;
        self.hudWindow.level = NSFloatingWindowLevel;
        self.hudWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                                          | NSWindowCollectionBehaviorStationary
                                          | NSWindowCollectionBehaviorFullScreenAuxiliary;
        self.hudWindow.hasShadow = YES;
        self.hudWindow.contentView = [self makeHudCard:NSMakeSize(W, H)];
        // 팝오버 표준: 바깥 클릭 = 닫기
        [NSEvent addGlobalMonitorForEventsMatchingMask:
            NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown
            handler:^(NSEvent *ev) {
                if (self.hudWindow.isVisible) [self.hudWindow orderOut:nil];
            }];
    }

    // 위치: 펫 왼쪽 우선, 공간 없으면 오른쪽 — 화면 안으로 클램프
    NSRect pet = self.window.frame;
    NSRect screen = (self.window.screen ?: NSScreen.mainScreen).visibleFrame;
    CGFloat x = pet.origin.x - W - 12;
    if (x < NSMinX(screen)) x = NSMaxX(pet) + 12;
    if (x + W > NSMaxX(screen)) x = NSMaxX(screen) - W - 8;
    CGFloat y = MAX(NSMinY(screen) + 8, MIN(pet.origin.y, NSMaxY(screen) - H - 8));
    [self.hudWindow setFrameOrigin:NSMakePoint(x, y)];

    [self buildHud];
    // 소환 즉시 타이핑 가능 (Spotlight/Raycast 규약) — 형님이 의도적으로 연 것이므로 포커스 가져옴
    [NSApp activateIgnoringOtherApps:YES];
    [self.hudWindow makeKeyAndOrderFront:nil];
    [self.hudWindow makeFirstResponder:self.hudInput];
    [self fetchHud];
}

// 내용은 gari hud가 조립 (본체가 단일 진실 — 펫은 표시만)
- (void)fetchHud {
    NSTask *t = [NSTask new];
    t.launchPath = [GariStateReader gariPath:@"bin/gari"];
    t.arguments = @[@"hud", @"--json"];
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    __weak typeof(self) weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        NSData *d = [pipe.fileHandleForReading readDataToEndOfFile];
        NSDictionary *json = d.length
            ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.hudData = [json isKindOfClass:NSDictionary.class] ? json : nil;
            [weakSelf buildHud];
            [weakSelf refresh];
        });
    };
    @try { [t launch]; }
    @catch (NSException *ex) {
        self.hudData = nil;
        [self buildHud];
    }
}

// 그림자 채점 버튼 — gari grade <ID> right|wrong
- (void)gradeShadow:(NSButton *)btn {
    NSArray *parts = [btn.identifier componentsSeparatedByString:@"|"];
    if (parts.count != 2) return;
    btn.enabled = NO;
    NSTask *t = [NSTask new];
    t.launchPath = [GariStateReader gariPath:@"bin/gari"];
    t.arguments = @[@"grade", parts[0], parts[1]];
    __weak typeof(self) weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.happyUntil = [NSDate dateWithTimeIntervalSinceNow:1.2];  // 채점 감사 표시
            [weakSelf fetchHud];
        });
    };
    @try { [t launch]; }
    @catch (NSException *ex) { [self fetchHud]; }
}

- (void)toggleAllPendings:(id)s { self.showAllPendings = !self.showAllPendings; [self buildHud]; }
- (void)toggleRecords:(id)s { self.showRecords = !self.showRecords; [self buildHud]; }
- (void)toggleSuggestions:(id)s { self.showSuggestions = !self.showSuggestions; [self buildHud]; }
- (void)toggleWorkItems:(id)s { self.showWorkItems = !self.showWorkItems; [self buildHud]; }

- (void)compassRowTapped:(NSClickGestureRecognizer *)g {
    NSString *proj = g.view.identifier;
    if (!proj.length || self.asking) return;
    self.hudInput.stringValue = [NSString stringWithFormat:
        @"%@ 프로젝트 지금 방향이 어떻게 되고 있어? 다음에 뭘 정해야 해?", proj];
    [self hudAsk:nil];
}

- (void)pendingRowTapped:(NSClickGestureRecognizer *)g {
    NSString *pid = g.view.identifier;
    if (!pid.length || self.asking) return;
    self.hudInput.stringValue = [NSString stringWithFormat:
        @"미결 카드 %@ — 이게 무슨 맥락에서 나온 건지, 지금도 유효한지 알려줘", pid];
    [self hudAsk:nil];
}

- (void)snoozePending:(NSButton *)btn {
    if (!btn.identifier.length) return;
    btn.enabled = NO;
    NSTask *t = [NSTask new];
    t.launchPath = [GariStateReader gariPath:@"bin/gari"];
    t.arguments = @[@"snooze", btn.identifier];
    __weak typeof(self) weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf fetchHud]; });
    };
    @try { [t launch]; } @catch (NSException *ex) { btn.enabled = YES; }
}

// 미결 행의 "완료" 버튼 — gari resolve 실행 후 재조회
- (void)resolvePending:(NSButton *)btn {
    if (btn.identifier.length == 0) return;
    btn.enabled = NO;
    btn.title = @"…";
    NSTask *t = [NSTask new];
    t.launchPath = [GariStateReader gariPath:@"bin/gari"];
    t.arguments = @[@"resolve", btn.identifier];
    __weak typeof(self) weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf fetchHud]; });
    };
    @try { [t launch]; }
    @catch (NSException *ex) { [self fetchHud]; }
}

// 패널 질문창 제출 (Enter)
- (void)hudAsk:(id)sender {
    NSString *q = [self.hudInput.stringValue stringByTrimmingCharactersInSet:
                   NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (q.length == 0 || self.asking) return;
    self.lastQ = q;
    self.lastA = @"";
    self.asking = YES;
    self.hudMode = 1;   // 질문하면 대화 탭으로
    [self.askTimer invalidate];
    self.lastAskStatus = @"";
    self.askTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:YES block:^(NSTimer *t) {
        NSString *st = [NSString stringWithContentsOfFile:
            [GariStateReader gariPath:@"store/ask-status.txt"]
            encoding:NSUTF8StringEncoding error:nil] ?: @"";
        st = [st stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![st isEqualToString:self.lastAskStatus]) {
            self.lastAskStatus = st;
            if (self.asking && self.hudWindow.isVisible && self.hudMode == 1) [self buildChat];
        }
    }];
    self.hudInput.enabled = NO;
    self.hudInput.stringValue = @"";
    [self buildHud];

    NSTask *t = [NSTask new];
    t.launchPath = [GariStateReader gariPath:@"bin/gari"];
    t.arguments = @[@"ask", q];
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    t.standardError = pipe;
    __weak typeof(self) weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        NSData *d = [pipe.fileHandleForReading readDataToEndOfFile];
        NSString *out = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.asking = NO;
            [weakSelf.askTimer invalidate];
            weakSelf.askTimer = nil;
            weakSelf.lastQ = nil;   // 스레드(원장)가 이제 진실 — 낙관적 말풍선 제거
            weakSelf.hudInput.enabled = YES;
            weakSelf.happyUntil = [NSDate dateWithTimeIntervalSinceNow:1.5];
            weakSelf.hopV = 6.0;   // 답 가져왔어요 — 깡총
            [weakSelf fetchHud];
            [weakSelf.hudWindow makeFirstResponder:weakSelf.hudInput];
        });
    };
    @try { [t launch]; }
    @catch (NSException *ex) {
        self.asking = NO;
        self.lastA = @"창구 연결 실패 — ~/gari/bin/gari 확인 요망";
        self.hudInput.enabled = YES;
        [self buildHud];
    }
}

// 가리에게 묻기 — 패널 질문창에 포커스 (시스템 경고창 없음)
- (void)askGari {
    if (!(self.hudWindow && self.hudWindow.isVisible)) [self openHud];
    [NSApp activateIgnoringOtherApps:YES];
    [self.hudWindow makeKeyAndOrderFront:nil];
    [self.hudWindow makeFirstResponder:self.hudInput];
}

- (void)rightMouseDown:(NSEvent *)e {
    NSMenu *m = [[NSMenu alloc] init];
    [[m addItemWithTitle:@"현황판 (클릭)" action:@selector(toggleHud) keyEquivalent:@""] setTarget:self];
    [[m addItemWithTitle:@"가리에게 묻기…" action:@selector(askGari) keyEquivalent:@""] setTarget:self];
    [[m addItemWithTitle:@"보고 파일 열기" action:@selector(openReport) keyEquivalent:@""] setTarget:self];
    [[m addItemWithTitle:@"상태 확인 (gari status)" action:@selector(openStatus) keyEquivalent:@""] setTarget:self];
    [m addItem:[NSMenuItem separatorItem]];
    [[m addItemWithTitle:@"1시간 숨기기" action:@selector(hideAnHour) keyEquivalent:@""] setTarget:self];
    [m addItem:[NSMenuItem separatorItem]];
    [[m addItemWithTitle:@"가리 펫 종료 (본체는 계속 돎)" action:@selector(quit) keyEquivalent:@""] setTarget:self];
    [NSMenu popUpContextMenu:m withEvent:e forView:self];
}

- (void)openReport {
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd";
    NSString *today = [df stringFromDate:NSDate.date];
    [NSFileManager.defaultManager createFileAtPath:
        [GariStateReader gariPath:[NSString stringWithFormat:@"pet/seen-%@", today]]
        contents:nil attributes:nil];
    NSString *report = [GariStateReader gariPath:[NSString stringWithFormat:@"reports/%@.md", today]];
    if (![NSFileManager.defaultManager fileExistsAtPath:report]) {
        NSArray *mds = [[NSFileManager.defaultManager
            contentsOfDirectoryAtPath:[GariStateReader gariPath:@"reports"] error:nil]
            filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.md'"]];
        NSString *latest = [[mds sortedArrayUsingSelector:@selector(compare:)] lastObject];
        if (latest) report = [GariStateReader gariPath:[@"reports/" stringByAppendingString:latest]];
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:report]];
    [self refresh];
}

- (void)openStatus {
    NSString *cmd = [NSString stringWithFormat:@"%@ status > %@ 2>&1; open -e %@",
        [GariStateReader gariPath:@"bin/gari"],
        [GariStateReader gariPath:@"pet/status-snapshot.txt"],
        [GariStateReader gariPath:@"pet/status-snapshot.txt"]];
    NSTask *t = [NSTask new]; t.launchPath = @"/bin/sh"; t.arguments = @[@"-c", cmd];
    [t launch];
}

- (void)hideAnHour {
    [self.hudWindow orderOut:nil];
    [self.window orderOut:nil];
    // 데스크톱 펫 1위 불만 = 가림. 완전 종료 대신 한 시간 자리 비움.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3600 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.window orderFrontRegardless];
    });
}

- (void)quit { [NSApp terminate:nil]; }

- (void)refresh {
    GariMood m; int b;
    [GariStateReader read:&m badge:&b];
    if (m != self.mood) self.moodChangedAt = NSDate.date;
    self.mood = m; self.badge = b;
    if (self.asking && self.hudWindow.isVisible && self.hudMode == 1)
        [self buildChat];   // 진행 단계 문구 갱신
    self.needsDisplay = YES;
}
@end

// ---------------------------------------------------------------- 앱 조립

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@property (strong) PetView *view;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSSize size = NSMakeSize(150, 112);
    NSImage *sheet = nil;
    NSData *cd = [NSData dataWithContentsOfFile:[GariStateReader gariPath:@"pet/pet-config.json"]];
    if (cd) {
        NSDictionary *cj = [NSJSONSerialization JSONObjectWithData:cd options:0 error:nil];
        NSString *sp = cj[@"spritesheet"];
        if ([sp isKindOfClass:NSString.class] && sp.length > 0) {
            sheet = [[NSImage alloc] initWithContentsOfFile:sp.stringByExpandingTildeInPath];
            if (!sheet) NSLog(@"가리펫: 스프라이트시트 로드 실패 — 내장 픽셀로 대체: %@", sp);
        }
    }
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    NSPoint origin = NSMakePoint(NSMaxX(screen) - size.width - 40, NSMinY(screen) + 60);
    NSData *pd = [NSData dataWithContentsOfFile:[GariStateReader gariPath:@"pet/position.json"]];
    if (pd) {
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:pd options:0 error:nil];
        if (j[@"x"] && j[@"y"]) {
            NSPoint saved = NSMakePoint([j[@"x"] doubleValue], [j[@"y"] doubleValue]);
            // 저장 위치가 현재 화면 구성 안에 실제로 보이는지 검사 — 모니터가 빠지면 좌표가 화면 밖이 된다
            NSRect savedRect = NSMakeRect(saved.x, saved.y, size.width, size.height);
            for (NSScreen *s in NSScreen.screens) {
                if (NSIntersectsRect(savedRect, s.visibleFrame)) { origin = saved; break; }
            }
        }
    }
    self.window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(origin.x, origin.y, size.width, size.height)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    self.window.opaque = NO;
    self.window.backgroundColor = NSColor.clearColor;
    self.window.level = NSFloatingWindowLevel;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                                   | NSWindowCollectionBehaviorStationary
                                   | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.window.hasShadow = NO;
    self.window.acceptsMouseMovedEvents = YES;

    self.view = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    self.view.sheet = sheet;
    self.window.contentView = self.view;
    [self.window orderFrontRegardless];
    [self.view refresh];

    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSRect f = self.window.frame;
        for (NSScreen *s in NSScreen.screens)
            if (NSIntersectsRect(f, s.visibleFrame)) return;   // 아직 보임 — 그대로
        NSRect vis = NSScreen.mainScreen.visibleFrame;          // 화면 밖 — 주 화면 우하단으로 귀환
        [self.window setFrameOrigin:NSMakePoint(NSMaxX(vis) - f.size.width - 40, NSMinY(vis) + 60)];
        [self.window orderFrontRegardless];
    }];
    [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) { [self.view refresh]; }];
    [self chainTick];   // 적응형 틱 — 잘 때는 느리게 (상시 고빈도 웨이크업 회피)
}

- (void)chainTick {
    [NSTimer scheduledTimerWithTimeInterval:[self.view desiredTickInterval]
                                    repeats:NO block:^(NSTimer *t) {
        [self.view animTick];
        [self chainTick];
    }];
}
@end

// ---------------------------------------------------------------- 자가 스냅샷 (시각 검증용)

static void renderSnapshots(NSString *outDir) {
    [NSFileManager.defaultManager createDirectoryAtPath:outDir
        withIntermediateDirectories:YES attributes:nil error:nil];
    PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, 150, 112)];
    struct { GariMood m; int badge; BOOL happy; const char *name; } shots[] = {
        {MoodSleep, 0, NO,  "sleep"}, {MoodAwake, 3, NO, "awake-badge"},
        {MoodWork,  0, NO,  "work"},  {MoodAlert, 0, NO, "alert"},
        {MoodAwake, 0, YES, "petting"},
    };
    for (int i = 0; i < 5; i++) {
        v.mood = shots[i].m; v.badge = shots[i].badge;
        v.breathPhase = 1.0; v.tick = 4;
        if (shots[i].happy) {
            v.happyUntil = [NSDate dateWithTimeIntervalSinceNow:5];
            v.bubbleOverride = @"충성!";
            for (int k = 0; k < 4; k++) {
                Heart *h = [Heart new];
                h.x = 60 + k * 18; h.y = 95 + (k % 2) * 14; h.vy = 1; h.life = 0.9;
                [v.hearts addObject:h];
            }
        } else { v.happyUntil = nil; v.bubbleOverride = nil; [v.hearts removeAllObjects]; }
        NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
        [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:[outDir stringByAppendingFormat:@"/pet-%s.png", shots[i].name] atomically:YES];
    }
    // 패널 미리보기 (스타일 자가검증용 — 샘플 데이터)
    v.mood = MoodAwake; v.badge = 0; v.happyUntil = nil; v.bubbleOverride = nil;
    NSView *card = [v makeHudCard:NSMakeSize(400, 500)];
    v.hudData = @{
        @"time": @"12:10",
        @"pipeline": @{@"ok": @YES, @"age_min": @5, @"cards_today": @41},
        @"next_step": @{@"action": @"Brain-Clone 카테고리 축 확정 — 검색 문장 3개 입력",
                        @"reason": @"RAG MVP의 마지막 블로킹 아이템 — 이게 풀려야 기억 시스템이 완성 단계로"},
        @"question": @"검색 문장 3개, 지금 입력할까요 아니면 월요일에 모아서 할까요?",
        @"nag": @"펫 시안 반복이 5회째인데 '좋음의 기준'이 아직 없습니다 — 레퍼런스 1장 고정하고 시작하면 왕복이 줄어듭니다.",
        @"chat": @{@"session": @"9d89a816", @"title": @"펫 소리 논의",
                   @"sessions": @[@{@"id": @"9d89a816", @"title": @"펫 소리 논의"}],
                   @"thread": @[@{@"q": @"D+1 로그 확정이 무슨 내용이야?", @"a": @"Brain-Clone 메모리 시스템이 여러 세션에 자동 반영되는 구조와 관련된 미결입니다, 형님.\n\n상황: Claude-mem으로 만든 기억들(현재 404개)을 분류·연결하는 색인을 프로젝트 세션들에 자동 제공하고 있거든요. 어제 하루에 실행된 140개 세션이 이 색인을 제대로 받았는지를 서버 기록으로 확인해야 한다는 뜻입니다.\n\n왜 필요한가: 색인 주입 시스템이 실제로 작동하는지 검증하지 않으면, 지금까지 정리한 기억들이 실제 대화에서 쓰이지 못할 수도 있거든요.\n\n«참견 — 이 확인이 D+1 구간(어제 다음날)을 지정한 이유가 뭔가요? 어제/오늘의 로그로는 부족한 건가요, 아니면 시간차 효과를 재는 건가요?"},
                                @{@"q": @"그거 언제 정했지?", @"a": @"## 확정 시점\n**2026-07-05 밤**에 정하셨습니다.\n- 해소하려면 `gari resolve ab12cd34` 실행\n- 참고: https://gari.local/cards\n\n«참견 — 이 결정의 검증 계획이 아직 없습니다.", @"ts": @"22:40"}]},
        @"shadow": @[@{@"id": @"f1e9e032", @"text": @"같은 지시 반복 감지: 펫 크기 조정 요청 3회", @"quote": @""}],
        @"approvals": @[@"아침 보고 시각 확정 — 현재 09:00 (config.json report_hour)"],
        @"pendings": @[@{@"idx": @0, @"project": @"brain-clone", @"id": @"ab12cd34",
                         @"text": @"RAG 5레이어(Vector/Keyword/SQL/Graph/API) 우선순위 결정 필요"},
                       @{@"idx": @1, @"project": @"gari", @"id": @"ef56ab78",
                         @"text": @"펫 최종 미감 판정 대기"},
                       @{@"idx": @2, @"project": @"roadmap", @"id": @"cd90ef12",
                         @"text": @"화면 기록 권한 설정 — 사용자만 가능한 작업"}],
        @"freshness": @{@"sweep_interval_min": @10, @"report_hour": @9,
                         @"morning_ts": @"2026-07-06T09:00:12", @"triage_ts": @"2026-07-06T09:00:44"},
        @"compass": @[@{@"project": @"solo-game-launch", @"identity": @"사내 게임 대회 출품용 모바일 채굴 게임",
                        @"next": @"대회 공식 심사 기준·마감일 확인 — 유일한 외부 블로커", @"activity": @29},
                      @{@"project": @"review-board", @"identity": @"크리에이티브 리뷰·협업 보드 도구",
                        @"next": @"상품화 포지셔닝(Focal 재정리) 결정", @"activity": @10}],
        @"triage": @{@"ts": @"2026-07-06T09:00:44",
                     @"now": @{@"id": @"ab12cd34", @"why": @"RAG MVP 마지막 블로킹"},
                     @"done_like": @[@{@"id": @"ef56ab78", @"evidence": @"오늘 16:31 미감 확정 카드"}],
                     @"dupes": @[], @"snooze": @[]},
        @"decisions": @[@{@"project": @"roadmap", @"text": @"가리 펫은 가리발디 물고기 — 단색 + 눈만"},
                        @{@"project": @"roadmap", @"text": @"패널에 질문창 내장"}],
        @"corrections": @[@{@"text": @"가리 현황판 가독성 개선 — 판매 품질로"}],
        @"wins": @[@{@"text": @"사용성 체크리스트 10개 중 9.5 준수"}],
    };
    [v buildHud];   // 톱 상태 (문답 없음)
    NSBitmapImageRep *prep = [card bitmapImageRepForCachingDisplayInRect:card.bounds];
    [card cacheDisplayInRect:card.bounds toBitmapImageRep:prep];
    [[prep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[outDir stringByAppendingString:@"/panel-top.png"] atomically:YES];
    [v.hudScroll.documentView scrollPoint:NSMakePoint(0, 560)];
    NSBitmapImageRep *prep3 = [card bitmapImageRepForCachingDisplayInRect:card.bounds];
    [card cacheDisplayInRect:card.bounds toBitmapImageRep:prep3];
    [[prep3 representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[outDir stringByAppendingString:@"/panel-pendings.png"] atomically:YES];

    v.hudMode = 1;
    v.asking = YES;
    v.lastQ = @"north-star에서 판정 기준 6개가 뭐였지?";
    [v buildHud];   // 대화 탭 + 진행 중 상태
    NSBitmapImageRep *prep2 = [card bitmapImageRepForCachingDisplayInRect:card.bounds];
    [card cacheDisplayInRect:card.bounds toBitmapImageRep:prep2];
    [[prep2 representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[outDir stringByAppendingString:@"/panel-chat.png"] atomically:YES];
    printf("스냅샷 6장 저장: %s\n", outDir.UTF8String);
}

static void renderIcon(NSString *outPath) {
    PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, 150, 112)];
    v.mood = MoodAwake; v.badge = 0; v.breathPhase = 1.0; v.tick = 4;
    CGFloat S = 6.5;   // 물고기(약 65x50pt)가 512 캔버스를 꽉 채우게
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:512 pixelsHigh:512 bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = ctx;
    NSAffineTransform *tf = [NSAffineTransform transform];
    // 뷰가 아니라 '물고기'를 캔버스 중앙에: 물고기 중심 ≈ 뷰 좌표 (75, 45)
    [tf translateXBy:256 - 75 * S yBy:256 - 45 * S];
    [tf scaleBy:S];
    [tf concat];
    [v drawRect:v.bounds];
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:outPath atomically:YES];
    printf("아이콘 원판 저장: %s\n", outPath.UTF8String);
}

int main(int argc, const char *argv[]) {
    // 단일 인스턴스 잠금 — 어느 문(CLI·Gari.app·launchd)으로 열어도 펫은 한 마리
    // (앱 실행 시 시스템이 숨은 인자를 붙이므로 인자 유무가 아니라 "유틸리티 모드 여부"로 판정)
    BOOL utility = (argc >= 2 && (strcmp(argv[1], "--icon") == 0 ||
                                  strcmp(argv[1], "--snapshot") == 0));
    if (!utility) {
        NSString *lockPath = [GariStateReader gariPath:@"pet/instance.lock"];
        int lockFd = open(lockPath.UTF8String, O_CREAT | O_RDWR, 0644);
        if (lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0) {
            return 0;   // 이미 떠 있음(또는 잠금 불가) — 조용히 종료
        }
        // lockFd는 의도적으로 열어둔 채 유지 — 프로세스 종료 시 OS가 잠금 해제
    }
    @autoreleasepool {
        if (argc >= 3 && strcmp(argv[1], "--icon") == 0) {
            [NSApplication sharedApplication];
            renderIcon([NSString stringWithUTF8String:argv[2]]);
            return 0;
        }
        if (argc >= 3 && strcmp(argv[1], "--snapshot") == 0) {
            [NSApplication sharedApplication];
            renderSnapshots([NSString stringWithUTF8String:argv[2]]);
            return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
