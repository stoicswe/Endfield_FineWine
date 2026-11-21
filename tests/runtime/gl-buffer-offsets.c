/* gl-buffer-offsets.c: OpenGL arguments that are an address in the program's memory, or an
 * offset into the bound buffer object. Draws one quad with vertices and indices that sit more
 * than 64 KB into their buffers (glVertexPointer and glDrawElements with offsets), one from
 * the program's own memory (the same calls with addresses), and reads pixels back both into
 * memory and into a pixel buffer at an offset. In a 32-bit program on FineWine's runtime an
 * address gets the base of the program's memory window and an offset must not.
 * Nothing is shown. Prints "gl-buffer-offsets: ok" on success. */
#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>

#define GL_ARRAY_BUFFER 0x8892
#define GL_ELEMENT_ARRAY_BUFFER 0x8893
#define GL_PIXEL_PACK_BUFFER 0x88EB
#define GL_STATIC_DRAW 0x88E4
#define GL_STREAM_READ 0x88E1
#define GL_READ_ONLY 0x88B8
#define GL_FRAMEBUFFER 0x8D40
#define GL_RENDERBUFFER 0x8D41
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_BGRA 0x80E1

static void (WINAPI *p_glGenBuffers)(GLsizei, GLuint *);
static void (WINAPI *p_glBindBuffer)(GLenum, GLuint);
static void (WINAPI *p_glBufferData)(GLenum, ptrdiff_t, const void *, GLenum);
static void *(WINAPI *p_glMapBuffer)(GLenum, GLenum);
static GLboolean (WINAPI *p_glUnmapBuffer)(GLenum);
static void (WINAPI *p_glGenFramebuffers)(GLsizei, GLuint *);
static void (WINAPI *p_glBindFramebuffer)(GLenum, GLuint);
static void (WINAPI *p_glGenRenderbuffers)(GLsizei, GLuint *);
static void (WINAPI *p_glBindRenderbuffer)(GLenum, GLuint);
static void (WINAPI *p_glRenderbufferStorage)(GLenum, GLenum, GLsizei, GLsizei);
static void (WINAPI *p_glFramebufferRenderbuffer)(GLenum, GLenum, GLenum, GLuint);
static GLenum (WINAPI *p_glCheckFramebufferStatus)(GLenum);

static int failures;
static void check(int ok, const char *what) { if (!ok) { failures++; printf("FAIL %s\n", what); } }
static int close_to(DWORD a, DWORD b)
{
    for (int s = 0; s < 24; s += 8) { int d = (int)((a >> s) & 0xff) - (int)((b >> s) & 0xff); if (d < -6 || d > 6) return 0; }
    return 1;
}

enum { FILLER = 8192 };                       /* 8192 vertices of 12 bytes = 96 KB */
static float vertices[(FILLER + 4) * 3];
static unsigned int indices[FILLER * 4 + 6];  /* 128 KB before the six that are used */

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    WNDCLASSW wc = {0}; wc.lpfnWndProc = DefWindowProcW; wc.hInstance = GetModuleHandleW(NULL); wc.lpszClassName = L"FineWineGLOffsets";
    RegisterClassW(&wc);
    HWND window = CreateWindowExW(0, wc.lpszClassName, L"", WS_OVERLAPPEDWINDOW, 0, 0, 64, 64, NULL, NULL, wc.hInstance, NULL);
    HDC dc = GetDC(window);
    PIXELFORMATDESCRIPTOR pfd = { sizeof(pfd), 1, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL, PFD_TYPE_RGBA, 32 };
    if (!SetPixelFormat(dc, ChoosePixelFormat(dc, &pfd), &pfd)) { printf("gl-buffer-offsets: no pixel format\n"); return 1; }
    HGLRC rc = wglCreateContext(dc);
    if (!rc || !wglMakeCurrent(dc, rc)) { printf("gl-buffer-offsets: no OpenGL context\n"); return 1; }
    printf("renderer: %s, version %s\n", (const char *)glGetString(GL_RENDERER), (const char *)glGetString(GL_VERSION));

