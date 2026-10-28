#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <algorithm>
#include <new>
#include <mutex>

#if defined(_WIN32)
#include <malloc.h>
#define TS_EXPORT extern "C" __declspec(dllexport)
#else
#define TS_EXPORT extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif

struct Mesh {
  int32_t vertices, indices, texture, order, flags, visible, mask_count, positions_changed;
  float opacity;
  const float* positions;
  const float* uvs;
  const uint16_t* triangles;
  const int32_t* masks;
  float multiply[4];
  float screen[4];
};

#if TS_HAS_CUBISM
#include "CubismFramework.hpp"
#include "ICubismAllocator.hpp"
#include "Model/CubismMoc.hpp"
#include "Model/CubismModel.hpp"
#include "Physics/CubismPhysics.hpp"
#include "Id/CubismIdManager.hpp"
#include "Rendering/CubismRenderer.hpp"
using namespace Live2D::Cubism::Framework;
namespace Core = Live2D::Cubism::Core;

#if !defined(TS_GPU)
// Canvas-only platforms own no SDK renderer GPU resources.
void Rendering::CubismRenderer::StaticRelease() {}
#endif
// Android's render worker and the Canvas fallback may coexist during a switch.
// Protect Cubism's process-wide allocator, IDs and framework lifecycle.
static std::recursive_mutex cubism_mutex;
#define TS_LOCK std::lock_guard<std::recursive_mutex> lock(cubism_mutex)
#if defined(TS_GPU) && !defined(TS_GPU_METAL)
#include "gpu_shaders.h"
static int shader_source_loads = 0;
static csmByte* load_shader(const std::string path, csmSizeInt* size) {
  const char* source = ts_shader(path);
  if (!source) { *size = 0; return nullptr; }
  ++shader_source_loads;
  *size = static_cast<csmSizeInt>(std::strlen(source));
  auto* bytes = new csmByte[*size + 1];
  std::memcpy(bytes, source, *size + 1);
  return bytes;
}
static void release_shader(csmByte* bytes) { delete[] bytes; }
static CubismFramework::Option framework_options = [] {
  CubismFramework::Option value{};
  value.LoggingLevel = CubismFramework::Option::LogLevel_Off;
  value.LoadFileFunction = load_shader;
  value.ReleaseBytesFunction = release_shader;
  return value;
}();
#endif

