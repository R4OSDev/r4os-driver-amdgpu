# AMDGPU

Version 0.1.12 adds direct eDP, AUX/DDC, ATOM command execution and confirmed
panel brightness for R4OS 0.80.16. The target is PCI 1002:15D8; Raven2 revisions are rejected.
AMDGPU.R4D is the external hardware owner. Kernel graphics/memory/queue APIs,
WINSVC and R4GFX retain their common device and resource contracts.

Normal `auto`/`passive` binding only captures PCI, UMA, board, firmware and
boot-framebuffer evidence. `mode=native` remains gated until display
integration; `IMAGE_SCOPE=none` excludes the unfinished native path from
normal profiles. Physical laptop validation belongs exclusively to 0.80.39.
Host fixtures verify source formats and ownership, not execution on Picasso.

The private resident native pump composes:

- Exact PCI/boot identity, validated VFCT or measured BAR0 ATOM shadow,
  reserved UMA, original firmware resources, SHA256 and generation checks.
- A fresh boot-writer hold and unchanged DCN1 scanout guard; PCI bus mastering,
  SMU10 interface/GFXOFF/SDMA power, confirmed CP/MEC/SDMA/RLC park.
- PSP10 TMR, mailbox, command/fence ring, all CE/PFP/ME/MEC/RLC/SDMA uploads
  and ASD completion. VCN, DMCU and optional TAs retain their later owners.
- GMC9/ATHUB, exact system/native BO residency, VMID1 IB/resource mappings,
  independent DMA leases and a journal restoring original GMC state.
- SDMA4.1 ring programming and an actual fill/copy/fence/RPTR prerequisite.
- GC9.1 golden tables, measured CU/RB masks, scratch/LDS apertures, 4 KB GDS,
  original clear state and v9 MQDs, RLC/CP/KIQ and the ordinary compute queue.
  Two rounds of actual context-register/fence/ring-consumption evidence are
  required before the common queue worker starts.

`gc_contexts.zig` owns eight generation-bound contexts and eight queued IBs.
Graphics and compute have independent 64 KB rings; normal-priority hardware
queues use software priority/age scheduling at IB boundaries. GDS reservations
and scratch ranges cannot overlap between live contexts. Each submission has
bounded packet storage, a deadline and its exact canonical resource owner.
The fixed renderer supplies genuine ACO programs and full GFX9 state.
Arbitrary Vulkan pipelines and scratch relocations retain their later owners.

`render_jobs.zig` shares R4AMD's genuine AddrLib/render archive with the R4L.
It uploads six immutable shaders to a separate 64 KB UMA arena, maps their
executable pages and keeps eight 4 KB parameter slots until exact retirement.
Normal fill/sample/list/grid/color work uses separate retained BO mappings;
text masks and NV12/P010/YUV420P use the same GC ring and timeline. Pipeline
validation failure reaches the canonical fence after partial resources retire.
Queue backpressure, GPU completion, map retirement and caller ACK remain
distinct; an old or wrong fence cannot release a newer job's resources.

The native allocation provider uses actual AddrLib image geometry and the
existing UMA budget owner. The native VA provider owns 32 bounded 64 MB
slots, full-BO bindings, exact generation tokens and separate unmap/TLB ACKs.
Stable YUV BO mappings survive frames. GPU command/parameter preparation
never maps pixels to the CPU. The registered render operations become visible
only after GC/SDMA prerequisites and shader preparation; Present stays with
the later DCN integration. These software checks do not admit the laptop.

Before queue activation AMDGPU also publishes an IMAGE_V1 architecture
record: GC/SDMA identity, verified external ASIC revision, actual post-golden
GB_ADDR_CONFIG, 4 KB BO binding alignment, 64 MB limit and memory generation.
The readback comparison respects Raven's reserved-bit mask. R4GFX consumes
this record for real AddrLib image admission; it does not invent topology.

R4AMD's allocation-free SDMA and PM4 encoders are shared source dependencies.
GC9 fences include cache actions and the GFX9 ZPASS_DONE EOP workaround.
SDMA doorbells count bytes; CP doorbells count dwords. Ring consumption does
not substitute for matching 64-bit memory fence tokens.

One preemptible driver worker owns all queue mutation. IH/IRQ only records
bounded metadata and wakes that worker. Close joins it before outer teardown;
GC quiescence leaves SDMA with its own owner. Proven engine idle precedes
PTE/TLB/DMA/BO/IRQ retirement and arena release. An uncertain write, timeout
or failed release retains ownership. Original BIOS command queues are never
restarted after replacing their firmware.

Build with `./Build.sh` on Linux or `Build.bat` on Windows, using PowerShell 7.
The normal build verifies pinned originals/generated registers, runs the
component tests and audits all sixteen unchanged firmware resources in the
R4D container. The DCN1 archive links 26 original Linux 7.2.4 AMD DC/DML units
and four private bridges into the R4D. The source closure contains frontend
resources, HUBP/HUBBUB/DPP/OPP/MPC/timing, request/deadline registers and
watermarks. A heap-owned DC context runs only in a dedicated SIMD-capable
driver Task. Planning performs no MMIO. Commit requires confirmed clocks
and all four pipes blank/disabled; Abort retains memory until restoration ACK.
The initial runtime retains the original boot plane. HDMI,
output enable and pageflip follow in 0.80.17-0.80.18. No activation hook is
installed by a normal probe. The grouped host tests execute the real archive
against explicit register/Task/heap responses; they do not emulate a GPU.

See workspace `Docs/Drivers/AMDGFXQueues08011.txt` and its JSON evidence,
plus the earlier AMD board, firmware, memory, queue, startup and SDMA records.
Original code is Apache-2.0; derived AMD/Mesa code retains MIT notices in its
sources, catalog and distribution legal exports.

Panel control uses board-selected direct UNIPHY/AUX/HPD routes, complete EDID
native timing and bounded DPCD link training with rate fallback. No bridge,
unknown PHY wiring, source spread spectrum or unsupported ATOM revision is
invented. The bounded ATOM interpreter runs the actual board command table
(revision 1.6 transmitter ABI) in the same SIMD worker, with separate heap
scratch and explicit MMIO operations; it executes no x86 firmware code.

The panel owner enforces power/backlight delays, observes HPD and actual
video enable before lighting the panel, and supports receiver AUX8/AUX16 or
original PWM. It reads back the programmed level before marking it known.
Direct PWM refuses active DMCU/ABM ownership and invalid period data; this
milestone does not upload DMCU firmware or pretend to support adaptive
backlight. Ordinary AUX timeouts release bus arbitration through a documented
patch, while uncertain MMIO effects retain the owner and restoration duty.

The common brightness API carries distinct intent and driver receipt serials.
AMDGPU's private worker bridge is ready for /18 native output publication.
Desktop restores stable per-receiver BRIGHTNESS.R4S choices; Appearance saves
levels and shows confirmed state. Current input/ACPI/EC paths provide no
brightness-key event, explicitly reported by the page. Panel identity,
electrical training, visible brightness and Lenovo Fn events remain untested
until /39. See Docs/Drivers/AMDPanel08016.txt for the exact software evidence.
