#Requires -Version 5.1
<#
.SYNOPSIS
    Update / install baru PHP di C:\Server (atau folder PHP lain) secara aman.

.DESCRIPTION
    Dua mode:
      UPDATE (default) :
        1. Deteksi versi, arsitektur (x64/x86), dan flavor (TS/NTS) PHP yang terpasang.
        2. Cari versi terbaru yang cocok di windows.php.net (fallback: /archives/).
        3. Download + ekstrak ke staging, validasi (php.exe -v).
        4. Stop Apache + proses php-cgi, backup -> <folder>.bak-<timestamp>.
        5. Pasang folder baru; php.ini lama + file custom (xdebug dll) dipertahankan.
        6. Smoke test, httpd -t, start ulang Apache. Gagal -> ROLLBACK otomatis.

      INSTALL BARU (-InstallNew) :
        1. Buat instalasi PHP segar di folder baru (mis. C:\Server\php-8.4).
        2. php.ini dibuat dari template php.ini-production (extension_dir diset).
        3. Opsional (-VhostPort): tambahkan vhost mod_fcgid ke httpd-vhosts.conf
           mengikuti pola yang sudah ada (port per versi PHP), lalu restart Apache.

.PARAMETER PhpDir
    Folder instalasi PHP. Default: C:\Server\php
    Untuk -InstallNew gunakan nama baru, mis. C:\Server\php-8.4

.PARAMETER Version
    Versi target. Boleh cabang ('8.2', '8.4') atau versi penuh ('8.3.14').
    Kosongkan (mode update) = tetap di cabang yang sedang terpasang, patch terbaru.
    WAJIB diisi untuk mode -InstallNew.

.PARAMETER InstallNew
    Instal PHP baru di folder baru (bukan update instalasi yang ada).

.PARAMETER VhostPort
    Hanya untuk -InstallNew: tambahkan vhost mod_fcgid di port ini ke
    conf/extra/httpd-vhosts.conf (konfigurasi di-backup dulu, divalidasi httpd -t).

.PARAMETER VhostDocRoot
    DocumentRoot untuk vhost baru. Default: D:/Development

.PARAMETER ThreadSafe
    TS atau NTS. Default: otomatis (deteksi dari php*apache2_4.dll).

.PARAMETER Arch
    x64 atau x86. Default: otomatis (dibaca dari header PE php*ts.dll).

.PARAMETER ApacheDir
    Root Apache. Default: C:\Server\Apache24. Dipakai untuk httpd -t dan restart.

.PARAMETER ZipPath
    Pakai file zip PHP yang sudah di-download (tanpa internet). Opsional.

.PARAMETER NoRestart
    Jangan start ulang Apache setelah update.

.PARAMETER Force
    Lewati cek "sudah versi terbaru" dan cek hak admin.

.EXAMPLE
    .\update-php.ps1
    Update C:\Server\php ke patch terbaru di cabang yang sama (8.2.x).

.EXAMPLE
    .\update-php.ps1 -Version 8.4
    Update C:\Server\php ke PHP 8.4 terbaru.

.EXAMPLE
    .\update-php.ps1 -InstallNew -PhpDir C:\Server\php-8.4 -Version 8.4 -VhostPort 84
    Install PHP 8.4 baru di C:\Server\php-8.4 + vhost fcgid di port 84.

.EXAMPLE
    .\update-php.ps1 -ListAvailable
    Lihat daftar versi PHP yang tersedia, tanpa mengubah apa pun.
#>
[CmdletBinding()]
param(
    [string]$PhpDir = 'C:\Server\php',
    [string]$Version = '',
    [switch]$InstallNew,
    [int]$VhostPort = 0,
    [string]$VhostDocRoot = 'D:/Development',
    [ValidateSet('TS', 'NTS', '')]
    [string]$ThreadSafe = '',
    [ValidateSet('x64', 'x86', '')]
    [string]$Arch = '',
    [string]$ApacheDir = 'C:\Server\Apache24',
    [string]$ZipPath = '',
    [switch]$NoRestart,
    [switch]$ListAvailable,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # supaya download jauh lebih cepat
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---- library bersama (deteksi, index windows.php.net, helper) -----------------
$libFile = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'php-updater-lib.ps1' } else { Join-Path (Get-Location).Path 'php-updater-lib.ps1' }
if (-not (Test-Path $libFile)) { Write-Error "php-updater-lib.ps1 tidak ditemukan: $libFile"; exit 1 }
. $libFile

