# Metal 4 and ray tracing: what it would take (2026-11-15)

An assessment, not an implementation. It answers two questions for FineWine's runtime: how hard
it would be to add Metal 4 to DXMT and to MoltenVK, and what stands between the runtime and
ray tracing. Everything stated as fact was checked in the sources and SDK on this machine; the
effort figures are estimates.

## The graphics layout this is about

| API | Layer | State in the runtime |
|---|---|---|
| Direct3D 9 and older | WineD3D | Works (`tests/runtime/d3d9-clear.c`). DXMT does not cover these. |
| Direct3D 10, 11 | DXMT on Metal | Works; the default for every prefix. |
| Direct3D 12 | Wine's vkd3d on MoltenVK | Works, with or without DXMT selected. No ray tracing. |
| Vulkan | MoltenVK | Works, with ray queries and ray tracing pipelines (see "Ray tracing" below). |

## What Metal 4 is, in the SDK

The macOS 26 SDK adds 31 `MTL4*` headers to Metal and four `MTL4FX*` headers to MetalFX, all
`API_AVAILABLE(macos(26.0))`. It is a second command model beside the existing one, not a set of
flags on it:

- `MTL4CommandQueue`, `MTL4CommandBuffer`, `MTL4CommandAllocator`: command memory is allocated
  and recycled by the program.
- `MTL4RenderCommandEncoder`, and one `MTL4ComputeCommandEncoder` that also does copies and
  acceleration structure builds.
- `MTL4ArgumentTable`: resource bindings as a table object, in place of per-encoder set calls.
- `MTLResidencySet`: the program declares which resources a queue or command buffer uses.
- Explicit barriers between stages, in place of Metal tracking hazards itself.
- `MTL4Compiler` and tasks: pipeline compilation as an explicit, asynchronous step.
- MetalFX: `MTL4FXTemporalScaler`, `MTL4FXSpatialScaler`, `MTL4FXTemporalDenoisedScaler`,
  `MTL4FXFrameInterpolator`.

So "enabling Metal 4" in a translation layer means writing a second back end for it, selected at
run time on macOS 26 or later, with the existing one kept for older systems.

## DXMT

**Where it stands.** No Metal 4 use. The only trace is a block in `winemetal_unix.c` under
`#if 0 // needs macOS 26 SDK, and we don't really use it at the moment`, and that is about
indirect command buffers, not the Metal 4 command model. No upstream branch is named for
Metal 4 (branches: `main`, `feat/d3d12-9`, `feat/dxil-4`, `feat/dxil-5`, `fix/coherent-event`,
`chore/idl`).

**How its Metal use is arranged.** DXMT is built in a way that helps:

- All Metal calls are on the Mac side, in one file: `src/winemetal/unix/winemetal_unix.c`
  (3,482 lines, 103 entry points).
- Drawing is not issued call by call. The Windows side records a command stream, and three
  interpreters replay it: `_MTLRenderCommandEncoder_encodeCommands`,
  `_MTLComputeCommandEncoder_encodeCommands` and `_MTLBlitCommandEncoder_encodeCommands`, with
  69 cases between them.
- It generates Metal's shader IR itself (`src/airconv`) and already binds resources through
  argument buffers.

**What a Metal 4 back end would be.**

1. A second set of the three interpreters, emitting to `MTL4RenderCommandEncoder` and
   `MTL4ComputeCommandEncoder`.
2. Command buffer lifetime: allocators, `commit`, and feedback in place of completion handlers.
   `MTLCommandBuffer` appears 64 times in that file.
3. Binding through `MTL4ArgumentTable`, and residency sets in place of `useResource`/`useHeap`
   (20 uses).
4. Barriers. Direct3D 11 has no explicit synchronisation, so DXMT would have to derive them
   from its own resource tracking. This is the part with real risk of subtle rendering bugs.
5. Pipeline creation through `MTL4Compiler`.
6. Run-time selection by OS version and GPU, and the Windows-side structures that mirror all of
   the above across the Wine boundary.

**Estimate.** Four to eight weeks for someone who knows DXMT's internals; longer for anyone
else, mostly spent on item 4. It is a contained job because of the single file and the
interpreters.

**What it would buy.** For Direct3D 11 games the gains are in overhead rather than features:
cheaper command encoding, less pipeline-compile stutter, and access to MetalFX frame
interpolation and the denoised scaler. None of it changes what games can run.

## MoltenVK

