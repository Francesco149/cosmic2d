[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $StageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = [IO.Path]::GetFullPath($StageRoot)
$target = Join-Path $root "cosmic2d-editor.exe"
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "staged editor launcher is missing: $target"
}

$programs = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::Programs)
if ([string]::IsNullOrWhiteSpace($programs)) {
    throw "Windows did not provide a per-user Start Menu Programs directory"
}

$link = Join-Path $programs "cosmic2d editor.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($link)
$shortcut.TargetPath = $target
$shortcut.WorkingDirectory = $root
$shortcut.IconLocation = "$target,0"
$shortcut.Description = "Open the cosmic2d project picker and editor"
$shortcut.WindowStyle = 1
$shortcut.Save()

if (-not (Test-Path -LiteralPath $link -PathType Leaf)) {
    throw "Start Menu shortcut was not created: $link"
}

$saved = $shell.CreateShortcut($link)
if (-not ([IO.Path]::GetFullPath($saved.TargetPath) -ieq $target)) {
    throw "Start Menu shortcut points somewhere unexpected: $($saved.TargetPath)"
}
if (-not ([IO.Path]::GetFullPath($saved.WorkingDirectory) -ieq $root)) {
    throw "Start Menu shortcut has an unexpected working directory: $($saved.WorkingDirectory)"
}

Write-Output $link