# ---------------------------------------------------------------- apache -----
function Get-ApacheService {
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'apache' -or $_.DisplayName -match 'apache' } |
        Select-Object -First 1
}
function Get-ApacheExe { Join-Path $ApacheDir 'bin\httpd.exe' }

function Stop-ApacheStack {
    $svc = Get-ApacheService
    if ($svc) {
        if ($svc.Status -eq 'Running') {
            Write-Step "Stop service Apache ($($svc.Name))"
            Stop-Service -Name $svc.Name -Force
        }
    } elseif (Test-Path (Get-ApacheExe)) {
        $running = Get-Process -Name httpd -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -like "$ApacheDir*" }
        if ($running) {
            Write-Step 'Stop Apache (httpd -k stop)'
            Invoke-Native (Get-ApacheExe) '-k', 'stop' | Out-Null
            Start-Sleep -Seconds 2
        }
    }
    # php-cgi milik folder ini sering masih memegang file (mod_fcgid) -> matikan.
    Get-Process -Name php-cgi -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path -like "$PhpDir*" } |
        ForEach-Object {
            Write-Step "Kill proses php-cgi (PID $($_.Id))"
            Stop-Process -Id $_.Id -Force
        }
}

function Start-ApacheStack {
    if ($NoRestart) { Write-Wrn '-NoRestart dipakai: Apache TIDAK di-start ulang.'; return }
    $httpd = Get-ApacheExe
    if ((Test-Path $httpd) -and -not (Get-ApacheService)) {
        Write-Step 'Validasi konfigurasi Apache (httpd -t)'
        $t = Invoke-Native $httpd '-t'
        if ($t.ExitCode -ne 0) {
            Write-Wrn "Konfigurasi Apache bermasalah:`n$($t.Output)"
            return
        }
        Write-Ok 'Syntax OK'
    }
    $svc = Get-ApacheService
    if ($svc) {
        Write-Step "Start service Apache ($($svc.Name))"
        Start-Service -Name $svc.Name
    } elseif (Test-Path $httpd) {
        Write-Step 'Start Apache (httpd -k start)'
        Invoke-Native $httpd '-k', 'start' | Out-Null
    } else {
        Write-Wrn "Tidak menemukan service/binary Apache di $ApacheDir - start manual ya."
    }
}

# Tambahkan blok vhost mod_fcgid ke httpd-vhosts.conf (dengan backup + validasi).
function Add-FcgidVhost {
    param([int]$Port, [string]$PhpFolder, [string]$DocRoot)

    $confPath = Join-Path $ApacheDir 'conf\extra\httpd-vhosts.conf'
    if (-not (Test-Path $confPath)) { Write-Wrn "Tidak menemukan $confPath - vhost tidak ditambahkan."; return $false }

    # Cek duplikasi port dulu
    $existing = [IO.File]::ReadAllText($confPath)
    if ($existing -match "(?m)^\s*Listen\s+$Port\s*$") {
        Write-Wrn "Port $Port sudah dipakai di httpd-vhosts.conf - vhost tidak ditambahkan."
        return $false
    }

    $phpUnix = $PhpFolder -replace '\\', '/'
    $tpl = @'
Listen __PORT__

<VirtualHost *:__PORT__>
    ServerAdmin admin@localhost
    ServerName localhost
    DocumentRoot "__ROOT__"
    DirectoryIndex index.php

    FcgidInitialEnv PHPRC "__PHP__/php.ini"

    <Directory "__ROOT__">
        <Files ~ "\.php$">
            AddHandler fcgid-script .php
            FcgidWrapper "__PHP__/php-cgi.exe" .php
            Options +ExecCGI
        </Files>
    </Directory>
</VirtualHost>
'@
    $block = $tpl.Replace('__PORT__', "$Port").Replace('__PHP__', $phpUnix).Replace('__ROOT__', $DocRoot)

    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$confPath.bak-$stamp"
    Copy-Item $confPath $backup -Force
    Write-Step "Backup konfigurasi vhost: $backup"

    try {
        [IO.File]::WriteAllText($confPath, $existing.TrimEnd() + "`r`n`r`n`r`n" + $block + "`r`n")
        $httpd = Get-ApacheExe
        if (Test-Path $httpd) {
            Write-Step "Validasi konfigurasi Apache (httpd -t)"
            $t = Invoke-Native $httpd '-t'
            if ($t.ExitCode -ne 0) { throw "httpd -t gagal:`n$($t.Output)" }
            Write-Ok 'Syntax OK'
        }
        Write-Ok "Vhost mod_fcgid ditambahkan: port $Port -> $phpUnix (akses: http://localhost:$Port/)"
        return $true
    } catch {
        Write-Wrn "Gagal menambah vhost: $($_.Exception.Message)"
        Write-Wrn 'Konfigurasi vhost dikembalikan ke semula.'
        Copy-Item $backup $confPath -Force
        return $false
    }
}