**Where it stands.** No Metal 4 use in release 1.4.2 (what the runtime bundles) or on upstream
`main` as of 2026-10-13: no file there mentions `MTL4`. No upstream branch is named for it
(branches: `main`, `mesh-shader`, `geometry-shaders`, and two `VK_KHR_portability_subset` ones).

**How its Metal use is arranged.** Spread through the library:

| Area | Size |
|---|---|
| `MoltenVK/Commands` | 14,515 lines in 30 files |
| `MoltenVK/GPUObjects` | 29,004 lines in 37 files |
| Uses of `MTLCommandBuffer` | 175 |
| Uses of `MTLRenderCommandEncoder` | 86 |
| Uses of `MTLComputeCommandEncoder` | 68 |
| Uses of `MTLBlitCommandEncoder` | 27 |
| Uses of `MTLRenderPipelineState` | 61 |
| Uses of `MTLArgumentEncoder` | 50 |

**What a Metal 4 back end would be.** The fit is better than for DXMT, because Vulkan and
Metal 4 share a shape: command pools map to allocators, descriptor sets to argument tables,
pipeline barriers to Metal 4 barriers, and pipeline creation to the compiler. But the work
touches command encoding, descriptor binding, pipeline creation and resource tracking all at
once, and the Metal 3 path has to keep working beside it.

**Estimate.** Three to six months for an experienced MoltenVK contributor. It is a project for
upstream (Khronos) rather than a patch to carry: MoltenVK's command and descriptor code changes
often, and a private fork of this size would be expensive to keep current.

**What it would buy.** The same overhead gains, and more of them, since Vulkan and Direct3D 12
programs already issue barriers that MoltenVK currently has to translate away.

## Ray tracing

Ray tracing does not depend on Metal 4. Metal has had acceleration structures and intersection
since before it (`MTLAccelerationStructure.h`, `MTLAccelerationStructureCommandEncoder.h`).
What is missing is in the two layers above Metal.

**MoltenVK (needed for Vulkan ray tracing, and under Direct3D 12).**

- Upstream offers none of the ray tracing extensions, in 1.4.2 or on `main`. Only
  `VK_KHR_deferred_host_operations`, which they depend on, is present.
- The shader side is partly there: SPIRV-Cross's Metal back end has ray query and acceleration
  structure support (`spirv_msl.cpp` includes `<metal_raytracing>` and emits
  `acceleration_structure` types).
- `VK_KHR_acceleration_structure` plus `VK_KHR_ray_query` (ray queries inside ordinary shaders)
  is the reachable part: build and update commands, the object types, and enabling the shader
  path. **Done on 2026-11-15** as `patches/moltenvk/0001`; see "What is implemented" below.
- `VK_KHR_ray_tracing_pipeline` (ray generation, hit and miss shaders, shader binding tables)
  has no Metal counterpart. **Done on 2026-11-15** as `patches/moltenvk/0003`, by a different
  route than first sketched here: the pipeline's shaders are merged into one compute shader
  built on ray queries, so SPIRV-Cross needed no new shader stages.

