#Requires -Version 5.1
<#
.SYNOPSIS
    TUI (menu console) untuk update PHP di C:\Server.

.DESCRIPTION
    Menu interaktif berbasis console yang menjalankan update-php.ps1.
    Cocok untuk terminal murni / RDP tanpa ingin repot dengan GUI.

.EXAMPLE
    .\update-php-tui.ps1
.EXAMPLE
    .\update-php-tui.ps1 -PhpDir C:\Server\php-7.4
#>
[CmdletBinding()]
param([string]$PhpDir = 'C:\Server\php')

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$libFile = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'php-updater-lib.ps1' } else { Join-Path (Get-Location).Path 'php-updater-lib.ps1' }
if (-not (Test-Path $libFile)) { Write-Host "php-updater-lib.ps1 tidak ditemukan: $libFile" -ForegroundColor Red; exit 1 }
. $libFile

$cliScript = Join-Path (Split-Path $libFile -Parent) 'update-php.ps1'
$folder    = $PhpDir
$isAdmin   = Test-IsAdmin
$force     = $false

try { $Host.UI.RawUI.WindowTitle = 'PHP Updater - C:\Server' } catch { }

# ------------------------------------------------------------- elevasi ------
if (-not $isAdmin) {
    Write-Host ''
    Write-Host '  Script berjalan TANPA hak Administrator.' -ForegroundColor Red
    Write-Host '  Update membutuhkan hak admin (rename folder di C:\Server).'
    $ans = Read-Host '  Jalankan ulang sebagai Admin sekarang? (y/T) '
    if ($ans -notmatch '^n') {
        Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-PhpDir', "`"$folder`"") `
            -Verb RunAs
        exit
    }
}

# ---------------------------------------------------------------- utils -----
function Pause-AnyKey {
    Write-Host ''
    Write-Host '  Tekan ENTER untuk kembali ke menu...' -NoNewline
    [void](Read-Host)
}

