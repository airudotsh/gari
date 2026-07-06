// dump-pixels — PNG의 픽셀을 텍스트로 덤프 (스프라이트 → 가리 격자 이식용)
// 빌드: clang -fobjc-arc -framework Cocoa -O2 -o dump-pixels dump-pixels.m
// 사용: ./dump-pixels sprite.png [--crop x y w h]
// 출력: 1행 = "W H", 이후 각 픽셀 "RRGGBBAA" (행 우선, 공백 구분)
#import <Cocoa/Cocoa.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: dump-pixels file.png [--crop x y w h]\n"); return 1; }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) { fprintf(stderr, "읽기 실패: %s\n", argv[1]); return 1; }
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:data];
        if (!rep) { fprintf(stderr, "비트맵 해석 실패\n"); return 1; }
        NSInteger x0 = 0, y0 = 0, w = rep.pixelsWide, h = rep.pixelsHigh;
        if (argc == 7 && strcmp(argv[2], "--crop") == 0) {
            x0 = atoi(argv[3]); y0 = atoi(argv[4]);
            w = atoi(argv[5]); h = atoi(argv[6]);
        }
        printf("%ld %ld\n", (long)w, (long)h);
        for (NSInteger y = y0; y < y0 + h; y++) {
            for (NSInteger x = x0; x < x0 + w; x++) {
                NSColor *c = [rep colorAtX:x y:y];
                c = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                printf("%02X%02X%02X%02X ",
                       (int)(c.redComponent * 255), (int)(c.greenComponent * 255),
                       (int)(c.blueComponent * 255), (int)(c.alphaComponent * 255));
            }
            printf("\n");
        }
    }
    return 0;
}
