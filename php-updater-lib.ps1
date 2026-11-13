#Requires -Version 5.1
<#
.SYNOPSIS
    Library fungsi bersama untuk update-php (CLI / GUI / TUI).

.DESCRIPTION
    File ini HANYA berisi function - tidak mengeksekusi apa pun saat di-dot-source.
    Dipakai oleh: update-php.ps1 (CLI), update-php-gui.ps1 (GUI), update-php-tui.ps1 (TUI).
#>

# ------------------------------------------------------------------ logging --
function Write-Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Wrn([string]$m)  { Write-Warning $m }
function Stop-Fail([string]$m)  { Write-Host "`n[ GAGAL ] $m" -ForegroundColor Red; exit 1 }

# Jalankan process native (php.exe/httpd.exe) dengan aman: output stderr tidak
# melempar error NativeCommandError saat $ErrorActionPreference = 'Stop'.
# Catatan: $CmdArgs memakai [object[]] + perataan manual. Sebelumnya memakai
# [ValueFromRemainingArguments][string[]] yang membuat argumen '-n','-v'
# tergabung jadi satu string "-n -v" -> php.exe menolak ("char 3: option not found").
function Invoke-Native {
    param([string]$File, [object[]]$CmdArgs = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $argList = @()
        foreach ($a in $CmdArgs) {
            if ($null -eq $a) { continue }
            if ($a -is [string]) {
                $argList += $a
            } elseif ($a -is [System.Collections.IEnumerable]) {
                foreach ($b in @($a)) { if ($null -ne $b) { $argList += [string]$b } }
            } else {
                $argList += [string]$a
            }
        }
        $out = & $File @argList 2>&1 | Out-String
        return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
    } finally { $ErrorActionPreference = $prev }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-PhpVersion([int]$Major, [int]$Minor) { New-Object version($Major, $Minor) }

# Baca arch (x64/x86) dari header PE sebuah DLL/EXE.
function Get-PeArch([string]$Path) {
    try {
        $fs = [IO.File]::OpenRead($Path)
        $br = New-Object IO.BinaryReader($fs)
        try {
            if ($br.ReadUInt16() -ne 0x5A4D) { return $null }        # 'MZ'
            $fs.Position = 0x3C
            $peOffset = $br.ReadInt32()
            $fs.Position = $peOffset
            if ($br.ReadUInt32() -ne 0x00004550) { return $null }    # 'PE\0\0'
            switch ($br.ReadUInt16()) {
                0x8664 { return 'x64' }
                0x014C { return 'x86' }
                default { return $null }
            }
        } finally { $br.Close(); $fs.Close() }
    } catch { return $null }
}

# Tag compiler resmi PHP per cabang: 8.x=vs16, 7.2-7.4=vc15, 7.0-7.1=vc14, 5.5-5.6=vc11, <=5.4=vc9
function Get-ExpectedVc([version]$V) {
    if ($V.Major -ge 8)    { return 'vs16' }
    if ($V.Major -eq 7 -and $V.Minor -ge 2) { return 'vc15' }
    if ($V.Major -eq 7)    { return 'vc14' }
    if ($V.Major -eq 5 -and $V.Minor -ge 5) { return 'vc11' }
    return 'vc9'
}

# Indeks semua zip PHP di windows.php.net (releases + archives).
function Get-PhpZipIndex {
    $bases = @(
        'https://windows.php.net/downloads/releases/',
        'https://windows.php.net/downloads/releases/archives/'
    )
    $rx = [regex]'href\s*=\s*"(?<url>php-(?<ver>\d+\.\d+\.\d+)-Win32-(?<vc>(?:vs|vc)\d+)-(?<arch>x64|x86)(?:-(?<nts>nts))?\.zip)"'
    $seen = @{}
    $items = @()
    foreach ($base in $bases) {
        try {
            $html = (Invoke-WebRequest -Uri $base -UseBasicParsing -TimeoutSec 60).Content
        } catch {
            Write-Wrn "Tidak bisa membaca $base ($($_.Exception.Message))"
            continue
        }
        foreach ($m in $rx.Matches($html)) {
            $name = $m.Groups['url'].Value
            if ($seen.ContainsKey($name)) { continue }
            $seen[$name] = $true
            $items += [pscustomobject]@{
                Version = [version]$m.Groups['ver'].Value
                Vc      = $m.Groups['vc'].Value.ToLower()
                Arch    = $m.Groups['arch'].Value.ToLower()
                Nts     = $m.Groups['nts'].Success
                Url     = $base + $name
            }
        }
    }
    return $items
}

# Pilih zip paling baru sesuai kriteria; fallback jika tag VC tidak ditemukan.
function Select-PhpZip {
    param($Index, [version]$Branch, [string]$Vc, [string]$Arch, [bool]$Nts)
    $cand = $Index | Where-Object {
        $_.Arch -eq $Arch -and $_.Nts -eq $Nts -and
        ($_.Version.Major -eq $Branch.Major -and $_.Version.Minor -eq $Branch.Minor)
    }
    if (-not $cand) { return $null }
    $exact = $cand | Where-Object { $_.Vc -eq $Vc }
    if ($exact) { return ($exact | Sort-Object Version -Descending | Select-Object -First 1) }
    $fallback = $cand | Sort-Object Version -Descending | Select-Object -First 1
    Write-Wrn "Build '$Vc' tidak ada; memakai '$($fallback.Vc)' (kemungkinan tetap kompatibel)."
    return $fallback
}

# Deteksi versi / arsitektur / flavor sebuah folder PHP.
function Get-PhpInfo {
    param([string]$Dir)
    $info = [pscustomobject]@{
        Dir         = $Dir
        Exists      = $false
        Version     = $null
        VersionText = 'tidak terdeteksi'
        Arch        = ''
        ThreadSafe  = ''
        HasExe      = $false
        HasIni      = $false
        Error       = ''
    }
    if ([string]::IsNullOrWhiteSpace($Dir) -or -not (Test-Path $Dir)) { return $info }
    $info.Exists  = $true
    $info.Dir     = (Resolve-Path $Dir).Path
    $exe          = Join-Path $info.Dir 'php.exe'
    $info.HasExe  = Test-Path $exe
    $info.HasIni  = Test-Path (Join-Path $info.Dir 'php.ini')
    if ($info.HasExe) {
        $r = Invoke-Native $exe '-n', '-v'
        if ($r.Output -match 'PHP\s+(\d+\.\d+\.\d+)') {
            $info.Version     = [version]$Matches[1]
            $info.VersionText = $Matches[1]
        } else {
            $info.Error = 'php.exe tidak bisa dijalankan (cek Visual C++ Redistributable).'
        }
    }
    foreach ($dll in @('php8ts.dll', 'php7ts.dll', 'php5ts.dll', 'php8.dll', 'php7.dll', 'php5.dll')) {
        $p = Join-Path $info.Dir $dll
        if (Test-Path $p) { $a = Get-PeArch $p; if ($a) { $info.Arch = $a; break } }
    }
    if (-not $info.Arch) { $info.Arch = 'x64' }
    $ts = Get-ChildItem -Path $info.Dir -Filter '*apache2_4.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    $info.ThreadSafe = if ($ts) { 'TS' } else { 'NTS' }
    return $info
}

# Daftar folder PHP di C:\Server (php, php-5.6, php-7.4, ...).
function Get-ServerPhpFolders {
    param([string]$Root = 'C:\Server')
    if (-not (Test-Path $Root)) { return @() }
    Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'php*' } |
        ForEach-Object { $_.FullName } |
        Sort-Object
}

