# AMDGPU

Version 0.1.18 adds generation-bound RADV device facts and validated native
graphics/compute IB submissions for R4OS 0.80.23. DCN1 HDMI audio and display
behavior from 0.80.22 are retained.
The target is PCI 1002:15D8; Raven2 revisions are rejected.
AMDGPU.R4D is the external hardware owner. Kernel graphics/memory/queue APIs,
WINSVC and R4GFX retain their common device and resource contracts.

Normal `auto`/`passive` binding only captures PCI, UMA, board, firmware and
boot-framebuffer evidence. `mode=native` starts an asynchronous owner with real firmware, engine and
display prerequisites and bounded restoration. `IMAGE_SCOPE=none` keeps the
in-progress driver out of normal profiles until package integration. Physical laptop validation belongs exclusively to 0.80.39.
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
only after GC/SDMA prerequisites and shader preparation. Present uses the
common upload queue, actual SDMA copies and DCN visibility receipts after
native takeover. These software checks do not admit the laptop.

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
R4D container. The DCN1 archive links 29 original Linux 7.2.4 AMD DC/DML units
and eight private bridges into the R4D. The source closure contains frontend
resources, HUBP/HUBBUB/DPP/OPP/MPC/timing, request/deadline registers and
watermarks. A heap-owned DC context runs only in a dedicated SIMD-capable
driver Task. Planning performs no MMIO. Commit requires confirmed clocks
and all four pipes blank/disabled; Abort retains memory until restoration ACK.
Native takeover holds the immutable boot pixels, plans real DML clocks,
programs the original ATOM pixel-clock and SST paths, and waits for an actual
frame-counter/address receipt before common commit. Abort reconstructs the
boot mode before releasing that hold. A passive probe installs no activation hook. The grouped host tests execute the real archive
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
AMDGPU services this bridge on the same serialized display task after
native output publication.
Desktop restores stable per-receiver BRIGHTNESS.R4S choices; Appearance saves
levels and shows confirmed state. Current input/ACPI/EC paths provide no
brightness-key event, explicitly reported by the page. Panel identity,
electrical training, visible brightness and Lenovo Fn events remain untested
until /39. See Docs/Drivers/AMDPanel08016.txt for the exact software evidence.

Direct HDMI uses the original DCN1 hardware I2C and stream encoders with
bounded GPIO ownership, E-DDC block reads and ATOM1.5 encoder/1.6 transmitter
commands. No Linux GPIO allocation, fake I2C success or guessed board clock
is involved. Acquisition failure, NACK and ordinary timeout release hardware
arbitration and restore the actual pad mask. MMIO failures retain effects.

The source remains uncompressed RGB HDMI1.4 TMDS with a 340MHz ceiling.
RGB8/10, full/limited range, PQ/HLG and static metadata require joint current
source, board, EDID and bandwidth admission. XR30 uses actual HUBP/CNVC,
OPP, 5:4 clock and encoder programming. Encoded mode images and prior color
state survive apply/confirm/rollback; SDR sends an explicit metadata reset.
Canonical legacy mode images receive bounded one-time limited conversion;
ordinary Desktop frames already match the published encoding. SYSTEM-source
presentation also enables the shared SDR ICC/VCGT path. Hardware LUT/CTM
caps stay zero. Six-bit eDP remains SDR without an invented eight-bit color
state. VRR is explicitly fixed/unavailable: this source profile implements
neither adaptive eDP nor HDMI EMP/FreeSync-VSIF. No DP-MST, DSC or FRL is
advertised. Audio samples/InfoFrames stay muted for /22; USB-C is data-only.
See Docs/Desktop/AMDFarbe08021.txt/.json for implementation and limits.

HPD stabilizes for 100ms before new admission. Observed disconnect or changed
EDID fingerprints invalidate the old receiver; pause, drain, confirmed
physical stop, completion settlement, common output withdrawal and resource
release execute in order, with exact generation receipts and a 5s deadline.
Busy or unsafe retirement retains resources; replacement cannot reuse old
jobs or output identities. A disconnect during unpublished activation retains
the restoration duty. The native run loop publishes actual common HDMI
receiver identities, samples HPD every 100ms and rechecks EDID every 2s when
no mode decision is pending. Active HDMI scanout now has its own target, private frames, transactional
modes and visibility receipts. The primary native output uses eDP.
See Docs/Drivers/AMDHDMI08017.txt/.json for the software-only evidence.


Transactional presentation (0.80.18)
----------------------------------
Only EDID timings admitted by link bandwidth and the actual DML planner enter
the mode catalog. Apply retains both old and candidate private BO pairs until
common confirm/rollback. Initial candidate pixels use actual SDMA jobs with
independent internal tokens. Rollback requires a fresh mode epoch and a new
observed scanout address/counter; a timer alone cannot complete a flip.

Partial damage preserves the previous frame before updating its rectangle.
The original DCN1 cursor is 64x64 premultiplied ARGB with bounded signed
clipping; show follows the actual present barrier. Near-VUPDATE Busy retries
before writes. Common completion Busy retains jobs, references and backing.
Panel-link loss or a stalled head isolates that output when a healthy peer
exists. A shared engine/MMIO failure still requires bounded device reset and
reconstruction, with leases held until proven engine/scanout quiescence.
HDMI, brightness and health work share one task.

