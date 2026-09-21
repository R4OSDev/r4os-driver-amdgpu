# AMDGPU

Version 0.1.8 implements the Picasso GC9.1/SDMA4.1 execution foundation for
R4OS 0.80.11. The target is PCI 1002:15D8; Raven2 revisions are rejected.
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
The compiler must supply the full shader/resource state and GFX9 scratch
relocations; compiler/render/Vulkan admission follows in later milestones.

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
R4D container. The separate original DCN1 math portability object still needs
full runtime/link integration in 0.80.15.

See workspace `Docs/Drivers/AMDGFXQueues08011.txt` and its JSON evidence,
plus the earlier AMD board, firmware, memory, queue, startup and SDMA records.
Original code is Apache-2.0; derived AMD/Mesa code retains MIT notices in its
sources, catalog and distribution legal exports.
