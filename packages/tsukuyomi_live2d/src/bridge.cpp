#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <algorithm>
#include <new>

#if defined(_WIN32)
#include <malloc.h>
#define API extern "C" __declspec(dllexport)
#else
#define API extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif

struct Mesh {
  int32_t vertices, indices, texture, order, flags, visible, mask_count;
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

// This renderer uses Flutter's canvas, and owns no SDK renderer GPU resources.
void Rendering::CubismRenderer::StaticRelease() {}

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
API int ts_available() { return 1; }
API void* ts_create(const uint8_t* bytes, int size, const uint8_t* physics, int physics_size) {
  if (!bytes || size < 4 || size > 64 * 1024 * 1024) return nullptr;
  if (!CubismFramework::IsStarted()) { CubismFramework::StartUp(&allocator); CubismFramework::Initialize(); }
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
API void ts_destroy(void* ptr) {
  if (!ptr) return;
  auto* s = static_cast<Scene*>(ptr);
  if (s->physics) CubismPhysics::Delete(s->physics);
  s->moc->DeleteModel(s->model); CubismMoc::Delete(s->moc); delete s;
  --instances; shutdown_if_idle();
}
API void ts_begin(void* ptr) { if (ptr) static_cast<Scene*>(ptr)->model->LoadParameters(); }
API void ts_parameter(void* ptr, const char* id, float value, int blend) {
  if (!ptr || !id || !std::isfinite(value)) return;
  auto* m = static_cast<Scene*>(ptr)->model;
  auto key = CubismFramework::GetIdManager()->GetId(id);
  if (blend == 1) m->AddParameterValue(key, value);
  else if (blend == 2) m->MultiplyParameterValue(key, value);
  else m->SetParameterValue(key, value);
}
API void ts_update(void* ptr, float delta) {
  if (!ptr) return;
  auto* s = static_cast<Scene*>(ptr);
  if (s->physics) s->physics->Evaluate(s->model, std::clamp(delta, 0.0f, 0.05f));
  s->model->Update();
}
API int ts_mesh_count(void* ptr) { return ptr ? static_cast<Scene*>(ptr)->model->GetDrawableCount() : 0; }
API int ts_mesh(void* ptr, int index, Mesh* out) {
  if (!ptr || !out || index < 0 || index >= ts_mesh_count(ptr)) return 0;
  auto* m = static_cast<Scene*>(ptr)->model; auto* core = m->GetModel();
  out->vertices = m->GetDrawableVertexCount(index);
  out->indices = m->GetDrawableVertexIndexCount(index);
  out->texture = m->GetDrawableTextureIndex(index);
  out->order = m->GetRenderOrders()[index];
  out->flags = Core::csmGetDrawableConstantFlags(core)[index];
  out->visible = m->GetDrawableDynamicFlagIsVisible(index);
  out->mask_count = m->GetDrawableMaskCounts()[index];
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
#else
API int ts_available() { return 0; }
API void* ts_create(const uint8_t*, int, const uint8_t*, int) { return nullptr; }
API void ts_destroy(void*) {}
API void ts_begin(void*) {}
API void ts_parameter(void*, const char*, float, int) {}
API void ts_update(void*, float) {}
API int ts_mesh_count(void*) { return 0; }
API int ts_mesh(void*, int, Mesh*) { return 0; }
#endif