# Cari backup terbaru untuk sebuah folder PHP (mis. C:\Server\php.bak-20251023-101500).
function Get-LatestPhpBackup {
    param([string]$PhpFolder)
    $parent = Split-Path $PhpFolder -Parent
    $leaf   = Split-Path $PhpFolder -Leaf
    if (-not $parent -or -not (Test-Path $parent)) { return $null }
    Get-ChildItem -Path $parent -Directory -Filter "$leaf.bak-*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1
}

# Buat / perbarui shortcut .bat di C:\Server\php_bat jika folder tersebut ada.
function Update-PhpBat {
    param(
        [string]$PhpFolder,
        [version]$Ver,
        [string]$BatDir = 'C:\Server\php_bat'
    )
    if (-not (Test-Path $BatDir)) { return }
    if (-not $Ver) { return }
    $batName = "php$($Ver.Major)$($Ver.Minor).bat"
    $batPath = Join-Path $BatDir $batName
    $exePath = Join-Path $PhpFolder 'php.exe'
    if (-not (Test-Path $exePath)) { return }
    $content = "@echo off`r`n$exePath %*`r`n"
    try {
        [IO.File]::WriteAllText($batPath, $content)
        Write-Ok "Launcher php_bat diperbarui: $batPath"
    } catch {
        Write-Wrn "Gagal menulis launcher ${batPath}: $($_.Exception.Message)"
    }
}

