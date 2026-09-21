param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$unit=[IO.Path]::GetFullPath('..',$PSScriptRoot)
$catalog=Get-Content -Raw (Join-Path $unit 'ThirdParty/Sources.json')|ConvertFrom-Json
$original=Join-Path $unit $catalog.original_root
$sections=[Collections.Generic.List[string]]::new()
$sections.Add("AMDGPU original AMD MIT source notices`nLinux $($catalog.upstream_version), SHA256 identities in ThirdParty/Sources.json.`nNo third-party code is relicensed.`n")
foreach($entry in $catalog.files){
    $path=Join-Path $original $entry.path
    if((Get-FileHash $path).Hash.ToLowerInvariant() -cne $entry.sha256){throw "AMD source drift: $($entry.path)"}
    $source=[IO.File]::ReadAllText($path)
    $notice=@([regex]::Matches($source,'(?s)/\*.*?\*/')|Where-Object {$_.Value.Contains('Permission is hereby granted')})
    if($notice.Count -ne 1){throw "AMD original notice is ambiguous: $($entry.path)"}
    $sections.Add($entry.path+"`nSHA256 "+$entry.sha256+"`n"+$notice[0].Value.Replace("`r`n","`n")+"`n")
}
[IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'AMDGPU-SOURCE-NOTICES.txt'),($sections -join "`n"),[Text.UTF8Encoding]::new($true))
[IO.File]::Copy((Join-Path $unit 'Firmware/LICENSES/LICENSE.amdgpu'),(Join-Path $OutputDirectory 'AMD-FIRMWARE-LICENSE.txt'),$true)
[IO.File]::Copy((Join-Path $unit 'Firmware/WHENCE'),(Join-Path $OutputDirectory 'AMD-FIRMWARE-WHENCE.txt'),$true)
Write-Host 'AMD original firmware license, WHENCE and full source notices exported.'