function Show-Header {
    Clear-Host
    Write-Host '  ================================================' -ForegroundColor DarkCyan
    Write-Host '   PHP UPDATER  -  C:\Server' -ForegroundColor Cyan
    Write-Host '  ================================================' -ForegroundColor DarkCyan
    $i = Get-PhpInfo $folder
    if ($i.Exists) {
        $flavor = if ($i.ThreadSafe -eq 'TS') { 'TS (Thread Safe)' } else { 'NTS' }
        Write-Host "   Folder    : $folder"
        Write-Host "   Terpasang : PHP $($i.VersionText)  ($($i.Arch), $flavor)" -ForegroundColor $(if ($i.Version) { 'Green' } else { 'Yellow' })
    } else {
        Write-Host "   Folder    : $folder  (TIDAK DITEMUKAN)" -ForegroundColor Red
    }
    $bak = Get-LatestPhpBackup $folder
    if ($bak) { Write-Host "   Backup    : $($bak.Name)" -ForegroundColor DarkGray }
    Write-Host "   Hak admin : $(if ($isAdmin) { 'YA' } else { 'TIDAK' })   |   Force: $(if ($force) { 'ON' } else { 'OFF' })" `
        -ForegroundColor $(if ($isAdmin) { 'Green' } else { 'Red' })
    Write-Host '  -----------------------------------------------' -ForegroundColor DarkCyan
}

function Show-Menu {
    Write-Host '   [1] Update otomatis (cabang saat ini -> patch terbaru)'
    Write-Host '   [2] Update ke versi tertentu (cabang 8.4 / persis 8.4.12)'
    Write-Host '   [3] Lihat versi yang tersedia di windows.php.net'
    Write-Host '   [4] Ganti folder PHP yang mau di-update'
    Write-Host '   [5] Buka folder backup terbaru'
    Write-Host '   [6] Install PHP BARU (folder baru + vhost fcgid opsional)'
    Write-Host "   [F] Toggle Force  (sekarang: $(if ($force) { 'ON' } else { 'OFF' }))"
    Write-Host '   [0] Keluar'
    Write-Host '  -----------------------------------------------' -ForegroundColor DarkCyan
}

function Invoke-CliUpdate {
    param([string]$Ver = '')
    if (-not $isAdmin -and -not $force) {
        Write-Host ''
        Write-Host '  Update butuh hak Administrator. Jalankan ulang sebagai admin (hapus flag -Force agar opsi elevasi muncul).' -ForegroundColor Red
        return
    }
    if (-not (Test-Path $folder)) {
        Write-Host "  Folder tidak ditemukan: $folder" -ForegroundColor Red
        return
    }
    Write-Host ''
    Write-Host "  Folder : $folder"
    Write-Host "  Target : $(if ($ver) { "PHP $ver" } else { 'patch terbaru cabang saat ini' })"
    Write-Host '  Apache : akan di-stop lalu di-start ulang (kecuali batal di tengah).'
    $ans = Read-Host '  Lanjutkan update? (y/N)'
    if ($ans -notmatch '^y') { Write-Host '  Dibatalkan.' -ForegroundColor Yellow; return }

    $cliArgs = @()
    if ($Ver)          { $cliArgs += @('-Version', $Ver) }
    if ($force)        { $cliArgs += '-Force' }
    & $cliScript -PhpDir $folder @cliArgs
    Write-Host ''
    if ($LASTEXITCODE -eq 0) {
        Write-Host '  Update berhasil.' -ForegroundColor Green
    } else {
        Write-Host "  Update gagal (kode $LASTEXITCODE) - instalasi lama sudah dikembalikan oleh rollback." -ForegroundColor Red
    }
}

function Show-AvailableVersions {
    Write-Host ''
    Write-Host '  Mengambil daftar versi dari windows.php.net...' -ForegroundColor DarkGray
    $i     = Get-PhpInfo $folder
    $index = Get-PhpZipIndex
    if (-not $index) { Write-Host '  Gagal mengambil daftar (cek koneksi internet).' -ForegroundColor Red; return }
    $items = $index |
        Where-Object { $_.Arch -eq $i.Arch -and $_.Nts -eq ($i.ThreadSafe -eq 'NTS') } |
        Sort-Object Version -Descending |
        Select-Object -First 25
    Write-Host ''
    Write-Host ('  {0,-12} {1,-8} {2,-5} {3}' -f 'Versi', 'Compiler', 'Arch', 'Url') -ForegroundColor Cyan
    Write-Host '  ------------------------------------------------------------'
    foreach ($it in $items) {
        Write-Host ('  {0,-12} {1,-8} {2,-5} {3}' -f $it.Version.ToString(), $it.Vc, $it.Arch, $it.Url)
    }
}

function Pick-Folder {
    Write-Host ''
    $folders = @(Get-ServerPhpFolders)
    if ($folders.Count -gt 0) {
        Write-Host '  Folder PHP yang terdeteksi di C:\Server:' -ForegroundColor Cyan
        for ($n = 0; $n -lt $folders.Count; $n++) {
            $i = Get-PhpInfo $folders[$n]
            Write-Host ('  [{0}] {1,-28} PHP {2}' -f ($n + 1), $folders[$n], $i.VersionText)
        }
    }
    Write-Host '  [Ketik path manual juga bisa, mis. D:\php]'
    $ans = Read-Host '  Pilih nomor / ketik path '
    if ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le $folders.Count) {
        $script:folder = $folders[[int]$ans - 1]
    } elseif ($ans) {
        $script:folder = $ans.Trim('"')
    }
}

function Install-New {
    Write-Host ''
    Write-Host '  === INSTALL PHP BARU ===' -ForegroundColor Cyan
    if (-not $isAdmin -and -not $force) {
        Write-Host '  Install butuh hak Administrator. Jalankan ulang sebagai admin.' -ForegroundColor Red
        return
    }
    $v = (Read-Host '  Versi (wajib; mis. 8.4 atau 8.4.12)').Trim()
    if ($v -notmatch '^\d+\.\d+(\.\d+)?$') { Write-Host "  Format tidak dikenal: '$v'" -ForegroundColor Red; return }

    # nama folder saran: 8.4 -> C:\Server\php-8.4 , 8.4.12 -> C:\Server\php-8.4
    $branchStr = if ($v -match '^\d+\.\d+\.\d+$') { (@($v -split '\.')[0..1] -join '.') } else { $v }
    $default   = "C:\Server\php-$branchStr"
    $ans = Read-Host "  Folder target [$default]"
    $target = if ($ans) { $ans.Trim('"').TrimEnd('\') } else { $default }

    if ((Test-Path $target) -and (Get-ChildItem -Path $target -Force -ErrorAction SilentlyContinue)) {
        Write-Host "  Folder sudah berisi file: $target" -ForegroundColor Red
        Write-Host '  Untuk update instalasi itu, pakai menu [1]/[2].'
        return
    }

    # Port default mengikuti cabang PHP seperti vhost lain (8.4 -> 84, 7.4 -> 74),
    # dan Listen-nya ditulis otomatis oleh update-php.ps1.
    $defPort  = $branchStr.Replace('.', '')
    $portArgs = @()
    $portAns  = (Read-Host "  Port vhost fcgid (Enter = $defPort, atau 0 = tanpa vhost)").Trim()
    if ($portAns -eq '') { $portAns = $defPort }
    if ($portAns -ne '0') {
        $port = 0
        if (-not [int]::TryParse($portAns, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            Write-Host "  Port tidak valid: '$portAns'" -ForegroundColor Red
            return
        }
        $portArgs = @('-VhostPort', "$port")
    }

    Write-Host ''
    Write-Host "  Folder : $target"
    Write-Host "  Versi  : $v"
    if ($portArgs.Count -gt 0) { Write-Host "  Vhost  : port $($portArgs[1]) (DocRoot D:/Development)" }
    else                       { Write-Host '  Vhost  : tidak (PHP terpasang tapi belum terhubung Apache)' }
    $ok = Read-Host '  Lanjutkan install? (y/N)'
    if ($ok -notmatch '^y') { Write-Host '  Dibatalkan.' -ForegroundColor Yellow; return }

    & $cliScript -InstallNew -PhpDir $target -Version $v @portArgs
    Write-Host ''
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Install berhasil di $target" -ForegroundColor Green
    } else {
        Write-Host "  Install gagal (kode $LASTEXITCODE)." -ForegroundColor Red
    }
}

# ----------------------------------------------------------------- loop ------
while ($true) {
    Show-Header
    Show-Menu
    $choice = (Read-Host '  Pilih').Trim()
    switch ($choice) {
        '1' { Invoke-CliUpdate -Ver '' }
        '2' {
            $v = (Read-Host '  Masukkan versi (mis. 8.4 atau 8.4.12)').Trim()
            if ($v -notmatch '^\d+(\.\d+){0,2}$') { Write-Host "  Format tidak dikenal: '$v'" -ForegroundColor Red }
            else { Invoke-CliUpdate -Ver $v }
            Pause-AnyKey
        }
        '3' { Show-AvailableVersions; Pause-AnyKey }
        '4' { Pick-Folder; Pause-AnyKey }
        '5' {
            $bak = Get-LatestPhpBackup $folder
            if ($bak) { Start-Process explorer.exe -ArgumentList "`"$($bak.FullName)`"" }
            else      { Write-Host '  Belum ada backup untuk folder ini.' -ForegroundColor Yellow; Pause-AnyKey }
        }
        '6' { Install-New; Pause-AnyKey }
        'F' { $force = -not $force }
        'f' { $force = -not $force }
        '0' { exit 0 }
        default { Write-Host '  Pilihan tidak dikenal.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 700 }
    }
    if ($choice -in @('1', '5')) { Pause-AnyKey }
}
