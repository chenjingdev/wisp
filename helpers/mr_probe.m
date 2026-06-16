// MediaRemote "지금 재생 중인가" 동기 조회 헬퍼 (→ mr_probe.dylib).
//
// macOS 15.4+/26은 비공개 MediaRemote의 now-playing **읽기**를 번들 id가 `com.apple.*`인
// 프로세스에만 허용한다(`com.apple.mediaremote.now-playing-read-access` 게이트). 우리 앱은
// ad-hoc 서명·비특권이라 남의 미디어(Music/Spotify/브라우저) 재생 여부를 읽으면 조용히
// false/빈값으로 막힌다. 반면 `/usr/bin/perl`은 번들 id가 `com.apple.perl5`라 게이트를
// 통과한다 — 그 perl이 이 dylib을 DynaLoader로 로드해 **특권 컨텍스트에서** adapter_probe를
// 호출하면 정상값을 얻는다. (ungive/mediaremote-adapter 원리)
//
// 출력(stdout): "1"=재생 중, "0"=멈춤, "?"=불명. MediaController가 이 한 글자로 게이팅한다.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

__attribute__((visibility("default")))
void adapter_probe(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!h) { printf("?\n"); fflush(stdout); return; }

    // 등록은 now-playing 클라이언트를 활성화한다(알림 자체는 안 쓴다 — 일회성 조회).
    void (*reg)(dispatch_queue_t) = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (reg) reg(dispatch_get_main_queue());

    // 콜백은 ObjC 블록이고 파라미터는 BOOL(=Bool, ObjCBool 아님).
    void (*getIsPlaying)(dispatch_queue_t, void (^)(BOOL)) =
        dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    if (!getIsPlaying) { printf("?\n"); fflush(stdout); return; }

    // 콜백을 전역(동시) 큐로 받아 메인스레드 세마포어 대기와 데드락이 없게 한다.
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL res = NO, got = NO;
    getIsPlaying(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(BOOL playing) {
        res = playing; got = YES;
        dispatch_semaphore_signal(sem);
    });
    long timedOut = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)));
    printf("%s\n", (timedOut == 0 && got) ? (res ? "1" : "0") : "?");
    fflush(stdout);
}