#define LOAD(name) if (!(p_##name = (void *)wglGetProcAddress(#name))) { printf("gl-buffer-offsets: no %s\n", #name); return 1; }
    LOAD(glGenBuffers) LOAD(glBindBuffer) LOAD(glBufferData) LOAD(glMapBuffer) LOAD(glUnmapBuffer)
    LOAD(glGenFramebuffers) LOAD(glBindFramebuffer) LOAD(glGenRenderbuffers) LOAD(glBindRenderbuffer)
    LOAD(glRenderbufferStorage) LOAD(glFramebufferRenderbuffer) LOAD(glCheckFramebufferStatus)

    GLuint fbo, rb, vbo, ibo, pbo;
    p_glGenFramebuffers(1, &fbo); p_glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    p_glGenRenderbuffers(1, &rb); p_glBindRenderbuffer(GL_RENDERBUFFER, rb);
    p_glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 64, 64);
    p_glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    check(p_glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "framebuffer complete");
    glViewport(0, 0, 64, 64);
    glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);

    /* left half, from buffer objects, at offsets above 64 KB */
    float *v = vertices + FILLER * 3;
    v[0] = -1; v[1] = -1; v[3] = 0; v[4] = -1; v[6] = -1; v[7] = 1; v[9] = 0; v[10] = 1;
    unsigned int *i = indices + FILLER * 4;
    i[0] = 0; i[1] = 1; i[2] = 2; i[3] = 2; i[4] = 1; i[5] = 3;
    p_glGenBuffers(1, &vbo); p_glBindBuffer(GL_ARRAY_BUFFER, vbo);
    p_glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
    p_glGenBuffers(1, &ibo); p_glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    p_glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);
    glEnableClientState(GL_VERTEX_ARRAY);
    glColor3f(1, 0, 0);
    glVertexPointer(3, GL_FLOAT, 0, (void *)(size_t)(FILLER * 3 * sizeof(float)));
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, (void *)(size_t)(FILLER * 4 * sizeof(unsigned int)));
    check(glGetError() == GL_NO_ERROR, "draw from buffer objects");

    /* right half, from the program's own memory */
    static const float own[12] = { 0, -1, 0,  1, -1, 0,  0, 1, 0,  1, 1, 0 };
    static const unsigned int own_indices[6] = { 0, 1, 2, 2, 1, 3 };
    p_glBindBuffer(GL_ARRAY_BUFFER, 0); p_glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
    glColor3f(0, 1, 0);
    glVertexPointer(3, GL_FLOAT, 0, own);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, own_indices);
    check(glGetError() == GL_NO_ERROR, "draw from memory");
    glFinish();

    /* read back into memory */
    static DWORD pixels[64 * 64];
    glReadPixels(0, 0, 64, 64, GL_BGRA, GL_UNSIGNED_BYTE, pixels);
    check(close_to(pixels[32 * 64 + 16] & 0xffffff, 0xff0000), "quad from buffer objects (read into memory)");
    check(close_to(pixels[32 * 64 + 48] & 0xffffff, 0x00ff00), "quad from memory (read into memory)");

    /* read back into a pixel buffer, 128 KB in */
    enum { PBO_OFFSET = 128 * 1024 };
    p_glGenBuffers(1, &pbo); p_glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo);
    p_glBufferData(GL_PIXEL_PACK_BUFFER, PBO_OFFSET + sizeof(pixels), NULL, GL_STREAM_READ);
    glReadPixels(0, 0, 64, 64, GL_BGRA, GL_UNSIGNED_BYTE, (void *)(size_t)PBO_OFFSET);
    check(glGetError() == GL_NO_ERROR, "read into a pixel buffer");
    const BYTE *mapped = p_glMapBuffer(GL_PIXEL_PACK_BUFFER, GL_READ_ONLY);
    check(mapped != NULL, "map the pixel buffer");
    if (mapped) {
        const DWORD *p = (const DWORD *)(mapped + PBO_OFFSET);
        check(close_to(p[32 * 64 + 16] & 0xffffff, 0xff0000), "quad from buffer objects (read into a pixel buffer)");
        check(close_to(p[32 * 64 + 48] & 0xffffff, 0x00ff00), "quad from memory (read into a pixel buffer)");
        p_glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
    }
    p_glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);

    wglMakeCurrent(NULL, NULL); wglDeleteContext(rc); ReleaseDC(window, dc); DestroyWindow(window);
    if (failures) { printf("gl-buffer-offsets: %d failure(s)\n", failures); return 1; }
    printf("gl-buffer-offsets: ok\n");
    return 0;
}
