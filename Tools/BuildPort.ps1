# Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference = 'Stop'
$unit = [IO.Path]::GetFullPath('..', $PSScriptRoot)
$libraries = $null
foreach ($line in Get-Content -LiteralPath (Join-Path $unit 'Settings.R4S')) {
    if ($line -match '^LIBRARIES_ROOT=(.+)$') { $libraries = [IO.Path]::GetFullPath($Matches[1].Replace('\', [IO.Path]::DirectorySeparatorChar), $unit) }
}
if (!$libraries) { throw 'Missing LIBRARIES_ROOT in Settings.R4S' }
& (Join-Path $libraries 'Shared/Native/BuildPortability.ps1') -UnitRoot $unit
