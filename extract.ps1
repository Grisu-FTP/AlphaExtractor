# AlphaExtractor (native Windows PowerShell port of extract.sh)
# Pull sound assets out of a launcher's asset folder.
# Needs nothing but PowerShell 5.1+ (built into Windows).
#
# Run:  powershell -ExecutionPolicy Bypass -File .\extract.ps1
$ErrorActionPreference = 'Stop'

$OutBase = if ($env:OUT_BASE) { $env:OUT_BASE } else { (Get-Location).Path }

$OfficialDirs = @(
    (Join-Path $env:APPDATA '.minecraft')
)
$PrismDirs = @(
    (Join-Path $env:APPDATA 'PrismLauncher'),
    (Join-Path $env:LOCALAPPDATA 'PrismLauncher')
)

# Folders the Alpha ports use (everything else in the old index gets skipped)
$AlphaDirs = @('music', 'newmusic', 'newsound', 'sound', 'sound3', 'streaming')

function Die($msg) { Write-Host $msg -ForegroundColor Red; exit 1 }

# blank line + heading so each step stands out
function Step($msg) { Write-Host ''; Write-Host "--- $msg ---"; Write-Host '' }


# ---------- json helpers ----------
# The index files are simple enough that a regex does the job (same as extract.sh).

$ObjectRe = [regex]'"([^"]+)"\s*:\s*\{\s*"hash"\s*:\s*"([0-9a-fA-F]{40})"'
$AssetIdRe = [regex]'"assetIndex"\s*:\s*\{[^}]*?"id"\s*:\s*"([^"]+)"'

# index file -> list of @{ Path; Hash }
function Get-Objects($file) {
    $text = [System.IO.File]::ReadAllText($file)
    foreach ($m in $ObjectRe.Matches($text)) {
        [pscustomobject]@{ Path = $m.Groups[1].Value; Hash = $m.Groups[2].Value }
    }
}

# version json -> id of the asset index it uses
function Get-VersionAssetIndex($file) {
    $m = $AssetIdRe.Match([System.IO.File]::ReadAllText($file))
    if ($m.Success) { $m.Groups[1].Value } else { $null }
}

# like sort -V: 1.9 before 1.10
function Natural-Key($s) {
    [regex]::Replace($s, '\d+', { param($m) $m.Value.PadLeft(10, '0') })
}


# ---------- step 1: where are the assets? ----------

function Find-Launcher($dirs) {
    foreach ($d in $dirs) {
        if (Test-Path -LiteralPath (Join-Path $d 'assets\indexes') -PathType Container) { return $d }
    }
    return $null
}

function Choose-Source {
    $official = Find-Launcher $OfficialDirs
    $prism = Find-Launcher $PrismDirs

    Write-Host '=== AlphaExtractor ==='
    Step '1/3  Source'
    Write-Host "  1) Provide path to asset folder (needs 'indexes' and 'objects')"

    $roots = @($null)   # roots[n-1] = launcher dir for option n
    $n = 1
    if ($official) {
        $n++; $roots += $official
        Write-Host "  $n) Official Minecraft Launcher  ($official)"
    }
    if ($prism) {
        $n++; $roots += $prism
        Write-Host "  $n) Prism Launcher               ($prism)"
    }

    $choice = Read-Host "Choice [1-$n]"
    $c = 0
    if (-not [int]::TryParse($choice, [ref]$c) -or $c -lt 1 -or $c -gt $n) { Die 'Invalid choice.' }

    if ($c -eq 1) {
        $script:GameRoot = $null
        $p = (Read-Host 'Asset folder path').Trim().Trim('"').Trim("'")
        if ($p.StartsWith('~')) { $p = $HOME + $p.Substring(1) }
        $script:Assets = $p
    } else {
        $script:GameRoot = $roots[$c - 1]
        $script:Assets = Join-Path $script:GameRoot 'assets'
    }

    if (-not ((Test-Path -LiteralPath (Join-Path $script:Assets 'indexes') -PathType Container) -and
              (Test-Path -LiteralPath (Join-Path $script:Assets 'objects') -PathType Container))) {
        Die "'$($script:Assets)' needs both an 'indexes' and an 'objects' folder."
    }
}


# ---------- step 2: what versions are in there? ----------

