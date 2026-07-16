[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $EditorArchive,
    [Parameter(Mandatory = $true)]
    [string] $PlayArchive,
    [string] $ScratchRoot = (Join-Path ([IO.Path]::GetTempPath()) ("cosmic2d clean path π " + [Guid]::NewGuid().ToString("N")))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Test-ArchiveChecksum([string] $Archive) {
    $sidecar = "$Archive.sha256"
    Assert-True (Test-Path -LiteralPath $sidecar -PathType Leaf) `
        "missing archive checksum: $sidecar"
    $line = ([IO.File]::ReadAllText($sidecar)).Trim()
    Assert-True ($line -match '^([0-9a-fA-F]{64})  (.+)$') `
        "malformed archive checksum: $sidecar"
    $expected = $Matches[1].ToLowerInvariant()
    $named = $Matches[2]
    Assert-True ($named -ceq (Split-Path -Leaf $Archive)) `
        "archive checksum must use a relative basename: $sidecar"
    $actual = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($actual -ceq $expected) "archive checksum mismatch: $Archive"
}

function Resolve-SingleRoot([string] $Parent) {
    $roots = @(Get-ChildItem -LiteralPath $Parent -Directory)
    Assert-True ($roots.Count -eq 1) "archive must contain exactly one root folder: $Parent"
    return $roots[0].FullName
}

function Test-TreeChecksum([string] $Root) {
    $manifest = Join-Path $Root "SHA256SUMS"
    Assert-True (Test-Path -LiteralPath $manifest -PathType Leaf) `
        "release lacks SHA256SUMS: $Root"
    foreach ($line in [IO.File]::ReadLines($manifest)) {
        Assert-True ($line -match '^([0-9a-f]{64})  \./(.+)$') `
            "malformed SHA256SUMS line: $line"
        $expected = $Matches[1]
        $relative = $Matches[2].Replace('/', [IO.Path]::DirectorySeparatorChar)
        $path = Join-Path $Root $relative
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
            "SHA256SUMS names a missing file: $relative"
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-True ($actual -ceq $expected) "tree checksum mismatch: $relative"
    }
}

function Invoke-Cosmic(
    [string] $Exe,
    [string[]] $Arguments,
    [string] $WorkingDirectory
) {
    Assert-True (Test-Path -LiteralPath $Exe -PathType Leaf) "missing launcher: $Exe"
    $process = Start-Process -FilePath $Exe -ArgumentList $Arguments `
        -WorkingDirectory $WorkingDirectory -NoNewWindow -Wait -PassThru
    Assert-True ($process.ExitCode -eq 0) `
        "launcher exited $($process.ExitCode): $Exe $($Arguments -join ' ')"
}

function Protect-Tree([string] $Root, [string] $Sid) {
    # Do not deny generic W: it includes SYNCHRONIZE, which executable launch
    # also requests. Deny only mutation rights and let the inheritable root ACE
    # propagate; applying /T after denying writes would block our own traversal.
    $rule = "*$Sid`:(OI)(CI)(WD,AD,WEA,WA,DC)"
    & "$env:SystemRoot\System32\icacls.exe" $Root /deny $rule /Q | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "could not make release tree read-only: $Root"

    $probe = Join-Path $Root "write-probe"
    $denied = $false
    try {
        [IO.File]::WriteAllText($probe, "must fail")
    } catch [UnauthorizedAccessException] {
        $denied = $true
    }
    Assert-True $denied "current user could still write the protected release tree: $Root"
}

function Unprotect-Tree([string] $Root, [string] $Sid) {
    if (-not (Test-Path -LiteralPath $Root)) { return }
    & "$env:SystemRoot\System32\icacls.exe" $Root /remove:d "*$Sid" /Q | Out-Null
}

$EditorArchive = [IO.Path]::GetFullPath($EditorArchive)
$PlayArchive = [IO.Path]::GetFullPath($PlayArchive)
Assert-True ((Split-Path -Leaf $EditorArchive) -ceq "cosmic2d-windows.zip") `
    "expected the cosmic2d-windows.zip editor archive"
$playLeaf = Split-Path -Leaf $PlayArchive
Assert-True ($playLeaf -match '^(.+)-windows\.zip$') "expected a *-windows.zip play archive"
$game = $Matches[1]

$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$editorRoot = $null
$playRoot = $null
$protectedRoots = @()
$newLogs = @()

try {
    Test-ArchiveChecksum $EditorArchive
    Test-ArchiveChecksum $PlayArchive

    New-Item -ItemType Directory -Path $ScratchRoot | Out-Null
    $editorParent = Join-Path $ScratchRoot "editor archive α"
    $playParent = Join-Path $ScratchRoot "play archive λ"
    $outside = Join-Path $ScratchRoot "unrelated working directory Ω"
    New-Item -ItemType Directory -Path $editorParent, $playParent, $outside | Out-Null
    Expand-Archive -LiteralPath $EditorArchive -DestinationPath $editorParent
    Expand-Archive -LiteralPath $PlayArchive -DestinationPath $playParent
    $editorRoot = Resolve-SingleRoot $editorParent
    $playRoot = Resolve-SingleRoot $playParent

    Test-TreeChecksum $editorRoot
    Test-TreeChecksum $playRoot

    $editorFront = Join-Path $editorRoot "cosmic2d-editor.exe"
    $editorDemo = Join-Path $editorRoot "demo.exe"
    $editorConsole = Join-Path $editorRoot "bin\cosmic-console.exe"
    $playFront = Join-Path $playRoot "$game.exe"
    $playGame = Join-Path $playRoot "bin\$game.exe"
    $playEditor = Join-Path $playRoot "bin\cosmic2d-editor.exe"
    $playConsole = Join-Path $playRoot "bin\cosmic-console.exe"
    foreach ($path in @($editorFront, $editorDemo, $editorConsole, $playFront,
                        $playGame, $playEditor, $playConsole)) {
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "missing launcher: $path"
    }
    $playerReadme = [IO.File]::ReadAllText((Join-Path $playRoot "README.md"))
    foreach ($signature in @("# cosmic demo", "Version ``0.1``", "## Controls",
                              "## Credits", "## Licenses")) {
        Assert-True ($playerReadme.Contains($signature)) `
            "player README lacks project metadata: $signature"
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $playRoot "icon.png") -PathType Leaf) `
        "player bundle lacks its project icon"
    $playerIdentity = [Diagnostics.FileVersionInfo]::GetVersionInfo($playFront)
    Assert-True ($playerIdentity.FileDescription -ceq "cosmic demo") `
        "player launcher lacks the project title resource"
    Assert-True ($playerIdentity.ProductVersion -ceq "0.1") `
        "player launcher lacks the project version resource"

    # The project-branded root PE delegates to bin/<game>.exe and must preserve
    # native Unicode argv. PowerShell 5.1 treats a BOM-less UTF-8 script as the
    # active ANSI code page, so construct lambda by code point. The child sees
    # UTF-8 Lua source: correct forwarding makes its string exactly two bytes;
    # mojibake exits 23 and fails Invoke-Cosmic. Keep the expression space-free
    # because Start-Process joins ArgumentList elements into one command line.
    $lambda = [char]0x03bb
    $unicodeEval = "pal.quit((#('$lambda')==2)and(0)or(23))"
    Invoke-Cosmic $playFront @("--headless", "--frames", "1", "--eval",
        $unicodeEval) $outside

    $protectedRoots += $editorRoot
    Protect-Tree $editorRoot $sid
    $protectedRoots += $playRoot
    Protect-Tree $playRoot $sid

    $appData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::ApplicationData)
    $diagnostics = Join-Path $appData "cosmic2d\engine\diagnostics"
    foreach ($root in @($editorRoot, $playRoot)) {
        $prefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
        Assert-True (-not ([IO.Path]::GetFullPath($diagnostics).StartsWith(
            $prefix, [StringComparison]::OrdinalIgnoreCase))) `
            "diagnostics path is inside a release tree: $diagnostics"
    }
    $before = @{}
    if (Test-Path -LiteralPath $diagnostics) {
        Get-ChildItem -LiteralPath $diagnostics -Filter "process-*.log" -File |
            ForEach-Object { $before[$_.FullName] = $true }
    }

    # Every public GUI launcher plus the explicit diagnostic entrance boots
    # from a cwd unrelated to the extracted tree. Capped runs must stay quiet.
    Invoke-Cosmic $editorFront @("--headless", "--frames", "1") $outside
    Invoke-Cosmic $editorDemo @("--headless", "--frames", "1") $outside
    Invoke-Cosmic $editorConsole @("--headless", "--frames", "1") $outside
    Invoke-Cosmic $playFront @("--headless", "--frames", "1") $outside
    Invoke-Cosmic $playGame @("--headless", "--frames", "1") $outside
    Invoke-Cosmic $playEditor @("--headless", "--frames", "1") $outside
    Invoke-Cosmic $playConsole @("projects/$game", "--headless", "--frames", "1") $outside

    $afterCapped = @()
    if (Test-Path -LiteralPath $diagnostics) {
        $afterCapped = @(Get-ChildItem -LiteralPath $diagnostics `
            -Filter "process-*.log" -File |
            Where-Object { -not $before.ContainsKey($_.FullName) })
    }
    Assert-True ($afterCapped.Count -eq 0) "capped runs created interactive diagnostics"

    # Exercise the native console executable uncapped in both archive shapes.
    # The eval quits on frame one, leaving a flushed per-user process log.
    Invoke-Cosmic $editorConsole @("--headless", "--eval",
        "cm.main.request_quit()") $outside
    Invoke-Cosmic $playConsole @("projects/$game", "--headless", "--eval",
        "cm.main.request_quit()") $outside

    $newLogs = @(Get-ChildItem -LiteralPath $diagnostics -Filter "process-*.log" -File |
        Where-Object { -not $before.ContainsKey($_.FullName) })
    Assert-True ($newLogs.Count -eq 2) `
        "expected two external process logs, found $($newLogs.Count)"
    $logText = ($newLogs | ForEach-Object {
        [IO.File]::ReadAllText($_.FullName)
    }) -join "`n"
    Assert-True ($logText.Contains("booted projects/picker")) `
        "editor archive diagnostic log did not record the picker boot"
    Assert-True ($logText.Contains("booted projects/$game")) `
        "play archive diagnostic log did not record the game boot"

    Test-TreeChecksum $editorRoot
    Test-TreeChecksum $playRoot
    Write-Output "windows clean-machine matrix: PASS"
} finally {
    foreach ($root in $protectedRoots) { Unprotect-Tree $root $sid }
    foreach ($log in $newLogs) {
        Remove-Item -LiteralPath $log.FullName -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $ScratchRoot) {
        Remove-Item -LiteralPath $ScratchRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}
