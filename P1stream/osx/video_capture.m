#include "p1stream.h"

#define GL_DO_NOT_WARN_IF_MULTI_GL_VERSION_HEADERS_INCLUDED

#include <assert.h>
#include <pthread.h>
#include <CoreVideo/CoreVideo.h>
#include <CoreMedia/CoreMedia.h>
#include <AVFoundation/AVFoundation.h>

// Source state.
typedef struct _P1CaptureVideoSource P1CaptureVideoSource;

struct _P1CaptureVideoSource {
    P1VideoSource super;

    CFTypeRef delegate;
    CFTypeRef session;

    CVPixelBufferRef frame;
};

// Delegate class we use internally for the capture session.
@interface P1VideoCaptureDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    P1CaptureVideoSource *cvsrc;
}

- (id)initWithSource:(P1CaptureVideoSource *)_source;

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection;

- (void)handleError:(NSNotification *)obj;

@end

// Plugin definition.
static bool p1_capture_video_source_start(P1PluginElement *pel);
static void p1_capture_video_source_stop(P1PluginElement *pel);
static void p1_capture_video_source_frame(P1VideoSource *vsrc);


P1VideoSource *p1_capture_video_source_create(P1Config *cfg, P1ConfigSection *sect)
{
    P1CaptureVideoSource *cvsrc = calloc(1, sizeof(P1CaptureVideoSource));
    P1VideoSource *vsrc = (P1VideoSource *) cvsrc;
    P1PluginElement *pel = (P1PluginElement *) cvsrc;
    assert(cvsrc != NULL);

    p1_video_source_init(vsrc, cfg, sect);

    pel->start = p1_capture_video_source_start;
    pel->stop = p1_capture_video_source_stop;
    vsrc->frame = p1_capture_video_source_frame;

    return vsrc;
}

static bool p1_capture_video_source_start(P1PluginElement *pel)
{
    P1Element *el = (P1Element *) pel;
    P1CaptureVideoSource *cvsrc = (P1CaptureVideoSource *) pel;

    @autoreleasepool {
        P1VideoCaptureDelegate *delegate = [[P1VideoCaptureDelegate alloc] initWithSource:cvsrc];

        // Create a capture session, listen for errors.
        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:delegate
                                                 selector:@selector(handleError:)
                                                     name:@"AVCaptureSessionRuntimeErrorNotification"
                                                   object:session];

        // Open the default video capture device.
        NSError *error;
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        assert(input && [session canAddInput:input]);
        [session addInput:input];

        // Create a video data output.
        dispatch_queue_t dispatch = dispatch_queue_create("video_capture", DISPATCH_QUEUE_SERIAL);
        AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
        [output setSampleBufferDelegate:delegate queue:dispatch];
        output.videoSettings = @{
            (NSString *) kCVPixelBufferPixelFormatTypeKey: [NSNumber numberWithInt:kCVPixelFormatType_32BGRA]
        };
        assert([session canAddOutput:output]);
        [session addOutput:output];

        // Retain session in state.
        cvsrc->delegate = CFBridgingRetain(delegate);
        cvsrc->session = CFBridgingRetain(session);

        // Start. This is sync, unfortunately.
        [session startRunning];
    }

    p1_element_set_state(el, P1_OTYPE_VIDEO_SOURCE, P1_STATE_RUNNING);

    return true;
}

static void p1_capture_video_source_stop(P1PluginElement *pel)
{
    P1Element *el = (P1Element *) pel;
    P1CaptureVideoSource *cvsrc = (P1CaptureVideoSource *) pel;

    @autoreleasepool {
        AVCaptureSession *session = (__bridge AVCaptureSession *) cvsrc->session;

        // Stop. This is sync, unfortunately.
        [session stopRunning];

        // Release references.
        CFRelease(cvsrc->session);
        CFRelease(cvsrc->delegate);
    }

    p1_element_set_state(el, P1_OTYPE_VIDEO_SOURCE, P1_STATE_IDLE);
}

static void p1_capture_video_source_frame(P1VideoSource *vsrc)
{
    P1CaptureVideoSource *cvsrc = (P1CaptureVideoSource *) vsrc;
    CVPixelBufferRef frame;

    frame = cvsrc->frame;
    if (frame) {
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(frame);
        if (surface != NULL) {
            p1_video_source_frame_iosurface(vsrc, surface);
        }
        else {
            CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
            int width = (int) CVPixelBufferGetWidth(frame);
            int height = (int) CVPixelBufferGetHeight(frame);
            void *data = CVPixelBufferGetBaseAddress(frame);
            p1_video_source_frame(vsrc, width, height, data);
            CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        }
    }
}

@implementation P1VideoCaptureDelegate

- (id)initWithSource:(P1CaptureVideoSource *)_cvsrc
{
    self = [super init];
    if (self) {
        cvsrc = _cvsrc;
    }
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    P1Element *el = (P1Element *) cvsrc;

    p1_element_lock(el);

    if (cvsrc->frame)
        CFRelease(cvsrc->frame);

    CVPixelBufferRef frame = CMSampleBufferGetImageBuffer(sampleBuffer);
    assert(frame != NULL);

    CFRetain(frame);
    cvsrc->frame = frame;

    p1_element_unlock(el);
}

- (void)handleError:(NSNotification *)obj
{
    NSLog(@"%@\n", obj.userInfo);
    assert(0);
}

@end