**Direct3D 12 (Wine's vkd3d).**

- DirectX Raytracing is not implemented. `RaytracingTier` is set to
  `D3D12_RAYTRACING_TIER_NOT_SUPPORTED`, and `CreateStateObject` and `DispatchRays` are stubs.
- Adding it means acceleration structure support, state objects and shader tables, and
  translating ray tracing shaders, on top of the Vulkan extensions above. Estimate: months, and
  it only becomes useful once MoltenVK has the extensions.
- vkd3d-proton (the Proton fork) has DirectX Raytracing, but it needs the ray tracing pipeline
  extension and a long list of other Vulkan features MoltenVK lacks. Moving the runtime to it is
  its own large porting job.

**A realistic first milestone.** Inline ray queries end to end: `VK_KHR_acceleration_structure`
and `VK_KHR_ray_query` in MoltenVK (done), then DirectX Raytracing 1.1 inline ray tracing in
vkd3d (not started). That covers games that use ray queries for shadows or reflections and
leaves out those built on full ray tracing pipelines.

### What is implemented

Three patches to MoltenVK 1.4.2 and one to SPIRV-Cross, in `patches/moltenvk`. The extensions
are offered on macOS 15 and later when the GPU supports ray tracing (every Apple silicon Mac
does): `VK_KHR_acceleration_structure`, `VK_KHR_ray_query`, `VK_KHR_ray_tracing_pipeline`.

**Acceleration structures** (`0001`, `0002`).

- A `VkAccelerationStructureKHR` is a Metal acceleration structure. Bottom-level structures take
  triangles (float, half and 16-bit normalised vertex formats; 16- and 32-bit indices; an
  optional transform) and bounding boxes straight from the application's buffers.
- Top-level structures: Vulkan and Metal lay instances out differently, so the instances are
  converted on the CPU when the build command is encoded. The instance data therefore has to be
  in host-visible memory, and has to be final when the command is recorded rather than when it
  runs. A null instance reference becomes an instance with mask zero.
- Builds, updates (as Metal refits), clone and compact copies, build sizes and device addresses
  work. An acceleration structure's device address is a handle MoltenVK makes up, not a GPU
  address.
- **Host commands** (`vkBuildAccelerationStructuresKHR`, `vkCopyAccelerationStructureKHR` and
  the rest). Metal only builds on the GPU, so each records the same work in a Metal command
  buffer of MoltenVK's own and waits for it. Inputs given as host pointers are copied into
  Metal buffers first. A deferred operation is told the work was not deferred.
- **Size queries.** `VK_QUERY_TYPE_ACCELERATION_STRUCTURE_COMPACTED_SIZE_KHR` is written by the
  GPU; `..._SERIALIZATION_SIZE_KHR` is known when the command is encoded. Both through
  `vkCmdWriteAccelerationStructuresPropertiesKHR` and its host twin.
- **Serialization.** Metal cannot write an acceleration structure out or read one in. What
  MoltenVK writes after Vulkan's header is what the structure was built from (the geometry of a
  bottom-level structure, the instances of a top-level one), and reading it back builds the
  structure again. Two consequences. The size to create for the copy is a full build's, not the
  compacted one. And a structure keeps its build inputs alive: serializing reads the vertex and
  index buffers it was built from at that moment, so they must still hold that data.
- In shaders the structure is bound through the argument buffer. Only Metal 3 argument buffers
  are supported, which is MoltenVK's default.

**Ray tracing pipelines** (`0003`, and the SPIRV-Cross patch).

Metal has no ray generation, hit, miss or callable shader stages, and SPIRV-Cross cannot
translate them. It can translate ray queries. So a pipeline's shaders are merged, at the SPIR-V
level, into one compute shader (`RayTracingLowering.cpp` in MoltenVKShaderConverter), which
MoltenVK compiles and dispatches like any other, one thread per ray:

- `traceRayEXT()` becomes a call to a generated function: a ray query loop that runs any-hit
  shaders on triangles that are not opaque and intersection shaders on bounding boxes, then the
  closest-hit or the miss shader. Which shader is read from the shader binding table at run
  time, through its buffer address; a shader group handle is 32 bytes whose first four hold the
  group's index plus one. `reportIntersectionEXT()` and `executeCallableEXT()` become generated
  functions too; `ignoreIntersectionEXT` and `terminateRayEXT` set a flag the loop reads.
- Metal shaders cannot recurse, so every shader is copied once for each depth it can run at, up
  to the pipeline's `maxPipelineRayRecursionDepth`. Each copy has its own payload and built-in
  variables. The cost is shader size: a pipeline that declares depth 4 is compiled as four
  copies of its hit and miss shaders. Rays traced deeper than declared are dropped.
- Shader records (`shaderRecordEXT`) are read in place, behind the handle.
- A Metal ray query does not return an instance's shader binding table offset. Each top-level
  structure therefore carries a small texture of those offsets, which `vkCmdTraceRaysKHR` binds
  for every acceleration structure binding the pipeline traces against.
