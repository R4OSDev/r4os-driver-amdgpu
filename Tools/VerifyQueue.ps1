param([switch]$Write)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$unit=[IO.Path]::GetFullPath('..',$PSScriptRoot)
$catalog=Get-Content -Raw (Join-Path $unit 'ThirdParty/Sources.json')|ConvertFrom-Json
$original=Join-Path $unit $catalog.original_root
function Definitions([string]$Path){
    $table=@{}
    $source=[IO.File]::ReadAllText((Join-Path $original ('drivers/gpu/drm/amd/'+$Path)))
    foreach($m in [regex]::Matches($source,'(?m)^#define\s+(\w+)\s+(0x[0-9a-fA-F]+|[0-9]+)(?:[uUlL]*)(?:\s|$)')){
        $s=$m.Groups[2].Value
        $table[$m.Groups[1].Value]=[Convert]::ToUInt32($s,$(if($s.StartsWith('0x')){16}else{10}))
    }
    foreach($m in [regex]::Matches($source,'(?m)^\s*(\w+)\s*=\s*(0x[0-9a-fA-F]+|[0-9]+)\s*,')){
        $s=$m.Groups[2].Value
        $table[$m.Groups[1].Value]=[Convert]::ToUInt32($s,$(if($s.StartsWith('0x')){16}else{10}))
    }
    return $table
}
$bases=Definitions 'include/vega10_ip_offset.h'
$lines=[Collections.Generic.List[string]]::new()
$lines.Add('// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0')
$lines.Add('// Generated from unchanged AMD MIT originals; ThirdParty/Sources.json.')
$lines.Add('// Tools/VerifyQueue.ps1. Register offsets in bytes; doorbells in dwords.')
$maximum=0L
foreach($block in @(
    @('ih','OSSSYS','oss/osssys_4_0',@('IH_RB_BASE','IH_RB_BASE_HI','IH_RB_CNTL','IH_RB_RPTR','IH_RB_WPTR','IH_RB_WPTR_ADDR_LO','IH_RB_WPTR_ADDR_HI','IH_DOORBELL_RPTR','IH_RB_CNTL_RING1','IH_RB_CNTL_RING2')),
    @('nb','NBIO','nbio/nbio_7_0',@('INTERRUPT_CNTL','INTERRUPT_CNTL2','BIF_IH_DOORBELL_RANGE','RCC_DOORBELL_APER_EN'))
)){
    $offsets=Definitions ('include/asic_reg/'+$block[2]+'_offset.h')
    $masks=Definitions ('include/asic_reg/'+$block[2]+'_sh_mask.h')
    $lines.Add('pub const '+$block[0]+' = struct {')
    foreach($reg in $block[3]){
        $key='mm'+$reg
        if(!$offsets.ContainsKey($key) -or !$offsets.ContainsKey($key+'_BASE_IDX')){throw "Missing $key"}
        $base=$block[1]+'_BASE__INST0_SEG'+$offsets[$key+'_BASE_IDX']
        if(!$bases.ContainsKey($base)){throw "Missing $base"}
        $offset=([long]$bases[$base]+$offsets[$key])*4
        $maximum=[Math]::Max($maximum,$offset)
        $lines.Add(('    pub const {0}: u32 = 0x{1:x};' -f $reg,$offset))
        foreach($name in @($masks.Keys|Where-Object {$_.StartsWith($reg+'__')}|Sort-Object)){
            $lines.Add(('    pub const {0}: u32 = 0x{1:x};' -f $name,$masks[$name]))
        }
    }
    $lines.Add('};')
}
$bells=Definitions 'amdgpu/amdgpu_doorbell.h'
foreach($pair in @(@('ih','IH'),@('gfx','GFX_RING0'),@('compute','MEC_RING0'),@('sdma','sDMA_ENGINE0'))){
    $key='AMDGPU_DOORBELL64_'+$pair[1]
    if(!$bells.ContainsKey($key)){throw "Missing $key"}
    $lines.Add(('pub const {0}_doorbell: u32 = 0x{1:x};' -f $pair[0],($bells[$key]*2)))
}
foreach($block in @(
    @('client','include/soc15_ih_clientid.h','SOC15_IH_CLIENTID_',@('IH','SDMA0','SDMA1','VMC','GRBM_CP','UTCL2')),
    @('gfx','include/ivsrcid/gfx/irqsrcs_gfx_9_0.h','GFX_9_0__SRCID__',@('CP_EOP_INTERRUPT','CP_PRIV_REG_FAULT','CP_PRIV_INSTR_FAULT','CP_ECC_ERROR','CP_FUE_ERROR')),
    @('sdma','include/ivsrcid/sdma0/irqsrcs_sdma0_4_0.h','SDMA0_4_0__SRCID__',@('SDMA_TRAP'))
)){
    $defs=Definitions $block[1]
    foreach($key in $block[3]){
        $name=$block[2]+$key
        if(!$defs.ContainsKey($name)){throw "Missing $name"}
        $lines.Add(('pub const {0}_{1}: u8 = 0x{2:x};' -f $block[0],$key,$defs[$name]))
    }
}
$lines.Add(('pub const required_prefix: u64 = 0x{0:x};' -f [long]([Math]::Ceiling(($maximum+4)/4096)*4096)))
$text=($lines -join "`n")+"`n"
$target=Join-Path $unit 'src/queue_registers.zig'
if($Write){[IO.File]::WriteAllText($target,$text,[Text.UTF8Encoding]::new($false))}
elseif([IO.File]::ReadAllText($target).Replace("`r`n","`n") -cne $text){throw 'AMD queue register drift; regenerate Tools/VerifyQueue.ps1 -Write'}
Write-Host 'AMDGPU IH, NBIO, doorbell and interrupt source definitions verified.'
