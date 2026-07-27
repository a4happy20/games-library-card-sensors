# ---- EDIT THESE PATHS ----
$steam = "C:\Games\Steam"
$vdf   = Join-Path $steam "steamapps\libraryfolders.vdf"
$outFile = "Y:\www\steam_games\steam_games.json"

# ── Games to KEEP OUT of the list ────────────────────────────────────────────
$excludeAppIds = @(
    '228980'    # Steamworks Common Redistributables
    '1946180'   # Skyrim Special Edition: Creation Kit
)
$excludeNames = @(
    # 'Wallpaper Engine'
)
# ─────────────────────────────────────────────────────────────────────────────

# ── Art resolution via GetItems (per-asset content hashes) ───────────────────
function Get-FirstAsset {
    param($Assets, [string[]]$Names)
    foreach ($n in $Names) {
        $p = $Assets.PSObject.Properties[$n]
        if ($p -and $p.Value) { return [string]$p.Value }
    }
    return $null
}

function Expand-AssetUrl {
    param([string]$Fmt, [string]$Value)
    if (-not $Value) { return $null }
    return $Fmt.Replace('${FILENAME}', $Value).Replace('${filename}', $Value)
}

function Resolve-SteamArt {
    param([Parameter(Mandatory)][int[]]$AppIds, [string]$CountryCode = 'US')

    $store  = 'https://shared.cloudflare.steamstatic.com/store_item_assets/'
    $legacy = 'https://cdn.cloudflare.steamstatic.com/steam/apps/'
    $out    = @{}
    if (-not $AppIds -or $AppIds.Count -eq 0) { return $out }

    for ($i = 0; $i -lt $AppIds.Count; $i += 100) {
        $slice = $AppIds[$i..([Math]::Min($i + 99, $AppIds.Count - 1))]
        $body = @{
            ids          = @($slice | ForEach-Object { @{ appid = $_ } })
            context      = @{ country_code = $CountryCode }
            data_request = @{ include_assets = $true }
        } | ConvertTo-Json -Depth 6 -Compress
        $url = 'https://api.steampowered.com/IStoreBrowseService/GetItems/v1/?input_json=' +
               [System.Uri]::EscapeDataString($body)

        try { $resp = Invoke-RestMethod -Uri $url -TimeoutSec 20 -ErrorAction Stop }
        catch { Write-Warning "GetItems failed for chunk at index $i; legacy fallback used. $_"; continue }

        foreach ($item in $resp.response.store_items) {
            $a = $item.assets
            if (-not $a -or -not $a.asset_url_format) { continue }
            $fmt = $store + $a.asset_url_format
            $out["$($item.appid)"] = [ordered]@{
                capsule   = Expand-AssetUrl $fmt (Get-FirstAsset $a @('library_capsule', 'library_capsule_2x'))
                capsule2x = Expand-AssetUrl $fmt (Get-FirstAsset $a @('library_capsule_2x', 'library_capsule'))
                header    = Expand-AssetUrl $fmt (Get-FirstAsset $a @('header'))
                hero      = Expand-AssetUrl $fmt (Get-FirstAsset $a @('library_hero', 'hero_capsule'))
                logo      = Expand-AssetUrl $fmt (Get-FirstAsset $a @('library_logo', 'logo'))
            }
        }
    }

    foreach ($id in $AppIds) {
        if (-not $out.ContainsKey("$id")) {
            $out["$id"] = [ordered]@{
                capsule   = "$legacy$id/library_600x900.jpg"
                capsule2x = "$legacy$id/library_600x900_2x.jpg"
                header    = "$legacy$id/header.jpg"
                hero      = "$legacy$id/library_hero.jpg"
                logo      = "$legacy$id/logo.png"
            }
        }
    }
    return $out
}
# ─────────────────────────────────────────────────────────────────────────────

