param([string]$ContainerPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$unit=[IO.Path]::GetFullPath('..',$PSScriptRoot)
$lockPath=Join-Path $unit 'src/firmware_lock.json'
$pin=Get-Content -Raw -LiteralPath $lockPath|ConvertFrom-Json
if($pin.schema -ne 3 -or $pin.firmware.Count -ne 24 -or $pin.metadata.Count -ne 2 -or $pin.revision -cne '2b8daaf611fbade74f26a5b58ec1defe6a02f5e0' -or $pin.raven2_rlc_revision -cne $pin.revision){throw 'Unsupported AMD firmware lock'}
foreach($entry in $pin.firmware){
    if($entry.family -cnotin @('picasso','raven2','shared') -or (($entry.family -ceq 'shared') -ne ($entry.role -ceq 'dmcu'))){throw 'Invalid AMD firmware family'}
    $revision=if($entry.family -ceq 'raven2' -and $entry.role -ceq 'rlc'){$pin.raven2_rlc_revision}else{$pin.revision}
    if($entry.upstream_revision -cne $revision){throw 'Firmware source revision differs from pinned bundle'}
}
$manifest=Get-Content -LiteralPath (Join-Path $unit 'module.R4MF')
$resources=@($manifest|Where-Object {$_.StartsWith('RESOURCE=')})
$expected=@('RESOURCE=AMD-FIRMWARE-LOCK.json:src/firmware_lock.json')
$whence=[IO.File]::ReadAllText((Join-Path $unit 'Firmware/WHENCE'))
$names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$bytes=(Get-Item $lockPath).Length
foreach($entry in @($pin.metadata)+@($pin.firmware)){
    if(!$names.Add($entry.resource) -or $entry.resource.Length -gt 63 -or $entry.bytes -le 0 -or $entry.bytes -gt 512KB){throw "Invalid firmware resource: $($entry.resource)"}
    $path=Join-Path $unit $entry.path
    if((Get-Item $path).Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $entry.sha256){throw "AMD firmware size/hash mismatch: $($entry.path)"}
    $bytes+=[long]([Math]::Ceiling($entry.bytes/16.0)*16)
    $expected+='RESOURCE='+$entry.resource+':'+$entry.path
    $sourceWhence=$whence
    if($entry.resource.EndsWith('.bin') -and !$sourceWhence.Contains('File: '+$entry.upstream_path)){throw "AMD WHENCE omits $($entry.upstream_path)"}
}
if($bytes -gt 4MB -or @($resources).Count -ne $expected.Count -or @(Compare-Object $resources $expected).Count){throw 'AMD resource set differs from the package lock'}
$version=@($manifest|Where-Object {$_.StartsWith('META=firmware.revision=')})
if($version.Count -ne 1 -or $version[0] -cne ('META=firmware.revision='+$pin.revision)){throw 'AMD firmware revision metadata mismatch'}
$label=@($manifest|Where-Object {$_.StartsWith('META=firmware.version=')})
if($label.Count -ne 1 -or $label[0] -cne ('META=firmware.version=linux-firmware-'+$pin.revision.Substring(0,12))){throw 'AMD firmware display label mismatch'}
$rlcVersion=@($manifest|Where-Object {$_.StartsWith('META=firmware.raven2_rlc_revision=')})
if($rlcVersion.Count -ne 1 -or $rlcVersion[0] -cne ('META=firmware.raven2_rlc_revision='+$pin.raven2_rlc_revision)){throw 'AMD RLC revision metadata mismatch'}
foreach($text in @($whence)){if(!$text.Contains('Licence: Redistributable. See LICENSE.amdgpu for details.')){throw 'AMD WHENCE license reference absent'}}
foreach($entry in $pin.metadata){
    $revision=$pin.revision
    if($entry.upstream_revision -cne $revision){throw 'Notice source revision differs from pinned bundle'}
}
Write-Host "AMDGPU firmware bundle: 24 original binaries, baseline WHENCE/license verified; baseline $($pin.revision), Raven2 RLC $($pin.raven2_rlc_revision); no GPU execution."

if($ContainerPath){
    # This is an exact-content audit after the canonical R4M0 builder/inspector.
    # Contract/ABI/R4M0.txt owns the section/resource layout.
    $image=[IO.File]::ReadAllBytes($ContainerPath)
    function Assert-Span([long]$Offset,[long]$Length){
        if($Offset -lt 0 -or $Length -lt 0 -or $Offset -gt $image.LongLength -or $Length -gt $image.LongLength-$Offset){throw 'R4M0 audit span outside container'}
    }
    function U32([long]$Offset){Assert-Span $Offset 4;return [BitConverter]::ToUInt32($image,[int]$Offset)}
    function U16([long]$Offset){Assert-Span $Offset 2;return [BitConverter]::ToUInt16($image,[int]$Offset)}
    if($image.Length -lt 64 -or [Text.Encoding]::ASCII.GetString($image,0,4) -cne 'R4M0' -or (U16 4) -ne 1 -or (U16 8) -ne 3){throw 'Not an R4D container'}
    $sectionOffset=U32 16;$sectionCount=U32 20
    if($sectionCount -gt 64){throw 'Too many R4M0 sections'}
    Assert-Span $sectionOffset ($sectionCount*32)
    $resourceOffset=-1L;$resourceBytes=0L
    for($i=0;$i -lt $sectionCount;$i++){
        $row=$sectionOffset+$i*32
        if([Text.Encoding]::ASCII.GetString($image,$row,8).TrimEnd([char]0) -cne '.rsrc'){continue}
        if($resourceOffset -ne -1 -or (U32 ($row+8)) -ne 0 -or (U32 ($row+24)) -ne 16){throw 'Ambiguous or allocated R4M0 resources'}
        $resourceOffset=[long](U32 ($row+12));$resourceBytes=[long](U32 ($row+16))
        Assert-Span $resourceOffset $resourceBytes
    }
    if($resourceOffset -lt 0 -or (U32 $resourceOffset) -ne $expected.Count){throw 'AMD R4M0 resource count differs from exact bundle'}
    $bound=@([pscustomobject]@{resource='AMD-FIRMWARE-LOCK.json';bytes=(Get-Item $lockPath).Length;sha256=(Get-FileHash $lockPath).Hash.ToLowerInvariant()})+@($pin.metadata)+@($pin.firmware)
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ranges=[Collections.Generic.List[object]]::new()
    $directoryEnd=4+$expected.Count*16
    for($i=0;$i -lt $expected.Count;$i++){
        $row=$resourceOffset+4+$i*16
        if((U16 $row) -ne 3 -or (U16 ($row+2)) -ne 0){throw 'Unexpected non-file AMD resource'}
        $nameOffset=[long](U32 ($row+4));$dataOffset=[long](U32 ($row+8));$length=[long](U32 ($row+12))
        if($nameOffset -lt $directoryEnd -or $nameOffset -ge $resourceBytes -or $dataOffset -lt $directoryEnd -or $dataOffset%16 -ne 0 -or
            $length -le 0 -or $dataOffset -gt $resourceBytes -or $length -gt $resourceBytes-$dataOffset){throw 'Bad AMD resource bounds'}
        $nameLength=0
        while($nameLength -lt 64 -and $nameOffset+$nameLength -lt $resourceBytes -and $image[$resourceOffset+$nameOffset+$nameLength] -ne 0){$nameLength++}
        if($nameLength -eq 0 -or $nameLength -gt 63 -or $nameOffset+$nameLength -ge $dataOffset){throw 'Invalid AMD resource name'}
        $name=[Text.Encoding]::ASCII.GetString($image,$resourceOffset+$nameOffset,$nameLength)
        if(!$seen.Add($name) -or $name -cne $bound[$i].resource -or $length -ne $bound[$i].bytes){throw 'AMD resource order/name/size differs from lock'}
        foreach($range in $ranges){if($dataOffset -lt $range.end -and $range.start -lt $dataOffset+$length){throw 'Overlapping AMD resource blobs'}}
        $ranges.Add([pscustomobject]@{start=$dataOffset;end=$dataOffset+$length})
        $data=[byte[]]::new($length);[Array]::Copy($image,$resourceOffset+$dataOffset,$data,0,$length)
        $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($data)).ToLowerInvariant()
        if($digest -cne $bound[$i].sha256){throw "Packed AMD resource hash mismatch: $name"}
    }
    Write-Host "AMDGPU R4M0 content audit: all $($expected.Count) non-allocated resources match their exact original bytes and package lock."
}