# ---------------------------------------------------------------- preflight --
$PhpDir     = if ($PhpDir) { $PhpDir } else { 'C:\Server\php' }
$PhpDirUnix = $PhpDir -replace '\\', '/'

if (-not (Test-IsAdmin) -and -not $Force) {
    Stop-Fail 'Jalankan PowerShell sebagai Administrator (rename folder di C:\Server butuh hak akses admin).'
}

$curVersion = $null
if ($InstallNew) {
    # ---- mode instalasi baru
    if (-not $Version) { Stop-Fail 'Install baru butuh -Version, mis. -Version 8.4 atau -Version 8.4.12' }
    if (Test-Path $PhpDir) {
        $items = Get-ChildItem -Path $PhpDir -Force -ErrorAction SilentlyContinue
        if ($items) {
            Stop-Fail "Folder $PhpDir sudah berisi file. Untuk UPDATE instalasi itu, jalankan tanpa -InstallNew."
        }
    }
    if (-not $Arch)       { $Arch = 'x64' }
    if (-not $ThreadSafe) { $ThreadSafe = 'TS' }
} else {
    # ---- mode update
    if (-not (Test-Path $PhpDir)) { Stop-Fail "Folder PHP tidak ditemukan: $PhpDir`nGunakan -InstallNew untuk instalasi baru." }
    $PhpDir = (Resolve-Path $PhpDir).Path
    $PhpDirUnix = $PhpDir -replace '\\', '/'
    $info       = Get-PhpInfo $PhpDir
    $curVersion = $info.Version
    if (-not $info.Version) {
        Write-Wrn "php.exe tidak bisa dijalankan / versi tidak terdeteksi di $PhpDir (installasi kosong/rusak?)."
    }
    if (-not $Arch)       { $Arch       = $info.Arch;       Write-Ok "Arsitektur terdeteksi: $Arch" }
    if (-not $ThreadSafe) { $ThreadSafe = $info.ThreadSafe; Write-Ok "Flavor terdeteksi: $ThreadSafe" }
}

if ($VhostPort -gt 0 -and -not $InstallNew) {
    Write-Wrn '-VhostPort hanya dipakai bersama -InstallNew - diabaikan.'
    $VhostPort = 0
}

# --- tentukan cabang target
if ($Version -match '^\d+\.\d+\.\d+$') { $targetExact = [version]$Version; $branch = New-PhpVersion $targetExact.Major $targetExact.Minor }
elseif ($Version -match '^\d+\.\d+$')  { $targetExact = $null; $branch = [version]$Version }
elseif ($InstallNew)                   { Stop-Fail "Format versi untuk install baru: '8.4' (cabang) atau '8.4.12' (persis). Yang '$Version' tidak didukung." }
elseif ($Version -match '^\d+$')       { if (-not $curVersion) { Stop-Fail 'Versi terpasang tidak terdeteksi; tulis versi lengkap, mis. -Version 8.4' }; $targetExact = $null; $branch = New-PhpVersion $curVersion.Major ([int]$Version) }
else                                   { if (-not $curVersion) { Stop-Fail 'Versi terpasang tidak terdeteksi; tulis versi/cabang, mis. -Version 8.4' }; $targetExact = $null; $branch = New-PhpVersion $curVersion.Major $curVersion.Minor }

