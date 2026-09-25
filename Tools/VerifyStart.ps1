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
# SOC15 consumes IP_BASE.instance, not the similarly named numeric macros.
# MP1's numeric SEG0 macro differs by 0x200 dwords from the actual table.
$bases=@{}
$source=[IO.File]::ReadAllText((Join-Path $original 'drivers/gpu/drm/amd/include/vega10_ip_offset.h'))
foreach($m in [regex]::Matches($source,'static const struct IP_BASE __maybe_unused (\w+)_BASE\s*=\s*\{ \{ \{ \{([^}]+)')){
    $index=0
    foreach($v in $m.Groups[2].Value.Split(',')){
        $v=$v.Trim()
        if($v){$bases[$m.Groups[1].Value+'_BASE__INST0_SEG'+$index]=[Convert]::ToUInt32($v,$(if($v.StartsWith('0x')){16}else{10}));$index++}
    }
}
if($bases['MP1_BASE__INST0_SEG0'] -ne 0x16000){throw 'Unexpected runtime MP1 base'}
$sdmaSource=[IO.File]::ReadAllText((Join-Path $original 'drivers/gpu/drm/amd/amdgpu/sdma_v4_0.c'))
$sdmaTables=@{}
$sdmaNames=@('golden_settings_sdma_4_1','golden_settings_sdma_rv1','golden_settings_sdma_rv2')
foreach($name in $sdmaNames){
    $match=[regex]::Match($sdmaSource,'(?s)static const struct soc15_reg_golden '+$name+'\[\]\s*=\s*\{(.*?)\};')
    if(!$match.Success){throw "Missing original SDMA golden table $name"}
    $sdmaTables[$name]=@([regex]::Matches($match.Groups[1].Value,'SOC15_REG_GOLDEN_VALUE\(SDMA0, 0, mm(\w+), (0x[0-9a-f]+), (0x[0-9a-f]+)\)'))
    if($sdmaTables[$name].Count -eq 0){throw "Empty original SDMA golden table $name"}
}
$lines=[Collections.Generic.List[string]]::new()
$lines.Add('// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0')
$lines.Add('// Generated from unchanged AMD MIT originals; ThirdParty/Sources.json.')
$lines.Add('// Tools/VerifyStart.ps1. Runtime IP_BASE table offsets, in bytes.')
$maximum=0L
foreach($block in @(
    @('psp','MP0','mp/mp_10_0',@('MP0_SMN_C2PMSG_64','MP0_SMN_C2PMSG_67','MP0_SMN_C2PMSG_69','MP0_SMN_C2PMSG_70','MP0_SMN_C2PMSG_71')),
    @('smu','MP1','mp/mp_10_0',@('MP1_SMN_C2PMSG_66','MP1_SMN_C2PMSG_82','MP1_SMN_C2PMSG_90')),
    @('pwr','PWR','pwr/pwr_10_0',@('PWR_MISC_CNTL_STATUS')),
    @('gc','GC','gc/gc_9_1',@('CP_ME_CNTL','CP_MEC_CNTL','CP_INT_CNTL_RING0','GRBM_STATUS','GRBM_STATUS2','GRBM_SOFT_RESET','GRBM_GFX_INDEX','RLC_CNTL','RLC_SERDES_CU_MASTER_BUSY','RLC_SERDES_NONCU_MASTER_BUSY')),
    @('sdma','SDMA0','sdma0/sdma0_4_1',@('SDMA0_CLK_CTRL','SDMA0_POWER_CNTL','SDMA0_F32_CNTL','SDMA0_STATUS_REG','SDMA0_CNTL','SDMA0_SEM_WAIT_FAIL_TIMER_CNTL','SDMA0_GFX_RB_CNTL','SDMA0_GFX_IB_CNTL','SDMA0_GFX_RB_RPTR','SDMA0_GFX_RB_RPTR_HI','SDMA0_GFX_RB_WPTR','SDMA0_GFX_RB_WPTR_HI','SDMA0_GFX_RB_RPTR_ADDR_HI','SDMA0_GFX_RB_RPTR_ADDR_LO','SDMA0_GFX_RB_BASE','SDMA0_GFX_RB_BASE_HI','SDMA0_GFX_MINOR_PTR_UPDATE','SDMA0_GFX_DOORBELL','SDMA0_GFX_DOORBELL_OFFSET','SDMA0_GFX_RB_WPTR_POLL_ADDR_LO','SDMA0_GFX_RB_WPTR_POLL_ADDR_HI','SDMA0_GFX_RB_WPTR_POLL_CNTL')),
    @('nb','NBIO','nbio/nbio_7_0',@('BIF_SDMA0_DOORBELL_RANGE','GPU_HDP_FLUSH_REQ','GPU_HDP_FLUSH_DONE')),
    @('hdp','HDP','hdp/hdp_4_0',@('HDP_READ_CACHE_INVALIDATE'))
)){
    $offsets=Definitions ('include/asic_reg/'+$block[2]+'_offset.h')
    $masks=Definitions ('include/asic_reg/'+$block[2]+'_sh_mask.h')
    $lines.Add('pub const '+$block[0]+' = struct {')
    $registers=@($block[3])
    if($block[0] -eq 'sdma'){
        foreach($name in $sdmaNames){foreach($entry in $sdmaTables[$name]){$registers+=$entry.Groups[1].Value}}
        $registers=@($registers | Select-Object -Unique)
    }
    foreach($reg in $registers){
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
    if($block[0] -eq 'sdma'){
        $lines.Add('    pub const Golden = struct { address: u32, clear: u32, set: u32 };')
        foreach($name in $sdmaNames){
            $lines.Add('    pub const '+$name+' = [_]Golden{')
            foreach($entry in $sdmaTables[$name]){
                $lines.Add(('        .{{ .address = {0}, .clear = {1}, .set = {2} }},' -f $entry.Groups[1].Value,$entry.Groups[2].Value,$entry.Groups[3].Value))
            }
            $lines.Add('    };')
        }
    }
    $lines.Add('};')
}
$offsets=Definitions 'include/asic_reg/dcn/dcn_1_0_offset.h'
$masks=Definitions 'include/asic_reg/dcn/dcn_1_0_sh_mask.h'
$lines.Add('pub const dc = struct {')
foreach($pair in @(
    @('hubp_cntl','HUBP{0}_DCHUBP_CNTL'), @('format','HUBP{0}_DCSURF_SURFACE_CONFIG'),
    @('tiling','HUBP{0}_DCSURF_TILING_CONFIG'), @('pitch','HUBPREQ{0}_DCSURF_SURFACE_PITCH'),
    @('primary','HUBPREQ{0}_DCSURF_PRIMARY_SURFACE_ADDRESS'), @('primary_hi','HUBPREQ{0}_DCSURF_PRIMARY_SURFACE_ADDRESS_HIGH'),
    @('inuse','HUBPREQ{0}_DCSURF_SURFACE_EARLIEST_INUSE'), @('inuse_hi','HUBPREQ{0}_DCSURF_SURFACE_EARLIEST_INUSE_HIGH'),
    @('flip','HUBPREQ{0}_DCSURF_FLIP_CONTROL'), @('surface','HUBPREQ{0}_DCSURF_SURFACE_CONTROL'),
    @('top','MPCC{0}_MPCC_TOP_SEL'), @('bottom','MPCC{0}_MPCC_BOT_SEL'), @('opp','MPCC{0}_MPCC_OPP_ID'),
    @('otg','OTG{0}_OTG_MASTER_EN'), @('control','OTG{0}_OTG_CONTROL'),
    @('htotal','OTG{0}_OTG_H_TOTAL'), @('vtotal','OTG{0}_OTG_V_TOTAL'), @('blank','OTG{0}_OTG_BLANK_CONTROL')
)){
    $values=@()
    foreach($index in 0..3){
        $reg=$pair[1] -f $index
        $key='mm'+$reg
        if(!$offsets.ContainsKey($key) -or !$offsets.ContainsKey($key+'_BASE_IDX')){throw "Missing $key"}
        $base='DCN_BASE__INST0_SEG'+$offsets[$key+'_BASE_IDX']
        $offset=([long]$bases[$base]+$offsets[$key])*4
        $maximum=[Math]::Max($maximum,$offset)
        $values+=('0x{0:x}' -f $offset)
        if($index -eq 0){
            foreach($name in @($masks.Keys|Where-Object {$_.StartsWith($reg+'__')}|Sort-Object)){
                $lines.Add(('    pub const {0}: u32 = 0x{1:x};' -f $name,$masks[$name]))
            }
        }
    }
    $lines.Add('    pub const '+$pair[0]+' = [_]u32{'+($values -join ', ')+'};')
}
$lines.Add('};')
$defs=Definitions 'pm/powerplay/inc/rv_ppsmc.h'
foreach($key in @($defs.Keys|Where-Object {$_.StartsWith('PPSMC_')}|Sort-Object)){
    $lines.Add(('pub const {0}: u32 = 0x{1:x};' -f $key,$defs[$key]))
}
$defs=Definitions 'pm/powerplay/inc/smu10_driver_if.h'
$lines.Add(('pub const smu_driver_if: u32 = {0};' -f $defs['SMU10_DRIVER_IF_VERSION']))
$lines.Add(('pub const required_prefix: u64 = 0x{0:x};' -f [long]([Math]::Ceiling(($maximum+4)/4096)*4096)))
$text=($lines -join "`n")+"`n"
$target=Join-Path $unit 'src/start_registers.zig'
if($Write){[IO.File]::WriteAllText($target,$text,[Text.UTF8Encoding]::new($false))}
elseif([IO.File]::ReadAllText($target).Replace("`r`n","`n") -cne $text){throw 'AMD startup register drift; regenerate Tools/VerifyStart.ps1 -Write'}
Write-Host 'AMDGPU PSP10/SMU10 runtime bases, mailbox IDs and engine halt definitions verified.'
