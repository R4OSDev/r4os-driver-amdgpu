param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$unit=[IO.Path]::GetFullPath('..',$PSScriptRoot)
$catalog=Get-Content -Raw (Join-Path $unit 'ThirdParty/Sources.json')|ConvertFrom-Json
$original=Join-Path $unit $catalog.original_root
$sections=[Collections.Generic.List[string]]::new()
$sections.Add("AMDGPU original source notices`nLinux $($catalog.upstream_version), SHA256 identities in ThirdParty/Sources.json.`nNo third-party code is relicensed.`n")
foreach($entry in $catalog.files){
    $path=Join-Path $original $entry.path
    if((Get-FileHash $path).Hash.ToLowerInvariant() -cne $entry.sha256){throw "AMD source drift: $($entry.path)"}
    $source=[IO.File]::ReadAllText($path)
    $notice=@([regex]::Matches($source,'(?s)/\*.*?\*/')|Where-Object {$_.Value.Contains('Permission is hereby granted') -or $_.Value.Contains('Permission to use, copy, modify, distribute, and sell')})
    if($notice.Count -eq 1){ $text=$notice[0].Value }
    elseif($notice.Count -eq 0 -and $entry.license -ceq 'MIT (SPDX; LICENSES/preferred/MIT)') {
        $prefix=[regex]::Match($source,'\A(?:\s*(?:/\*[\s\S]*?\*/|//[^\r\n]*))+').Value
        if($prefix -notmatch 'SPDX-License-Identifier:\s*MIT\b'){throw "Missing original MIT identifier: $($entry.path)"}
        $text=$prefix
    } else {throw "AMD original notice is ambiguous: $($entry.path)"}
    $sections.Add($entry.path+"`nSHA256 "+$entry.sha256+"`n"+$text.Replace("`r`n","`n")+"`n")
}
foreach($entry in $catalog.additional_licenses) {
    $path=Join-Path $unit $entry.path
    if((Get-FileHash $path).Hash.ToLowerInvariant() -cne $entry.sha256){throw "AMD license drift: $($entry.path)"}
    $sections.Add($entry.path+"`n"+[IO.File]::ReadAllText($path))
}
[IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'AMDGPU-SOURCE-NOTICES.txt'),($sections -join "`n"),[Text.UTF8Encoding]::new($true))
[IO.File]::Copy((Join-Path $unit 'Firmware/LICENSES/LICENSE.amdgpu'),(Join-Path $OutputDirectory 'AMD-FIRMWARE-LICENSE.txt'),$true)
[IO.File]::Copy((Join-Path $unit 'Firmware/WHENCE'),(Join-Path $OutputDirectory 'AMD-FIRMWARE-WHENCE.txt'),$true)
Write-Host 'AMD original firmware license, WHENCE and full source notices exported.'