function Find-Versions {
    $script:Count = @{}          # index id -> file count
    $newest = @{}                # index id -> newest version name
    $script:IndexOf = @{}        # menu name -> index id

    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:Assets 'indexes') -Filter '*.json' -File) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $script:Count[$id] = @(Get-Objects $f.FullName).Count
    }

    # Match versions to indexes. Going oldest -> newest means the newest
    # version ends up as the name for each index.
    if ($script:GameRoot) {
        $files = @()
        # Prism keeps them in meta\net.minecraft, the official launcher in versions\<ver>\
        $meta = Join-Path $script:GameRoot 'meta\net.minecraft'
        if (Test-Path -LiteralPath $meta) { $files += Get-ChildItem -LiteralPath $meta -Filter '*.json' -File }
        $vers = Join-Path $script:GameRoot 'versions'
        if (Test-Path -LiteralPath $vers) {
            foreach ($d in Get-ChildItem -LiteralPath $vers -Directory) {
                $files += Get-ChildItem -LiteralPath $d.FullName -Filter '*.json' -File
            }
        }
        $sorted = $files | ForEach-Object {
            [pscustomobject]@{ Ver = [System.IO.Path]::GetFileNameWithoutExtension($_.Name); File = $_.FullName }
        } | Sort-Object { Natural-Key $_.Ver }

        foreach ($v in $sorted) {
            $id = Get-VersionAssetIndex $v.File
            if ($id -and $script:Count.ContainsKey($id)) { $newest[$id] = $v.Ver }
        }
    }

    # All the a1.x / b1.x / 1.0-1.5 versions share one index, so show it once
    $modern = @()
    foreach ($id in $script:Count.Keys) {
        if ($id -eq 'pre-1.6') {
            $name = 'Pre 1.6'
        } else {
            $name = if ($newest.ContainsKey($id)) { $newest[$id] } else { $id }
            $modern += $name
        }
        $script:IndexOf[$name] = $id
    }

    $script:Names = @($modern | Sort-Object { Natural-Key $_ })
    if ($script:IndexOf.ContainsKey('Pre 1.6')) { $script:Names += 'Pre 1.6' }
    if ($script:Names.Count -eq 0) { Die 'No asset indexes found.' }
}

function Choose-Version {
    Step '2/3  Version'
    for ($i = 0; $i -lt $script:Names.Count; $i++) {
        $name = $script:Names[$i]
        '  {0,3}) {1,-16} ({2} files)' -f ($i + 1), $name, $script:Count[$script:IndexOf[$name]] | Write-Host
    }

    $pick = Read-Host "Extract which one? [1-$($script:Names.Count)]"
    $p = 0
    if (-not [int]::TryParse($pick, [ref]$p) -or $p -lt 1 -or $p -gt $script:Names.Count) { Die 'Invalid choice.' }

    $script:Version = $script:Names[$p - 1]
    $script:IndexId = $script:IndexOf[$script:Version]
}


# ---------- step 3: copy the files ----------

function Extract-Files {
    $indexFile = Join-Path $script:Assets "indexes\$($script:IndexId).json"
    $folder = "$($script:Version)Re"
    if ($script:Version -eq 'Pre 1.6') { $folder = 'p1.6Re' }

    Step '3/3  Extract'
    $out = Join-Path $OutBase $folder

    if (Test-Path -LiteralPath $out) {
        $yn = Read-Host "'$out' already exists, merge into it? [y/N]"
        if ($yn -notmatch '^[Yy]$') { Die 'Aborted.' }
    }
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $outFull = [System.IO.Path]::GetFullPath($out)

    $legacy = [regex]::IsMatch([System.IO.File]::ReadAllText($indexFile), '"map_to_resources"\s*:\s*true')
    $ok = 0; $missing = 0

    foreach ($o in Get-Objects $indexFile) {
        $rel = $o.Path
        # no icons or realms needed
        if ($rel -like 'icons/*' -or $rel -like 'realms/*') { continue }
        # everything left lives in minecraft/, so move it up a level
        if ($rel.StartsWith('minecraft/')) { $rel = $rel.Substring('minecraft/'.Length) }
        # old index also has junk, only keep the Alpha folders
        if ($legacy -and ($AlphaDirs -notcontains $rel.Split('/')[0])) { continue }
        # don't let a weird path escape the output folder
        $parts = $rel.Split('/')
        if ($rel.StartsWith('/') -or $rel -match '^[A-Za-z]:' -or $parts -contains '..' -or $parts -contains '') { continue }

        $src = Join-Path $script:Assets "objects\$($o.Hash.Substring(0, 2))\$($o.Hash)"
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { $missing++; continue }

        $dst = [System.IO.Path]::GetFullPath((Join-Path $out ($rel -replace '/', '\')))
        if (-not $dst.StartsWith($outFull, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $ok++
    }

    Write-Host "Extracted $ok files"
    Write-Host ''
    if ($missing -gt 0) { Write-Host "Warning: $missing files are in the index but missing from objects/" }
    Write-Host "Done -> $out"
}


# ---------- go ----------
Choose-Source
Find-Versions
Choose-Version
Extract-Files
