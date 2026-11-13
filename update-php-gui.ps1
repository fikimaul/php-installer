#Requires -Version 5.1
<#
.SYNOPSIS
    GUI (Windows Forms) untuk update / install baru PHP di C:\Server.

.DESCRIPTION
    Fitur:
      - Pilih folder dengan dialog picker modern Windows (bisa navigasi & ketik path).
      - Dua mode: "Update instalasi yang ada" dan "Install baru (folder baru)".
      - Mode install baru bisa otomatis mendaftarkan vhost mod_fcgid ke
        httpd-vhosts.conf (port bebas, mengikuti pola vhost yang sudah ada).
      - Deteksi otomatis versi/arch/TS instalasi terpilih.
      - Tombol "Cek Versi Tersedia" (daftar build dari windows.php.net).
      - Log real-time berwarna (di-poll dari file, aman cross-thread).
      - Tombol Batal dinonaktifkan otomatis saat fase kritis; tombol backup.
    Semua proses memakai mesin update-php.ps1 (backup + rollback otomatis).

.EXAMPLE
    .\update-php-gui.ps1
.EXAMPLE
    .\update-php-gui.ps1 -PhpDir C:\Server\php-8.4
#>
[CmdletBinding()]
param([string]$PhpDir = 'C:\Server\php')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:LibPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'php-updater-lib.ps1' } else { Join-Path (Get-Location).Path 'php-updater-lib.ps1' }
if (-not (Test-Path $script:LibPath)) {
    [System.Windows.Forms.MessageBox]::Show("php-updater-lib.ps1 tidak ditemukan:`n$script:LibPath", 'PHP Updater', 'OK', 'Error') | Out-Null
    exit 1
}
. $script:LibPath

# --------------------------------------------------------- folder picker -----
# Dialog picker folder gaya Vista/Windows 10 (ada address bar, bisa ketik path).
# Fallback: FolderBrowserDialog lama kalau Add-Type gagal.
$pickerSrc = @'
using System;
using System.Runtime.InteropServices;

