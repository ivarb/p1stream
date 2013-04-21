#import "P1Preview.h"
#import "P1TextureMeta.h"
#import "P1TexturePool.h"


G_DEFINE_TYPE(P1PreviewSink, p1_preview_sink, GST_TYPE_VIDEO_SINK)
static GstVideoSinkClass *parent_class = NULL;

static GstStateChangeReturn p1_preview_sink_change_state(GstElement *element, GstStateChange transition);
static gboolean p1_preview_sink_propose_allocation(GstBaseSink *sink, GstQuery *query);
static gboolean p1_preview_sink_set_caps(GstBaseSink *sink, GstCaps *caps);
static GstFlowReturn p1_preview_sink_show_frame(GstVideoSink *video_sink, GstBuffer *buf);

static GstStaticPadTemplate sink_template = GST_STATIC_PAD_TEMPLATE(
    "sink", GST_PAD_SINK, GST_PAD_ALWAYS, GST_STATIC_CAPS(
        "video/x-gl-texture, "
            "width = (int) [ 1, max ], "
            "height = (int) [ 1, max ]"
    )
);


static void p1_preview_sink_class_init(P1PreviewSinkClass *klass)
{
    parent_class = g_type_class_ref(GST_TYPE_VIDEO_SINK);

    GstVideoSinkClass *videosink_class = GST_VIDEO_SINK_CLASS(klass);
    videosink_class->show_frame = p1_preview_sink_show_frame;

    GstBaseSinkClass *basesink_class = GST_BASE_SINK_CLASS(klass);
    basesink_class->propose_allocation = p1_preview_sink_propose_allocation;
    basesink_class->set_caps           = p1_preview_sink_set_caps;

    GstElementClass *element_class = GST_ELEMENT_CLASS(klass);
    element_class->change_state = p1_preview_sink_change_state;
    gst_element_class_add_pad_template(element_class, gst_static_pad_template_get(&sink_template));
    gst_element_class_set_static_metadata(element_class, "P1stream preview sink",
                                           "Sink/Video",
                                           "The P1stream video preview",
                                           "Stéphan Kochen <stephan@kochen.nl>");
}

static void p1_preview_sink_init(P1PreviewSink *self)
{
    self->viewRef = NULL;
}

static gboolean p1_preview_sink_propose_allocation(GstBaseSink *basesink, GstQuery *query)
{
    P1PreviewSink *self = P1_PREVIEW_SINK(basesink);
    P1Preview *view = (__bridge P1Preview *)self->viewRef;

    P1GLContext *context = p1_gl_context_new_existing(view.CGLContextObj);
    g_return_val_if_fail(context != NULL, FALSE);

    P1TexturePool *pool = p1_texture_pool_new(context);
    g_object_unref(context);
    g_return_val_if_fail(pool != NULL, FALSE);

    gst_query_add_allocation_pool(query, GST_BUFFER_POOL(pool), 1, 2, 2);
    gst_object_unref(pool);

    return TRUE;
}

static GstFlowReturn p1_preview_sink_show_frame(GstVideoSink *videosink, GstBuffer *buf)
{
    P1PreviewSink *self = P1_PREVIEW_SINK(videosink);
    P1Preview *view = (__bridge P1Preview *)self->viewRef;

    view.buffer = buf;

    return GST_FLOW_OK;
}

static gboolean p1_preview_sink_set_caps(GstBaseSink *basesink, GstCaps *caps)
{
    P1PreviewSink *self = P1_PREVIEW_SINK(basesink);
    P1Preview *view = (__bridge P1Preview *)self->viewRef;

    gint width, height;
    GstStructure *structure = gst_caps_get_structure(caps, 0);
    if (!gst_structure_get_int(structure, "width",  &width))
        return FALSE;
    if (!gst_structure_get_int(structure, "height", &height))
        return FALSE;
    view.aspect = (CGFloat)width / (CGFloat)height;

    dispatch_sync(dispatch_get_main_queue(), ^{
        [view updateVideoConstraint];
    });

    return TRUE;
}

static GstStateChangeReturn p1_preview_sink_change_state(GstElement *element, GstStateChange transition)
{
    GstStateChangeReturn res;
    P1PreviewSink *self = P1_PREVIEW_SINK(element);
    P1Preview *view = (__bridge P1Preview *)self->viewRef;

    switch (transition) {
        case GST_STATE_CHANGE_NULL_TO_READY:
            // Ref our parent view while we're active.
            g_assert(self->viewRef != NULL);
            CFRetain(self->viewRef);
            break;
        default:
            break;
    }

    res = GST_ELEMENT_CLASS(parent_class)->change_state(element, transition);
    if (res == GST_STATE_CHANGE_FAILURE)
        return res;

    switch (transition) {
        case GST_STATE_CHANGE_PAUSED_TO_READY:
            view.buffer = NULL;
            [view performSelectorOnMainThread:@selector(clearVideoConstraint)
                                   withObject:nil
                                waitUntilDone:TRUE];
            break;
        case GST_STATE_CHANGE_READY_TO_NULL:
            CFRelease(self->viewRef);
            break;
        default:
            break;
    }

    return res;
}


