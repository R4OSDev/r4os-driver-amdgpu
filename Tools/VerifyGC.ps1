param([switch]$Write)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$unit=[IO.Path]::GetFullPath('..',$PSScriptRoot)
$catalog=Get-Content -Raw (Join-Path $unit 'ThirdParty/Sources.json')|ConvertFrom-Json
$original=Join-Path $unit ($catalog.original_root+'/drivers/gpu/drm/amd')
function Definitions([string]$Relative){
    $table=@{}
    foreach($m in [regex]::Matches([IO.File]::ReadAllText((Join-Path $original $Relative)),'(?m)^#define\s+(\w+)\s+(0x[0-9a-fA-F]+|[0-9]+)(?:[uUlL]*)(?:\s|$)')){
        $s=$m.Groups[2].Value
        $table[$m.Groups[1].Value]=[Convert]::ToUInt32($s,$(if($s.StartsWith('0x')){16}else{10}))
    }
    return $table
}
$offsets=Definitions 'include/asic_reg/gc/gc_9_0_offset.h'
$masks=Definitions 'include/asic_reg/gc/gc_9_0_sh_mask.h'
$ip=[IO.File]::ReadAllText((Join-Path $original 'include/vega10_ip_offset.h'))
$m=[regex]::Match($ip,'static const struct IP_BASE __maybe_unused GC_BASE\s*=\s*\{ \{ \{ \{([^}]+)')
if(!$m.Success){throw 'GC runtime IP_BASE missing'}
$bases=@($m.Groups[1].Value.Split(',')|Where-Object {$_.Trim()}|ForEach-Object {[Convert]::ToUInt32($_.Trim(),16)})
$registers=@'
GRBM_GFX_CNTL GRBM_GFX_INDEX GRBM_CNTL GRBM_STATUS GRBM_STATUS2
CC_GC_SHADER_ARRAY_CONFIG GC_USER_SHADER_ARRAY_CONFIG CC_RB_BACKEND_DISABLE GC_USER_RB_BACKEND_DISABLE
SH_MEM_CONFIG SH_MEM_BASES GDS_VMID0_BASE GDS_VMID0_SIZE GDS_GWS_VMID0 GDS_OA_VMID0 GDS_COMPUTE_MAX_WAVE_ID
RLC_SAFE_MODE RLC_CGTT_MGCG_OVERRIDE RLC_MEM_SLP_CNTL CP_MEM_SLP_CNTL RLC_PG_DELAY RLC_PG_DELAY_2 RLC_PG_DELAY_3 RLC_AUTO_PG_CTRL
RLC_CNTL RLC_CGCG_CGLS_CTRL RLC_CGCG_CGLS_CTRL_3D RLC_SRM_CNTL RLC_CSIB_ADDR_LO RLC_CSIB_ADDR_HI RLC_CSIB_LENGTH
RLC_JUMP_TABLE_RESTORE RLC_PG_CNTL RLC_LB_CNTL RLC_SPM_MC_CNTL RLC_CP_SCHEDULERS
CP_ME_CNTL CP_MEC_CNTL CP_MAX_CONTEXT CP_DEVICE_ID CP_RB_WPTR_DELAY CP_RB_VMID
CP_RB0_CNTL CP_RB0_WPTR CP_RB0_WPTR_HI CP_RB0_RPTR CP_RB0_RPTR_ADDR CP_RB0_RPTR_ADDR_HI
CP_RB_WPTR_POLL_ADDR_LO CP_RB_WPTR_POLL_ADDR_HI CP_RB_WPTR_POLL_CNTL CP_RB0_BASE CP_RB0_BASE_HI
CP_RB_DOORBELL_CONTROL CP_RB_DOORBELL_RANGE_LOWER CP_RB_DOORBELL_RANGE_UPPER
CP_PQ_WPTR_POLL_CNTL CP_PQ_STATUS CP_MQD_BASE_ADDR CP_MQD_BASE_ADDR_HI CP_MQD_CONTROL
CP_HQD_EOP_BASE_ADDR CP_HQD_EOP_BASE_ADDR_HI CP_HQD_EOP_CONTROL CP_HQD_PQ_DOORBELL_CONTROL CP_HQD_ACTIVE
CP_HQD_DEQUEUE_REQUEST CP_HQD_PQ_RPTR CP_HQD_PQ_WPTR_LO CP_HQD_PQ_WPTR_HI CP_HQD_PQ_BASE CP_HQD_PQ_BASE_HI
CP_HQD_PQ_CONTROL CP_HQD_PQ_RPTR_REPORT_ADDR CP_HQD_PQ_RPTR_REPORT_ADDR_HI CP_HQD_PQ_WPTR_POLL_ADDR CP_HQD_PQ_WPTR_POLL_ADDR_HI
CP_HQD_VMID CP_HQD_PERSISTENT_STATE CP_HQD_IB_CONTROL CP_HQD_QUANTUM CP_HQD_PIPE_PRIORITY CP_HQD_QUEUE_PRIORITY CP_HQD_ERROR
CP_MEC_DOORBELL_RANGE_LOWER CP_MEC_DOORBELL_RANGE_UPPER CP_HQD_IQ_TIMER
CP_INT_CNTL_RING0 CP_INT_CNTL_RING1 CP_INT_CNTL_RING2 CP_ME1_PIPE0_INT_CNTL CP_ME1_PIPE1_INT_CNTL CP_ME1_PIPE2_INT_CNTL CP_ME1_PIPE3_INT_CNTL
VGT_INDEX_TYPE COMPUTE_TMPRING_SIZE SPI_TMPRING_SIZE COMPUTE_USER_DATA_0 COMPUTE_USER_DATA_1 COMPUTE_USER_DATA_15 PA_SC_GENERIC_SCISSOR_TL
'@ -split '\s+' | Where-Object {$_}
$source=[IO.File]::ReadAllText((Join-Path $original 'amdgpu/gfx_v9_0.c'))
$tables=@{}
foreach($name in @('golden_settings_gc_9_1','golden_settings_gc_9_1_rv1','golden_settings_gc_9_x_common')){
    $match=[regex]::Match($source,'(?s)static const struct soc15_reg_golden '+$name+'\[\]\s*=\s*\{(.*?)\};')
    if(!$match.Success){throw "Missing original golden table $name"}
    $entries=@([regex]::Matches($match.Groups[1].Value,'SOC15_REG_GOLDEN_VALUE\(GC, 0, mm(\w+), (0x[0-9a-f]+), (0x[0-9a-f]+)\)'))
    $tables[$name]=$entries
    foreach($entry in $entries){$registers+=$entry.Groups[1].Value}
}
$lines=[Collections.Generic.List[string]]::new()
$lines.Add('// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0')
$lines.Add('// Generated from pinned AMD MIT originals by Tools/VerifyGC.ps1; notices: ThirdParty/Sources.json.')
$maximum=0L
foreach($reg in @($registers|Sort-Object -Unique)){
    $key='mm'+$reg
    if(!$offsets.ContainsKey($key) -or !$offsets.ContainsKey($key+'_BASE_IDX')){throw "Missing $key"}
    $address=([long]$bases[$offsets[$key+'_BASE_IDX']]+$offsets[$key])*4
    $maximum=[Math]::Max($maximum,$address)
    $lines.Add(('pub const {0}: u32 = 0x{1:x};' -f $reg,$address))
    foreach($name in @($masks.Keys|Where-Object {$_.StartsWith($reg+'__')}|Sort-Object)){
        $lines.Add(('pub const {0}: u32 = 0x{1:x};' -f $name,$masks[$name]))
    }
}
$lines.Add('pub const Golden = struct { address: u32, clear: u32, set: u32 };')
foreach($name in @('golden_settings_gc_9_1','golden_settings_gc_9_1_rv1','golden_settings_gc_9_x_common')){
    $lines.Add('pub const '+$name+' = [_]Golden{')
    foreach($entry in $tables[$name]){
        $lines.Add(('    .{{ .address = {0}, .clear = {1}, .set = {2} }},' -f $entry.Groups[1].Value,$entry.Groups[2].Value,$entry.Groups[3].Value))
    }
    $lines.Add('};')
}
$lines.Add(('pub const required_prefix: u64 = 0x{0:x};' -f [long]([Math]::Ceiling(($maximum+4)/4096)*4096)))
$text=($lines -join "`n")+"`n"
$target=Join-Path $unit 'src/gc_registers.zig'
if($Write){[IO.File]::WriteAllText($target,$text,[Text.UTF8Encoding]::new($false))}
elseif([IO.File]::ReadAllText($target).Replace("`r`n","`n") -cne $text){throw 'GFX9 register drift; regenerate Tools/VerifyGC.ps1 -Write'}
Write-Host 'AMDGPU GC9.1 runtime offsets, fields and Picasso golden tables verified.'

& (Join-Path $PSScriptRoot "VerifyMedia.ps1")
