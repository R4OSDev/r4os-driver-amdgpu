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
$offsets=Definitions 'include/asic_reg/vcn/vcn_1_0_offset.h'
$supplement=Definitions 'amdgpu/vcn_v1_0.c'
foreach($name in $supplement.Keys){$offsets[$name]=$supplement[$name]}
$masks=Definitions 'include/asic_reg/vcn/vcn_1_0_sh_mask.h'
$lines=[Collections.Generic.List[string]]::new()
$lines.Add('// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0')
$lines.Add('// Generated from unchanged AMD MIT originals; ThirdParty/Sources.json.')
$lines.Add('// Tools/VerifyMedia.ps1; MMIO offsets in bytes.')
$maximum=0L
foreach($reg in @('UVD_REG_XX_MASK_1_0','UVD_RBC_XX_IB_REG_CHECK_1_0','JPEG_CGC_CTRL','JPEG_CGC_GATE','UVD_CGC_CTRL','UVD_CGC_GATE','UVD_CONTEXT_ID','UVD_CONTEXT_ID2','UVD_DPG_LMA_CTL','UVD_DPG_LMA_DATA','UVD_DPG_LMA_MASK','UVD_DPG_PAUSE','UVD_GPCOM_VCPU_CMD','UVD_GPCOM_VCPU_DATA0','UVD_GPCOM_VCPU_DATA1','UVD_GP_SCRATCH8','UVD_JPEG_ADDR_CONFIG','UVD_JPEG_GPCOM_CMD','UVD_JPEG_GPCOM_DATA0','UVD_JPEG_GPCOM_DATA1','UVD_JPEG_PITCH','UVD_JPEG_UV_ADDR_CONFIG','UVD_JRBC_EXTERNAL_REG_BASE','UVD_JRBC_IB_SIZE','UVD_JRBC_RB_CNTL','UVD_JRBC_RB_COND_RD_TIMER','UVD_JRBC_RB_REF_DATA','UVD_JRBC_RB_RPTR','UVD_JRBC_RB_WPTR','UVD_JRBC_STATUS','UVD_LMI_CTRL','UVD_LMI_CTRL2','UVD_LMI_JPEG_VMID','UVD_LMI_JRBC_IB_64BIT_BAR_HIGH','UVD_LMI_JRBC_IB_64BIT_BAR_LOW','UVD_LMI_JRBC_IB_VMID','UVD_LMI_JRBC_RB_64BIT_BAR_HIGH','UVD_LMI_JRBC_RB_64BIT_BAR_LOW','UVD_LMI_JRBC_RB_MEM_RD_64BIT_BAR_HIGH','UVD_LMI_JRBC_RB_MEM_RD_64BIT_BAR_LOW','UVD_LMI_JRBC_RB_MEM_WR_64BIT_BAR_HIGH','UVD_LMI_JRBC_RB_MEM_WR_64BIT_BAR_LOW','UVD_LMI_JRBC_RB_VMID','UVD_LMI_RBC_IB_64BIT_BAR_HIGH','UVD_LMI_RBC_IB_64BIT_BAR_LOW','UVD_LMI_RBC_IB_VMID','UVD_LMI_RBC_RB_64BIT_BAR_HIGH','UVD_LMI_RBC_RB_64BIT_BAR_LOW','UVD_LMI_STATUS','UVD_LMI_SWAP_CNTL','UVD_LMI_VCPU_CACHE1_64BIT_BAR_HIGH','UVD_LMI_VCPU_CACHE1_64BIT_BAR_LOW','UVD_LMI_VCPU_CACHE2_64BIT_BAR_HIGH','UVD_LMI_VCPU_CACHE2_64BIT_BAR_LOW','UVD_LMI_VCPU_CACHE_64BIT_BAR_HIGH','UVD_LMI_VCPU_CACHE_64BIT_BAR_LOW','UVD_MASTINT_EN','UVD_MIF_CURR_ADDR_CONFIG','UVD_MIF_CURR_UV_ADDR_CONFIG','UVD_MIF_RECON1_ADDR_CONFIG','UVD_MIF_RECON1_UV_ADDR_CONFIG','UVD_MIF_REF_ADDR_CONFIG','UVD_MIF_REF_UV_ADDR_CONFIG','UVD_MPC_CNTL','UVD_MPC_SET_MUX','UVD_MPC_SET_MUXA0','UVD_MPC_SET_MUXB0','UVD_NO_OP','UVD_PGFSM_CONFIG','UVD_PGFSM_STATUS','UVD_POWER_STATUS','UVD_RBC_IB_SIZE','UVD_RBC_RB_CNTL','UVD_RBC_RB_RPTR','UVD_RBC_RB_RPTR_ADDR','UVD_RBC_RB_WPTR','UVD_RBC_RB_WPTR_CNTL','UVD_RB_BASE_HI','UVD_RB_BASE_HI2','UVD_RB_BASE_HI3','UVD_RB_BASE_HI4','UVD_RB_BASE_LO','UVD_RB_BASE_LO2','UVD_RB_BASE_LO3','UVD_RB_BASE_LO4','UVD_RB_RPTR','UVD_RB_RPTR2','UVD_RB_RPTR3','UVD_RB_RPTR4','UVD_RB_SIZE','UVD_RB_SIZE2','UVD_RB_SIZE3','UVD_RB_SIZE4','UVD_RB_WPTR','UVD_RB_WPTR2','UVD_RB_WPTR3','UVD_RB_WPTR4','UVD_SCRATCH2','UVD_SCRATCH9','UVD_SOFT_RESET','UVD_STATUS','UVD_SUVD_CGC_CTRL','UVD_SUVD_CGC_GATE','UVD_SYS_INT_EN','UVD_UDEC_ADDR_CONFIG','UVD_UDEC_DBW_ADDR_CONFIG','UVD_UDEC_DBW_UV_ADDR_CONFIG','UVD_UDEC_DB_ADDR_CONFIG','UVD_VCPU_CACHE_OFFSET0','UVD_VCPU_CACHE_OFFSET1','UVD_VCPU_CACHE_OFFSET2','UVD_VCPU_CACHE_SIZE0','UVD_VCPU_CACHE_SIZE1','UVD_VCPU_CACHE_SIZE2','UVD_VCPU_CNTL')){
    $key='mm'+$reg
    if(!$offsets.ContainsKey($key)){throw "Missing $key"}
    $base='UVD_BASE__INST0_SEG'+$offsets[$key+'_BASE_IDX']
    $offset=([long]$bases[$base]+$offsets[$key])*4
    $maximum=[Math]::Max($maximum,$offset)
    $lines.Add(('pub const {0}: u32 = 0x{1:x};' -f $reg,$offset))
    foreach($name in @($masks.Keys|Where-Object {$_.StartsWith($reg+'__')}|Sort-Object)){
        $lines.Add(('pub const {0}: u32 = 0x{1:x};' -f $name,$masks[$name]))
    }
}
$lines.Add(('pub const required_prefix: u64 = 0x{0:x};' -f [long]([Math]::Ceiling(($maximum+4)/4096)*4096)))
$text=($lines -join "`n")+"`n"
$target=Join-Path $unit 'src/vcn_registers.zig'
if($Write){[IO.File]::WriteAllText($target,$text,[Text.UTF8Encoding]::new($false))}
elseif([IO.File]::ReadAllText($target).Replace("`r`n","`n") -cne $text){throw 'VCN1 register drift; run VerifyMedia.ps1 -Write'}
Write-Host 'AMDGPU VCN1 register definitions verified.'