@implementation P1Preview

@synthesize element, aspect;

// VBO data for a square with texture coordinates flipped.
static const GLfloat vboData[4 * 4] = {
    -1, -1, 0, 0,
    -1, +1, 0, 1,
    +1, -1, 1, 0,
    +1, +1, 1, 1
};
const GLsizei vboSize = sizeof(vboData);
const GLsizei vboStride = 4 * sizeof(GLfloat);
const void *vboTexCoordsOffset = (void *)(2 * sizeof(GLfloat));

- (id)initWithFrame:(NSRect)frameRect
{
    // Set up context with 3.2 core profile.
    NSOpenGLPixelFormat *pixelFormat;
    NSOpenGLPixelFormatAttribute attrs[] = {
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
        0
    };
    pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];

    // Chain up.
    self = [super initWithFrame:frameRect pixelFormat:pixelFormat];
    if (self) {
        // Create the GStreamer element.
        element = g_object_new(P1_TYPE_PREVIEW_SINK, NULL);
        g_assert(element != NULL);
        element->viewRef = (__bridge CFTypeRef)self;

        // Start context init.
        NSOpenGLContext *context = self.openGLContext;
        [context makeCurrentContext];

        // Black background.
        glClearColor(0, 0, 0, 1);

        // VBO and VAO for all drawing area vertex coordinates.
        glGenVertexArrays(1, &vertexArrayName);
        glGenBuffers(1, &vertexBufferName);
        glBindBuffer(GL_ARRAY_BUFFER, vertexBufferName);
        glBufferData(GL_ARRAY_BUFFER, vboSize, vboData, GL_STATIC_DRAW);

        // Dirt simple shader.
        shaderProgram = glCreateProgram();
        glBindAttribLocation(shaderProgram, 0, "a_Position");
        glBindAttribLocation(shaderProgram, 1, "a_TexCoords");
        glBindFragDataLocation(shaderProgram, 0, "o_FragColor");
        buildShaderProgram(shaderProgram, @"simple");
        textureUniform = glGetUniformLocation(shaderProgram, "u_Texture");

        g_assert(glGetError() == GL_NO_ERROR);
    }
    return self;
}

- (void)dealloc
{
    if (element) {
        element->viewRef = NULL;
        gst_object_unref(element);
    }
}

- (CGLContextObj)CGLContextObj
{
    @synchronized(self) {
        return self.openGLContext.CGLContextObj;
    }
}

- (void)updateVideoConstraint
{
    [self clearVideoConstraint];
    videoConstraint = [NSLayoutConstraint constraintWithItem:self
                                                   attribute:NSLayoutAttributeWidth
                                                   relatedBy:NSLayoutRelationEqual
                                                      toItem:self
                                                   attribute:NSLayoutAttributeHeight
                                                  multiplier:aspect
                                                    constant:0];
    [self addConstraint:videoConstraint];
}

- (void)clearVideoConstraint
{
    if (videoConstraint) {
        [self removeConstraint:videoConstraint];
        videoConstraint = nil;
    }
}

- (void)setBuffer:(GstBuffer *)buffer
{
    @synchronized(self) {
        if (currentBuffer)
            gst_buffer_unref(currentBuffer);

        if (buffer)
            currentBuffer = gst_buffer_ref(buffer);
        else
            currentBuffer = NULL;

        [self lockFocus];
        [self.openGLContext makeCurrentContext];
        [self drawBuffer];
        [self unlockFocus];
    }
}

- (BOOL)isOpaque
{
    return TRUE;
}

- (void)drawRect:(NSRect)dirtyRect
{
    [self drawBuffer];
}

- (void)drawBuffer
{
    CGLError err;

    CGLContextObj context = self.openGLContext.CGLContextObj;
    err = CGLLockContext(context);
    assert(err == kCGLNoError);
    glClear(GL_COLOR_BUFFER_BIT);

    GstBuffer *buf = self->currentBuffer;
    if (buf != NULL) {
        P1TextureMeta *texture = gst_buffer_get_texture_meta(buf);
        g_assert(p1_gl_context_get_raw(texture->context) == context);

        const NSRect bounds = self.bounds;
        glViewport(bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height);

        glUseProgram(shaderProgram);

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_RECTANGLE, texture->name);
        glUniform1i(textureUniform, 0);

        glBindVertexArray(vertexArrayName);
        glBindBuffer(GL_ARRAY_BUFFER, vertexBufferName);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, vboStride, 0);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, vboStride, vboTexCoordsOffset);
        glEnableVertexAttribArray(0);
        glEnableVertexAttribArray(1);

        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

        glDisableVertexAttribArray(0);
        glDisableVertexAttribArray(1);
    }

    glFlush();
    err = CGLUnlockContext(context);
    assert(err == kCGLNoError);
}

@end
