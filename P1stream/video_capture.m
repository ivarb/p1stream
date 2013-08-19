#include <stdio.h>
#include <assert.h>
#include <pthread.h>
#include <CoreVideo/CoreVideo.h>
#include <CoreMedia/CoreMedia.h>
#include <AVFoundation/AVFoundation.h>

#include "video.h"

// Source state.
typedef struct _P1VideoCaptureSource P1VideoCaptureSource;

struct _P1VideoCaptureSource {
    P1VideoSource super;

    CVPixelBufferRef frame;
    pthread_mutex_t frame_lock;

    CFTypeRef delegate;
    CFTypeRef session;
};

// Delegate class we use internally for the capture session.
@interface P1VideoCaptureDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    P1VideoCaptureSource *source;
}

- (id)initWithSource:(P1VideoCaptureSource *)_source;

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection;

- (void)handleError:(NSNotification *)obj;

@end

// Plugin definition.
static P1VideoSource *p1_video_capture_create();
static void p1_video_capture_free(P1VideoSource *_source);
static bool p1_video_capture_start(P1VideoSource *_source);
static void p1_video_capture_frame(P1VideoSource *_source);
static void p1_video_capture_stop(P1VideoSource *_source);

P1VideoPlugin p1_video_capture = {
    .create = p1_video_capture_create,
    .free = p1_video_capture_free,

    .start = p1_video_capture_start,
    .frame = p1_video_capture_frame,
    .stop = p1_video_capture_stop
};


static P1VideoSource *p1_video_capture_create()
{
    P1VideoCaptureSource *source = calloc(1, sizeof(P1VideoCaptureSource));
    assert(source != NULL);

    P1VideoSource *_source = (P1VideoSource *) source;
    _source->plugin = &p1_video_capture;

    pthread_mutex_init(&source->frame_lock, NULL);

    @autoreleasepool {
        P1VideoCaptureDelegate *delegate = [[P1VideoCaptureDelegate alloc] initWithSource:source];

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
        source->delegate = CFBridgingRetain(delegate);
        source->session = CFBridgingRetain(session);
    }

    return _source;
}

static void p1_video_capture_free(P1VideoSource *_source)
{
    P1VideoCaptureSource *source = (P1VideoCaptureSource *) _source;

    CFRelease(source->session);
    CFRelease(source->delegate);

    pthread_mutex_destroy(&source->frame_lock);
}

static bool p1_video_capture_start(P1VideoSource *_source)
{
    P1VideoCaptureSource *source = (P1VideoCaptureSource *) _source;

    @autoreleasepool {
        AVCaptureSession *session = (__bridge AVCaptureSession *)source->session;
        [session startRunning];
    }

    return true;
}

static void p1_video_capture_frame(P1VideoSource *_source)
{
    P1VideoCaptureSource *source = (P1VideoCaptureSource *) _source;
    CVPixelBufferRef frame;

    pthread_mutex_lock(&source->frame_lock);
    frame = source->frame;
    if (frame)
        CFRetain(frame);
    pthread_mutex_unlock(&source->frame_lock);

    if (!frame)
        return;

    IOSurfaceRef surface = CVPixelBufferGetIOSurface(frame);
    if (surface != NULL) {
        p1_video_frame_iosurface(_source, surface);
    }
    else {
        CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        int width = (int) CVPixelBufferGetWidth(frame);
        int height = (int) CVPixelBufferGetHeight(frame);
        void *data = CVPixelBufferGetBaseAddress(frame);
        p1_video_frame_raw(_source, width, height, data);
        CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
    }

    CFRelease(frame);
}

static void p1_video_capture_stop(P1VideoSource *_source)
{
    P1VideoCaptureSource *source = (P1VideoCaptureSource *) _source;

    @autoreleasepool {
        AVCaptureSession *session = (__bridge AVCaptureSession *)source->session;
        [session stopRunning];
    }
}

@implementation P1VideoCaptureDelegate

- (id)initWithSource:(P1VideoCaptureSource *)_source
{
    self = [super init];
    if (self) {
        source = _source;
    }
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    // Get the image data.
    CVPixelBufferRef frame = CMSampleBufferGetImageBuffer(sampleBuffer);
    assert(frame != NULL);
    CFRetain(frame);

    CVPixelBufferRef old_frame;

    pthread_mutex_lock(&source->frame_lock);
    old_frame = source->frame;
    source->frame = frame;
    pthread_mutex_unlock(&source->frame_lock);

    if (old_frame)
        CFRelease(old_frame);
}

- (void)handleError:(NSNotification *)obj
{
    NSLog(@"%@\n", obj.userInfo);
    assert(0);
}

@end
