#include "p1stream.h"

#include <CoreVideo/CoreVideo.h>


typedef struct _P1DisplayVideoClock P1DisplayVideoClock;

struct _P1DisplayVideoClock {
    P1VideoClock super;

    CGDirectDisplayID cfg_display_id;
    int cfg_divisor;

    CGDirectDisplayID display_id;
    int divisor;

    CVDisplayLinkRef display_link;
    int skip_counter;
};

static bool p1_display_video_clock_init(P1DisplayVideoClock *dvclock, P1Context *ctx);
static void p1_display_video_clock_config(P1Plugin *pel, P1Config *cfg);
static void p1_display_video_clock_start(P1Plugin *pel);
static void p1_display_video_clock_stop(P1Plugin *pel);
static void p1_display_video_clock_kill_session(P1DisplayVideoClock *dvclock);
static CVReturn p1_display_video_clock_callback(
    CVDisplayLinkRef displayLink,
    const CVTimeStamp *inNow,
    const CVTimeStamp *inOutputTime,
    CVOptionFlags flagsIn,
    CVOptionFlags *flagsOut,
    void *displayLinkContext);


P1VideoClock *p1_display_video_clock_create(P1Context *ctx)
{
    P1DisplayVideoClock *dvclock = calloc(1, sizeof(P1DisplayVideoClock));

    if (dvclock) {
        if (!p1_display_video_clock_init(dvclock, ctx)) {
            free(dvclock);
            dvclock = NULL;
        }
    }

    return (P1VideoClock *) dvclock;
}

static bool p1_display_video_clock_init(P1DisplayVideoClock *dvclock, P1Context *ctx)
{
    P1VideoClock *vclock = (P1VideoClock *) dvclock;
    P1Plugin *pel = (P1Plugin *) dvclock;

    if (!p1_video_clock_init(vclock, ctx))
        return false;

    pel->config = p1_display_video_clock_config;
    pel->start = p1_display_video_clock_start;
    pel->stop = p1_display_video_clock_stop;

    return true;
}

static void p1_display_video_clock_config(P1Plugin *pel, P1Config *cfg)
{
    P1DisplayVideoClock *dvclock = (P1DisplayVideoClock *) pel;
    P1Object *obj = (P1Object *) pel;

    if (!cfg->get_uint32(cfg, "display", &dvclock->cfg_display_id))
        dvclock->cfg_display_id = kCGDirectMainDisplay;
    if (!cfg->get_int(cfg, "divisor", &dvclock->cfg_divisor))
        dvclock->cfg_divisor = 1;

    if (dvclock->cfg_display_id != dvclock->display_id ||
        dvclock->cfg_divisor != dvclock->divisor)
        p1_object_set_flag(obj, P1_FLAG_NEEDS_RESTART);
}

static void p1_display_video_clock_start(P1Plugin *pel)
{
    P1Object *obj = (P1Object *) pel;
    P1DisplayVideoClock *dvclock = (P1DisplayVideoClock *) pel;
    CVReturn ret;

    dvclock->display_id = dvclock->cfg_display_id;
    dvclock->divisor = dvclock->cfg_divisor;
    dvclock->skip_counter = 0;

    ret = CVDisplayLinkCreateWithCGDisplay(dvclock->display_id, &dvclock->display_link);
    if (ret != kCVReturnSuccess)
        goto halt;

    ret = CVDisplayLinkSetOutputCallback(dvclock->display_link, p1_display_video_clock_callback, dvclock);
    if (ret != kCVReturnSuccess)
        goto halt;

    // Async, final state change happens in the callback.
    ret = CVDisplayLinkStart(dvclock->display_link);
    if (ret != kCVReturnSuccess)
        goto halt;

    obj->state.current = P1_STATE_STARTING;
    p1_object_notify(obj);

    return;

halt:
    p1_log(obj, P1_LOG_ERROR, "Failed to start display link: Core Video error %d", ret);

    p1_display_video_clock_kill_session(dvclock);

    obj->state.current = P1_STATE_IDLE;
    obj->state.flags |= P1_FLAG_ERROR;
    p1_object_notify(obj);
}

static void p1_display_video_clock_stop(P1Plugin *pel)
{
    P1Object *obj = (P1Object *) pel;

    // Just set to stopping, the thread will do the rest.
    obj->state.current = P1_STATE_STOPPING;
    p1_object_notify(obj);
}

static void p1_display_video_clock_kill_session(P1DisplayVideoClock *dvclock)
{
    if (dvclock->display_link) {
        CFRelease(dvclock->display_link);
        dvclock->display_link = NULL;
    }
}

static CVReturn p1_display_video_clock_callback(
    CVDisplayLinkRef displayLink,
    const CVTimeStamp *inNow,
    const CVTimeStamp *inOutputTime,
    CVOptionFlags flagsIn,
    CVOptionFlags *flagsOut,
    void *displayLinkContext)
{
    P1DisplayVideoClock *dvclock = (P1DisplayVideoClock *) displayLinkContext;
    P1VideoClock *vclock = (P1VideoClock *) displayLinkContext;
    P1Object *obj = (P1Object *) displayLinkContext;
    CVReturn ret;

    p1_object_lock(obj);

    if (obj->state.current == P1_STATE_STOPPING) {
        ret = CVDisplayLinkStop(dvclock->display_link);
        if (ret != kCVReturnSuccess) {
            p1_log(obj, P1_LOG_ERROR, "Failed to stop display link: Core Video error %d", ret);
            obj->state.flags |= P1_FLAG_ERROR;
        }
        p1_display_video_clock_kill_session(dvclock);

        obj->state.current = P1_STATE_IDLE;
        p1_object_notify(obj);

        goto end;
    }

    if (obj->state.current == P1_STATE_STARTING) {
        // Get the display refresh period.
        double period = CVDisplayLinkGetActualOutputVideoRefreshPeriod(dvclock->display_link);
        if (period == 0.0)
            goto end;

        // Set the frame rate based on this and the divisor.
        vclock->fps_num = (uint32_t) round(1.0 / period);
        vclock->fps_den = dvclock->divisor;

        // Report running.
        obj->state.current = P1_STATE_RUNNING;
        p1_object_notify(obj);
    }

    if (obj->state.current == P1_STATE_RUNNING) {
        // Skip tick based on divisor.
        if (dvclock->skip_counter >= dvclock->divisor)
            dvclock->skip_counter = 0;
        if (dvclock->skip_counter++ != 0)
            goto end;

        p1_object_unlock(obj);
        p1_video_clock_tick(vclock, inNow->hostTime);
        return kCVReturnSuccess;
    }

end:
    p1_object_unlock(obj);

    return kCVReturnSuccess;
}
