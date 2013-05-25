#include <gst/base/gstbasetransform.h>
#import "P1GLContext.h"


#define GST_QUERY_GL_CONTEXT GST_QUERY_MAKE_TYPE(251, GST_QUERY_TYPE_DOWNSTREAM)

void p1_utils_static_init();

GstQuery *gst_query_new_gl_context();
P1GLContext *gst_query_get_gl_context(GstQuery *query);
gboolean gst_query_set_gl_context(GstQuery *query, P1GLContext *context);

GLuint p1_build_shader(GLuint type, NSString *resource, NSString *ext);
void p1_build_shader_program(GLuint program, NSString *resource);

gboolean p1_decide_texture_allocation(GstQuery *query);