public static class VistaFolderPicker
{
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    private class FileOpenDialog { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown),
     Guid("d57dc728-5d6c-4a33-9a20-399314c5f3f5")]
    private interface IFileDialog
    {
        [PreserveSig] int Show(IntPtr hwndParent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint fos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid([MarshalAs(UnmanagedType.LPStruct)] Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
        void GetResults(out IntPtr ppenum);
        void GetSelectedItems(out IntPtr ppsai);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown),
     Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe")]
    private interface IShellItem
    {
        void BindToHandler(IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid bhid,
                           [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    private const uint FOS_PICKFOLDERS = 0x20;
    private const uint FOS_FORCEFILESYSTEM = 0x40;
    private const uint SIGDN_FILESYSPATH = 0x80058000;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHCreateItemFromParsingName(string path, IntPtr pbc,
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IShellItem ppv);

    public static string Pick(string initialPath, string title)
    {
        var dlg = (IFileDialog)new FileOpenDialog();
        uint options;
        dlg.GetOptions(out options);
        dlg.SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
        if (!string.IsNullOrEmpty(title)) dlg.SetTitle(title);

        if (!string.IsNullOrEmpty(initialPath))
        {
            IShellItem folder;
            if (SHCreateItemFromParsingName(initialPath, IntPtr.Zero,
                    typeof(IShellItem).GUID, out folder) == 0)
            {
                try { dlg.SetFolder(folder); }
                finally { Marshal.ReleaseComObject(folder); }
            }
        }

        if (dlg.Show(IntPtr.Zero) != 0) return null;   // dibatalkan

        IShellItem result;
        dlg.GetResult(out result);
        try
        {
            string path;
            result.GetDisplayName(SIGDN_FILESYSPATH, out path);
            return path;
        }
        finally { Marshal.ReleaseComObject(result); }
    }
}
'@
$script:Picker = $null
try {
    if (-not ('VistaFolderPicker' -as [type])) { Add-Type -TypeDefinition $pickerSrc -ErrorAction Stop }
    $script:Picker = 'VistaFolderPicker' -as [type]
} catch { }

function Select-Folder([string]$Initial, [string]$Title) {
    if ($script:Picker) {
        try { return [VistaFolderPicker]::Pick($Initial, $Title) } catch { }
    }
    # Fallback: dialog lama
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description  = $Title
    $dlg.SelectedPath = $Initial
    if ($dlg.ShowDialog() -eq 'OK') { return $dlg.Path }
    return $null
}

# ---------------------------------------------------------------- state ------
$script:IsAdmin = Test-IsAdmin
$script:Running = $false
$script:Proc    = $null
$script:Job     = $null
$script:OutFile = $null
$script:ErrFile = $null
$script:Pos     = @{ Out = 0; Err = 0 }
$script:ExitTicks = 0
$script:SawFail   = $false

# -------------------------------------------------------------------- form ---
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'PHP Updater - C:\Server'
$form.ClientSize      = New-Object System.Drawing.Size(846, 700)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

# --- banner admin
$lblAdmin = New-Object System.Windows.Forms.Label
$lblAdmin.Location  = New-Object System.Drawing.Point(14, 11)
$lblAdmin.Size      = New-Object System.Drawing.Size(630, 20)
$lblAdmin.ForeColor = [System.Drawing.Color]::Firebrick
$lblAdmin.Text      = 'Tanpa hak Administrator - tombol Update/Install dinonaktifkan.'
$lblAdmin.Visible   = -not $script:IsAdmin
$form.Controls.Add($lblAdmin)

$btnElevate = New-Object System.Windows.Forms.Button
$btnElevate.Location  = New-Object System.Drawing.Point(650, 7)
$btnElevate.Size      = New-Object System.Drawing.Size(184, 26)
$btnElevate.Text      = 'Jalankan sebagai Admin'
$btnElevate.Visible   = -not $script:IsAdmin
$btnElevate.Add_Click({
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-PhpDir', "`"$($txtFolder.Text)`"") `
        -Verb RunAs
    $form.Close()
})
$form.Controls.Add($btnElevate)

# --- group: instalasi PHP
$grpInst = New-Object System.Windows.Forms.GroupBox
$grpInst.Location  = New-Object System.Drawing.Point(12, 38)
$grpInst.Size      = New-Object System.Drawing.Size(822, 92)
$grpInst.Text      = ' Folder PHP '
$form.Controls.Add($grpInst)

$lblFolder = New-Object System.Windows.Forms.Label
$lblFolder.Location = New-Object System.Drawing.Point(14, 28)
$lblFolder.Size     = New-Object System.Drawing.Size(84, 20)
$lblFolder.Text     = 'Folder PHP:'
$grpInst.Controls.Add($lblFolder)

$txtFolder = New-Object System.Windows.Forms.TextBox
$txtFolder.Location = New-Object System.Drawing.Point(100, 24)
$txtFolder.Size     = New-Object System.Drawing.Size(604, 23)
$txtFolder.Text     = $PhpDir
$grpInst.Controls.Add($txtFolder)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Location = New-Object System.Drawing.Point(712, 23)
$btnBrowse.Size     = New-Object System.Drawing.Size(96, 25)
$btnBrowse.Text     = 'Jelajahi...'
$btnBrowse.Add_Click({
    $initial = $txtFolder.Text.Trim()
    if (-not (Test-Path $initial)) { $initial = 'C:\Server' }
    $p = Select-Folder $initial 'Pilih folder instalasi PHP'
    if ($p) { $txtFolder.Text = $p; Refresh-Info }
})
$grpInst.Controls.Add($btnBrowse)

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Location = New-Object System.Drawing.Point(14, 58)
$lblInfo.Size     = New-Object System.Drawing.Size(590, 20)
$lblInfo.Text     = 'Terdeteksi: -'
$grpInst.Controls.Add($lblInfo)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Location = New-Object System.Drawing.Point(712, 55)
$btnRefresh.Size     = New-Object System.Drawing.Size(96, 25)
$btnRefresh.Text     = 'Segarkan'
$btnRefresh.Add_Click({ Refresh-Info })
$grpInst.Controls.Add($btnRefresh)

# --- group: versi target
$grpVer = New-Object System.Windows.Forms.GroupBox
$grpVer.Location  = New-Object System.Drawing.Point(12, 138)
$grpVer.Size      = New-Object System.Drawing.Size(822, 92)
$grpVer.Text      = ' Versi Target '
$form.Controls.Add($grpVer)

$lblVer = New-Object System.Windows.Forms.Label
$lblVer.Location = New-Object System.Drawing.Point(14, 30)
$lblVer.Size     = New-Object System.Drawing.Size(94, 20)
$lblVer.Text     = 'Versi target:'
$grpVer.Controls.Add($lblVer)

$cmbVersion = New-Object System.Windows.Forms.ComboBox
$cmbVersion.Location           = New-Object System.Drawing.Point(110, 26)
$cmbVersion.Size               = New-Object System.Drawing.Size(424, 23)
$cmbVersion.AutoCompleteMode   = 'SuggestAppend'
$cmbVersion.AutoCompleteSource = 'ListItems'
[void]$cmbVersion.Items.Add('(Otomatis - patch terbaru cabang saat ini)')
$cmbVersion.SelectedIndex = 0
$grpVer.Controls.Add($cmbVersion)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Location = New-Object System.Drawing.Point(542, 25)
$btnCheck.Size     = New-Object System.Drawing.Size(166, 25)
$btnCheck.Text     = 'Cek Versi Tersedia'
$btnCheck.Add_Click({ Start-CheckVersions })
$grpVer.Controls.Add($btnCheck)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Location  = New-Object System.Drawing.Point(14, 58)
$lblHint.Size      = New-Object System.Drawing.Size(794, 20)
$lblHint.ForeColor = [System.Drawing.Color]::Gray
$lblHint.Text      = 'Update: kosongkan/(Otomatis) = patch terbaru cabang saat ini. Install baru: wajib pilih/ketik versi (8.4 atau 8.4.12).'
$grpVer.Controls.Add($lblHint)

# --- group: mode
$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Location  = New-Object System.Drawing.Point(12, 238)
$grpMode.Size      = New-Object System.Drawing.Size(822, 86)
$grpMode.Text      = ' Mode '
$form.Controls.Add($grpMode)

$radUpdate = New-Object System.Windows.Forms.RadioButton
$radUpdate.Location = New-Object System.Drawing.Point(16, 26)
$radUpdate.Size     = New-Object System.Drawing.Size(240, 20)
$radUpdate.Text     = 'Update instalasi yang ada'
$radUpdate.Checked  = $true
$radUpdate.Add_CheckedChanged({ Update-ModeUi })
$grpMode.Controls.Add($radUpdate)

$radInstall = New-Object System.Windows.Forms.RadioButton
$radInstall.Location = New-Object System.Drawing.Point(266, 26)
$radInstall.Size     = New-Object System.Drawing.Size(300, 20)
$radInstall.Text     = 'Install baru (folder baru, mis. C:\Server\php-8.4)'
$radInstall.Add_CheckedChanged({
    # Saat pindah ke mode install baru, vhost fcgid ikut dibuat secara default
    # (pengguna masih bisa uncheck kalau tidak mau).
    if ($radInstall.Checked) { $chkVhost.Checked = $true }
    Update-ModeUi
})
$grpMode.Controls.Add($radInstall)

$chkVhost = New-Object System.Windows.Forms.CheckBox
$chkVhost.Location = New-Object System.Drawing.Point(16, 54)
$chkVhost.Size     = New-Object System.Drawing.Size(280, 20)
$chkVhost.Text     = 'Daftarkan vhost fcgid otomatis di port'
$chkVhost.Enabled  = $false
$chkVhost.Add_CheckedChanged({ Update-ModeUi })
$grpMode.Controls.Add($chkVhost)

$lblPort = New-Object System.Windows.Forms.Label
$lblPort.Location = New-Object System.Drawing.Point(300, 55)
$lblPort.Size     = New-Object System.Drawing.Size(36, 20)
$lblPort.Text     = 'Port:'
$lblPort.Enabled  = $false
$grpMode.Controls.Add($lblPort)

$txtPort = New-Object System.Windows.Forms.TextBox
$txtPort.Location = New-Object System.Drawing.Point(336, 52)
$txtPort.Size     = New-Object System.Drawing.Size(70, 23)
$txtPort.Text     = '84'
$txtPort.Enabled  = $false
$grpMode.Controls.Add($txtPort)

$lblVhostHint = New-Object System.Windows.Forms.Label
$lblVhostHint.Location  = New-Object System.Drawing.Point(416, 55)
$lblVhostHint.Size      = New-Object System.Drawing.Size(392, 20)
$lblVhostHint.ForeColor = [System.Drawing.Color]::Gray
$lblVhostHint.Text      = 'DocRoot D:/Development (sama seperti vhost lain) + httpd -t sebelum restart.'
$grpMode.Controls.Add($lblVhostHint)

# --- opsi
$chkRestart = New-Object System.Windows.Forms.CheckBox
$chkRestart.Location = New-Object System.Drawing.Point(14, 334)
$chkRestart.Size     = New-Object System.Drawing.Size(260, 20)
$chkRestart.Text     = 'Restart Apache setelah selesai'
$chkRestart.Checked  = $true
$form.Controls.Add($chkRestart)

$chkForce = New-Object System.Windows.Forms.CheckBox
$chkForce.Location = New-Object System.Drawing.Point(288, 334)
$chkForce.Size     = New-Object System.Drawing.Size(300, 20)
$chkForce.Text     = 'Paksa (lewati cek "sudah versi terbaru")'
$form.Controls.Add($chkForce)

# --- tombol aksi
$btnUpdate = New-Object System.Windows.Forms.Button
$btnUpdate.Location  = New-Object System.Drawing.Point(14, 362)
$btnUpdate.Size      = New-Object System.Drawing.Size(180, 36)
$btnUpdate.Text      = 'Update Sekarang'
$btnUpdate.Enabled   = $script:IsAdmin
$btnUpdate.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnUpdate.ForeColor = [System.Drawing.Color]::White
$btnUpdate.FlatStyle = 'Flat'
$btnUpdate.Add_Click({ Start-Update })
$form.Controls.Add($btnUpdate)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Location = New-Object System.Drawing.Point(202, 362)
$btnCancel.Size     = New-Object System.Drawing.Size(120, 36)
$btnCancel.Text     = 'Batalkan'
$btnCancel.Enabled  = $false
$btnCancel.Add_Click({ Stop-Update })
$form.Controls.Add($btnCancel)

$btnBackup = New-Object System.Windows.Forms.Button
$btnBackup.Location = New-Object System.Drawing.Point(330, 362)
$btnBackup.Size     = New-Object System.Drawing.Size(180, 36)
$btnBackup.Text     = 'Buka Folder Backup'
$btnBackup.Add_Click({
    $bak = Get-LatestPhpBackup $txtFolder.Text.Trim()
    if ($bak) {
        Start-Process explorer.exe -ArgumentList "`"$($bak.FullName)`""
        $status.Text = "Backup terbaru: $($bak.FullName)"
    } else {
        $status.Text = 'Belum ada backup untuk folder ini.'
    }
})
$form.Controls.Add($btnBackup)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(520, 370)
$progress.Size     = New-Object System.Drawing.Size(314, 20)
$progress.Style    = 'Blocks'
$form.Controls.Add($progress)

# --- log
$log = New-Object System.Windows.Forms.RichTextBox
$log.Location   = New-Object System.Drawing.Point(12, 408)
$log.Size       = New-Object System.Drawing.Size(822, 248)
$log.ReadOnly   = $true
$log.BackColor  = [System.Drawing.Color]::White
$log.Font       = New-Object System.Drawing.Font('Consolas', 9)
$log.DetectUrls = $true
$log.Text       = 'Log akan muncul di sini.' + "`r`n`r`n"
$form.Controls.Add($log)

# --- status
$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(14, 664)
$status.Size     = New-Object System.Drawing.Size(820, 20)
$status.Text     = if ($script:IsAdmin) { 'Siap.' } else { 'Berjalan tanpa hak admin - hanya untuk melihat info/versi.' }
$form.Controls.Add($status)

# ---------------------------------------------------------------- functions --
function Add-Log {
    param([string]$Text, [System.Drawing.Color]$Color)
    $log.SelectionStart  = $log.TextLength
    $log.SelectionLength = 0
    $log.SelectionColor  = $Color
    $log.AppendText($Text + "`r`n")
    $log.SelectionColor  = $log.ForeColor
    $log.ScrollToCaret()
}

function Get-LogColor([string]$line) {
    if ($line -match 'GAGAL|ROLLBACK|tidak ditemukan|TIDAK kompatibel|tanpa hak') { return [System.Drawing.Color]::Firebrick }
    if ($line -match '^\s*==>')                                                 { return [System.Drawing.Color]::DarkCyan }
    if ($line -match '\[OK\]|SELESAI')                                          { return [System.Drawing.Color]::DarkGreen }
    if ($line -match '^\s*Warning')                                             { return [System.Drawing.Color]::DarkOrange }
    return [System.Drawing.Color]::Black
}

function Update-ModeUi {
    $install = $radInstall.Checked
    $btnUpdate.Text  = if ($install) { 'Install Sekarang' } else { 'Update Sekarang' }
    $chkVhost.Enabled = $install
    $txtPort.Enabled  = $install -and $chkVhost.Checked
    $lblPort.Enabled  = $txtPort.Enabled
    # Restart Apache hanya relevan kalau update, atau install baru + vhost.
    $chkRestart.Enabled = (-not $install) -or $chkVhost.Checked
    Refresh-Info
}

function Refresh-Info {
    $folder  = $txtFolder.Text.Trim()
    $install = $radInstall.Checked
    $i = Get-PhpInfo $folder
    if (-not $i.Exists -or -not $i.HasExe) {
        # Belum ada, atau ada tapi belum ada php.exe (folder kosong) -> aman untuk install baru.
        if ($install) {
            if ($i.Exists) {
                $lblInfo.Text = 'Folder kosong - siap untuk diinstall.'
            } else {
                $lblInfo.Text = 'Folder baru - akan dibuat saat proses install.'
            }
            $lblInfo.ForeColor = [System.Drawing.Color]::DarkGreen
        } elseif ($i.Exists) {
            $lblInfo.Text      = 'Folder ada, tetapi php.exe tidak ditemukan - pilih folder lain (mis. C:\Server\php).'
            $lblInfo.ForeColor = [System.Drawing.Color]::Firebrick
        } else {
            $lblInfo.Text      = 'Folder tidak ditemukan (pilih mode Install baru untuk membuat folder baru).'
            $lblInfo.ForeColor = [System.Drawing.Color]::Firebrick
        }
        return
    }
    $flavor = if ($i.ThreadSafe -eq 'TS') { 'Thread Safe' } else { 'Non-Thread Safe' }
    $extra  = if ($i.HasIni) { '' } else { '  |  php.ini belum ada' }
    if ($install) {
        $lblInfo.Text      = "Folder sudah terisi: PHP $($i.VersionText)  |  $($i.Arch)  |  $flavor  (pakai mode Update!)"
        $lblInfo.ForeColor = [System.Drawing.Color]::Firebrick
    } else {
        $lblInfo.Text      = "Terdeteksi: PHP $($i.VersionText)  |  $($i.Arch)  |  $flavor$extra"
        $lblInfo.ForeColor = if ($i.Version) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkOrange }
    }
}

function Set-Busy([bool]$Busy) {
    $script:Running     = $Busy
    $btnUpdate.Enabled  = (-not $Busy) -and $script:IsAdmin
    $btnCheck.Enabled   = -not $Busy
    $btnBrowse.Enabled  = -not $Busy
    $btnRefresh.Enabled = -not $Busy
    $txtFolder.Enabled  = -not $Busy
    $cmbVersion.Enabled = -not $Busy
    $radUpdate.Enabled  = -not $Busy
    $radInstall.Enabled = -not $Busy
    $chkForce.Enabled   = -not $Busy
    Update-ModeUi
    if ($Busy) {
        $chkVhost.Enabled = $false
        $txtPort.Enabled  = $false
        $lblPort.Enabled  = $false
        $btnCancel.Enabled = $true
        $progress.Style    = 'Marquee'
    } else {
        $btnCancel.Enabled = $false
        $progress.Style    = 'Blocks'
        $progress.Value   = 0
    }
}

# Baca baris baru dari file log child process (aman: file dibuka share-readwrite).
function Read-AppendedLines {
    param([string]$Path, [string]$Key)
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path $Path)) { return @() }
    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($fs.Length -le $script:Pos[$Key]) { return @() }
        $fs.Position = $script:Pos[$Key]
        $sr  = New-Object System.IO.StreamReader($fs)
        $txt = $sr.ReadToEnd()
        $script:Pos[$Key] = $fs.Position
        return @(($txt -split "`r?`n") | Where-Object { $_ -ne '' })
    } catch { return @() }
    finally { if ($fs) { $fs.Dispose() } }
}

function Show-Msg([string]$Msg, [string]$Kind = 'OK') {
    $icon = switch ($Kind) { 'Error' { 'Error' } 'Warning' { 'Warning' } default { 'Information' } }
    [System.Windows.Forms.MessageBox]::Show($Msg, 'PHP Updater', 'OK', $icon) | Out-Null
}

function Start-Update {
    if ($script:Running) { return }
    if (-not $script:IsAdmin) {
        Show-Msg 'Jalankan aplikasi sebagai Administrator dulu (klik tombol "Jalankan sebagai Admin").' 'Warning'
        return
    }
    $install = $radInstall.Checked
    $folder  = $txtFolder.Text.Trim()
    if ([string]::IsNullOrEmpty($folder)) { Show-Msg 'Folder PHP belum diisi.' 'Error'; return }
    if (-not $install -and -not (Test-Path $folder)) {
        Show-Msg "Folder tidak ditemukan:`n$folder`n`nUntuk membuat instalasi baru, pilih mode Install baru." 'Error'
        return
    }
    if ($install -and (Test-Path $folder) -and (Get-ChildItem -Path $folder -Force -ErrorAction SilentlyContinue)) {
        Show-Msg "Folder sudah berisi file:`n$folder`n`nUntuk update, pilih mode Update instalasi yang ada." 'Error'
        return
    }

    # versi
    $ver = $cmbVersion.Text.Trim()
    if ($ver -match '^\(' -or $ver -eq '') { $ver = '' }
    if ($install) {
        if ($ver -notmatch '^\d+\.\d+(\.\d+)?$') {
            Show-Msg 'Install baru membutuhkan versi, mis. "8.4" (cabang) atau "8.4.12" (persis).' 'Error'
            return
        }
    } else {
        if ($ver -ne '' -and $ver -notmatch '^\d+(\.\d+){0,2}$') {
            Show-Msg "Format versi tidak dikenal: '$ver'`n`nGunakan '8.4' (cabang) atau '8.4.12' (persis)." 'Error'
            return
        }
    }

    # vhost (khusus install baru)
    $port = 0
    if ($install -and $chkVhost.Checked) {
        $portTxt = $txtPort.Text.Trim()
        $port = 0
        [void][int]::TryParse($portTxt, [ref]$port)
        if ($port -lt 1 -or $port -gt 65535) {
            Show-Msg "Port vhost tidak valid: '$portTxt' (harus 1-65535)." 'Error'
            return
        }
    }

    # konfirmasi
    $msg  = if ($install) { "INSTALL PHP BARU di:`n$folder`n`n" } else { "UPDATE PHP di:`n$folder`n`n" }
    $msg += if ($ver) { "Target : PHP $ver`n" } else { "Target : patch terbaru cabang saat ini`n" }
    if ($install -and $port -gt 0) { $msg += "Vhost  : mod_fcgid di port $port (DocumentRoot D:/Development)`n" }
    if (-not $install) {
        $msg += if ($chkRestart.Checked) { 'Apache : akan di-stop, lalu di-start ulang.' } else { 'Apache : TIDAK akan di-restart.' }
    } elseif ($port -gt 0) {
        $msg += 'Apache : di-start ulang setelah vhost valid (httpd -t).'
    }
    $msg += "`n`nLanjutkan?"
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Konfirmasi', 'YesNo', 'Question') -ne 'Yes') { return }

    $cli = Join-Path (Split-Path $script:LibPath -Parent) 'update-php.ps1'
    if (-not (Test-Path $cli)) { Show-Msg "update-php.ps1 tidak ditemukan:`n$cli" 'Error'; return }

    $argList = New-Object System.Collections.Generic.List[string]
    $argList.AddRange([string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$cli`"", '-PhpDir', "`"$folder`""))
    if ($install) { $argList.Add('-InstallNew') }
    if ($ver)     { $argList.AddRange([string[]]@('-Version', $ver)) }
    if ($port -gt 0)                    { $argList.AddRange([string[]]@('-VhostPort', "$port")) }
    if ($chkForce.Checked)              { $argList.Add('-Force') }
    if (-not $chkRestart.Checked)       { $argList.Add('-NoRestart') }

    $stamp         = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:OutFile = Join-Path $env:TEMP "phpup-out-$stamp.log"
    $script:ErrFile = Join-Path $env:TEMP "phpup-err-$stamp.log"
    $script:Pos     = @{ Out = 0; Err = 0 }
    $script:ExitTicks = 0
    $script:SawFail   = $false

    Add-Log ('=' * 74) ([System.Drawing.Color]::Gray)
    Add-Log ("{0}: {1} {2}" -f $(if ($install) { 'Install baru' } else { 'Update' }), $folder, $(if ($ver) { "-> PHP $ver" } else { '(otomatis)' })) ([System.Drawing.Color]::Black)
    Add-Log ('=' * 74) ([System.Drawing.Color]::Gray)

    try {
        $script:Proc = Start-Process -FilePath 'powershell.exe' -ArgumentList ($argList -join ' ') `
            -RedirectStandardOutput $script:OutFile -RedirectStandardError $script:ErrFile `
            -NoNewWindow -PassThru
    } catch {
        Show-Msg "Gagal menjalankan proses:`n$($_.Exception.Message)" 'Error'
        return
    }

    Set-Busy $true
    $status.Text = 'Berjalan... download bisa memakan waktu 1-3 menit.'
    $timer.Start()
}

function Stop-Update {
    if ($script:Proc -and -not $script:Proc.HasExited) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Membatalkan di tengah proses bisa membuat instalasi dalam kondisi setengah jalan (perlu rollback manual).`n`nTetap batalkan?",
            'Peringatan', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
        try { $script:Proc.Kill() } catch { }
        Add-Log '!!! Proses dibatalkan paksa oleh user !!!' ([System.Drawing.Color]::Firebrick)
    }
}

function Complete-Update([int]$Code) {
    Set-Busy $false
    Refresh-Info
    Add-Log "Proses selesai (exit code: $Code)..." ([System.Drawing.Color]::Gray)
    # Kegagalan dideteksi ganda: exit code DAN/ATAU adanya baris [ GAGAL ] di log,
    # supaya tetap dilaporkan gagal walau exit code anak proses tidak terbaca benar.
    $gagal = ($Code -ne 0) -or $script:SawFail
    if (-not $gagal) {
        Add-Log '--- SELESAI dengan sukses ---' ([System.Drawing.Color]::DarkGreen)
        $status.Text = 'Selesai, sukses.'
        Show-Msg 'Proses selesai dengan sukses.' 'OK'
    } else {
        $why = if ($Code -ne 0) { "exit code $Code" } else { 'exit code 0 tetapi log berisi [ GAGAL ]' }
        Add-Log "--- GAGAL ($why). Lihat log di atas. ---" ([System.Drawing.Color]::Firebrick)
        $status.Text = "Gagal ($why)."
        Show-Msg "Proses gagal ($why).`n`nCek log di jendela aplikasi. Untuk mode update, instalasi lama sudah dikembalikan oleh rollback." 'Warning'
    }
}

function Start-CheckVersions {
    if ($script:Running) { return }
    $script:Job = Start-Job -ScriptBlock { param($libPath) . $libPath; Get-PhpZipIndex } -ArgumentList $script:LibPath
    $btnCheck.Enabled = $false
    $status.Text      = 'Mengambil daftar versi dari windows.php.net...'
    Add-Log 'Mengambil daftar versi tersedia...' ([System.Drawing.Color]::DarkGray)
    $timerJob.Start()
}

# ------------------------------------------------------------------- timer ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    foreach ($line in Read-AppendedLines $script:OutFile 'Out') {
        Add-Log $line (Get-LogColor $line)
        if ($line -match 'Backup:') { $btnCancel.Enabled = $false }
        if ($line -match '\[ GAGAL \]') { $script:SawFail = $true }
    }
    foreach ($line in Read-AppendedLines $script:ErrFile 'Err') {
        Add-Log $line (Get-LogColor $line)
    }
    if ($script:Proc -and $script:Proc.HasExited) {
        $script:ExitTicks++
        if ($script:ExitTicks -ge 2) {
            $timer.Stop()
            Complete-Update ([int]$script:Proc.ExitCode)
        }
    } else {
        $script:ExitTicks = 0
    }
})

$timerJob = New-Object System.Windows.Forms.Timer
$timerJob.Interval = 500
$timerJob.Add_Tick({
    if (-not $script:Job) { $timerJob.Stop(); return }
    if (@('Completed', 'Failed', 'Stopped') -notcontains $script:Job.State) { return }
    $timerJob.Stop()
    $ok    = $script:Job.State -eq 'Completed'
    $items = if ($ok) { Receive-Job $script:Job -ErrorAction SilentlyContinue } else { $null }
    Remove-Job $script:Job -Force
    $script:Job = $null
    $btnCheck.Enabled = $true
    if (-not $ok -or -not $items) {
        $status.Text = 'Gagal mengambil daftar versi (cek koneksi internet).'
        Add-Log 'Gagal mengambil daftar versi dari windows.php.net.' ([System.Drawing.Color]::Firebrick)
        return
    }
    # Folder belum ada (mode install baru) -> pakai default instalasi: x64 + TS.
    $i       = Get-PhpInfo $txtFolder.Text.Trim()
    $arch    = if ($i.Arch)     { $i.Arch }     else { 'x64' }
    $wantNts = if ($i.ThreadSafe) { $i.ThreadSafe -eq 'NTS' } else { $false }
    $versions = @($items |
        Where-Object { $_.Arch -eq $arch -and $_.Nts -eq $wantNts } |
        Sort-Object Version -Descending |
        ForEach-Object { $_.Version.ToString() } |
        Select-Object -Unique)
    $cmbVersion.Items.Clear()
    [void]$cmbVersion.Items.Add('(Otomatis - patch terbaru cabang saat ini)')
    foreach ($v in $versions) { [void]$cmbVersion.Items.Add($v) }
    $cmbVersion.SelectedIndex = 0
    # Mode install baru butuh versi eksplisit -> pilih otomatis versi pertama (terbaru).
    if ($radInstall.Checked -and $cmbVersion.Items.Count -gt 1) { $cmbVersion.SelectedIndex = 1 }
    $status.Text = "Ditemukan $($versions.Count) versi untuk $arch/$(if ($wantNts) { 'NTS' } else { 'TS' }). Pilih lalu klik Update/Install."
    Add-Log "Daftar versi dimuat: $($versions.Count) build tersedia." ([System.Drawing.Color]::DarkGreen)
})

# ------------------------------------------------------------------ startup --
$form.Add_Shown({
    Update-ModeUi
    Refresh-Info
    if (-not $script:IsAdmin) {
        Add-Log 'Berjalan tanpa hak Administrator. Klik "Jalankan sebagai Admin" untuk bisa meng-update/menginstall.' ([System.Drawing.Color]::Firebrick)
    }
})
$form.Add_FormClosed({
    $timer.Stop()
    $timerJob.Stop()
    if ($script:Job) { Remove-Job $script:Job -Force }
    if ($script:Proc -and -not $script:Proc.HasExited) {
        $r = [System.Windows.Forms.MessageBox]::Show('Proses masih berjalan. Tutup aplikasi dan hentikan prosesnya?', 'PHP Updater', 'YesNo', 'Warning')
        if ($r -eq 'Yes') { try { $script:Proc.Kill() } catch { } }
    }
})

[void]$form.ShowDialog()