- Each stage's specialization constants are fixed when the pipeline is created.
- `vkCmdTraceRaysIndirectKHR` works (Metal's indirect dispatch reads the same three counts).
- The ray tracing bind point has its own pipeline and descriptor sets, as Vulkan requires.

Limits of the pipeline support:

- Pipeline libraries (`VK_KHR_pipeline_library`) are refused.
- `ignoreIntersectionEXT` / `terminateRayEXT` inside a function other than `main` only return
  from that function; the rest of `main` still runs.
- An array of acceleration structures has no offset texture: its instances' shader binding
  table offsets read as zero. At most eight acceleration structure bindings per pipeline.
- Callable shaders may nest two deep.
- Stack size queries return zero; capture/replay handles are not provided.
- One thread per work group. Correct, but not how one would tune a compute shader; no
  performance has been measured.
- Shaders from compilers other than glslang (DXC, or vkd3d's own) have not been tried.

**Tested** by two programs, natively (`scripts/test-moltenvk-raytracing.sh`) and through Wine
as ARM64 and as x64 programs (`scripts/test-finewine-runtime.sh`):

- `tests/moltenvk/raytracing.c`: a triangle, an instance, a compute shader tracing two ray
  queries; then a compacted-size query and compacting copy, serializing and reading back in a
  command buffer and on the host, and host builds, tracing against each result.
- `tests/moltenvk/rtpipeline.c` with the shaders in `tests/moltenvk/rt`: eight shaders in nine
  groups over five instances. It checks closest-hit built-ins and barycentrics, two hit groups
  sharing a shader with different shader records, per-instance hit group selection, an any-hit
  shader ignoring a triangle and a procedural hit, an intersection shader's distance, hit kind
  and attributes, a second ray traced from a closest-hit shader, a callable shader, and both
  direct and indirect dispatch.

Nothing larger has been run: no game, no refit, no large scene.

**Build.** The patches are applied only to the runtime's MoltenVK
(`MVK_FLAVOR=finewine scripts/build-moltenvk.sh all`, output in `build/moltenvk-out-finewine`).
The MoltenVK builds that go into the CrossOver payloads are unchanged.

## Frame generation (DLSS Frame Generation to MetalFX): findings, not yet built

Asked for on 2026-11-15, with the requirement that DLSS and frame generation work on the
MoltenVK path (Direct3D 12 and Vulkan) as well as on DXMT. What was established that day:

- **MetalFX has it.** `MTLFXFrameInterpolator` (macOS 26 and later) takes the current and
  previous colour, depth and motion vectors and writes an in-between frame. On this machine
  (Apple M3, macOS 27) `supportsDevice:` is true, an interpolator is created without a scaler,
  and encoding one runs without error. A first try at feeding it produced the current frame
  rather than an in-between one, so its input conventions (motion vector direction and scale,
  history) still have to be worked out.
- **Where games ask for it.** DLSS Frame Generation is reached through NVIDIA's Streamline
  (`sl.dlss_g`), which calls NGX with feature 11 and presents the extra frames itself. It exists
  for Direct3D 12 and Vulkan only. There is no Direct3D 11 version for a game to call.
- **What this runtime has.** DXMT's `nvngx.dll` implements NGX for Direct3D 11 only, and only
  feature 1 (super resolution, on MetalFX's temporal scaler). Direct3D 12 here is Wine's vkd3d
  on MoltenVK, which has no NGX at all, so DLSS super resolution is not available there either.
- **So the mapping needs, in order:** NGX entry points for Direct3D 12; a way from a vkd3d
  resource to the Metal texture behind it (MoltenVK can export one; the call has to cross from
  the Windows side to the Unix side); super resolution on that path; then feature 11 on
  `MTLFXFrameInterpolator`; and Streamline's own checks have to pass.
- **Streamline's checks include the GPU vendor.** It offers DLSS only on an NVIDIA adapter.
  DXMT already answers that for Direct3D 11: with `DXMT_ENABLE_NVEXT=1`, which FineWine sets
  when "DLSS through MetalFX" is on, its adapter keeps the name "Apple M3" but reports
  NVIDIA's vendor id (`0x10DE`; `src/dxgi/dxgi_adapter.cpp`). The Direct3D 12 adapter reports
  Apple's (`0x106B`). A Direct3D 12 DLSS path would have to report NVIDIA's too.

## Summary

| Item | Effort | Depends on |
|---|---|---|
| Metal 4 back end in DXMT | 4 to 8 weeks | DXMT internals; macOS 26 |
| Metal 4 back end in MoltenVK | 3 to 6 months | Best done upstream |
| Vulkan ray queries in MoltenVK | Done (first version) | Nothing else |
| Vulkan ray tracing pipelines in MoltenVK | Done (first version) | Lowering to ray queries |
| Direct3D 12 ray tracing in vkd3d | Months | The MoltenVK items above |
| DLSS Frame Generation on MetalFX | Not started; needs NGX for Direct3D 12 first | A decision on the GPU vendor id |

None of these is needed to run a game that does not use ray tracing. For Arknights: Endfield and
similar Direct3D 11 titles the path that matters is already in place: FEX, DXMT, and DLSS
through MetalFX.