$vcExpected = Get-ExpectedVc $branch
$modeLabel  = if ($InstallNew) { 'INSTALL BARU' } else { 'UPDATE' }
Write-Host ''
Write-Host "    Mode        : $modeLabel"
Write-Host "    Folder      : $PhpDir"
Write-Host "    Terpasang   : $(if ($curVersion) { $curVersion } elseif ($InstallNew) { '(folder baru)' } else { 'tidak terdeteksi' })"
Write-Host "    Target      : $branch$(if ($targetExact) { ' (exact ' + $targetExact + ')' }) ($vcExpected, $Arch, $ThreadSafe)"
Write-Host ''

# --- daftar build yang tersedia (hanya jika dibutuhkan)
$index = @()
if (-not $ZipPath -or $ListAvailable) { $index = Get-PhpZipIndex }
if ($ListAvailable) {
    $index | Where-Object { $_.Arch -eq $Arch -and $_.Nts -eq ($ThreadSafe -eq 'NTS') } |
        Sort-Object Version -Descending | Select-Object -First 25 |
        Format-Table Version, Vc, Arch, @{ n = 'Flavor'; e = { if ($_.Nts) { 'NTS' } else { 'TS' } } }, Url -AutoSize
    exit 0
}

# ---------------------------------------------------------------- download ----
$zipFile = $ZipPath
if (-not $zipFile) {
    $flavorLabel = if ($ThreadSafe -eq 'NTS') { 'NTS' } else { 'TS' }
    Write-Step "Cari versi $branch terbaru ($flavorLabel) di windows.php.net"
    $pick = Select-PhpZip -Index $index -Branch $branch -Vc $vcExpected -Arch $Arch -Nts ($ThreadSafe -eq 'NTS')
    if (-not $pick) { Stop-Fail "Tidak ada build $branch $Arch $ThreadSafe di windows.php.net. Coba -Version lain atau -ListAvailable." }
    if ($targetExact -and $pick.Version -ne $targetExact) {
        $pick = $index | Where-Object { $_.Version -eq $targetExact -and $_.Arch -eq $Arch -and $_.Nts -eq ($ThreadSafe -eq 'NTS') } | Select-Object -First 1
        if (-not $pick) { Stop-Fail "Versi $targetExact ($Arch/$ThreadSafe) tidak tersedia." }
    }
    if ($curVersion -and $pick.Version -le $curVersion -and -not $Force) {
        Stop-Fail "Sudah versi terbaru ($curVersion). Pakai -Force jika tetap mau reinstall."
    }
    Write-Ok "Versi target: $($pick.Version)  [$($pick.Url)]"
    $zipFile = Join-Path $env:TEMP ("php-{0}-{1}-{2}.zip" -f $pick.Version, $pick.Arch, $(if ($pick.Nts) { 'nts' } else { 'ts' }))
    if (-not (Test-Path $zipFile)) {
        Write-Step 'Download zip PHP (sekitar 25 MB, bisa 1-3 menit)'
        Invoke-WebRequest -Uri $pick.Url -OutFile $zipFile -UseBasicParsing -TimeoutSec 600
    } else {
        Write-Ok 'Zip sudah ada di %TEMP%, skip download.'
    }
} else {
    if (-not (Test-Path $zipFile)) { Stop-Fail "File zip tidak ditemukan: $zipFile" }
    $pick = $null
}

# ---------------------------------------------------------------- ekstrak -----
Write-Step 'Ekstrak ke folder staging'
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$stage   = Join-Path $env:TEMP "php-stage-$stamp"
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Expand-Archive -Path $zipFile -DestinationPath $stage -Force

$stageExe = Join-Path $stage 'php.exe'
if (-not (Test-Path $stageExe)) { Stop-Fail 'php.exe tidak ada di dalam zip - file download rusak?' }

$stageCheck = Invoke-Native $stageExe '-n', '-v'
if ($stageCheck.ExitCode -ne 0 -or $stageCheck.Output -notmatch 'PHP\s+(\d+\.\d+\.\d+)') {
    Stop-Fail "Build baru gagal dijalankan. Cek Visual C++ Redistributable 2015-2022 ($Arch) terpasang.`n$($stageCheck.Output)"
}
if (-not ($stageCheck.Output -match 'PHP\s+(\d+\.\d+\.\d+)')) { Stop-Fail 'Versi build baru tidak terbaca.' }
$stageVer = [version]$Matches[1]
Write-Ok "Build tervalidasi: PHP $stageVer"