# ── Description lookup via the storefront appdetails endpoint ─────────────────
# One appid per call (multi-appid requests return null for descriptions), and
# it's rate-limited (HTTP 429). We back off on 429 and cache across runs, so
# after the first run only newly installed games hit the API.
function Clean-Text {
    param([string]$s)
    if (-not $s) { return $null }
    $s = $s -replace '<[^>]+>', ''                    # strip any stray HTML tags
    $s = [System.Net.WebUtility]::HtmlDecode($s)      # &amp; -> & , etc.
    return $s.Trim()
}

function Get-SteamDescription {
    param([int]$AppId, [string]$Lang = 'english', [string]$Cc = 'US')
    $url = "https://store.steampowered.com/api/appdetails?appids=$AppId&l=$Lang&cc=$Cc"
    for ($try = 0; $try -lt 3; $try++) {
        try {
            $r = Invoke-RestMethod -Uri $url -TimeoutSec 20 -ErrorAction Stop
            $entry = $r."$AppId"
            if ($entry -and $entry.success -and $entry.data) {
                return Clean-Text ([string]$entry.data.short_description)
            }
            return $null   # success:false (delisted / region-locked) — no description
        }
        catch {
            $code = $null
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            if ($code -eq 429) { Start-Sleep -Seconds 15; continue }   # rate limited
            Start-Sleep -Seconds 3
        }
    }
    return $null
}
# ─────────────────────────────────────────────────────────────────────────────

$libs = @($steam)
if (Test-Path $vdf) {
    Select-String -Path $vdf -Pattern '"path"\s+"(.+?)"' | ForEach-Object {
        $libs += ($_.Matches.Groups[1].Value -replace '\\\\', '\')
    }
}

$games = @()
foreach ($lib in ($libs | Select-Object -Unique)) {
    $apps = Join-Path $lib "steamapps"
    if (Test-Path $apps) {
        Get-ChildItem -Path $apps -Filter "appmanifest_*.acf" | ForEach-Object {
            $c  = Get-Content $_.FullName -Raw -Encoding UTF8
            $id = if ($c -match '"appid"\s+"(\d+)"')  { $matches[1] }
            $nm = if ($c -match '"name"\s+"(.+?)"')    { $matches[1] }
            if ($id -and ($excludeAppIds -contains $id)) { return }
            if ($nm -and ($excludeNames  -contains $nm)) { return }
            if ($id -and $nm) { $games += [pscustomobject]@{ appid = $id; name = $nm } }
        }
    }
}

$games = $games | Sort-Object name

# Resolve finished art URLs for every appid in one batched pass.
$art = Resolve-SteamArt -AppIds @($games | ForEach-Object { [int]$_.appid })

# Reuse descriptions from the previous run; only fetch ones we don't have yet.
$prevOverview = @{}
if (Test-Path $outFile) {
    try {
        $prev = Get-Content $outFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($prev.appid -and $prev.overview) {
            for ($i = 0; $i -lt $prev.appid.Count; $i++) {
                $ov = $prev.overview[$i]
                if ($ov) { $prevOverview["$($prev.appid[$i])"] = [string]$ov }
            }
        }
    } catch { Write-Warning "Couldn't read cached descriptions; re-fetching. $_" }
}

$overview = @()
$fetched  = 0
foreach ($g in $games) {
    $key = "$($g.appid)"
    if ($prevOverview.ContainsKey($key)) {
        $overview += $prevOverview[$key]           # cache hit — no API call
    } else {
        $overview += (Get-SteamDescription -AppId ([int]$g.appid))
        $fetched++
        Start-Sleep -Milliseconds 1500             # stay under the rate limit
    }
}

# Parallel arrays. overview[i] aligns with name[i]/appid[i]/art[i].
$out = [ordered]@{
    name     = @($games | ForEach-Object { $_.name })
    appid    = @($games | ForEach-Object { $_.appid })
    overview = $overview
    art      = @($games | ForEach-Object { $art["$($_.appid)"] })
    type     = "file"
}

[System.IO.File]::WriteAllText($outFile,
  ($out | ConvertTo-Json -Depth 5 -Compress),
  (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Wrote $($games.Count) games to $outFile ($fetched descriptions fetched, $($games.Count - $fetched) from cache)"