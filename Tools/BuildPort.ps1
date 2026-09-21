# Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
param([string]$OutputRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$unit = [IO.Path]::GetFullPath('..', $PSScriptRoot)
$libraries = $null
foreach ($line in Get-Content -LiteralPath (Join-Path $unit 'Settings.R4S')) {
    if ($line -match '^LIBRARIES_ROOT=(.+)$') { $libraries = [IO.Path]::GetFullPath($Matches[1].Replace('\', [IO.Path]::DirectorySeparatorChar), $unit) }
}
if (!$libraries) { throw 'Missing LIBRARIES_ROOT in Settings.R4S' }
& (Join-Path $libraries 'Shared/Native/BuildPortability.ps1') -UnitRoot $unit
$settings = @{}
foreach ($line in Get-Content (Join-Path $libraries 'Settings.R4S')) {
    if ($line -match '^([A-Z_]+)=(.+)$') { $settings[$Matches[1]] = $Matches[2] }
}
$workspace = [IO.Path]::GetFullPath($settings.WORKSPACE_ROOT.Replace('\','/'), $libraries)
$artifacts = [IO.Path]::GetFullPath($settings.ARTIFACTS_ROOT.Replace('\','/'), $workspace)
$hostName = if ($IsWindows) { 'Windows-x64' } else { 'Linux-x64' }
$native = Join-Path $artifacts "Native/AMDGPU/$hostName/DCN1-7.2.4"
$record = Get-Content -Raw (Join-Path $native 'portability.json') | ConvertFrom-Json
if ($record.objects.Count -ne 26) { throw 'Incomplete DCN1 source closure.' }
$output = if ($OutputRoot) { [IO.Path]::GetFullPath($OutputRoot, $workspace) } else { Join-Path $native 'Archives' }
[IO.Directory]::CreateDirectory($output) | Out-Null
$ar = (Get-Command $(if ($IsWindows) { 'llvm-ar.exe' } else { 'llvm-ar-19' }) -CommandType Application | Select-Object -First 1).Source
$nm = (Get-Command $(if ($IsWindows) { 'llvm-nm.exe' } else { 'llvm-nm-19' }) -CommandType Application | Select-Object -First 1).Source
function Archive([string]$Name, [string[]]$Files) {
    $path = Join-Path $output $Name
    [IO.File]::Delete($path)
    $response = $path + '.rsp'
    [IO.File]::WriteAllLines($response, @(@('rcsD', $path) + $Files | ForEach-Object { '"' + $_.Replace('\','\\').Replace('"','\"') + '"' }), [Text.UTF8Encoding]::new($false))
    & $ar ('@' + $response)
    if ($LASTEXITCODE) { throw "DCN1 archive failed: $Name" }
}
Archive 'AMDGPU-DCN1.a' @($record.objects | ForEach-Object { Join-Path $native $_.object })
if ($IsWindows) {
    $clang = (Get-Command 'clang.exe' -CommandType Application | Select-Object -First 1).Source
    $hostObjects = @(foreach ($object in $record.objects) {
        $arguments = [Collections.Generic.List[string]]::new()
        foreach ($argument in $object.compiler_arguments) { $arguments.Add([string]$argument) }
        $target = $arguments.IndexOf('-target'); $destination = $arguments.IndexOf('-o'); $dependency = $arguments.IndexOf('-MF')
        if ($target -lt 0 -or $destination -lt 0 -or $dependency -lt 0) { throw 'Incomplete DCN compiler arguments.' }
        $path = Join-Path $output ($object.name + '.obj')
        $arguments[$target+1] = 'x86_64-w64-windows-gnu'; $arguments[$destination+1] = $path; $arguments[$dependency+1] = $path + '.d'
        $response = $path + '.rsp'
        [IO.File]::WriteAllLines($response, @($arguments | ForEach-Object { '"' + $_.Replace('\','\\').Replace('"','\"') + '"' }), [Text.UTF8Encoding]::new($false))
        & $clang ('@' + $response)
        if ($LASTEXITCODE) { throw "Windows host DCN compilation failed: $($object.name)" }
        $path
    })
    Archive 'AMDGPU-DCN1-Host.a' $hostObjects
} else { Copy-Item (Join-Path $output 'AMDGPU-DCN1.a') (Join-Path $output 'AMDGPU-DCN1-Host.a') -Force }
$symbols = @(& $nm --defined-only (Join-Path $output 'AMDGPU-DCN1.a'))
if ($LASTEXITCODE) { throw 'Cannot inspect DCN1 archive.' }
foreach ($symbol in @('r4dcn_prepare','r4dcn_program','r4dcn_quiesce','dcn_validate_bandwidth','dml1_rq_dlg_get_dlg_params','optc1_program_timing','hubp1_program_surface_flip_and_addr','hubbub1_program_watermarks')) {
    if (!($symbols | Where-Object { $_ -match ('\b' + [regex]::Escape($symbol) + '$') })) { throw "Missing DCN1 function: $symbol" }
}
[ordered]@{schema=1; module='AMDGPU'; upstream='7.2.4'; originals=23; bridge_units=3; native_record_sha256=(Get-FileHash (Join-Path $native 'portability.json')).Hash.ToLowerInvariant(); archives=@(foreach ($name in @('AMDGPU-DCN1.a','AMDGPU-DCN1-Host.a')) { [ordered]@{name=$name;sha256=(Get-FileHash (Join-Path $output $name)).Hash.ToLowerInvariant()} })} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $output 'archives.json') -Encoding utf8NoBOM
Write-Host 'AMDGPU: 23 original DCN1/DC/DML units and 3 private bridges archived for R4D and host.'