# ================================================================ INSTALL BARU
if ($InstallNew) {
    try {
        Write-Step "Install baru: PHP $stageVer -> $PhpDir"
        if (Test-Path $PhpDir) { Remove-Item $PhpDir -Recurse -Force }   # hanya folder kosong
        Move-Item -Path $stage -Destination $PhpDir

        # php.ini dari template production
        $tplIni  = Join-Path $PhpDir 'php.ini-production'
        $newIni  = Join-Path $PhpDir 'php.ini'
        if (Test-Path $tplIni) {
            Copy-Item $tplIni $newIni -Force
            $txt  = [IO.File]::ReadAllText($newIni)
            $line = "extension_dir = `"$PhpDirUnix/ext`""
            $txt2 = if ($txt -match '(?m)^\s*extension_dir\s*=') {
                [regex]::Replace($txt, '(?m)^\s*extension_dir\s*=.*$', $line)
            } else { $txt + [Environment]::NewLine + $line + [Environment]::NewLine }
            [IO.File]::WriteAllText($newIni, $txt2)
            Write-Ok 'php.ini dibuat dari php.ini-production, extension_dir diset.'
        } else {
            Write-Wrn 'Template php.ini-production tidak ada - lanjut tanpa php.ini.'
        }

        # smoke test
        Write-Step 'Smoke test'
        $newPhpExe = Join-Path $PhpDir 'php.exe'
        $smoke = Invoke-Native $newPhpExe '-n', '-v'
        if ($smoke.ExitCode -ne 0) { throw "php.exe -v gagal:`n$($smoke.Output)" }
        Write-Ok (($smoke.Output -split "`n")[0].Trim())

        # perbarui / buat shortcut bat di C:\Server\php_bat jika foldernya ada
        Update-PhpBat -PhpFolder $PhpDir -Ver $stageVer
    } catch {
        Write-Wrn "Terjadi kesalahan: $($_.Exception.Message)"
        Write-Step 'BERSIHKAN folder instalasi yang gagal'
        if (Test-Path $PhpDir) { Remove-Item $PhpDir -Recurse -Force -ErrorAction SilentlyContinue }
        Stop-Fail 'Install dibatalkan, folder baru dibersihkan. Tidak ada perubahan pada instalasi lain.'
    }

    $vhostOk = $false
    if ($VhostPort -gt 0) {
        Write-Step "Tambah vhost mod_fcgid (port $VhostPort)"
        $vhostOk = Add-FcgidVhost -Port $VhostPort -PhpFolder $PhpDir -DocRoot $VhostDocRoot
    }

    Write-Host ''
    Write-Host "    SELESAI. PHP $stageVer terinstall di $PhpDir" -ForegroundColor Green
    if ($vhostOk) {
        if ($NoRestart) {
            Write-Wrn '-NoRestart dipakai: Apache TIDAK direstart - vhost baru baru aktif saat Apache direstart berikutnya.'
        } else {
            Write-Step 'Restart Apache agar vhost baru terbaca'
            Stop-ApacheStack      # kalau Apache jalan -> stop dulu (start saja tidak cukup)
            Start-ApacheStack
            Write-Host "    Akses: http://localhost:$VhostPort/  (DocumentRoot $VhostDocRoot)"
        }
    } else {
        Write-Host '    Catatan: PHP sudah terpasang, tetapi BELUM terhubung ke Apache.'
        Write-Host "    Untuk memakainya via fcgid, tambahkan vhost manual atau ulangi dengan -VhostPort <port>."
    }
    exit 0
}

# ==================================================================== UPDATE ==
$oldBranch = if ($curVersion) { "$($curVersion.Major).$($curVersion.Minor)" } else { '?' }
if ($oldBranch -ne "$($stageVer.Major).$($stageVer.Minor)") {
    Write-Wrn "Cabang berubah ($oldBranch -> $($stageVer.Major).$($stageVer.Minor))."
    Write-Wrn "File custom yang disalin (mis. php_xdebug.dll) mungkin TIDAK kompatibel - cek pesan startup saat smoke test."
}

$backup = "$PhpDir.bak-$stamp"
$swapped = $false
try {
    Write-Step 'Stop Apache + php-cgi'
    Stop-ApacheStack

    Write-Step "Backup: $PhpDir -> $backup"
    Rename-Item -Path $PhpDir -NewName (Split-Path $backup -Leaf)

    Write-Step "Pasang PHP $stageVer ke $PhpDir"
    Move-Item -Path $stage -Destination $PhpDir
    $swapped = $true

    # 1) php.ini lama dipertahankan, extension_dir disesuaikan
    $oldIni = Join-Path $backup 'php.ini'
    $newIni = Join-Path $PhpDir 'php.ini'
    if (Test-Path $oldIni) {
        Copy-Item $oldIni $newIni -Force
        $txt = [IO.File]::ReadAllText($newIni)
        $line = "extension_dir = `"$PhpDirUnix/ext`""
        $txt2 = if ($txt -match '(?m)^\s*extension_dir\s*=') {
            [regex]::Replace($txt, '(?m)^\s*extension_dir\s*=.*$', $line)
        } else { $txt + [Environment]::NewLine + $line + [Environment]::NewLine }
        if ($txt2 -ne $txt) { [IO.File]::WriteAllText($newIni, $txt2) }
        Write-Ok 'php.ini lama dipertahankan, extension_dir diperbarui.'
    } else {
        Write-Wrn 'php.ini lama tidak ditemukan - memakai template bawaan.'
    }

    # 2) file custom yang tidak ada di build resmi (xdebug, dll) ikut dibawa
    Write-Step 'Salin file custom dari instalasi lama (yang tidak ada di build baru)'
    $copied = 0
    Get-ChildItem -Path $backup -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($backup.Length).TrimStart('\')
        if ($rel -ieq 'php.ini') { return }
        $target = Join-Path $PhpDir $rel
        if (-not (Test-Path $target)) {
            $dir = Split-Path $target -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Copy-Item $_.FullName $target -Force
            Write-Host "      + $rel"
            $copied++
        }
    }
    if ($copied -eq 0) { Write-Ok 'Tidak ada file custom.' } else { Write-Ok "$copied file custom disalin." }

    # 3) smoke test di lokasi final (dengan php.ini)
    Write-Step 'Smoke test'
    $newPhpExe = Join-Path $PhpDir 'php.exe'
    $smoke = Invoke-Native $newPhpExe '-v'
    if ($smoke.ExitCode -ne 0) { throw "php.exe -v gagal:`n$($smoke.Output)" }
    Write-Ok (($smoke.Output -split "`n")[0].Trim())

    $mods = (Invoke-Native $newPhpExe '-m').Output
    $warns = ($mods -split "`n") | Where-Object { $_ -match 'Unable to load dynamic library|PHP Startup' }
    if ($warns) {
        Write-Wrn 'Ada extension yang gagal dimuat (biasanya extension lama di php.ini):'
        $warns | ForEach-Object { Write-Wrn "    $_" }
    } else {
        Write-Ok 'Semua extension termuat normal.'
    }

    # perbarui / buat shortcut bat di C:\Server\php_bat jika foldernya ada
    Update-PhpBat -PhpFolder $PhpDir -Ver $stageVer
} catch {
    Write-Wrn "Terjadi kesalahan: $($_.Exception.Message)"
    Write-Step 'ROLLBACK ke kondisi semula'
    if ($swapped -and (Test-Path $PhpDir)) { Remove-Item $PhpDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ((Test-Path $backup) -and -not (Test-Path $PhpDir)) { Rename-Item -Path $backup -NewName (Split-Path $PhpDir -Leaf) }
    Start-ApacheStack
    Stop-Fail 'Update dibatalkan, instalasi lama sudah dikembalikan.'
}

# ---------------------------------------------------------------- selesai ----
Write-Step 'Start Apache'
Start-ApacheStack

Write-Host ''
Write-Host "    SELESAI. PHP $curVersion -> $stageVer di $PhpDir" -ForegroundColor Green
Write-Host "    Backup tersimpan di: $backup  (hapus manual kalau sudah yakin)"
if ($NoRestart) {
    Write-Host '    PERHATIAN: Apache dalam keadaan STOPPED (karena -NoRestart) - start manual ya.' -ForegroundColor Yellow
}
Write-Host "    Catatan: vhost lama (php-5.3/5.4/5.6/7.2/7.4) tidak tersentuh - tetap di port masing-masing."
