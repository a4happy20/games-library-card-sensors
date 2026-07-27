# Reads every RetroArch playlist (.lpl) and writes a JSON list of games for HA
#
# Art strategy: INDEX the thumbnails on disk, match each game by a normalized
# name, then COPY the matched file into your served www folder and emit a
# /local/... URL. This serves YOUR local art directly — so anything RetroArch
# can display (official titles, rom hacks, hand-added art) displays on the card.

# ---- EDIT THESE PATHS ----
$RetroArchExe = 'F:\Games\RetroArch\retroarch.exe'
$PlaylistDir  = 'F:\Games\RetroArch\playlists'
$ThumbnailDir = 'F:\Games\RetroArch\thumbnails'
$OutFile      = 'Y:\www\steam_games\retroarch_games.json'

# Where to publish thumbnails so HA can serve them.
#   $ServeDir     = a folder under Y:\www  (== HA /config/www)
#   $ServeUrlBase = the matching /local URL for that folder
$ServeDir     = 'Y:\www\steam_games\ra_thumbs'
$ServeUrlBase = '/local/steam_games/ra_thumbs'
# --------------------------------

# Normalize for matching: lowercase, drop all non-alphanumeric. Immune to
# RetroArch's char substitutions, spaces, punctuation and case.
function Get-Norm { param([string]$s) if (-not $s) { return '' } ($s.ToLower() -replace '[^a-z0-9]','') }

if (-not (Test-Path -LiteralPath $ServeDir)) { New-Item -ItemType Directory -Path $ServeDir -Force | Out-Null }

# ── Index every thumbnail on disk: normalized filename -> list of {sys,name,path} ──
$boxIdx  = @{}
$snapIdx = @{}
$titleIdx = @{}
if (Test-Path -LiteralPath $ThumbnailDir) {
    Get-ChildItem -LiteralPath $ThumbnailDir -Directory | ForEach-Object {
        $sys = $_.Name
        foreach ($pair in @(@{ dir = 'Named_Boxarts'; map = $boxIdx }, @{ dir = 'Named_Snaps'; map = $snapIdx }, @{ dir = 'Named_Titles'; map = $titleIdx })) {
            $d = Join-Path $_.FullName $pair.dir
            if (Test-Path -LiteralPath $d) {
                Get-ChildItem -LiteralPath $d -Filter *.png -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $nm   = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                    $norm = Get-Norm $nm
                    if ($norm) {
                        if (-not $pair.map.ContainsKey($norm)) {
                            $pair.map[$norm] = New-Object System.Collections.Generic.List[object]
                        }
                        $pair.map[$norm].Add([pscustomobject]@{ sys = $sys; name = $nm; path = $_.FullName })
                    }
                }
            }
        }
    }
}

# Pick the best on-disk match (prefer the game's own system on ties).
function Resolve-Thumb {
    param($Map, [string]$Norm, [string]$PreferSys)
    if (-not $Norm -or -not $Map.ContainsKey($Norm)) { return $null }
    $cands = $Map[$Norm]
    $pick  = $cands | Where-Object { (Get-Norm $_.sys) -eq (Get-Norm $PreferSys) } | Select-Object -First 1
    if (-not $pick) { $pick = $cands[0] }
    return $pick
}

# Copy a matched thumbnail into the served folder; return its /local URL.
# Dest name is pure alphanumeric (normsystem_normname[_snap].png) so the URL
# needs no encoding. Copies only when missing or the source is newer.
function Publish-Thumb {
    param($Pick, [string]$Suffix)
    if (-not $Pick) { return '' }
    $dest     = "$(Get-Norm $Pick.sys)_$(Get-Norm $Pick.name)$Suffix.png"
    $destPath = Join-Path $ServeDir $dest
    try {
        $need = $true
        if (Test-Path -LiteralPath $destPath) {
            $need = (Get-Item -LiteralPath $Pick.path).LastWriteTimeUtc -gt (Get-Item -LiteralPath $destPath).LastWriteTimeUtc
        }
        if ($need) { Copy-Item -LiteralPath $Pick.path -Destination $destPath -Force }
    } catch { return '' }
    "$ServeUrlBase/$dest"
}

$labels  = New-Object System.Collections.Generic.List[string]
$roms    = New-Object System.Collections.Generic.List[string]
$cores   = New-Object System.Collections.Generic.List[string]
$systems = New-Object System.Collections.Generic.List[string]
$arts    = New-Object System.Collections.Generic.List[object]
$seen    = New-Object System.Collections.Generic.HashSet[string]

Get-ChildItem -LiteralPath $PlaylistDir -Filter *.lpl -ErrorAction SilentlyContinue | ForEach-Object {
    $plName = $_.BaseName
    try {
        $pl = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Warning "Skipping unreadable/old-format playlist: $($_.Name)"
        return
    }

    # Fallback core for DETECT entries: the playlist default, else the first
    # entry that names a real core.
    $fallbackCore = $pl.default_core_path
    if ([string]::IsNullOrWhiteSpace($fallbackCore) -or $fallbackCore -eq 'DETECT') {
        $fallbackCore = ($pl.items |
            Where-Object { $_.core_path -and $_.core_path -ne 'DETECT' } |
            Select-Object -First 1 -ExpandProperty core_path)
    }

    foreach ($item in $pl.items) {
        if ([string]::IsNullOrWhiteSpace($item.path)) { continue }

        $core = $item.core_path
        if ([string]::IsNullOrWhiteSpace($core) -or $core -eq 'DETECT') { $core = $fallbackCore }
        if ([string]::IsNullOrWhiteSpace($core)) { $core = 'DETECT' }

        $label = $item.label
        if ([string]::IsNullOrWhiteSpace($label)) {
            $label = [System.IO.Path]::GetFileNameWithoutExtension($item.path)
        }
        if (-not $seen.Add($label)) { continue }

        $system = if ($item.db_name) { $item.db_name -replace '\.lpl$','' } else { $plName }

        $norm    = Get-Norm $label
        $capsule = Publish-Thumb (Resolve-Thumb $boxIdx   $norm $system) ''
        $header  = Publish-Thumb (Resolve-Thumb $snapIdx  $norm $system) '_snap'
        $title   = Publish-Thumb (Resolve-Thumb $titleIdx $norm $system) '_title'
        if (-not $capsule) { $capsule = '' }
        if (-not $header)  { $header  = $capsule }
        if (-not $title)  { $title  = $capsule }

        $labels.Add($label)
        $roms.Add($item.path)
        $cores.Add($core)
        $systems.Add($system)
        $arts.Add([ordered]@{ capsule = $capsule; header = $header; title = $title })
    }
}

$out = [ordered]@{
    retroarch = $RetroArchExe
    label     = $labels
    rom       = $roms
    core      = $cores
    system    = $systems
    art       = $arts
    type      = "file"
}

[System.IO.File]::WriteAllText($OutFile,
  ($out | ConvertTo-Json -Depth 6 -Compress),
  (New-Object System.Text.UTF8Encoding($false)))

$withArt = ($arts | Where-Object { $_.capsule }).Count
Write-Host "Wrote $($labels.Count) RetroArch games to $OutFile ($withArt with artwork, $($labels.Count - $withArt) without)"