Presentation statistics use actual observed counter/address receipts and
monotonic host time; refresh intervals are estimates. Host tests exercise real
C/Zig owners against explicit software responses. They do not measure GPU
pixels, electrical links, real VBlank, Windows execution or laptop behavior.
See Docs/Drivers/AMDPresentation08018.txt and its JSON evidence. Desktop provider integration is recorded in /19, multihead in /20 and
physical tests remain /39.


Multihead (0.80.20)
------------------
Each output owns its scanout receipt, BO pair, mode banks and source VA.
Queue admission is bounded and skips a busy peer; flips release the DCN task
between sample/ACK operations. Only the launching owner consumes a task result.
Original DML plans both heads before isolated pipe changes. Initial clocks
reserve at least 600 MHz, with confirmed actual values and ASIC limits;
shared clocks do not change while peers scan. Watermarks only rise during
updates. Dynamic lowering remains the power milestone /34.

HDMI retirement proves link and frontend stop before canonical target removal
and image release. Busy withdrawal retains resources. Reconnect uses fresh
receiver and output generations. Panel loss can leave HDMI and its mode
transactions running; unproven primary resources stay held for recovery /36.
The common Desktop retains layout, scale, clone, primary selection and input
policy; additional heads use software cursors. Logical disable is black/idle,
while physical screen-power and laptop sleep policy belong to /35.
See Docs/Desktop/AMDMehrschirm08020.txt/.json for the model and SMP4 evidence.


HDMI audio (0.80.22)
--------------------
Init captures only the actual class-04/03 1002:15DE companion PCI function.
Legacy and ECAM access identities are preserved; the shared copied-audio
validator requires Kernel 0.1.204 for ECAM routes. The serialized DCN owner selects a connected AZALIA endpoint independently
of the display pipe. Original AMD dce_audio.c and stream-encoder functions
program sink identity, PCM descriptor, speakers, lip sync, DTO, ACR and audio
InfoFrames. The admitted wire profile is stereo 48 kHz S16 LPCM; unsupported
receivers retain video without a fabricated audio route. RGB10 uses the
physical 5:4 TMDS clock for audio regeneration.

A copied receiver source binds the exact companion, physical PortID and
connector to a monotonically revised ELD. Ready follows confirmed video
address/frame evidence. Mode changes and unplug withdraw availability before
transport changes; reset closes copied metadata even if hardware must stay
owned. HDA verifies the revision-3 AMD vendor registers and programs channel
mapping; AUDSVC retains output selection, gain and mute. No service/Kernel ABI
or alternate mixer is introduced. Physical display sleep uses the same stop
boundary and is integrated in /35. Audible and electrical qualification is
reserved for /39. See Docs/Drivers/AMDHDMIAudio08022.txt/.json.

RADV admission (0.80.23)
-----------------------
IMAGE_V1 backend properties revision 2 preserve the exact 64-byte architecture
prefix and add measured PCI/CU/RB/firmware/topology, UMA and VA facts in a
240-byte payload. The driver publishes them only after GC readiness. Native
command/profile revision 1 also accepts the distinct 32+16*N-byte PM4 header
and up to 32 IBs/resources. Every IB must fit a canonical execution binding;
preflight finishes before command output, and fences retain those bindings.
Legacy 504-byte YUV commands keep their existing path. See the software
evidence in Docs/Drivers/AMDRADV08023.txt/.json; physical admission is /39.

VCN1 media foundation (0.80.28)
--------------------------------
The PSP plan now authenticates Picasso VCN firmware. A separate pre-budgeted
1 MB UMA workspace owns stack/context, decode/encode/JPEG rings and fence
self-tests. VCN readiness is published only after all three ring proofs.
The worker routes decode/encode IBs through canonical native binding loans;
32-bit VCN fence identities never wrap within an epoch. Media shutdown must
confirm drained rings, clean LMI/UMC, reset and power ACK before releasing
storage or closing the shared renderer. Static clocks keep active VCN tiles
on; normal idle energy policy follows in /34.

Native YUV allocations expose linear NV12/P010 in one BO with two planes.
The codec-specific session/picture/feedback messages follow in /29-/31;
JPEG application IBs follow in /30. A working ring is not a codec capability.
Docs/Drivers/AMDVCN08028.txt/.json record software and source-oracle evidence.
Physical firmware execution, pixels, power and laptop qualification are /39.

JPEG submission (0.80.30)
------------------------
AMDGPU 0.1.21 accepts native media engine 4 with one bounded system IB.
The worker CPU maps/copies that IB into its retained 8 KB VMID0 slot after
the producer releases its CPU write lease. The caller's BOs and the copied
IB stay alive through the exact hardware fence and resource retirement ACK.
The VCN1 workaround excludes JPEG from decode/encode work until opposing
entries are fully retired; decode and encode may run together. Pending jobs
retain their admission order and original bounded deadline without holding
extra native bindings. A timeout never releases hardware-owned IB storage.
DeviceFacts bit 3 advertises this path separately from VCN ring readiness.
Existing VCN tests cover copy independence, cross-engine exclusion, delayed
retirement and timeout retention. Docs/Drivers/AMDCodecs08030 records the
software evidence; actual VCN/JPEG execution and image quality remain /39.
