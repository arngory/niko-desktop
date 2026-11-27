<#
.SYNOPSIS
  Registers URL protocol handlers for Niko Desktop in HKCU (no UAC required).
  By default only registers `niko://` to avoid taking over third-party `sn://` or `clash://` handlers.
.PARAMETER ExecutablePath
  Full path to niko.exe (defaults to niko.exe next to this script or in the parent directory).
.PARAMETER IncludeThirdPartySchemes
  Opt-in to also register `sn://` and `clash://` if not already owned by another application.
.PARAMETER Force
  Overwrite existing `sn://` or `clash://` handlers even if owned by another application.
.PARAMETER Unregister
  Removes HKCU URL protocol handler registrations owned by this Niko executable.
#>
[CmdletBinding()]
param(
    [string]$ExecutablePath = "",
    [switch]$IncludeThirdPartySchemes,
    [switch]$Force,
    [switch]$Unregister
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $here = Join-Path $PSScriptRoot "niko.exe"
    $parent = Join-Path (Split-Path -Parent $PSScriptRoot) "niko.exe"
    if (Test-Path $here) {
        $ExecutablePath = (Resolve-Path $here).Path
    } elseif (Test-Path $parent) {
        $ExecutablePath = (Resolve-Path $parent).Path
    } else {
        throw "Provide -ExecutablePath pointing to niko.exe"
    }
}

$resolvedExe = (Resolve-Path $ExecutablePath).Path
# Use `--url "%1"` so Windows launchers cannot inject arbitrary CLI flags into niko.exe.
$command = "`"$resolvedExe`" --url `"%1`""

function Test-OwnedByUs([string]$Scheme) {
    $cmdPath = "HKCU:\Software\Classes\$Scheme\shell\open\command"
    if (-not (Test-Path $cmdPath)) {
        return $false
    }
    $val = (Get-ItemProperty -Path $cmdPath -Name "(Default)" -ErrorAction SilentlyContinue).'(Default)'
    if ([string]::IsNullOrWhiteSpace($val)) {
        return $false
    }
    return $val.StartsWith("`"$resolvedExe`"", [System.StringComparison]::OrdinalIgnoreCase)
}

$schemes = @("niko", "rcinv1", "rcinv2", "rcinv3")
if ($IncludeThirdPartySchemes -or $Unregister) {
    $schemes += @("sn", "clash", "hiddify", "sing-box", "v2rayng", "anytls", "naive+https", "naive+quic")
}

if ($Unregister) {
    $removed = @()
    foreach ($scheme in $schemes) {
        $keyPath = "HKCU:\Software\Classes\$scheme"
        if ((Test-Path $keyPath) -and (Test-OwnedByUs $scheme)) {
            Remove-Item -Path $keyPath -Recurse -Force
            $removed += $scheme
        }
    }
    Write-Host "Unregistered Niko-owned URL schemes: $($removed -join ', ')"
    exit 0
}

$registered = @()
foreach ($scheme in $schemes) {
    $base = "HKCU:\Software\Classes\$scheme"
    if (($scheme -ne "niko") -and (Test-Path "$base\shell\open\command") -and (-not (Test-OwnedByUs $scheme)) -and (-not $Force)) {
        Write-Warning "Skipping ${scheme}:// because it is already owned by another application (pass -Force to override)."
        continue
    }
    New-Item -Path "$base\shell\open\command" -Force | Out-Null
    Set-ItemProperty -Path $base -Name "(Default)" -Value "URL:Niko $scheme Protocol"
    Set-ItemProperty -Path $base -Name "URL Protocol" -Value ""
    Set-ItemProperty -Path "$base\shell\open\command" -Name "(Default)" -Value $command
    $registered += $scheme
}

Write-Host "Registered HKCU URL schemes ($($registered -join ', ')) -> $resolvedExe"
