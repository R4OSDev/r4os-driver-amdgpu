param([switch]$Write)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$unit=[IO.Path]::GetFullPath('..',$PSScriptRoot)
$catalog=Get-Content -Raw (Join-Path $unit 'ThirdParty/Sources.json')|ConvertFrom-Json
$original=Join-Path $unit $catalog.original_root
# VerifyIdentity checks every original file hash before this generator runs.
$include=Join-Path $original 'drivers/gpu/drm/amd/include'
function Definitions([string]$Path){
    $table=@{}
    foreach($m in [regex]::Matches([IO.File]::ReadAllText((Join-Path $include $Path)),'(?m)^#define\s+(\w+)\s+(0x[0-9a-fA-F]+|[0-9]+)(?:[uUlL]*)\s*$')){
        $s=$m.Groups[2].Value
        $table[$m.Groups[1].Value]=[Convert]::ToUInt32($s,$(if($s.StartsWith('0x')){16}else{10}))
    }
    return $table
}
$bases=Definitions 'vega10_ip_offset.h'
$lines=[Collections.Generic.List[string]]::new()
$lines.Add('// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0')
$lines.Add('// Generated from original AMD MIT headers in ThirdParty/Sources.json.')
$lines.Add('// Tools/VerifyMemory.ps1; addresses are byte offsets, masks unchanged.')
$registers=@('MC_VM_FB_LOCATION_BASE','MC_VM_FB_LOCATION_TOP','MC_VM_AGP_BASE','MC_VM_AGP_BOT','MC_VM_AGP_TOP','MC_VM_SYSTEM_APERTURE_LOW_ADDR','MC_VM_SYSTEM_APERTURE_HIGH_ADDR','MC_VM_SYSTEM_APERTURE_DEFAULT_ADDR_LSB','MC_VM_SYSTEM_APERTURE_DEFAULT_ADDR_MSB','MC_VM_MX_L1_TLB_CNTL','VM_L2_CNTL','VM_L2_CNTL2','VM_L2_CNTL3','VM_L2_CNTL4','VM_L2_PROTECTION_FAULT_CNTL','VM_L2_PROTECTION_FAULT_CNTL2','VM_L2_PROTECTION_FAULT_DEFAULT_ADDR_LO32','VM_L2_PROTECTION_FAULT_DEFAULT_ADDR_HI32','VM_L2_CONTEXT1_IDENTITY_APERTURE_LOW_ADDR_LO32','VM_L2_CONTEXT1_IDENTITY_APERTURE_LOW_ADDR_HI32','VM_L2_CONTEXT1_IDENTITY_APERTURE_HIGH_ADDR_LO32','VM_L2_CONTEXT1_IDENTITY_APERTURE_HIGH_ADDR_HI32','VM_L2_CONTEXT_IDENTITY_PHYSICAL_OFFSET_LO32','VM_L2_CONTEXT_IDENTITY_PHYSICAL_OFFSET_HI32','VM_CONTEXT0_CNTL','VM_CONTEXT1_CNTL','VM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32','VM_CONTEXT0_PAGE_TABLE_BASE_ADDR_HI32','VM_CONTEXT1_PAGE_TABLE_BASE_ADDR_LO32','VM_CONTEXT0_PAGE_TABLE_START_ADDR_LO32','VM_CONTEXT0_PAGE_TABLE_START_ADDR_HI32','VM_CONTEXT0_PAGE_TABLE_END_ADDR_LO32','VM_CONTEXT0_PAGE_TABLE_END_ADDR_HI32','VM_INVALIDATE_ENG0_REQ','VM_INVALIDATE_ENG17_REQ','VM_INVALIDATE_ENG17_ACK','VM_INVALIDATE_ENG0_ADDR_RANGE_LO32','VM_INVALIDATE_ENG0_ADDR_RANGE_HI32','VM_INVALIDATE_ENG1_ADDR_RANGE_LO32')
$maxOffset=0L
foreach($block in @(@('gfx','GC','gc/gc_9_1','gc/gc_9_0',$registers),@('mm','MMHUB','mmhub/mmhub_1_0','mmhub/mmhub_1_0',$registers),@('at','ATHUB','athub/athub_1_0','',@('ATHUB_MISC_CNTL','ATC_VMID0_PASID_MAPPING')),@('hdp','HDP','hdp/hdp_4_0','',@('HDP_READ_CACHE_INVALIDATE','HDP_NONSURFACE_BASE','HDP_NONSURFACE_BASE_HI')),@('nb','NBIO','nbio/nbio_7_0','',@('HDP_MEM_COHERENCY_FLUSH_CNTL')))){
    $offsets=Definitions ('asic_reg/'+$block[2]+'_offset.h')
    $masks=Definitions ('asic_reg/'+$block[2]+'_sh_mask.h')
    $defaults=if($block[3]){Definitions ('asic_reg/'+$block[3]+'_default.h')}else{@{}}
    $lines.Add('pub const '+$block[0]+' = struct {')
    foreach($reg in $block[4]){
        $key='mm'+$reg
        if(!$offsets.ContainsKey($key) -or !$offsets.ContainsKey($key+'_BASE_IDX')){throw "Missing memory register $key"}
        $baseKey=$block[1]+'_BASE__INST0_SEG'+$offsets[$key+'_BASE_IDX']
        if(!$bases.ContainsKey($baseKey)){throw "Missing IP segment $baseKey"}
        $offset=([long]$bases[$baseKey]+$offsets[$key])*4
        $maxOffset=[Math]::Max($maxOffset,$offset)
        $lines.Add(('    pub const {0}: u32 = 0x{1:x};' -f $reg,$offset))
        foreach($name in @($masks.Keys|Where-Object {$_.StartsWith($reg+'__')}|Sort-Object)){$lines.Add(('    pub const {0}: u32 = 0x{1:x};' -f $name,$masks[$name]))}
        if($defaults.ContainsKey($key+'_DEFAULT')){$lines.Add(('    pub const {0}_DEFAULT: u32 = 0x{1:x};' -f $reg,$defaults[$key+'_DEFAULT']))}
    }
    $lines.Add('};')
}
$lines.Add(('pub const required_prefix: u64 = 0x{0:x};' -f [long]([Math]::Ceiling(($maxOffset+4)/4096)*4096)))
$text=($lines -join "`n")+"`n"
$target=Join-Path $unit 'src/memory_registers.zig'
if($Write){[IO.File]::WriteAllText($target,$text,[Text.UTF8Encoding]::new($false))}
elseif([IO.File]::ReadAllText($target).Replace("`r`n","`n") -cne $text){throw 'AMD memory register drift; regenerate Tools/VerifyMemory.ps1 -Write'}
Write-Host 'AMDGPU memory register identities, fields and IP segments verified.'
