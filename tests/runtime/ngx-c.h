/* ngx-c.h: calling nvngx.dll from C, for the DLSS tests.
 *
 * A game talks to NGX through NVIDIA's SDK, whose parameter object is a C++ class with virtual
 * functions. These macros call the same functions through the object's table, in the order
 * nvngx.dll (DXMT's, built with llvm-mingw) lays them out, which is the order NVIDIA's SDK
 * expects. They work from x64 and from ARM64 programs. */
#ifndef NGX_C_H
#define NGX_C_H
#include <windows.h>

typedef struct NGXParams { void **vtbl; } NGXParams;
#define NGX_SET_POINTER(p, name, v)  ((void (*)(NGXParams *, const char *, void *))(p)->vtbl[0])(p, name, (void *)(v))
#define NGX_SET_D3D12(p, name, v)    ((void (*)(NGXParams *, const char *, void *))(p)->vtbl[1])(p, name, (void *)(v))
#define NGX_SET_INT(p, name, v)      ((void (*)(NGXParams *, const char *, int))(p)->vtbl[3])(p, name, v)
#define NGX_SET_UINT(p, name, v)     ((void (*)(NGXParams *, const char *, unsigned int))(p)->vtbl[4])(p, name, v)
#define NGX_SET_FLOAT(p, name, v)    ((void (*)(NGXParams *, const char *, float))(p)->vtbl[6])(p, name, v)
#define NGX_GET_UINT(p, name, out)   ((unsigned int (*)(NGXParams *, const char *, unsigned int *))(p)->vtbl[11])(p, name, out)

#define NGX_OK 1u
#define NGX_FEATURE_SUPER_SAMPLING 1u
#define NGX_FEATURE_FRAME_GENERATION 11u
#define NGX_DLSS_FLAG_MV_LOWRES 2

typedef unsigned int (*ngx_alloc_params_t)(NGXParams **);
typedef unsigned int (*ngx_create_t)(void *command_list, unsigned int feature, NGXParams *, unsigned int **handle);
typedef unsigned int (*ngx_evaluate_t)(void *command_list, const unsigned int *handle, NGXParams *, void *callback);
typedef unsigned int (*ngx_release_t)(unsigned int *handle);

#endif
