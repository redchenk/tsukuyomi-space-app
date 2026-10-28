#include "quickjs.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define TS_EXPORT __declspec(dllexport)
#else
#include <time.h>
#define TS_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

typedef struct {
  JSRuntime *runtime;
  JSContext *context;
  JSValue invoke;
  double deadline;
  char error[512];
  char *output;
  int ready;
} Studio;

static double monotonic_seconds(void) {
#ifdef _WIN32
  LARGE_INTEGER count, frequency;
  QueryPerformanceCounter(&count); QueryPerformanceFrequency(&frequency);
  return (double)count.QuadPart / (double)frequency.QuadPart;
#else
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
#endif
}
static int interrupt(JSRuntime *runtime, void *opaque) {
  (void)runtime;
  return monotonic_seconds() > ((Studio *)opaque)->deadline;
}
static void failure(Studio *s) {
  JSValue error = JS_GetException(s->context);
  const char *text = JS_ToCString(s->context, error);
  snprintf(s->error, sizeof(s->error), "%s", text ? text : "Studio motion runtime failed");
  if (text) JS_FreeCString(s->context, text);
  JS_FreeValue(s->context, error);
}
TS_EXPORT void ts_studio_destroy(void *ptr) {
  Studio *s = ptr;
  if (!s) return;
  if (s->context) {
    JS_FreeValue(s->context, s->invoke);
    JS_FreeContext(s->context);
  }
  if (s->runtime) JS_FreeRuntime(s->runtime);
  free(s->output); free(s);
}
TS_EXPORT void *ts_studio_create(const char *source, int length) {
  if (!source || length <= 0 || length > 1024 * 1024) return NULL;
  Studio *s = calloc(1, sizeof(*s));
  if (!s) return NULL;
  s->invoke = JS_UNDEFINED;
  s->runtime = JS_NewRuntime();
  if (!s->runtime) { ts_studio_destroy(s); return NULL; }
  JS_SetMemoryLimit(s->runtime, 32 * 1024 * 1024);
  JS_SetMaxStackSize(s->runtime, 1024 * 1024);
  JS_SetInterruptHandler(s->runtime, interrupt, s);
  s->deadline = monotonic_seconds() + 2;
  s->context = JS_NewContext(s->runtime);
  if (!s->context) { ts_studio_destroy(s); return NULL; }
  // No libc, module loader, filesystem, network, timers or host functions.
  JSValue result = JS_Eval(s->context, source, (size_t)length,
                          "bundled-studio-motion.js", JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(result)) { failure(s); return s; }
  JS_FreeValue(s->context, result);
  JSValue global = JS_GetGlobalObject(s->context);
  s->invoke = JS_GetPropertyStr(s->context, global, "__studioInvoke");
  JS_FreeValue(s->context, global);
  s->ready = JS_IsFunction(s->context, s->invoke);
  if (!s->ready) snprintf(s->error, sizeof(s->error), "Studio motion entrypoint missing");
  return s;
}
TS_EXPORT int ts_studio_ready(void *ptr) { return ptr && ((Studio *)ptr)->ready; }
TS_EXPORT const char *ts_studio_error(void *ptr) {
  return ptr ? ((Studio *)ptr)->error : "Cannot allocate Studio motion runtime";
}
TS_EXPORT const char *ts_studio_call(void *ptr, const char *json, int length) {
  Studio *s = ptr;
  if (!s || !s->ready || !json || length < 0 || length > 64 * 1024) return NULL;
  free(s->output); s->output = NULL; s->error[0] = 0;
  JS_UpdateStackTop(s->runtime);
  s->deadline = monotonic_seconds() + 0.050;
  JSValue input = JS_ParseJSON(s->context, json, (size_t)length, "motion-input");
  if (JS_IsException(input)) { failure(s); return NULL; }
  JSValue result = JS_Call(s->context, s->invoke, JS_UNDEFINED, 1, &input);
  JS_FreeValue(s->context, input);
  if (JS_IsException(result)) { failure(s); return NULL; }
  JSValue encoded = JS_JSONStringify(s->context, result, JS_UNDEFINED, JS_UNDEFINED);
  JS_FreeValue(s->context, result);
  if (JS_IsException(encoded)) { failure(s); return NULL; }
  size_t size = 0;
  const char *text = JS_ToCStringLen(s->context, &size, encoded);
  if (text && size <= 128 * 1024) {
    s->output = malloc(size + 1);
    if (s->output) memcpy(s->output, text, size + 1);
  }
  if (text) JS_FreeCString(s->context, text);
  JS_FreeValue(s->context, encoded);
  if (!s->output) snprintf(s->error, sizeof(s->error), "Studio motion output exceeds limit");
  return s->output;
}