class Allocator final : public ICubismAllocator {
 public:
  void* Allocate(const csmSizeType size) override { return std::malloc(size); }
  void Deallocate(void* p) override { std::free(p); }
  void* AllocateAligned(const csmSizeType size, const csmUint32 alignment) override {
#if defined(_WIN32)
    return _aligned_malloc(size, alignment);
#else
    void* p = nullptr;
    return posix_memalign(&p, std::max<size_t>(alignment, sizeof(void*)), size) ? nullptr : p;
#endif
  }
  void DeallocateAligned(void* p) override {
#if defined(_WIN32)
    _aligned_free(p);
#else
    std::free(p);
#endif
  }
};
static Allocator allocator;
static int instances = 0;
struct Scene { CubismMoc* moc; CubismModel* model; CubismPhysics* physics; };
static void shutdown_if_idle() {
  if (!instances && CubismFramework::IsInitialized()) {
    CubismFramework::Dispose(); CubismFramework::CleanUp();
  }
}
TS_EXPORT int ts_available() { return 1; }
TS_EXPORT void* ts_create(const uint8_t* bytes, int size, const uint8_t* physics, int physics_size) { TS_LOCK;
  if (!bytes || size < 4 || size > 64 * 1024 * 1024) return nullptr;
  if (!CubismFramework::IsStarted()) { CubismFramework::StartUp(&allocator
#if defined(TS_GPU) && !defined(TS_GPU_METAL)
    , &framework_options
#endif
    ); CubismFramework::Initialize(); }
  auto* moc = CubismMoc::Create(bytes, size, true);
  if (!moc) { shutdown_if_idle(); return nullptr; }
  auto* model = moc->CreateModel();
  if (!model) { CubismMoc::Delete(moc); shutdown_if_idle(); return nullptr; }
  // Cubism 5.3 offscreen part blending needs a separate renderer implementation.
  if (Core::csmGetOffscreenCount(model->GetModel()) > 0 || model->IsBlendModeEnabled()) {
    moc->DeleteModel(model); CubismMoc::Delete(moc); shutdown_if_idle(); return nullptr;
  }
  auto* scene = new Scene{moc, model, physics_size > 0 ? CubismPhysics::Create(physics, physics_size) : nullptr};
  ++instances; model->SaveParameters(); model->Update(); return scene;
}
TS_EXPORT void ts_destroy(void* ptr) { TS_LOCK;
  if (!ptr) return;
  auto* s = static_cast<Scene*>(ptr);
  if (s->physics) CubismPhysics::Delete(s->physics);
  s->moc->DeleteModel(s->model); CubismMoc::Delete(s->moc); delete s;
  --instances; shutdown_if_idle();
}
TS_EXPORT void ts_begin(void* ptr) { TS_LOCK; if (ptr) static_cast<Scene*>(ptr)->model->LoadParameters(); }
TS_EXPORT void ts_parameter(void* ptr, const char* id, float value, int blend) { TS_LOCK;
  if (!ptr || !id || !std::isfinite(value)) return;
  auto* m = static_cast<Scene*>(ptr)->model;
  auto key = CubismFramework::GetIdManager()->GetId(id);
  // Parameter-batch ABI: bit 16 is weighted set, low 16 bits are 0..1.
  // This keeps all existing platform transports and legacy blend modes valid.
  if ((blend & 0xffff0000) == 0x10000) m->SetParameterValue(key, value, (blend & 0xffff) / 65535.0f);
  else if (blend == 1) m->AddParameterValue(key, value);
  else if (blend == 2) m->MultiplyParameterValue(key, value);
  else m->SetParameterValue(key, value);
}
TS_EXPORT void ts_update(void* ptr, float delta) { TS_LOCK;
  if (!ptr) return;
  auto* s = static_cast<Scene*>(ptr);
  if (s->physics) s->physics->Evaluate(s->model, std::clamp(delta, 0.0f, 0.05f));
  // CubismModel::Update clears changed flags immediately after evaluation.
  // Retain them until the bridge has read this frame, then reset next time.
  Core::csmResetDrawableDynamicFlags(s->model->GetModel());
  Core::csmUpdateModel(s->model->GetModel());
}
TS_EXPORT int ts_mesh_count(void* ptr) { TS_LOCK; return ptr ? static_cast<Scene*>(ptr)->model->GetDrawableCount() : 0; }
TS_EXPORT int ts_mesh(void* ptr, int index, Mesh* out) { TS_LOCK;
  if (!ptr || !out || index < 0 || index >= ts_mesh_count(ptr)) return 0;
  auto* m = static_cast<Scene*>(ptr)->model; auto* core = m->GetModel();
  out->vertices = m->GetDrawableVertexCount(index);
  out->indices = m->GetDrawableVertexIndexCount(index);
  out->texture = m->GetDrawableTextureIndex(index);
  out->order = m->GetRenderOrders()[index];
  out->flags = Core::csmGetDrawableConstantFlags(core)[index];
  out->visible = m->GetDrawableDynamicFlagIsVisible(index);
  out->mask_count = m->GetDrawableMaskCounts()[index];
  out->positions_changed = m->GetDrawableDynamicFlagVertexPositionsDidChange(index);
  out->opacity = m->GetDrawableOpacity(index);
  out->positions = m->GetDrawableVertices(index);
  out->uvs = reinterpret_cast<const float*>(m->GetDrawableVertexUvs(index));
  out->triangles = m->GetDrawableVertexIndices(index);
  out->masks = m->GetDrawableMasks()[index];
  const auto mul = m->GetDrawableMultiplyColor(index); const auto scr = m->GetDrawableScreenColor(index);
  out->multiply[0] = mul.X; out->multiply[1] = mul.Y; out->multiply[2] = mul.Z; out->multiply[3] = mul.W;
  out->screen[0] = scr.X; out->screen[1] = scr.Y; out->screen[2] = scr.Z; out->screen[3] = scr.W;
  return 1;
}
TS_EXPORT int ts_meshes(void* ptr, Mesh* out, int count) { TS_LOCK;
  if (!ptr || !out || count != ts_mesh_count(ptr)) return 0;
  for (int i = 0; i < count; ++i) if (!ts_mesh(ptr, i, out + i)) return 0;
  return 1;
}
#if defined(CSM_TARGET_ANDROID_ES2)
#include "android_gpu.inc"
#elif defined(TS_GPU)
#include "desktop_gpu.inc"
#endif
#else
TS_EXPORT int ts_available() { return 0; }
TS_EXPORT void* ts_create(const uint8_t*, int, const uint8_t*, int) { return nullptr; }
TS_EXPORT void ts_destroy(void*) {}
TS_EXPORT void ts_begin(void*) {}
TS_EXPORT void ts_parameter(void*, const char*, float, int) {}
TS_EXPORT void ts_update(void*, float) {}
TS_EXPORT int ts_mesh_count(void*) { return 0; }
TS_EXPORT int ts_mesh(void*, int, Mesh*) { return 0; }
TS_EXPORT int ts_meshes(void*, Mesh*, int) { return 0; }
#endif

#if !defined(TS_GPU) || defined(CSM_TARGET_ANDROID_ES2)
TS_EXPORT const void* ts_gpu_api() { return nullptr; }
#endif
