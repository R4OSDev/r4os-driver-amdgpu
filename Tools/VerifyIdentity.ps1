param([switch]$Write)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$unit=[IO.Path]::GetFullPath('..',$PSScriptRoot)
$catalog=Get-Content -Raw (Join-Path $unit 'ThirdParty/Sources.json')|ConvertFrom-Json
$original=Join-Path $unit $catalog.original_root
foreach($entry in $catalog.files){
    $path=Join-Path $original $entry.path
    if((Get-Item $path).Length -ne $entry.bytes -or (Get-FileHash $path).Hash.ToLowerInvariant() -cne $entry.sha256){throw "Original hash mismatch: $($entry.path)"}
}
function Definition([string]$File,[string]$Name){
    $source=[IO.File]::ReadAllText((Join-Path $original ('drivers/gpu/drm/amd/include/'+$File)))
    $match=[regex]::Match($source,('(?m)^#define\s+'+[regex]::Escape($Name)+'\s+(0x[0-9a-fA-F]+|[0-9]+)(?:[uUlL]*)\s*$'))
    if(!$match.Success){throw "Missing original definition $Name"}
    return [Convert]::ToUInt32($match.Groups[1].Value, $(if($match.Groups[1].Value.StartsWith('0x')){16}else{10}))
}
$nbio=Definition 'vega10_ip_offset.h' 'NBIO_BASE__INST0_SEG2'
$gc=Definition 'vega10_ip_offset.h' 'GC_BASE__INST0_SEG0'
$strap=Definition 'asic_reg/nbio/nbio_7_0_offset.h' 'mmRCC_DEV0_EPF0_STRAP0'
$mem=Definition 'asic_reg/nbio/nbio_7_0_offset.h' 'mmRCC_CONFIG_MEMSIZE'
$fb=Definition 'asic_reg/gc/gc_9_1_offset.h' 'mmMC_VM_FB_OFFSET'
$mask=Definition 'asic_reg/nbio/nbio_7_0_sh_mask.h' 'RCC_DEV0_EPF0_STRAP0__STRAP_ATI_REV_ID_DEV0_F0_MASK'
$shift=Definition 'asic_reg/nbio/nbio_7_0_sh_mask.h' 'RCC_DEV0_EPF0_STRAP0__STRAP_ATI_REV_ID_DEV0_F0__SHIFT'
if((Definition 'asic_reg/nbio/nbio_7_0_offset.h' 'mmRCC_DEV0_EPF0_STRAP0_BASE_IDX') -ne 2 -or
   (Definition 'asic_reg/nbio/nbio_7_0_offset.h' 'mmRCC_CONFIG_MEMSIZE_BASE_IDX') -ne 2 -or
   (Definition 'asic_reg/gc/gc_9_1_offset.h' 'mmMC_VM_FB_OFFSET_BASE_IDX') -ne 0){throw 'Unexpected IP base segment'}
$prefix=[uint64]([Math]::Ceiling((($gc+$fb)*4+4)/4096)*4096)
$lines=@('// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0',
 '// Generated from pinned Linux 7.2.4 AMD MIT definitions. Do not hand-edit.',
 '// Original notices and SHA256: ThirdParty/Sources.json. Tools/VerifyIdentity.ps1.',
 ('pub const nbio_base2: u32 = 0x{0:x};' -f $nbio),('pub const gc_base0: u32 = 0x{0:x};' -f $gc),
 ('pub const strap: u32 = (nbio_base2 + 0x{0:x}) * 4;' -f $strap),
 ('pub const memsize: u32 = (nbio_base2 + 0x{0:x}) * 4;' -f $mem),
 ('pub const fb_offset: u32 = (gc_base0 + 0x{0:x}) * 4;' -f $fb),
 ('pub const revision_mask: u32 = 0x{0:x};' -f $mask),('pub const revision_shift = {0};' -f $shift),
 'pub const page_bytes: u64 = 4096;',
 '// Required register prefix, never a measurement of the complete PCI BAR.',
 ('pub const required_prefix: u64 = 0x{0:x};' -f $prefix))
$text=($lines -join "`n")+"`n"
$target=Join-Path $unit 'src/registers.zig'
if($Write){[IO.File]::WriteAllText($target,$text,[Text.UTF8Encoding]::new($false))}
elseif([IO.File]::ReadAllText($target).Replace("`r`n","`n") -cne $text){throw 'AMD register source drift; regenerate with Tools/VerifyIdentity.ps1 -Write'}
Write-Host 'AMDGPU identity source check: pinned MIT files, IP segments, offsets and revision mask verified.'
