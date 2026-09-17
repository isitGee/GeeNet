<#
================================================================================
  GeeNet - Windows Network Toolkit
  Diagnose | Troubleshoot | Repair
  Made by George Mwanga  +255762358050   github.com/isitgee
================================================================================
  Two modes:
    [1] Beginner / Guided Troubleshooting  - plain-English IT-support style wizard
    [2] Professional / Advanced Tools      - direct access to the classic tools

  Design:
      Core primitives  ->  Diagnostic tests  ->  Interpretation engine
                                              ->  Verdict / next-step engine
                                              ->  Repair engine (explained + retested)
                                              ->  Guided scenarios (data-driven)
      Nothing here needs the internet to launch. Core diagnostics are offline-safe.
      Everything uses built-in Windows tools only (no third-party modules).
================================================================================
#>

[CmdletBinding()]
param(
    # Mode shortcuts (GeeNet.bat <-> GeeNet.ps1)
    [switch]$Beginner,
    [switch]$Professional,

    # Diagnostics / maintenance
    [switch]$SelfTest,          # run internal self test and exit
    [switch]$Ascii,             # force ASCII markers instead of Unicode ones
    [switch]$NoElevate,         # never offer to relaunch as Administrator
    [switch]$NoBanner,          # skip the title banner
    [switch]$Version            # print version and exit
)

# ------------------------------------------------------------------------------
#region 1. BOOTSTRAP / GLOBAL STATE
# ------------------------------------------------------------------------------

$script:GeeNetVersion = "2.0"
$script:GeeNetAuthor  = "George Mwanga"
$script:GeeNetPhone   = "+255762358050"
$script:GeeNetGitHub  = "github.com/isitgee"
$script:GeeNetRoot    = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:GeeNetReports = Join-Path $script:GeeNetRoot "reports"

# Keep the console readable: we handle our own errors and never spray red text at users.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# Non-interactive mode is used by the built-in self test / automated checks.
$script:GNInteractive = $true
$script:GNAnswerQueue = New-Object System.Collections.Generic.Queue[string]

# Session state: one object that everything can log into.
$script:GNSession = $null
$script:GNLogFile = $null

function New-GeeNetSession {
    $script:GNSession = [ordered]@{
        Started      = Get-Date
        Mode         = ''
        SymptomId    = ''
        SymptomText  = ''
        CategoryId   = ''
        Answers      = [ordered]@{}
        Log          = New-Object System.Collections.Generic.List[object]
        Results      = New-Object System.Collections.Generic.List[object]
        StoppedReason= ''
        Verdict      = $null
        Repairs      = New-Object System.Collections.Generic.List[object]
        Findings     = New-Object System.Collections.Generic.List[string]
        OutageScope  = ''
        SavedReport  = ''
    }
    Reset-GeeNetLogFile
}

function Reset-GeeNetLogFile {
    $stamp = (Get-Date).ToString("yyyyMMdd")
    $tempRoot = ''
    try { $tempRoot = [System.IO.Path]::GetTempPath() } catch { }
    if (-not $tempRoot) { $tempRoot = "$env:TEMP" }
    if (-not $tempRoot) { $tempRoot = $script:GeeNetReports }
    # Try the temporary folder first (it is the natural place for a session log), and
    # fall back to the reports folder. A log must never be the reason GeeNet stops.
    foreach ($candidate in @((Join-Path $tempRoot "GeeNet"), $script:GeeNetReports)) {
        try {
            if (-not (Test-Path $candidate)) { New-Item -ItemType Directory -Path $candidate -Force | Out-Null }
            $probe = Join-Path $candidate ".geenet-write-test"
            Set-Content -Path $probe -Value 'ok' -Encoding ASCII -ErrorAction Stop
            Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
            $script:GNLogFile = Join-Path $candidate "GeeNet_Session_$stamp.log"
            return
        } catch { }
    }
    $script:GNLogFile = $null
}

function Write-GeeNetLog {
    <#
      Diagnostic session log. Timestamped, terse, greppable - this is what the user
      can attach to a support ticket. Never logs passwords/keys.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','PASS','FAIL','WARN','SKIP','ACTION','STEP')]
        [string]$Level = 'INFO'
    )
    $entry = [pscustomobject]@{
        Time    = (Get-Date).ToString("HH:mm:ss")
        Level   = $Level
        Message = $Message
    }
    if ($script:GNSession) { [void]$script:GNSession.Log.Add($entry) }
    if ($script:GNLogFile) {
        try { Add-Content -Path $script:GNLogFile -Value ("{0}  {1,-6} {2}" -f $entry.Time, $entry.Level, $entry.Message) -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    }
    return $entry
}

function Get-GeeNetLogLines {
    if (-not $script:GNSession) { return @() }
    return @($script:GNSession.Log | ForEach-Object { "{0}  {1}" -f $_.Time, $_.Message })
}

# ------------------------------------------------------------------------------
#region 2. CONSOLE / LANGUAGE LAYER (glyphs, formatting, wrapping)
# ------------------------------------------------------------------------------

function Test-GeeNetUnicodeConsole {
    if ($Ascii) { return $false }
    if ($env:GEENET_NO_UNICODE -eq '1') { return $false }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        try { return (([Console]::OutputEncoding.WebName) -match 'utf-?8') } catch { return $false }
    }
    # Windows PowerShell 5.1: only trust Unicode output when the console code page is UTF-8
    try { return (([Console]::OutputEncoding.WebName) -match 'utf-?8') } catch { return $false }
}

$script:GNUnicode = Test-GeeNetUnicodeConsole

# Status marks. Pass/Fail/Tick/Cross must agree with each other, otherwise the same
# result looks different depending on which screen it appears on.
if ($script:GNUnicode) {
    $script:GNG = @{ Pass=[char]0x2713; Fail=[char]0x2717; Warn='!'; Info='i'; Skip='-'
                     Bullet='-'; Arrow='->'; Dot='*'; Bang='!'; Blob='*'; Triangle='!'; Back=[char]0x2190
                     Tick=[char]0x2713; Cross=[char]0x2717 }
} else {
    $script:GNG = @{ Pass='OK'; Fail='X'; Warn='!'; Info='i'; Skip='-'
                     Bullet='-'; Arrow='->'; Dot='*'; Bang='!'; Blob='*'; Triangle='!'; Back='<'
                     Tick='+'; Cross='x' }
}

# Palette - one place to change the look of the whole tool.
$script:GNCol = @{
    Title    = 'Cyan'
    SubTitle = 'DarkCyan'
    Head     = 'Yellow'
    Text     = 'Gray'
    Bright   = 'White'
    Pass     = 'Green'
    Fail     = 'Red'
    Warn     = 'DarkYellow'
    Info     = 'Cyan'
    Tech     = 'DarkGray'
    Action   = 'Magenta'
    Accent   = 'Green'
    Dim      = 'DarkGray'
}

$script:GNW = 78   # target content width

# --- output core ---------------------------------------------------------------
$script:GNLineBuffer = ''

function Write-GNOut {
    param(
        [string]$Text = '',
        [string]$Color = 'Gray',
        [switch]$NoNewline
    )
    try {
        if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline }
        else { Write-Host $Text -ForegroundColor $Color }
    } catch { }
    $script:GNLineBuffer += $Text
    if (-not $NoNewline) {
        [void]$script:GNTranscript.Add($script:GNLineBuffer)
        $script:GNLineBuffer = ''
    }
}

$script:GNTranscript = New-Object System.Collections.Generic.List[string]

function Write-GNPair {
    <#  Renders "  Label ............ value" style rows used in the summary blocks. #>
    param(
        [string]$Label,
        [string]$Value,
        [string]$LabelColor = 'Gray',
        [string]$ValueColor = 'White',
        [int]$Indent = 2,
        [int]$Width = 30
    )
    $pad = ' ' * $Indent
    $lbl = $Label
    if ($lbl.Length -gt ($Width - 2)) { $lbl = $lbl.Substring(0, [Math]::Max(1, $Width - 3)) + '.' }
    $dots = '.' * ([Math]::Max(1, $Width - $lbl.Length))
    Write-GNOut ("{0}{1} {2} " -f $pad, $lbl, $dots) -Color $LabelColor -NoNewline
    Write-GNOut $Value -Color $ValueColor
}

function Write-GNRule {
    param([string]$Char = '-', [int]$Indent = 2, [int]$Width = 0, [string]$Color = 'DarkCyan')
    if ($Width -le 0) { $Width = $script:GNW - $Indent }
    Write-GNOut ((' ' * $Indent) + ($Char * $Width)) -Color $Color
}

function Split-GNText {
    <#  Word-wrap helper. Never splits inside a word unless the word itself is too long. #>
    param([string]$Text, [int]$Width = 74)
    $out = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return @('') }
    foreach ($rawLine in ($Text -split "`r?`n")) {
        if ($rawLine.Trim().Length -eq 0) { $out += ''; continue }
        $words = $rawLine.Trim() -split '\s+'
        $cur = ''
        foreach ($w in $words) {
            if ($cur.Length -eq 0) { $cur = $w }
            elseif (($cur.Length + 1 + $w.Length) -le $Width) { $cur += ' ' + $w }
            else {
                $out += $cur
                while ($w.Length -gt $Width) { $out += $w.Substring(0, $Width); $w = $w.Substring($Width) }
                $cur = $w
            }
        }
        if ($cur.Length -gt 0) { $out += $cur }
    }
    return $out
}

function Write-GNPara {
    <#  Wrapped paragraph with hanging indent. The workhorse of explanation output. #>
    param(
        [string]$Text,
        [string]$Color = 'Gray',
        [int]$Indent = 6,
        [int]$Width = 0,
        [string]$Bullet = ''
    )
    if ($Width -le 0) { $Width = $script:GNW - $Indent - 2 }
    $lines = Split-GNText -Text $Text -Width $Width
    $pad = ' ' * $Indent
    $first = $true
    foreach ($l in $lines) {
        $marker = $pad
        if ($first -and $Bullet) { $marker = (' ' * [Math]::Max(0, $Indent - 2)) + $Bullet + ' ' }
        Write-GNOut ($marker + $l) -Color $Color
        $first = $false
    }
}

function Write-GNList {
    param(
        [string[]]$Items,
        [string]$Color = 'Gray',
        [int]$Indent = 6,
        [string]$Marker = $null
    )
    if (-not $Marker) { $Marker = $script:GNG.Bullet }
    foreach ($i in @($Items)) {
        if ([string]::IsNullOrWhiteSpace($i)) { continue }
        # Sub-bullets: items starting with '-' render as indented dashes.
        if ($i.StartsWith('-')) {
            Write-GNPara -Text $i.Substring(1).Trim() -Color $Color -Indent ($Indent + 3) -Bullet '-'
        } else {
            Write-GNPara -Text $i -Color $Color -Indent $Indent -Bullet $Marker
        }
    }
}

function Write-GNSection {
    param([string]$Title, [string]$Color = 'Yellow')
    Write-GNOut ''
    Write-GNOut ("  " + $Title.ToUpper()) -Color $Color
    Write-GNRule '=' 2 ($script:GNW - 4) $Color
}

function Write-GNInfo  { param([string]$Text) Write-GNPara -Text $Text -Color $script:GNCol.Text -Indent 4 }
function Write-GNTech  { param([string]$Text) if ($Text) { Write-GNPara -Text ("Technical detail: " + $Text) -Color $script:GNCol.Tech -Indent 4 } }
function Write-GNAction{ param([string]$Text) Write-GNPara -Text $Text -Color $script:GNCol.Action -Indent 4 }
function Write-GNWarn  { param([string]$Text) Write-GNPara -Text $Text -Color $script:GNCol.Warn -Indent 4 }

function Write-GNBanner {
    param([string]$Mode = '')
    Write-GNOut ''
    Write-GNOut "   ____            _   _      _   " -Color Cyan
    Write-GNOut "  / ___| ___  ___ | \ | | ___| |_ " -Color Cyan
    Write-GNOut " | |  _ / _ \/ _ \|  \| |/ _ \ __|" -Color Cyan
    Write-GNOut " | |_| |  __/  __/| |\  |  __/ |_ " -Color Cyan
    Write-GNOut "  \____|\___|\___||_| \_|\___|\__|" -Color Cyan
    Write-GNOut ''
    Write-GNOut "  GeeNet " -Color White -NoNewline
    Write-GNOut ("v" + $script:GeeNetVersion) -Color DarkGray -NoNewline
    Write-GNOut "  -  Windows Network Toolkit" -Color White
    Write-GNOut "  Diagnose  |  Troubleshoot  |  Repair" -Color DarkCyan
    if ($Mode) { Write-GNOut ("  Mode: " + $Mode) -Color DarkCyan }
    Write-GNOut ''
    Write-GNOut ("  Made by " + $script:GeeNetAuthor + " " + $script:GeeNetPhone) -Color Green
    Write-GNOut ("  " + $script:GeeNetGitHub) -Color DarkGreen
}

function Write-Header {
    <#  Kept from the original tool (same name, same job) - used by every screen. #>
    Clear-Host
    Write-GNOut ''
    Write-GNOut "  GeeNet" -Color Cyan
    Write-GNOut "  Windows Network Toolkit" -Color White
    Write-GNOut "  Diagnose  |  Troubleshoot  |  Repair" -Color DarkCyan
    Write-GNOut ''
    Write-GNOut ("  Made by " + $script:GeeNetAuthor + " " + $script:GeeNetPhone) -Color Green
    Write-GNOut ("  " + $script:GeeNetGitHub) -Color DarkGreen
    Write-GNOut ''
    Write-GNOut "  --------------------------------------------------------" -Color DarkCyan
    Write-GNOut ''
}

function Pause-GeeNet {
    param([string]$Message = '  Press Enter to return to the menu')
    if (-not $script:GNInteractive) { return }
    Write-GNOut ''
    [void](Read-GNInput -Prompt $Message)
}

# ------------------------------------------------------------------------------
#region 3. INPUT LAYER (interactive + scriptable for self tests)
# ------------------------------------------------------------------------------

function Read-GNInput {
    <#  Single funnel for all keyboard input so automated tests can drive the tool. #>
    param([string]$Prompt = '', [string]$Default = '', [string]$Color = 'White')
    if (-not $Prompt) { $Prompt = '  > ' }
    $script:GNLineBuffer += $Prompt
    if (-not $script:GNInteractive) {
        $answer = ''
        if ($script:GNAnswerQueue.Count -gt 0) { $answer = $script:GNAnswerQueue.Dequeue() }
        Write-GNOut ($Prompt + $answer) -Color $script:GNCol.Dim
        return $answer
    }
    try {
        $val = Read-Host $Prompt
    } catch { $val = '' }
    [void]$script:GNTranscript.Add($script:GNLineBuffer + $val)
    $script:GNLineBuffer = ''
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val.Trim()
}

function Read-GNConfirm {
    <#  Yes/No gate. Everything disruptive goes through here. #>
    param([string]$Prompt = '  Continue?', [bool]$DefaultYes = $false)
    $suffix = if ($DefaultYes) { ' [Y/n] ' } else { ' [y/N] ' }
    $wrong = 0
    while ($true) {
        $a = Read-GNInput -Prompt ($Prompt + $suffix)
        if ([string]::IsNullOrWhiteSpace($a)) { return $DefaultYes }
        if ($a -match '^(y|yes)$') { return $true }
        if ($a -match '^(n|no)$') { return $false }
        $wrong++
        if ($wrong -ge 4) {
            # Something is feeding us unusable input: fall back to the safe answer.
            Write-GNOut "  No usable answer was received - using the safe default." -Color $script:GNCol.Warn
            return $DefaultYes
        }
        Write-GNOut "  Please answer Y or N." -Color $script:GNCol.Warn
    }
}

function Read-GNChoice {
    <#  Menu prompt with [0] back support. #>
    param([string]$Prompt = '  Select an option', [string[]]$Valid = @())
    $blanks = 0
    while ($true) {
        $a = Read-GNInput -Prompt $Prompt
        if ($a -eq '') {
            $blanks++
            # A menu must never loop forever: if no answer arrives (no console, closed input)
            # or the user presses Enter a few times, treat it as "0" (back/exit).
            if (-not $script:GNInteractive -or $blanks -ge 3) { return '0' }
            continue
        }
        if ($Valid.Count -eq 0) { return $a }
        if ($Valid -contains $a) { return $a }
        Write-GNOut ("  '" + $a + "' is not one of the options shown above.") -Color $script:GNCol.Warn
    }
}

function Wait-GNCountdown {
    <#  Short visible wait so the user knows something is happening (no fake delays). #>
    param([int]$Seconds = 3, [string]$Message = 'Waiting')
    if (-not $script:GNInteractive) { return }
    for ($i = $Seconds; $i -gt 0; $i--) {
        Write-GNOut ("`r  " + $Message + " ... " + $i + "s ") -Color $script:GNCol.Dim -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-GNOut "`r" -NoNewline
    Write-GNOut ("  " + $Message + " ... done") -Color $script:GNCol.Dim
}

# ------------------------------------------------------------------------------
#region 4. PRIVILEGE / ELEVATION
# ------------------------------------------------------------------------------

function Test-GeeNetAdmin {
    <#  $true when running elevated. Used to decide whether a repair is even possible. #>
    try {
        if ($env:OS -ne 'Windows_NT') { return $false }
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Write-GNAdminState {
    if (Test-GeeNetAdmin) {
        Write-GNOut "  Privileges : Administrator" -Color Green
    } else {
        Write-GNOut "  Privileges : Standard user" -Color DarkYellow
        Write-GNPara -Text "Some repairs (Winsock/TCP-IP reset, adapter restarts, network reset) need Administrator rights. GeeNet will tell you before anything like that runs." -Color DarkGray -Indent 15
    }
}

function Invoke-GeeNetElevated {
    <#
      Runs a single command in an elevated PowerShell window and returns its output + exit code.
      Uses a temp result file so we can report honestly whether it worked - we never assume success.
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [int]$WaitSeconds = 120
    )
    $result = [pscustomobject]@{ Attempted = $false; Elevated = $false; Success = $false; Output = ''; ExitCode = $null }
    if (Test-GeeNetAdmin) { return $result }   # caller should run inline instead
    try {
        $tmpDir = Join-Path $env:TEMP "GeeNet"
        if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
        $tag = [Guid]::NewGuid().ToString('N').Substring(0,8)
        $ps1 = Join-Path $tmpDir "elev_$tag.ps1"
        $out = Join-Path $tmpDir "elev_$tag.out"
        $wrapper = @"
`$ErrorActionPreference='Continue'
`$output = ''
try {
    `$output = & { $Command } 2>&1 | Out-String
    `$code = `$LASTEXITCODE
} catch { `$output = `$_.Exception.Message; `$code = 1 }
Set-Content -Path '$out' -Value (("EXITCODE=" + `$code) + "`n" + `$output) -Encoding UTF8
"@
        Set-Content -Path $ps1 -Value $wrapper -Encoding UTF8
        $result.Attempted = $true
        $proc = Start-Process -FilePath "powershell.exe" `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$ps1`"") `
            -Verb RunAs -PassThru -WindowStyle Normal -ErrorAction Stop
        if ($proc) { [void]$proc.WaitForExit($WaitSeconds * 1000) }
        if (Test-Path $out) {
            $raw = Get-Content -Path $out -Raw -ErrorAction SilentlyContinue
            if ($raw -match '(?s)^EXITCODE=(-?\d+)\s*(.*)$') {
                $result.ExitCode = [int]$Matches[1]
                $result.Output   = $Matches[2].Trim()
                $result.Success  = ($result.ExitCode -eq 0)
            } else { $result.Output = "$raw" }
        }
        $result.Elevated = $true
        Remove-Item $ps1, $out -Force -ErrorAction SilentlyContinue
    } catch {
        # User clicked "No" on the UAC prompt, or elevation is blocked by policy.
        $result.Output = "Elevation was cancelled or refused: " + $_.Exception.Message
    }
    return $result
}

function Request-GeeNetElevationRestart {
    <#  Relaunch the whole tool elevated (used from the main menu / .bat path). #>
    if (Test-GeeNetAdmin) { return $false }
    if ($NoElevate) { return $false }
    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) { return $false }
    try {
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
        if ($Beginner) { $argList += '-Beginner' } elseif ($Professional) { $argList += '-Professional' }
        Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-GNOut ''
        Write-GNOut "  Could not restart with Administrator rights (UAC was declined)." -Color $script:GNCol.Warn
        Write-GNOut "  GeeNet will keep running - repairs that need admin rights will tell you so." -Color $script:GNCol.Dim
        Start-Sleep -Milliseconds 900
        return $false
    }
}

# ------------------------------------------------------------------------------
#region 5. ENVIRONMENT / CAPABILITY DETECTION
# ------------------------------------------------------------------------------

$script:GNIsWindows = $true
try { $script:GNIsWindows = ([System.Environment]::OSVersion.Platform -eq 'Win32NT') } catch { }

# Modern TLS for HTTPS checks (PowerShell 5.1 defaults can be TLS 1.0 only).
try {
    $tls = [Net.SecurityProtocolType]::Tls12
    if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $tls
    }
} catch { }

function Test-GNCommand {
    param([string]$Name)
    try { return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue) } catch { return $false }
}

function Get-GNSystemFacts {
    $facts = [ordered]@{
        ComputerName = $(if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { try { [Environment]::MachineName } catch { 'unknown' } })
        User         = $(if ($env:USERNAME) { $env:USERNAME } else { try { [Environment]::UserName } catch { 'unknown' } })
        Domain       = $env:USERDOMAIN
        OSName       = 'Unknown'
        OSVersion    = ''
        OSBuild      = ''
        Architecture = $env:PROCESSOR_ARCHITECTURE
        PowerShell   = $PSVersionTable.PSVersion.ToString()
        IsAdmin      = (Test-GeeNetAdmin)
        LastBoot     = $null
        UptimeHours  = $null
        Vendor       = ''
        Model        = ''
    }
    try {
        if (Test-GNCommand Get-CimInstance) {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($os) {
                $facts.OSName    = $os.Caption
                $facts.OSVersion = $os.Version
                $facts.OSBuild   = $os.BuildNumber
                if ($os.LastBootUpTime) {
                    $facts.LastBoot = $os.LastBootUpTime
                    $facts.UptimeHours = [Math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
                }
            }
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
            if ($cs) { $facts.Vendor = $cs.Manufacturer; $facts.Model = $cs.Model }
        }
    } catch { }
    if ($facts.OSName -eq 'Unknown') {
        try {
            $k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
            if ($k) {
                $facts.OSName    = "$($k.ProductName)"
                $facts.OSVersion = "$($k.CurrentVersion)$($k.DisplayVersion)"
                $facts.OSBuild   = "$($k.CurrentBuild).$($k.UBR)"
            }
        } catch { }
    }
    return [pscustomobject]$facts
}

function Test-GNPendingReboot {
    $flags = @()
    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $flags += 'Windows Update' }
        if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations') { $flags += 'pending file rename' }
        $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
        if ($pfro) { }
    } catch { }
    return $flags
}

# ------------------------------------------------------------------------------
#region 6. GATHERERS (normalised hardware / configuration views)
# ------------------------------------------------------------------------------

function Get-GNAdapters {
    <#
      Returns a normalised adapter list no matter which Windows version we are on.
      Shape: Name, Description, Status, LinkSpeed, MacAddress, InterfaceIndex,
             MediaType, IsWifi, IsEthernet, IsVirtual, DriverName, DriverDate
    #>
    $list = New-Object System.Collections.Generic.List[object]

    $add = {
        param($name, $desc, $status, $speed, $mac, $index, $media, $driver, $driverDate, $virtual)
        $isWifi = $false
        $isEth  = $false
        $probe = ("$name $desc $media").ToLower()
        if ($probe -match 'wi-?fi|wireless|wlan|802\.11|80211') { $isWifi = $true }
        if ($probe -match 'ethernet|eth[0-9]|gigabit|realtek pcie|intel\(r\) i219|usb.*lan') { $isEth = $true }
        if ($probe -match 'loopback|tunnel|teredo|isatap|6to4|bluetooth|kernel debug') { $virtual = $true }
        if ($probe -match 'virtual|vmware|hyper-v|vethernet|virtualbox|npcap|tap-|tun|wireguard|openvpn|zerotier|radmin|hamachi') { $virtual = $true }
        $list.Add([pscustomobject]@{
            Name           = "$name"
            Description    = "$desc"
            Status         = "$status"
            LinkSpeed      = "$speed"
            MacAddress     = "$mac"
            InterfaceIndex = $index
            MediaType      = "$media"
            IsWifi         = $isWifi
            IsEthernet     = ($isEth -and -not $isWifi)
            IsVirtual      = $virtual
            DriverName     = "$driver"
            DriverDate     = "$driverDate"
        })
    }

    if (Test-GNCommand Get-NetAdapter) {
        try {
            $nas = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue)
            foreach ($a in $nas) {
                $dName = ''; $dDate = ''
                try { if ($a.DriverInformation) { $dName = $a.DriverInformation.DriverFileName; $dDate = $a.DriverInformation.DriverDate } } catch { }
                & $add $a.Name $a.InterfaceDescription $a.Status $a.LinkSpeed $a.MacAddress $a.ifIndex $a.MediaType $dName $dDate $false
            }
            if ($list.Count -gt 0) { return $list }
        } catch { }
    }

    if (Test-GNCommand Get-CimInstance) {
        try {
            $cim = @(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue |
                     Where-Object { $_.PhysicalAdapter -eq $true -or $_.NetConnectionID })
            foreach ($c in $cim) {
                $status = switch ($c.NetConnectionStatus) {
                    2 { 'Up' } 1 { 'Disconnected' } 0 { 'Disabled' } 7 { 'Disabled' } 3 { 'Disconnected' } default { 'Unknown' }
                }
                if ($c.NetConnectionStatus -eq 0 -or $c.NetConnectionStatus -eq 7) { $status = 'Disabled' }
                $speed = ''
                if ($c.Speed) { $speed = ("{0} bps" -f $c.Speed) }
                & $add $c.NetConnectionID $c.Name $status $speed $c.MACAddress $c.InterfaceIndex $c.AdapterType '' '' ($c.PhysicalAdapter -ne $true)
            }
            if ($list.Count -gt 0) { return $list }
        } catch { }
    }

    # Last resort: .NET view (always available, less detail)
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            $status = switch ("$($ni.OperationalStatus)") { 'Up' { 'Up' } 'Down' { 'Disconnected' } default { "$($ni.OperationalStatus)" } }
            $speed = ''
            try { if ($ni.Speed -gt 0) { $speed = ("{0} bps" -f $ni.Speed) } } catch { }
            & $add $ni.Name $ni.Description $status $speed $ni.GetPhysicalAddress().ToString() '' "$($ni.NetworkInterfaceType)" '' '' $false
        }
    } catch { }
    return $list
}

function Get-GNIPConfig {
    <#
      Normalised IP configuration. Prefers Get-NetIPConfiguration, falls back to
      ipconfig /all parsing on very old systems.
      Shape: Adapter, InterfaceIndex, IPv4, PrefixLength, SubnetMask, Gateway,
             DnsServers, DhcpEnabled, DhcpServer, Apipa, IsWifi, MediaType, ProfileName, NetworkCategory
    #>
    $list = New-Object System.Collections.Generic.List[object]

    if (Test-GNCommand Get-NetIPConfiguration) {
        try {
            $cfgs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)
            foreach ($c in $cfgs) {
                $ip4 = ''; $prefix = $null; $mask = ''
                try {
                    $first = $c.IPv4Address | Select-Object -First 1
                    if ($first) { $ip4 = "$($first.IPAddress)"; $prefix = $first.PrefixLength }
                } catch { }
                if ($prefix -ne $null) { $mask = Convert-GNPrefixToMask -PrefixLength ([int]$prefix) }
                $gw = ''
                try { $g = $c.IPv4DefaultGateway | Select-Object -First 1; if ($g) { $gw = "$($g.NextHop)" } } catch { }
                $dns = @()
                try { $dns = @($c.DNSServer | Where-Object { $_.AddressFamily -eq 2 -and $_.ServerAddresses } | ForEach-Object { $_.ServerAddresses } | Select-Object -Unique) } catch { }
                if ($dns.Count -eq 0) {
                    try { $dns = @($c.DNSServer | ForEach-Object { $_.ServerAddresses } | Select-Object -Unique) } catch { }
                }
                $dhcpEnabled = $null
                try { if ($c.NetIPv4Interface) { $dhcpEnabled = ("$($c.NetIPv4Interface.Dhcp)" -eq 'Enabled') } } catch { }
                $dnsSuffix = ''
                try { $dnsSuffix = "$($c.NetIPv4Interface.DnsSuffix)" } catch { }
                $profile = ''; $category = ''
                try { if ($c.NetProfile) { $profile = "$($c.NetProfile.Name)"; $category = "$($c.NetProfile.NetworkCategory)" } } catch { }
                $status = ''
                try { $status = "$($c.NetAdapter.Status)" } catch { }
                $isWifi = $false
                try { if ($c.NetAdapter -and "$($c.NetAdapter.MediaType)" -match '802\.11') { $isWifi = $true } } catch { }

                $list.Add([pscustomobject]@{
                    Adapter         = "$($c.InterfaceAlias)"
                    InterfaceIndex  = $c.InterfaceIndex
                    IPv4            = $ip4
                    PrefixLength    = $prefix
                    SubnetMask      = $mask
                    Gateway         = $gw
                    DnsServers      = @($dns)
                    DnsSuffix       = $dnsSuffix
                    DhcpEnabled     = $dhcpEnabled
                    DhcpServer      = ''
                    Apipa           = ($ip4 -like '169.254.*')
                    IsWifi          = $isWifi
                    AdapterStatus   = $status
                    ProfileName     = $profile
                    NetworkCategory = $category
                    Source          = 'NetTCPIP'
                })
            }
            if ($list.Count -gt 0) {
                # enrich DHCP server info where the cmdlets expose it
                if (Test-GNCommand Get-CimInstance) {
                    try {
                        $cim = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue)
                        # Match by description/alias similarity first, then fall back to the single
                        # DHCP-enabled adapter, because Windows alias names ('Ethernet') rarely
                        # appear in the adapter description ('Realtek PCIe GbE Family Controller').
                        $dhcpCandidates = @($cim | Where-Object { $_.DHCPEnabled -eq $true -and "$($_.DHCPServer)" })
                        foreach ($row in $list) {
                            $match = $cim | Where-Object {
                                $d = "$($_.Description)"
                                $d -and ($d -like "*$($row.Adapter)*" -or "$($row.Adapter)" -like "*$d*")
                            } | Select-Object -First 1
                            if ($match) {
                                if ($match.DHCPEnabled -eq $true) { $row.DhcpEnabled = $true }
                                if ($match.DHCPServer) { $row.DhcpServer = "$($match.DHCPServer)" }
                                continue
                            }
                            if (-not $row.DhcpServer -and $row.DhcpEnabled -eq $true -and $dhcpCandidates.Count -eq 1) {
                                $row.DhcpServer = "$($dhcpCandidates[0].DHCPServer)"
                            }
                        }
                    } catch { }
                }
                return $list
            }
        } catch { }
    }

    if (Test-GNCommand Get-NetIPAddress) {
        try {
            $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
            foreach ($ip in $ips) {
                if ("$($ip.IPAddress)" -eq '127.0.0.1') { continue }
                $gw = ''
                if (Test-GNCommand Get-NetRoute) {
                    try {
                        $r = Get-NetRoute -InterfaceIndex $ip.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($r) { $gw = "$($r.NextHop)" }
                    } catch { }
                }
                $dns = @()
                if (Test-GNCommand Get-DnsClientServerAddress) {
                    try {
                        $d = Get-DnsClientServerAddress -InterfaceIndex $ip.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($d) { $dns = @($d.ServerAddresses) }
                    } catch { }
                }
                $list.Add([pscustomobject]@{
                    Adapter         = "$($ip.InterfaceAlias)"
                    InterfaceIndex  = $ip.InterfaceIndex
                    IPv4            = "$($ip.IPAddress)"
                    PrefixLength    = $ip.PrefixLength
                    SubnetMask      = (Convert-GNPrefixToMask -PrefixLength ([int]$ip.PrefixLength))
                    Gateway         = $gw
                    DnsServers      = @($dns)
                    DnsSuffix       = "$($ip.DnsSuffix)"
                    DhcpEnabled     = $null
                    DhcpServer      = ''
                    Apipa           = ("$($ip.IPAddress)" -like '169.254.*')
                    IsWifi          = $false
                    AdapterStatus   = "$($ip.InterfaceOperationalStatus)"
                    ProfileName     = ''
                    NetworkCategory = ''
                    Source          = 'NetIPAddress'
                })
            }
            if ($list.Count -gt 0) { return $list }
        } catch { }
    }

    # Fallback: parse ipconfig /all (old Windows / stripped systems)
    try {
        $raw = (Invoke-GNNative -File 'ipconfig' -Arguments @('/all') -TimeoutSec 15).Output
        $list = @(Convert-GNIPConfigText -Text $raw)
    } catch { }
    return $list
}

function Convert-GNPrefixToMask {
    param([int]$PrefixLength)
    if ($PrefixLength -lt 0 -or $PrefixLength -gt 32) { return '' }
    try {
        $bytes = New-Object byte[] 4
        for ($i = 0; $i -lt 4; $i++) {
            $bits = [Math]::Min(8, [Math]::Max(0, $PrefixLength - ($i * 8)))
            $bytes[$i] = [byte](256 - [Math]::Pow(2, 8 - $bits))
        }
        return ([System.Net.IPAddress]::new($bytes)).ToString()
    } catch { return '' }
}

function Convert-GNIPConfigText {
    <#  Minimal parser for `ipconfig /all` used only when the NetTCPIP module is absent. #>
    param([string]$Text)
    $results = @()
    if (-not $Text) { return $results }
    $blocks = $Text -split "`r?`n(?=\S.*adapter )"
    foreach ($b in $blocks) {
        if ($b -notmatch 'adapter (.+?):') { continue }
        $name = $Matches[1].Trim()
        $ip4 = ''; $mask = ''; $gw = ''; $dhcp = ''; $dnsList = @(); $dhcpEnabled = $null; $suffix = ''
        $lines = $b -split "`r?`n"
        $collectDns = $false
        foreach ($l in $lines) {
            $t = $l.Trim()
            if ($t -match '^IPv4 Address[^:]*:\s*([0-9\.]+)') { $ip4 = $Matches[1] }
            elseif ($t -match '^Subnet Mask[^:]*:\s*([0-9\.]+)') { $mask = $Matches[1] }
            elseif ($t -match '^Default Gateway[^:]*:\s*([0-9\.]+)') { $gw = $Matches[1] }
            elseif ($t -match '^DHCP Enabled[^:]*:\s*(\S+)') { $dhcpEnabled = ($Matches[1] -match 'Yes') }
            elseif ($t -match '^DHCP Server[^:]*:\s*([0-9\.]+)') { $dhcp = $Matches[1] }
            elseif ($t -match '^DNS Suffix Search List|^Connection-specific DNS Suffix') { if ($t -match ':\s*(\S+)') { $suffix = $Matches[1] } }
            elseif ($t -match '^DNS Servers[^:]*:\s*([0-9a-fA-F:\.]+)') { $collectDns = $true; $dnsList += $Matches[1] }
            elseif ($collectDns -and $t -match '^([0-9a-fA-F:\.]+)\s*$') { $dnsList += $Matches[1] }
            elseif ($t.Length -gt 0 -and $t -match '^[A-Za-z].*:\s*$') { $collectDns = $false }
        }
        $prefix = $null
        if ($mask) { try { $prefix = Convert-GNMaskToPrefix -Mask $mask } catch { } }
        $results += [pscustomobject]@{
            Adapter         = $name
            InterfaceIndex  = $null
            IPv4            = $ip4
            PrefixLength    = $prefix
            SubnetMask      = $mask
            Gateway         = $gw
            DnsServers      = @($dnsList | Select-Object -Unique)
            DnsSuffix       = $suffix
            DhcpEnabled     = $dhcpEnabled
            DhcpServer      = $dhcp
            Apipa           = ($ip4 -like '169.254.*')
            IsWifi          = ($name -match 'wi-?fi|wireless|wlan')
            AdapterStatus   = ''
            ProfileName     = ''
            NetworkCategory = ''
            Source          = 'ipconfig'
        }
    }
    return $results
}

function Convert-GNMaskToPrefix {
    param([string]$Mask)
    $parts = $Mask -split '\.'
    if ($parts.Count -ne 4) { return $null }
    $bits = 0
    foreach ($p in $parts) {
        $v = [int]$p
        for ($i = 7; $i -ge 0; $i--) { if (($v -shr $i) -band 1) { $bits++ } }
    }
    return $bits
}

function Get-GNActiveAdapter {
    <#  The adapter Windows is actually using right now (the one with a default route). #>
    $adapters = @(Get-GNAdapters)
    $configs  = @(Get-GNIPConfig)

    # preference 1: a config entry with a default gateway on an Up adapter
    foreach ($c in $configs) {
        if ($c.Gateway -and -not $c.Apipa) {
            $ad = $adapters | Where-Object { $_.Name -eq $c.Adapter } | Select-Object -First 1
            if ($ad -and $ad.Status -eq 'Up') { return [pscustomobject]@{ Adapter = $ad; Config = $c } }
        }
    }
    # preference 2: any Up physical adapter with an IPv4 address
    foreach ($c in $configs) {
        $ad = $adapters | Where-Object { $_.Name -eq $c.Adapter } | Select-Object -First 1
        if ($ad -and $ad.Status -eq 'Up' -and $c.IPv4 -and -not $c.Apipa) { return [pscustomobject]@{ Adapter = $ad; Config = $c } }
    }
    # preference 3: any Up physical adapter at all
    $up = $adapters | Where-Object { $_.Status -eq 'Up' -and -not $_.IsVirtual } | Select-Object -First 1
    if ($up) {
        $c = $configs | Where-Object { $_.Adapter -eq $up.Name } | Select-Object -First 1
        return [pscustomobject]@{ Adapter = $up; Config = $c }
    }
    return $null
}

function Get-GNDefaultGateway {
    <#  Backwards compatible with the original GeeNet helper, now gateway-object aware. #>
    $cfg = Get-GNIPConfig | Where-Object { $_.Gateway -and -not $_.Apipa } | Select-Object -First 1
    if ($cfg) { return $cfg.Gateway }
    $gw = $null
    if (Test-GNCommand Get-NetRoute) {
        try {
            $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                 Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
                 Sort-Object RouteMetric | Select-Object -First 1
            if ($r) { $gw = "$($r.NextHop)" }
        } catch { }
    }
    return $gw
}

function Get-GNWifiInfo {
    <#  Parses `netsh wlan show interfaces` into usable fields (offline, built-in). #>
    $info = [ordered]@{
        Present       = $false
        Name          = ''
        Description   = ''
        State         = ''
        SSID          = ''
        BSSID         = ''
        RadioType     = ''
        Authentication= ''
        Cipher        = ''
        Channel       = ''
        ReceiveRate   = ''
        TransmitRate  = ''
        SignalPercent = $null
        Profile       = ''
        Error         = ''
    }
    try {
        $out = (Invoke-GNNative -File 'netsh' -Arguments @('wlan','show','interfaces') -TimeoutSec 12)
        $text = "$($out.Output)"
        if ($text -match 'There is no wireless interface' -or $text -match 'not running') { $info.Error = 'No wireless interface detected by Windows.'; return [pscustomobject]$info }
        if ($text -match 'The Wireless AutoConfig Service.*is not running') { $info.Error = 'The WLAN AutoConfig service (WlanSvc) is not running.'; return [pscustomobject]$info }
        $nameLine = [regex]::Match($text, '(?m)^\s*Name\s*:\s*(.+)$')
        if ($nameLine.Success) {
            $info.Present = $true
            $info.Name = $nameLine.Groups[1].Value.Trim()
        }
        foreach ($pair in @(
            @('Description','Description'), @('State','State'), @('SSID','SSID'), @('BSSID','BSSID'),
            @('Radio type','RadioType'), @('Authentication','Authentication'), @('Cipher','Cipher'),
            @('Channel','Channel'), @('Receive rate (Mbps)','ReceiveRate'), @('Transmit rate (Mbps)','TransmitRate'),
            @('Profile','Profile'))) {
            $m = [regex]::Match($text, '(?m)^\s*' + [regex]::Escape($pair[0]) + '\s*:\s*(.+)$')
            if ($m.Success) { $info[$pair[1]] = $m.Groups[1].Value.Trim() }
        }
        $sig = [regex]::Match($text, '(?m)^\s*Signal\s*:\s*(\d+)%')
        if ($sig.Success) { $info.SignalPercent = [int]$sig.Groups[1].Value }
        # SSID lines can repeat as "SSID : x" and "BSSID : y" - the regex above picks the first SSID only.
    } catch {
        $info.Error = "Could not read Wi-Fi information: $($_.Exception.Message)"
    }
    return [pscustomobject]$info
}

function Get-GNWifiProfiles {
    try {
        $out = (Invoke-GNNative -File 'netsh' -Arguments @('wlan','show','profiles') -TimeoutSec 12).Output
        $names = @()
        foreach ($m in [regex]::Matches("$out", '(?m)^\s*All User Profile\s*:\s*(.+)$')) { $names += $m.Groups[1].Value.Trim() }
        return @($names | Select-Object -Unique)
    } catch { return @() }
}

function Test-GNAirplaneMode {
    <#  Reads the Windows radio state flag. 1 = radios off (airplane mode / Wi-Fi switch off). #>
    $state = $null
    try {
        $v = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\RadioManagement\SystemRadioState' -Name '(default)' -ErrorAction SilentlyContinue
        if ($v -ne $null -and $v.'(default)' -ne $null) { $state = [int]$v.'(default)' }
    } catch { }
    return [pscustomobject]@{ Detected = ($state -ne $null); Value = $state; AirplaneOn = ($state -eq 1) }
}

function Get-GNInterfaceStats {
    param([string]$Name)
    $stats = $null
    if (Test-GNCommand Get-NetAdapterStatistics) {
        try {
            if ($Name) { $stats = Get-NetAdapterStatistics -Name $Name -ErrorAction SilentlyContinue }
            else { $stats = Get-NetAdapterStatistics -ErrorAction SilentlyContinue | Select-Object -First 1 }
        } catch { }
    }
    return $stats
}

function Get-GNProxyConfig {
    <#  Reads WinINET (browser) and WinHTTP (system/service) proxy configuration. #>
    $cfg = [ordered]@{
        Enabled      = $false
        Server       = ''
        PacUrl       = ''
        Bypass       = ''
        WinHttpProxy = ''
        Sources      = @()
    }
    try {
        $k = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($k) {
            if ($k.ProxyEnable -eq 1) { $cfg.Enabled = $true; $cfg.Server = "$($k.ProxyServer)"; $cfg.Sources += 'WinINET' }
            if ($k.AutoConfigURL) { $cfg.Enabled = $true; $cfg.PacUrl = "$($k.AutoConfigURL)"; $cfg.Sources += 'PAC' }
            if ($k.ProxyOverride) { $cfg.Bypass = "$($k.ProxyOverride)" }
        }
    } catch { }
    try {
        $l = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections' -ErrorAction SilentlyContinue
        if ($l -and ($l.DefaultConnectionSettings -is [byte[]]) -and $l.DefaultConnectionSettings.Length -gt 46) {
            $b = $l.DefaultConnectionSettings
            if ($b[8] -eq 1 -and $cfg.Server -eq '') { $cfg.Enabled = $true; $cfg.Sources += 'WinINET(LAN)' }
        }
    } catch { }
    try {
        $out = (Invoke-GNNative -File 'netsh' -Arguments @('winhttp','show','proxy') -TimeoutSec 12).Output
        $m = [regex]::Match("$out", '(?m)Proxy Server\(s\)\s*:\s*(.+)$')
        if ($m.Success) {
            $val = $m.Groups[1].Value.Trim()
            $cfg.WinHttpProxy = $val
            if ($val -and $val -notmatch 'Direct access|no proxy') { $cfg.Enabled = $true; if ($cfg.Sources -notcontains 'WinHTTP') { $cfg.Sources += 'WinHTTP' } }
        }
    } catch { }
    return [pscustomobject]$cfg
}

function Get-GNFirewallState {
    $state = [ordered]@{ Available = $false; EnabledProfiles = @(); DisabledProfiles = @(); ThirdParty = @() }
    if (Test-GNCommand Get-NetFirewallProfile) {
        try {
            $profiles = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
            $state.Available = ($profiles.Count -gt 0)
            foreach ($p in $profiles) {
                if ($p.Enabled -eq $true -or "$($p.Enabled)" -eq 'True' -or "$($p.Enabled)" -eq '1') { $state.EnabledProfiles += "$($p.Name)" }
                else { $state.DisabledProfiles += "$($p.Name)" }
            }
        } catch { }
    }
    if (-not $state.Available) {
        try {
            $out = (Invoke-GNNative -File 'netsh' -Arguments @('advfirewall','show','allprofiles','state') -TimeoutSec 15).Output
            foreach ($m in [regex]::Matches("$out", '(?m)^\s*(Domain|Private|Public) Profile Settings\s*:\s*[\r\n]?\s*State\s+(ON|OFF)')) {
                if ($m.Groups[2].Value -eq 'ON') { $state.EnabledProfiles += $m.Groups[1].Value; $state.Available = $true }
                else { $state.DisabledProfiles += $m.Groups[1].Value; $state.Available = $true }
            }
        } catch { }
    }
    # Third-party security products that filter traffic
    if (Test-GNCommand Get-CimInstance) {
        try {
            $av = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)
            foreach ($a in $av) { if ($a.displayName) { $state.ThirdParty += "$($a.displayName)" } }
        } catch { }
    }
    return [pscustomobject]$state
}

function Get-GNVpnInfo {
    $info = [ordered]@{ Adapters = @(); Connections = @(); ActiveRoutes = @(); Clients = @() }
    try {
        $adapters = @(Get-GNAdapters)
        $info.Adapters = @($adapters | Where-Object {
            $_.IsVirtual -and ("$($_.Name) $($_.Description)" -match 'vpn|tap|tun|wireguard|openvpn|pulse|anyconnect|globalprotect|forticlient|zerotier|tailscale|softether|l2tp|pptp|sstp|ikev2|ipsec')
        } | ForEach-Object { "$($_.Name) [$($_.Status)]" })
    } catch { }
    if (Test-GNCommand Get-VpnConnection) {
        try {
            $all = @()
            $all += @(Get-VpnConnection -ErrorAction SilentlyContinue)
            $all += @(Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue)
            $info.Connections = @($all | Where-Object { $_ } | Select-Object -Property Name, ServerAddress, ConnectionStatus, TunnelType -Unique |
                ForEach-Object { "$($_.Name) -> $($_.ServerAddress) [$($_.ConnectionStatus)]" })
        } catch { }
    }
    if (-not $info.Connections -or $info.Connections.Count -eq 0) {
        try {
            if (Test-GNCommand Get-CimInstance) {
                $p = @(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue |
                       Where-Object { "$($_.Name)" -match 'VPN|TAP|TUN|WireGuard|AnyConnect|GlobalProtect|OpenVPN' })
                $info.Clients = @($p | ForEach-Object { "$($_.Name)" } | Select-Object -Unique)
            }
        } catch { }
    }
    if (Test-GNCommand Get-NetRoute) {
        try {
            $rts = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                     Where-Object { $_.RouteMetric -le 1 -and $_.DestinationPrefix -ne '0.0.0.0/0' -and $_.DestinationPrefix -notmatch '^(224|255|127)\.' })
            $info.ActiveRoutes = @($rts | Select-Object -First 6 | ForEach-Object { "$($_.DestinationPrefix) via $($_.NextHop) ($($_.InterfaceAlias))" })
        } catch { }
    }
    return [pscustomobject]$info
}

function Get-GNHostsFileEntries {
    $sysRoot = if ($env:SystemRoot) { "$env:SystemRoot" } else { 'C:\Windows' }
    $file = $sysRoot.TrimEnd('\') + '\System32\drivers\etc\hosts'
    $entries = @()
    try {
        if (Test-Path $file) {
            foreach ($line in (Get-Content $file -ErrorAction SilentlyContinue)) {
                $t = $line.Trim()
                if (-not $t -or $t.StartsWith('#')) { continue }
                $entries += $t
            }
        }
    } catch { }
    return @($entries)
}

function Get-GNNeighbors {
    $list = @()
    if (Test-GNCommand Get-NetNeighbor) {
        try { $list = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue) } catch { }
    }
    if ($list.Count -eq 0) {
        try {
            $out = (Invoke-GNNative -File 'arp' -Arguments @('-a') -TimeoutSec 12).Output
            $rows = @()
            foreach ($m in [regex]::Matches("$out", '(?m)^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F\-]{11,17})\s+(\S+)')) {
                $rows += [pscustomobject]@{
                    IPAddress = $m.Groups[1].Value
                    LinkLayerAddress = $m.Groups[2].Value
                    State = $m.Groups[3].Value
                    InterfaceAlias = ''
                }
            }
            $list = $rows
        } catch { }
    }
    return @($list)
}

function Get-GNRoutes {
    $list = @()
    if (Test-GNCommand Get-NetRoute) {
        try { $list = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue) } catch { }
    }
    if ($list.Count -eq 0) {
        try {
            $out = (Invoke-GNNative -File 'route' -Arguments @('print','-4') -TimeoutSec 15).Output
            $rows = @()
            foreach ($m in [regex]::Matches("$out", '(?m)^\s*(\d+\.\d+\.\d+\.\d+)\s+(\d+\.\d+\.\d+\.\d+)\s+(\d+\.\d+\.\d+\.\d+)\s+(\d+)\s*$')) {
                $rows += [pscustomobject]@{
                    DestinationPrefix = "$($m.Groups[1].Value)/$((Convert-GNMaskToPrefix -Mask $m.Groups[2].Value))"
                    NextHop = $m.Groups[3].Value
                    RouteMetric = [int]$m.Groups[4].Value
                    InterfaceAlias = ''
                }
            }
            $list = $rows
        } catch { }
    }
    return @($list)
}

function Get-GNTcpConnections {
    if (Test-GNCommand Get-NetTCPConnection) {
        try { return @(Get-NetTCPConnection -ErrorAction SilentlyContinue) } catch { }
    }
    try {
        $out = (Invoke-GNNative -File 'netstat' -Arguments @('-ano') -TimeoutSec 15).Output
        $rows = @()
        foreach ($m in [regex]::Matches("$out", '(?m)^\s*TCP\s+(\S+):(\d+)\s+(\S+):(\d+)\s+(\S+)\s+(\d+)')) {
            $rows += [pscustomobject]@{
                LocalAddress = $m.Groups[1].Value; LocalPort = [int]$m.Groups[2].Value
                RemoteAddress = $m.Groups[3].Value; RemotePort = [int]$m.Groups[4].Value
                State = $m.Groups[5].Value; OwningProcess = [int]$m.Groups[6].Value
            }
        }
        return $rows
    } catch { return @() }
}

function Get-GNCriticalServices {
    $names = @('Dnscache','Dhcp','WlanSvc','NlaSvc','netprofm','NcaSvc','nsi','DPS','WinHttpAutoProxySvc','LanmanWorkstation')
    $list = @()
    foreach ($n in $names) {
        try {
            $s = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($s) { $list += [pscustomobject]@{ Name = $s.Name; Display = $s.DisplayName; Status = "$($s.Status)"; StartType = "$($s.StartType)" } }
        } catch { }
    }
    return @($list)
}

# ------------------------------------------------------------------------------
#region 7. LOW-LEVEL PRIMITIVES (ping / TCP / DNS / HTTP / native commands)
#      Isolated on purpose: the self test overrides these to simulate failures
#      safely without touching the real network.
# ------------------------------------------------------------------------------

function Invoke-GNNative {
    <#  Runs a built-in Windows tool with a hard timeout and returns text + exit code. #>
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 20
    )
    $res = [pscustomobject]@{ ExitCode = $null; Output = ''; TimedOut = $false; Error = '' }
    $tmpOut = $null
    try {
        if (-not (Test-GNCommand $File) -and -not (Test-Path $File)) {
            $res.Error = "$File not found"
            return $res
        }
        $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ("gn_" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".txt")
        $argsList = @()
        if ($Arguments) { $argsList = $Arguments }
        $p = Start-Process -FilePath $File -ArgumentList $argsList -NoNewWindow -PassThru `
                -RedirectStandardOutput $tmpOut -RedirectStandardError ($tmpOut + ".err") -ErrorAction Stop
        $done = $p.WaitForExit($TimeoutSec * 1000)
        if (-not $done) {
            $res.TimedOut = $true
            try { $p.Kill() } catch { }
        }
        $res.ExitCode = $p.ExitCode
        if (Test-Path $tmpOut) { $res.Output = (Get-Content -Path $tmpOut -Raw -ErrorAction SilentlyContinue) }
        $errFile = $tmpOut + ".err"
        if (Test-Path $errFile) {
            $errText = (Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue)
            if ($errText) { $res.Output = "$($res.Output)`n$errText" }
        }
    } catch {
        $res.Error = $_.Exception.Message
    } finally {
        try { if ($tmpOut -and (Test-Path $tmpOut)) { Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue } } catch { }
        try { if ($tmpOut -and (Test-Path ($tmpOut + ".err"))) { Remove-Item ($tmpOut + ".err") -Force -ErrorAction SilentlyContinue } } catch { }
    }
    return $res
}

function Invoke-GNPing {
    <#
      ICMP echo test using .NET (identical behaviour on Windows PowerShell 5.1 and 7+).
      Returns sent/received/loss and per-packet round trip times.
    #>
    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$Count = 2,
        [int]$TimeoutMs = 1200,
        [int]$BufferSize = 32,
        [switch]$DontFragment
    )
    $r = [ordered]@{
        Target = $Target; Sent = 0; Received = 0; Lost = 0; LossPercent = 100
        Success = $false; Times = @(); AvgMs = $null; MinMs = $null; MaxMs = $null; JitterMs = $null
        Statuses = @(); Error = ''; ResolvedTo = ''
    }
    $r.Sent = $Count
    try { $r.ResolvedTo = ([System.Net.Dns]::GetHostAddresses($Target) | Select-Object -First 1).ToString() } catch { }
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $opts = $null
        if ($DontFragment) {
            $opts = New-Object System.Net.NetworkInformation.PingOptions(64, $true)
        }
        $buf = New-Object byte[] $BufferSize
        for ($i = 1; $i -le $Count; $i++) {
            $reply = $null
            try {
                if ($opts) { $reply = $ping.Send($Target, $TimeoutMs, $buf, $opts) }
                else { $reply = $ping.Send($Target, $TimeoutMs, $buf) }
            } catch {
                $r.Statuses += 'Exception'
                $r.Error = $_.Exception.Message
                continue
            }
            if ($reply) {
                $r.Statuses += "$($reply.Status)"
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $r.Received++
                    $r.Times += [int]$reply.RoundtripTime
                }
            }
        }
        $ping.Dispose()
    } catch {
        $r.Error = $_.Exception.Message
    }
    $r.Lost = $r.Sent - $r.Received
    if ($r.Sent -gt 0) {
        if ($r.Received -gt 0) { $r.LossPercent = [Math]::Round(($r.Lost / $r.Sent) * 100, 0) } else { $r.LossPercent = 100 }
    }
    if ($r.Times.Count -gt 0) {
        $r.AvgMs   = [Math]::Round((($r.Times | Measure-Object -Average).Average), 1)
        $r.MinMs   = ($r.Times | Measure-Object -Minimum).Minimum
        $r.MaxMs   = ($r.Times | Measure-Object -Maximum).Maximum
        $r.JitterMs= [Math]::Round(($r.MaxMs - $r.MinMs), 1)
    }
    $r.Success = ($r.Received -gt 0)
    return [pscustomobject]$r
}

function Test-GNTcpPort {
    <#  Raw TCP connect test. Works without DNS when given a literal IP. #>
    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$Port = 443,
        [int]$TimeoutMs = 3000,
        [switch]$NoDns
    )
    $res = [pscustomobject]@{ Target = $Target; Port = $Port; Open = $false; ElapsedMs = $null; Error = ''; ResolvedIp = '' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = $null
    try {
        if ($NoDns -and $Target -notmatch '^\d+\.\d+\.\d+\.\d+$') {
            $res.Error = 'Not an IP address (DNS skipped)'
            return $res
        }
        $client = New-Object System.Net.Sockets.TcpClient
        $client.NoDelay = $true
        $async = $client.BeginConnect($Target, $Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $ok) { $res.Error = "Connection timed out after $TimeoutMs ms"; return $res }
        $client.EndConnect($async)
        $res.Open = $true
        try { $res.ResolvedIp = "$($client.Client.RemoteEndPoint)".Split(':')[0] } catch { }
    } catch {
        $res.Error = $_.Exception.InnerException.Message
        if (-not $res.Error) { $res.Error = $_.Exception.Message }
    } finally {
        $sw.Stop()
        $res.ElapsedMs = [int]$sw.ElapsedMilliseconds
        if ($client) { try { $client.Close() } catch { } }
    }
    return $res
}

function Invoke-GNDnsQuery {
    <#  DNS resolution test with timing, optional explicit server (to compare resolvers). #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Server = '',
        [int]$TimeoutSec = 6
    )
    $res = [pscustomobject]@{
        Name = $Name; Server = $Server; Success = $false; Addresses = @()
        ElapsedMs = $null; Error = ''; RespondedWith = ''
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Server -and (Test-GNCommand Resolve-DnsName)) {
        try {
            $out = @(Resolve-DnsName -Name $Name -Type A -Server $Server -DnsOnly -ErrorAction Stop)
            $addrs = @($out | Where-Object { $_.IPAddress } | ForEach-Object { "$($_.IPAddress)" })
            $res.Addresses = @($addrs | Select-Object -Unique)
            $res.Success = ($res.Addresses.Count -gt 0)
            if (-not $res.Success) { $res.RespondedWith = 'Server answered but returned no A records (possible NXDOMAIN)' }
        } catch {
            $res.Error = $_.Exception.Message
        }
    } else {
        try {
            $addrs = @([System.Net.Dns]::GetHostAddresses($Name) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() })
            $res.Addresses = @($addrs | Select-Object -Unique)
            $res.Success = ($res.Addresses.Count -gt 0)
            if ($Server) { $res.Server = "$Server (unused - Resolve-DnsName unavailable)" }
        } catch {
            $res.Error = $_.Exception.Message
        }
    }
    $sw.Stop()
    $res.ElapsedMs = [int]$sw.ElapsedMilliseconds
    return $res
}

function Request-GNHttp {
    <#
      HTTP/HTTPS request via .NET. Uses the system proxy by default (browser-like),
      unless -Direct is specified. Returns status code + a short body sample.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 8,
        [switch]$Direct,
        [int]$MaxBytes = 2048
    )
    $res = [pscustomobject]@{
        Url = $Url; Success = $false; StatusCode = $null; StatusText = ''
        Content = ''; ElapsedMs = $null; Error = ''; UsedProxy = ''; Redirected = $false
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) GeeNet/2.0'
        $req.AllowAutoRedirect = $true
        if ($Direct) {
            $req.Proxy = $null
            $res.UsedProxy = 'none (direct connection)'
        } else {
            try {
                $p = [System.Net.WebRequest]::GetSystemWebProxy()
                $uri = New-Object System.Uri($Url)
                if ($p -and $p.GetProxy($uri).AbsoluteUri -ne $uri.AbsoluteUri) {
                    $req.Proxy = $p
                    $res.UsedProxy = "$($p.GetProxy($uri))"
                } else {
                    $res.UsedProxy = 'none'
                }
            } catch { $res.UsedProxy = 'none' }
        }
        $resp = $req.GetResponse()
        $res.StatusCode = [int]([System.Net.HttpWebResponse]$resp).StatusCode
        $res.StatusText = "$(([System.Net.HttpWebResponse]$resp).StatusDescription)"
        try {
            $stream = $resp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $buf = New-Object char[] $MaxBytes
            $read = $reader.Read($buf, 0, $MaxBytes)
            if ($read -gt 0) { $res.Content = (-join $buf[0..($read-1)]) }
            $reader.Close()
        } catch { }
        $res.Success = ($res.StatusCode -ge 200 -and $res.StatusCode -lt 400)
        $resp.Close()
    } catch [System.Net.WebException] {
        $we = $_.Exception
        if ($we.Response) {
            try {
                $res.StatusCode = [int]([System.Net.HttpWebResponse]$we.Response).StatusCode
                $res.StatusText = "$(([System.Net.HttpWebResponse]$we.Response).StatusDescription)"
            } catch { }
        }
        $res.Error = "$($we.Status): $($we.Message)"
    } catch {
        $res.Error = $_.Exception.Message
    }
    $sw.Stop()
    $res.ElapsedMs = [int]$sw.ElapsedMilliseconds
    return $res
}

# ------------------------------------------------------------------------------
#region 8. DIAGNOSTIC RESULT OBJECT + RENDERING
# ------------------------------------------------------------------------------

function New-GNResult {
    <#
      Every diagnostic returns this object. The UI never prints "FAILED" without
      walking the user through: what we tested, why, what it means, what to do next,
      and whether GeeNet can fix it.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Link','Local','IP','Transport','App','Stack','Context')]
        [string]$Layer = 'App',
        [ValidateSet('Pass','Fail','Warn','Skip','Info')]
        [string]$Status = 'Info',
        [string]$Summary = '',
        [string]$Why = '',
        [string]$Meaning = '',
        [string[]]$Causes = @(),
        [string[]]$NextSteps = @(),
        [ValidateSet('NotNeeded','SafeAuto','NeedsAdmin','Manual','Hardware','Boundary')]
        [string]$FixClass = 'NotNeeded',
        [string]$Technical = '',
        [hashtable]$Data = @{},
        [int]$DurationMs = 0,
        [string]$SkipReason = ''
    )
    return [pscustomobject]@{
        Id         = $Id
        Name       = $Name
        Layer      = $Layer
        Status     = $Status
        Summary    = $Summary
        Why        = $Why
        Meaning    = $Meaning
        Causes     = @($Causes)
        NextSteps  = @($NextSteps)
        FixClass   = $FixClass
        Technical  = $Technical
        Data       = $Data
        DurationMs = $DurationMs
        SkipReason = $SkipReason
        Time       = (Get-Date).ToString('HH:mm:ss')
    }
}

function Get-GNFixClassText {
    param([string]$FixClass, [string]$Id = '')
    switch ($FixClass) {
        'NotNeeded'  { return "Nothing to fix - this check passed." }
        'SafeAuto'   { return "GeeNet can usually fix this automatically (safe, reversible)." }
        'NeedsAdmin' { return "This needs a repair that requires Administrator rights." }
        'Manual'     { return "This needs a manual action from you (instructions below)." }
        'Hardware'   { return "This is outside the computer - it needs a physical check or a different device." }
        'Boundary'   { return "This is past the point GeeNet can repair; it points at the router, the ISP or the network itself." }
        default      { return "" }
    }
}

function Write-GNResultUnit {
    <#
      Renders a result. Compact on PASS, full explanation on FAIL/WARN.
      -Full forces the teaching block even on PASS.
    #>
    param(
        [Parameter(Mandatory)]$Result,
        [switch]$Full,
        [switch]$NoRule
    )
    $col  = 'Green'
    $mark = $script:GNG.Pass
    switch ($Result.Status) {
        'Fail' { $col = 'Red';        $mark = $script:GNG.Cross }
        'Warn' { $col = 'DarkYellow'; $mark = $script:GNG.Triangle }
        'Skip' { $col = 'DarkGray';   $mark = $script:GNG.Skip }
        'Info' { $col = 'Cyan';       $mark = $script:GNG.Info }
    }

    if ($Result.Layer -ne '' -and $Result.Layer -ne 'Context') {
        Write-GNOut ("  [" + $Result.Layer.ToUpper() + "] " + $Result.Name) -Color $script:GNCol.Bright
    } else {
        Write-GNOut ("  " + $Result.Name) -Color $script:GNCol.Bright
    }
    Write-GNOut ("      " + $mark + "  " + $Result.Status.ToUpper()) -Color $col
    if ($Result.Summary) { Write-GNPara -Text $Result.Summary -Color $script:GNCol.Text -Indent 6 }
    if ($Result.Technical -and ($Result.Status -eq 'Fail' -or $Result.Status -eq 'Warn' -or $Full)) {
        Write-GNTech $Result.Technical
    }

    $teach = ($Result.Status -eq 'Fail' -or $Result.Status -eq 'Warn' -or $Full)
    if (-not $teach) {
        if (-not $NoRule) { Write-GNOut '' }
        return
    }

    if ($Result.Status -eq 'Skip') {
        if ($Result.SkipReason) {
            Write-GNOut ''
            Write-GNOut "      Why this was skipped:" -Color $script:GNCol.Warn
            Write-GNPara -Text $Result.SkipReason -Color $script:GNCol.Text -Indent 8
        }
        if (-not $NoRule) { Write-GNOut '' }
        return
    }

    if ($Result.Why) {
        Write-GNOut ''
        Write-GNOut "      Why we checked this:" -Color $script:GNCol.Info
        Write-GNPara -Text $Result.Why -Color $script:GNCol.Text -Indent 8
    }
    if ($Result.Meaning) {
        Write-GNOut ''
        Write-GNOut "      What this means:" -Color $script:GNCol.Info
        Write-GNPara -Text $Result.Meaning -Color $script:GNCol.Text -Indent 8
    }
    if ($Result.Causes.Count -gt 0) {
        Write-GNOut ''
        Write-GNOut "      Likely causes:" -Color $script:GNCol.Info
        Write-GNList -Items $Result.Causes -Color $script:GNCol.Text -Indent 8
    }
    if ($Result.NextSteps.Count -gt 0) {
        Write-GNOut ''
        Write-GNOut "      Recommended next step:" -Color $script:GNCol.Info
        $i = 1
        foreach ($s in $Result.NextSteps) {
            Write-GNPara -Text ("$i. " + $s) -Color $script:GNCol.Action -Indent 8
            $i++
        }
    }
    $fixText = Get-GNFixClassText -FixClass $Result.FixClass -Id $Result.Id
    if ($fixText) {
        Write-GNOut ''
        $fixCol = switch ($Result.FixClass) {
            'SafeAuto'   { 'Green' }
            'NeedsAdmin' { 'DarkYellow' }
            'Manual'     { 'Cyan' }
            'Hardware'   { 'DarkYellow' }
            'Boundary'   { 'DarkYellow' }
            default      { 'DarkGray' }
        }
        Write-GNOut "      Can GeeNet fix this?" -Color $script:GNCol.Info
        Write-GNPara -Text $fixText -Color $fixCol -Indent 8
    }
    if (-not $NoRule) { Write-GNOut '' }
}

function Add-GNResult {
    param($Result, [switch]$Quiet)
    if ($script:GNSession) { [void]$script:GNSession.Results.Add($Result) }
    $level = switch ($Result.Status) { 'Pass' { 'PASS' } 'Fail' { 'FAIL' } 'Warn' { 'WARN' } 'Skip' { 'SKIP' } default { 'INFO' } }
    [void](Write-GeeNetLog -Message ("{0,-22} {1}: {2}" -f $Result.Id, $level, $Result.Summary) -Level $level)
    if (-not $Quiet) { Write-GNResultUnit -Result $Result }
    return $Result
}

# ------------------------------------------------------------------------------
#region 9. LAYER 1-2 TESTS: ADAPTER / LINK / ETHERNET / WI-FI / DRIVER
# ------------------------------------------------------------------------------

function Test-NetworkAdapter {
    <#  Is there a usable network adapter at all? Everything else depends on this. #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $adapters = @(Get-GNAdapters)
    $physical = @($adapters | Where-Object { -not $_.IsVirtual })
    $up       = @($physical | Where-Object { $_.Status -eq 'Up' })
    $disabled = @($physical | Where-Object { $_.Status -eq 'Disabled' })
    $conn     = @($up | Select-Object -First 1)
    $sw.Stop()

    $data = @{
        AdapterCount   = $adapters.Count
        PhysicalCount  = $physical.Count
        UpCount        = $up.Count
        DisabledCount  = $disabled.Count
        AdapterNames   = ($up | ForEach-Object { $_.Name }) -join ', '
        HasAdapter     = ($physical.Count -gt 0)
        HasUpAdapter   = ($up.Count -gt 0)
        IsWifi         = [bool]($up | Where-Object { $_.IsWifi })
        IsEthernet     = [bool]($up | Where-Object { $_.IsEthernet })
        DisabledNames  = ($disabled | ForEach-Object { $_.Name }) -join ', '
    }

    if ($physical.Count -eq 0) {
        return New-GNResult -Id 'AdapterState' -Name 'Network adapter check' -Layer 'Link' -Status 'Fail' `
            -Summary "Windows cannot see any physical network adapter on this computer." `
            -Why "Your network adapter is the hardware that talks to the network. Without an active adapter nothing else about networking can work, so GeeNet checks this first." `
            -Meaning "Either the adapter is disabled in Windows, Windows has a device/driver problem with it, or the hardware is not being detected." `
            -Causes @('Wi-Fi or Ethernet adapter is disabled in Device Manager or Network Connections','Faulty or missing network driver','Windows is in a state where the adapter failed to start','Very rarely: the network hardware itself has failed or is not seated/connected') `
            -NextSteps @('Open Device Manager and look for a network adapter with a warning symbol','Open Network Connections (ncpa.cpl) and check whether any adapter is greyed out or says Disabled','If the adapter is missing entirely, check for driver updates from the PC/laptop maker','Restart the computer once, then run this check again') `
            -FixClass 'NeedsAdmin' `
            -Technical "No physical (non-virtual) adapters reported. Total adapters seen: $($adapters.Count). Adapters: $(($adapters | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join '; ')" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($up.Count -eq 0) {
        $detail = if ($disabled.Count -gt 0) { "Adapter(s) disabled: $($data.DisabledNames)." } else { "Adapter(s) present but not connected: " + (($physical | ForEach-Object { "$($_.Name) [$($_.Status)]" }) -join ', ') + "." }
        return New-GNResult -Id 'AdapterState' -Name 'Network adapter check' -Layer 'Link' -Status 'Fail' `
            -Summary "Windows can see the network adapter, but it is not connected/active right now." `
            -Why "Before anything else, Windows needs an adapter that is switched on and connected to a network." `
            -Meaning "The adapter exists, but there is no active link. With Wi-Fi this means not connected to any network; with Ethernet it usually means the cable is unplugged, the port is dead, or the adapter is disabled." `
            -Causes @('Wi-Fi is switched off or not connected to a network','Ethernet cable is unplugged or faulty','The adapter is disabled in Windows','Airplane mode is on','Adapter driver failed to start') `
            -NextSteps @('Check whether you are on Wi-Fi or Ethernet, and make sure that connection is actually on','For Wi-Fi: make sure Wi-Fi is enabled (not airplane mode) and connect to your network','For Ethernet: push the cable in firmly at both ends, or try another cable/port','If the adapter shows as disabled, GeeNet can try to enable it') `
            -FixClass 'SafeAuto' `
            -Technical $detail `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    $names = $data.AdapterNames
    $kind  = if ($data.IsWifi -and $data.IsEthernet) { 'Wi-Fi and Ethernet' } elseif ($data.IsWifi) { 'Wi-Fi' } else { 'Ethernet' }
    return New-GNResult -Id 'AdapterState' -Name 'Network adapter check' -Layer 'Link' -Status 'Pass' `
        -Summary "Windows found an active network adapter ($names) using $kind." `
        -Why "This is the doorway between your computer and the network - if it is healthy we can look further out." `
        -Meaning "The hardware is present, enabled and connected, so troubleshooting can continue past the physical layer." `
        -Technical "Up adapters: $names. Status: $(($up | ForEach-Object { "$($_.Name)=$($_.Status), $($_.LinkSpeed)" }) -join '; ')" `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-WiFi {
    <#  Wi-Fi specific: is there a radio, is it connected, how strong is the signal? #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $wifi = Get-GNWifiInfo
    $adapters = @(Get-GNAdapters)
    $wifiAdapters = @($adapters | Where-Object { $_.IsWifi })
    $wifiAdapter = $wifiAdapters | Select-Object -First 1
    $airplane = Test-GNAirplaneMode
    $services = @(Get-GNCriticalServices)
    $wlanSvc = $services | Where-Object { $_.Name -eq 'WlanSvc' } | Select-Object -First 1
    $sw.Stop()

    $data = @{
        WifiAdapterPresent = ($wifiAdapters.Count -gt 0)
        WifiAdapterName    = if ($wifiAdapter) { $wifiAdapter.Name } else { '' }
        WifiAdapterStatus  = if ($wifiAdapter) { $wifiAdapter.Status } else { '' }
        Present            = $wifi.Present
        State              = $wifi.State
        SSID               = $wifi.SSID
        SignalPercent      = $wifi.SignalPercent
        RadioType          = $wifi.RadioType
        Channel            = $wifi.Channel
        Auth               = $wifi.Authentication
        Connected          = ($wifi.State -match 'connected' -and $wifi.State -notmatch 'disconnected')
        AirplaneMode       = $airplane.AirplaneOn
        WlanServiceStatus  = if ($wlanSvc) { $wlanSvc.Status } else { 'not found' }
        Error              = $wifi.Error
        RxRate             = $wifi.ReceiveRate
        TxRate             = $wifi.TransmitRate
    }

    if (-not $data.WifiAdapterPresent -and -not $wifi.Present) {
        # No wireless hardware at all. That is only a fault if this computer has no other way
        # of being connected - otherwise it is simply not applicable and must not be blamed.
        $otherLinkUp = @($adapters | Where-Object { -not $_.IsVirtual -and -not $_.IsWifi -and $_.Status -eq 'Up' })
        $data.OtherLinkUp = ($otherLinkUp.Count -gt 0)
        if ($otherLinkUp.Count -gt 0) {
            return New-GNResult -Id 'Wifi' -Name 'Wi-Fi check' -Layer 'Link' -Status 'Info' `
                -Summary "This computer has no Wi-Fi adapter - nothing to check here." `
                -Why "A Wi-Fi check only applies when the machine has a wireless adapter." `
                -Meaning "Your connection is running over $(($otherLinkUp | ForEach-Object { $_.Name }) -join ', '), which is up. Missing wireless hardware is not a fault and is not causing your problem." `
                -NextSteps @('No action needed for Wi-Fi - GeeNet continues with the checks that do apply') `
                -FixClass 'NotNeeded' `
                -Technical "No 802.11 adapter present. Other adapters up: $(($otherLinkUp | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')." `
                -Data $data -DurationMs $sw.ElapsedMilliseconds
        }
        return New-GNResult -Id 'Wifi' -Name 'Wi-Fi check' -Layer 'Link' -Status 'Fail' `
            -Summary "This computer does not appear to have a working Wi-Fi adapter." `
            -Why "If Windows cannot see a Wi-Fi adapter, it cannot show networks or connect to them." `
            -Meaning "Either this PC has no Wi-Fi hardware, the Wi-Fi adapter is disabled or uninstalled in Device Manager, or a driver problem stopped it." `
            -Causes @('Wi-Fi adapter disabled in Device Manager or Network Connections','Missing or broken Wi-Fi driver (common after a Windows update)','Wi-Fi hardware not present (desktop PC with no wireless card)','Wi-Fi card failed or is not detected by the BIOS/firmware') `
            -NextSteps @('Open Device Manager and look under "Network adapters" for a wireless adapter','If it has a warning triangle, right-click it and try Enable device, then Update driver','If there is no wireless adapter listed, check whether the PC actually has Wi-Fi hardware','A USB Wi-Fi adapter is a quick test/repair for desktop PCs') `
            -FixClass 'Manual' `
            -Technical "Get-NetAdapter shows no 802.11 adapter. netsh wlan: $($wifi.Error) WlanSvc: $($data.WlanServiceStatus)" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($airplane.AirplaneOn) {
        return New-GNResult -Id 'Wifi' -Name 'Wi-Fi check' -Layer 'Link' -Status 'Fail' `
            -Summary "Airplane mode is turned ON, so Wi-Fi is switched off by Windows." `
            -Why "Airplane mode is a Windows setting that turns off all wireless radios at once - it overrides the Wi-Fi switch." `
            -Meaning "Wi-Fi cannot connect while airplane mode is on, no matter what you do to your network." `
            -Causes @('Airplane mode switched on from the taskbar quick settings','A keyboard function key (often F2, F8 or F12) toggled the radios off','Windows remembered airplane mode from a previous session') `
            -NextSteps @('Click the network/sound/battery icon in the taskbar (bottom-right) and turn Airplane mode OFF','Press the Wi-Fi function key on the keyboard once and see if Wi-Fi comes back','Then run the Wi-Fi check again') `
            -FixClass 'Manual' `
            -Technical "HKLM\SYSTEM\CurrentControlSet\Control\RadioManagement\SystemRadioState = $($airplane.Value) (1 = radios off)" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($wifiAdapter -and $wifiAdapter.Status -eq 'Disabled') {
        return New-GNResult -Id 'Wifi' -Name 'Wi-Fi check' -Layer 'Link' -Status 'Fail' `
            -Summary "The Wi-Fi adapter ($($wifiAdapter.Name)) is disabled in Windows." `
            -Why "A disabled adapter is switched off at the software level, so Windows will not show or connect to any Wi-Fi network." `
            -Meaning "This is a setting problem, not a hardware fault - it can normally be switched back on in seconds." `
            -Causes @('Adapter disabled in Network Connections (ncpa.cpl) or Device Manager','Disabled by a security/productivity tool','Driver was disabled after a failed update') `
            -NextSteps @('GeeNet can re-enable the adapter for you','If that fails, open Network Connections and right-click the adapter, then choose Enable','If the adapter disables itself again, the driver may need reinstalling') `
            -FixClass 'SafeAuto' `
            -Technical "Adapter '$($wifiAdapter.Name)' status = Disabled" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if (-not $data.Connected) {
        $ethInUse = @($adapters | Where-Object { -not $_.IsVirtual -and -not $_.IsWifi -and $_.Status -eq 'Up' })
        if ($ethInUse.Count -gt 0) {
            return New-GNResult -Id 'Wifi' -Name 'Wi-Fi check' -Layer 'Link' -Status 'Info' `
                -Summary "Wi-Fi is not connected, and it is not needed - you are connected over the cable." `
                -Why "A wireless link only matters when it is the connection you are actually using." `
                -Meaning "The Wi-Fi radio is idle while $(($ethInUse | ForEach-Object { $_.Name }) -join ', ') carries your traffic, so this is not the cause of your problem." `
                -NextSteps @('No action needed - GeeNet checks the connection you are actually using') `
                -FixClass 'NotNeeded' `
                -Technical "netsh wlan state: '$($wifi.State)'. Ethernet adapters up: $(($ethInUse | ForEach-Object { $_.Name }) -join ', ')." `
                -Data $data -DurationMs $sw.ElapsedMilliseconds
        }
        $hint = ''
        if ($wifi.Error) { $hint = $wifi.Error }
        return New-GNResult -Id 'Wifi' -Name 'Wi-Fi check' -Layer 'Link' -Status 'Fail' `
            -Summary "The Wi-Fi adapter is working, but this computer is not connected to any Wi-Fi network." `
            -Why "Being connected to a network is what gives your computer an IP address and a route to the internet." `
            -Meaning "Windows sees the Wi-Fi hardware, but there is no active wireless connection. Networks may be hidden, out of range, or the connection attempt may be failing." `
            -Causes @('Not connected to your network yet (forgotten, or the network changed)','Wrong Wi-Fi password saved','The network is out of range or the router/access point is off','Saved profile was deleted or corrupted','Wi-Fi adapter driver misbehaving, or the WLAN service stopped') `
            -NextSteps @('Click the Wi-Fi icon in the taskbar and connect to your network','Check the password carefully (passwords are case sensitive)','GeeNet can scan which networks are visible so you know if yours can be seen','If your network is not in the list at all, see the Wi-Fi signals-not-showing path') `
            -FixClass 'Manual' `
            -Technical "netsh wlan show interfaces -> State: '$($wifi.State)'. $hint" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    $signal = $wifi.SignalPercent
    $status = 'Pass'
    $summary = "Connected to Wi-Fi network '$($wifi.SSID)'"
    if ($signal -ne $null) { $summary += " with $signal% signal strength." } else { $summary += "." }
    $causes = @()
    $steps = @()
    $meaning = "Your Wi-Fi radio is on, connected to the network, and the link quality looks usable."

    if ($signal -ne $null -and $signal -lt 40) {
        $status = 'Warn'
        $meaning = "You are connected, but the signal is weak. Weak Wi-Fi causes exactly the symptoms people describe as 'slow internet' or 'keeps dropping'."
        $causes = @('Distance from the router or too many walls/floors in between','Interference from other networks or appliances (microwaves, cordless phones)','Router antenna position','Wi-Fi band choice (2.4 GHz travels further but is slower; 5 GHz is faster but shorter range)','Too many devices sharing one access point')
        $steps = @('Move closer to the router or remove obstacles between you and it','If you can, switch to the 5 GHz band when you are close, or 2.4 GHz when you are far','Restart the router if the signal was fine before','If possible, use an Ethernet cable for work that must not drop')
    } elseif ($signal -ne $null -and $signal -lt 60) {
        $status = 'Warn'
        $meaning = "You are connected, but the signal is only fair. This can show up as occasional slowdowns, especially with video calls or gaming."
        $causes = @('Distance or obstacles between the PC and the router','Neighbouring Wi-Fi networks competing on the same channel','Router placement (inside a cabinet, behind a TV, on the floor)')
        $steps = @('Move the router to a more open, higher position','Move your device closer, or reduce obstacles','If several networks are visible, the router channel may need changing (router-side task)')
    }

    $suffix = ''
    if ($wifi.RadioType) { $suffix += " Radio: $($wifi.RadioType)." }
    if ($wifi.Channel)   { $suffix += " Channel: $($wifi.Channel)." }
    if ($wifi.ReceiveRate) { $suffix += " Link rate: $($wifi.ReceiveRate)/$($wifi.TransmitRate) Mbps." }

    return New-GNResult -Id 'Wifi' -Name 'Wi-Fi check' -Layer 'Link' -Status $status `
        -Summary $summary -Why "Wi-Fi is your physical connection to the network, so its quality sets the ceiling for everything else." `
        -Meaning $meaning -Causes $causes -NextSteps $steps `
        -FixClass $(if ($status -eq 'Warn') { 'Manual' } else { 'NotNeeded' }) `
        -Technical "SSID: $($wifi.SSID). State: $($wifi.State). Auth: $($wifi.Authentication).$suffix Profile: $($wifi.Profile)" `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-Ethernet {
    <#  Wired link check: cable in, negotiated speed, adapter state. #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $adapters = @(Get-GNAdapters)
    $eth = @($adapters | Where-Object { $_.IsEthernet -and -not $_.IsVirtual })
    $ethUp = @($eth | Where-Object { $_.Status -eq 'Up' })
    $ethDown = @($eth | Where-Object { $_.Status -ne 'Up' })
    $stats = Get-GNInterfaceStats

    $data = @{
        EthernetCount = $eth.Count
        UpCount = $ethUp.Count
        LinkSpeeds = ($ethUp | ForEach-Object { "$($_.Name)=$($_.LinkSpeed)" }) -join ', '
        DownStatuses = ($ethDown | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', '
        HasEthernet = ($eth.Count -gt 0)
        HasLink = ($ethUp.Count -gt 0)
    }
    if ($stats) {
        try {
            $data.RxErrors = if ($stats.ReceivedPacketErrors) { $stats.ReceivedPacketErrors } else { 0 }
            $data.TxErrors = if ($stats.OutboundPacketErrors) { $stats.OutboundPacketErrors } else { 0 }
            $data.RxDiscards = if ($stats.ReceivedDiscardedPackets) { $stats.ReceivedDiscardedPackets } else { 0 }
        } catch { }
    }
    $sw.Stop()

    if ($eth.Count -eq 0) {
        # Same reasoning as Wi-Fi: no wired port is only a fault when nothing else connects.
        $wifiUp = @($adapters | Where-Object { $_.IsWifi -and $_.Status -eq 'Up' })
        $data.OtherLinkUp = ($wifiUp.Count -gt 0)
        if ($wifiUp.Count -gt 0) {
            return New-GNResult -Id 'Ethernet' -Name 'Ethernet (cable) check' -Layer 'Link' -Status 'Info' `
                -Summary "This computer has no Ethernet adapter - nothing to check here (your Wi-Fi link is up)." `
                -Why "A cable check only applies when the machine has a wired network port." `
                -Meaning "Thin laptops and tablets often have no Ethernet port. Since Wi-Fi is connected, the missing port is not a fault." `
                -NextSteps @('No action needed - GeeNet continues with the Wi-Fi and internet checks') `
                -FixClass 'NotNeeded' `
                -Technical "No 802.3 adapter present. Wi-Fi adapters up: $(($wifiUp | ForEach-Object { $_.Name }) -join ', ')." `
                -Data $data -DurationMs $sw.ElapsedMilliseconds
        }
        return New-GNResult -Id 'Ethernet' -Name 'Ethernet (cable) check' -Layer 'Link' -Status 'Fail' `
            -Summary "No Ethernet adapter was found on this computer." `
            -Why "An Ethernet connection needs a physical network port/adapter, so Windows must be able to see one." `
            -Meaning "This computer either has no wired port, or the wired adapter is disabled, uninstalled, or has a driver problem." `
            -Causes @('Desktop/laptop has no Ethernet port (some thin laptops need a USB or dock adapter)','Ethernet adapter disabled in Device Manager or Network Connections','Missing or broken Ethernet driver','Adapter hidden because it is switched off in BIOS/UEFI') `
            -NextSteps @('Open Device Manager and check for an Ethernet adapter under Network adapters','If it has a warning symbol, try Enable device, then Update driver','If you use a USB/dock adapter, unplug and replug it','If this PC has no wired port, Wi-Fi is your connection type - no Ethernet troubleshooting needed') `
            -FixClass 'Manual' `
            -Technical "Adapters found: $(($adapters | ForEach-Object { "$($_.Name)[$($_.Status)]" }) -join '; ')" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($ethUp.Count -eq 0) {
        $wifiInUse = @($adapters | Where-Object { $_.IsWifi -and $_.Status -eq 'Up' })
        if ($wifiInUse.Count -gt 0) {
            return New-GNResult -Id 'Ethernet' -Name 'Ethernet (cable) check' -Layer 'Link' -Status 'Info' `
                -Summary "No cable is plugged in, and it is not needed - you are connected over Wi-Fi." `
                -Why "A wired link only matters when it is the connection you are actually using." `
                -Meaning "Windows sees the network card with no cable attached. Your Wi-Fi connection ($(($wifiInUse | ForEach-Object { $_.Name }) -join ', ')) is up, so the missing cable is not causing your problem." `
                -NextSteps @('No action needed - GeeNet checks the connection you are actually using') `
                -FixClass 'NotNeeded' `
                -Technical "Ethernet adapters: $($data.DownStatuses). Wi-Fi adapters up: $(($wifiInUse | ForEach-Object { $_.Name }) -join ', ')." `
                -Data $data -DurationMs $sw.ElapsedMilliseconds
        }
        $statusText = if ($data.DownStatuses) { $data.DownStatuses } else { 'unknown' }
        return New-GNResult -Id 'Ethernet' -Name 'Ethernet (cable) check' -Layer 'Link' -Status 'Fail' `
            -Summary "The Ethernet adapter exists but there is no active cable link ($statusText)." `
            -Why "An Ethernet connection is only 'up' when a cable links your PC to a working port on a switch or router." `
            -Meaning "Windows sees the network card, but no signal is arriving through the cable. This is the classic 'Network cable unplugged' state." `
            -Causes @('Cable is unplugged at the PC or at the router/switch','Damaged or low-quality cable','The router/switch port is dead or disabled','The dock/USB-Ethernet adapter lost power or its driver failed','Adapter disabled in Windows') `
            -NextSteps @('Push the cable in firmly at both ends until it clicks','Try a different cable, then a different port on the router','Try the cable on another device to prove the cable is good','If you are on a dock, unplug the dock and reconnect it, then check the adapter again') `
            -FixClass 'Manual' `
            -Technical "Ethernet adapter(s): $($data.DownStatuses)" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    $warn = $false
    $causes = @()
    $steps = @()
    $meaning = "The cable link is up and the speed looks normal for this hardware."
    $speedText = $data.LinkSpeeds
    if ($data.LinkSpeeds -match '100\s*Mbps|10\s*Mbps') {
        $warn = $true
        $meaning = "The link is up, but it negotiated a low speed ($speedText). Gigabit-capable equipment usually links at 1 Gbps - a slow link is often a cable problem."
        $causes = @('Cable is only Cat5 or damaged (only 2 of 4 wire pairs working)','Cable is long or kinked','Router/switch port or the PC port is failing','Old powerline/adapter hardware in the path')
        $steps = @('Swap the cable for a known-good Cat5e/Cat6 cable','Try a different port on the router/switch','If the speed stays low, test with another computer to see whether it is the cable or the port')
    }
    if ($data.ContainsKey('RxErrors') -and $data.RxErrors -gt 100) {
        $warn = $true
        $meaning += " The adapter also reports receive errors ($($data.RxErrors)), which points at the cable/port more than at Windows settings."
        $causes += 'Faulty cable or port causing damaged frames'
        $steps += 'Replace the Ethernet cable and retest - error counters pointing up usually means bad cabling'
    }

    return New-GNResult -Id 'Ethernet' -Name 'Ethernet (cable) check' -Layer 'Link' -Status $(if ($warn) { 'Warn' } else { 'Pass' }) `
        -Summary "Ethernet link is up ($speedText)." `
        -Why "A healthy wired link is the most reliable connection a computer can have - if it is up, cable and port problems are ruled out." `
        -Meaning $meaning -Causes $causes -NextSteps $steps `
        -Technical "Adapter errors: rx=$($data.RxErrors) tx=$($data.TxErrors) discards=$($data.RxDiscards)" `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-AdapterDriver {
    <#  Device Manager level problems: adapter present but with an error code. #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $problems = @()
    $evidence = @()
    if (Test-GNCommand Get-CimInstance) {
        try {
            $rows = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
                      Where-Object { "$($_.PNPClass)" -match 'Net|Wireless' })
            foreach ($r in $rows) {
                $code = $null
                try { if ($r.ConfigManagerErrorCode -ne $null) { $code = [int]$r.ConfigManagerErrorCode } } catch { }
                if ($code -ne $null -and $code -ne 0) {
                    $problems += [pscustomobject]@{ Device = "$($r.Name)"; ErrorCode = $code; Status = "$($r.Status)" }
                    $evidence += "$($r.Name) (code $code)"
                }
            }
        } catch { }
    }
    $sw.Stop()

    $data = @{ ProblemDevices = $problems; Count = $problems.Count }

    if ($problems.Count -gt 0) {
        $first = $problems[0]
        $explain = switch ($first.ErrorCode) {
            1  { 'The device is not configured correctly - this usually means the driver failed to load.' }
            10 { 'The device cannot start. This is almost always a driver problem.' }
            12 { 'Not enough free resources for the device. A restart often clears this.' }
            22 { 'The device is disabled - Windows is deliberately not using it.' }
            28 { 'No driver is installed for this device.' }
            31 { 'Windows could not load the driver for this device.' }
            43 { 'Windows stopped the device after it reported a problem - typical of a crashed or misbehaving driver.' }
            45 { 'The device is not currently connected to the computer.' }
            52 { 'Windows cannot verify the digital signature of the driver.' }
            default { "Windows reported error code $($first.ErrorCode) for this device." }
        }
        return New-GNResult -Id 'AdapterDriver' -Name 'Network adapter driver check' -Layer 'Link' -Status 'Fail' `
            -Summary "Windows is reporting a problem with a network device: $($evidence -join '; ')" `
            -Why "A device with an error code will not carry network traffic no matter how good the cable, Wi-Fi or router are." `
            -Meaning "This is a driver/device problem inside Windows, not a problem with your router or ISP. $explain" `
            -Causes @('Driver corrupted or replaced by a bad Windows update','Driver incompatible with this version of Windows','Device failed to start after an unclean shutdown','Antivirus/security tool blocking the driver','Hardware fault') `
            -NextSteps @('Open Device Manager and find the device with the warning symbol','Right-click it and choose Uninstall device (keep the "delete driver software" box unticked first)','Then choose Scan for hardware changes so Windows reinstalls the driver','If it returns with the same error, download the driver from the PC maker or adapter maker','As a quick test/repair, remove and reinsert a USB Wi-Fi/Ethernet adapter','Restart the computer and run this check again') `
            -FixClass 'Manual' `
            -Technical "Device Manager error codes: $($evidence -join ', ')" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'AdapterDriver' -Name 'Network adapter driver check' -Layer 'Link' -Status 'Pass' `
        -Summary "No network device errors reported by Windows." `
        -Why "A device with the wrong driver can look connected while silently dropping traffic." `
        -Meaning "Device Manager is happy with the network hardware, so driver problems are unlikely to be the cause of your issue." `
        -Technical "Checked Win32_PnPEntity ConfigManagerErrorCode for Net/Wireless devices - all clean." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

# ------------------------------------------------------------------------------
#region 10. LAYER 3 TESTS: IP CONFIGURATION / DHCP / GATEWAY / ROUTING
# ------------------------------------------------------------------------------

function Get-GNInterfaceDetail {
    param([string]$Alias, [int]$Index = -1)
    $d = [ordered]@{
        Dhcp         = ''
        DhcpServer   = ''
        PrefixOrigin = ''
        SuffixOrigin = ''
        AddressState = ''
        IfOperStatus = ''
        Mtu          = ''
        Found        = $false
    }
    if (Test-GNCommand Get-NetIPInterface) {
        try {
            $iface = $null
            if ($Index -ge 0) { $iface = Get-NetIPInterface -InterfaceIndex $Index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1 }
            if (-not $iface -and $Alias) { $iface = Get-NetIPInterface -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1 }
            if ($iface) {
                $d.Found = $true
                $d.Dhcp = "$($iface.Dhcp)"
                $d.IfOperStatus = "$($iface.ConnectionState)"
                try { if ($iface.NlMtu) { $d.Mtu = $iface.NlMtu } } catch { }
            }
        } catch { }
    }
    if (Test-GNCommand Get-NetIPAddress) {
        try {
            $ip = $null
            if ($Index -ge 0) { $ip = Get-NetIPAddress -InterfaceIndex $Index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1 }
            if (-not $ip -and $Alias) { $ip = Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1 }
            if ($ip) {
                $d.Found = $true
                $d.PrefixOrigin = "$($ip.PrefixOrigin)"
                $d.SuffixOrigin = "$($ip.SuffixOrigin)"
                $d.AddressState = "$($ip.AddressState)"
            }
        } catch { }
    }
    if (Test-GNCommand Get-CimInstance) {
        try {
            $cfg = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue |
                     Where-Object { $_.IPEnabled -eq $true -and $_.Description })
            $hit = $null
            if ($Alias) {
                # match loosely: adapter alias vs adapter description
                $hit = $cfg | Where-Object { "$($_.Description)" -like "*$Alias*" } | Select-Object -First 1
                if (-not $hit) {
                    $hit = $cfg | Where-Object { "$($_.Caption)" -like "*$Alias*" -or "$($_.SettingID)" } | Select-Object -First 1
                }
            }
            if (-not $hit -and $cfg.Count -gt 0) { $hit = $cfg[0] }
            if ($hit) {
                if ($hit.DHCPEnabled -ne $null) { if ($hit.DHCPEnabled) { $d.Dhcp = 'Enabled' } elseif (-not $d.Dhcp) { $d.Dhcp = 'Disabled' } }
                if ($hit.DHCPServer) { $d.DhcpServer = "$($hit.DHCPServer)" }
            }
        } catch { }
    }
    return $d
}

function Test-IPConfiguration {
    <#  Does the computer have a usable IPv4 address, subnet and DNS? #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $adapters = @(Get-GNAdapters)
    $configs  = @(Get-GNIPConfig)
    $active   = $null
    $upNames  = @($adapters | Where-Object { $_.Status -eq 'Up' -and -not $_.IsVirtual } | ForEach-Object { $_.Name })
    foreach ($c in $configs) {
        if ($upNames -contains $c.Adapter) { $active = $c; break }
    }
    if (-not $active) { $active = $configs | Where-Object { $_.IPv4 } | Select-Object -First 1 }
    if (-not $active) { $active = $configs | Select-Object -First 1 }
    $sw.Stop()

    $detail = Get-GNInterfaceDetail -Alias "$($active.Adapter)" -Index ([int]"$($active.InterfaceIndex)")
    $ip = "$($active.IPv4)"
    $data = @{
        Adapter      = "$($active.Adapter)"
        IPv4         = $ip
        SubnetMask   = "$($active.SubnetMask)"
        PrefixLength = $active.PrefixLength
        Gateway      = "$($active.Gateway)"
        DnsServers   = @($active.DnsServers)
        DhcpEnabled  = $active.DhcpEnabled
        DhcpServer   = if ($active.DhcpServer) { $active.DhcpServer } else { $detail.DhcpServer }
        Apipa        = [bool]$active.Apipa
        HasIpv4      = [bool]$ip
        AddressState = $detail.AddressState
        ProfileName  = "$($active.ProfileName)"
        NetworkCategory = "$($active.NetworkCategory)"
        Mtu          = $detail.Mtu
        AdapterStatus= "$($active.AdapterStatus)"
    }

    if (-not $ip) {
        return New-GNResult -Id 'IPConfig' -Name 'IP address check' -Layer 'IP' -Status 'Fail' `
            -Summary "Your computer does not have an IPv4 address on the active adapter ($($active.Adapter))." `
            -Why "Every device on a network needs its own IP address. It is how your computer is identified and how replies find their way back to you." `
            -Meaning "Without an IPv4 address your computer cannot send or receive normal network traffic. This is a configuration/DHCP problem, not a website problem." `
            -Causes @('Windows has not been able to get an address from the router (DHCP)','The adapter is still starting up, or the link just came up','DHCP Client service is stopped or broken','Static IP was misconfigured (wrong subnet, wrong adapter)','The router is not offering DHCP (router-side problem)') `
            -NextSteps @('Ask Windows to get a fresh address from the router (GeeNet can do this for you)','Check the cable/Wi-Fi connection is really up','If renewing fails twice, suspect the router/DHCP side or a stopped DHCP service') `
            -FixClass 'SafeAuto' `
            -Technical "Adapter '$($active.Adapter)' has no IPv4 address. DHCP: $($detail.Dhcp). Address state: $($detail.AddressState)." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($active.Apipa) {
        return New-GNResult -Id 'IPConfig' -Name 'IP address check' -Layer 'IP' -Status 'Fail' `
            -Summary "Your computer gave itself a $ip address. That is an automatic fallback address, not a real network address." `
            -Why "Addresses beginning with 169.254 are self-assigned by Windows when it cannot reach a DHCP server." `
            -Meaning "Windows could not obtain an IP address from the network, so it made one up so it could still talk to the local segment. With this address you can only reach other machines that have done the same - normally there is no internet and no router access." `
            -Causes @('The router is not giving out addresses (DHCP server off, pool exhausted, DHCP broken)','The cable/Wi-Fi link is not truly connected to the network (wrong SSID, VLAN, dead switch port)','DHCP Client service stopped, or firewall blocking DHCP (UDP 67/68)','Adapter is set to a static address in the 169.254 range by mistake','Rogue DHCP / rogue device on the network') `
            -NextSteps @('GeeNet will try to get a proper address from the router (release + renew)','If you still get 169.254 after a renew, the router/DHCP side is the likely problem','Check whether other devices on this network get normal addresses','If your PC works on a phone hotspot but not here, the home router DHCP is the suspect') `
            -FixClass 'SafeAuto' `
            -Technical "IPv4 $ip (APIPA/self-assigned). DHCP: $($detail.Dhcp). Gateway: '$($active.Gateway)'." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    $extra = @()
    $status = 'Pass'
    $causes = @()
    $steps = @()
    $meaning = "Your computer has a proper IPv4 address from the network, which means the DHCP conversation with the router worked."

    if ($ip -match '^169\.254\.') { }
    elseif ($ip -match '^0\.') {
        $status = 'Fail'
        $meaning = "The address $ip is not usable."
        $causes = @('Adapter is set to "Obtain automatically" but no DHCP server was reachable at connection time')
        $steps = @('Get a fresh address from DHCP (GeeNet can do this)')
    }
    if ("$($active.SubnetMask)" -eq '255.255.255.255') {
        $status = 'Warn'
        $meaning += " The subnet mask is 255.255.255.255, which limits the computer to itself - unusual outside VPN point-to-point links."
        $causes += 'Wrong subnet mask or prefix length in the IP settings'
        $steps += 'Check the IP/subnet mask in IPv4 settings - it probably should be 255.255.255.0 for a home network'
    }
    if ($data.AddressState -eq 'Duplicate') {
        $status = 'Fail'
        $meaning = "Windows detected that another device on the network is using the same IP address (duplicate address)."
        $causes = @('Another device is configured with the same static IP','A stale DHCP reservation handed the same address to two devices','Two adapters/VMs sharing a bridged network with the same address')
        $steps = @('Get a fresh address from DHCP so you get a different one','If a static IP is configured, change it to a free address or switch back to automatic','Restart the other device that appears to share the address')
    }
    if ($data.ProfileName) { $extra += "Network profile: $($data.ProfileName) [$($data.NetworkCategory)]." }
    if ($data.Mtu) { $extra += "MTU: $($data.Mtu)." }

    return New-GNResult -Id 'IPConfig' -Name 'IP address check' -Layer 'IP' -Status $status `
        -Summary "Your computer has the IPv4 address $ip (subnet $($active.SubnetMask))." `
        -Why "The IP address, subnet mask and gateway together tell your computer what network it is on and how to leave that network." `
        -Meaning $meaning `
        -Causes $causes -NextSteps $steps `
        -FixClass $(if ($status -eq 'Fail') { 'SafeAuto' } elseif ($status -eq 'Warn') { 'Manual' } else { 'NotNeeded' }) `
        -Technical "$($active.Adapter): IPv4 $ip/$($active.PrefixLength) (mask $($active.SubnetMask)), gateway '$($active.Gateway)', DNS $((@($active.DnsServers)) -join ', '). DHCP: $($detail.Dhcp). $($extra -join ' ')" `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-DHCP {
    <#  The DHCP conversation: is the PC asking the router for an address, and did it work? #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $active = Get-GNActiveAdapter
    $detail = $null
    if ($active) { $detail = Get-GNInterfaceDetail -Alias "$($active.Config.Adapter)" -Index ([int]"$($active.Adapter.InterfaceIndex)") }
    $svc = @(Get-GNCriticalServices) | Where-Object { $_.Name -eq 'Dhcp' } | Select-Object -First 1
    $sw.Stop()

    $data = @{
        DhcpEnabled = if ($detail) { $detail.Dhcp } else { '' }
        DhcpServer  = if ($detail) { $detail.DhcpServer } else { '' }
        SuffixOrigin= if ($detail) { $detail.SuffixOrigin } else { '' }
        Service     = if ($svc) { $svc.Status } else { 'not found' }
        Apipa       = if ($active -and $active.Config) { [bool]$active.Config.Apipa } else { $false }
        IPv4        = if ($active -and $active.Config) { "$($active.Config.IPv4)" } else { '' }
        Adapter     = if ($active) { "$($active.Config.Adapter)" } else { '' }
    }
    $svcText = if ($svc) { "$($svc.Display) = $($svc.Status)" } else { 'DHCP Client service not found' }
    $tech = "DHCP: $($data.DhcpEnabled). Origin: $($data.SuffixOrigin). Server: $($data.DhcpServer). Service: $svcText."

    if ($svc -and $svc.Status -ne 'Running') {
        return New-GNResult -Id 'Dhcp' -Name 'Automatic address (DHCP) check' -Layer 'IP' -Status 'Fail' `
            -Summary "The Windows DHCP Client service is not running, so this computer cannot request an IP address automatically." `
            -Why "Windows asks the router for an address through this service. If the service is stopped, the request is never sent." `
            -Meaning "This is why an address may be missing or the computer may be stuck with a 169.254 self-assigned address. Fixing the service is a Windows-side repair." `
            -Causes @('Service stopped or disabled','Service disabled by an optimiser/tweaking tool','Service crashed') `
            -NextSteps @('GeeNet can start the DHCP Client service if it is stopped','If it will not start, note the error and restart Windows','Check that no "network optimiser" tool disabled it') `
            -FixClass 'NeedsAdmin' `
            -Technical $tech `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($data.DhcpEnabled -eq 'Disabled') {
        $isManualOk = (-not $data.Apipa -and $data.IPv4)
        $status = if ($isManualOk) { 'Info' } else { 'Warn' }
        return New-GNResult -Id 'Dhcp' -Name 'Automatic address (DHCP) check' -Layer 'IP' -Status $status `
            -Summary "This adapter is set to use a fixed (static) IP address instead of asking the router automatically." `
            -Why "Most home and office networks hand out addresses automatically. A fixed address only works if it matches the network and does not clash with another device." `
            -Meaning $(if ($isManualOk) { "Your static address $($data.IPv4) looks usable, but it is not from DHCP - if your network changed (new router, new subnet) this will stop working." } else { "The manual address is missing or unusable, and because DHCP is switched off Windows will not ask the router for one." }) `
            -Causes @('Static IP configured on purpose (server, printer, lab exercise)','Static IP left over from an earlier network','A troubleshooting step someone set and did not undo') `
            -NextSteps $(if ($isManualOk) { @('If this static address is intentional, keep it - just make sure it is outside the router DHCP range','If it was not intentional, switch the adapter back to "Obtain an IP address automatically"','After any change, confirm the gateway and DNS still look right') } else { @('Switch this adapter back to automatic addressing (GeeNet can do this)','Then renew the address and check that a normal address appears','Recheck the gateway and DNS afterwards') }) `
            -FixClass $(if ($isManualOk) { 'Manual' } else { 'NeedsAdmin' }) `
            -Technical $tech `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($data.Apipa -or -not $data.IPv4) {
        return New-GNResult -Id 'Dhcp' -Name 'Automatic address (DHCP) check' -Layer 'IP' -Status 'Fail' `
            -Summary "Your computer asked the network for an address but did not receive one (no address, or a 169.254 fallback address)." `
            -Why "DHCP is the automatic address hand-out service that runs on your router. When it fails you get no valid address for your network." `
            -Meaning "The problem is between your computer and the router's DHCP service: either the request never reached it, the reply never came back, or the router refused to give one." `
            -Causes @('Router DHCP server disabled, pool exhausted, or router needs a restart','Link is not really connected to the network (wrong SSID, dead switch port, VLAN mismatch)','DHCP traffic blocked by firewall/security software','DHCP Client service problem','Very rarely: another device on the network is answering DHCP incorrectly') `
            -NextSteps @('GeeNet will release and renew the address (usually fixes transient failures)','If renewal keeps failing, restart the router - physical router action, not something GeeNet can do','Test another device on the same network: if it also fails, the router/ISP side is the suspect') `
            -FixClass 'SafeAuto' `
            -Technical $tech `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'Dhcp' -Name 'Automatic address (DHCP) check' -Layer 'IP' -Status 'Pass' `
        -Summary "DHCP is working: your computer received the address $($data.IPv4) from the network." `
        -Why "A valid DHCP address proves the router is reachable enough to answer a request, which is a very good sign for the local network." `
        -Meaning "Address assignment is working, so any remaining problem is further along the path (gateway, internet, DNS or an application)." `
        -Technical $tech `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-DefaultGateway {
    <#  Is a default gateway (the router) configured? #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $active = Get-GNActiveAdapter
    $configs = @(Get-GNIPConfig)
    $mw = @($configs | Where-Object { $_.Gateway -and -not $_.Apipa })
    $routes = @(Get-GNRoutes) | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -or $_.DestinationPrefix -eq '0.0.0.0' }
    $sw.Stop()

    $gw = if ($active -and $active.Config -and $active.Config.Gateway) { "$($active.Config.Gateway)" } else { "$(($mw | Select-Object -First 1).Gateway)" }
    $data = @{
        Gateway      = $gw
        HasGateway   = [bool]$gw
        GatewayCount = $mw.Count
        DefaultRoutes= $routes.Count
        Adapter      = if ($active) { "$($active.Config.Adapter)" } else { '' }
        IPv4         = if ($active -and $active.Config) { "$($active.Config.IPv4)" } else { '' }
        Apipa        = if ($active -and $active.Config) { [bool]$active.Config.Apipa } else { $false }
        RouteNextHops= (($routes | ForEach-Object { "$($_.NextHop) (metric $($_.RouteMetric))" }) -join ', ')
    }

    if (-not $gw) {
        $reason = if ($data.Apipa) { 'your computer has a self-assigned 169.254 address, so the router never told it where the exit is' } else { 'no IPv4 configuration includes a default gateway' }
        return New-GNResult -Id 'Gateway' -Name 'Router (default gateway) check' -Layer 'IP' -Status 'Fail' `
            -Summary "No default gateway is configured - Windows does not know which device to send internet traffic to." `
            -Why "The default gateway is normally your router. It is the exit door out of your local network; without it, traffic to the internet has nowhere to go." `
            -Meaning "Because $reason, your computer has no route to anything outside its own network segment. Internet access is impossible until this is fixed." `
            -Causes @('No valid IP address from DHCP (the gateway arrives with the address)','Static IP configured without a gateway','Wrong subnet mask, so the gateway address is not considered local','Adapter is connected to something that does not route (a switch with no router, a dead port)') `
            -NextSteps @('Get a fresh address from DHCP - the gateway normally comes with it','If you use a static IP, fill in the gateway field with your router address (often 192.168.0.1 or 192.168.1.1)','Check the adapter is really connected to your own network, not somebody else''s or a guest network') `
            -FixClass 'SafeAuto' `
            -Technical "No 0.0.0.0/0 route with a valid next hop. IP configs seen: $(($configs | ForEach-Object { "$($_.Adapter)=$($_.IPv4)/gw:'$($_.Gateway)'" }) -join '; ')" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    $tech = "Gateway $gw from interface '$($data.Adapter)'. Default routes: $($data.DefaultRoutes) [$($data.RouteNextHops)]."
    $warnExtra = ''
    $status = 'Pass'
    if ($mw.Count -gt 1) {
        $status = 'Warn'
        $others = ($mw | ForEach-Object { "$($_.Adapter)=$($_.Gateway)" }) -join ', '
        $warnExtra = " More than one adapter has a gateway ($others). Multiple gateways can send traffic out of the wrong interface."
    }

    return New-GNResult -Id 'Gateway' -Name 'Router (default gateway) check' -Layer 'IP' -Status $status `
        -Summary "Your router address is set to $gw." `
        -Why "This is the address your computer uses to leave the local network, so GeeNet needs to know it before testing the path outward." `
        -Meaning "The gateway is configured and looks like a normal private address on your network.$warnExtra" `
        -Causes $(if ($status -eq 'Warn') { @('A VPN or virtual adapter is also providing a default route','Two adapters (Wi-Fi and Ethernet) are both connected at once') } else { @() }) `
        -NextSteps $(if ($status -eq 'Warn') { @('Disconnect the adapter you are not using (for example turn Wi-Fi off if you are on Ethernet)','If a VPN is meant to be off, disconnect it and recheck','Then rerun this check') } else { @() }) `
        -FixClass 'NotNeeded' `
        -Technical $tech `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-GatewayReach {
    <#
      Can the computer actually talk to the router?
      ICMP is tried first; if the router does not answer ICMP we cross-check with the ARP
      table and a TCP probe, because many routers simply block ping.
    #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $gw = Get-GNDefaultGateway
    if (-not $gw) {
        $sw.Stop()
        return New-GNResult -Id 'GatewayReach' -Name 'Router reachability check' -Layer 'Local' -Status 'Skip' `
            -Summary "No router address was found, so there is nothing to ping." `
            -SkipReason "Without a default gateway we cannot test the router directly. Fix the IP/gateway configuration first." `
            -Data @{ Gateway = ''; Skipped = $true } -DurationMs $sw.ElapsedMilliseconds
    }

    $ping = Invoke-GNPing -Target $gw -Count 2 -TimeoutMs 1200
    $arpHit = $false; $arpMac = ''
    try {
        $arpNeighbors = @(Get-GNNeighbors)
        $n = $arpNeighbors | Where-Object { "$($_.IPAddress)" -eq "$gw" } | Select-Object -First 1
        if ($n -and "$($n.LinkLayerAddress)" -and "$($n.LinkLayerAddress)" -notmatch '^(00-00-00-00-00-00|00:00:00:00:00:00|)$') {
            $arpHit = $true; $arpMac = "$($n.LinkLayerAddress)"
        }
    } catch { }

    $tcp = $null
    if (-not $ping.Success -and $arpHit) {
        foreach ($p in @(53, 80, 443)) {
            $tcp = Test-GNTcpPort -Target $gw -Port $p -TimeoutMs 2000
            if ($tcp.Open) { break }
        }
    }
    $sw.Stop()

    $tcpOpen = ($tcp -and $tcp.Open)
    $data = @{
        Gateway   = "$gw"
        PingOk    = $ping.Success
        PingLoss  = $ping.LossPercent
        PingAvg   = $ping.AvgMs
        ArpPresent= $arpHit
        ArpMac    = $arpMac
        TcpOpen   = $tcpOpen
        TcpPort   = if ($tcpOpen) { $tcp.Port } else { 0 }
        Reachable = ($ping.Success -or $tcpOpen)
        Statuses  = ($ping.Statuses -join ',')
    }

    if ($ping.Success) {
        return New-GNResult -Id 'GatewayReach' -Name 'Router reachability check' -Layer 'Local' -Status 'Pass' `
            -Summary "Your router ($gw) answered $($ping.Received) of $($ping.Sent) pings in about $($ping.AvgMs) ms." `
            -Why "If the router answers, then your Wi-Fi/Ethernet link and your local network are working. It separates 'local' problems from 'internet' problems." `
            -Meaning "The local network path is healthy. Any remaining fault is very likely further out: internet/ISP, DNS, or the application itself." `
            -Technical "ping $gw -> $($ping.Received)/$($ping.Sent) replies, avg $($ping.AvgMs) ms, loss $($ping.LossPercent)%." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($tcpOpen) {
        return New-GNResult -Id 'GatewayReach' -Name 'Router reachability check' -Layer 'Local' -Status 'Pass' `
            -Summary "Your router did not answer pings, but its hardware address is in your ARP table and it accepted a TCP connection on port $($tcp.Port) - so the router is reachable." `
            -Why "Many routers are configured to ignore ping (ICMP) as a security measure, so a failed ping alone does not prove a fault." `
            -Meaning "The local network is fine. GeeNet confirmed the router another way, so we should not blame the cable, Wi-Fi or IP configuration." `
            -Technical "ICMP blocked by router. ARP entry for $gw = $arpMac. TCP $($tcp.Port) connected in $($tcp.ElapsedMs) ms." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($arpHit) {
        return New-GNResult -Id 'GatewayReach' -Name 'Router reachability check' -Layer 'Local' -Status 'Warn' `
            -Summary "Your router ($gw) did not answer pings and did not accept a TCP connection, but its hardware address ($arpMac) is visible on your network." `
            -Why "Seeing the router's hardware address proves the cable/Wi-Fi link is live and the router is physically present on your network." `
            -Meaning "The router is there at the link level, but it is not responding at the network level. It may be overloaded, mid-restart, blocking all traffic from this PC, or filtering this traffic." `
            -Causes @('Router is busy, updating, or partially crashed','Router firewall/access rules blocking this computer','Your computer is connected to a different network segment (guest network, VLAN) than the router interface you are testing','Duplicate IP address on the network','Router is restarting') `
            -NextSteps @('Turn the router off for 30 seconds and back on, then re-test (physical action - GeeNet cannot do this)','Check whether other devices on this network can reach it','If you are on a guest/hotel/office Wi-Fi, some traffic may be deliberately blocked','Check for an IP address conflict on this computer') `
            -FixClass 'Hardware' `
            -Technical "ping $gw -> $($ping.Received)/$($ping.Sent) replies ($($ping.LossPercent)% loss). ARP entry present: $arpMac. TCP 53/80/443 all refused or timed out." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'GatewayReach' -Name 'Router reachability check' -Layer 'Local' -Status 'Fail' `
        -Summary "GeeNet sent pings to your router ($gw) and got no reply. The router is not answering on your network." `
        -Why "The router is the doorway out of your network. If the computer cannot reach the router, no internet traffic can leave, no matter what the router is doing." `
        -Meaning "The problem is local: between this computer and the router. Your internet connection itself may be perfectly fine - your computer just cannot use it." `
        -Causes @('Wi-Fi connected to the wrong network or a weak/dead connection','Ethernet cable, port or dock problem','Incorrect IP address or subnet mask, so the gateway is not on the same subnet','The router is off, restarting, or its LAN side is unresponsive','Your computer is on a different network/subnet than the gateway') `
        -NextSteps @('Check whether you are on Wi-Fi or Ethernet and make sure that connection is really up','Compare your IP address and subnet mask with the gateway address - they must be on the same network','Turn the router off and on again (physical action)','If other devices work, retest the adapter here; if nothing works, the router is the suspect') `
        -FixClass 'Manual' `
        -Technical "ping $gw -> $($ping.Received)/$($ping.Sent) replies. Statuses: $($ping.Statuses). No ARP entry for the gateway. TCP probes: refused/timed out." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

# ------------------------------------------------------------------------------
#region 11. LAYER 3-4 TESTS: INTERNET IP, TCP, LATENCY, PACKET LOSS, STABILITY
# ------------------------------------------------------------------------------

$script:GNInternetTargets = @('1.1.1.1','8.8.8.8')     # Cloudflare + Google: no DNS needed
$script:GNControlSites    = @('https://www.msftconnecttest.com/connecttest.txt','https://www.google.com/generate_204')

function Test-InternetIP {
    <#
      Can we reach the internet by raw IP address (no DNS involved at all)?
      ICMP first, then TCP 443 - because some networks block ping but allow web traffic.
    #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $icmpOk = $false
    $bestIcmp = $null
    $results = @()
    foreach ($t in $script:GNInternetTargets) {
        $p = Invoke-GNPing -Target $t -Count 2 -TimeoutMs 1500
        $results += $p
        if ($p.Success -and -not $icmpOk) { $icmpOk = $true; $bestIcmp = $p }
    }

    $tcpOk = $false; $tcpInfo = $null
    if (-not $icmpOk) {
        foreach ($t in $script:GNInternetTargets) {
            $c = Test-GNTcpPort -Target $t -Port 443 -TimeoutMs 3000 -NoDns
            if ($c.Open) { $tcpOk = $true; $tcpInfo = $c; break }
        }
    }
    $sw.Stop()

    $data = @{
        IcmpOk      = $icmpOk
        Tcp443Ok    = $tcpOk
        LossPercent = if ($bestIcmp) { $bestIcmp.LossPercent } elseif ($results.Count -gt 0) { $results[0].LossPercent } else { 100 }
        AvgMs       = if ($bestIcmp) { $bestIcmp.AvgMs } else { $null }
        Successful  = if ($bestIcmp) { $bestIcmp.Target } elseif ($tcpInfo) { $tcpInfo.Target } else { '' }
        Results     = @(Get-GNArray -Items $results | ForEach-Object { "$($_.Target): $($_.Received)/$($_.Sent) replies, statuses $($_.Statuses -join '/')" })
    }

    if ($icmpOk) {
        return New-GNResult -Id 'InternetIP' -Name 'Internet reachability check (by IP address)' -Layer 'Transport' -Status 'Pass' `
            -Summary "GeeNet reached the internet: $($data.Successful) answered $($bestIcmp.Received) of $($bestIcmp.Sent) pings in about $($bestIcmp.AvgMs) ms." `
            -Why "Testing a public IP address uses no domain names at all, so it tells us whether the internet path itself works - separately from DNS." `
            -Meaning "Traffic is leaving your network and coming back. Your router, your ISP link and the internet path are working, so any remaining problem is NOT your connection itself." `
            -Technical ($data.Results -join ' | ') `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($tcpOk) {
        return New-GNResult -Id 'InternetIP' -Name 'Internet reachability check (by IP address)' -Layer 'Transport' -Status 'Pass' `
            -Summary "Ping was blocked, but GeeNet still reached the internet: a TCP connection to $($tcpInfo.Target) port 443 succeeded in $($tcpInfo.ElapsedMs) ms." `
            -Why "Some networks and routers block ping (ICMP) while web traffic works normally. Checking a web port avoids a false alarm." `
            -Meaning "Your internet connection works. The 'failed ping' you may have seen is just this network blocking ICMP, which is normal in hotels, offices and some ISPs." `
            -Technical "ICMP: no replies from $($script:GNInternetTargets -join ', '). TCP 443 to $($tcpInfo.Target): connected." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'InternetIP' -Name 'Internet reachability check (by IP address)' -Layer 'Transport' -Status 'Fail' `
        -Summary "GeeNet could not reach the internet by IP address. Neither ping nor a web-port connection to 1.1.1.1 or 8.8.8.8 worked." `
        -Why "This test skips domain names completely, so a failure here means the path out of your network is broken - not a DNS problem." `
        -Meaning "Your computer can (or cannot) reach the router, but traffic is not reaching the internet. Everything that needs the internet will fail from this point." `
        -Causes @('Router is up but its internet (WAN) link is down','ISP outage or maintenance in your area','Router needs a restart, or its internet light is red/orange','Your account/line is suspended or the data bundle is finished','Captive portal (hotel/airport Wi-Fi) has not been accepted yet','MAC filtering / parental controls blocking this device at the router','Router firewall or ISP blocking this traffic') `
        -NextSteps @('Check another device (phone on mobile data is not proof - use the same Wi-Fi) - if it also fails, the problem is router/ISP side','Look at your router lights: internet/WAN light should be on or blinking','Restart the router (unplug 30 seconds) - physical action, GeeNet cannot do this','If a login page should appear on public Wi-Fi, open a browser and accept the terms','If other devices work but this PC does not, come back and run the local checks again') `
        -FixClass 'Boundary' `
        -Technical "$(($data.Results) -join ' | ') | TCP 443 probes: $((@($script:GNInternetTargets) | ForEach-Object { "$($_):$((Test-GNTcpPort -Target $_ -Port 443 -TimeoutMs 2500 -NoDns).Open)" }) -join ', ')" `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-DNS {
    <#  Do domain names resolve - and if not, is it us or the DNS server? #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $active = Get-GNActiveAdapter
    $servers = @()
    if ($active -and $active.Config) { $servers = @($active.Config.DnsServers) }
    $servers = @($servers | Where-Object { $_ })

    $targets = @('www.google.com','www.microsoft.com')
    $results = @()
    $successCount = 0
    $slowest = 0
    foreach ($t in $targets) {
        $r = Invoke-GNDnsQuery -Name $t -TimeoutSec 6
        $results += $r
        if ($r.Success) { $successCount++; if ($r.ElapsedMs -gt $slowest) { $slowest = $r.ElapsedMs } }
    }
    $allOk = ($successCount -eq $targets.Count)
    $partial = ($successCount -ge 1 -and -not $allOk)

    # If the configured resolver failed, try a public resolver to localise the fault.
    $fallback = $null
    if (-not $allOk) {
        $fallback = Invoke-GNDnsQuery -Name 'www.google.com' -Server '1.1.1.1' -TimeoutSec 6
    }
    $sw.Stop()

    $badServer = @($servers | Where-Object { $_ -match '^(0\.0\.0\.0|255\.255\.255\.255|169\.254\.)' })
    $data = @{
        DnsServers      = @($servers)
        SuccessCount    = $successCount
        TargetCount     = $targets.Count
        AllOk           = $allOk
        Partial         = $partial
        SlowestMs       = $slowest
        FallbackOk      = if ($fallback) { $fallback.Success } else { $null }
        FallbackAddress = if ($fallback) { ($fallback.Addresses | Select-Object -First 1) } else { '' }
        BadServers      = $badServer
        Results         = @(Get-GNArray -Items $results | ForEach-Object { "$($_.Name): $(if ($_.Success) { ($_.Addresses -join ',') + ' in ' + $_.ElapsedMs + 'ms' } else { 'FAILED (' + $_.Error + ')' })" })
    }
    $serverText = if ($servers.Count -gt 0) { $servers -join ', ' } else { 'none configured' }

    if ($allOk -and $slowest -le 1200) {
        return New-GNResult -Id 'DNS' -Name 'DNS name resolution check' -Layer 'App' -Status 'Pass' `
            -Summary "Names resolve correctly: GeeNet turned www.google.com and www.microsoft.com into IP addresses using your DNS server ($serverText)." `
            -Why "DNS is the internet's phone book. Your computer needs it to turn a name like google.com into an address it can actually connect to." `
            -Meaning "DNS is healthy, so 'websites do not open' is very unlikely to be a DNS problem. Look instead at HTTPS/firewall/proxy or the specific site/application." `
            -Technical "$(($data.Results) -join ' | ') | resolvers: $serverText" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($allOk -and $slowest -gt 1200) {
        return New-GNResult -Id 'DNS' -Name 'DNS name resolution check' -Layer 'App' -Status 'Warn' `
            -Summary "Names resolve, but slowly - the slowest lookup took $slowest ms (a healthy lookup is usually under 200 ms)." `
            -Why "Before any web page can load, the name must be resolved. Slow DNS makes every new website you open feel sluggish, even on a fast connection." `
            -Meaning "Your DNS server is answering but taking too long. This usually shows up as 'websites take a few seconds before they start loading'." `
            -Causes @('The DNS server configured (often the router) is forwarding slowly or is overloaded','DNS is being proxied through a VPN or security tool','Packet loss or high latency on the connection','Too many open connections/streams from downloads on this PC') `
            -NextSteps @('Try switching this computer to a fast public DNS server (GeeNet can set 1.1.1.1 / 8.8.8.8 for you)','If you use a VPN, compare speed with it disconnected','Re-test after the change - the lookup time should drop clearly') `
            -FixClass 'NeedsAdmin' `
            -Technical "$(($data.Results) -join ' | ') | resolvers: $serverText" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($fallback -and $fallback.Success) {
        return New-GNResult -Id 'DNS' -Name 'DNS name resolution check' -Layer 'App' -Status 'Fail' `
            -Summary "Your normal DNS server could not resolve names, but a public DNS server (1.1.1.1) could. That points to the DNS server your computer is using." `
            -Why "GeeNet compares your configured resolver with a well-known public resolver - if one works and the other does not, the fault is in the resolver being used, not in the internet path." `
            -Meaning "Your internet connection is fine, but the DNS server you are pointed at is not answering properly. Names will fail to resolve for websites and apps until the DNS setting is corrected." `
            -Causes @('The DNS server address is wrong, stale, or belongs to an old network','The router is supposed to forward DNS but its DNS proxy is broken','VPN or a security product took over DNS and is failing','The configured DNS server is out of reach (blocked or offline)') `
            -NextSteps @('Switch this computer to reliable public DNS (GeeNet can do it for you)','If a VPN is connected, disconnect it and re-test','Re-test name resolution afterwards to confirm it is fixed') `
            -FixClass 'NeedsAdmin' `
            -Technical "Configured resolvers: $serverText. Failed: $(($results | Where-Object { -not $_.Success } | ForEach-Object { $_.Name + '(' + $_.Error + ')' }) -join '; '). Public resolver 1.1.1.1 succeeded with $($data.FallbackAddress)." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    $isDnsReachable = $false
    if ($servers.Count -gt 0) {
        foreach ($s in $servers) {
            $t = Test-GNTcpPort -Target $s -Port 53 -TimeoutMs 1500 -NoDns
            if ($t.Open) { $isDnsReachable = $true; break }
        }
    }

    return New-GNResult -Id 'DNS' -Name 'DNS name resolution check' -Layer 'App' -Status 'Fail' `
        -Summary "Name resolution failed for every test name. Your computer could not turn domain names into IP addresses." `
        -Why "DNS is the phone book of the internet. If it fails, you can still reach addresses by number, but any name you type or any app that uses names will fail." `
        -Meaning "This is a DNS failure, either because the DNS server is unreachable or because the DNS service/settings on this PC are broken. Note: if the internet path itself is also down, DNS failures are expected and this test is not the real fault." `
        -Causes @('DNS server address missing, wrong, or pointing at an old network','DNS server unreachable because the local network/internet path is down','Windows DNS Client service stopped or hosts file misconfigured','VPN or security software intercepting DNS and failing','Captive portal not yet accepted') `
        -NextSteps @('First confirm the internet path works (GeeNet checks that earlier) - if it does not, fix that first','Clear the DNS cache and retry (GeeNet can do this)','If it still fails, set a reliable public DNS server on this computer','Check the hosts file for bad entries if only specific sites fail') `
        -FixClass 'SafeAuto' `
        -Technical "Resolvers: $serverText. Results: $(($data.Results) -join ' | '). TCP 53 reachable: $isDnsReachable. Public resolver test: $(if ($fallback) { 'failed' } else { 'not run' })." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-HTTPS {
    <#
      End-to-end web test: TCP + TLS + HTTP response, plus captive-portal detection.
      Uses well-known Microsoft/Google endpoints so results are meaningful for browsing.
    #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $primary = Request-GNHttp -Url $script:GNControlSites[0] -TimeoutSec 8
    $secondary = $null
    if (-not $primary.Success) { $secondary = Request-GNHttp -Url $script:GNControlSites[1] -TimeoutSec 8 }
    $captive = Test-GNCaptivePortalInternal
    $sw.Stop()

    $data = @{
        PrimaryOk    = $primary.Success
        PrimaryCode  = $primary.StatusCode
        PrimaryMs    = $primary.ElapsedMs
        SecondaryOk  = if ($secondary) { $secondary.Success } else { $null }
        UsedProxy    = "$($primary.UsedProxy)"
        Error        = "$($primary.Error)"
        CaptivePortal= [bool]$captive.Portal
        PortalDetail = "$($captive.Detail)"
        ContentSample= "$($primary.Content)"
    }

    if ($primary.Success) {
        $bodyNote = ''
        if ($primary.Content) { $bodyNote = " Response started with: '" + ($primary.Content.Substring(0, [Math]::Min(60, $primary.Content.Length)) -replace '\s+',' ') + "'" }
        return New-GNResult -Id 'HTTPS' -Name 'Web (HTTPS) connectivity check' -Layer 'App' -Status 'Pass' `
            -Summary "A real web request worked: HTTPS to a known test site returned HTTP $($primary.StatusCode) in $($primary.ElapsedMs) ms." `
            -Why "This is the closest thing to what your browser does - it proves the full path works: cable/Wi-Fi, router, internet, DNS, TLS and HTTP." `
            -Meaning "Web browsing should work from this computer. If a particular site or app still fails, the problem is with that site/app, the proxy, the firewall, or cached state - not the connection." `
            -Technical "GET $($script:GNControlSites[0]) -> HTTP $($primary.StatusCode) in $($primary.ElapsedMs) ms. Proxy: $($primary.UsedProxy).$bodyNote" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($captive.Portal) {
        return New-GNResult -Id 'HTTPS' -Name 'Web (HTTPS) connectivity check' -Layer 'App' -Status 'Fail' `
            -Summary "Web requests are being redirected to a sign-in page. This looks like a captive portal (hotel, airport, cafe or guest Wi-Fi)." `
            -Why "Public Wi-Fi networks block the internet until you accept their terms on a web page." `
            -Meaning "Your connection is technically working, but the network is holding your traffic until you log in. No amount of repairing this PC will fix it - you must accept the terms." `
            -Causes @('You have not accepted the network terms on this Wi-Fi yet','The captive portal session expired','The portal page itself failed to load (try a different browser)') `
            -NextSteps @('Open a browser and try to visit any website - the sign-in page should appear, then accept it','If nothing appears, browse to http://neverssl.com or http://example.com (plain HTTP) to trigger the portal','If the portal keeps failing, ask the venue/network owner') `
            -FixClass 'Boundary' `
            -Technical "HTTPS request to $($script:GNControlSites[0]) failed ($($primary.Error)) while HTTP returned unexpected content: $($captive.Detail)" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    $errText = "$($primary.Error)"
    if ($errText -match 'Security|SSL|TLS|Trust|Certificate') {
        return New-GNResult -Id 'HTTPS' -Name 'Web (HTTPS) connectivity check' -Layer 'App' -Status 'Fail' `
            -Summary "The secure connection was rejected during the TLS/certificate handshake." `
            -Why "HTTPS requires a trusted certificate. If the certificate is intercepted or replaced, the secure channel fails." `
            -Meaning "Something between your computer and the website is interfering with encrypted traffic - typically a security product performing HTTPS inspection, or a proxy." `
            -Causes @('Antivirus/security software doing HTTPS inspection with a broken or untrusted certificate','Corporate proxy or self-signed certificate in the path','Outdated Windows root certificates or very old TLS settings','Captive portal re-signing traffic') `
            -NextSteps @('Temporarily disable HTTPS scanning in your antivirus and retest','If you are on a work network, ask IT whether HTTPS inspection is required','Install pending Windows updates (they refresh trusted certificates)','Test connecting to the same site from a phone on the same Wi-Fi to compare') `
            -FixClass 'Manual' `
            -Technical "TLS/HTTP error: $errText. Proxy in use: $($primary.UsedProxy)." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($data.UsedProxy -and $data.UsedProxy -ne 'none') {
        return New-GNResult -Id 'HTTPS' -Name 'Web (HTTPS) connectivity check' -Layer 'App' -Status 'Fail' `
            -Summary "Web requests fail while a proxy is configured ($($data.UsedProxy))." `
            -Why "A proxy sits between your computer and the internet. If it is unreachable, wrong, or blocks traffic, browsing fails even though the connection is fine." `
            -Meaning "The evidence points at the proxy configuration rather than at your Wi-Fi/router/internet connection." `
            -Causes @('Proxy set by a VPN, malware, or an old configuration and now unreachable','Corporate proxy required but not reachable from this network','Proxy settings left over from another location') `
            -NextSteps @('Disable the system proxy and re-test the HTTPS check (GeeNet can do this)','If a VPN is installed, disconnect it and re-test','If this is a work computer, get the correct proxy settings from IT') `
            -FixClass 'SafeAuto' `
            -Technical "GET $($script:GNControlSites[0]) via proxy $($data.UsedProxy) failed: $errText" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'HTTPS' -Name 'Web (HTTPS) connectivity check' -Layer 'App' -Status 'Fail' `
        -Summary "HTTPS web requests failed, even though the lower layers looked healthy." `
        -Why "This is the layer where a working connection becomes a working website. If it fails here, the problem is usually filtering, a proxy, a firewall rule, or the application." `
        -Meaning "Something between your computer and the websites is blocking or breaking web traffic. Because DNS resolved, we should not blame DNS." `
        -Causes @('Firewall or security software blocking outbound web traffic','Proxy or VPN configuration interfering','Router/ISP content filter','Application-level block (parental controls, school/office policy)','Wrong system clock causing certificate/TLS problems') `
        -NextSteps @('Check proxy settings and firewall/security software (GeeNet can show and reset proxy settings)','Test the same site from another device on the same network','If only one browser/app fails but others work, the problem is in that application','Check the Windows clock is correct (wrong time breaks secure connections)') `
        -FixClass 'Manual' `
        -Technical "GET https://www.msftconnecttest.com/connecttest.txt -> $errText. GET https://www.google.com/generate_204 -> $(if ($secondary) { $secondary.Error } else { 'not run' }). TCP 443 to 1.1.1.1: $((Test-GNTcpPort -Target '1.1.1.1' -Port 443 -TimeoutMs 2500 -NoDns).Open)" `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-GNCaptivePortalInternal {
    <#
      Detects hotel/airport style sign-in pages: plain HTTP should return the exact
      known text; a different page or a redirect means something is intercepting.
    #>
    $result = [pscustomobject]@{ Portal = $false; Detail = ''; Ran = $false }
    try {
        $probe = Request-GNHttp -Url 'http://www.msftconnecttest.com/connecttest.txt' -TimeoutSec 6 -Direct
        $result.Ran = $true
        if ($probe.Success) {
            $body = "$($probe.Content)".Trim()
            if ($body -notmatch 'Microsoft Connect Test') {
                $result.Portal = $true
                $result.Detail = "HTTP test returned unexpected content (status $($probe.StatusCode)): '" + ($body.Substring(0, [Math]::Min(80, $body.Length))) + "'"
            }
        } elseif ($probe.StatusCode -eq 302 -or $probe.StatusCode -eq 301 -or $probe.StatusCode -eq 200) {
            $result.Portal = $true
            $result.Detail = "HTTP test was redirected (status $($probe.StatusCode))"
        } else {
            $result.Detail = "HTTP probe failed: $($probe.Error)"
        }
    } catch {
        $result.Detail = "Captive portal probe error: $($_.Exception.Message)"
    }
    return $result
}

function Test-CaptivePortal {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cp = Test-GNCaptivePortalInternal
    $sw.Stop()
    if ($cp.Portal) {
        return New-GNResult -Id 'CaptivePortal' -Name 'Sign-in page (captive portal) check' -Layer 'App' -Status 'Fail' `
            -Summary "Your network is intercepting web traffic and redirecting it to a sign-in page." `
            -Why "Many public networks require you to accept terms or log in before giving you internet access." `
            -Meaning "This is not a fault on your computer - the network is deliberately holding your traffic until you sign in." `
            -Causes @('Terms not accepted yet','Session expired and needs signing in again','Portal page failing to load') `
            -NextSteps @('Open a browser and accept the terms / sign in','If no page appears, visit http://neverssl.com to force it','Then re-run this check') `
            -FixClass 'Boundary' `
            -Technical $cp.Detail -Data @{ Portal = $true; Detail = $cp.Detail } -DurationMs $sw.ElapsedMilliseconds
    }
    return New-GNResult -Id 'CaptivePortal' -Name 'Sign-in page (captive portal) check' -Layer 'App' -Status 'Pass' `
        -Summary "No sign-in page detected - the internet is not being intercepted by a portal." `
        -Why "Captive portals cause confusing 'connected but no internet' symptoms, so it is worth ruling out early." `
        -Meaning "Your traffic is going where it should; nothing is hijacking your web requests." `
        -Technical $(if ($cp.Ran) { "HTTP content test matched the expected response. $($cp.Detail)" } else { "Probe could not run: $($cp.Detail)" }) `
        -Data @{ Portal = $false; Detail = $cp.Detail } -DurationMs $sw.ElapsedMilliseconds
}

function Test-Latency {
    <#  Round trip time to the router and to the internet - the 'is it slow?' test. #>
    param([int]$Count = 8, [switch]$IncludeGateway)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $gw = Get-GNDefaultGateway
    $gwPing = $null
    if ($gw -and $IncludeGateway) { $gwPing = Invoke-GNPing -Target $gw -Count $Count -TimeoutMs 1500 }
    $netPing = Invoke-GNPing -Target '1.1.1.1' -Count $Count -TimeoutMs 1800
    $sw.Stop()

    $data = @{
        Gateway    = "$gw"
        GatewayAvg = if ($gwPing) { $gwPing.AvgMs } else { $null }
        GatewayLoss= if ($gwPing) { $gwPing.LossPercent } else { $null }
        NetAvg     = $netPing.AvgMs
        NetMin     = $netPing.MinMs
        NetMax     = $netPing.MaxMs
        NetJitter  = $netPing.JitterMs
        NetLoss    = $netPing.LossPercent
        Received   = $netPing.Received
        Sent       = $netPing.Sent
    }
    if (-not $netPing.Success) {
        return New-GNResult -Id 'Latency' -Name 'Latency (speed of delay) check' -Layer 'Transport' -Status 'Skip' `
            -Summary "The internet could not be reached, so latency could not be measured." `
            -SkipReason "Measuring delay only makes sense once the internet is reachable. Fix the reachability problem first." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    $avg = $netPing.AvgMs
    $status = 'Pass'
    $meaning = "The delay to the internet is about $avg ms, which is normal for this kind of connection."
    $causes = @()
    $steps = @()
    if ($avg -ge 150) {
        $status = 'Warn'
        $meaning = "The delay to the internet is high (about $avg ms). This is the 'everything feels slow' signal - gaming and video calls suffer first."
        $causes = @('Wi-Fi signal weak or interference heavy','ISP congestion or a long routing path','VPN adding an extra hop','Downloading/streaming running in the background','Router overloaded (many devices or a very old router)')
        $steps = @('Move closer to the router or use Ethernet for testing','Close background downloads/updates and re-test','If you use a VPN, test with it disconnected','Compare with another device on the same network to see whether it is this PC or the whole connection')
    } elseif ($avg -ge 60) {
        $status = 'Warn'
        $meaning = "Delay is moderate (about $avg ms). Fine for browsing, noticeable in video calls and gaming."
        $causes = @('Wi-Fi rather than wired connection','Distance from the router','Background traffic on the network')
        $steps = @('If you need stable video calls or gaming, prefer Ethernet','Re-test when nothing else is using the connection')
    }
    if ($netPing.JitterMs -ge 60) {
        $status = 'Warn'
        $meaning += " The delay also varies a lot (jitter $($netPing.JitterMs) ms), which is what makes video/voice stutter."
        $causes += 'Unstable link (weak Wi-Fi, interference, congested network)'
        $steps += 'Test again on a wired connection to see whether the jitter disappears'
    }

    $gwText = ''
    if ($gwPing) { $gwText = "Gateway: avg $($gwPing.AvgMs) ms with $($gwPing.LossPercent)% loss. " }
    return New-GNResult -Id 'Latency' -Name 'Latency (speed of delay) check' -Layer 'Transport' -Status $status `
        -Summary "Delay to the internet: $avg ms average (fastest $($netPing.MinMs) ms, slowest $($netPing.MaxMs) ms)." `
        -Why "Speed is not only about bandwidth. Delay (latency) decides how responsive things feel, and jitter decides whether calls and games stay smooth." `
        -Meaning $meaning -Causes $causes -NextSteps $steps `
        -FixClass $(if ($status -eq 'Warn') { 'Manual' } else { 'NotNeeded' }) `
        -Technical "$gwText Internet: $($netPing.Received)/$($netPing.Sent) replies, min $($netPing.MinMs) / avg $avg / max $($netPing.MaxMs) ms, jitter $($netPing.JitterMs) ms." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-PacketLoss {
    <#  Are packets getting lost? The usual cause of stuttering calls and dropped games. #>
    param([int]$Count = 10)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $gw = Get-GNDefaultGateway
    $gwPing = $null
    if ($gw) { $gwPing = Invoke-GNPing -Target $gw -Count $Count -TimeoutMs 1200 }
    $netPing = Invoke-GNPing -Target '1.1.1.1' -Count $Count -TimeoutMs 1500
    $sw.Stop()

    $data = @{
        Gateway        = "$gw"
        GatewayLoss    = if ($gwPing) { $gwPing.LossPercent } else { $null }
        GatewaySent    = if ($gwPing) { $gwPing.Sent } else { 0 }
        GatewayRecv    = if ($gwPing) { $gwPing.Received } else { 0 }
        NetLoss        = $netPing.LossPercent
        NetSent        = $netPing.Sent
        NetRecv        = $netPing.Received
        NetAvg         = $netPing.AvgMs
    }

    if (-not $netPing.Success -and $gwPing -and $gwPing.Success) {
        return New-GNResult -Id 'PacketLoss' -Name 'Packet loss check' -Layer 'Transport' -Status 'Skip' `
            -Summary "The internet did not answer at all, so loss percentages would be misleading." `
            -SkipReason "When the target is completely unreachable, 'loss' is not a measurement - the reachability problem must be fixed first." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    $gwLoss = if ($gwPing) { $gwPing.LossPercent } else { $null }
    $netLoss = $netPing.LossPercent
    $status = 'Pass'
    $meaning = "No meaningful packet loss was seen - $($netPing.Received) of $($netPing.Sent) test packets came back."
    $causes = @()
    $steps = @()

    if ($netLoss -ge 20) {
        $status = 'Fail'
    } elseif ($netLoss -gt 0) {
        $status = 'Warn'
    }
    if ($status -ne 'Pass') {
        $meaning = "Some test packets never came back ($netLoss% lost to the internet$(if ($gwLoss -ne $null) { ", $gwLoss% to your router" })). Lost packets are resent, which is why calls freeze, games lag out and downloads slow down or stall."
        $causes = @('Weak Wi-Fi signal or interference (very common)','Faulty or damaged Ethernet cable/port','Overloaded router or network (someone else saturating the link)','Unstable ISP line (especially on older DSL/coax/mobile links)','Power-saving settings on the network adapter') 
        $steps = @('Test on a wired connection: if loss disappears, it is Wi-Fi','Check the cables and the router ports','Test when the network is quieter (late night) to see whether it is congestion or the line itself','Run GeeNet''s stability monitor for a minute to see whether the loss is constant or in bursts','If loss happens on Ethernet too and other devices have the same problem, contact the ISP')
        if ($gwLoss -ne $null -and $gwLoss -ge 20 -and $netLoss -ge 20) {
            $meaning += " Loss already happens between this PC and the router, so the problem is inside your own network - not out on the internet."
        }
    }

    return New-GNResult -Id 'PacketLoss' -Name 'Packet loss check' -Layer 'Transport' -Status $status `
        -Summary "Packet loss to the internet: $netLoss% ($($netPing.Received)/$($netPing.Sent) replies)." `
        -Why "Resending lost data is invisible on web pages but very visible in live calls, games and remote desktop sessions." `
        -Meaning $meaning -Causes $causes -NextSteps $steps `
        -FixClass $(if ($status -eq 'Pass') { 'NotNeeded' } else { 'Manual' }) `
        -Technical "Internet 1.1.1.1: $($netPing.Received)/$($netPing.Sent) replies ($netLoss% loss, avg $($netPing.AvgMs) ms). Router $(if ($gwPing) { "$($gwPing.Received)/$($gwPing.Sent) replies ($gwLoss% loss)" } else { 'not tested' })." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-Stability {
    <#
      Stability monitor: watches the link for a while and records every interruption,
      then reports a pattern ("drops every ~40s", "link reconnects", "loss bursts").
      This is what answers 'my internet keeps disconnecting'.
    #>
    param(
        [int]$Seconds = 60,
        [int]$IntervalSeconds = 3,
        [switch]$Quiet
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $gw = Get-GNDefaultGateway
    $active = Get-GNActiveAdapter
    $startAdapter = if ($active) { "$($active.Adapter.Status)" } else { '' }
    $startSsid = ''
    try { $startSsid = (Get-GNWifiInfo).SSID } catch { }
    $events = New-Object System.Collections.Generic.List[object]
    $samples = New-Object System.Collections.Generic.List[object]
    $gwFails = 0; $netFails = 0; $rounds = 0
    $consecutiveFail = 0; $maxConsecutiveFail = 0
    $begin = Get-Date

    while (((Get-Date) - $begin).TotalSeconds -lt $Seconds) {
        $rounds++
        $t = Get-Date
        $gwOk = $null; $netOk = $null
        if ($gw) { $gwOk = (Invoke-GNPing -Target $gw -Count 1 -TimeoutMs 1200).Success }
        $netOk = (Invoke-GNPing -Target '1.1.1.1' -Count 1 -TimeoutMs 1500).Success
        if ($gwOk -eq $false) { $gwFails++ }
        if (-not $netOk) { $netFails++ }
        if (-not $netOk) { $consecutiveFail++; if ($consecutiveFail -gt $maxConsecutiveFail) { $maxConsecutiveFail = $consecutiveFail } } else { $consecutiveFail = 0 }
        [void]$samples.Add([pscustomobject]@{ Time = $t.ToString('HH:mm:ss'); GatewayOk = $gwOk; InternetOk = $netOk })

        # link flap detection
        $currAdapter = Get-GNActiveAdapter
        $currStatus = if ($currAdapter) { "$($currAdapter.Adapter.Status)" } else { 'none' }
        $currSsid = ''
        try { $currSsid = (Get-GNWifiInfo).SSID } catch { }
        if ($currStatus -ne $startAdapter -and $currStatus -ne '') {
            [void]$events.Add([pscustomobject]@{ Time = $t.ToString('HH:mm:ss'); Event = "Adapter '$($active.Adapter.Name)' changed state: $startAdapter -> $currStatus"; Type = 'Link' })
            $startAdapter = $currStatus
        }
        if ($startSsid -and $currSsid -and $currSsid -ne $startSsid) {
            [void]$events.Add([pscustomobject]@{ Time = $t.ToString('HH:mm:ss'); Event = "Wi-Fi moved from '$startSsid' to '$currSsid'"; Type = 'Link' })
            $startSsid = $currSsid
        }

        if (-not $Quiet -and $script:GNInteractive) {
            $dot = if ($netOk) { '.' } else { 'x' }
            Write-GNOut $dot -Color $(if ($netOk) { 'DarkGray' } else { 'Red' }) -NoNewline
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
    if (-not $Quiet -and $script:GNInteractive) { Write-GNOut '' }

    $sw.Stop()
    $netLossPct = if ($rounds -gt 0) { [Math]::Round((($netFails / $rounds) * 100), 0) } else { 0 }
    $gwLossPct  = if ($rounds -gt 0 -and $gw) { [Math]::Round((($gwFails / $rounds) * 100), 0) } else { 0 }
    # Materialise the collections with plain loops: piping a generic List through ForEach-Object
    # inside a hashtable literal can trip a PowerShell binder fault on some builds.
    $eventLines = New-Object System.Collections.Generic.List[string]
    foreach ($ev in $events.ToArray()) { [void]$eventLines.Add("$($ev.Time) $($ev.Event)") }
    $sampleRows = @($samples.ToArray())
    $data = @{
        Seconds        = $Seconds
        Rounds         = $rounds
        InternetFails  = $netFails
        GatewayFails   = $gwFails
        InternetLossPct= $netLossPct
        GatewayLossPct = $gwLossPct
        LongestOutage  = ($maxConsecutiveFail * $IntervalSeconds)
        Events         = @($eventLines.ToArray())
        Samples        = $sampleRows
    }
    $pattern = "Clean: no interruptions during $Seconds seconds of monitoring."
    if ($netFails -gt 0) {
        $pattern = "$($netFails) of $rounds checks failed"
        if ($maxConsecutiveFail -ge 2) { $pattern += ", with one gap lasting about $($maxConsecutiveFail * $IntervalSeconds) seconds" }
        if ($events.Count -gt 0) { $pattern += ", and $($events.Count) link change(s) observed" }
        $pattern += '.'
    }

    if ($netFails -eq 0 -and $events.Count -eq 0) {
        return New-GNResult -Id 'Stability' -Name 'Stability monitor' -Layer 'Transport' -Status 'Pass' `
            -Summary "Stable: the connection stayed up for the whole $Seconds second monitoring window." `
            -Why "Some faults only appear under load or over time, so watching the link is the only way to catch them." `
            -Meaning "No dropouts were seen while GeeNet watched. If you still experience interruptions, they may be caused by load (downloads, updates, streaming) or happen at other times of day." `
            -Technical "Samples: $rounds. Internet failures: 0. Router failures: 0. Link changes: 0." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($netFails -gt 0 -and $gwFails -gt 0 -and $gwLossPct -ge 30) {
        return New-GNResult -Id 'Stability' -Name 'Stability monitor' -Layer 'Transport' -Status 'Fail' `
            -Summary "Unstable: the connection to your own router failed in $gwLossPct% of checks during monitoring." `
            -Why "If even the router is unreachable in bursts, the problem is inside your own network - not the internet or the ISP." `
            -Meaning "$pattern Because the router itself was unreachable, look at Wi-Fi signal, the cable/port, or the adapter - the internet link may be perfectly fine." `
            -Causes @('Weak/flapping Wi-Fi signal or interference','Faulty Ethernet cable, port or dock','Router LAN side struggling (too many devices, overheating, old firmware)','Adapter power management switching the device off to save power','Duplicate IP or another device fighting for the same address') `
            -NextSteps @('Run this monitor again on a wired connection - if drops disappear it is a Wi-Fi issue','Change the Ethernet cable/port and re-test','Turn off "Allow the computer to turn off this device to save power" in the adapter properties','Restart the router, then re-test','If the router drops for everyone (including other devices), it is a router fault') `
            -FixClass 'Manual' `
            -Technical "Monitoring $Seconds s in $IntervalSeconds s steps. Router losses $gwFails/$rounds ($gwLossPct%). Internet losses $netFails/$rounds. Longest gap ~$($data.LongestOutage) s. Events: $(if ($events.Count) { ($events | ForEach-Object { $_.Event }) -join '; ' } else { 'none' })." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($netFails -gt 0 -and $gwLossPct -lt 10) {
        return New-GNResult -Id 'Stability' -Name 'Stability monitor' -Layer 'Transport' -Status 'Fail' `
            -Summary "Unstable internet: the router stayed reachable, but internet access failed in $netLossPct% of checks." `
            -Why "A reachable router with an unreachable internet is the signature of a problem upstream: your router's internet link or your ISP." `
            -Meaning "$pattern Your local network is behaving, so this is most likely the router's internet connection, the line, or the ISP." `
            -Causes @('Router internet (WAN) link dropping - line quality, cable, or an overloaded router','ISP instability in your area or an overloaded local node','Router session table exhausted by lots of connections (torrents, many devices)','Mobile/4G backup switching, or a neighbour saturating a shared link') `
            -NextSteps @('Check another device (same Wi-Fi) during a dropout - if it drops too, it is the router/ISP','Restart the router and re-test','Run the monitor again at a different time of day to see whether it is congestion','If the problem repeats for days, report it to your ISP with this report') `
            -FixClass 'Boundary' `
            -Technical "Monitoring $Seconds s. Internet losses $netFails/$rounds ($netLossPct%). Router losses $gwFails/$rounds ($gwLossPct%). Longest gap ~$($data.LongestOutage) s." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'Stability' -Name 'Stability monitor' -Layer 'Transport' -Status 'Warn' `
        -Summary "Mostly stable, with $netLossPct% of checks failing during monitoring." `
        -Why "Occasional failures are enough to break voice/video calls even if web browsing seems fine." `
        -Meaning $pattern `
        -Causes @('Wi-Fi interference or marginal signal','Background downloads/updates saturating the link','Provider-side congestion at peak times') `
        -NextSteps @('Re-run the monitor with nothing else using the connection','Test on Ethernet to see whether it is Wi-Fi related','If dropouts line up with specific times of day, that points at ISP congestion') `
        -FixClass 'Manual' `
        -Technical "Monitoring $Seconds s. Internet losses $netFails/$rounds ($netLossPct%). Router losses $gwFails/$rounds ($gwLossPct%)." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

# ------------------------------------------------------------------------------
#region 12. LAYER 2-3 TESTS: ARP / ROUTING / LOCAL NETWORK / STACK / PROXY / VPN
# ------------------------------------------------------------------------------

function Test-ARP {
    <#  Neighbour (ARP) table: proves devices are physically reachable and shows odd entries. #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $neighbors = @(Get-GNNeighbors)
    $gw = Get-GNDefaultGateway
    $gwEntry = $null
    if ($gw) { $gwEntry = $neighbors | Where-Object { "$($_.IPAddress)" -eq "$gw" } | Select-Object -First 1 }
    $incomplete = @($neighbors | Where-Object { "$($_.State)" -match 'Incomplete|Unreachable' -or "$($_.LinkLayerAddress)" -match '^(00-00-00-00-00-00|00:00:00:00:00:00)$' })
    $byMac = @($neighbors | Where-Object { "$($_.LinkLayerAddress)" -and "$($_.LinkLayerAddress)" -notmatch '^(FF-FF-FF-FF-FF-FF|ff-ff-ff-ff-ff-ff)$' } |
              Group-Object LinkLayerAddress | Where-Object { $_.Count -gt 1 })
    $sw.Stop()

    $data = @{
        Count       = $neighbors.Count
        Gateway     = "$gw"
        GatewayMac  = if ($gwEntry) { "$($gwEntry.LinkLayerAddress)" } else { '' }
        GatewayState= if ($gwEntry) { "$($gwEntry.State)" } else { 'missing' }
        Incomplete  = @($incomplete | ForEach-Object { "$($_.IPAddress)" })
        SharedMacs  = @($byMac | ForEach-Object { "$($_.Name) used by: " + (($_.Group | ForEach-Object { $_.IPAddress }) -join ', ') })
    }

    if ($gw -and -not $data.GatewayMac) {
        return New-GNResult -Id 'ARP' -Name 'Local device table (ARP/neighbour) check' -Layer 'Local' -Status 'Warn' `
            -Summary "There is no hardware (MAC) entry for your router in the local device table." `
            -Why "Your computer learns the router's hardware address the moment it talks to it. A missing entry means that conversation never succeeded." `
            -Meaning "This is consistent with the router being unreachable at the local network level. It reinforces that this is a local, not internet, fault." `
            -Causes @('Router unreachable from this computer (Wi-Fi/Ethernet/IP problem)','Computer is on a different subnet than the router','Table entry expired because nothing was sent recently') `
            -NextSteps @('Fix the local connection first (link and IP address checks)','Then re-run this check - the router''s MAC address should appear','If the router still never appears, test from another device on the same network') `
            -FixClass 'Manual' `
            -Technical "Neighbour entries: $($neighbors.Count). Gateway '$gw' has no usable MAC entry ($($data.GatewayState))." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($data.SharedMacs.Count -gt 0) {
        return New-GNResult -Id 'ARP' -Name 'Local device table (ARP/neighbour) check' -Layer 'Local' -Status 'Warn' `
            -Summary "Two different IP addresses on your network share the same hardware (MAC) address." `
            -Why "Normally each device has a unique MAC address. Sharing one is a classic sign of a duplicate-IP or rogue-device problem." `
            -Meaning "This can cause intermittent drops and 'no internet on this device only' symptoms, because replies get delivered to the wrong place." `
            -Causes @('Duplicate IP address on the network','Two virtual machines bridged onto the same network with the same MAC','A second router configured incorrectly on the same network','Guest or rogue access point answering for other devices') `
            -NextSteps @('Restart the router to clear stale entries, then recheck','If the entries return, find the device and give it a different address','On this PC, get a fresh DHCP address (GeeNet can do that)','If you cannot identify the device, treat it as a security concern and check who is on the network') `
            -FixClass 'Manual' `
            -Technical ($data.SharedMacs -join ' | ') `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($incomplete.Count -gt 2) {
        return New-GNResult -Id 'ARP' -Name 'Local device table (ARP/neighbour) check' -Layer 'Local' -Status 'Warn' `
            -Summary "Several local addresses show as incomplete or unreachable in the device table." `
            -Why "Incomplete entries mean the computer tried to reach a local device and got no hardware-address answer at all." `
            -Meaning "This suggests the local network is partly unresponsive - devices are configured to be there but do not answer. It is common alongside weak Wi-Fi or a struggling router." `
            -Causes @('Weak Wi-Fi causing unanswered ARP requests','Router or switch overloaded','Devices that have been switched off but are still in the table') `
            -NextSteps @('Re-run the check after reconnecting the network','Test with a wired connection if the PC has a port','Restart the router if many devices are affected') `
            -FixClass 'Manual' `
            -Technical "Incomplete entries: $(($data.Incomplete) -join ', ')" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'ARP' -Name 'Local device table (ARP/neighbour) check' -Layer 'Local' -Status 'Pass' `
        -Summary "Local network device table looks normal ($($neighbors.Count) entries; router MAC $(if ($data.GatewayMac) { $data.GatewayMac } else { 'n/a' }))." `
        -Why "The ARP table shows which devices on your local network the computer can actually see and talk to." `
        -Meaning "Your computer is learning local devices normally, which means the local segment is working." `
        -Technical "Entries: $($neighbors.Count). Gateway $($data.Gateway) -> $($data.GatewayMac) state $($data.GatewayState)." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-Route {
    <#  Routing table sanity: default routes, metric problems, VPN hijacking routes. #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $routes = @(Get-GNRoutes)
    $defaults = @($routes | Where-Object { "$($_.DestinationPrefix)" -eq '0.0.0.0/0' -or "$($_.DestinationPrefix)" -eq '0.0.0.0' })
    $suspicious = @($routes | Where-Object { "$($_.DestinationPrefix)" -match '^0\.0\.0\.0/(1|2|3|4|5|6|7)$' })
    $vpnRoutes = @($routes | Where-Object { "$($_.InterfaceAlias)" -match 'vpn|tap|tun|wireguard|openvpn|anyconnect|globalprotect' })
    $gwCount = @($defaults | Where-Object { "$($_.NextHop)" -and "$($_.NextHop)" -ne '0.0.0.0' } | Select-Object -ExpandProperty NextHop -Unique).Count
    $sw.Stop()

    $data = @{
        RouteCount   = $routes.Count
        DefaultCount = $defaults.Count
        GatewayCount = $gwCount
        Defaults     = @($defaults | ForEach-Object { "$($_.DestinationPrefix) via $($_.NextHop) metric $($_.RouteMetric) on $($_.InterfaceAlias)" })
        HalfRoutes   = @($suspicious | ForEach-Object { "$($_.DestinationPrefix) via $($_.NextHop)" })
        VpnRoutes    = @($vpnRoutes | ForEach-Object { "$($_.DestinationPrefix) via $($_.NextHop) ($($_.InterfaceAlias))" })
    }

    if ($defaults.Count -eq 0) {
        return New-GNResult -Id 'Route' -Name 'Routing table check' -Layer 'IP' -Status 'Fail' `
            -Summary "There is no default route in the routing table - the computer has no way out to the internet." `
            -Why "Routing is how the computer decides where to send each packet. Without a default route, everything outside your own subnet is unreachable." `
            -Meaning "This matches the missing-gateway finding: the network configuration itself is incomplete." `
            -Causes @('No gateway from DHCP (no valid IP address obtained)','Static IP configured without a gateway','Default route removed by a VPN client or a script') `
            -NextSteps @('Renew the IP address so the route is rebuilt (GeeNet can do this)','If you use a static IP, add the router as gateway','If a VPN client is installed, make sure it is disconnected properly after use') `
            -FixClass 'SafeAuto' `
            -Technical "Routes seen: $($routes.Count). No 0.0.0.0/0 entry." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($gwCount -gt 1) {
        return New-GNResult -Id 'Route' -Name 'Routing table check' -Layer 'IP' -Status 'Warn' `
            -Summary "More than one default gateway is configured ($($data.Defaults -join ' | '))." `
            -Why "With two exits, Windows picks one by metric - and if it picks the wrong one, traffic can vanish with no obvious error." `
            -Meaning "This is a classic cause of 'works sometimes, fails other times' behaviour, especially when a VPN or a second adapter (Wi-Fi + Ethernet, or a virtual adapter) is involved." `
            -Causes @('VPN or virtual adapter left connected','Both Wi-Fi and Ethernet connected at once','A virtual machine (Hyper-V/VMware/VirtualBox) network adapter with its own gateway','Leftover configuration from another network') `
            -NextSteps @('Disconnect the connection you are not using, then re-test','If it is a VPN, disconnect the VPN and confirm one default route remains','Disable unused virtual adapters in Network Connections if you do not need them') `
            -FixClass 'Manual' `
            -Technical "Default routes: $($data.Defaults -join ' | ')" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($suspicious.Count -gt 0) {
        return New-GNResult -Id 'Route' -Name 'Routing table check' -Layer 'IP' -Status 'Warn' `
            -Summary "Unusual split routes are present ($($data.HalfRoutes -join ', '))." `
            -Why "Routes like 0.0.0.0/1 override the normal default route. They are almost always created by VPN software or by malware." `
            -Meaning "Traffic may be sent through a tunnel or an unexpected path, which explains slow or failing internet while the basics look fine." `
            -Causes @('VPN client still controlling routing','Traffic-forcing tool or proxy','Malware (rarely)') `
            -NextSteps @('Disconnect any VPN, then re-run this check','If the routes remain with no VPN running, restart Windows','If they still remain, check installed proxy/VPN tools') `
            -FixClass 'Manual' `
            -Technical "Split routes: $($data.HalfRoutes -join ', '). VPN-related routes: $($data.VpnRoutes -join ', ')" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    $vpnNote = ''
    if ($vpnRoutes.Count -gt 0) { $vpnNote = " VPN-related routes present: $($data.VpnRoutes -join ', ')." }
    return New-GNResult -Id 'Route' -Name 'Routing table check' -Layer 'IP' -Status 'Pass' `
        -Summary "Routing table looks healthy: one default route via $(($defaults | Select-Object -First 1).NextHop)." `
        -Why "A clean routing table means your computer has exactly one sensible way out to the internet." `
        -Meaning "No routing conflicts were found, so problems elsewhere (DNS, HTTPS, application) are the more likely causes." `
        -Technical "Routes: $($routes.Count). Default: $(($data.Defaults) -join ' | ').$vpnNote" `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-LocalHost {
    <#  Can this computer reach another device on the LAN (server, NAS, printer, another PC)? #>
    param([string]$Target = '', [int[]]$Ports = @(445, 3389, 80, 443, 22, 9100), [int]$TimeoutMs = 2000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ([string]::IsNullOrWhiteSpace($Target)) {
        return New-GNResult -Id 'LocalHost' -Name 'Local device check' -Layer 'LocalNetwork' -Status 'Skip' `
            -Summary 'GeeNet was not given a device name, so this check was not run.' `
            -Why 'This check tests one specific device on your own network.' `
            -Meaning 'Nothing was proved either way about that device.' `
            -SkipReason 'No device name or address was available for this scenario.' `
            -FixClass 'Manual' -DurationMs $sw.ElapsedMilliseconds
    }
    $ping = Invoke-GNPing -Target $Target -Count 2 -TimeoutMs $TimeoutMs
    $openPorts = @()
    if (-not $ping.Success) {
        foreach ($p in $Ports) {
            $t = Test-GNTcpPort -Target $Target -Port $p -TimeoutMs $TimeoutMs
            if ($t.Open) { $openPorts += $p }
        }
    }
    $sw.Stop()

    $data = @{
        Target      = $Target
        PingOk      = $ping.Success
        AvgMs       = $ping.AvgMs
        ResolvedTo  = $ping.ResolvedTo
        OpenPorts   = @($openPorts)
        Reachable   = ($ping.Success -or $openPorts.Count -gt 0)
        PortsTested = @($Ports)
    }

    if ($data.Reachable) {
        $how = if ($ping.Success) { "answered ping in about $($ping.AvgMs) ms" } else { "did not answer ping but accepts connections on port(s) $(($openPorts) -join ', ')" }
        return New-GNResult -Id 'LocalHost' -Name "Local device reachability ($Target)" -Layer 'Local' -Status 'Pass' `
            -Summary "The device at $Target is reachable - it $how." `
            -Why "Being able to reach another device on your own network proves the local network (switch/router/Wi-Fi) is passing traffic." `
            -Meaning "Local network connectivity works for this device. If the application on it still fails, the issue is with that service, its firewall, or credentials - not the network path." `
            -Technical "ping $Target -> $($ping.Received)/$($ping.Sent). Open ports: $(if ($openPorts.Count) { ($openPorts -join ', ') } else { 'none tested open' })." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'LocalHost' -Name "Local device reachability ($Target)" -Layer 'Local' -Status 'Fail' `
        -Summary "The device at $Target did not answer ping and no tested service port responded." `
        -Why "If even a device on your own network is unreachable, the problem is local (network path, subnet, or that device), not the internet." `
        -Meaning "Either the device is off or unreachable, or it blocks these ports, or your computer is not on the same network as it." `
        -Causes @('The device is switched off, asleep, or disconnected','Device firewall blocking ping and the tested ports','Your computer and the device are on different subnets/VLANs','Name resolution gave the wrong address','Network isolation enabled (guest Wi-Fi, AP isolation, corporate policy)') `
        -NextSteps @('Check the device is powered on and connected','Confirm the address/hostname is correct','Try reaching a different device on the same network to see whether it is only this device','If you are on guest Wi-Fi, client isolation may deliberately block device-to-device traffic') `
        -FixClass 'Manual' `
        -Technical "ping $Target -> $($ping.Received)/$($ping.Sent) replies. Tested ports $(($Ports) -join ', '): none open." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-LocalNetwork {
    <#  General local-network health when no specific device is named. #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $gw = Get-GNDefaultGateway
    $neighbors = @(Get-GNNeighbors)
    $gwReach = $null
    if ($gw) { $gwReach = Invoke-GNPing -Target $gw -Count 2 -TimeoutMs 1200 }
    $hosts = @($neighbors | Where-Object { "$($_.LinkLayerAddress)" -and "$($_.State)" -notmatch 'Incomplete' })
    $services = @(Get-GNCriticalServices) | Where-Object { @('LanmanWorkstation','Dnscache','Dhcp') -contains $_.Name }
    $sw.Stop()

    $data = @{
        Gateway        = "$gw"
        GatewayReach   = if ($gwReach) { $gwReach.Success } else { $false }
        NeighborCount  = $neighbors.Count
        ReachablePeers = $hosts.Count
        Services       = @($services | ForEach-Object { "$($_.Name)=$($_.Status)" })
    }

    if ($gwReach -and $gwReach.Success -and $hosts.Count -ge 1) {
        return New-GNResult -Id 'LocalNetwork' -Name 'Local network (LAN) check' -Layer 'Local' -Status 'Pass' `
            -Summary "Local network is working: the router answered and $($hosts.Count) other device(s) are visible on your network." `
            -Why "A healthy local network means file sharing, printers and local servers have a working path between devices." `
            -Meaning "The LAN side is healthy, so local-only problems (shared folders, local servers, printers) are more likely to be on those devices or their permissions." `
            -Technical "Gateway $gw reachable. Neighbour entries with MAC: $($hosts.Count)." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'LocalNetwork' -Name 'Local network (LAN) check' -Layer 'Local' -Status 'Warn' `
        -Summary "The local network looks thin: router reachable = $(if ($gwReach) { $gwReach.Success } else { 'no gateway' }), visible neighbours = $($hosts.Count)." `
        -Why "If other devices are not visible, local services (shares, printers, local servers) will not work even when the internet does." `
        -Meaning "This suggests a local-network problem rather than an internet problem - or a network that isolates devices from each other (guest networks and office Wi-Fi often do)." `
        -Causes @('Client isolation / AP isolation enabled on the network','Weak Wi-Fi so neighbours are not discovered','Different subnet or VLAN from the other devices','Network discovery or file sharing switched off on this PC','All other devices are simply powered off') `
        -NextSteps @('If you are on a guest/hotel network, expect device-to-device traffic to be blocked - that is by design','On your own network, check whether other devices can see this PC','Test reaching a specific device by IP address to be sure','Check the PC you are trying to reach is switched on and on the same network') `
        -FixClass 'Manual' `
        -Technical "Gateway '$gw' reachable: $(if ($gwReach) { $gwReach.Success } else { 'not tested' }). Neighbour entries: $($neighbors.Count). Services: $($data.Services -join ', ')." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-Services {
    <#  Windows network services that quietly break connectivity when they stop. #>
    $services = @(Get-GNCriticalServices)
    $critical = @{
        'Dnscache'           = 'DNS Client - caches and resolves names'
        'Dhcp'               = 'DHCP Client - asks the router for an IP address'
        'NlaSvc'             = 'Network Location Awareness - decides your network profile'
        'netprofm'           = 'Network List Service - lists networks'
        'nsi'                = 'Network Store Interface - core network plumbing'
        'DPS'                = 'Diagnostic Policy Service - required by Windows troubleshooting'
        'WlanSvc'            = 'WLAN AutoConfig - required for Wi-Fi'
        'NcaSvc'             = 'Network Connectivity Assistant - connectivity status'
        'WinHttpAutoProxySvc'= 'WinHTTP Web Proxy Auto-Discovery - proxy detection'
    }
    $stopped = @()
    $present = @()
    foreach ($s in $services) {
        $present += "$($s.Name)=$($s.Status)"
        if ($critical.ContainsKey($s.Name) -and $s.Status -ne 'Running') {
            $stopped += [pscustomobject]@{ Name = $s.Name; Status = "$($s.Status)"; Meaning = $critical[$s.Name] }
        }
    }
    $data = @{ Stopped = $stopped; Present = $present }

    if ($stopped.Count -gt 0) {
        $list = ($stopped | ForEach-Object { "$($_.Name) ($($_.Status)) - $($_.Meaning)" }) -join '; '
        return New-GNResult -Id 'Services' -Name 'Windows network services check' -Layer 'Stack' -Status 'Fail' `
            -Summary "One or more Windows network services are not running: $list" `
            -Why "These built-in services do the behind-the-scenes work: asking for an IP address, resolving names, listing networks, and reporting connectivity to Windows." `
            -Meaning "A stopped service can produce symptoms that look like a broken network: no address, No Internet warnings, or apps that cannot resolve names." `
            -Causes @('Service stopped or disabled by an update or a tuning/optimiser tool','Service set to Disabled (not just stopped)','Service failed to start because a dependency failed') `
            -NextSteps @('GeeNet can try to start the stopped service(s) - needs Administrator rights','If a service will not start, restart Windows and check again','Check that no third-party optimiser tool disabled it') `
            -FixClass 'NeedsAdmin' `
            -Technical "Stopped: $list. All observed: $($data.Present -join ', ')." `
            -Data $data -DurationMs 0
    }

    return New-GNResult -Id 'Services' -Name 'Windows network services check' -Layer 'Stack' -Status 'Pass' `
        -Summary "All key Windows network services are running." `
        -Why "When these services run normally, Windows can obtain addresses, resolve names and report network status correctly." `
        -Meaning "You can rule out stopped-service problems; look at the network path and configuration instead." `
        -Technical "Observed: $($data.Present -join ', ')." `
        -Data $data -DurationMs 0
}

function Test-NetworkStack {
    <#  Winsock / TCP-IP stack integrity, and whether interface-level IPv4 is enabled. #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $winsock = [ordered]@{ Ok = $false; Entries = 0; Error = '' }
    try {
        $out = (Invoke-GNNative -File 'netsh' -Arguments @('winsock','show','catalog') -TimeoutSec 25)
        $text = "$($out.Output)"
        if ($text -match 'Catalog Entry ID') {
            $ids = [regex]::Matches($text, '(?m)^\s*Catalog Entry ID\s*:\s*(\d+)')
            $winsock.Entries = $ids.Count
            $winsock.Ok = $true
        } elseif ($text -match 'Unable|error|Invalid|not found') {
            $winsock.Error = (($text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' / '
        }
    } catch { $winsock.Error = $_.Exception.Message }
    $prov = @()
    try {
        if (Test-GNCommand Get-NetAdapterBinding) {
            $prov = @((Get-NetAdapterBinding -ComponentID 'ms_tcpip' -ErrorAction SilentlyContinue) | ForEach-Object { "$($_.Name)=$($_.Enabled)" })
        }
    } catch { }
    $disabledIpv4 = @($prov | Where-Object { $_ -match 'False$' })
    $sw.Stop()

    $data = @{
        WinsockOk       = $winsock.Ok
        WinsockEntries  = $winsock.Entries
        WinsockError    = $winsock.Error
        Ipv4Bindings    = $prov
        Ipv4DisabledOn  = $disabledIpv4
    }

    if ($disabledIpv4.Count -gt 0) {
        return New-GNResult -Id 'NetworkStack' -Name 'Windows network stack check' -Layer 'Stack' -Status 'Fail' `
            -Summary "IPv4 is switched off in the adapter settings for: $($disabledIpv4 -join ', ')." `
            -Why "Even with a perfect cable and router, Windows will not run IPv4 on an adapter where it is unticked in the adapter properties." `
            -Meaning "This is a Windows-side configuration problem that blocks all normal internet traffic on that adapter." `
            -Causes @('IPv4 unticked in the adapter properties','Set by a tweaking tool, malware, or a failed network reset') `
            -NextSteps @('GeeNet can try to re-enable IPv4 on the adapter (needs Administrator rights)','If that fails, open Network Connections, adapter properties, and tick Internet Protocol Version 4','Reboot and re-test') `
            -FixClass 'NeedsAdmin' `
            -Technical "ms_tcpip bindings: $($prov -join ', ')" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if (-not $winsock.Ok) {
        return New-GNResult -Id 'NetworkStack' -Name 'Windows network stack check' -Layer 'Stack' -Status 'Fail' `
            -Summary "Windows could not read its network socket catalogue, which usually means the Winsock stack is damaged." `
            -Why "The Winsock catalogue is the list of network providers Windows uses for all socket traffic. If it is unreadable or corrupted, apps fail to connect in strange ways." `
            -Meaning "This is a strong sign of a damaged network stack - common after aggressive cleaner tools, some VPN/proxy uninstalls, or malware cleanup." `
            -Causes @('Winsock corruption from a tool or uninstall that removed a Layered Service Provider badly','Leftover entries from an uninstalled VPN/proxy/firewall product','Malware damage') `
            -NextSteps @('Run a Winsock reset (GeeNet can do it with Administrator rights)','Also reset the TCP/IP stack if a Winsock reset alone does not help','Restart Windows after the reset - the change needs a reboot to take effect') `
            -FixClass 'NeedsAdmin' `
            -Technical "netsh winsock show catalog: $($winsock.Error)" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'NetworkStack' -Name 'Windows network stack check' -Layer 'Stack' -Status 'Pass' `
        -Summary "The Windows network stack looks intact ($($winsock.Entries) Winsock catalogue entries; IPv4 enabled on the adapters)." `
        -Why "A healthy stack means the fault is more likely in configuration, the network path, or an application than in Windows itself." `
        -Meaning "There is no evidence of Winsock/TCP-IP corruption, so GeeNet will not recommend a reset that would need a reboot." `
        -Technical "Winsock entries: $($winsock.Entries). IPv4 bindings: $($prov -join ', ')." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-Proxy {
    <#  Proxy configuration: a very common cause of 'connected but nothing loads'. #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cfg = Get-GNProxyConfig
    $direct = Test-GNTcpPort -Target '1.1.1.1' -Port 443 -TimeoutMs 3000 -NoDns
    $proxied = $null
    $directHttp = $null
    if ($cfg.Enabled) {
        $proxied = Request-GNHttp -Url 'http://www.msftconnecttest.com/connecttest.txt' -TimeoutSec 8
        $directHttp = Request-GNHttp -Url 'http://www.msftconnecttest.com/connecttest.txt' -TimeoutSec 8 -Direct
    }
    $sw.Stop()

    $data = @{
        Enabled     = $cfg.Enabled
        Server      = "$($cfg.Server)"
        PacUrl      = "$($cfg.PacUrl)"
        WinHttp     = "$($cfg.WinHttpProxy)"
        Sources     = @($cfg.Sources)
        DirectTcpOk = $direct.Open
        ViaProxyOk  = if ($proxied) { $proxied.Success } else { $null }
        DirectHttpOk= if ($directHttp) { $directHttp.Success } else { $null }
    }

    if (-not $cfg.Enabled) {
        return New-GNResult -Id 'Proxy' -Name 'Proxy settings check' -Layer 'App' -Status 'Pass' `
            -Summary "No proxy is configured - this computer connects to the internet directly." `
            -Why "A proxy is an extra middle computer for web traffic. A wrong or dead proxy breaks browsing while everything else looks fine." `
            -Meaning "Proxy-based failures can be ruled out, so any remaining web problem lies elsewhere (firewall, DNS, application, the site itself)." `
            -Technical "WinINET proxy disabled, no PAC file, WinHTTP: '$($cfg.WinHttpProxy)'." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($data.DirectTcpOk -and $data.ViaProxyOk -eq $false -and $data.DirectHttpOk) {
        return New-GNResult -Id 'Proxy' -Name 'Proxy settings check' -Layer 'App' -Status 'Fail' `
            -Summary "A proxy is configured ($($data.Server)$($data.PacUrl)) and web traffic fails through it, but works when sent directly." `
            -Why "This comparison isolates the proxy: same connection, same site, different results depending on the route used." `
            -Meaning "The internet connection is fine. The proxy setting is what is breaking web access on this computer." `
            -Causes @('Proxy left over from another network or from an uninstalled VPN/security product','Malware or adware that set a proxy to intercept traffic','PAC file URL that is unreachable','Corporate proxy that is not accessible from this location') `
            -NextSteps @('Disable the proxy settings on this computer (GeeNet can do that)','Reset the WinHTTP proxy configuration as well','Restart the browser afterwards','If this is a work PC, ask IT for the correct proxy address instead of removing it') `
            -FixClass 'SafeAuto' `
            -Technical "Proxy: '$($data.Server)' PAC '$($data.PacUrl)' WinHTTP '$($data.WinHttp)' (sources: $(($data.Sources) -join ', ')). Direct TCP 443 to 1.1.1.1: connected. Through proxy: failed. Direct HTTP: succeeded." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'Proxy' -Name 'Proxy settings check' -Layer 'App' -Status 'Warn' `
        -Summary "A proxy is configured ($($data.Server)$($data.PacUrl)). Web traffic through it $(if ($data.ViaProxyOk) { 'worked in this test' } else { 'did not answer as expected' })." `
        -Why "Proxy settings silently affect browsers, Windows Update and many applications but not all of them - which makes symptoms look random." `
        -Meaning "Having a proxy set is not automatically wrong, but if you are not on a network that requires one, it should normally be off." `
        -Causes @('Proxy required by a workplace network','Proxy left behind by a VPN/security tool','PAC file auto-configuration from an old location') `
        -NextSteps @('If you do not recognise this proxy, disable it (GeeNet can do it)','If you do need it, confirm the address with whoever manages your network','Retest your original problem afterwards') `
        -FixClass 'SafeAuto' `
        -Technical "WinINET proxy '$($data.Server)', PAC '$($data.PacUrl)', WinHTTP '$($data.WinHttp)'. Sources: $(($data.Sources) -join ', ')." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-VPN {
    <#  Is a VPN installed/connected, and is it interfering with normal traffic? #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $vpn = Get-GNVpnInfo
    $adapters = @(Get-GNAdapters)
    $vpnUp = @($adapters | Where-Object { $_.IsVirtual -and $_.Status -eq 'Up' -and ("$($_.Name) $($_.Description)" -match 'vpn|tap|tun|wireguard|openvpn|anyconnect|globalprotect|forticlient|zerotier|tailscale|ipsec|l2tp|pptp|sstp') })
    $routes = @(Get-GNRoutes)
    $defaults = @($routes | Where-Object { "$($_.DestinationPrefix)" -eq '0.0.0.0/0' })
    $gw = Get-GNDefaultGateway
    $gwPing = $null
    if ($gw) { $gwPing = Invoke-GNPing -Target $gw -Count 2 -TimeoutMs 1200 }
    $netPing = Invoke-GNPing -Target '1.1.1.1' -Count 2 -TimeoutMs 1500
    $sw.Stop()

    $data = @{
        VpnAdapters       = @($vpn.Adapters)
        VpnConnections    = @($vpn.Connections)
        VpnClients        = @($vpn.Clients)
        VpnActiveAdapters = @($vpnUp | ForEach-Object { "$($_.Name) [$($_.Status)]" })
        VpnRoutes         = @($vpn.ActiveRoutes)
        DefaultRoutes     = @($defaults | ForEach-Object { "$($_.DestinationPrefix) via $($_.NextHop) metric $($_.RouteMetric) on $($_.InterfaceAlias)" })
        GatewayReach      = if ($gwPing) { $gwPing.Success } else { $false }
        InternetReach     = $netPing.Success
        AnyVpn            = (($vpn.Adapters.Count + $vpn.Connections.Count + $vpnUp.Count) -gt 0)
        VpnTunnelUp       = ($vpnUp.Count -gt 0)
    }

    if (-not $data.AnyVpn) {
        return New-GNResult -Id 'VPN' -Name 'VPN / tunnel check' -Layer 'App' -Status 'Info' `
            -Summary "No VPN software or tunnel adapter was detected on this computer." `
            -Why "VPNs are one of the most common causes of 'internet stopped working' because they change routing and DNS." `
            -Meaning "VPN-related causes can be ruled out for this problem." `
            -Technical "No VPN adapters, tunnel adapters in use, or VPN connections found." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($data.VpnTunnelUp -and -not $netPing.Success -and $data.GatewayReach) {
        return New-GNResult -Id 'VPN' -Name 'VPN / tunnel check' -Layer 'App' -Status 'Fail' `
            -Summary "A VPN/tunnel adapter is connected ($($data.VpnActiveAdapters -join ', ')) and the internet is unreachable while the local network still works." `
            -Why "When a VPN is active it becomes your route to the internet. If the tunnel is half-broken, traffic enters it and never comes out." `
            -Meaning "The evidence points at the VPN connection rather than at your Wi-Fi, router or ISP: the local network is fine, and traffic only fails once it enters the tunnel." `
            -Causes @('VPN session dropped or half-connected (adapter still up)','VPN server unreachable or blocking traffic','VPN client software misconfigured after an update','DNS being sent into the tunnel and failing') `
            -NextSteps @('Disconnect the VPN completely, then re-test the internet','If the internet returns, reconnect the VPN and re-test','If it fails again, the VPN software or server is the fault - try another VPN server or update the client','If disconnecting does not remove the tunnel adapter, restart Windows') `
            -FixClass 'Manual' `
            -Technical "Tunnel adapters: $($data.VpnActiveAdapters -join ', '). Default routes: $($data.DefaultRoutes -join ' | '). Gateway reachable: $($data.GatewayReach). Internet: $($data.InternetReach). VPN routes: $($data.VpnRoutes -join ', ')" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($data.VpnTunnelUp -and $netPing.Success) {
        return New-GNResult -Id 'VPN' -Name 'VPN / tunnel check' -Layer 'App' -Status 'Warn' `
            -Summary "A VPN/tunnel adapter is connected ($($data.VpnActiveAdapters -join ', ')). The internet is currently reachable through it." `
            -Why "Traffic through a VPN takes a longer path, so it is often slower - and it changes which DNS servers you use." `
            -Meaning "A VPN is active and not blocking traffic right now, but it may explain slowness, unusual DNS results, or apps that refuse to connect." `
            -Causes @('VPN routing all traffic through a distant server (slower, higher latency)','VPN-provided DNS servers failing for some sites','Split-tunnel configuration sending only some traffic through the VPN') `
            -NextSteps @('Compare with the VPN disconnected - if the problem disappears, the VPN is the cause','Try a VPN server closer to you','If only some apps fail, check whether they are excluded or blocked by the VPN policy') `
            -FixClass 'Manual' `
            -Technical "VPN adapters up: $($data.VpnActiveAdapters -join ', '). VPN routes: $($data.VpnRoutes -join ', ')" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    $installed = @($data.VpnConnections + $data.VpnClients) | Select-Object -First 3
    return New-GNResult -Id 'VPN' -Name 'VPN / tunnel check' -Layer 'App' -Status 'Info' `
        -Summary "VPN software is installed ($($installed -join ', ')) but no tunnel is currently active." `
        -Why "Installed VPN clients can still change DNS, proxy or routing settings even when they appear disconnected." `
        -Meaning "If your problem started around the time you installed or updated a VPN, the leftover configuration is worth checking." `
        -NextSteps @('If the problem started after installing a VPN, test with the VPN fully disconnected or uninstalled temporarily','Check the Proxy and Routing checks for leftovers','Re-run this check after connecting/disconnecting the VPN to compare') `
        -FixClass 'Manual' `
        -Technical "Installed: $($data.VpnConnections -join '; ') $($data.VpnClients -join '; '). No active tunnel adapter." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-Firewall {
    <#  Firewall state + third-party security products that filter traffic. #>
    $fw = Get-GNFirewallState
    $data = @{
        Available        = $fw.Available
        EnabledProfiles  = @($fw.EnabledProfiles)
        DisabledProfiles = @($fw.DisabledProfiles)
        SecurityProducts = @($fw.ThirdParty)
    }
    if ($fw.DisabledProfiles.Count -gt 0) {
        return New-GNResult -Id 'Firewall' -Name 'Firewall / security filtering check' -Layer 'App' -Status 'Warn' `
            -Summary "The Windows firewall is switched OFF for: $($fw.DisabledProfiles -join ', ')." `
            -Why "A disabled firewall is a security risk and can also indicate that something else (or someone) changed your protection settings." `
            -Meaning "A disabled firewall itself does not usually cause 'no internet', but security software changes often come together with network configuration changes, so it is worth noting." `
            -Causes @('Third-party security suite disabled the Windows firewall in favour of its own','Someone turned it off manually','Leftover state after a security tool was uninstalled') `
            -NextSteps @('Turn the Windows firewall back on for the profiles listed (Windows Security > Firewall and network protection)','If a third-party suite is installed, make sure exactly one firewall is active','Re-test your original problem afterwards') `
            -FixClass 'Manual' `
            -Technical "Enabled: $(($data.EnabledProfiles) -join ', '). Disabled: $($data.DisabledProfiles -join ', '). Security products: $($data.SecurityProducts -join ', ')" `
            -Data $data -DurationMs 0
    }

    $secText = if ($data.SecurityProducts.Count -gt 0) { " Security products detected: $($data.SecurityProducts -join ', ')." } else { '' }
    return New-GNResult -Id 'Firewall' -Name 'Firewall / security filtering check' -Layer 'App' -Status 'Pass' `
        -Summary "Windows firewall is enabled for all profiles ($($fw.EnabledProfiles -join ', ')).$secText" `
        -Why "Firewalls can block traffic, so it helps to know whether one is active before blaming a website or an app." `
        -Meaning "The firewall is in its normal state. If web traffic fails while DNS and TCP work, security software is still worth a quick test - especially HTTPS inspection." `
        -Technical "Enabled profiles: $($fw.EnabledProfiles -join ', '). Security products: $(($data.SecurityProducts) -join ', ')" `
        -Data $data -DurationMs 0
}

function Test-HostsFile {
    <#  The hosts file can silently break one site (or many) with a bad entry. #>
    $entries = @(Get-GNHostsFileEntries)
    # Default Windows lines such as "127.0.0.1 localhost" are normal and must not be reported
    # as a fault. Only overrides that point a real hostname somewhere else, or block known
    # domains, are treated as suspicious.
    $benign = @('localhost', 'localhost.localdomain', 'local', 'broadcasthost', 'ip6-localhost', 'ip6-loopback', 'wpad', 'wpad.localdomain')
    $suspicious = @($entries | Where-Object {
        $line = "$_".Trim()
        if (-not $line) { return $false }
        $parts = @($line -split '\s+' | Where-Object { $_ -and $_ -notlike '#' })
        if ($parts.Count -lt 2) { return $false }
        $names = @($parts[1..($parts.Count - 1)] | Where-Object { $_ -notlike '#' })
        $allBenign = $true
        foreach ($n in $names) { if ($benign -notcontains $n.ToLower()) { $allBenign = $false } }
        if ($allBenign) { return $false }
        if ($line -match '^(0\.0\.0\.0|127\.0\.0\.1|::1)\s') { return $true }
        if ($line -match 'facebook|instagram|whatsapp|ads|tracker|doubleclick') { return $true }
        return $false
    })
    $sysRoot = if ($env:SystemRoot) { "$env:SystemRoot" } else { 'C:\Windows' }
    $file = $sysRoot.TrimEnd('\') + '\System32\drivers\etc\hosts'
    $data = @{ Path = $file; Count = $entries.Count; Entries = @($entries); Suspicious = @($suspicious) }

    if ($suspicious.Count -gt 0) {
        return New-GNResult -Id 'HostsFile' -Name 'Hosts file check' -Layer 'App' -Status 'Warn' `
            -Summary "Your hosts file contains $($suspicious.Count) entr(y/ies) that override or block websites." `
            -Why "The hosts file is a local override list: it can send a domain name somewhere else, or block it completely, without the router or DNS being involved at all." `
            -Meaning "This can cause exactly the 'only one website does not work' problem - or block ads/social sites on purpose. It is often left behind by ad-blockers, parental-control tools, or malware." `
            -Causes @('Ad-blocking or anti-malware tool writing entries (intentional)','Leftover entries from an uninstalled tool','Malware redirecting or blocking sites') `
            -NextSteps @('Open C:\Windows\System32\drivers\etc\hosts in Notepad as Administrator and review the entries','Remove the lines you did not add yourself (keep the comments and the default lines)','Save the file and re-test the site','If entries reappear on their own, run a malware scan') `
            -FixClass 'Manual' `
            -Technical "Entries: $(($suspicious) -join ' | ')" `
            -Data $data -DurationMs 0
    }

    return New-GNResult -Id 'HostsFile' -Name 'Hosts file check' -Layer 'App' -Status 'Pass' `
        -Summary "Hosts file is clean (no third-party overrides)." `
        -Why "A bad hosts entry can make one specific website fail while everything else works - a very confusing symptom." `
        -Meaning "Local name overrides can be ruled out as the reason a site or app is failing." `
        -Technical "File: $file. Active entries: $($entries.Count)." `
        -Data $data -DurationMs 0
}

function Test-MTU {
    <#  Path MTU test: oversized packets break logins, VPNs and some sites. #>
    param([int]$StartSize = 1472)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $gw = Get-GNDefaultGateway
    $target = if ($gw) { $gw } else { '1.1.1.1' }
    $probe = Invoke-GNPing -Target $target -Count 1 -TimeoutMs 1500 -BufferSize $StartSize -DontFragment
    $mtu = $null
    if ($probe.Success) {
        $mtu = $StartSize + 28
    } else {
        $low = 500; $high = $StartSize; $found = $null
        for ($i = 0; $i -lt 8 -and ($high - $low) -gt 8; $i++) {
            $mid = [int](($low + $high) / 2)
            $r = Invoke-GNPing -Target $target -Count 1 -TimeoutMs 1500 -BufferSize $mid -DontFragment
            if ($r.Success) { $low = $mid; $found = $mid } else { $high = $mid }
        }
        if ($found) { $mtu = $found + 28 }
    }
    $sw.Stop()
    $data = @{ Target = $target; Mtu = $mtu; TestedSize = $StartSize; Fragmented = (-not $probe.Success) }

    if ($mtu -eq $null) {
        return New-GNResult -Id 'MTU' -Name 'Packet size (MTU) check' -Layer 'Transport' -Status 'Skip' `
            -Summary "Could not determine the usable packet size - the target did not answer the size probe." `
            -SkipReason "MTU testing needs the target to answer ping. If the network blocks ping, this test cannot give a reliable answer - which is fine, because MTU problems are less common than the other causes on this list." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($mtu -lt 1400) {
        return New-GNResult -Id 'MTU' -Name 'Packet size (MTU) check' -Layer 'Transport' -Status 'Warn' `
            -Summary "The largest usable packet size is only $mtu bytes (normal Ethernet is 1500)." `
            -Why "If packets are bigger than the path allows, they get dropped or fragmented, which makes some websites, logins and VPNs fail while others work fine." `
            -Meaning "There is an MTU problem on the path, typical of VPN tunnels, PPPoE, or a router with a wrong MTU setting." `
            -Causes @('VPN tunnel (WireGuard/OpenVPN/IPsec) reducing the usable size, often needing MSS clamping','PPPoE DSL connections (1492)','Router MTU set incorrectly','ISP equipment with a smaller MTU') `
            -NextSteps @('If you use a VPN, this is normal to a degree - but the VPN should handle it. Try another server or update the client','For DSL/PPPoE, set the router MTU to 1492','If the problem is a specific website timing out on large pages, note it in the report for your ISP') `
            -FixClass 'Manual' `
            -Technical "Path MTU to $target is about $mtu bytes (DF probe at $StartSize failed)." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'MTU' -Name 'Packet size (MTU) check' -Layer 'Transport' -Status 'Pass' `
        -Summary "Packet size is normal (path MTU about $mtu bytes)." `
        -Why "Correct packet size rules out a whole class of confusing 'some sites will not load' failures." `
        -Meaning "No fragmentation problem was found on the path to $(if ($gw) { 'your router' } else { 'the internet' })." `
        -Technical "Path MTU to $target is about $mtu bytes. Tested with the DF flag at $StartSize bytes." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

# ------------------------------------------------------------------------------
#region 13. APPLICATION / WEBSITE SPECIFIC TESTS
# ------------------------------------------------------------------------------

$script:GNAppProfiles = @(
    @{ Key='teams';     Name='Microsoft Teams';       Host='teams.microsoft.com';     Port=443;  Note='Teams also uses UDP 3478-3481 for calls - if chat works but calls fail, that is a UDP problem.' }
    @{ Key='zoom';      Name='Zoom';                  Host='zoom.us';                 Port=443;  Note='Zoom meetings use UDP 8801-8810. If login works but meetings fail, the UDP path is blocked.' }
    @{ Key='discord';   Name='Discord';               Host='discord.com';             Port=443;  Note='Voice needs UDP; text chat and voice often fail separately.' }
    @{ Key='m365';      Name='Outlook / Microsoft 365'; Host='outlook.office365.com'; Port=443;  Note='If Outlook fails but webmail works, check the mail client profile.' }
    @{ Key='gmail';     Name='Gmail / Google Workspace'; Host='mail.google.com';      Port=443;  Note='Google services use many ports; port 443 is the main one.' }
    @{ Key='github';    Name='GitHub / Git over HTTPS'; Host='github.com';            Port=443;  Note='Git over SSH uses port 22 - if HTTPS works but git push fails, port 22 is probably blocked.' }
    @{ Key='githubssh'; Name='GitHub over SSH (port 22)'; Host='github.com';         Port=22;   Note='Many networks and ISPs block port 22.' }
    @{ Key='steam';     Name='Steam';                 Host='store.steampowered.com';  Port=443;  Note='Steam downloads also use ports 27015-27050; the launcher login uses 443.' }
    @{ Key='epic';      Name='Epic Games';            Host='www.epicgames.com';       Port=443;  Note='The Epic launcher also uses ports 80, 443, 5222 and 3478.' }
    @{ Key='gaming';    Name='Games (Xbox / PSN style services)'; Host='www.xbox.com'; Port=443; Note='Multiplayer needs UDP ports 3074 and 3478-3480 open in the router/firewall.' }
    @{ Key='whatsapp';  Name='WhatsApp Desktop';      Host='web.whatsapp.com';        Port=443;  Note='WhatsApp Desktop mirrors the web app on port 443.' }
    @{ Key='dropbox';   Name='Dropbox / file sync';   Host='www.dropbox.com';         Port=443;  Note='If sync fails but browsing works, the sync client may be blocked or signed out.' }
    @{ Key='office';    Name='Office 365 login';      Host='login.microsoftonline.com'; Port=443; Note='Sign-in services are often blocked separately by filters and proxies.' }
)

function Test-ApplicationConnectivity {
    <#
      Application-specific check: DNS + TCP + HTTPS for one service, compared against a control
      connection - so GeeNet can say 'this service specifically fails' instead of guessing.
    #>
    param(
        [string]$ProfileKey = '',
        # NOTE: not named $Host - that name is an automatic PowerShell variable and
        # assigning to it fails ("Cannot overwrite variable Host"). The alias keeps
        # callers that splat @{ Host = ... } working.
        [Alias('Host')][string]$HostName = '',
        [int]$Port = 443,
        [int]$TimeoutMs = 4000,
        [string]$Label = ''
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $profile = $null
    if ($ProfileKey) { $profile = $script:GNAppProfiles | Where-Object { $_.Key -eq $ProfileKey } | Select-Object -First 1 }
    if ($profile) { $HostName = $profile.Host; $Port = $profile.Port }
    if (-not $HostName) { $HostName = 'www.google.com' }
    $label = if ($Label) { $Label } elseif ($profile) { $profile.Name } else { $HostName }

    $dns = Invoke-GNDnsQuery -Name $HostName -TimeoutSec 6
    $tcp = Test-GNTcpPort -Target $HostName -Port $Port -TimeoutMs $TimeoutMs
    $httpCheck = $null
    if ($Port -eq 443 -and $tcp.Open) { $httpCheck = Request-GNHttp -Url "https://$HostName/" -TimeoutSec 8 }
    $controlTcp = Test-GNTcpPort -Target '1.1.1.1' -Port 443 -TimeoutMs $TimeoutMs -NoDns
    $sw.Stop()

    $data = @{
        Profile    = $label
        Host       = $HostName
        Port       = $Port
        DnsOk      = $dns.Success
        DnsAddress = ($dns.Addresses | Select-Object -First 1)
        TcpOpen    = $tcp.Open
        HttpOk     = if ($httpCheck) { $httpCheck.Success } else { $null }
        HttpCode   = if ($httpCheck) { $httpCheck.StatusCode } else { $null }
        ControlOk  = $controlTcp.Open
        Note       = if ($profile) { $profile.Note } else { '' }
    }

    if ($tcp.Open -and ($httpCheck -eq $null -or $httpCheck.Success)) {
        $resultNote = if ($httpCheck -and $httpCheck.StatusCode) { "HTTP $($httpCheck.StatusCode)" } else { "port $Port open" }
        return New-GNResult -Id 'AppConnect' -Name "Application check: $label" -Layer 'App' -Status 'Pass' `
            -Summary "$label looks reachable from this computer ($resultNote)." `
            -Why "Checking the service's own host and port tells us whether the block is at the network level or inside the application itself." `
            -Meaning "The network path to this service works. If the app still fails, the problem is inside the application or your account: sign-in, cache, an outdated version, or a local firewall rule for that app." `
            -Causes @('Application needs updating or is stuck on an old session','Corrupted app cache or saved credentials','Local firewall rule blocking that specific app','Server-side issue with the service itself') `
            -NextSteps @('Close and reopen the application, or sign out and back in','Clear the application cache, or repair/reinstall it if the problem continues','Check whether the service itself has an outage (status page or social media)','If other devices on this network work fine, the fault is in this installation') `
            -FixClass 'Manual' `
            -Technical "$label : DNS $(if ($dns.Success) { 'ok (' + $data.DnsAddress + ')' } else { 'failed' }), TCP ${HostName}:$Port $(if ($tcp.Open) { 'open in ' + $tcp.ElapsedMs + ' ms' } else { 'failed' })$(if ($httpCheck) { ", HTTPS status $($httpCheck.StatusCode)" }). Control 1.1.1.1:443 $(if ($controlTcp.Open) { 'open' } else { 'blocked' }). $(if ($profile) { $profile.Note })" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if (-not $data.ControlOk) {
        return New-GNResult -Id 'AppConnect' -Name "Application check: $label" -Layer 'App' -Status 'Skip' `
            -Summary "The internet itself is not reachable, so we cannot tell whether $label specifically is blocked." `
            -SkipReason "When the whole internet is unreachable, per-application results are not meaningful. Fix the connection first, then retest the application." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if (-not $dns.Success) {
        return New-GNResult -Id 'AppConnect' -Name "Application check: $label" -Layer 'App' -Status 'Fail' `
            -Summary "The name $HostName could not be resolved, so $label cannot be reached even though the internet works." `
            -Why "Applications still need DNS. If other names resolve but this one does not, the problem is specific to this name." `
            -Meaning "Either this service's name resolution is failing (DNS filtering, a hosts file entry, or the service's own DNS records) or the name is being blocked deliberately." `
            -Causes @('DNS filter / parental control / school or office policy blocking this service','Hosts file entry blocking or redirecting this name','VPN DNS failing for this domain','The service itself is having DNS problems') `
            -NextSteps @('Check the hosts file result for this name','Try the app on another device on the same network - if it also fails, it is name-level blocking rather than this PC','If you use a VPN or filtering tool, test with it switched off','Try a different DNS server to confirm (GeeNet can set public DNS)') `
            -FixClass 'Manual' `
            -Technical "DNS for $HostName failed: $($dns.Error). Control internet TCP 443: open." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'AppConnect' -Name "Application check: $label" -Layer 'App' -Status 'Fail' `
        -Summary "$label specifically is not reachable: the name resolves to $($data.DnsAddress) but port $Port did not accept a connection." `
        -Why "Comparing this service with a control connection separates 'this service is blocked' from 'the whole connection is broken'." `
        -Meaning "Your internet works and this one service does not. That points at port blocking, the app's own network path, or the provider side - not at your home connection." `
        -Causes @('Port blocked by firewall, router, ISP or the office network','VPN/proxy sending this service the wrong way','The service itself is down or blocking your region/IP address','An application-specific firewall rule') `
        -NextSteps @('Try the service from another network (a phone hotspot) to see whether it is network-level blocking','If it works on the hotspot but not at home, your router or ISP is filtering that port or service','Check your firewall rules for that application','Check whether the service is down (status page)') `
        -FixClass 'Manual' `
        -Technical "$label : DNS ok ($($data.DnsAddress)), TCP ${HostName}:$Port failed ($($tcp.Error)). Control 1.1.1.1:443 connected in $($controlTcp.ElapsedMs) ms. $(if ($profile) { $profile.Note })" `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-Website {
    <#  'Only one website does not work' - checks that specific name end to end. #>
    param([string]$Domain = '')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ([string]::IsNullOrWhiteSpace($Domain)) {
        # Never let a missing parameter turn into an interactive prompt in the middle of a diagnosis.
        return New-GNResult -Id 'Website' -Name 'Specific website check' -Layer 'Application' -Status 'Skip' `
            -Summary 'GeeNet was not given a website name, so this check was not run.' `
            -Why 'This check tests one specific website end to end.' `
            -Meaning 'Nothing was proved either way about that website.' `
            -SkipReason 'No website name was available for this scenario.' `
            -FixClass 'Manual' -DurationMs $sw.ElapsedMilliseconds
    }
    $domain = $Domain.Trim().ToLower()
    $domain = $domain -replace '^https?://', ''
    $domain = $domain -replace '/.*$', ''
    $dnsHere = Invoke-GNDnsQuery -Name $domain -TimeoutSec 6
    $dnsPublic = Invoke-GNDnsQuery -Name $domain -Server '1.1.1.1' -TimeoutSec 6
    $tcp1 = Test-GNTcpPort -Target $domain -Port 443 -TimeoutMs 5000
    $https = $null
    if ($tcp1.Open) { $https = Request-GNHttp -Url "https://$domain/" -TimeoutSec 10 }
    $hostsEntries = @(Get-GNHostsFileEntries | Where-Object { $_ -match [regex]::Escape($domain) })
    $controlDns = Invoke-GNDnsQuery -Name 'www.google.com' -TimeoutSec 5
    $sw.Stop()

    $data = @{
        Domain       = $domain
        DnsOk        = $dnsHere.Success
        DnsAddress   = ($dnsHere.Addresses | Select-Object -First 1)
        DnsPublicOk  = $dnsPublic.Success
        TcpOpen      = $tcp1.Open
        HttpOk       = if ($https) { $https.Success } else { $null }
        HttpCode     = if ($https) { $https.StatusCode } else { $null }
        HostsEntries = @($hostsEntries)
        ControlDnsOk = $controlDns.Success
    }

    if (-not $data.ControlDnsOk) {
        return New-GNResult -Id 'Website' -Name "Website check: $domain" -Layer 'App' -Status 'Skip' `
            -Summary "General DNS is failing on this computer, so a site-specific result would be misleading." `
            -SkipReason "Fix the general DNS problem first. After that, if this one website still fails, it is genuinely site-specific." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($hostsEntries.Count -gt 0) {
        return New-GNResult -Id 'Website' -Name "Website check: $domain" -Layer 'App' -Status 'Fail' `
            -Summary "Your hosts file contains an entry for $domain, which overrides the real address." `
            -Why "The hosts file takes priority over DNS, so a stale entry hijacks this specific site." `
            -Meaning "This is almost certainly why only this website fails: this computer is being told to go somewhere else, or nowhere at all." `
            -Causes @('Ad-blocker or parental-control tool','Leftover entry from an uninstalled tool','Malware redirect') `
            -NextSteps @("Open C:\Windows\System32\drivers\etc\hosts as Administrator and remove the line(s) containing $domain",'Save the file, then re-test the website','If the entries return on their own, run a malware scan') `
            -FixClass 'Manual' `
            -Technical "Hosts entries: $(($hostsEntries) -join ' | ')" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if (-not $dnsHere.Success -and $dnsPublic.Success) {
        return New-GNResult -Id 'Website' -Name "Website check: $domain" -Layer 'App' -Status 'Fail' `
            -Summary "Your computer cannot look up $domain, but a public DNS server can - so this name is being blocked or filtered for you." `
            -Why "If one resolver cannot see a name that another resolver resolves perfectly, filtering or a broken forwarder is involved." `
            -Meaning "This is name-level blocking that is specific to this site, not a general connection problem." `
            -Causes @('Router or ISP DNS filtering (parental control, safe browsing)','School or office DNS policy','Security software with web filtering','A stale local DNS cache entry for this name') `
            -NextSteps @('Clear the DNS cache and retest (GeeNet can do it)','Switch this computer to a public DNS server to test (GeeNet can do it)','If a public DNS server fixes it, the filtering is in your router or ISP DNS','If you need the site for work, ask the network administrator') `
            -FixClass 'SafeAuto' `
            -Technical "Local resolvers failed for $domain ($($dnsHere.Error)). Public resolver 1.1.1.1 succeeded ($($dnsPublic.Addresses -join ', '))." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if (-not $dnsHere.Success -and -not $dnsPublic.Success) {
        return New-GNResult -Id 'Website' -Name "Website check: $domain" -Layer 'App' -Status 'Warn' `
            -Summary "The name $domain does not resolve anywhere - not even through a public DNS server." `
            -Why "If no resolver anywhere can find the name, the name itself may not exist or may be having a worldwide problem." `
            -Meaning "This is very unlikely to be a fault on your computer. Check the spelling of the address, and check whether the site is down for everyone." `
            -Causes @('Typing error in the website address','The site or its DNS provider is down','The domain has expired or been suspended') `
            -NextSteps @('Double-check the spelling of the website address','Try the same site from your phone (on mobile data) to see whether it works anywhere','If it fails everywhere, the site itself is the problem - nothing on this PC will fix it') `
            -FixClass 'Boundary' `
            -Technical "$domain fails on both the local resolver and 1.1.1.1." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if (-not $tcp1.Open) {
        return New-GNResult -Id 'Website' -Name "Website check: $domain" -Layer 'App' -Status 'Fail' `
            -Summary "The name resolves ($($data.DnsAddress)) but the secure port 443 never answers." `
            -Why "A site can resolve and still refuse connections - that is a server-side or filtering problem rather than a connection problem." `
            -Meaning "Your internet works and the name resolves; the site itself is not accepting connections from you." `
            -Causes @('The site is down or overloaded','The site, or a filter, is blocking your region/network','Port 443 blocked for that host by a firewall or proxy','The service blocks the address range you are on') `
            -NextSteps @('Try the site from another network (phone hotspot) to see whether your network is being blocked','Try a different browser to rule out browser state','Check whether the site is down for everyone','If it fails everywhere, it is the site''s problem') `
            -FixClass 'Boundary' `
            -Technical "DNS ok ($($data.DnsAddress)). TCP ${domain}:443 failed: $($tcp1.Error)" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    $codeText = if ($https.StatusCode) { "HTTP $($https.StatusCode)" } else { 'no HTTP status' }
    return New-GNResult -Id 'Website' -Name "Website check: $domain" -Layer 'App' -Status 'Warn' `
        -Summary "The site is reachable at the network level ($codeText) but the web request did not complete as expected." `
        -Why "This separates 'cannot reach the server' from 'the server answered with something unexpected' - two very different problems." `
        -Meaning "The site may be returning an error page, requiring a login, or blocking your browser session. Your connection itself is working." `
        -Causes @('The site returned an error or a login/consent page','Browser cache, cookies or extensions interfering','Time or date wrong on this PC (breaks secure sessions)','The site blocks your region') `
        -NextSteps @('Try the site in a private/incognito window','Clear the browser cache and cookies for that site','Check the date and time on this PC are correct','Try another browser or device') `
        -FixClass 'Manual' `
        -Technical "GET https://$domain/ -> $($https.Error) $(if ($https.StatusCode) { "(HTTP $($https.StatusCode))" })" `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-OutageScope {
    <#
      Boundary test: does the problem affect other devices too? This single question decides
      'client-side' versus 'router/ISP-side' reasoning.
    #>
    param([ValidateSet('ThisPcOnly','OtherDevicesToo','NotSure')][string]$Answer = 'NotSure')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $gw = Get-GNDefaultGateway
    $gwReach = $null
    if ($gw) { $gwReach = Invoke-GNPing -Target $gw -Count 2 -TimeoutMs 1200 }
    $netReach = Invoke-GNPing -Target '1.1.1.1' -Count 2 -TimeoutMs 1500
    $sw.Stop()

    $data = @{
        Answer           = $Answer
        Gateway          = "$gw"
        GatewayReachable = if ($gwReach) { $gwReach.Success } else { $false }
        InternetReach    = $netReach.Success
    }

    if ($Answer -eq 'OtherDevicesToo') {
        return New-GNResult -Id 'OutageScope' -Name 'Problem scope (other devices)' -Layer 'Context' -Status 'Warn' `
            -Summary "You told GeeNet that other devices on this network also have no internet." `
            -Why "When several devices fail at the same time, the fault is usually shared between them - the router, the line, or the ISP." `
            -Meaning "GeeNet can diagnose and repair the computer side only. A shared outage is outside what any software on this PC can fix - the evidence points at the router, the line, or the ISP." `
            -Causes @('Router lost its internet connection (WAN light off or red)','ISP outage or maintenance in the area','Line or cable damage outside the building','Account issue (unpaid bill, data bundle finished, suspension)','Router needs a restart after a firmware update or a power cut') `
            -NextSteps @('Restart the router: unplug it for 30 seconds, then plug it back in (physical action - GeeNet cannot do this)','Look at the router lights and note which are off or red','Contact your ISP with this report if it does not come back (GeeNet can save the report)','If you have mobile data, use it in the meantime') `
            -FixClass 'Boundary' `
            -Technical "User reports multiple devices affected. Gateway $gw reachable from this PC: $(if ($gwReach) { $gwReach.Success } else { 'n/a' }). Internet reachable: $($netReach.Success)." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($Answer -eq 'ThisPcOnly') {
        return New-GNResult -Id 'OutageScope' -Name 'Problem scope (other devices)' -Layer 'Context' -Status 'Info' `
            -Summary "You told GeeNet that other devices on this network have working internet, but this computer does not." `
            -Why "If other devices work, the router, the line and the ISP are all fine - so the fault is inside this computer or its own connection to the network." `
            -Meaning "This narrows the investigation to the client side: this PC's adapter, its IP configuration, DNS, proxy/VPN settings or firewall." `
            -NextSteps @('Focus on this PC: adapter, IP configuration, DNS and proxy/VPN checks','Compare this PC''s IP address with a working device - they should be on the same subnet','If this PC works on a phone hotspot but not here, the router may be blocking or mis-addressing just this device') `
            -FixClass 'SafeAuto' `
            -Technical "User reports only this PC affected. This PC: gateway reachable $(if ($gwReach) { $gwReach.Success } else { 'n/a' }), internet reachable $($netReach.Success)." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'OutageScope' -Name 'Problem scope (other devices)' -Layer 'Context' -Status 'Info' `
        -Summary "Scope not confirmed: GeeNet does not know yet whether other devices have internet." `
        -Why "Knowing whether other devices are affected decides whether the fault is inside this computer or shared with the whole network." `
        -Meaning "Until the scope is known, the diagnosis covers both possibilities, and GeeNet will suggest the quick check that settles it." `
        -NextSteps @('Pick up your phone, stay on the Wi-Fi (not mobile data) and try loading a website','If the phone works, the problem is this computer; if it fails too, the problem is shared','Answer this question next time so GeeNet can be more precise') `
        -FixClass 'Manual' `
        -Technical "Scope answer: not sure. This PC: gateway $gw reachable $(if ($gwReach) { $gwReach.Success } else { 'n/a' }), internet $($netReach.Success)." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

# ------------------------------------------------------------------------------
#region 14. TEST REGISTRY (scenarios reference these short keys)
# ------------------------------------------------------------------------------

$script:GNTestRegistry = [ordered]@{
    'Adapter'       = @{ Function = 'Test-NetworkAdapter';  Name = 'Network adapter' }
    'WiFi'          = @{ Function = 'Test-WiFi';            Name = 'Wi-Fi' }
    'WiFiScan'      = @{ Function = 'Test-WiFiScan';        Name = 'Nearby Wi-Fi networks' }
    'Ethernet'      = @{ Function = 'Test-Ethernet';        Name = 'Ethernet cable' }
    'Driver'        = @{ Function = 'Test-AdapterDriver';   Name = 'Adapter driver' }
    'IP'            = @{ Function = 'Test-IPConfiguration'; Name = 'IP configuration' }
    'DHCP'          = @{ Function = 'Test-DHCP';            Name = 'DHCP address service' }
    'Gateway'       = @{ Function = 'Test-DefaultGateway';  Name = 'Default gateway' }
    'GatewayReach'  = @{ Function = 'Test-GatewayReach';    Name = 'Router reachability' }
    'ARP'           = @{ Function = 'Test-ARP';             Name = 'Local device table (ARP)' }
    'Route'         = @{ Function = 'Test-Route';           Name = 'Routing table' }
    'LocalNetwork'  = @{ Function = 'Test-LocalNetwork';    Name = 'Local network' }
    'LocalHost'     = @{ Function = 'Test-LocalHost';       Name = 'Local device reachability' }
    'MTU'           = @{ Function = 'Test-MTU';             Name = 'Packet size (MTU)' }
    'InternetIP'    = @{ Function = 'Test-InternetIP';      Name = 'Internet by IP address' }
    'CaptivePortal' = @{ Function = 'Test-CaptivePortal';   Name = 'Sign-in page (portal)' }
    'DNS'           = @{ Function = 'Test-DNS';             Name = 'DNS name resolution' }
    'HTTPS'         = @{ Function = 'Test-HTTPS';           Name = 'Web (HTTPS) access' }
    'Website'       = @{ Function = 'Test-Website';         Name = 'Website reachability' }
    'AppConnect'    = @{ Function = 'Test-ApplicationConnectivity'; Name = 'Application/service connectivity' }
    'Latency'       = @{ Function = 'Test-Latency';         Name = 'Latency' }
    'PacketLoss'    = @{ Function = 'Test-PacketLoss';      Name = 'Packet loss' }
    'BandwidthHogs' = @{ Function = 'Test-BandwidthHogs';   Name = 'Programs using the network' }
    'Stability'     = @{ Function = 'Test-Stability';       Name = 'Stability monitor' }
    'Proxy'         = @{ Function = 'Test-Proxy';           Name = 'Proxy settings' }
    'VPN'           = @{ Function = 'Test-VPN';             Name = 'VPN / tunnel' }
    'Firewall'      = @{ Function = 'Test-Firewall';        Name = 'Firewall / security' }
    'HostsFile'     = @{ Function = 'Test-HostsFile';       Name = 'Hosts file' }
    'Services'      = @{ Function = 'Test-Services';        Name = 'Windows services' }
    'NetworkStack'  = @{ Function = 'Test-NetworkStack';    Name = 'Windows network stack' }
    'OutageScope'   = @{ Function = 'Test-OutageScope';     Name = 'Problem scope' }
}

function Get-GNTestInfo {
    param([string]$Key)
    if ($script:GNTestRegistry.Contains($Key)) { return $script:GNTestRegistry[$Key] }
    return $null
}

# ------------------------------------------------------------------------------
#region 15. INTERPRETATION ENGINE (combination reasoning + sequential stop rules)
# ------------------------------------------------------------------------------

function Get-GNArray {
    <#
      Normalises "a collection of results" into a plain array.
      Besides making the code below predictable, this avoids a PowerShell binder fault
      that can throw "Argument types do not match" when @() is applied to a generic
      List[object] on some PowerShell builds.
    #>
    param($Items)
    if ($null -eq $Items) { return @() }
    if ($Items -is [array]) { return $Items }
    try {
        if ($Items.PSObject.Methods['ToArray']) { return $Items.ToArray() }
    } catch { }
    return @($Items)
}

function Show-GNTechnicalDetails {
    <#
      The optional deep layer: the actual values behind the plain-English diagnosis.
      Nothing is hidden from beginners - it is just kept out of the way until asked for.
    #>
    param($Results)
    $rows = @((Get-GNArray -Items $Results) | Where-Object { $_ -and "$($_.Layer)" -ne 'Context' })
    Write-GNOut ''
    Write-GNRule '=' 2 ($script:GNW - 4) DarkCyan
    Write-GNOut "  TECHNICAL DETAILS" -Color Cyan
    Write-GNRule '-' 2 ($script:GNW - 4) DarkCyan
    Write-GNPara -Text "These are the values GeeNet actually read from Windows and measured. You do not need them to follow the advice - they are here so nothing is hidden and so a technician can see the raw evidence." -Color $script:GNCol.Dim -Indent 4
    if ($rows.Count -eq 0) {
        Write-GNOut ''
        Write-GNPara -Text "No checks have run yet, so there is nothing to show." -Color $script:GNCol.Warn -Indent 4
        Write-GNOut ''
        return
    }
    foreach ($r in $rows) {
        $mark = switch ("$($r.Status)") { 'Pass' { $script:GNG.Tick } 'Fail' { $script:GNG.Cross } 'Warn' { $script:GNG.Triangle } 'Skip' { $script:GNG.Skip } default { $script:GNG.Info } }
        Write-GNOut ''
        Write-GNOut ("  " + $mark + " " + $r.Name + "   [" + $r.Status + "]") -Color $script:GNCol.Bright
        if ($r.Technical) { Write-GNPara -Text $r.Technical -Color $script:GNCol.Text -Indent 6 }
        else { Write-GNPara -Text "(no extra detail was recorded for this check)" -Color $script:GNCol.Dim -Indent 6 }
        $bits = @()
        if ($r.Id) { $bits += "check id $($r.Id)" }
        if ($r.Layer) { $bits += "layer $($r.Layer)" }
        if ($r.DurationMs) { $bits += "took $($r.DurationMs) ms" }
        if ($r.FixClass -and $r.FixClass -ne 'NotNeeded') { $bits += "fix class $($r.FixClass)" }
        if ($bits.Count -gt 0) { Write-GNOut ("      " + ($bits -join '   -   ')) -Color $script:GNCol.Dim }
    }
    Write-GNOut ''
    Write-GNPara -Text "The values above are also written to the session log and to any report you save." -Color $script:GNCol.Dim -Indent 4
    if ($script:GNLogFile) { Write-GNPara -Text ("Session log: " + $script:GNLogFile) -Color $script:GNCol.Dim -Indent 4 }
    Write-GNOut ''
}

function Get-GNResultMap {
    param($Results)
    $map = @{}
    foreach ($r in (Get-GNArray -Items $Results)) {
        if ($r -and $r.Id) { $map[$r.Id] = $r }
    }
    return $map
}

function Get-GNStatusOf {
    param([hashtable]$Map, [string]$Id)
    if ($Map.ContainsKey($Id)) { return "$($Map[$Id].Status)" }
    return 'Absent'
}

function Test-GNAnyFailed {
    param([hashtable]$Map, [string[]]$Ids)
    foreach ($i in $Ids) { if ((Get-GNStatusOf -Map $Map -Id $i) -eq 'Fail') { return $true } }
    return $false
}

function Test-GNAnyWarned {
    param([hashtable]$Map, [string[]]$Ids)
    foreach ($i in $Ids) { if ((Get-GNStatusOf -Map $Map -Id $i) -eq 'Warn') { return $true } }
    return $false
}

function Get-GNStopDecision {
    <#
      Sequential reasoning: decide whether an early result already proves the likely failure,
      so we do not waste the user's time running predictable tests further along the chain.

      Returns 'Continue', 'Stop' (nothing else makes sense) or 'StopSoft'
      (skip only the internet-dependent tests, but keep gathering context).
    #>
    param(
        [string]$TestKey,
        $Result,
        [string[]]$Remaining = @(),
        $ResultsSoFar = @()
    )
    if (-not $Result) { return 'Continue' }
    # A failure on the link type you are NOT using must never stop the investigation:
    # e.g. the cable is unplugged but Wi-Fi is working, or vice versa.
    $linkOtherOk = {
        param([string]$OtherId)
        foreach ($r in @($ResultsSoFar)) { if ($r.Id -eq $OtherId -and $r.Status -eq 'Pass') { return $true } }
        return $false
    }
    $softOnly = @('OutageScope','VPN','Proxy','Firewall','HostsFile','Services','NetworkStack','CaptivePortal','LocalNetwork','LocalHost')

    switch ($TestKey) {
        'Adapter' {
            if ($Result.Status -eq 'Fail') { return 'Stop' }
        }
        'WiFi' {
            if ($Result.Status -eq 'Fail' -and "$($Result.Data.Connected)" -ne 'True') {
                # Wi-Fi link is down - but only stop if no other link is carrying the connection.
                if (& $linkOtherOk 'Ethernet') { return 'Continue' }
                if ($Result.Data.OtherLinkUp -eq $true) { return 'Continue' }
                if ($Remaining.Length -gt 0) { return 'Stop' }
            }
        }
        'Ethernet' {
            if ($Result.Status -eq 'Fail' -and $Result.Data.HasLink -eq $false) {
                if (& $linkOtherOk 'Wifi') { return 'Continue' }
                if ($Result.Data.OtherLinkUp -eq $true) { return 'Continue' }
                if ($Remaining -contains 'WiFi' -or $Remaining -contains 'WiFiScan') { return 'Continue' }
                if ($Remaining.Length -gt 0) { return 'Stop' }
            }
        }
        'IP' {
            if ($Result.Status -eq 'Fail') {
                # allow DHCP explanation to run, then stop
                if ($Remaining -contains 'DHCP') { return 'Continue' }
                return 'Stop'
            }
        }
        'DHCP' {
            if ($Result.Status -eq 'Fail' -and $Result.Data.DhcpEnabled -ne 'Disabled') { return 'Stop' }
        }
        'Gateway' {
            if ($Result.Status -eq 'Fail') {
                if ($Remaining -contains 'DHCP') { return 'Continue' }
                return 'Stop'
            }
        }
        'GatewayReach' {
            if ($Result.Status -eq 'Fail') { return 'Stop' }
        }
        'InternetIP' {
            if ($Result.Status -eq 'Fail') { return 'StopSoft' }
            if ($Result.Status -eq 'Skip') { return 'StopSoft' }
        }
        'DNS' {
            if ($Result.Status -eq 'Fail') { return 'StopSoft' }
        }
        'NetworkStack' {
            if ($Result.Status -eq 'Fail' -and $Result.Data.Ipv4DisabledOn -and @($Result.Data.Ipv4DisabledOn).Count -gt 0) { return 'Stop' }
        }
    }
    return 'Continue'
}

function Get-GNStopReason {
    param([string]$TestKey, $Result)
    switch ($TestKey) {
        'Adapter'      { return "No active network adapter was detected. Without an active adapter (Wi-Fi or Ethernet switched on, enabled and connected) nothing further along the chain can work, so GeeNet stopped here instead of reporting a pile of predictable failures. Fixing the adapter connection is the logical next step." }
        'WiFi'         { return "Your Wi-Fi is not connected to any network. IP addresses, the router and the internet all depend on that link being up, so GeeNet stopped here rather than reporting failures that are simply a consequence of the disconnected Wi-Fi." }
        'Ethernet'     { return "There is no live Ethernet link (no cable connection detected). Everything past the physical layer depends on it, so GeeNet stopped here." }
        'IP'           { return "Your computer does not currently have a usable IPv4 address. Without an address there is no gateway, no routing and no internet, so GeeNet stopped before running tests that could only fail for the same reason." }
        'DHCP'         { return "The automatic address service (DHCP) is not working, so this computer has no valid address for the network. GeeNet stopped here because every later test depends on having an address." }
        'Gateway'      { return "No default gateway (router address) is configured, so the computer has no route out of the local network. GeeNet stopped here - the configuration must be fixed first." }
        'GatewayReach' { return "Your computer cannot reach its own router. Internet tests would only report the same failure, so GeeNet stopped here: this is a local network problem, not an internet problem." }
        'InternetIP'   { return "The internet could not be reached by IP address, and that does not involve DNS at all. GeeNet skipped the domain-name and web tests because they can only be expected to fail until the connection itself is working. The problem is out on the network/ISP side of your router's internet link." }
        'DNS'          { return "Domain names could not be resolved, so the web (HTTPS) test would be testing DNS again instead of the web layer. GeeNet stopped the dependent tests and focused the diagnosis on DNS." }
        default        { return "GeeNet stopped here because this failure makes the remaining tests meaningless." }
    }
}

function Get-GNBoundary {
    <#
      Core reasoning step: work out WHICH layer the evidence points at, using the combination
      of results rather than any single failure.
    #>
    param([hashtable]$Map, [hashtable]$Context = @{})
    $s = { param($id) Get-GNStatusOf -Map $Map -Id $id }

    $adapter     = & $s 'AdapterState'
    $wifi        = & $s 'Wifi'
    $eth         = & $s 'Ethernet'
    $ip          = & $s 'IPConfig'
    $dhcp        = & $s 'Dhcp'
    $gw          = & $s 'Gateway'
    $gwReach     = & $s 'GatewayReach'
    $internet    = & $s 'InternetIP'
    $dns         = & $s 'DNS'
    $https       = & $s 'HTTPS'
    $portal      = & $s 'CaptivePortal'
    $proxy       = & $s 'Proxy'
    $vpn         = & $s 'VPN'
    $stack       = & $s 'NetworkStack'
    $services    = & $s 'Services'
    $app         = & $s 'AppConnect'
    $website     = & $s 'Website'
    $localHost   = & $s 'LocalHost'
    $localNet    = & $s 'LocalNetwork'
    $stability   = & $s 'Stability'
    $latency     = & $s 'Latency'
    $loss        = & $s 'PacketLoss'
    $hosts       = & $s 'HostsFile'
    $mtu         = & $s 'MTU'
    $route       = & $s 'Route'
    $arp         = & $s 'ARP'

    $scope = ''
    if ($Context -and $Context.ContainsKey('OutageScope')) { $scope = "$($Context['OutageScope'])" }
    $connType = ''
    if ($Context -and $Context.ContainsKey('ConnectionType')) { $connType = "$($Context['ConnectionType'])" }

    # A fault on the link type the user is NOT connected through must not drive the diagnosis.
    # (Desktop with no Wi-Fi card, laptop on Wi-Fi with the cable unplugged, etc.)
    if ($wifi -eq 'Fail' -and $eth -eq 'Pass' -and $connType -ne 'WiFi') { $wifi = 'Info' }
    if ($eth -eq 'Fail' -and $wifi -eq 'Pass' -and $connType -ne 'Ethernet') { $eth = 'Info' }

    # ---- 1. Physical / link layer -------------------------------------------
    if ($adapter -eq 'Fail')              { return 'Link' }
    if ($wifi -eq 'Fail' -and $eth -eq 'Fail' -and $connType -eq 'Ethernet') { return 'EthLink' }
    if ($wifi -eq 'Fail' -and $eth -ne 'Fail') { return 'WifiLink' }
    if ($eth -eq 'Fail' -and $wifi -ne 'Pass')  { return 'EthLink' }
    # ---- 2. Windows / stack --------------------------------------------------
    if ($services -eq 'Fail')             { return 'Services' }
    if ($stack -eq 'Fail')                { return 'Stack' }
    # ---- 3. IP / DHCP --------------------------------------------------------
    if ($ip -eq 'Fail')                   { return 'IP' }
    if ($dhcp -eq 'Fail')                 { return 'DHCP' }
    if ($gw -eq 'Fail')                   { return 'Gateway' }
    if ($route -eq 'Fail')                { return 'Route' }
    # ---- 4. Local network ----------------------------------------------------
    if ($gwReach -eq 'Fail')              { return 'LocalNet' }
    if ($localHost -eq 'Fail')            { return 'LocalDevice' }
    # ---- 5. Boundaries that look like the internet side -----------------------
    if ($portal -eq 'Fail')               { return 'CaptivePortal' }
    if ($vpn -eq 'Fail')                  { return 'VPN' }
    if ($internet -eq 'Fail')             { return 'Upstream' }
    # ---- 6. DNS --------------------------------------------------------------
    if ($dns -eq 'Fail')                  { return 'DNS' }
    # ---- 7. Web / proxy ------------------------------------------------------
    if ($proxy -eq 'Fail')                { return 'Proxy' }
    if ($https -eq 'Fail')                { return 'HTTPS' }
    # ---- 8. Application / site specific -------------------------------------
    if ($website -eq 'Fail')              { return 'Website' }
    if ($app -eq 'Fail')                  { return 'Application' }
    if ($hosts -eq 'Warn')                { return 'HostsFile' }
    # ---- 9. Warnings ---------------------------------------------------------
    if ($stability -eq 'Fail')            { return 'Stability' }
    if ($loss -eq 'Fail')                 { return 'PacketLoss' }
    if ($mtu -eq 'Warn')                  { return 'MTU' }
    if ($latency -eq 'Warn')              { return 'Latency' }
    if ($wifi -eq 'Warn')                 { return 'WifiQuality' }
    if ($eth -eq 'Warn')                  { return 'EthQuality' }
    if ($arp -eq 'Warn')                  { return 'LocalNet' }
    if ($localNet -eq 'Warn')             { return 'LocalNet' }
    if ($dns -eq 'Warn')                  { return 'DNSSlow' }
    if ($proxy -eq 'Warn')                { return 'Proxy' }
    if ($vpn -eq 'Warn')                  { return 'VPN' }
    if ($loss -eq 'Warn')                 { return 'PacketLoss' }
    if ($stability -eq 'Warn')            { return 'Stability' }
    if ($https -eq 'Warn')                { return 'HTTPS' }
    if ($internet -eq 'Warn')             { return 'Upstream' }
    return 'Healthy'
}

function Get-GNVerdict {
    <#
      Builds the human diagnosis: boundary, plain-language explanation, evidence,
      likely causes, next steps, whether it is client-side, and which repairs apply.
    #>
    param(
        [string[]]$Plan = @(),
        $Results,
        [hashtable]$Context = @{},
        [string]$Focus = 'Reachability',
        [string]$SymptomText = ''
    )
    $Results = Get-GNArray -Items $Results
    $map = Get-GNResultMap -Results $Results
    $boundary = Get-GNBoundary -Map $map -Context $Context
    $scope = ''
    if ($Context -and $Context.ContainsKey('OutageScope')) { $scope = "$($Context['OutageScope'])" }
    $recent = ''
    if ($Context -and $Context.ContainsKey('RecentChange')) { $recent = "$($Context['RecentChange'])" }
    $connType = ''
    if ($Context -and $Context.ContainsKey('ConnectionType')) { $connType = "$($Context['ConnectionType'])" }
    $gw = ''
    if ($map.ContainsKey('GatewayReach')) { $gw = "$($map['GatewayReach'].Data.Gateway)" }
    elseif ($map.ContainsKey('Gateway')) { $gw = "$($map['Gateway'].Data.Gateway)" }

    $v = [ordered]@{
        Boundary      = $boundary
        Headline      = ''
        Diagnosis     = ''
        Evidence      = @()
        LikelyCauses  = @()
        NextSteps     = @()
        AutoFixable   = $false
        RepairIds     = @()
        ManualActions = @()
        BoundaryNote  = ''
        ClientSide    = $true
        Confidence    = 'moderate'
        Severity      = 'Fail'
    }

    switch ($boundary) {
        'Link' {
            $v.Headline = 'The problem starts at the network adapter (physical/link layer)'
            $v.Diagnosis = "Windows cannot see a usable, connected network adapter. Everything above this layer - addresses, the router and the internet - depends on it, so this is where the diagnosis stops."
            $v.LikelyCauses = @('Wi-Fi or Ethernet adapter is switched off, disabled, or not connected','Driver/device problem reported by Windows','Adapter missing because of hardware or BIOS state')
            $v.NextSteps = @('Make sure the connection you use (Wi-Fi or Ethernet) is actually switched on and connected','Use the repair options below to re-enable the adapter, then re-test','If the adapter still does not appear, open Device Manager and look for a warning symbol','If there is no adapter at all, the driver or the hardware needs attention')
            $v.RepairIds = @('EnableAdapter','RestartAdapter','ReconnectWifi','RestartWlanService')
            $v.AutoFixable = $true
            $v.Confidence = 'high'
        }
        'WifiLink' {
            $v.Headline = 'The Wi-Fi link itself is not connected'
            $v.Diagnosis = "The Wi-Fi adapter is present but this computer is not connected to a wireless network. That alone explains everything you are seeing: no address, no router, no internet."
            $v.LikelyCauses = @('Not connected to your network, or the saved profile is failing','Wi-Fi switched off or airplane mode on','Weak or missing signal, or the network is out of range','WLAN service or driver problem')
            $v.NextSteps = @('Reconnect to your Wi-Fi network, checking the password','If your network is not listed, check that the router is on and you are in range','Use the repair options to reconnect or restart the Wi-Fi service','Then re-test - GeeNet will verify the fix automatically')
            $v.RepairIds = @('ReconnectWifi','RestartWlanService','RestartAdapter','ForgetProfile')
            $v.AutoFixable = $true
            $v.Confidence = 'high'
        }
        'EthLink' {
            $v.Headline = 'The Ethernet (cable) link is not up'
            $v.Diagnosis = "Windows sees the network card but there is no active cable link, so no traffic can pass. This is the classic " + '"Network cable unplugged"' + " state."
            $v.LikelyCauses = @('Cable unplugged, damaged, or the socket is loose','Router/switch port dead or disabled','Dock or USB-Ethernet adapter lost power or its driver failed','Adapter disabled in Windows')
            $v.NextSteps = @('Check the cable at both ends, and watch for a link light','Try another cable, then another port on the router','Use the repair options to re-enable or restart the adapter','Re-test afterwards to confirm the link is up')
            $v.RepairIds = @('EnableAdapter','RestartAdapter')
            $v.AutoFixable = $true
            $v.Confidence = 'high'
        }
        'Services' {
            $v.Headline = 'Windows network services are not running correctly'
            $v.Diagnosis = "One or more Windows network services that handle addresses, names and network awareness are stopped. That can produce symptoms that look like a broken network even when the hardware and router are fine."
            $v.LikelyCauses = @('Service stopped or disabled (often by a tuning tool or an update)','A dependency service failed, so this one could not start')
            $v.NextSteps = @('Let GeeNet start the stopped service(s) - this needs Administrator rights','Re-test afterwards to confirm the address and name resolution work','If a service refuses to start, restart Windows and check again')
            $v.RepairIds = @('StartNetworkServices','RestartAdapter')
            $v.AutoFixable = $true
            $v.Confidence = 'high'
        }
        'Stack' {
            $v.Headline = 'The Windows network stack looks damaged or misconfigured'
            $v.Diagnosis = "Windows cannot use its network stack normally (Winsock catalogue unreadable, or IPv4 switched off on the adapter). This is a Windows-side problem rather than a network problem."
            $v.LikelyCauses = @('Winsock corruption from a tool, uninstall, or malware cleanup','IPv4 unticked in the adapter properties','Leftover entries from an uninstalled VPN/proxy/security product')
            $v.NextSteps = @('Run the safe repair (re-enable IPv4 or reset Winsock) - Administrator rights needed','Restart Windows after a Winsock/TCP-IP reset: the change only applies after a reboot','Re-test after the restart')
            $v.RepairIds = @('EnableIpv4','WinsockReset','TcpIpReset')
            $v.AutoFixable = $true
            $v.Confidence = 'high'
            $v.BoundaryNote = 'A stack reset is a real repair, not a guess - but it needs a restart to take effect.'
        }
        'IP' {
            $v.Headline = 'This computer does not have a usable IP address'
            $v.Diagnosis = "The adapter is connected, but Windows has no valid IPv4 address for this network (either no address at all, or a self-assigned 169.254 address). With no address, the router and the internet are unreachable no matter how good the connection is."
            $v.LikelyCauses = @('DHCP did not hand out an address (link just came up, or the request failed)','Router DHCP service off/broken or its address pool is full','Adapter set to a static address that does not match this network','DHCP Client service or firewall blocking the request')
            $v.NextSteps = @('Let GeeNet release and renew the address (safe, quick)','If you still get 169.254, the router/DHCP side is the likely fault','Check another device on the network: if it cannot get an address either, the router is the problem','If this PC works on a phone hotspot but not here, the home router is the suspect')
            $v.RepairIds = @('RenewDhcp','RestartAdapter','RestoreDhcp')
            $v.AutoFixable = $true
            $v.Confidence = 'high'
        }
        'DHCP' {
            $v.Headline = 'The automatic address service (DHCP) is failing'
            $v.Diagnosis = "Your computer asked the network for an address and did not get one. This is an address-provisioning problem on the local network - not an internet problem."
            $v.LikelyCauses = @('Router DHCP pool exhausted or the DHCP service has stopped responding','Link just came up, or the request was lost','DHCP Client service stopped on this PC','Firewall/security software blocking DHCP traffic','Stale lease from an old network')
            $v.NextSteps = @('Let GeeNet release and renew the address','If renewal fails twice, restart the router (physical action)','Confirm other devices get addresses on this same network','If a static IP is configured, switch the adapter back to automatic')
            $v.RepairIds = @('RenewDhcp','RestoreDhcp','RestartAdapter')
            $v.AutoFixable = $true
            $v.Confidence = 'high'
        }
        'Gateway' {
            $v.Headline = 'No default gateway (router address) is configured'
            $v.Diagnosis = "Your computer has an address but no gateway, so it has no idea which device to send internet traffic through. That alone blocks all internet access."
            $v.LikelyCauses = @('DHCP supplied an address but no gateway','Static IP configured without the gateway field','Gateway address removed by a VPN client or a script')
            $v.NextSteps = @('Renew the address so the gateway arrives with it (GeeNet can do this)','If you use a static IP, enter your router address as the gateway','Check whether a VPN client removed the default route')
            $v.RepairIds = @('RenewDhcp','RestoreDhcp')
            $v.AutoFixable = $true
            $v.Confidence = 'high'
        }
        'Route' {
            $v.Headline = 'The routing table is missing its way out'
            $v.Diagnosis = "There is no default route, or routing conflicts are present, so traffic has no usable path to the internet."
            $v.LikelyCauses = @('No gateway from DHCP','VPN or a virtual adapter interfering with routes','Leftover routes from another network')
            $v.NextSteps = @('Renew the address so the route is rebuilt','Disconnect any VPN, then re-check','Re-test the internet after that')
            $v.RepairIds = @('RenewDhcp','RestartAdapter')
            $v.AutoFixable = $true
        }
        'LocalNet' {
            $v.Headline = 'Your computer cannot reach the router (local network problem)'
            $v.Diagnosis = "The adapter, the address and the gateway configuration are all in place, but the router does not answer. That means the fault is between this computer and the router - your internet connection may be perfectly fine."
            $v.LikelyCauses = @('Wi-Fi connected to the wrong network, or weak/unstable signal','Ethernet cable, port or dock problem','IP address or subnet mask not matching the router network','Router LAN side unresponsive, overloaded, or restarting','Your PC is on a different network segment (guest VLAN) than you think')
            $v.NextSteps = @('Check your IP address, subnet mask and gateway are all on the same network','Test on a wired connection if you are on Wi-Fi (or the reverse)','Restart the router (physical action - GeeNet cannot do this)','If other devices work but this one does not, re-run this diagnosis after clearing the ARP cache')
            $v.RepairIds = @('ClearArpCache','RestartAdapter','ReconnectWifi','RestoreDhcp')
            $v.AutoFixable = $true
            $v.BoundaryNote = 'If the router does not respond to this computer but works for other devices, the router may be filtering this PC, or this PC may be on a different network segment.'
        }
        'LocalDevice' {
            $v.Headline = 'This computer cannot reach the local device you named'
            $v.Diagnosis = "The device you asked GeeNet to test did not answer. Your internet path is not implicated by this finding."
            $v.LikelyCauses = @('The device is off, asleep or disconnected','Its firewall blocks ping and the ports tested','It is on a different subnet/VLAN','Network isolation (guest Wi-Fi or office policy) blocks device-to-device traffic')
            $v.NextSteps = @('Confirm the device is powered on and connected','Check the address you gave is correct','Test another device on the same network to see whether it is only this one','If you are on guest Wi-Fi, expect device isolation')
            $v.AutoFixable = $false
            $v.Confidence = 'moderate'
        }
        'CaptivePortal' {
            $v.Headline = 'A sign-in page (captive portal) is holding your internet access'
            $v.Diagnosis = "Your network is redirecting web traffic to a login or terms page. The connection works; the network simply will not let traffic through until you accept or sign in."
            $v.LikelyCauses = @('Terms not accepted yet on this network','Session expired','Portal page not loading in the browser')
            $v.NextSteps = @('Open a browser and accept the terms or sign in','If no page appears, visit http://neverssl.com to force the portal','Then let GeeNet re-test')
            $v.AutoFixable = $false
            $v.ClientSide = $false
            $v.BoundaryNote = 'This is a network policy, not a fault on this computer. GeeNet cannot accept terms for you.'
            $v.Confidence = 'high'
        }
        'VPN' {
            $v.Headline = 'A VPN/tunnel is interfering with your internet access'
            $v.Diagnosis = "A VPN or tunnel adapter is active and traffic is not getting through it, while the local network still works. The evidence points at the VPN connection rather than at your Wi-Fi, router or ISP."
            $v.LikelyCauses = @('VPN session half-connected or dropped while the adapter stayed up','VPN server unreachable','VPN client changed routing/DNS','VPN software misconfigured after an update')
            $v.NextSteps = @('Disconnect the VPN completely and re-test - this is the single most useful test','If the internet returns, reconnect and compare','If it breaks again, switch VPN server or update the client','If the tunnel adapter stays up after disconnecting, restart Windows')
            $v.AutoFixable = $false
            $v.Confidence = 'moderate'
            $v.BoundaryNote = 'GeeNet will not change VPN configuration automatically - VPN software is best managed by its own client.'
        }
        'Upstream' {
            $v.Headline = 'The local network is fine, but the internet is not reachable'
            $v.Diagnosis = "Your computer has an address, the router is reachable (or at least configured), but traffic is not reaching the internet. That points upstream of this computer: the router's internet link, the line, or the ISP."
            $v.LikelyCauses = @('Router lost its internet (WAN) connection','ISP outage or line problem in your area','Router needs a restart or is overloaded','Account/bundle issue (suspended, data finished)','Captive portal not accepted, or MAC filtering at the router blocking this device')
            $v.NextSteps = @('Check whether other devices on the same network have internet - that single check tells you whether this is your computer or the whole connection','Look at your router: the internet/WAN light should be lit or blinking','Restart the router: unplug 30 seconds, plug back in (physical action)','If other devices also fail, contact your ISP - GeeNet can save a report to send them')
            $v.AutoFixable = $false
            $v.ClientSide = $false
            $v.BoundaryNote = 'GeeNet can diagnose the computer side of this problem, but it cannot physically repair or reboot your router, and it cannot restore an ISP link.'
            $v.Confidence = 'high'
        }
        'DNS' {
            $v.Headline = 'Domain names (DNS) are not resolving'
            $v.Diagnosis = "The internet works by IP address, but names like google.com cannot be turned into addresses. That is why pages will not open even though you are connected."
            $v.LikelyCauses = @('DNS server address wrong, stale, or belonging to an old network','Configured DNS server not responding (router DNS proxy or VPN DNS failing)','Windows DNS Client service stopped, or a corrupt cache entry','Hosts file or filtering tool overriding names')
            $v.NextSteps = @('Clear the DNS cache first (safe, instant)','If it continues, switch this computer to a reliable public DNS server','If a VPN is connected, disconnect it and retest','Re-test name resolution - GeeNet will verify the fix')
            $v.RepairIds = @('FlushDns','SetPublicDns','RegisterDns','StartNetworkServices')
            $v.AutoFixable = $true
            $v.Confidence = 'high'
        }
        'DNSSlow' {
            $v.Headline = 'DNS is working but slowly'
            $v.Diagnosis = "Names resolve, but each lookup takes far longer than it should. That makes every new website feel like it hangs for a few seconds before loading."
            $v.LikelyCauses = @('The DNS server you use (often the router) is overloaded or forwarding slowly','A VPN or security tool is proxying DNS','Packet loss or high latency on the connection')
            $v.Severity = 'Warn'
            $v.NextSteps = @('Try switching this computer to a fast public DNS server','Test with any VPN disconnected','Re-test the lookup time afterwards')
            $v.RepairIds = @('SetPublicDns','FlushDns')
            $v.AutoFixable = $true
            $v.Confidence = 'moderate'
        }
        'Proxy' {
            $v.Headline = 'Proxy settings are breaking web access'
            $v.Diagnosis = "A proxy is configured on this computer and web traffic fails through it while working directly. The connection is fine - the proxy setting is the problem."
            $v.LikelyCauses = @('Proxy left over from another network or an uninstalled tool','Malware/adware proxy','Corporate proxy not reachable from here','Unreachable PAC (auto-config) URL')
            $v.NextSteps = @('Disable the proxy settings (GeeNet can do it), and reset the WinHTTP proxy','Restart the browser afterwards','If this is a work PC, ask IT for the correct proxy instead','Re-test web access to confirm')
            $v.RepairIds = @('DisableProxy','ResetWinHttpProxy')
            $v.AutoFixable = $true
            $v.Confidence = 'high'
        }
        'HTTPS' {
            $v.Headline = 'Web traffic (HTTPS) is being blocked or broken'
            $v.Diagnosis = "Everything up to the internet works, DNS resolves names, but secure web requests do not complete. That points at filtering, a proxy, TLS inspection, or the application layer - not at your Wi-Fi or router."
            $v.LikelyCauses = @('Firewall or security software blocking web traffic (including HTTPS inspection)','Proxy or VPN interfering','Router/ISP content filter or parental controls','Wrong system clock breaking TLS','Captive portal or portal-like filtering')
            $v.NextSteps = @('Check proxy settings and reset them if they are unfamiliar','Test the same site from another device on this network to compare','Temporarily disable HTTPS inspection in your antivirus and re-test','Check the Windows date and time are correct, then re-test')
            $v.AutoFixable = $false
            $v.Confidence = 'moderate'
        }
        'Website' {
            $v.Headline = 'This specific website is the problem, not your connection'
            $v.Diagnosis = "General internet and DNS are working, but this one site does not load. That is a site-specific issue: blocking or filtering of that name, or a problem at the site itself."
            $v.LikelyCauses = @('Hosts file or DNS filtering blocking that name','The site is down or is blocking your region/network','A filter (school, office, parental control) blocking the site','Browser cache/cookies for that site')
            $v.NextSteps = @('Try the site on another device or on mobile data to compare','Clear the DNS cache, then re-test','Check the hosts file entries for that name','Try a private/incognito window to rule out browser state')
            $v.RepairIds = @('FlushDns')
            $v.AutoFixable = $true
            $v.Confidence = 'moderate'
        }
        'HostsFile' {
            $v.Headline = 'Your hosts file is overriding website addresses'
            $v.Diagnosis = "Local entries in the Windows hosts file are redirecting or blocking specific names, which can make one site (or several) fail while everything else works."
            $v.LikelyCauses = @('Ad-blocker or parental-control tool writing entries (often intentional)','Leftover entries from an uninstalled tool','Malware redirecting traffic')
            $v.NextSteps = @('Review the entries GeeNet listed in the result above','Remove the lines you did not add, then re-test','If they come back, run a malware scan')
            $v.AutoFixable = $false
            $v.Confidence = 'moderate'
            $v.Severity = 'Warn'
        }
        'Application' {
            $v.Headline = 'The application itself cannot connect (network path is fine)'
            $v.Diagnosis = "Your connection, DNS and general web access all work, but this application cannot reach its service. That points at the application, its proxy/VPN settings, a firewall rule for that app, or the service's own status."
            $v.LikelyCauses = @('Application needs an update, or is stuck on an old session/cache','Firewall rule blocking that specific application','The service itself is down or blocking your network','Port the app needs is blocked (many apps need UDP ports that networks block)')
            $v.NextSteps = @('Close and reopen the application, or sign out and back in','Test the same app on another device on this network','If calls/voice fail but text works, suspect blocked UDP ports','Check the service status page for an outage')
            $v.AutoFixable = $false
            $v.Confidence = 'moderate'
        }
        'Stability' {
            $v.Headline = 'The connection is unstable (intermittent dropouts)'
            $v.Diagnosis = "GeeNet monitored the link and saw repeated failures. That is what causes random disconnections, freezing calls and dropped games - even though a single test might look fine."
            $v.LikelyCauses = @('Weak Wi-Fi signal or interference','Faulty Ethernet cable, port or dock','Router struggling or overheating','ISP line instability','Adapter power management switching the device off')
            $v.NextSteps = @('Repeat the monitor on a wired connection - if drops disappear, it is Wi-Fi','Replace the cable/port if you are wired','Turn off adapter power saving to remove that variable','If the router drops for other devices too, restart it and involve your ISP')
            $v.RepairIds = @('DisableAdapterPowerSave','RestartAdapter','ReconnectWifi')
            $v.AutoFixable = $true
            $v.Confidence = 'moderate'
            $v.Severity = 'Fail'
        }
        'PacketLoss' {
            $v.Headline = 'Packets are being lost on the way to the internet'
            $v.Diagnosis = "GeeNet saw replies go missing during testing. Packet loss is the usual cause of stuttering video calls, lag in games and stalled downloads."
            $v.LikelyCauses = @('Weak Wi-Fi or interference','Cable/port faults','Network congestion (downloads, updates, many devices)','ISP line quality')
            $v.NextSteps = @('Test on Ethernet to see whether loss disappears','Check for background downloads/updates saturating the link','Run the stability monitor for a minute to see the pattern','If loss persists on a wired link and on other devices, contact your ISP')
            $v.RepairIds = @('DisableAdapterPowerSave','RestartAdapter')
            $v.AutoFixable = $true
            $v.Confidence = 'moderate'
        }
        'Latency' {
            $v.Headline = 'The connection works but the delay (latency) is high'
            $v.Diagnosis = "Everything is reachable, but round-trip times are high or jumpy. This is what makes a connection feel slow even when downloads are fine."
            $v.LikelyCauses = @('Wi-Fi distance/interference','Network congestion','VPN adding an extra hop','ISP routing/congestion at peak times')
            $v.NextSteps = @('Test on a wired connection for comparison','Close background downloads and re-test','Test with any VPN disconnected','Compare with another device on the same network')
            $v.AutoFixable = $false
            $v.Confidence = 'moderate'
            $v.Severity = 'Warn'
        }
        'WifiQuality' {
            $v.Headline = 'Wi-Fi signal quality is marginal'
            $v.Diagnosis = "You are connected, but the wireless signal is weak or only fair. That is enough to explain slow speeds, dropouts and stuttering calls."
            $v.LikelyCauses = @('Distance or obstacles between this PC and the router','Interference from other networks or appliances','Router antenna placement, or using the 2.4 GHz band at short range')
            $v.NextSteps = @('Move closer to the router, or move the router to a more open position','Prefer 5 GHz when close, 2.4 GHz when far','Use Ethernet for anything that must not drop','Re-run the Wi-Fi check to see the signal improve')
            $v.AutoFixable = $false
            $v.Confidence = 'moderate'
            $v.Severity = 'Warn'
        }
        'EthQuality' {
            $v.Headline = 'The Ethernet link is up but degraded'
            $v.Diagnosis = "The cable link negotiated a low speed, or the adapter is reporting errors. That points at the cable, the port, or the dock."
            $v.LikelyCauses = @('Damaged or low-quality (Cat5) cable','Router/switch port problem','Failing dock or USB-Ethernet adapter')
            $v.NextSteps = @('Swap the cable for a known-good Cat5e/Cat6 cable','Try a different router port','Re-run the Ethernet check and compare the link speed')
            $v.AutoFixable = $false
            $v.Confidence = 'moderate'
            $v.Severity = 'Warn'
        }
        'MTU' {
            $v.Headline = 'Packet size (MTU) is smaller than normal on this path'
            $v.Diagnosis = "The largest packet that can pass without fragmentation is unusually small. That typically comes from a VPN tunnel, PPPoE DSL, or a router with the wrong MTU and it can make some sites and logins fail."
            $v.LikelyCauses = @('VPN tunnel without MSS clamping','PPPoE DSL connections (1492 maximum)','Router MTU misconfigured')
            $v.NextSteps = @('If you use a VPN, try another server or update the client','For DSL/PPPoE, set the router MTU to 1492','If specific large pages time out, mention the MTU finding to your ISP')
            $v.AutoFixable = $false
            $v.Confidence = 'moderate'
            $v.Severity = 'Warn'
        }
        default {
            $v.Headline = 'No fault found in the tests GeeNet could run'
            $v.Diagnosis = "Everything GeeNet tested passed: adapter, address, router, internet by IP, DNS and web access. Your connection looks healthy from this computer right now."
            $v.ClientSide = $false
            if ($Focus -eq 'Slowness') {
                $v.Diagnosis += " Since you reported slowness, bear in mind that a healthy single test does not rule out congestion or intermittent problems - run the stability monitor and latency test to see the pattern over time."
                $v.NextSteps = @('Run the stability monitor for 60 seconds to look for dropouts','Run the latency and packet loss tests, ideally while the problem is happening','Test again when the connection feels slow, and compare the numbers','If it is slow only at certain times, that points to congestion on the network or at your ISP')
            } elseif ($Focus -eq 'Stability') {
                $v.Diagnosis += " Since you reported dropouts, run the stability monitor again while the problem is actually happening - intermittent faults are invisible otherwise."
                $v.NextSteps = @('Run the stability monitor when the problem happens','Note the exact time of a dropout so it can be matched to the report','Test on a wired connection to rule Wi-Fi in or out','If the router drops for other devices too, restart it and contact your ISP if it continues')
            } elseif ($Focus -eq 'Windows') {
                $v.Diagnosis += " If Windows itself still shows a warning or the wrong network name while pages do load, that is usually cosmetic: the Network Location Awareness profile is stale, or the network is marked Public."
                $v.NextSteps = @('If everything actually works, you can ignore the Windows warning','To clear a stale profile: restart the computer, which rebuilds network profiles','Check Settings > Network & Internet > properties: set the network to Private on a home/office network so file sharing and discovery work','If a specific app is blocked, check Windows Firewall for that app rather than resetting the network')
            } elseif ($Focus -eq 'App') {
                $v.Diagnosis += " If a specific application still fails, the fault is inside that application or its service - the network path to it is working."
                $v.NextSteps = @('Restart the application and sign in again','Test the same application on another device on this network','If it is a voice/video app, blocked UDP ports are the usual culprit','Check the service status page in case the problem is theirs')
            } else {
                $v.NextSteps = @('If the problem comes back, run this diagnosis again while it is happening','Note what changed just before the problem started (an update, a new app, a settings change)','Use the Professional tools section for deeper checks such as traceroute and continuous ping')
            }
            $v.Severity = 'Pass'
            $v.Confidence = 'moderate'
        }
    }

    # ---- context adjustments -------------------------------------------------
    if ($scope -eq 'OtherDevicesToo' -and $boundary -notin @('CaptivePortal','Application','Website','HostsFile')) {
        $v.ClientSide = $false
        if (-not $v.AutoFixable) {
            $v.Diagnosis += " You also told GeeNet that other devices on this network have no internet, which means this is a shared problem - the router, the line, or the ISP - and not something on this PC."
            $v.BoundaryNote = 'GeeNet can diagnose the computer side of this problem, but it cannot physically repair or reboot your router, and it cannot restore an ISP link. That part needs you (or your ISP).'
        }
    }
    if ($scope -eq 'ThisPcOnly' -and $v.ClientSide) {
        $v.Diagnosis += " You told GeeNet that other devices on this network work fine, so this is a client-side problem: the investigation stayed inside this computer and its own connection."
        $v.Confidence = 'high'
    }
    if ($recent) {
        switch ($recent) {
            'WindowsUpdate' { $v.LikelyCauses += 'A recent Windows or driver update changed the adapter, driver or network settings'; $v.NextSteps += 'If the problem started right after an update, check for a newer driver from the PC or adapter maker, and consider rolling back the network driver' }
            'VpnInstall'    { $v.LikelyCauses += 'Installing or configuring a VPN changed routing, DNS or proxy settings'; $v.NextSteps += 'Disconnect the VPN completely and re-test; if the problem disappears, the VPN configuration is the cause' }
            'DnsChange'     { $v.LikelyCauses += 'A DNS server change means names now go to a resolver that is not working'; $v.NextSteps += 'Switch this computer back to automatic DNS, or to a reliable public server' }
            'StaticIp'      { $v.LikelyCauses += 'A manually configured IP address does not match this network'; $v.NextSteps += 'Switch the adapter back to automatic addressing and re-test' }
            'SettingsPoke'  { $v.LikelyCauses += 'Something was changed in the network settings that this computer cannot recover from by itself'; $v.NextSteps += 'Use the repair options below to restore automatic settings, then restart Windows if needed' }
            'Other'         { $v.LikelyCauses += 'Something changed around the time the problem started'; $v.NextSteps += 'If you can remember the change, undo it and re-test' }
        }
    }
    # The boundary note only makes sense when something is actually wrong: on a healthy
    # connection there is nothing to fix, here or on the router.
    if (-not $v.ClientSide -and -not $v.BoundaryNote -and $v.Severity -ne 'Pass') {
        $v.BoundaryNote = 'GeeNet can diagnose the computer side of this problem, but it cannot physically repair or reboot your router.'
    }

    # ---- what only the user can do -------------------------------------------
    # Some faults cannot be repaired by software on this PC (the router, the line, the
    # application, a captured portal, a VPN). Never leave the user with no way forward.
    if ($v.Boundary -ne 'Healthy') {
        if (@($v.RepairIds).Count -eq 0 -and -not $v.AutoFixable) {
            $v.AutoFixable = $false
            if ($v.ManualActions.Count -eq 0) { $v.ManualActions = @($v.NextSteps) }
        }
    }

    # ---- evidence list -------------------------------------------------------
    $evidence = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($Results)) {
        if (-not $r) { continue }
        if ($r.Layer -eq 'Context') { continue }
        if ($r.Status -eq 'Skip') { continue }
        $mark = switch ($r.Status) { 'Pass' { 'OK  ' } 'Fail' { 'FAIL' } 'Warn' { 'WARN' } default { 'INFO' } }
        $line = "$mark  $($r.Name) - $($r.Summary)"
        [void]$evidence.Add($line)
    }
    $v.Evidence = (Get-GNArray -Items $evidence)

    # ---- repairs from failed results (fallback if boundary did not set them) --
    if ($v.RepairIds.Count -eq 0) {
        foreach ($r in @($Results)) {
            if ($r -and $r.Status -eq 'Fail' -and $r.FixClass -eq 'SafeAuto') {
                if ($r.Id -eq 'IPConfig' -or $r.Id -eq 'Dhcp') { $v.RepairIds += 'RenewDhcp' }
                elseif ($r.Id -eq 'DNS') { $v.RepairIds += 'FlushDns' }
                elseif ($r.Id -eq 'Proxy') { $v.RepairIds += 'DisableProxy' }
                elseif ($r.Id -eq 'Route') { $v.RepairIds += 'RenewDhcp' }
                elseif ($r.Id -eq 'AdapterState') { $v.RepairIds += 'EnableAdapter' }
            }
        }
        $v.RepairIds = @($v.RepairIds | Select-Object -Unique)
        $v.AutoFixable = ($v.RepairIds.Count -gt 0)
    } else {
        $v.RepairIds = @($v.RepairIds | Select-Object -Unique)
    }

    # Automatic repair only makes sense if the failure is on this computer
    if (-not $v.ClientSide) { $v.AutoFixable = $false }

    return [pscustomobject]$v
}

# ------------------------------------------------------------------------------
#region 16. INVESTIGATION RUNNER (sequential engine + rendering)
# ------------------------------------------------------------------------------

function Write-GNStepLine {
    param(
        [int]$Index, [int]$Total, [string]$Name, [string]$Status = '',
        [int]$DurationMs = 0, [switch]$NoNewline
    )
    $label = "[$Index/$Total] $Name"
    $maxLabel = $script:GNW - 18
    if ($label.Length -gt $maxLabel) { $label = $label.Substring(0, $maxLabel - 3) + '...' }
    $dots = '.' * [Math]::Max(1, ($maxLabel - $label.Length))
    Write-GNOut ("  " + $label + " " + $dots + " ") -Color $script:GNCol.Bright -NoNewline
    if ($NoNewline) { return }
    $col = 'DarkGray'
    switch ($Status) {
        'PASS' { $col = 'Green' }
        'FAIL' { $col = 'Red' }
        'WARN' { $col = 'DarkYellow' }
        'SKIP' { $col = 'DarkGray' }
        'INFO' { $col = 'Cyan' }
    }
    $dur = ''
    if ($DurationMs -gt 0) { $dur = (" ({0:N1}s)" -f ($DurationMs / 1000)) }
    Write-GNOut ($Status + $dur) -Color $col
}

function Invoke-GNInvestigation {
    <#
      Runs a plan of diagnostic steps in order, applies the sequential stop rules,
      explains any step it skipped, then produces and renders the combined verdict.

      This is the engine behind both Beginner troubleshooting and 'Full Diagnostics'.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Plan,
        [hashtable]$Context = @{},
        [hashtable]$TestParams = @{},
        [string]$Focus = 'Reachability',
        [string]$SymptomText = '',
        [switch]$NoVerdict,
        [switch]$Quiet
    )
    $results = New-Object System.Collections.Generic.List[object]
    $stopped = ''
    $softStop = $false
    $softWhitelist = @('OutageScope','VPN','Proxy','Firewall','HostsFile','Services','NetworkStack','CaptivePortal','Latency','PacketLoss','Stability')
    $index = 0
    $total = $Plan.Count
    $runList = @()
    $skippedKeys = @()

    if (-not $Quiet) {
        Write-GNOut ''
        Write-GNOut "  GeeNet Diagnostic Investigation" -Color Cyan
        Write-GNRule '=' 2 ($script:GNW - 4) DarkCyan
        Write-GNOut ''
        Write-GeeNetLog -Message ("Investigation started: plan = " + ($Plan -join ' -> ')) -Level 'STEP'
    }

    foreach ($key in $Plan) {
        $index++
        $info = Get-GNTestInfo -Key $key
        if (-not $info) { continue }
        $remaining = @()
        if ($index -lt $total) { $remaining = @($Plan[($index)..($total-1)] | Where-Object { $_ }) }
        $runList += $key

        # --- respect a soft stop: skip internet-dependent steps but keep context checks
        if ($softStop -and ($softWhitelist -notcontains $key)) {
            $results += New-GNResult -Id $key -Name $info.Name -Layer 'Stack' -Status 'Skip' `
                -Summary "Skipped: an earlier test already proved the likely failure." `
                -SkipReason "GeeNet stopped this test because a previous failure makes it meaningless: $stopped"
            $skippedKeys += $key
            if (-not $Quiet) {
                Write-GNStepLine -Index $index -Total $total -Name $info.Name -Status 'SKIP'
                Write-GNPara -Text "Skipped - an earlier failure already explains this." -Color $script:GNCol.Dim -Indent 6
                Write-GNOut ''
            }
            continue
        }

        # --- run it
        $swStep = [System.Diagnostics.Stopwatch]::StartNew()
        $result = $null
        try {
            $p = @{}
            if ($TestParams -and $TestParams.ContainsKey($key)) { $p = $TestParams[$key] }
            if ($p.Count -gt 0) { $result = & $info.Function @p } else { $result = & $info.Function }
        } catch {
            $result = New-GNResult -Id $key -Name $info.Name -Layer 'Stack' -Status 'Fail' `
                -Summary "This check could not be completed on this computer." `
                -Why "Unexpected errors mean the information was not available, not that the network is broken." `
                -Meaning "GeeNet could not gather this evidence, so treat this one as 'unknown' rather than 'broken'." `
                -NextSteps @('Continue with the remaining checks','If the problem persists, run GeeNet again as Administrator so more checks can read system information') `
                -FixClass 'Manual' -Technical ("The check reported: " + $_.Exception.Message)
        }
        $swStep.Stop()
        if (-not $result) {
            $result = New-GNResult -Id $key -Name $info.Name -Layer 'Stack' -Status 'Info' -Summary "No result was returned by this check."
        }
        if (-not $result.DurationMs -or $result.DurationMs -eq 0) { $result.DurationMs = [int]$swStep.ElapsedMilliseconds }
        $results += $result
        if ($script:GNSession) { [void]$script:GNSession.Results.Add($result) }
        $level = switch ($result.Status) { 'Pass' { 'PASS' } 'Fail' { 'FAIL' } 'Warn' { 'WARN' } 'Skip' { 'SKIP' } default { 'INFO' } }
        [void](Write-GeeNetLog -Message ("{0,-24} {1} - {2}" -f $key, $level, $result.Summary) -Level $level)

        if (-not $Quiet) {
            $statusText = switch ($result.Status) { 'Pass' { 'PASS' } 'Fail' { 'FAIL' } 'Warn' { 'WARN' } 'Skip' { 'SKIP' } default { 'INFO' } }
            Write-GNStepLine -Index $index -Total $total -Name $info.Name -Status $statusText -DurationMs $result.DurationMs
            Write-GNOut ''
            Write-GNResultUnit -Result $result -NoRule
        }

        # --- sequential decision
        if ($result.Status -eq 'Fail' -or $result.Status -eq 'Skip') {
            $decision = Get-GNStopDecision -TestKey $key -Result $result -Remaining $remaining -ResultsSoFar $results
            if ($decision -eq 'Stop') {
                $stopped = Get-GNStopReason -TestKey $key -Result $result
                $stoppedKeys = @()
                if ($index -lt $total) { $stoppedKeys = @($Plan[($index)..($total-1)] | Where-Object { $_ }) }
                foreach ($sk in $stoppedKeys) {
                    $skInfo = Get-GNTestInfo -Key $sk
                    $skName = if ($skInfo) { $skInfo.Name } else { $sk }
                    $skLayer = 'Stack'
                    $skResult = New-GNResult -Id $sk -Name $skName -Layer $skLayer -Status 'Skip' `
                        -Summary "Skipped: a previous failure already proves the likely cause." `
                        -SkipReason $stopped
                    $results += $skResult
                    if ($script:GNSession) { [void]$script:GNSession.Results.Add($skResult) }
                    $skippedKeys += $sk
                }
                if (-not $Quiet) {
                    Write-GNOut ''
                    Write-GNRule '-' 2 ($script:GNW - 4) DarkYellow
                    Write-GNOut ''
                    Write-GNOut "  GeeNet stopped the remaining tests" -Color DarkYellow
                    Write-GNPara -Text $stopped -Color $script:GNCol.Text -Indent 4
                    Write-GNOut ''
                }
                [void](Write-GeeNetLog -Message ("Sequential stop after $key : remaining tests skipped") -Level 'SKIP')
                break
            } elseif ($decision -eq 'StopSoft') {
                $softStop = $true
                $stopped = Get-GNStopReason -TestKey $key -Result $result
                [void](Write-GeeNetLog -Message ("Soft stop after $key : internet-dependent tests will be skipped") -Level 'SKIP')
            }
        }
    }

    $verdict = Get-GNVerdict -Plan $Plan -Results $results -Context $Context -Focus $Focus -SymptomText $SymptomText
    if ($script:GNSession) {
        $script:GNSession.Verdict = $verdict
        $script:GNSession.StoppedReason = $stopped
        $script:GNSession.Findings = New-Object System.Collections.Generic.List[string]
        foreach ($f in Get-GNFindingLines -Results $results) { [void]$script:GNSession.Findings.Add($f) }
    }
    $inv = [pscustomobject]@{
        Focus         = $Focus
        Plan          = $Plan
        Ran           = $runList
        Results       = (Get-GNArray -Items $results)
        StoppedReason = $stopped
        Skipped       = @($skippedKeys)
        Verdict       = $verdict
    }
    if (-not $NoVerdict -and -not $Quiet) { Write-GNVerdict -Verdict $verdict }
    return $inv
}

function Get-GNFindingLines {
    param($Results)
    $Results = Get-GNArray -Items $Results
    $lines = New-Object System.Collections.Generic.List[string]
    $friendly = @{
        'AdapterState'  = @{ Pass='Network adapter working'; Fail='Network adapter problem'; Warn='Network adapter warning' }
        'Wifi'          = @{ Pass='Wi-Fi connected'; Fail='Wi-Fi not connected'; Warn='Wi-Fi signal weak' }
        'Ethernet'      = @{ Pass='Ethernet link up'; Fail='Ethernet link down'; Warn='Ethernet link degraded' }
        'AdapterDriver' = @{ Pass='Adapter driver healthy'; Fail='Adapter driver problem'; Warn='Adapter driver warning' }
        'IPConfig'      = @{ Pass='IP address obtained'; Fail='No usable IP address'; Warn='Unusual IP configuration' }
        'Dhcp'          = @{ Pass='DHCP working'; Fail='DHCP not working'; Warn='Static/manual addressing in use' }
        'Gateway'       = @{ Pass='Router gateway configured'; Fail='No router gateway'; Warn='Multiple gateways detected' }
        'GatewayReach'  = @{ Pass='Router reachable'; Fail='Router unreachable'; Warn='Router not responding to ping' }
        'ARP'           = @{ Pass='Local device table normal'; Fail='Local device table problem'; Warn='Local device table unusual' }
        'Route'         = @{ Pass='Routing table normal'; Fail='No default route'; Warn='Routing conflicts detected' }
        'LocalNetwork'  = @{ Pass='Local network reachable'; Fail='Local network unreachable'; Warn='Local network limited' }
        'LocalHost'     = @{ Pass='Local device reachable'; Fail='Local device unreachable'; Warn='Local device warning' }
        'MTU'           = @{ Pass='Packet size normal'; Fail='Packet size problem'; Warn='Packet size reduced' }
        'InternetIP'    = @{ Pass='Internet reachable (by IP)'; Fail='Internet IP unreachable'; Warn='Internet partially reachable' }
        'CaptivePortal' = @{ Pass='No sign-in page detected'; Fail='Sign-in page blocking access'; Warn='Sign-in page check inconclusive' }
        'DNS'           = @{ Pass='DNS name resolution working'; Fail='DNS name resolution failing'; Warn='DNS resolution slow' }
        'HTTPS'         = @{ Pass='Web (HTTPS) access working'; Fail='Web (HTTPS) access failing'; Warn='Web access partially working' }
        'Latency'       = @{ Pass='Latency normal'; Fail='Latency high'; Warn='Latency above normal' }
        'PacketLoss'    = @{ Pass='No packet loss detected'; Fail='Packet loss detected'; Warn='Some packet loss detected' }
        'Stability'     = @{ Pass='Connection stable during monitoring'; Fail='Connection unstable'; Warn='Occasional dropouts' }
        'Proxy'         = @{ Pass='No proxy configured'; Fail='Proxy configuration blocking traffic'; Warn='Proxy configured' }
        'VPN'           = @{ Pass='No VPN interference'; Fail='VPN/tunnel blocking internet'; Warn='VPN active'; Info='No VPN detected' }
        'Firewall'      = @{ Pass='Firewall normal'; Fail='Firewall problem'; Warn='Firewall disabled for some profiles' }
        'HostsFile'     = @{ Pass='Hosts file clean'; Fail='Hosts file overrides present'; Warn='Hosts file overrides present' }
        'Services'      = @{ Pass='Windows network services running'; Fail='Windows network service stopped'; Warn='Windows service warning' }
        'NetworkStack'  = @{ Pass='Windows network stack healthy'; Fail='Windows network stack problem'; Warn='Windows network stack warning' }
        'AppConnect'    = @{ Pass='Application reachable'; Fail='Application not reachable'; Warn='Application warning'; Skip='Application check skipped' }
        'Website'       = @{ Pass='Website reachable'; Fail='Website not reachable'; Warn='Website problem'; Skip='Website check skipped' }
        'OutageScope'   = @{ Pass='Problem scope known'; Fail='Problem scope'; Warn='Multiple devices affected'; Info='Scope noted' }
    }
    foreach ($r in @($Results)) {
        if (-not $r) { continue }
        $text = $r.Name
        if ($friendly.ContainsKey($r.Id)) {
            $set = $friendly[$r.Id]
            if ($set.ContainsKey($r.Status)) { $text = $set[$r.Status] }
        }
        $mark = switch ($r.Status) { 'Pass' { $script:GNG.Tick } 'Fail' { $script:GNG.Cross } 'Warn' { $script:GNG.Triangle } 'Skip' { $script:GNG.Skip } default { $script:GNG.Info } }
        [void]$lines.Add("$mark  $text")
    }
    return (Get-GNArray -Items $lines)
}

function Write-GNVerdict {
    param($Verdict, [switch]$IncludeEvidence)
    if (-not $Verdict) { return }
    Write-GNOut ''
    Write-GNRule '=' 2 ($script:GNW - 4) Cyan
    Write-GNOut ''
    Write-GNOut "  DIAGNOSIS" -Color Cyan
    Write-GNOut ''
    Write-GNPara -Text $Verdict.Headline -Color White -Indent 4

    if ($IncludeEvidence -and $Verdict.Evidence.Count -gt 0) {
        Write-GNOut ''
        Write-GNOut "  Evidence from the tests" -Color $script:GNCol.Info
        foreach ($e in $Verdict.Evidence) {
            $col = 'Gray'
            if ($e -match '^FAIL') { $col = 'Red' }
            elseif ($e -match '^WARN') { $col = 'DarkYellow' }
            elseif ($e -match '^OK') { $col = 'Green' }
            Write-GNPara -Text $e -Color $col -Indent 6
        }
    }

    Write-GNOut ''
    Write-GNPara -Text $Verdict.Diagnosis -Color $script:GNCol.Text -Indent 4

    if ($Verdict.LikelyCauses.Count -gt 0) {
        Write-GNOut ''
        $causeLabel = "  Most likely cause"
        if ($Verdict.LikelyCauses.Count -gt 1) { $causeLabel = "  Most likely causes" }
        Write-GNOut ($causeLabel + ":") -Color $script:GNCol.Info
        Write-GNList -Items $Verdict.LikelyCauses -Color $script:GNCol.Text -Indent 6
    }

    if ($Verdict.NextSteps.Count -gt 0) {
        Write-GNOut ''
        Write-GNOut "  Recommended next steps:" -Color $script:GNCol.Info
        $i = 1
        foreach ($s in $Verdict.NextSteps) {
            Write-GNPara -Text ("$i. " + $s) -Color $script:GNCol.Action -Indent 6
            $i++
        }
    }

    if ($Verdict.BoundaryNote) {
        Write-GNOut ''
        Write-GNOut "  Where GeeNet stops:" -Color DarkYellow
        Write-GNPara -Text $Verdict.BoundaryNote -Color $script:GNCol.Text -Indent 6
    }

    Write-GNOut ''
    $conf = switch ($Verdict.Confidence) {
        'high'     { 'Confidence: high - the tests point clearly at this layer.' }
        'moderate' { 'Confidence: moderate - this is the most likely explanation, but other causes are possible.' }
        default    { 'Confidence: low - the evidence is not conclusive.' }
    }
    Write-GNPara -Text $conf -Color $script:GNCol.Dim -Indent 4
    Write-GNOut ''
}

function Get-GNQuickSummary {
    <#  One-line status used by menus and reports. #>
    param($Verdict)
    if (-not $Verdict) { return 'No diagnosis available.' }
    switch ($Verdict.Severity) {
        'Pass' { return "Healthy: $($Verdict.Headline)" }
        'Warn' { return "Working, with warnings: $($Verdict.Headline)" }
        default { return "Problem found: $($Verdict.Headline)" }
    }
}

# ------------------------------------------------------------------------------
#region 17. REPAIR ENGINE
# ------------------------------------------------------------------------------
#  Every repair declares:
#    Title / Risk / Admin / Restart  - so GeeNet can tell the user exactly what it does
#    What  - what the repair does, in plain language
#    Why   - when it makes sense
#    Effect- what the user will notice, including disruption
#    Undo  - whether it can be undone
#    Code  - the command(s) actually run (native Windows tools only)
#    Retest- which diagnostics are re-run afterwards to prove whether it worked
#  Nothing here runs without an explicit confirmation from the user.

$script:GNRepairs = [ordered]@{

    'FlushDns' = @{
        Title  = 'Clear the DNS cache'
        Risk   = 'Low'; Admin = $false; Restart = $false
        What   = 'Deletes the list of name-to-address answers Windows has been keeping in memory.'
        Why    = 'A stale or corrupted cache entry can make a website unreachable even though DNS works perfectly.'
        Effect = 'Nothing is disrupted. The next time you open a site, the lookup takes a few milliseconds longer while the cache refills.'
        Undo   = 'Not needed - the cache refills by itself.'
        Retest = @('DNS')
        Code   = @'
ipconfig /flushdns | Out-String
'@
    }

    'RenewDhcp' = @{
        Title  = 'Get a fresh IP address (release and renew)'
        Risk   = 'Low'; Admin = $false; Restart = $false
        What   = 'Gives the current IP address back to the router and asks for a new one.'
        Why    = 'Fixes stale addresses, expired leases, and the very common "our computer got a 169.254 address because the first request failed" case.'
        Effect = 'The connection drops for a few seconds while the address is re-requested. Downloads or calls in progress on this PC would be interrupted.'
        Undo   = 'Not needed - you simply get an address again.'
        Retest = @('IP','DHCP','Gateway','GatewayReach','InternetIP')
        Code   = @'
if ("{adapter}" -ne "") { ipconfig /release "{adapter}" | Out-String } else { ipconfig /release | Out-String }
Start-Sleep -Seconds 1
if ("{adapter}" -ne "") { ipconfig /renew "{adapter}" | Out-String } else { ipconfig /renew | Out-String }
'@
    }

    'RestoreDhcp' = @{
        Title  = 'Set the adapter back to automatic (DHCP) addressing'
        Risk   = 'Moderate'; Admin = $true; Restart = $false
        What   = 'Changes this adapter from a fixed (static) IP address back to "Obtain an IP address automatically", and the same for DNS.'
        Why    = 'A static address that does not match your network is a very common cause of "no internet" or "unidentified network" - especially on laptops that moved between networks.'
        Effect = 'Any intentional static address on this adapter is removed. On a home or office network with a DHCP server this is what you want. On a network that REQUIRES a fixed address you would lose connectivity - do not run this on lab/server setups that need static addressing.'
        Undo   = 'You would need the original static values back. GeeNet prints them before changing anything.'
        Retest = @('IP','DHCP','Gateway','GatewayReach')
        Code   = @'
netsh interface ip set address name="{adapter}" source=dhcp
netsh interface ip set dns name="{adapter}" source=dhcp
'@
    }

    'EnableAdapter' = @{
        Title  = 'Enable the network adapter'
        Risk   = 'Low'; Admin = $true; Restart = $false
        What   = 'Switches the adapter back on in Windows (the same as right-clicking Enable in Network Connections).'
        Why    = 'A disabled adapter carries no traffic at all - this is a harmless, instant fix when that is the cause.'
        Effect = 'The adapter re-enables and reconnects. Wi-Fi may take a few seconds to reconnect to your network.'
        Undo   = 'You can disable it again in Network Connections if you prefer.'
        Retest = @('Adapter','IP','GatewayReach')
        Code   = @'
Enable-NetAdapter -Name "{adapter}" -Confirm:$false | Out-String
'@
    }

    'RestartAdapter' = @{
        Title  = 'Restart (bounce) the network adapter'
        Risk   = 'Moderate'; Admin = $true; Restart = $false
        What   = 'Disables and re-enables the adapter, forcing Windows to reload its driver and reconnect.'
        Why    = 'Clears driver-level stuck states, stale link states, and "connected but nothing passes" conditions - one of the most effective client-side fixes.'
        Effect = 'The connection drops for about 5 seconds while the adapter restarts. Anything using the network on this PC is briefly interrupted.'
        Undo   = 'Not needed - the adapter comes back automatically.'
        Retest = @('Adapter','IP','GatewayReach','InternetIP')
        Code   = @'
Disable-NetAdapter -Name "{adapter}" -Confirm:$false | Out-String
Start-Sleep -Seconds 4
Enable-NetAdapter -Name "{adapter}" -Confirm:$false | Out-String
Start-Sleep -Seconds 4
Get-NetAdapter -Name "{adapter}" | Select-Object Name,Status,LinkSpeed | Format-List | Out-String
'@
    }

    'ReconnectWifi' = @{
        Title  = 'Reconnect the Wi-Fi connection'
        Risk   = 'Low'; Admin = $false; Restart = $false
        What   = 'Disconnects from the wireless network and connects to your saved profile again.'
        Why    = 'Fixes a half-connected or stale Wi-Fi session, and re-runs the address request with a clean link.'
        Effect = 'Wi-Fi drops for a few seconds. If the saved password or profile is broken, you may need to re-enter the password yourself.'
        Undo   = 'None needed.'
        Retest = @('WiFi','IP','GatewayReach','InternetIP')
        Code   = @'
netsh wlan disconnect | Out-String
Start-Sleep -Seconds 2
if ("{profile}" -ne "") { netsh wlan connect name="{profile}" | Out-String } else { netsh wlan connect | Out-String }
Start-Sleep -Seconds 5
netsh wlan show interfaces | Out-String
'@
    }

    'RestartWlanService' = @{
        Title  = 'Restart the Wi-Fi service (WLAN AutoConfig)'
        Risk   = 'Low'; Admin = $true; Restart = $false
        What   = 'Restarts the Windows service that manages Wi-Fi connections and networks.'
        Why    = 'If the service is stuck, Windows can stop showing networks, refuse to connect, or stay disconnected after sleep.'
        Effect = 'Wi-Fi disconnects briefly and reconnects. Network list is rebuilt.'
        Undo   = 'None needed.'
        Retest = @('WiFi','Adapter')
        Code   = @'
Restart-Service -Name WlanSvc -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 4
Get-Service -Name WlanSvc | Select-Object Name,Status | Format-List | Out-String
netsh wlan show interfaces | Out-String
'@
    }

    'ForgetProfile' = @{
        Title  = 'Forget the saved Wi-Fi network'
        Risk   = 'High'; Admin = $false; Restart = $false
        What   = 'Deletes the saved Wi-Fi profile (network name and stored password) for this network from this computer.'
        Why    = 'Useful only when the saved profile is corrupted - the classic sign is "the password is definitely correct but it will not connect".'
        Effect = 'You WILL need to select the network again and type the Wi-Fi password by hand. If you do not know the password, do not run this.'
        Undo   = 'No automatic undo - you re-enter the password (or the network gets re-saved when you connect).'
        Retest = @('WiFi','IP')
        Code   = @'
if ("{profile}" -ne "") { netsh wlan delete profile name="{profile}" | Out-String } else { Write-Output "No saved profile name was detected - delete the profile from Settings > Network > Wi-Fi > Manage known networks." }
'@
    }

    'SetPublicDns' = @{
        Title  = 'Use reliable public DNS servers (1.1.1.1 and 8.8.8.8)'
        Risk   = 'Moderate'; Admin = $true; Restart = $false
        What   = 'Points this adapter at Cloudflare (1.1.1.1) and Google (8.8.8.8) for name resolution instead of whatever it uses now.'
        Why    = 'When the DNS server you are given (usually the router, or a leftover from an old network or VPN) is failing, this restores name resolution immediately.'
        Effect = 'Names resolve through Cloudflare/Google. Note this bypasses any filtering your router or ISP applies through DNS (some parents/offices want that filtering), and on a corporate network you should normally use the company DNS instead.'
        Undo   = 'Easily reversible: GeeNet can switch the adapter back to automatic DNS.'
        Retest = @('DNS','HTTPS')
        Code   = @'
if (Get-Command Set-DnsClientServerAddress -ErrorAction SilentlyContinue) {
    Set-DnsClientServerAddress -InterfaceAlias "{adapter}" -ServerAddresses ("1.1.1.1","8.8.8.8")
    Get-DnsClientServerAddress -InterfaceAlias "{adapter}" -AddressFamily IPv4 | Select-Object InterfaceAlias,ServerAddresses | Format-List | Out-String
} else {
    netsh interface ip set dns name="{adapter}" static 1.1.1.1 primary
    netsh interface ip add dns name="{adapter}" 8.8.8.8 index=2
}
ipconfig /flushdns | Out-String
'@
    }

    'ResetDnsAutomatic' = @{
        Title  = 'Switch DNS back to automatic (from the router)'
        Risk   = 'Low'; Admin = $true; Restart = $false
        What   = 'Removes manual DNS servers from this adapter so Windows uses the DNS servers handed out by the network.'
        Why    = 'Use this to undo a manual DNS change (or a leftover VPN DNS setting).'
        Effect = 'DNS returns to whatever your router/network provides. Names keep working normally.'
        Undo   = 'You can set manual DNS again at any time.'
        Retest = @('DNS')
        Code   = @'
netsh interface ip set dns name="{adapter}" source=dhcp
ipconfig /flushdns | Out-String
'@
    }

    'DisableProxy' = @{
        Title  = 'Disable the system proxy settings'
        Risk   = 'Moderate'; Admin = $true; Restart = $false
        What   = 'Turns off the Windows/browser proxy setting and removes any automatic proxy (PAC) URL, and resets the WinHTTP proxy.'
        Why    = 'A proxy left behind by a VPN, security tool, or malware is a classic cause of "connected but nothing loads" - and it is easy to remove when you are not on a network that requires one.'
        Effect = 'Browsers and apps stop using the proxy. On a work network that REQUIRES a proxy, internet access would stop working - in that case ask IT for the correct proxy address instead of removing it.'
        Undo   = 'The previous proxy values can be re-entered in Settings > Network & Internet > Proxy.'
        Retest = @('Proxy','HTTPS')
        Code   = @'
$k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$old = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
if ($old) {
    Write-Output ("Previous proxy value: ProxyEnable=" + $old.ProxyEnable + " ProxyServer=" + $old.ProxyServer + " AutoConfigURL=" + $old.AutoConfigURL)
}
Set-ItemProperty -Path $k -Name ProxyEnable -Value 0 -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $k -Name AutoConfigURL -ErrorAction SilentlyContinue
netsh winhttp reset proxy | Out-String
'@
    }

    'ResetWinHttpProxy' = @{
        Title  = 'Reset the WinHTTP proxy configuration'
        Risk   = 'Low'; Admin = $true; Restart = $false
        What   = 'Removes proxy settings used by Windows itself and by services (not just browsers).'
        Why    = 'Fix for apps that fail to reach the internet while browsers work, or the reverse.'
        Effect = 'Windows services connect directly again.'
        Undo   = 'Proxy can be set again if your network requires it.'
        Retest = @('Proxy','HTTPS')
        Code   = @'
netsh winhttp reset proxy | Out-String
'@
    }

    'ClearArpCache' = @{
        Title  = 'Clear the local device (ARP) cache'
        Risk   = 'Low'; Admin = $true; Restart = $false
        What   = 'Empties the table of hardware addresses this computer has learned about local devices.'
        Why    = 'Clears stale or wrong hardware-address entries - used when the router or another device on the LAN cannot be reached or appears duplicated.'
        Effect = 'The table rebuilds within seconds with no noticeable interruption.'
        Undo   = 'None needed.'
        Retest = @('ARP','GatewayReach')
        Code   = @'
netsh interface ip delete arpcache | Out-String
Start-Sleep -Seconds 2
Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count | Out-String
'@
    }

    'WinsockReset' = @{
        Title  = 'Reset the Winsock catalogue'
        Risk   = 'Moderate'; Admin = $true; Restart = $true
        What   = 'Restores the Windows list of network providers (the "socket" layer) to its default state.'
        Why    = 'Fixes socket-level corruption caused by badly uninstalled VPN/proxy/security products and by some malware cleanups.'
        Effect = 'Needs a RESTART to take effect. After restarting, any VPN or proxy tool may need to reinstall its entries. This is a known, standard repair, but it is not something to run "just in case".'
        Undo   = 'The change is permanent in the sense that third-party socket providers are removed and must be reinstalled by their own software.'
        Retest = @('NetworkStack','DNS','HTTPS')
        Code   = @'
netsh winsock reset | Out-String
'@
    }

    'TcpIpReset' = @{
        Title  = 'Reset the TCP/IP stack'
        Risk   = 'Moderate'; Admin = $true; Restart = $true
        What   = 'Rewrites the TCP/IP configuration registry keys back to Windows defaults.'
        Why    = 'Fixes a damaged or heavily modified TCP/IP configuration (a classic last-step client-side repair).'
        Effect = 'Needs a RESTART. Static IP addresses, custom DNS entries and custom routes are removed - the adapter goes back to automatic settings after the restart.'
        Undo   = 'Manual settings would have to be re-applied after the restart.'
        Retest = @('NetworkStack','IP','DNS')
        Code   = @'
netsh int ip reset | Out-String
'@
    }

    'EnableIpv4' = @{
        Title  = 'Turn IPv4 back on for the adapter'
        Risk   = 'Moderate'; Admin = $true; Restart = $false
        What   = 'Re-binds (ticks) Internet Protocol Version 4 in the adapter properties.'
        Why    = 'If IPv4 has been switched off for an adapter, no normal internet traffic can work at all.'
        Effect = 'IPv4 is enabled; the adapter re-reads its address settings.'
        Undo   = 'Can be unticked again in adapter properties.'
        Retest = @('NetworkStack','IP','GatewayReach')
        Code   = @'
Enable-NetAdapterBinding -Name "{adapter}" -ComponentID ms_tcpip -ErrorAction SilentlyContinue | Out-String
Get-NetAdapterBinding -Name "{adapter}" -ComponentID ms_tcpip | Select-Object Name,DisplayName,Enabled | Format-List | Out-String
'@
    }

    'StartNetworkServices' = @{
        Title  = 'Start stopped Windows network services'
        Risk   = 'Low'; Admin = $true; Restart = $false
        What   = 'Starts the key Windows network services if they are stopped (DHCP Client, DNS Client, Network Location Awareness, Network List, WLAN AutoConfig and related).'
        Why    = 'Stopped services break address assignment, name resolution and Wi-Fi in ways that look like a network outage.'
        Effect = 'No disruption - services simply start. Windows may briefly re-evaluate the network profile.'
        Undo   = 'Not needed.'
        Retest = @('Services','IP','DNS','WiFi')
        Code   = @'
$targets = 'Dhcp','Dnscache','NlaSvc','netprofm','nsi','DPS','NcaSvc','WinHttpAutoProxySvc','WlanSvc'
foreach ($t in $targets) {
    $svc = Get-Service -Name $t -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
    if ($svc.Status -ne 'Running') {
        Write-Output ("Starting " + $t + " (was " + $svc.Status + ")")
        try { Set-Service -Name $t -StartupType Automatic -ErrorAction SilentlyContinue } catch { }
        try { Start-Service -Name $t -ErrorAction SilentlyContinue } catch { }
    }
}
Get-Service -Name $targets -ErrorAction SilentlyContinue | Select-Object Name,Status | Format-Table -AutoSize | Out-String
'@
    }

    'DisableAdapterPowerSave' = @{
        Title  = 'Stop Windows switching off the adapter to save power'
        Risk   = 'Moderate'; Admin = $true; Restart = $false
        What   = 'Turns off power management on the network adapter (the "Allow the computer to turn off this device to save power" setting).'
        Why    = 'Power saving is a well-known cause of random dropouts, especially on laptops - the adapter sleeps and the connection dies for no visible reason.'
        Effect = 'Very slightly higher power use; the adapter no longer sleeps. No disruption.'
        Undo   = 'Re-enable in Device Manager > adapter > Power Management.'
        Retest = @('Stability','Adapter')
        Code   = @'
$pm = Get-NetAdapterPowerManagement -Name "{adapter}" -ErrorAction SilentlyContinue
if ($pm) { $pm | Disable-NetAdapterPowerManagement -Confirm:$false -ErrorAction SilentlyContinue | Out-String } else { Write-Output "Power management settings are not available for this adapter." }
Get-NetAdapterPowerManagement -Name "{adapter}" -ErrorAction SilentlyContinue | Format-List | Out-String
'@
    }

    'RegisterDns' = @{
        Title  = 'Re-register this computer''s DNS name'
        Risk   = 'Low'; Admin = $true; Restart = $false
        What   = 'Asks Windows to refresh its own DNS registration with the network.'
        Why    = 'Useful on domain/office networks where this computer''s name does not resolve for other machines.'
        Effect = 'No disruption.'
        Undo   = 'None needed.'
        Retest = @('DNS')
        Code   = @'
ipconfig /registerdns | Out-String
'@
    }

    'CleanHostsFile' = @{
        Title  = 'Disable the suspicious hosts-file entries'
        Risk   = 'Moderate'; Admin = $true; Restart = $false
        What   = 'Backs up the Windows hosts file and comments out entries that block or redirect websites (lines starting with 0.0.0.0, 127.0.0.1 or ::1).'
        Why    = 'These entries override DNS for specific names, which is exactly how one website can fail while everything else works.'
        Effect = 'Sites blocked by those entries become reachable again. If the entries were added on purpose (ad-blocking or parental control), that protection stops working.'
        Undo   = 'A backup is saved next to the file as hosts.geenet.bak, and disabled lines start with "# GeeNet".'
        Retest = @('HostsFile','Website')
        Code   = @'
$f = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
if (Test-Path $f) {
    Copy-Item -Path $f -Destination ($f + '.geenet.bak') -Force -ErrorAction SilentlyContinue
    $lines = Get-Content -Path $f -ErrorAction SilentlyContinue
    $out = foreach ($l in $lines) {
        if ($l -match '^\s*(0\.0\.0\.0|127\.0\.0\.1|::1)\s' -and $l -notmatch '^\s*#') { '# GeeNet disabled: ' + $l } else { $l }
    }
    Set-Content -Path $f -Value $out -Encoding ASCII
    Write-Output ("Backup written to " + $f + ".geenet.bak")
}
'@
    }

    'NetworkReset' = @{
        Title  = 'Windows network reset (last resort)'
        Risk   = 'High'; Admin = $true; Restart = $true
        What   = 'Resets Winsock, TCP/IP and the IPv4/IPv6 interface configuration back to Windows defaults.'
        Why    = 'This is the heavy hammer for a genuinely damaged network stack, after the lighter repairs have failed.'
        Effect = 'A RESTART is required. All network adapters are re-installed by Windows, and every saved network setting (static IPs, manual DNS, custom routes, VPN/proxy entries, saved Wi-Fi passwords in some cases) is lost. On a work or school computer that uses specific network settings, do not run this without checking with IT.'
        Undo   = 'No automatic undo. Settings must be re-entered by hand afterwards.'
        Retest = @('NetworkStack','Adapter','IP','DNS')
        Code   = @'
netsh winsock reset | Out-String
netsh int ip reset | Out-String
netsh interface ipv4 reset | Out-String
netsh interface ipv6 reset | Out-String
'@
    }
}

function Get-GNRepair {
    param([string]$Id)
    # Backwards compatibility: older verdict logic and outside callers may use a phrase
    # rather than a repair key. Map the known ones so nothing ever degrades to "unknown".
    $legacyMap = @{
        'RestartNetworkServices' = 'StartNetworkServices'
        'RestartWlan'            = 'RestartWlanService'
        'RestartDhcp'            = 'RenewDhcp'
        'ResetWinsock'           = 'WinsockReset'
        'ResetTcpIp'             = 'TcpIpReset'
        'ForgetWifiProfile'      = 'ForgetProfile'
        'ReconnectWiFi'          = 'ReconnectWifi'
        'DisablePowerSave'       = 'DisableAdapterPowerSave'
    }
    if ($Id -and $legacyMap.ContainsKey($Id)) { $Id = $legacyMap[$Id] }
    if ($script:GNRepairs.Contains($Id)) {
        $def = $script:GNRepairs[$Id]
        return [pscustomobject]@{
            Id      = $Id
            Title   = $def.Title
            Risk    = $def.Risk
            Admin   = [bool]$def.Admin
            Restart = [bool]$def.Restart
            What    = $def.What
            Why     = $def.Why
            Effect  = $def.Effect
            Undo    = $def.Undo
            Retest  = @($def.Retest)
            Code    = $def.Code
        }
    }
    return $null
}

function Get-GNRiskBadge {
    param([string]$Risk)
    switch ($Risk) {
        'Low'      { return 'LOW RISK - safe and reversible' }
        'Moderate' { return 'MODERATE - changes settings (explained below)' }
        'High'     { return 'HIGH IMPACT - disruptive or hard to undo' }
        default    { return $Risk }
    }
}

function Resolve-GNRepairContext {
    <#  Works out which adapter / Wi-Fi profile the repair should target. #>
    $ctx = @{ Adapter = ''; Profile = ''; AdapterKind = '' }
    $active = Get-GNActiveAdapter
    if ($active) {
        $ctx.Adapter = "$($active.Adapter.Name)"
        $ctx.AdapterKind = if ($active.Adapter.IsWifi) { 'Wi-Fi' } else { 'Ethernet' }
    }
    try {
        $w = Get-GNWifiInfo
        if ($w.Profile) { $ctx.Profile = "$($w.Profile)" }
        elseif ($w.SSID) { $ctx.Profile = "$($w.SSID)" }
    } catch { }
    return $ctx
}

function Show-GNRepairPreview {
    param($Repair)
    Write-GNOut ''
    Write-GNRule '=' 2 ($script:GNW - 4) Magenta
    Write-GNOut ''
    Write-GNOut ("  REPAIR: " + $Repair.Title) -Color White
    $badgeCol = switch ($Repair.Risk) { 'Low' { 'Green' } 'Moderate' { 'DarkYellow' } default { 'Red' } }
    Write-GNPara -Text (Get-GNRiskBadge -Risk $Repair.Risk) -Color $badgeCol -Indent 4
    if ($Repair.Admin) {
        Write-GNPara -Text "Administrator rights: required" -Color DarkYellow -Indent 4
    } else {
        Write-GNPara -Text "Administrator rights: not required" -Color DarkGray -Indent 4
    }
    if ($Repair.Restart) { Write-GNPara -Text "A restart is required afterwards." -Color DarkYellow -Indent 4 }
    Write-GNOut ''
    Write-GNOut "  What it does:" -Color $script:GNCol.Info
    Write-GNPara -Text $Repair.What -Color $script:GNCol.Text -Indent 6
    Write-GNOut ''
    Write-GNOut "  Why it can help:" -Color $script:GNCol.Info
    Write-GNPara -Text $Repair.Why -Color $script:GNCol.Text -Indent 6
    Write-GNOut ''
    Write-GNOut "  What you will notice:" -Color $script:GNCol.Info
    Write-GNPara -Text $Repair.Effect -Color $script:GNCol.Text -Indent 6
    Write-GNOut ''
    Write-GNOut "  Undo:" -Color $script:GNCol.Info
    Write-GNPara -Text $Repair.Undo -Color $script:GNCol.Text -Indent 6
    Write-GNOut ''
}

function Invoke-GNRepairCode {
    <#  Runs the repair commands, either here or in an elevated window, and reports the truth. #>
    param(
        [string]$Code,
        [bool]$NeedsAdmin,
        [switch]$AutoApprove
    )
    $r = [pscustomobject]@{ Ran = $false; Elevated = $false; Success = $false; Output = ''; ExitCode = $null; Error = '' }
    if ($NeedsAdmin -and -not (Test-GeeNetAdmin)) {
        if ($AutoApprove) {
            $r.Error = 'Administrator rights are required and automatic elevation is disabled.'
            return $r
        }
        Write-GNOut ''
        Write-GNOut "  This repair needs Administrator rights." -Color DarkYellow
        Write-GNPara -Text "GeeNet can open a single elevated Windows prompt that runs just this repair, then come back. You will see the standard Windows User Account Control (UAC) prompt." -Color $script:GNCol.Text -Indent 4
        $ok = Read-GNConfirm -Prompt "  Run this repair with Administrator rights now?" -DefaultYes $true
        if (-not $ok) {
            $r.Error = 'User chose not to elevate. The repair was not attempted.'
            return $r
        }
        $elev = Invoke-GeeNetElevated -Command $Code -WaitSeconds 180
        $r.Ran = $elev.Attempted
        $r.Elevated = $elev.Elevated
        $r.Success = $elev.Success
        $r.Output = "$($elev.Output)"
        $r.ExitCode = $elev.ExitCode
        if (-not $elev.Elevated) { $r.Error = "$($elev.Output)" }
        return $r
    }

    try {
        $sb = [scriptblock]::Create($Code)
        $output = & $sb 2>&1 | Out-String
        $r.Ran = $true
        $r.Success = $true
        $r.ExitCode = $LASTEXITCODE
        if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) { $r.Success = $false }
        $r.Output = "$output"
        if ($output -match 'Access is denied|requires elevation|Requested operation requires elevation') {
            $r.Success = $false
            $r.Error = 'Windows denied the operation (access denied).'
        }
    } catch {
        $r.Ran = $true
        $r.Success = $false
        $r.Error = $_.Exception.Message
        $r.Output = "$($_.Exception.Message)"
    }
    return $r
}

function Invoke-GNRetest {
    <#
      Re-runs the diagnostics that matter after a repair and reports the change honestly.
      beforeMap: test key -> previous status
    #>
    param(
        [string[]]$TestKeys,
        [hashtable]$Before = @{},
        [switch]$Quiet
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($key in @($TestKeys)) {
        $info = Get-GNTestInfo -Key $key
        if (-not $info) { continue }
        $result = $null
        try { $result = & $info.Function } catch { $result = $null }
        if (-not $result) { continue }
        # NOTE: this variable must not be called $before - PowerShell is case-insensitive,
        # so it would collide with the [hashtable]$Before parameter and fail the assignment.
        $statusBefore = if ($Before.ContainsKey($key)) { "$($Before[$key])" } else { '' }
        $statusAfter = "$($result.Status)"
        $improved = switch ($statusAfter) {
            'Pass' { if ($statusBefore -eq 'Pass') { 'same' } else { 'improved' } }
            'Warn' { if ($statusBefore -eq 'Fail') { 'improved' } elseif ($statusBefore -eq 'Warn') { 'same' } else { 'worse' } }
            'Skip' { 'unknown' }
            'Fail' { if ($statusBefore -eq 'Fail') { 'same' } else { 'worse' } }
            default { 'same' }
        }
        [void]$rows.Add([pscustomobject]@{
            Key = $key; Name = $info.Name; Before = $statusBefore; After = $statusAfter; Change = $improved; Result = $result
        })
        if ($script:GNSession) { [void]$script:GNSession.Results.Add($result) }
    }
    if (-not $Quiet -and $rows.Count -gt 0) {
        Write-GNOut ''
        Write-GNOut "  Re-test results" -Color Cyan
        Write-GNRule '-' 2 60 DarkCyan
        foreach ($row in $rows) {
            $col = switch ($row.After) { 'Pass' { 'Green' } 'Fail' { 'Red' } 'Warn' { 'DarkYellow' } default { 'DarkGray' } }
            $arrow = switch ($row.Change) {
                'improved' { 'now working (was ' + $row.Before + ')' }
                'worse'    { 'now failing (was ' + $row.Before + ')' }
                'same'     { 'unchanged (' + $row.After + ')' }
                default    { 'unknown' }
            }
            Write-GNOut ("  " + $row.Name.PadRight(30).Substring(0,30) + " ") -Color $script:GNCol.Bright -NoNewline
            Write-GNOut ("$($row.After) - $arrow") -Color $col
        }
        Write-GNOut ''
    }
    $improvedCount = @(Get-GNArray -Items $rows | Where-Object { $_.Change -eq 'improved' }).Count
    return [pscustomobject]@{ Rows = (Get-GNArray -Items $rows); Improved = ($improvedCount -gt 0); ImprovedCount = $improvedCount }
}

function Invoke-GNRepairFlow {
    <#
      The complete, honest repair cycle:
        explain -> confirm -> (elevate) -> run -> retest -> report
      Never claims success it did not verify.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [hashtable]$Before = @{},
        [switch]$AutoApprove,
        [switch]$SkipRetest
    )
    $repair = Get-GNRepair -Id $Id
    if (-not $repair) {
        Write-GNOut "  Unknown repair: $Id" -Color Red
        return $null
    }
    $ctx = Resolve-GNRepairContext
    $code = $repair.Code.Replace('{adapter}', "$($ctx.Adapter)").Replace('{profile}', "$($ctx.Profile)")

    Show-GNRepairPreview -Repair $repair
    if ($repair.Id -in @('ReconnectWifi','ForgetProfile') -and -not $ctx.Profile) {
        Write-GNWarn "GeeNet could not detect a saved Wi-Fi profile name, so this repair may need to be done by hand (Settings > Network & Internet > Wi-Fi)."
        Write-GNOut ''
    }
    if ($repair.Id -eq 'RestoreDhcp') {
        $cur = Get-GNActiveAdapter
        if ($cur -and $cur.Config -and $cur.Config.IPv4) {
            Write-GNOut "  Current settings that would be replaced:" -Color DarkYellow
            Write-GNPara -Text "Adapter '$($cur.Config.Adapter)': IP $($cur.Config.IPv4) / $($cur.Config.SubnetMask), gateway '$($cur.Config.Gateway)', DNS $(@($cur.Config.DnsServers) -join ', ')" -Color $script:GNCol.Text -Indent 4
            Write-GNOut ''
        }
    }

    $defaultYes = ($repair.Risk -eq 'Low')
    $proceed = $true
    if (-not $AutoApprove) {
        $proceed = Read-GNConfirm -Prompt "  Run this repair?" -DefaultYes $defaultYes
    }
    if (-not $proceed) {
        Write-GNOut ''
        Write-GNPara -Text "Repair not run. Nothing on your computer was changed." -Color $script:GNCol.Dim -Indent 4
        if ($script:GNSession) {
            [void]$script:GNSession.Repairs.Add([pscustomobject]@{
                Id = $Id; Title = $repair.Title; Attempted = $false; Success = $false
                Note = 'User declined'; Time = (Get-Date).ToString('HH:mm:ss')
            })
        }
        return $null
    }

    Write-GeeNetLog -Message ("Repair requested: $($repair.Title) ($Id)") -Level 'ACTION'
    Write-GNOut ''
    Write-GNOut "  Running: $($repair.Title) ..." -Color Cyan
    $exec = Invoke-GNRepairCode -Code $code -NeedsAdmin $repair.Admin -AutoApprove:$AutoApprove

    if (-not $exec.Ran -and $exec.Error) {
        Write-GNOut ''
        Write-GNWarn $exec.Error
        Write-GNPara -Text "GeeNet did NOT change anything and will not pretend the repair ran." -Color $script:GNCol.Text -Indent 4
        if ($script:GNSession) {
            [void]$script:GNSession.Repairs.Add([pscustomobject]@{
                Id = $Id; Title = $repair.Title; Attempted = $false; Success = $false
                Note = $exec.Error; Time = (Get-Date).ToString('HH:mm:ss')
            })
        }
        return [pscustomobject]@{ Repair = $Id; Ran = $false; Success = $false; Output = ''; Retest = $null }
    }

    if ($exec.Output) {
        Write-GNOut ''
        Write-GNOut "  Output reported by Windows:" -Color DarkGray
        foreach ($line in ("$($exec.Output)" -split "`r?`n")) {
            if ($line.Trim().Length -eq 0) { continue }
            Write-GNPara -Text ($line.Trim()) -Color $script:GNCol.Tech -Indent 6
        }
    }

    $okText = if ($exec.Success) { 'completed with no error reported by Windows.' } else { 'reported an error or was refused by Windows - it may not have taken effect.' }
    Write-GNOut ''
    Write-GNPara -Text ("Repair $okText") -Color $(if ($exec.Success) { 'Green' } else { 'Red' }) -Indent 4

    $retest = $null
    $resolved = $false
    if (-not $SkipRetest) {
        Write-GNOut ''
        Write-GNOut "  Re-testing the affected checks ..." -Color Cyan
        $retest = Invoke-GNRetest -TestKeys $repair.Retest -Before $Before
        $resolved = ($retest.ImprovedCount -gt 0)
    }

    if ($script:GNSession) {
        [void]$script:GNSession.Repairs.Add([pscustomobject]@{
            Id = $Id; Title = $repair.Title; Attempted = $true; Success = [bool]$exec.Success
            Elevated = [bool]$exec.Elevated
            Note = if ($exec.Success) { 'Executed' } else { "$($exec.Error)" }
            RetestImproved = $resolved
            Time = (Get-Date).ToString('HH:mm:ss')
        })
    }
    [void](Write-GeeNetLog -Message ("Repair $Id executed: success=$($exec.Success), retest-improved=$resolved") -Level 'ACTION')

    Write-GNOut ''
    if ($resolved) {
        Write-GNPara -Text "Good news: the re-test now looks better than it did before the repair." -Color Green -Indent 4
    } elseif ($exec.Success) {
        Write-GNPara -Text "The repair ran, but the re-test did not improve. GeeNet is not going to claim this fixed anything - the cause is elsewhere." -Color DarkYellow -Indent 4
    }
    if ($repair.Restart) {
        Write-GNPara -Text "Remember: this repair only takes full effect after you restart Windows." -Color DarkYellow -Indent 4
    }

    return [pscustomobject]@{
        Repair = $Id; Ran = $true; Success = [bool]$exec.Success
        Output = "$($exec.Output)"; Retest = $retest; Improved = $resolved
    }
}

function Repair-ScenarioAction {
    <#  Name-compatible helper: run a named repair by id. #>
    param([string]$Id, [hashtable]$Before = @{})
    return Invoke-GNRepairFlow -Id $Id -Before $Before
}

function Get-GNStatusMap {
    param($Results)
    $m = @{}
    foreach ($r in (Get-GNArray -Items $Results)) { if ($r -and $r.Id) { $m[$r.Id] = $r.Status } }
    return $m
}

# ------------------------------------------------------------------------------
#region 18. EXTRA TESTS USED BY SPECIFIC SCENARIOS
# ------------------------------------------------------------------------------

function Test-WiFiScan {
    <#  What can this computer actually see? Answers 'my network is not in the list'. #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $info = Get-GNWifiInfo
    $visible = @()
    $raw = ''
    try {
        $out = Invoke-GNNative -File 'netsh' -Arguments @('wlan','show','networks','mode=bssid') -TimeoutSec 20
        $raw = "$($out.Output)"
        $current = $null
        foreach ($line in ($raw -split "`r?`n")) {
            $t = $line.Trim()
            if ($t -match '^SSID\s+\d+\s*:\s*(.*)$') {
                if ($current) { $visible += $current }
                $current = [pscustomobject]@{ SSID = "$($Matches[1])".Trim(); Signal = ''; Channel = ''; Band = ''; Auth = '' }
            } elseif ($current -and $t -match '^Signal\s*:\s*(.+)$') { $current.Signal = "$($Matches[1])".Trim() }
            elseif ($current -and $t -match '^Channel\s*:\s*(.+)$') {
                $current.Channel = "$($Matches[1])".Trim()
                $chNum = 0
                [void][int]::TryParse($current.Channel, [ref]$chNum)
                if ($chNum -ge 1 -and $chNum -le 14) { $current.Band = '2.4 GHz' }
                elseif ($chNum -ge 32) { $current.Band = '5 GHz' }
            } elseif ($current -and $t -match '^Authentication\s*:\s*(.+)$') { $current.Auth = "$($Matches[1])".Trim() }
        }
        if ($current) { $visible += $current }
    } catch { }
    $profiles = @(Get-GNWifiProfiles)
    $professional = @($profiles | Where-Object { $_ })
    $visibleNames = @($visible | ForEach-Object { $_.SSID } | Where-Object { $_ })
    $savedVisible = @($professional | Where-Object { $visibleNames -contains $_ })
    $sw.Stop()

    $data = @{
        VisibleCount   = $visible.Count
        Visible         = @($visible | ForEach-Object { "$($_.SSID) [$($_.Signal)] $($_.Band) ch $($_.Channel)" })
        SavedProfiles  = @($professional)
        SavedVisible   = @($savedVisible)
        ConnectedSsid  = "$($info.SSID)"
        WifiPresent    = $info.Present
        RadioError     = "$($info.Error)"
    }

    if ($visible.Count -eq 0) {
        return New-GNResult -Id 'WiFiScan' -Name 'Nearby Wi-Fi networks check' -Layer 'Link' -Status 'Fail' `
            -Summary "This computer cannot see ANY Wi-Fi networks right now." `
            -Why "If no networks are visible at all (not even your neighbours'), the problem is the Wi-Fi radio or driver on this computer - not your router." `
            -Meaning "Either the wireless radio is off, the WLAN service is stopped, or the Wi-Fi driver is not working." `
            -Causes @('Wi-Fi switched off, or airplane mode enabled','WLAN AutoConfig service stopped','Wi-Fi driver failed or needs reinstalling','Physical Wi-Fi switch or keyboard function key (F2/F8/F12) turned radios off','Region/regulatory setting blocking the radio after a driver change') `
            -NextSteps @('Turn Wi-Fi on from the taskbar, and check airplane mode is off','Try the Wi-Fi function key on the keyboard','Restart the WLAN AutoConfig service (GeeNet can do it)','If the adapter is enabled but sees nothing, the driver needs reinstalling or updating') `
            -FixClass 'SafeAuto' `
            -Technical "netsh wlan show networks returned no SSIDs. $($info.Error)" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    if ($professional.Count -gt 0 -and $savedVisible.Count -eq 0) {
        return New-GNResult -Id 'WiFiScan' -Name 'Nearby Wi-Fi networks check' -Layer 'Link' -Status 'Warn' `
            -Summary "This computer sees $($visible.Count) Wi-Fi network(s), but none of your saved networks are in range." `
            -Why "Windows connects automatically to networks you have saved before - it cannot do that if the network is out of range or switched off." `
            -Meaning "Your saved network ($($professional -join ', ')) is not currently visible, which means it is out of range, its router is off, or it is using 5 GHz only and you are too far away." `
            -Causes @('The router/access point is switched off or restarting','Out of range - the network does not reach this location','5 GHz-only network that does not reach this far (5 GHz has shorter range than 2.4 GHz)','The network is hidden (SSID broadcast disabled)') `
            -NextSteps @('Move closer to the router and re-scan','Check the router is powered on','If the network is hidden, connect manually by typing the name','If your phone sees it but this PC does not, the difference is this PC''s Wi-Fi adapter or driver') `
            -FixClass 'Manual' `
            -Technical "Visible: $($data.Visible -join ' | '). Saved profiles: $($professional -join ', ')." `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    $connectedNote = if ($data.ConnectedSsid) { " Currently connected to '$($data.ConnectedSsid)'." } else { '' }
    return New-GNResult -Id 'WiFiScan' -Name 'Nearby Wi-Fi networks check' -Layer 'Link' -Status 'Pass' `
        -Summary "This computer can see $($visible.Count) Wi-Fi network(s), including your saved network(s).$connectedNote" `
        -Why "Seeing networks proves the Wi-Fi radio and driver are working, so the fault is not the wireless hardware." `
        -Meaning "Your Wi-Fi hardware works and can see the networks you expect, so any problem is in connecting, addressing, or further along the network." `
        -Technical "Visible: $($data.Visible -join ' | '). Saved profiles: $($professional -join ', ')." `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

function Test-BandwidthHogs {
    <#  Is something on this PC eating the connection? Explains 'slow when many apps are open'. #>
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $conns = @(Get-GNTcpConnections)
    $established = @($conns | Where-Object { "$($_.State)" -match 'Established' })
    $byProcess = @($established | Group-Object OwningProcess | Sort-Object Count -Descending | Select-Object -First 6)
    $rows = @()
    foreach ($g in $byProcess) {
        $pname = 'PID ' + $g.Name
        try {
            $p = Get-Process -Id ([int]$g.Name) -ErrorAction SilentlyContinue
            if ($p) { $pname = $p.ProcessName }
        } catch { }
        $rows += [pscustomobject]@{ Process = $pname; Connections = $g.Count }
    }
    $bulkable = @('steam','steamwebhelper','utorrent','qbittorrent','transmission','bittorrent','aria2','onedrive','dropbox','googledrivefs','backblaze','wetransfer','thunder','idm','msedge','chrome','firefox','teams','zoom','discord','spotify')
    $running = @()
    foreach ($n in $bulkable) {
        try {
            $p = Get-Process -Name $n -ErrorAction SilentlyContinue
            if ($p) { $running += $n }
        } catch { }
    }
    $sw.Stop()

    $data = @{
        Established  = $established.Count
        TopProcesses = @(Get-GNArray -Items $rows | ForEach-Object { "$($_.Process) ($($_.Connections) connections)" })
        RunningApps  = @($running)
    }

    $heavy = @(Get-GNArray -Items $rows | Where-Object { $_.Connections -ge 40 })
    if ($heavy.Count -gt 0 -or $running.Count -ge 3) {
        return New-GNResult -Id 'BandwidthHogs' -Name 'Bandwidth usage check' -Layer 'App' -Status 'Warn' `
            -Summary "Applications are holding many network connections: $($data.TopProcesses -join ', ')." `
            -Why "Background applications can consume the whole connection without you noticing, which shows up as 'the internet is slow'." `
            -Meaning "This is likely to be a load problem rather than a fault: the connection may be perfectly capable, just busy. Many simultaneous connections can also saturate a home router's connection table." `
            -Causes @('Downloads, updates or cloud sync running in the background','Streaming, gaming launchers or video calls','A torrent client seeding in the background','Windows Update / Delivery Optimization sharing updates with other PCs') `
            -NextSteps @('Pause downloads, cloud sync and launchers, then re-test speed','Check whether Windows Update was busy around the time the problem happened','If the slowdown happens whenever these apps run, limit their background activity or schedule it overnight','Compare with them closed to confirm they are the cause') `
            -FixClass 'Manual' `
            -Technical "Established connections: $($established.Count). Top: $($data.TopProcesses -join ' | '). Notable apps running: $($data.RunningApps -join ', ')" `
            -Data $data -DurationMs $sw.ElapsedMilliseconds
    }

    return New-GNResult -Id 'BandwidthHogs' -Name 'Bandwidth usage check' -Layer 'App' -Status 'Pass' `
        -Summary "No heavy bandwidth usage detected from background applications ($($data.Established) active connections)." `
        -Why "It is worth ruling out your own applications before blaming the connection." `
        -Meaning "Nothing on this computer is obviously saturating the link right now, so slowness is more likely to come from the connection itself." `
        -Technical "Established connections: $($established.Count). Top: $($data.TopProcesses -join ' | ')" `
        -Data $data -DurationMs $sw.ElapsedMilliseconds
}

# ------------------------------------------------------------------------------
#region 19. CANONICAL TEST ORDER + QUESTION DEFINITIONS
# ------------------------------------------------------------------------------

# The order GeeNet reasons in: physical link -> adapter -> Windows stack -> IP -> local -> internet -> DNS -> web -> app
$script:GNPlanOrder = @(
    'Adapter','WiFi','WiFiScan','Ethernet','Driver','Services','NetworkStack',
    'IP','DHCP','Gateway','Route','ARP','GatewayReach','LocalNetwork','LocalHost',
    'CaptivePortal','MTU','VPN','InternetIP','DNS','Proxy','HTTPS','Website','AppConnect',
    'HostsFile','Firewall','BandwidthHogs','Latency','PacketLoss','Stability','OutageScope'
)

function Sort-GNPlan {
    <#  Puts a merged plan back into the canonical diagnostic order (stable). #>
    param([string[]]$Plan)
    $clean = @($Plan | Where-Object { $_ } | Select-Object -Unique)
    $indexed = @()
    for ($i = 0; $i -lt $clean.Count; $i++) {
        $order = [array]::IndexOf($script:GNPlanOrder, $clean[$i])
        if ($order -lt 0) { $order = 500 + $i }
        $indexed += [pscustomobject]@{ Key = $clean[$i]; Order = $order; Seq = $i }
    }
    return @($indexed | Sort-Object Order, Seq | ForEach-Object { $_.Key })
}

$script:GNQuestions = [ordered]@{

    'Scope' = @{
        Id = 'Scope'; Type = 'Choice'
        Prompt = 'Are other devices on this network (like your phone, still on the Wi-Fi) able to get internet right now?'
        Options = @(
            @{ Key = 'ThisPcOnly';     Label = 'Yes - other devices work, only this computer fails' }
            @{ Key = 'OtherDevicesToo'; Label = 'No - other devices have no internet either' }
            @{ Key = 'NotSure';        Label = 'I am not sure / I have not checked' }
        )
        ContextKey = 'OutageScope'
        TestKey = 'OutageScope'; TestParam = 'Answer'
        Why = 'This one answer decides whether GeeNet should look inside this computer or at the router/ISP.'
    }

    'ConnType' = @{
        Id = 'ConnType'; Type = 'Choice'
        Prompt = 'How is this computer connected to the network?'
        Options = @(
            @{ Key = 'WiFi';     Label = 'Wi-Fi (wireless)' }
            @{ Key = 'Ethernet'; Label = 'Ethernet cable' }
            @{ Key = 'NotSure';  Label = 'Not sure' }
        )
        ContextKey = 'ConnectionType'
        Why = 'Wi-Fi and cable problems are different, so knowing the connection type focuses the checks.'
    }

    'RecentChange' = @{
        Id = 'RecentChange'; Type = 'Choice'
        Prompt = 'Did anything change around the time the problem started?'
        Options = @(
            @{ Key = 'None';          Label = 'Nothing I know of' }
            @{ Key = 'WindowsUpdate'; Label = 'A Windows or driver update' }
            @{ Key = 'VpnInstall';    Label = 'I installed or changed a VPN' }
            @{ Key = 'DnsChange';     Label = 'I changed DNS settings' }
            @{ Key = 'StaticIp';      Label = 'I set a manual/static IP address' }
            @{ Key = 'SettingsPoke';  Label = 'I changed something else in network settings' }
            @{ Key = 'Other';         Label = 'Something else (new router, moved house, new ISP)' }
        )
        ContextKey = 'RecentChange'
        Why = 'Knowing what changed usually points straight at the cause.'
    }

    'AppWhich' = @{
        Id = 'AppWhich'; Type = 'Choice'
        Prompt = 'Which application is having trouble connecting?'
        Dynamic = 'Apps'
        TestKey = 'AppConnect'; TestParam = 'ProfileKey'
        ContextKey = 'AppChoice'
        Why = 'Testing the application''s own service separates an app problem from a connection problem.'
    }

    'AppHost' = @{
        Id = 'AppHost'; Type = 'Text'
        Prompt = 'Type the address the application uses (for example server.company.com)'
        TestKey = 'AppConnect'; TestParam = 'HostName'
        Why = 'GeeNet will test that exact address.'
    }

    'Domain' = @{
        Id = 'Domain'; Type = 'Text'
        Prompt = 'Which website is the problem? (for example example.com)'
        TestKey = 'Website'; TestParam = 'Domain'
        ContextKey = 'Domain'
        Why = 'GeeNet will test that exact website: name lookup, connection and the web request itself.'
    }

    'LanTarget' = @{
        Id = 'LanTarget'; Type = 'Text'
        Prompt = 'What is the name or IP address of the device you cannot reach? (for example 192.168.1.10 or nas)'
        TestKey = 'LocalHost'; TestParam = 'Target'
        Why = 'GeeNet will test that device directly instead of guessing what it is.'
    }

    'StabilityTime' = @{
        Id = 'StabilityTime'; Type = 'Choice'
        Prompt = 'How long should GeeNet watch the connection for dropouts?'
        Options = @(
            @{ Key = '30';  Label = '30 seconds (quick check)' }
            @{ Key = '60';  Label = '1 minute (recommended)' }
            @{ Key = '120'; Label = '2 minutes (catch rarer dropouts)' }
        )
        TestKey = 'Stability'; TestParam = 'Seconds'
        Why = 'Intermittent faults only show up when you watch the connection for a while.'
    }
}

# Recovery hints: when an answer points at a change, add the checks that prove it.
$script:GNPlanByAnswer = @{
    'RecentChange' = @{
        'WindowsUpdate' = @('Driver','WiFi','Ethernet','NetworkStack')
        'VpnInstall'    = @('VPN','Route','Proxy','DNS')
        'DnsChange'     = @('DNS','HostsFile','Proxy')
        'StaticIp'      = @('IP','DHCP','Route','Gateway')
        'SettingsPoke'  = @('IP','DHCP','DNS','Route','Proxy','NetworkStack')
        'Other'         = @('Gateway','GatewayReach','Adapter','DHCP')
    }
    'ConnType' = @{
        'WiFi'     = @('WiFi','WiFiScan')
        'Ethernet' = @('Ethernet')
        'NotSure'  = @('WiFi','Ethernet')
    }
}

function Get-GNQuestion {
    param([string]$Id)
    if ($script:GNQuestions.Contains($Id)) { return $script:GNQuestions[$Id] }
    return $null
}

function Get-GNAppQuestionOptions {
    <#  Builds the application list for the 'which application?' question from the profile table. #>
    $opts = @()
    $i = 1
    foreach ($p in $script:GNAppProfiles) {
        $opts += @{ Key = "$($p.Key)"; Label = "$($p.Name)" }
        $i++
    }
    $opts += @{ Key = 'other'; Label = 'Something else (I will type the address)' }
    return $opts
}

# ------------------------------------------------------------------------------
#region 20. SCENARIO LIBRARY (data-driven - add new scenarios here, no other code changes)
# ------------------------------------------------------------------------------
#  Scenario fields:
#    Id        unique id (prefixed by category)
#    Cat       category id
#    Text      what the user would say - written in plain, real-world language
#    Plan      ordered diagnostic keys (auto-sorted into canonical order)
#    Focus     'Reachability' | 'Slowness' | 'Stability' | 'Dns' | 'Local' | 'App' | 'Windows'
#    Questions extra questions that genuinely change the diagnostic path
#    Preset    context values that are already known from the wording of the scenario
#    Note      optional clarifying line shown before the investigation

$script:GNCategories = @(
    @{ Id='internet';  Number=1;  Title='Internet connection problems';      Blurb='Connected but no internet, or the internet stopped working.' }
    @{ Id='wifi';      Number=2;  Title='Wi-Fi problems';                    Blurb='Networks missing, cannot connect, keeps dropping, weak signal.' }
    @{ Id='ethernet';  Number=3;  Title='Ethernet / wired problems';         Blurb='Cable not detected, no link, wired connection problems.' }
    @{ Id='ipdhcp';    Number=4;  Title='IP address / DHCP problems';        Blurb='No address, 169.254 address, gateway missing, conflicts.' }
    @{ Id='dns';       Number=5;  Title='DNS / website name problems';       Blurb='Names do not resolve, pages do not open, DNS is slow.' }
    @{ Id='router';    Number=6;  Title='Router / local network symptoms';   Blurb='Router unreachable, ISP, other devices - find out whose fault it is.' }
    @{ Id='slow';      Number=7;  Title='Slow internet';                     Blurb='Slow downloads, slow pages, high ping, busy connections.' }
    @{ Id='stability'; Number=8;  Title='Connection stability / packet loss';Blurb='Random dropouts, freezing calls, lag in games.' }
    @{ Id='apps';      Number=9;  Title='Website / application problems';    Blurb='One site or one app will not connect.' }
    @{ Id='vpn';       Number=10; Title='VPN / proxy problems';              Blurb='VPN breaks the internet, proxy settings interfering.' }
    @{ Id='windows';   Number=11; Title='Windows network settings';          Blurb='Stack, Winsock, services, resets, settings screens.' }
    @{ Id='adapter';   Number=12; Title='Network adapter / driver problems'; Blurb='Adapter disabled, missing, erroring, or failing later.' }
    @{ Id='lan';       Number=13; Title='Local network / LAN problems';      Blurb='Other computers, shared folders, local servers, ARP, routes.' }
    @{ Id='advanced';  Number=14; Title='Symptoms from a change you made';   Blurb='"It worked yesterday", "I installed a VPN", "I changed settings".' }
    @{ Id='notsure';   Number=15; Title='Something else / I am not sure';    Blurb='Let GeeNet work out what is wrong for you.' }
)

$script:GNScenarios = @(

    # ---------------------------------------------------------------- INTERNET
    @{ Id='INT-01'; Cat='internet'; Text="I can't connect to the internet at all"; Focus='Reachability'
       Plan=@('Adapter','WiFi','Ethernet','IP','DHCP','Gateway','GatewayReach','InternetIP','CaptivePortal','DNS','HTTPS','OutageScope'); Questions=@('Scope') }
    @{ Id='INT-02'; Cat='internet'; Text="My computer says 'No Internet' even though it is connected"; Focus='Reachability'
       Plan=@('Adapter','IP','DHCP','Gateway','GatewayReach','InternetIP','CaptivePortal','DNS','HTTPS','OutageScope'); Questions=@('Scope') }
    @{ Id='INT-03'; Cat='internet'; Text='My Wi-Fi is connected but there is no internet'; Focus='Reachability'
       Plan=@('Adapter','WiFi','IP','DHCP','Gateway','GatewayReach','InternetIP','CaptivePortal','DNS','HTTPS','OutageScope'); Questions=@('Scope') }
    @{ Id='INT-04'; Cat='internet'; Text='My Ethernet is connected but there is no internet'; Focus='Reachability'
       Plan=@('Adapter','Ethernet','IP','DHCP','Gateway','GatewayReach','InternetIP','CaptivePortal','DNS','HTTPS','OutageScope'); Questions=@('Scope') }
    @{ Id='INT-05'; Cat='internet'; Text='The internet suddenly stopped working'; Focus='Reachability'
       Plan=@('Adapter','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS','HTTPS'); Questions=@('RecentChange','Scope') }
    @{ Id='INT-06'; Cat='internet'; Text='The internet worked earlier today but stopped'; Focus='Reachability'
       Plan=@('Adapter','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS','HTTPS','Stability'); Questions=@('RecentChange','Scope','StabilityTime') }
    @{ Id='INT-07'; Cat='internet'; Text='My phone has internet but this computer does not'; Focus='Reachability'
       Preset=@{ OutageScope='ThisPcOnly' }
       Plan=@('Adapter','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS','HTTPS','Proxy','VPN','Firewall','HostsFile') }
    @{ Id='INT-08'; Cat='internet'; Text='Only this computer has no internet'; Focus='Reachability'
       Preset=@{ OutageScope='ThisPcOnly' }
       Plan=@('Adapter','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS','HTTPS','Proxy','VPN') }
    @{ Id='INT-09'; Cat='internet'; Text="The internet is connected but websites don't load"; Focus='Dns'
       Plan=@('Adapter','IP','GatewayReach','InternetIP','CaptivePortal','DNS','Proxy','HTTPS') }
    @{ Id='INT-10'; Cat='internet'; Text="Some websites work but others don't"; Focus='Dns'
       Plan=@('InternetIP','CaptivePortal','DNS','Proxy','HTTPS','HostsFile','Website'); Questions=@('Domain') }
    @{ Id='INT-11'; Cat='internet'; Text='The internet connection keeps disconnecting'; Focus='Stability'
       Plan=@('Adapter','WiFi','Ethernet','IP','GatewayReach','InternetIP','PacketLoss','Stability'); Questions=@('StabilityTime','Scope') }
    @{ Id='INT-12'; Cat='internet'; Text='The internet works for a few minutes and then stops'; Focus='Stability'
       Plan=@('Adapter','IP','DHCP','GatewayReach','InternetIP','PacketLoss','Stability'); Questions=@('StabilityTime') }
    @{ Id='INT-13'; Cat='internet'; Text='The internet is extremely slow'; Focus='Slowness'
       Plan=@('Adapter','WiFi','Ethernet','IP','GatewayReach','InternetIP','Latency','PacketLoss','BandwidthHogs','DNS') }
    @{ Id='INT-14'; Cat='internet'; Text='The internet is slow only on this computer'; Focus='Slowness'
       Preset=@{ OutageScope='ThisPcOnly' }
       Plan=@('Adapter','WiFi','Ethernet','GatewayReach','InternetIP','Latency','PacketLoss','BandwidthHogs','DNS','Proxy') }
    @{ Id='INT-15'; Cat='internet'; Text='The internet is slow at certain times of day'; Focus='Slowness'
       Plan=@('InternetIP','Latency','PacketLoss','Stability','BandwidthHogs'); Questions=@('StabilityTime') }
    @{ Id='INT-16'; Cat='internet'; Text='The connection drops randomly and comes back'; Focus='Stability'
       Plan=@('Adapter','WiFi','Ethernet','GatewayReach','InternetIP','PacketLoss','Stability'); Questions=@('StabilityTime') }
    @{ Id='INT-17'; Cat='internet'; Text="Windows says I have a 'Limited' connection"; Focus='Reachability'
       Plan=@('Adapter','IP','DHCP','Gateway','CaptivePortal','GatewayReach','InternetIP','DNS') }
    @{ Id='INT-18'; Cat='internet'; Text="Windows says 'No Internet, Secured'"; Focus='Reachability'
       Plan=@('Adapter','WiFi','IP','DHCP','GatewayReach','CaptivePortal','InternetIP','DNS','HTTPS') }
    @{ Id='INT-19'; Cat='internet'; Text="Windows says 'Unidentified Network'"; Focus='Reachability'
       Plan=@('Adapter','IP','DHCP','Gateway','Route','ARP','GatewayReach','InternetIP') }

    # ------------------------------------------------------------------ WI-FI
    @{ Id='WIFI-01'; Cat='wifi'; Text='Wi-Fi networks are not showing at all'; Focus='Local'
       Plan=@('Adapter','WiFi','WiFiScan','Services','Driver') }
    @{ Id='WIFI-02'; Cat='wifi'; Text='My Wi-Fi adapter is missing'; Focus='Local'
       Plan=@('Adapter','WiFi','Driver') }
    @{ Id='WIFI-03'; Cat='wifi'; Text='Wi-Fi cannot be turned on'; Focus='Local'
       Plan=@('WiFi','Adapter','Services','Driver') }
    @{ Id='WIFI-04'; Cat='wifi'; Text='My Wi-Fi keeps disconnecting'; Focus='Stability'
       Plan=@('Adapter','WiFi','DHCP','GatewayReach','PacketLoss','Stability'); Questions=@('StabilityTime') }
    @{ Id='WIFI-05'; Cat='wifi'; Text='I cannot connect to my Wi-Fi network'; Focus='Local'
       Plan=@('Adapter','WiFi','WiFiScan','Services','IP','DHCP','GatewayReach') }
    @{ Id='WIFI-06'; Cat='wifi'; Text='It says my Wi-Fi password is wrong'; Focus='Local'
       Plan=@('WiFi','WiFiScan','Adapter') }
    @{ Id='WIFI-07'; Cat='wifi'; Text='The Wi-Fi password is definitely correct but the connection fails'; Focus='Local'
       Plan=@('WiFi','WiFiScan','Adapter','IP','GatewayReach'); Note='The saved Wi-Fi profile may be corrupted. GeeNet will confirm the adapter and radio are fine before suggesting anything drastic.' }
    @{ Id='WIFI-08'; Cat='wifi'; Text='Wi-Fi connects and then immediately disconnects'; Focus='Stability'
       Plan=@('Adapter','WiFi','DHCP','IP','GatewayReach','Stability'); Questions=@('StabilityTime') }
    @{ Id='WIFI-09'; Cat='wifi'; Text='Wi-Fi is connected but has no internet'; Focus='Reachability'
       Preset=@{ ConnectionType='WiFi' }
       Plan=@('Adapter','WiFi','IP','DHCP','Gateway','GatewayReach','InternetIP','CaptivePortal','DNS','HTTPS'); Questions=@('Scope') }
    @{ Id='WIFI-10'; Cat='wifi'; Text='My Wi-Fi signal is very weak'; Focus='Slowness'
       Plan=@('WiFi','WiFiScan','Latency','PacketLoss') }
    @{ Id='WIFI-11'; Cat='wifi'; Text='The Wi-Fi signal keeps changing or dropping bars'; Focus='Stability'
       Plan=@('WiFi','WiFiScan','PacketLoss','Stability'); Questions=@('StabilityTime') }
    @{ Id='WIFI-12'; Cat='wifi'; Text='My computer cannot see one specific Wi-Fi network'; Focus='Local'
       Plan=@('WiFi','WiFiScan','Driver','Adapter') }
    @{ Id='WIFI-13'; Cat='wifi'; Text='Other devices can see the Wi-Fi but this PC cannot'; Focus='Local'
       Plan=@('Adapter','WiFi','WiFiScan','Driver','Services') }
    @{ Id='WIFI-14'; Cat='wifi'; Text='Wi-Fi stopped working after a Windows update'; Focus='Windows'
       Preset=@{ RecentChange='WindowsUpdate' }
       Plan=@('Adapter','Driver','WiFi','WiFiScan','Services','IP') }
    @{ Id='WIFI-15'; Cat='wifi'; Text='My Wi-Fi adapter shows as disabled'; Focus='Local'
       Plan=@('WiFi','Adapter','Driver') }
    @{ Id='WIFI-16'; Cat='wifi'; Text='I think airplane mode is interfering'; Focus='Local'
       Plan=@('WiFi','Adapter','Services') }
    @{ Id='WIFI-17'; Cat='wifi'; Text='Windows keeps asking me for the Wi-Fi password again'; Focus='Local'
       Plan=@('WiFi','WiFiScan','Driver','Adapter') }
    @{ Id='WIFI-18'; Cat='wifi'; Text='My phone is fast on this Wi-Fi but this laptop is slow'; Focus='Slowness'
       Preset=@{ OutageScope='ThisPcOnly' }
       Plan=@('WiFi','WiFiScan','Latency','PacketLoss','BandwidthHogs','DNS') }

    # -------------------------------------------------------------- ETHERNET
    @{ Id='ETH-01'; Cat='ethernet'; Text='The Ethernet cable is connected but there is no internet'; Focus='Reachability'
       Preset=@{ ConnectionType='Ethernet' }
       Plan=@('Adapter','Ethernet','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS','HTTPS'); Questions=@('Scope') }
    @{ Id='ETH-02'; Cat='ethernet'; Text='My Ethernet cable is not detected'; Focus='Local'
       Plan=@('Adapter','Ethernet','Driver') }
    @{ Id='ETH-03'; Cat='ethernet'; Text='It says the network cable is unplugged'; Focus='Local'
       Plan=@('Ethernet','Adapter','Driver') }
    @{ Id='ETH-04'; Cat='ethernet'; Text='Ethernet works on another computer but not this one'; Focus='Local'
       Plan=@('Ethernet','Adapter','Driver','IP','DHCP','GatewayReach') }
    @{ Id='ETH-05'; Cat='ethernet'; Text='My Ethernet adapter is disabled'; Focus='Local'
       Plan=@('Ethernet','Adapter','Driver') }
    @{ Id='ETH-06'; Cat='ethernet'; Text='Ethernet has no IP address'; Focus='Reachability'
       Plan=@('Ethernet','IP','DHCP','Services','GatewayReach') }
    @{ Id='ETH-07'; Cat='ethernet'; Text='Ethernet shows a 169.254 address'; Focus='Reachability'
       Plan=@('Ethernet','IP','DHCP','GatewayReach') }
    @{ Id='ETH-08'; Cat='ethernet'; Text='Ethernet connects but I cannot access the network'; Focus='Local'
       Plan=@('Ethernet','IP','GatewayReach','ARP','Route','LocalNetwork') }
    @{ Id='ETH-09'; Cat='ethernet'; Text='My wired connection keeps dropping'; Focus='Stability'
       Plan=@('Ethernet','Adapter','GatewayReach','PacketLoss','Stability'); Questions=@('StabilityTime') }
    @{ Id='ETH-10'; Cat='ethernet'; Text='Ethernet suddenly stopped working'; Focus='Local'
       Plan=@('Ethernet','Adapter','Driver','IP','DHCP'); Questions=@('RecentChange') }
    @{ Id='ETH-11'; Cat='ethernet'; Text='I think there is a network adapter driver problem'; Focus='Windows'
       Plan=@('Driver','Adapter','Ethernet','WiFi') }

    # ----------------------------------------------------------------- IP / DHCP
    @{ Id='IP-01'; Cat='ipdhcp'; Text='My computer has no IP address'; Focus='Reachability'
       Plan=@('Adapter','IP','DHCP','Services','GatewayReach') }
    @{ Id='IP-02'; Cat='ipdhcp'; Text='My computer has a 169.254.x.x address'; Focus='Reachability'
       Plan=@('Adapter','IP','DHCP','Services','GatewayReach') }
    @{ Id='IP-03'; Cat='ipdhcp'; Text='DHCP is not giving my computer an address'; Focus='Reachability'
       Plan=@('IP','DHCP','Services','Adapter','Gateway') }
    @{ Id='IP-04'; Cat='ipdhcp'; Text='My IP address looks wrong'; Focus='Reachability'
       Plan=@('Adapter','IP','DHCP','Route','ARP') }
    @{ Id='IP-05'; Cat='ipdhcp'; Text='The default gateway is missing'; Focus='Reachability'
       Plan=@('IP','Gateway','Route','DHCP') }
    @{ Id='IP-06'; Cat='ipdhcp'; Text='I have several network adapters and I am confused which is used'; Focus='Local'
       Plan=@('Adapter','Route','Gateway','IP','VPN') }
    @{ Id='IP-07'; Cat='ipdhcp'; Text='I think there is an IP address conflict'; Focus='Local'
       Plan=@('IP','ARP','Route','DHCP') }
    @{ Id='IP-08'; Cat='ipdhcp'; Text='My computer cannot obtain an IP address'; Focus='Reachability'
       Plan=@('Adapter','IP','DHCP','Services','GatewayReach') }
    @{ Id='IP-09'; Cat='ipdhcp'; Text='Renewing the IP address fails'; Focus='Windows'
       Plan=@('IP','DHCP','Services','NetworkStack','Adapter') }
    @{ Id='IP-10'; Cat='ipdhcp'; Text='Network worked before but DHCP stopped working'; Focus='Reachability'
       Plan=@('IP','DHCP','Gateway','Services','Adapter') }
    @{ Id='IP-11'; Cat='ipdhcp'; Text='A static IP address may be configured incorrectly'; Focus='Reachability'
       Plan=@('IP','DHCP','Gateway','Route'); Questions=@('RecentChange') }

    # -------------------------------------------------------------------- DNS
    @{ Id='DNS-01'; Cat='dns'; Text="The internet works but websites don't open"; Focus='Dns'
       Plan=@('IP','GatewayReach','InternetIP','DNS','Proxy','HTTPS','HostsFile') }
    @{ Id='DNS-02'; Cat='dns'; Text='I can ping 1.1.1.1 but not google.com'; Focus='Dns'
       Plan=@('InternetIP','DNS','HostsFile','Proxy') }
    @{ Id='DNS-03'; Cat='dns'; Text='Websites cannot be found'; Focus='Dns'
       Plan=@('IP','InternetIP','DNS','HTTPS','HostsFile') }
    @{ Id='DNS-04'; Cat='dns'; Text='DNS lookup fails'; Focus='Dns'
       Plan=@('DNS','HostsFile','Services','InternetIP') }
    @{ Id='DNS-05'; Cat='dns'; Text="Some websites work while others don't (name problems)"; Focus='Dns'
       Plan=@('InternetIP','DNS','HostsFile','Proxy','Website'); Questions=@('Domain') }
    @{ Id='DNS-06'; Cat='dns'; Text='DNS is very slow - pages hang before loading'; Focus='Slowness'
       Plan=@('DNS','Latency','PacketLoss','InternetIP') }
    @{ Id='DNS-07'; Cat='dns'; Text='I think my DNS cache is corrupted'; Focus='Dns'
       Plan=@('DNS','HostsFile') }
    @{ Id='DNS-08'; Cat='dns'; Text='The DNS server may be unavailable'; Focus='Dns'
       Plan=@('GatewayReach','InternetIP','DNS','Proxy') }
    @{ Id='DNS-09'; Cat='dns'; Text='My computer may be using an invalid DNS server'; Focus='Dns'
       Plan=@('IP','DNS','Proxy','VPN') }
    @{ Id='DNS-10'; Cat='dns'; Text="Domain names don't resolve but IP addresses work"; Focus='Dns'
       Plan=@('InternetIP','DNS','HostsFile','HTTPS') }

    # ----------------------------------------------------------------- ROUTER
    @{ Id='RT-01'; Cat='router'; Text="I can't reach my router at all"; Focus='Local'
       Plan=@('Adapter','IP','Gateway','GatewayReach','ARP','Route') }
    @{ Id='RT-02'; Cat='router'; Text='The gateway ping fails'; Focus='Local'
       Plan=@('Gateway','GatewayReach','ARP','Route','IP') }
    @{ Id='RT-03'; Cat='router'; Text='My computer sees the Wi-Fi but cannot reach the router'; Focus='Local'
       Plan=@('WiFi','IP','DHCP','GatewayReach','ARP') }
    @{ Id='RT-04'; Cat='router'; Text='My computer cannot communicate with the local network'; Focus='Local'
       Plan=@('Adapter','IP','GatewayReach','ARP','LocalNetwork') }
    @{ Id='RT-05'; Cat='router'; Text='The gateway is missing from my configuration'; Focus='Reachability'
       Plan=@('IP','Gateway','Route','DHCP') }
    @{ Id='RT-06'; Cat='router'; Text='The router is powered on but my PC cannot reach it'; Focus='Local'
       Plan=@('Adapter','IP','GatewayReach','ARP','Route') }
    @{ Id='RT-07'; Cat='router'; Text='The network works for other devices but not this PC'; Focus='Reachability'
       Preset=@{ OutageScope='ThisPcOnly' }
       Plan=@('Adapter','IP','DHCP','GatewayReach','ARP','DNS','Proxy','VPN','HostsFile') }
    @{ Id='RT-08'; Cat='router'; Text='The router is on but the computer has no internet'; Focus='Reachability'
       Plan=@('Adapter','IP','GatewayReach','InternetIP','DNS','CaptivePortal'); Questions=@('Scope') }
    @{ Id='RT-09'; Cat='router'; Text='Other devices have internet but this PC does not'; Focus='Reachability'
       Preset=@{ OutageScope='ThisPcOnly' }
       Plan=@('Adapter','IP','DHCP','GatewayReach','InternetIP','DNS','Proxy','VPN') }
    @{ Id='RT-10'; Cat='router'; Text='No devices have internet - the whole network is down'; Focus='Reachability'
       Preset=@{ OutageScope='OtherDevicesToo' }
       Plan=@('Adapter','IP','GatewayReach','InternetIP','DNS') }
    @{ Id='RT-11'; Cat='router'; Text='The router is reachable but there is no internet'; Focus='Reachability'
       Plan=@('GatewayReach','InternetIP','CaptivePortal','DNS','HTTPS') }
    @{ Id='RT-12'; Cat='router'; Text='The router cannot be reached and the internet light looks wrong'; Focus='Local'
       Plan=@('IP','Gateway','GatewayReach','ARP','InternetIP') }
    @{ Id='RT-13'; Cat='router'; Text='I think my ISP may be down'; Focus='Reachability'
       Plan=@('IP','GatewayReach','InternetIP','DNS','CaptivePortal'); Questions=@('Scope') }
    @{ Id='RT-14'; Cat='router'; Text='The connection works directly but not through the router'; Focus='Local'
       Plan=@('GatewayReach','InternetIP','DNS','MTU','Proxy','VPN') }

    # -------------------------------------------------------------------- SLOW
    @{ Id='SLOW-01'; Cat='slow'; Text='The internet is generally slow'; Focus='Slowness'
       Plan=@('Adapter','IP','GatewayReach','InternetIP','Latency','PacketLoss','BandwidthHogs') }
    @{ Id='SLOW-02'; Cat='slow'; Text='Only this computer is slow'; Focus='Slowness'
       Preset=@{ OutageScope='ThisPcOnly' }
       Plan=@('Adapter','WiFi','Ethernet','GatewayReach','InternetIP','Latency','PacketLoss','BandwidthHogs','Proxy','DNS') }
    @{ Id='SLOW-03'; Cat='slow'; Text='Downloads are slow'; Focus='Slowness'
       Plan=@('Adapter','GatewayReach','InternetIP','Latency','PacketLoss','MTU','BandwidthHogs') }
    @{ Id='SLOW-04'; Cat='slow'; Text='Websites load slowly'; Focus='Slowness'
       Plan=@('InternetIP','DNS','HTTPS','Latency','Proxy') }
    @{ Id='SLOW-05'; Cat='slow'; Text='It becomes slow when I have many applications open'; Focus='Slowness'
       Plan=@('InternetIP','Latency','PacketLoss','BandwidthHogs') }
    @{ Id='SLOW-06'; Cat='slow'; Text='High ping / latency'; Focus='Slowness'
       Plan=@('GatewayReach','InternetIP','Latency','PacketLoss') }
    @{ Id='SLOW-07'; Cat='slow'; Text='Packet loss on my connection'; Focus='Stability'
       Plan=@('Adapter','GatewayReach','InternetIP','PacketLoss','Stability'); Questions=@('StabilityTime') }
    @{ Id='SLOW-08'; Cat='slow'; Text='My Wi-Fi signal is weak so the connection is slow'; Focus='Slowness'
       Plan=@('WiFi','WiFiScan','Latency','PacketLoss') }
    @{ Id='SLOW-09'; Cat='slow'; Text='Background applications may be using my bandwidth'; Focus='Slowness'
       Plan=@('InternetIP','Latency','BandwidthHogs','PacketLoss') }

    # --------------------------------------------------------------- STABILITY
    @{ Id='STAB-01'; Cat='stability'; Text='The internet keeps dropping'; Focus='Stability'
       Plan=@('Adapter','WiFi','Ethernet','IP','GatewayReach','InternetIP','PacketLoss','Stability'); Questions=@('StabilityTime','Scope') }
    @{ Id='STAB-02'; Cat='stability'; Text='Ping randomly fails'; Focus='Stability'
       Plan=@('GatewayReach','InternetIP','PacketLoss','Stability'); Questions=@('StabilityTime') }
    @{ Id='STAB-03'; Cat='stability'; Text='My ping is very high'; Focus='Slowness'
       Plan=@('GatewayReach','InternetIP','Latency','PacketLoss') }
    @{ Id='STAB-04'; Cat='stability'; Text='I am seeing packet loss'; Focus='Stability'
       Plan=@('GatewayReach','InternetIP','PacketLoss','Stability'); Questions=@('StabilityTime') }
    @{ Id='STAB-05'; Cat='stability'; Text='The connection works intermittently'; Focus='Stability'
       Plan=@('Adapter','WiFi','Ethernet','GatewayReach','InternetIP','PacketLoss','Stability'); Questions=@('StabilityTime') }
    @{ Id='STAB-06'; Cat='stability'; Text='The gateway ping randomly fails'; Focus='Local'
       Plan=@('GatewayReach','ARP','PacketLoss','Stability'); Questions=@('StabilityTime') }
    @{ Id='STAB-07'; Cat='stability'; Text='Ping to the internet randomly fails but the router is fine'; Focus='Stability'
       Plan=@('GatewayReach','InternetIP','PacketLoss','Stability'); Questions=@('StabilityTime') }
    @{ Id='STAB-08'; Cat='stability'; Text='The connection drops during gaming'; Focus='Stability'
       Plan=@('Adapter','GatewayReach','InternetIP','Latency','PacketLoss','Stability'); Questions=@('StabilityTime') }
    @{ Id='STAB-09'; Cat='stability'; Text='Video calls keep freezing'; Focus='Stability'
       Plan=@('Adapter','GatewayReach','InternetIP','Latency','PacketLoss','Stability'); Questions=@('StabilityTime') }
    @{ Id='STAB-10'; Cat='stability'; Text='Remote Desktop keeps disconnecting'; Focus='Stability'
       Plan=@('GatewayReach','InternetIP','Latency','PacketLoss','MTU','Stability'); Questions=@('StabilityTime') }

    # -------------------------------------------------------------------- APPS
    @{ Id='APP-01'; Cat='apps'; Text='My browser cannot open websites'; Focus='App'
       Plan=@('InternetIP','DNS','Proxy','Firewall','HTTPS','HostsFile') }
    @{ Id='APP-02'; Cat='apps'; Text='One application cannot connect to the internet'; Focus='App'
       Plan=@('InternetIP','DNS','AppConnect','Proxy','VPN','Firewall'); Questions=@('AppWhich') }
    @{ Id='APP-03'; Cat='apps'; Text='Teams / Zoom / Discord cannot connect'; Focus='App'
       Plan=@('InternetIP','DNS','AppConnect','Proxy','VPN','Firewall'); Questions=@('AppWhich') }
    @{ Id='APP-04'; Cat='apps'; Text='A gaming launcher cannot connect (Steam, Epic, Xbox)'; Focus='App'
       Plan=@('InternetIP','DNS','MTU','AppConnect','Firewall'); Questions=@('AppWhich') }
    @{ Id='APP-05'; Cat='apps'; Text='Git or GitHub cannot connect'; Focus='App'
       Plan=@('InternetIP','DNS','Proxy','AppConnect','Firewall'); Questions=@('AppWhich') }
    @{ Id='APP-06'; Cat='apps'; Text='HTTPS connections fail (secure sites will not load)'; Focus='App'
       Plan=@('InternetIP','DNS','HTTPS','Proxy','Firewall','MTU') }
    @{ Id='APP-07'; Cat='apps'; Text='Websites work but one specific application does not'; Focus='App'
       Plan=@('InternetIP','Proxy','VPN','Firewall','AppConnect'); Questions=@('AppWhich') }
    @{ Id='APP-08'; Cat='apps'; Text="Only one website doesn't work"; Focus='App'
       Plan=@('InternetIP','DNS','HostsFile','Website','HTTPS','Proxy'); Questions=@('Domain') }
    @{ Id='APP-09'; Cat='apps'; Text='Email or Outlook cannot connect'; Focus='App'
       Plan=@('InternetIP','DNS','AppConnect','Proxy','MTU'); Questions=@('AppWhich') }
    @{ Id='APP-10'; Cat='apps'; Text='Microsoft Store or Windows Update cannot connect'; Focus='App'
       Plan=@('InternetIP','DNS','Proxy','Firewall','MTU','HTTPS') }
    @{ Id='APP-11'; Cat='apps'; Text='A game or multiplayer service will not connect'; Focus='App'
       Plan=@('InternetIP','DNS','Latency','PacketLoss','AppConnect','Firewall'); Questions=@('AppWhich') }

    # --------------------------------------------------------------------- VPN
    @{ Id='VPN-01'; Cat='vpn'; Text='The VPN is connected but there is no internet'; Focus='Reachability'
       Plan=@('Adapter','IP','GatewayReach','InternetIP','VPN','Route','DNS') }
    @{ Id='VPN-02'; Cat='vpn'; Text='The VPN will not connect'; Focus='App'
       Plan=@('InternetIP','DNS','MTU','Latency','VPN','Proxy') }
    @{ Id='VPN-03'; Cat='vpn'; Text='The internet stops as soon as I enable the VPN'; Focus='Reachability'
       Preset=@{ RecentChange='VpnInstall' }
       Plan=@('InternetIP','VPN','Route','DNS','MTU') }
    @{ Id='VPN-04'; Cat='vpn'; Text='I think a proxy configuration is interfering'; Focus='App'
       Plan=@('InternetIP','Proxy','HTTPS','DNS') }
    @{ Id='VPN-05'; Cat='vpn'; Text='My DNS servers change when the VPN is active'; Focus='Dns'
       Plan=@('InternetIP','DNS','VPN','Proxy') }
    @{ Id='VPN-06'; Cat='vpn'; Text='The VPN causes routing problems'; Focus='Local'
       Plan=@('InternetIP','Route','VPN','MTU','ARP') }
    @{ Id='VPN-07'; Cat='vpn'; Text='Everything broke after I installed a VPN'; Focus='Reachability'
       Preset=@{ RecentChange='VpnInstall' }
       Plan=@('InternetIP','VPN','Route','Proxy','DNS','HostsFile') }

    # ----------------------------------------------------------------- WINDOWS
    @{ Id='WIN-01'; Cat='windows'; Text='My network stack may be corrupted'; Focus='Windows'
       Plan=@('NetworkStack','Services','Adapter','DNS','IP') }
    @{ Id='WIN-02'; Cat='windows'; Text='I think Winsock is corrupted'; Focus='Windows'
       Plan=@('NetworkStack','Services','Adapter','InternetIP') }
    @{ Id='WIN-03'; Cat='windows'; Text='The TCP/IP stack may need a reset'; Focus='Windows'
       Plan=@('NetworkStack','Route','IP','InternetIP') }
    @{ Id='WIN-04'; Cat='windows'; Text='I want to clear the DNS cache'; Focus='Windows'
       Plan=@('DNS','HostsFile') }
    @{ Id='WIN-05'; Cat='windows'; Text='The network adapter may need restarting'; Focus='Windows'
       Plan=@('Adapter','WiFi','Ethernet','IP','GatewayReach') }
    @{ Id='WIN-06'; Cat='windows'; Text='Open Windows network settings for me'; Focus='Windows'
       Action='OpenNetworkSettings'; Plan=@('Adapter','IP','GatewayReach') }
    @{ Id='WIN-07'; Cat='windows'; Text='I want to run the Windows network troubleshooter'; Focus='Windows'
       Action='OpenTroubleshooter'; Plan=@('Adapter','IP','GatewayReach','DNS','InternetIP') }
    @{ Id='WIN-08'; Cat='windows'; Text='I think I need a full network reset'; Focus='Windows'
       Plan=@('NetworkStack','Adapter','IP','DNS','Route') }
    @{ Id='WIN-09'; Cat='windows'; Text='My Windows network services may have stopped'; Focus='Windows'
       Plan=@('Services','DNS','DHCP','Adapter') }
    @{ Id='WIN-10'; Cat='windows'; Text='My Windows network settings look wrong'; Focus='Windows'
       Plan=@('IP','DNS','Route','Proxy','NetworkStack') }

    # ----------------------------------------------------------------- ADAPTER
    @{ Id='AD-01'; Cat='adapter'; Text='My network adapter is disabled'; Focus='Windows'
       Plan=@('Adapter','Driver','WiFi','Ethernet') }
    @{ Id='AD-02'; Cat='adapter'; Text='My network adapter is missing'; Focus='Windows'
       Plan=@('Adapter','Driver') }
    @{ Id='AD-03'; Cat='adapter'; Text='My network adapter shows an error'; Focus='Windows'
       Plan=@('Driver','Adapter') }
    @{ Id='AD-04'; Cat='adapter'; Text='I think there is a driver problem'; Focus='Windows'
       Plan=@('Driver','Adapter','WiFi','Ethernet') }
    @{ Id='AD-05'; Cat='adapter'; Text='Device Manager reports a problem with a network device'; Focus='Windows'
       Plan=@('Driver','Adapter') }
    @{ Id='AD-06'; Cat='adapter'; Text='My Wi-Fi adapter stopped working'; Focus='Windows'
       Plan=@('Adapter','WiFi','Driver','Services') }
    @{ Id='AD-07'; Cat='adapter'; Text='My Ethernet adapter stopped working'; Focus='Windows'
       Plan=@('Adapter','Ethernet','Driver') }
    @{ Id='AD-08'; Cat='adapter'; Text='The adapter works after a restart but later fails'; Focus='Stability'
       Plan=@('Adapter','Driver','Stability','PacketLoss'); Questions=@('StabilityTime') }

    # --------------------------------------------------------------------- LAN
    @{ Id='LAN-01'; Cat='lan'; Text='I cannot reach another computer on my network'; Focus='Local'
       Plan=@('Adapter','IP','GatewayReach','ARP','LocalNetwork','LocalHost'); Questions=@('LanTarget') }
    @{ Id='LAN-02'; Cat='lan'; Text='I cannot access shared folders'; Focus='Local'
       Plan=@('IP','GatewayReach','ARP','LocalNetwork','LocalHost','Services'); Questions=@('LanTarget') }
    @{ Id='LAN-03'; Cat='lan'; Text='I cannot reach a local server or NAS'; Focus='Local'
       Plan=@('IP','GatewayReach','ARP','LocalHost','LocalNetwork'); Questions=@('LanTarget') }
    @{ Id='LAN-04'; Cat='lan'; Text='The local network works but there is no internet'; Focus='Reachability'
       Plan=@('Adapter','IP','GatewayReach','LocalNetwork','InternetIP','DNS') }
    @{ Id='LAN-05'; Cat='lan'; Text='The internet works but the local network does not'; Focus='Local'
       Plan=@('IP','GatewayReach','ARP','Route','LocalNetwork','Firewall') }
    @{ Id='LAN-06'; Cat='lan'; Text='My ARP / neighbour information looks unusual'; Focus='Local'
       Plan=@('ARP','Route','IP','GatewayReach') }
    @{ Id='LAN-07'; Cat='lan'; Text='My routing table may contain unexpected routes'; Focus='Local'
       Plan=@('Route','VPN','ARP','InternetIP') }

    # ---------------------------------------------------------------- ADVANCED
    @{ Id='ADV-01'; Cat='advanced'; Text='Everything was working yesterday'; Focus='Reachability'
       Plan=@('Adapter','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS','HTTPS'); Questions=@('RecentChange','Scope') }
    @{ Id='ADV-02'; Cat='advanced'; Text='I changed something in network settings and now nothing works'; Focus='Windows'
       Preset=@{ RecentChange='SettingsPoke' }
       Plan=@('Adapter','IP','DHCP','Gateway','Route','DNS','Proxy','NetworkStack') }
    @{ Id='ADV-03'; Cat='advanced'; Text='I installed a VPN and now the internet is broken'; Focus='Reachability'
       Preset=@{ RecentChange='VpnInstall' }
       Plan=@('InternetIP','VPN','Proxy','Route','DNS') }
    @{ Id='ADV-04'; Cat='advanced'; Text='I updated Windows and Wi-Fi stopped working'; Focus='Windows'
       Preset=@{ RecentChange='WindowsUpdate' }
       Plan=@('Adapter','Driver','WiFi','WiFiScan','Services','NetworkStack') }
    @{ Id='ADV-05'; Cat='advanced'; Text='I changed DNS and now websites will not load'; Focus='Dns'
       Preset=@{ RecentChange='DnsChange' }
       Plan=@('InternetIP','DNS','HostsFile','Proxy','HTTPS') }
    @{ Id='ADV-06'; Cat='advanced'; Text='I manually configured an IP and now I cannot connect'; Focus='Reachability'
       Preset=@{ RecentChange='StaticIp' }
       Plan=@('Adapter','IP','DHCP','Gateway','Route','GatewayReach') }
    @{ Id='ADV-07'; Cat='advanced'; Text='I can connect to Wi-Fi but cannot access anything'; Focus='Reachability'
       Plan=@('Adapter','WiFi','IP','DHCP','GatewayReach','InternetIP','DNS','HTTPS') }
    @{ Id='ADV-08'; Cat='advanced'; Text='My PC works on another network but not on this one'; Focus='Local'
       Plan=@('Adapter','IP','DHCP','GatewayReach','ARP','InternetIP','DNS') }
    @{ Id='ADV-09'; Cat='advanced'; Text='My PC works on a mobile hotspot but not on my home Wi-Fi'; Focus='Local'
       Plan=@('Adapter','WiFi','WiFiScan','IP','DHCP','GatewayReach','ARP','DNS') }
    @{ Id='ADV-10'; Cat='advanced'; Text='Only one website does not work'; Focus='App'
       Plan=@('InternetIP','DNS','HostsFile','Website','HTTPS'); Questions=@('Domain') }
    @{ Id='ADV-11'; Cat='advanced'; Text='Only one application does not connect'; Focus='App'
       Plan=@('InternetIP','DNS','AppConnect','Proxy','VPN','Firewall'); Questions=@('AppWhich') }
    @{ Id='ADV-12'; Cat='advanced'; Text='Other people use my Wi-Fi fine but my device does not'; Focus='Reachability'
       Preset=@{ OutageScope='ThisPcOnly' }
       Plan=@('Adapter','WiFi','IP','DHCP','GatewayReach','ARP','DNS','Proxy') }

    # ---------------------------------------------------------------- NOT SURE
    @{ Id='NS-01'; Cat='notsure'; Text='I am not sure what is wrong - please check everything'; Focus='Reachability'
       Plan=@('Adapter','WiFi','Ethernet','Driver','Services','NetworkStack','IP','DHCP','Gateway','Route','ARP','GatewayReach','InternetIP','CaptivePortal','DNS','Proxy','HTTPS','VPN'); Questions=@('ConnType','Scope','RecentChange')
       Note='GeeNet will ask two or three quick questions, then work through the network layer by layer like a technician would.' }
    @{ Id='NS-02'; Cat='notsure'; Text='Everything feels wrong with my internet, I do not know where to start'; Focus='Reachability'
       Plan=@('Adapter','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS','HTTPS','Latency','PacketLoss'); Questions=@('ConnType','Scope') }
    @{ Id='NS-03'; Cat='notsure'; Text='The internet is either slow or unstable - I cannot tell which'; Focus='Slowness'
       Plan=@('Adapter','IP','GatewayReach','InternetIP','Latency','PacketLoss','DNS','Stability'); Questions=@('StabilityTime','Scope') }
)

function Get-GNCategory {
    param([string]$Id)
    return ($script:GNCategories | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

function Get-GNScenariosInCategory {
    param([string]$CategoryId)
    return @($script:GNScenarios | Where-Object { $_.Cat -eq $CategoryId })
}

function Get-GNScenario {
    param([string]$Id)
    return ($script:GNScenarios | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

# ------------------------------------------------------------------------------
#region 21. GUIDED (BEGINNER) MODE: NAVIGATION AND QUESTIONS
# ------------------------------------------------------------------------------

function Write-GNGuidedHeader {
    param([string]$Title = 'Guided Troubleshooting', [string]$Subtitle = '')
    Clear-Host
    Write-GNOut ''
    Write-GNOut "  GeeNet" -Color Cyan -NoNewline
    Write-GNOut "  /  $Title" -Color White
    Write-GNOut "  Windows Network Toolkit - " -Color DarkCyan -NoNewline
    Write-GNOut "Made by $($script:GeeNetAuthor)" -Color Green
    if ($Subtitle) { Write-GNOut "  $Subtitle" -Color DarkGray }
    Write-GNOut ''
    Write-GNRule '-' 2 ($script:GNW - 4) DarkCyan
    Write-GNOut ''
}

function Select-GNCategory {
    <#  'What problem are you experiencing?' #>
    while ($true) {
        Write-GNGuidedHeader -Title 'Guided Troubleshooting' -Subtitle 'Tell GeeNet what is wrong, in your own words.'
        Write-GNOut "  What problem are you experiencing?" -Color White
        Write-GNOut ''
        foreach ($c in $script:GNCategories) {
            Write-GNOut ("  [" + $c.Number + "] " + $c.Title) -Color White
            Write-GNPara -Text $c.Blurb -Color $script:GNCol.Dim -Indent 7
        }
        Write-GNOut ''
        Write-GNOut "  [0] Back to the main menu" -Color DarkGray
        Write-GNOut ''
        $answer = Read-GNChoice -Prompt '  Select a category'
        if ($answer -eq '0') { return $null }
        $cat = $script:GNCategories | Where-Object { "$($_.Number)" -eq "$answer" } | Select-Object -First 1
        if (-not $cat) {
            Write-GNOut ''
            Write-GNOut "  Please choose one of the numbers shown." -Color DarkYellow
            Start-Sleep -Seconds 1
            continue
        }
        return $cat
    }
}

function Select-GNScenario {
    <#  The symptom list inside a category, with keyword search. #>
    param($Category)
    $list = @(Get-GNScenariosInCategory -CategoryId $Category.Id)
    while ($true) {
        Write-GNGuidedHeader -Title 'Guided Troubleshooting' -Subtitle $Category.Title
        Write-GNOut "  Which of these sounds most like your problem?" -Color White
        Write-GNOut ''
        $i = 0
        foreach ($s in $list) {
            $i++
            Write-GNPara -Text ("[$($i)] " + $s.Text) -Color $script:GNCol.Text -Indent 2
        }
        Write-GNOut ''
        Write-GNOut "  [F] Search   [0] Back to categories" -Color DarkGray
        Write-GNOut ''
        $answer = Read-GNChoice -Prompt '  Select a symptom'
        if ($answer -eq '0') { return $null }
        if ($answer -match '^(f|find|search)$') {
            Write-GNOut ''
            $kw = Read-GNInput -Prompt '  Type a few words (for example: no internet, slow, dns, vpn)'
            if ([string]::IsNullOrWhiteSpace($kw)) { continue }
            $found = @($script:GNScenarios | Where-Object { $_.Text -match [regex]::Escape($kw) -or $_.Cat -match [regex]::Escape($kw) })
            if ($found.Count -eq 0) {
                Write-GNOut ''
                Write-GNOut "  Nothing matched '$kw'. Try a simpler word, or browse the categories." -Color DarkYellow
                Pause-GeeNet '  Press Enter to continue'
                continue
            }
            Write-GNOut ''
            Write-GNOut "  Matches for '$kw':" -Color Cyan
            Write-GNOut ''
            $j = 0
            foreach ($f in $found) {
                $j++
                $catName = (Get-GNCategory -Id $f.Cat).Title
                Write-GNPara -Text ("[$j] " + $f.Text + "   (" + $catName + ")") -Color $script:GNCol.Text -Indent 2
            }
            Write-GNOut ''
            Write-GNOut "  [0] Back" -Color DarkGray
            $pick = Read-GNChoice -Prompt '  Select a match'
            if ($pick -eq '0') { continue }
            $sel = $found[([int]$pick) - 1]
            if ($sel) { return $sel }
            continue
        }
        $idx = 0
        [void][int]::TryParse("$answer", [ref]$idx)
        if ($idx -ge 1 -and $idx -le $list.Count) { return $list[$idx - 1] }
        Write-GNOut ''
        Write-GNOut "  Please choose one of the numbers shown, or press F to search." -Color DarkYellow
        Start-Sleep -Seconds 1
    }
}

function Ask-GNQuestions {
    <#
      Asks only the questions that genuinely change the diagnostic path,
      stores the answers as context, and returns the test parameters they imply.
    #>
    param($Scenario)
    $out = [pscustomobject]@{
        Answers    = @{}
        Context    = @{}
        TestParams = @{}
        ExtraPlan  = @()
        RemovedPlan= @()
    }
    if ($Scenario.Preset) {
        foreach ($k in $Scenario.Preset.Keys) { $out.Context[$k] = $Scenario.Preset[$k] }
    }
    $qIds = @()
    if ($Scenario.Questions) { $qIds = @($Scenario.Questions) }
    if ($qIds.Count -eq 0) { return $out }

    Write-GNOut "  Before GeeNet starts testing, it needs $($qIds.Count) quick answer$(if ($qIds.Count -gt 1) { 's' })." -Color Cyan
    Write-GNPara -Text "GeeNet asks only what changes the diagnosis - it will find the technical details (addresses, gateways, DNS) by itself." -Color DarkGray -Indent 4
    Write-GNOut ''

    foreach ($qId in $qIds) {
        $q = Get-GNQuestion -Id $qId
        if (-not $q) { continue }
        $answer = $null
        Write-GNOut ''
        Write-GNOut ("  " + $q.Prompt) -Color White
        if ($q.Why) { Write-GNPara -Text ("Why: " + $q.Why) -Color $script:GNCol.Dim -Indent 4 }

        if ($q.Type -eq 'Choice') {
            $options = if ($q.Dynamic -eq 'Apps') { Get-GNAppQuestionOptions } else { $q.Options }
            Write-GNOut ''
            $n = 0
            foreach ($o in $options) {
                $n++
                Write-GNPara -Text ("[$n] " + $o.Label) -Color $script:GNCol.Text -Indent 4
            }
            Write-GNOut ''
            $pick = Read-GNChoice -Prompt '  Enter a number'
            $idx = 0
            [void][int]::TryParse("$pick", [ref]$idx)
            if ($idx -ge 1 -and $idx -le $options.Count) { $answer = "$($options[$idx-1].Key)" }
            else { $answer = "$($options[0].Key)" }
            Write-GNOut ("  Answer recorded: " + $answer) -Color DarkGray
        } else {
            $answer = Read-GNInput -Prompt '  > '
            if ([string]::IsNullOrWhiteSpace($answer)) { $answer = '' }
            Write-GNOut ''
        }

        $out.Answers[$qId] = $answer
        if ($q.ContextKey) { $out.Context[$q.ContextKey] = $answer }

        if ($q.TestKey -and $q.TestParam -and -not [string]::IsNullOrWhiteSpace($answer)) {
            $val = $answer
            if ($q.TestParam -eq 'Seconds') { $val = [int]$answer }
            if (-not $out.TestParams.ContainsKey($q.TestKey)) { $out.TestParams[$q.TestKey] = @{} }
            $out.TestParams[$q.TestKey][$q.TestParam] = $val
        }

        # Follow-up for a free-text application target
        if ($q.Id -eq 'AppWhich' -and $answer -eq 'other') {
            $host = Read-GNInput -Prompt '  Type the server address the app uses (or leave blank to skip)'
            if (-not [string]::IsNullOrWhiteSpace($host)) {
                $out.TestParams['AppConnect'] = @{ Host = $host; Label = $host }
                $out.Answers['AppHost'] = $host
            } else {
                $out.RemovedPlan += 'AppConnect'
            }
        }

        # Plan additions driven by the answer
        if ($script:GNPlanByAnswer.ContainsKey($qId)) {
            $mapping = $script:GNPlanByAnswer[$qId]
            if ($mapping.ContainsKey($answer)) {
                $out.ExtraPlan += @($mapping[$answer])
            }
        }

        if ($q.TestKey -and $q.TestParam -eq 'Domain' -and [string]::IsNullOrWhiteSpace($answer)) {
            $out.RemovedPlan += 'Website'
        }
        if ($q.TestKey -and $q.TestParam -eq 'Target' -and [string]::IsNullOrWhiteSpace($answer)) {
            $out.RemovedPlan += 'LocalHost'
        }
    }
    Write-GNOut ''
    Write-GNOut "  Thanks - starting the diagnosis now." -Color Green
    Write-GNOut ''
    return $out
}

function Get-GNScenarioNote {
    <#  Clarifying boundary text shown before certain scenarios run. #>
    param($Scenario)
    $notes = @()
    if ($Scenario.Note) { $notes += $Scenario.Note }
    if ($Scenario.Cat -eq 'router' -or $Scenario.Id -in @('RT-10','RT-13','INT-01')) {
        $notes += "GeeNet can diagnose the computer side of this problem, but it cannot physically repair or reboot your router, and it cannot restore an ISP connection. It will tell you clearly when the evidence points outside your PC."
    }
    if ($Scenario.Cat -eq 'vpn') {
        $notes += "GeeNet will not change VPN configuration automatically - it will diagnose first and explain what the evidence shows."
    }
    return $notes
}

# ------------------------------------------------------------------------------
#region 22. GUIDED MODE: SCENARIO RUN, REPAIR LOOP, SESSION RESULT
# ------------------------------------------------------------------------------

function Invoke-GNScenario {
    <#
      The full guided session for one symptom:
        questions -> sequential investigation -> diagnosis -> repairs (+retest)
        -> updated diagnosis -> session result -> optional saved report
    #>
    param([Parameter(Mandatory)]$Scenario)
    $session = $script:GNSession
    if ($session) {
        $session.SymptomId = $Scenario.Id
        $session.SymptomText = $Scenario.Text
        $session.CategoryId = $Scenario.Cat
        $session.Mode = 'Beginner / Guided'
    }
    Write-GNGuidedHeader -Title 'Guided Troubleshooting' -Subtitle ((Get-GNCategory -Id $Scenario.Cat).Title)
    Write-GNOut "  Your problem:" -Color Cyan
    Write-GNPara -Text ("`"" + $Scenario.Text + "`"") -Color White -Indent 4
    Write-GNOut ''
    Write-GeeNetLog -Message ("Guided session started: $($Scenario.Id) - $($Scenario.Text)") -Level 'STEP'
    foreach ($n in (Get-GNScenarioNote -Scenario $Scenario)) {
        Write-GNOut "  Note:" -Color DarkYellow
        Write-GNPara -Text $n -Color $script:GNCol.Text -Indent 4
        Write-GNOut ''
    }

    # ---- questions -----------------------------------------------------------
    $q = Ask-GNQuestions -Scenario $Scenario

    # ---- scenario action (open a settings page etc.) -------------------------
    if ($Scenario.Action) {
        switch ($Scenario.Action) {
            'OpenNetworkSettings'    { Write-GNOut "  Opening Windows network settings ..." -Color Cyan; try { Start-Process 'ms-settings:network-status' } catch { } }
            'OpenNetworkConnections' { Write-GNOut "  Opening Network Connections ..." -Color Cyan; try { Start-Process 'ncpa.cpl' } catch { } }
            'OpenDeviceManager'      { Write-GNOut "  Opening Device Manager ..." -Color Cyan; try { Start-Process 'devmgmt.msc' } catch { } }
            'OpenTroubleshooter'     { Write-GNOut "  Opening the Windows network troubleshooter ..." -Color Cyan; try { Start-Process 'ms-settings:troubleshoot' } catch { } }
        }
        Write-GNOut ''
        Write-GNPara -Text "GeeNet has opened that window for you. You can also let GeeNet run its own checks - they are usually more informative than the Windows troubleshooter." -Color $script:GNCol.Text -Indent 4
        Write-GNOut ''
        $cont = Read-GNConfirm -Prompt "  Run GeeNet's diagnostic checks as well?" -DefaultYes $true
        if (-not $cont) {
            Write-GNOut ''
            Write-GNPara -Text "No problem - nothing else was changed on your computer." -Color $script:GNCol.Dim -Indent 4
            Pause-GeeNet
            return
        }
        Start-Sleep -Milliseconds 600
    }

    # ---- build the effective plan --------------------------------------------
    $plan = @($Scenario.Plan) + @($q.ExtraPlan)
    if ($q.RemovedPlan.Count -gt 0) {
        $plan = @($plan | Where-Object { $q.RemovedPlan -notcontains $_ })
        foreach ($r in $q.RemovedPlan) {
            [void](Write-GeeNetLog -Message "Skipped '$r' because no target was given" -Level 'SKIP')
        }
    }
    $plan = @(Sort-GNPlan -Plan $plan)

    # ---- run the investigation ----------------------------------------------
    $inv = Invoke-GNInvestigation -Plan $plan -Context $q.Context -TestParams $q.TestParams -Focus $Scenario.Focus -SymptomText $Scenario.Text

    # ---- repair / retest loop -----------------------------------------------
    $recheck = $null
    while ($true) {
        $verdict = if ($recheck) { $recheck.Verdict } else { $inv.Verdict }
        $results = if ($recheck) { $recheck.Results } else { $inv.Results }
        $before = Get-GNStatusMap -Results $results

        $options = New-Object System.Collections.Generic.List[object]
        foreach ($rid in @($verdict.RepairIds)) {
            if ($options.Count -ge 4) { break }
            $rep = Get-GNRepair -Id $rid
            if ($rep) { [void]$options.Add($rep) }
        }

        Write-GNOut ''
        Write-GNRule '=' 2 ($script:GNW - 4) Magenta
        Write-GNOut ''
        if ($options.Count -eq 0) {
            Write-GNOut "  What GeeNet suggests now" -Color Magenta
            Write-GNOut ''
            if ($verdict.ClientSide -eq $false) {
                Write-GNPara -Text "There is no safe automatic repair for this one - the evidence points outside this computer (or outside what software can fix). The steps above are what a technician would do next." -Color $script:GNCol.Text -Indent 4
            } else {
                Write-GNPara -Text "GeeNet has no automatic repair left for this diagnosis. The recommended next steps above are the best path, and the Professional tools section has deeper checks (traceroute, continuous ping, Wi-Fi detail)." -Color $script:GNCol.Text -Indent 4
            }
            Write-GNOut ''
            Write-GNOut "  [1] Run the checks again (if you changed something yourself)" -Color White
            Write-GNOut "  [2] Show the diagnostic log for this session" -Color White
            Write-GNOut "  [3] Save a diagnostic report" -Color White
            Write-GNOut "  [T] Show the technical details behind this diagnosis" -Color White
            Write-GNOut "  [0] Finish and show the session summary" -Color DarkGray
            Write-GNOut ''
            $pick = Read-GNChoice -Prompt '  Select an option'
            if ($pick -match '^(t|tech|technical)$') { Show-GNTechnicalDetails -Results $results; continue }
            if ($pick -eq '1') {
                Write-GNOut ''
                Write-GNOut "  Re-running the key checks ..." -Color Cyan
                $recheck = Invoke-GNRecheck -Investigation $inv -Context $q.Context -Focus $Scenario.Focus -SymptomText $Scenario.Text
                Write-GNVerdict -Verdict $recheck.Verdict
                continue
            } elseif ($pick -eq '2') {
                Show-GNDiagnosticLog
                continue
            } elseif ($pick -eq '3') {
                Save-GNSessionReport
                continue
            } else { break }
        }

        Write-GNOut "  GeeNet can try to fix this" -Color Magenta
        Write-GNPara -Text "Each option below is explained in full before anything runs, and GeeNet re-tests afterwards to check honestly whether it helped. Nothing runs without your permission." -Color $script:GNCol.Text -Indent 4
        Write-GNOut ''
        $i = 0
        foreach ($o in $options) {
            $i++
            $riskCol = switch ($o.Risk) { 'Low' { 'Green' } 'Moderate' { 'DarkYellow' } default { 'Red' } }
            Write-GNOut ("  [$i] " + $o.Title) -Color White
            Write-GNOut ("      ") -NoNewline -Color Gray
            Write-GNOut ((Get-GNRiskBadge -Risk $o.Risk) + $(if ($o.Admin) { ' - needs Administrator' } else { '' }) + $(if ($o.Restart) { ' - restart required' } else { '' })) -Color $riskCol
        }
        if ($verdict.RepairIds.Count -gt $options.Count) {
            Write-GNOut ("  ... and " + ($verdict.RepairIds.Count - $options.Count) + " further repair option(s) available in the Professional tools section.") -Color DarkGray
        }
        Write-GNOut ''
        Write-GNOut "  [R] Re-run the checks     [L] Show the diagnostic log" -Color White
        Write-GNOut "  [S] Save a report         [T] Technical details" -Color White
        Write-GNOut "  [0] Finish (do not change anything)" -Color White
        Write-GNOut ''
        $pick = Read-GNChoice -Prompt '  Select an option'
        if ($pick -eq '0') { break }
        if ($pick -match '^(t|tech|technical)$') { Show-GNTechnicalDetails -Results $results; continue }
        if ($pick -match '^(r|recheck|rerun)$') {
            Write-GNOut ''
            Write-GNOut "  Re-running the key checks ..." -Color Cyan
            $recheck = Invoke-GNRecheck -Investigation $inv -Context $q.Context -Focus $Scenario.Focus -SymptomText $Scenario.Text
            Write-GNVerdict -Verdict $recheck.Verdict
            continue
        }
        if ($pick -match '^(l|log)$') { Show-GNDiagnosticLog; continue }
        if ($pick -match '^(s|save)$') { Save-GNSessionReport; continue }
        $idx = 0
        [void][int]::TryParse("$pick", [ref]$idx)
        if ($idx -lt 1 -or $idx -gt $options.Count) {
            Write-GNOut ''
            Write-GNOut "  Please pick one of the options shown." -Color DarkYellow
            continue
        }
        $chosen = $options[$idx - 1]
        $flowResult = Invoke-GNRepairFlow -Id $chosen.Id -Before $before
        if ($flowResult -and $flowResult.Ran) {
            Write-GNOut ''
            Write-GNOut "  Re-checking the diagnosis with the repair applied ..." -Color Cyan
            $recheck = Invoke-GNRecheck -Investigation $inv -Context $q.Context -Focus $Scenario.Focus -SymptomText $Scenario.Text
            Write-GNVerdict -Verdict $recheck.Verdict
            if ($recheck.Verdict.Severity -eq 'Pass') {
                Write-GNOut ''
                Write-GNPara -Text "That looks resolved. GeeNet will not keep going once the checks pass." -Color Green -Indent 4
                break
            }
        }
    }

    # ---- session result ------------------------------------------------------
    $finalVerdict = if ($recheck) { $recheck.Verdict } else { $inv.Verdict }
    $finalResults = if ($recheck) { $recheck.Results } else { $inv.Results }
    Write-GNSessionResult -Scenario $Scenario -Verdict $finalVerdict -Results $finalResults -StoppedReason $inv.StoppedReason

    Write-GNOut ''
    Write-GNOut "  [S] Save a diagnostic report" -Color White
    Write-GNOut "  [L] Show the diagnostic log" -Color White
    Write-GNOut "  [Enter] Back to the menu" -Color DarkGray
    Write-GNOut ''
    $last = Read-GNInput -Prompt '  Select an option'
    if ($last -match '^(l|log)$') { Show-GNDiagnosticLog }
    elseif ($last -match '^(s|save)$') { Save-GNSessionReport }
}

function Invoke-GNRecheck {
    <#  Re-runs the essential chain and merges the new results into the old set. #>
    param($Investigation, [hashtable]$Context = @{}, [string]$Focus = '', [string]$SymptomText = '')
    $essential = @('Adapter','WiFi','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS','HTTPS','VPN','Proxy','AppConnect','Website','LocalHost','NetworkStack','Services')
    $plan = @($Investigation.Plan)
    $retestKeys = @($plan | Where-Object { $essential -contains $_ })
    if ($retestKeys.Count -eq 0) { $retestKeys = @('Adapter','IP','GatewayReach','InternetIP','DNS','HTTPS') }

    $fresh = New-Object System.Collections.Generic.List[object]
    Write-GNOut ''
    foreach ($key in $retestKeys) {
        $info = Get-GNTestInfo -Key $key
        if (-not $info) { continue }
        Write-GNStepLine -Index ($retestKeys.IndexOf($key) + 1) -Total $retestKeys.Count -Name $info.Name -Status '' -NoNewline
        $r = $null
        try { $r = & $info.Function } catch { $r = $null }
        if ($r) {
            $statusText = switch ($r.Status) { 'Pass' { 'PASS' } 'Fail' { 'FAIL' } 'Warn' { 'WARN' } 'Skip' { 'SKIP' } default { 'INFO' } }
            $col = switch ($r.Status) { 'Pass' { 'Green' } 'Fail' { 'Red' } 'Warn' { 'DarkYellow' } default { 'DarkGray' } }
            Write-GNOut ($statusText + (" ({0:N1}s)" -f ($r.DurationMs / 1000))) -Color $col
            [void]$fresh.Add($r)
            if ($script:GNSession) { [void]$script:GNSession.Results.Add($r) }
        } else {
            Write-GNOut 'SKIPPED' -Color DarkGray
        }
    }
    # merge: fresh results replace old ones of the same id, order preserved
    $merged = New-Object System.Collections.Generic.List[object]
    $freshMap = @{}
    foreach ($r in (Get-GNArray -Items $fresh)) {
        if ($r -and -not [string]::IsNullOrWhiteSpace("$($r.Id)")) { $freshMap["$($r.Id)"] = $r }
    }
    foreach ($old in (Get-GNArray -Items $Investigation.Results)) {
        $oldId = if ($old -and -not [string]::IsNullOrWhiteSpace("$($old.Id)")) { "$($old.Id)" } else { '' }
        if ($oldId -and $freshMap.ContainsKey($oldId)) {
            [void]$merged.Add($freshMap[$oldId])
            $freshMap.Remove($oldId) | Out-Null
        } else {
            [void]$merged.Add($old)
        }
    }
    foreach ($k in @($freshMap.Keys)) { [void]$merged.Add($freshMap[$k]) }

    if (-not $Focus -and $Investigation.PSObject.Properties['Focus']) { $Focus = "$($Investigation.Focus)" }
    if (-not $Focus) { $Focus = 'Reachability' }
    if (-not $SymptomText -and $script:GNSession) { $SymptomText = "$($script:GNSession.SymptomText)" }
    $verdict = $null
    try {
        $verdict = Get-GNVerdict -Plan $Investigation.Plan -Results $merged -Context $Context -Focus $Focus -SymptomText $SymptomText
    } catch {
        # Never lose the diagnosis because of a re-check: fall back to the previous verdict
        $verdict = $Investigation.Verdict
        [void](Write-GeeNetLog -Message "Re-check interpretation failed: $($_.Exception.Message)" -Level 'WARN')
    }
    $inv = [pscustomobject]@{
        Plan = $Investigation.Plan; Ran = $retestKeys; Results = (Get-GNArray -Items $merged)
        StoppedReason = $Investigation.StoppedReason; Skipped = @(); Verdict = $verdict
    }
    if ($script:GNSession) {
        $script:GNSession.Verdict = $verdict
        $script:GNSession.Findings = New-Object System.Collections.Generic.List[string]
        foreach ($f in Get-GNFindingLines -Results $merged) { [void]$script:GNSession.Findings.Add($f) }
    }
    return $inv
}

function Write-GNSessionResult {
    <#  The end-of-session result block the user takes away. #>
    param($Scenario, $Verdict, $Results, [string]$StoppedReason = '')
    Write-GNOut ''
    Write-GNRule '=' 2 ($script:GNW - 4) Cyan
    Write-GNOut ''
    Write-GNOut "  TROUBLESHOOTING COMPLETE" -Color Cyan
    Write-GNOut ''
    Write-GNOut "  Problem" -Color $script:GNCol.Info
    Write-GNPara -Text ("`"" + $Scenario.Text + "`"") -Color White -Indent 4
    Write-GNOut ''
    Write-GNOut "  Findings" -Color $script:GNCol.Info
    foreach ($f in (Get-GNFindingLines -Results $Results)) {
        $col = 'Gray'
        if ($f -match '^' + [regex]::Escape($script:GNG.Cross)) { $col = 'Red' }
        elseif ($f -match '^' + [regex]::Escape($script:GNG.Triangle)) { $col = 'DarkYellow' }
        elseif ($f -match '^' + [regex]::Escape($script:GNG.Tick)) { $col = 'Green' }
        elseif ($f -match '^' + [regex]::Escape($script:GNG.Skip)) { $col = 'DarkGray' }
        Write-GNPara -Text $f -Color $col -Indent 4
    }
    Write-GNOut ''
    Write-GNOut "  Likely cause" -Color $script:GNCol.Info
    Write-GNPara -Text $Verdict.Headline -Color White -Indent 4
    Write-GNPara -Text $Verdict.Diagnosis -Color $script:GNCol.Text -Indent 4
    if ($Verdict.LikelyCauses.Count -gt 0) {
        Write-GNList -Items $Verdict.LikelyCauses -Color $script:GNCol.Text -Indent 6
    }
    Write-GNOut ''
    Write-GNOut "  What GeeNet tried" -Color $script:GNCol.Info
    $repairs = @()
    if ($script:GNSession) { $repairs = Get-GNArray -Items $script:GNSession.Repairs }
    if ($repairs.Count -eq 0) {
        Write-GNPara -Text "No repairs were run - the diagnosis and next steps are above." -Color $script:GNCol.Text -Indent 4
    } else {
        foreach ($r in $repairs) {
            $line = "$($r.Title) - "
            if (-not $r.Attempted) { $line += "not run ($($r.Note))" }
            elseif ($r.Success -and $r.RetestImproved) { $line += "ran and the re-test improved" }
            elseif ($r.Success) { $line += "ran, but the re-test did not improve" }
            else { $line += "was refused or reported an error" }
            Write-GNPara -Text $line -Color $script:GNCol.Text -Indent 4 -Bullet $script:GNG.Bullet
        }
    }
    Write-GNOut ''
    Write-GNOut "  Current status" -Color $script:GNCol.Info
    switch ($Verdict.Severity) {
        'Pass' { Write-GNPara -Text "Resolved - the checks pass now." -Color Green -Indent 4 }
        'Warn' { Write-GNPara -Text "Working, with warnings - the connection is usable but something still looks off." -Color DarkYellow -Indent 4 }
        default { Write-GNPara -Text "Problem remains unresolved for now." -Color Red -Indent 4 }
    }
    Write-GNOut ''
    Write-GNOut "  Recommended next step" -Color $script:GNCol.Info
    if ($Verdict.NextSteps.Count -gt 0) {
        $n = 1
        foreach ($s in ($Verdict.NextSteps | Select-Object -First 4)) {
            Write-GNPara -Text ("$n. " + $s) -Color $script:GNCol.Action -Indent 4
            $n++
        }
    }
    if ($Verdict.BoundaryNote) {
        Write-GNPara -Text $Verdict.BoundaryNote -Color DarkYellow -Indent 4
    }
    Write-GNOut ''
    Write-GNPara -Text (Get-GNQuickSummary -Verdict $Verdict) -Color $script:GNCol.Dim -Indent 4
}

function Show-GNDiagnosticLog {
    Write-GNGuidedHeader -Title 'Diagnostic Log' -Subtitle 'Everything GeeNet did during this session, with timestamps.'
    $lines = @(Get-GeeNetLogLines)
    if ($lines.Count -eq 0) {
        Write-GNOut "  No log entries for this session yet." -Color DarkYellow
    } else {
        foreach ($l in $lines) {
            $col = 'Gray'
            if ($l -match 'FAIL') { $col = 'Red' }
            elseif ($l -match 'PASS') { $col = 'Green' }
            elseif ($l -match 'WARN') { $col = 'DarkYellow' }
            elseif ($l -match 'ACTION') { $col = 'Magenta' }
            elseif ($l -match 'SKIP') { $col = 'DarkGray' }
            Write-GNOut ("  " + $l) -Color $col
        }
    }
    Write-GNOut ''
    if ($script:GNLogFile) { Write-GNOut ("  Log file: " + $script:GNLogFile) -Color DarkGray }
    Pause-GeeNet '  Press Enter to go back'
}

function Start-GNGuidedMode {
    <#  Entry point for the Beginner / Guided mode. #>
    while ($true) {
        $cat = Select-GNCategory
        if (-not $cat) { return }
        while ($true) {
            $scenario = Select-GNScenario -Category $cat
            if (-not $scenario) { break }

            if (-not $script:GNSession) { New-GeeNetSession }
            Invoke-GNScenario -Scenario $scenario

            Write-GNOut ''
            Write-GNOut "  [1] Start a new diagnosis" -Color White
            Write-GNOut "  [2] List the saved reports" -Color White
            Write-GNOut "  [0] Back to the main menu" -Color DarkGray
            Write-GNOut ''
            $pick = Read-GNChoice -Prompt '  Select an option'
            if ($pick -eq '1') {
                New-GeeNetSession
                $script:GNSession.Mode = 'Beginner / Guided'
                continue
            } elseif ($pick -eq '2') {
                Show-GNReports
                continue
            } else { return }
        }
    }
}

# ------------------------------------------------------------------------------
#region 23. REPORTS
# ------------------------------------------------------------------------------

function Get-GNSystemReportBody {
    <#  Shared body for reports: safe, non-sensitive system + network facts. #>
    $facts = Get-GNSystemFacts
    $adapters = @(Get-GNAdapters)
    $configs = @(Get-GNIPConfig)
    $wifi = Get-GNWifiInfo
    $routes = @(Get-GNRoutes)
    $proxy = Get-GNProxyConfig
    $services = @(Get-GNCriticalServices)
    $sb = New-Object System.Text.StringBuilder
    $add = { param($t) [void]$sb.AppendLine($t) }

    & $add '================ SYSTEM ================'
    & $add "Computer name     : $($facts.ComputerName)"
    $userLine = "$($facts.User)"
    if ($facts.Domain) { $userLine = "$userLine  (domain/computer: $($facts.Domain))" }
    & $add "User              : $userLine"
    & $add "Windows           : $($facts.OSName) $($facts.OSVersion) (build $($facts.OSBuild))"
    & $add "Hardware          : $($facts.Vendor) $($facts.Model)"
    & $add "PowerShell        : $($facts.PowerShell)"
    & $add "Running as admin  : $($facts.IsAdmin)"
    & $add "Last boot         : $($facts.LastBoot)  (uptime $($facts.UptimeHours) hours)"

    & $add ''

    & $add '================ ACTIVE ADAPTERS ================'
    foreach ($a in $adapters) {
        if ($a.IsVirtual) { continue }
        & $add ("{0,-22} {1,-14} {2,-16} {3}" -f $a.Name, $a.Status, $a.LinkSpeed, $a.Description)
    }
    & $add ''

    & $add '================ IP CONFIGURATION ================'
    foreach ($c in $configs) {
        $kind = if ($c.IsWifi) { 'Wi-Fi' } else { 'Wired/virtual' }
        & $add "Adapter       : $($c.Adapter)  [$kind]"
        & $add "IPv4 address  : $($c.IPv4)"
        & $add "Subnet mask   : $($c.SubnetMask)  (/$($c.PrefixLength))"
        & $add "Default gw    : $($c.Gateway)"
        & $add "DNS servers   : $(@($c.DnsServers) -join ', ')"
        & $add "DHCP enabled  : $($c.DhcpEnabled)   DHCP server: $($c.DhcpServer)"
        & $add "APIPA (169.254): $($c.Apipa)"
        & $add "Network profile: $($c.ProfileName) [$($c.NetworkCategory)]"
        & $add "DNS suffix    : $($c.DnsSuffix)"
        & $add ''
    }

    & $add '================ WI-FI ================'
    if ($wifi.Present -or $wifi.SSID) {
        & $add "Adapter      : $($wifi.Name)"
        & $add "State        : $($wifi.State)"
        & $add "SSID         : $($wifi.SSID)"
        & $add "BSSID        : $($wifi.BSSID)"
        & $add "Signal       : $($wifi.SignalPercent)%"
        & $add "Radio type   : $($wifi.RadioType)   Channel: $($wifi.Channel)"
        & $add "Auth / cipher: $($wifi.Authentication) / $($wifi.Cipher)"
        & $add "Link rates   : rx $($wifi.ReceiveRate) / tx $($wifi.TransmitRate) Mbps"
    } else {
        & $add "No Wi-Fi interface reported. $($wifi.Error)"
    }
    & $add ''

    & $add '================ ROUTING (IPv4) ================'
    foreach ($r in ($routes | Where-Object { "$($_.DestinationPrefix)" -eq '0.0.0.0/0' -or "$($_.DestinationPrefix)" -eq '0.0.0.0' })) {
        & $add "Default route : via $($r.NextHop) metric $($r.RouteMetric) on $($r.InterfaceAlias)"
    }
    & $add "Total IPv4 routes: $($routes.Count)"
    & $add ''

    & $add '================ PROXY / TLS ================'
    & $add "Proxy enabled : $($proxy.Enabled)   Server: '$($proxy.Server)'  PAC: '$($proxy.PacUrl)'"
    & $add "WinHTTP proxy : $($proxy.WinHttpProxy)"
    & $add ''

    & $add '================ WINDOWS NETWORK SERVICES ================'
    foreach ($s in $services) { & $add ("{0,-22} {1,-12} {2}" -f $s.Name, $s.Status, $s.Display) }
    & $add ''

    return $sb.ToString()
}

function Save-GNSessionReport {
    <#  Report for a guided troubleshooting session (the one the user can send to support). #>
    $session = $script:GNSession
    if (-not $session) {
        Write-GNOut "  There is no session to report yet. Run a guided diagnosis first." -Color DarkYellow
        Pause-GeeNet
        return
    }
    try {
        if (-not (Test-Path $script:GeeNetReports)) { New-Item -ItemType Directory -Path $script:GeeNetReports -Force | Out-Null }
    } catch { }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $file = Join-Path $script:GeeNetReports ("GeeNet_Guided_Report_$stamp.txt")

    $verdict = $session.Verdict
    $sb = New-Object System.Text.StringBuilder
    $add = { param($t) [void]$sb.AppendLine($t) }

    & $add '================================================================'
    & $add ' GeeNet Diagnostic Report - Guided Troubleshooting Session'
    & $add " Made by $($script:GeeNetAuthor)  $($script:GeeNetPhone)  $($script:GeeNetGitHub)"
    & $add " GeeNet version $($script:GeeNetVersion)"
    & $add '================================================================'
    & $add ''
    & $add "Problem reported : $($session.SymptomText)"
    & $add "Category         : $((Get-GNCategory -Id $session.CategoryId).Title)"
    & $add "Session started  : $($session.Started)"
    & $add "Report generated : $(Get-Date)"
    & $add "Mode             : $($session.Mode)"
    & $add ''

    if ($session.Answers -and $session.Answers.Count -gt 0) {
        & $add '================ ANSWERS GIVEN BY THE USER ================'
        foreach ($k in $session.Answers.Keys) {
            $q = Get-GNQuestion -Id $k
            $label = if ($q) { $q.Prompt } else { $k }
            & $add "$label"
            & $add "    -> $($session.Answers[$k])"
        }
        & $add ''
    }

    & $add (Get-GNSystemReportBody)

    & $add '================ DIAGNOSTIC TESTS ================'
    # A repair is followed by a re-check, so the session holds several results per check.
    # Show each check once, in the order it first ran, using its most recent result.
    $testOrder = New-Object System.Collections.Generic.List[string]
    $testLatest = @{}
    foreach ($r in (Get-GNArray -Items $session.Results)) {
        if (-not $r) { continue }
        if ($r.Layer -eq 'Context') { continue }
        $rid = "$($r.Id)"
        if (-not $rid) { $rid = "check-$($testOrder.Count)" }
        if (-not $testLatest.ContainsKey($rid)) { [void]$testOrder.Add($rid) }
        $testLatest[$rid] = $r
    }
    foreach ($rid in $testOrder) {
        $r = $testLatest[$rid]
        & $add ("[{0}] {1} - {2}" -f "$($r.Status)".ToUpper(), $r.Name, $r.Summary)
        if ($r.Status -ne 'Pass' -and $r.Technical) { & $add ("      technical: " + $r.Technical) }
        if ($r.Status -eq 'Skip' -and $r.SkipReason) { & $add ("      skipped because: " + $r.SkipReason) }
    }
    & $add ''

    if ($session.StoppedReason) {
        & $add '================ SEQUENTIAL STOP ================'
        & $add $session.StoppedReason
        & $add ''
    }

    & $add '================ FINDINGS ================'
    foreach ($f in (Get-GNArray -Items $session.Findings)) { & $add $f }
    & $add ''

    if ($verdict) {
        & $add '================ LIKELY DIAGNOSIS ================'
        & $add "Headline   : $($verdict.Headline)"
        & $add "Boundary   : $($verdict.Boundary)  (client-side: $($verdict.ClientSide))"
        & $add "Confidence : $($verdict.Confidence)"
        & $add ''
        & $add $verdict.Diagnosis
        & $add ''
        if (@($verdict.LikelyCauses).Count -gt 0) {
            & $add 'Most likely causes:'
            foreach ($c in $verdict.LikelyCauses) { & $add ("  - " + $c) }
        }
        & $add ''
        if (@($verdict.NextSteps).Count -gt 0) {
            & $add 'Recommended next steps:'
            $i = 1
            foreach ($s in $verdict.NextSteps) { & $add ("  $i. $s"); $i++ }
        }
        if ($verdict.BoundaryNote) { & $add ''; & $add $verdict.BoundaryNote }
        & $add ''
    }

    & $add '================ REPAIRS ATTEMPTED ================'
    $repairs = Get-GNArray -Items $session.Repairs
    if ($repairs.Count -eq 0) { & $add 'No repairs were run during this session.' }
    foreach ($r in $repairs) {
        & $add ("$($r.Time)  $($r.Title)")
        & $add ("      attempted: $($r.Attempted)   success: $($r.Success)   re-test improved: $($r.RetestImproved)")
        if ($r.Note) { & $add ("      note: $($r.Note)") }
    }
    & $add ''

    & $add '================ SESSION LOG ================'
    foreach ($l in (Get-GeeNetLogLines)) { & $add $l }
    & $add ''
    & $add '================ END OF REPORT ================'

    try {
        Set-Content -Path $file -Value $sb.ToString() -Encoding UTF8
        $script:GNSession.SavedReport = $file
        Write-GNOut ''
        Write-GNOut "  Report saved:" -Color Green
        Write-GNPara -Text $file -Color White -Indent 4
        Write-GNPara -Text "This report contains no passwords or personal files - only network configuration and test results." -Color DarkGray -Indent 4
        Write-GNOut ''
        Write-GNOut "  [1] Open the reports folder   [Enter] Back" -Color White
        $pick = Read-GNInput -Prompt '  Select an option'
        if ($pick -eq '1') { try { Start-Process explorer.exe -ArgumentList "/select,`"$file`"" } catch { try { Start-Process $script:GeeNetReports } catch { } } }
    } catch {
        Write-GNOut "  Could not save the report: $($_.Exception.Message)" -Color Red
        Pause-GeeNet
    }
}

function Get-GNDiagnosticReportSections {
    <#
      The diagnostic half of a report: what was asked, what was tested, what it means,
      what was repaired and what to do next.  Used by the network report so that a
      report made after a guided session carries the diagnosis as well as the config.
    #>
    param($Session = $script:GNSession)
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not $Session) { return (Get-GNArray -Items $lines) }
    $verdict = $Session.Verdict
    $hasTests = @((Get-GNArray -Items $Session.Results) | Where-Object { $_ -and "$($_.Layer)" -ne 'Context' }).Count -gt 0
    if (-not $hasTests -and -not $verdict) { return (Get-GNArray -Items $lines) }

    if ($Session.SymptomText) {
        [void]$lines.Add('================ PROBLEM REPORTED ================')
        [void]$lines.Add("$($Session.SymptomText)")
        if ($Session.CategoryId) {
            $cat = Get-GNCategory -Id "$($Session.CategoryId)"
            if ($cat) { [void]$lines.Add("Category : $($cat.Title)") }
        }
        if ($Session.Mode) { [void]$lines.Add("Mode     : $($Session.Mode)") }
        [void]$lines.Add('')
    }
    if ($Session.Answers -and @($Session.Answers.Keys).Count -gt 0) {
        [void]$lines.Add('================ ANSWERS GIVEN ================')
        foreach ($k in @($Session.Answers.Keys)) {
            $q = Get-GNQuestion -Id "$k"
            [void]$lines.Add("$(if ($q) { $q.Prompt } else { $k })")
            [void]$lines.Add("    -> $($Session.Answers[$k])")
        }
        [void]$lines.Add('')
    }

    if ($hasTests) {
        [void]$lines.Add('================ DIAGNOSTIC TESTS (result per check) ================')
        # A repair is followed by a re-check, so the session holds several results per
        # check.  Show each check once, in the order it first ran, with its latest result.
        $order = New-Object System.Collections.Generic.List[string]
        $latest = @{}
        foreach ($r in (Get-GNArray -Items $Session.Results)) {
            if (-not $r) { continue }
            if ("$($r.Layer)" -eq 'Context') { continue }
            $rid = "$($r.Id)"
            if (-not $rid) { $rid = "check-$($order.Count)" }
            if (-not $latest.ContainsKey($rid)) { [void]$order.Add($rid) }
            $latest[$rid] = $r
        }
        foreach ($rid in $order) {
            $r = $latest[$rid]
            [void]$lines.Add(("[{0}] {1} - {2}" -f "$($r.Status)".ToUpper(), $r.Name, $r.Summary))
            if ("$($r.Status)" -ne 'Pass' -and $r.Technical) { [void]$lines.Add("      technical: $($r.Technical)") }
            if ("$($r.Status)" -eq 'Skip' -and $r.SkipReason) { [void]$lines.Add("      skipped because: $($r.SkipReason)") }
        }
        [void]$lines.Add('')
    }

    if ($Session.StoppedReason) {
        [void]$lines.Add('================ WHY SOME TESTS WERE SKIPPED ================')
        [void]$lines.Add("$($Session.StoppedReason)")
        [void]$lines.Add('')
    }

    if ($Session.Findings -and @(Get-GNArray -Items $Session.Findings).Count -gt 0) {
        [void]$lines.Add('================ FINDINGS ================')
        foreach ($f in (Get-GNArray -Items $Session.Findings)) { [void]$lines.Add("$f") }
        [void]$lines.Add('')
    }

    if ($verdict) {
        [void]$lines.Add('================ LIKELY DIAGNOSIS ================')
        [void]$lines.Add("Headline   : $($verdict.Headline)")
        [void]$lines.Add("Layer      : $($verdict.Boundary)   (client-side: $($verdict.ClientSide))")
        [void]$lines.Add("Confidence : $($verdict.Confidence)   Status: $($verdict.Severity)")
        [void]$lines.Add('')
        [void]$lines.Add("$($verdict.Diagnosis)")
        [void]$lines.Add('')
        $causeList = @($verdict.LikelyCauses)
        if ($causeList.Count -eq 0) { $causeList = @($verdict.ManualActions) }
        if ($causeList.Count -gt 0) {
            [void]$lines.Add('Most likely causes:')
            foreach ($c in $causeList) { [void]$lines.Add("  - $c") }
        }
        [void]$lines.Add('')
        if (@($verdict.NextSteps).Count -gt 0) {
            [void]$lines.Add('Recommended next steps:')
            $n = 0
            foreach ($t in @($verdict.NextSteps)) { $n++; [void]$lines.Add("  $n. $t") }
        }
        if (@($verdict.ManualActions).Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('Only you can do these:')
            foreach ($t in @($verdict.ManualActions)) { [void]$lines.Add("  - $t") }
        }
        if ($verdict.BoundaryNote) {
            [void]$lines.Add('')
            [void]$lines.Add("Limit of what can be fixed from this PC: $($verdict.BoundaryNote)")
        }
        [void]$lines.Add('')
        [void]$lines.Add('What was checked (evidence):')
        foreach ($e in @($verdict.Evidence)) { [void]$lines.Add("  $e") }
        [void]$lines.Add('')
    }

    $repairs = Get-GNArray -Items $Session.Repairs
    [void]$lines.Add('================ REPAIRS ATTEMPTED ================')
    if (@($repairs).Count -eq 0) {
        [void]$lines.Add('None. No repair was run in this session - the diagnosis above explains why.')
    } else {
        foreach ($r in $repairs) {
            $state = if (-not $r.Attempted) { 'not run' } elseif ($r.Success -and $r.RetestImproved) { 'ran and the re-test improved' } elseif ($r.Success) { 'ran, but the re-test did not improve' } else { 'refused or reported an error' }
            [void]$lines.Add("$($r.Time)  $($r.Title)  [$($r.Risk) risk]  -> $state")
            if ($r.Note) { [void]$lines.Add("      note: $($r.Note)") }
            if ($r.Output) { foreach ($l in ("$($r.Output)" -split "`r?`n") | Where-Object { $_ } | Select-Object -First 6) { [void]$lines.Add("      output: $l") } }
        }
    }
    [void]$lines.Add('')
    return (Get-GNArray -Items $lines)
}

function Generate-Report {
    <#  Original GeeNet menu item (kept) - now generates a readable system report. #>
    param([switch]$NoPause)
    Write-Header
    Write-GNOut "  GENERATE NETWORK REPORT" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    Write-GNPara -Text "This writes a plain-text report of this computer's network configuration, suitable for sending to a technician or ISP." -Color $script:GNCol.Text -Indent 4
    Write-GNOut ''
    try {
        if (-not (Test-Path $script:GeeNetReports)) { New-Item -ItemType Directory -Path $script:GeeNetReports -Force | Out-Null }
    } catch { }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $file = Join-Path $script:GeeNetReports ("GeeNet_Network_Report_$stamp.txt")
    $body = @()
    $body += '================================================================'
    $body += ' GeeNet Network Report'
    $body += " Made by $($script:GeeNetAuthor)  $($script:GeeNetPhone)  $($script:GeeNetGitHub)"
    $body += " GeeNet version $($script:GeeNetVersion)"
    $body += '================================================================'
    $body += ''
    $body += (Get-GNSystemReportBody)
    $body += '================ ADAPTER DETAIL ================'
    try {
        $adDetail = @(Get-GNAdapters)
        if ($adDetail.Count -eq 0) { $body += '(no adapters reported)' }
        else {
            foreach ($a in $adDetail) {
                $kind = if ($a.IsWifi) { 'Wi-Fi' } elseif ($a.IsEthernet) { 'Ethernet' } elseif ($a.IsVirtual) { 'Virtual/tunnel' } else { 'Other' }
                $body += ("{0,-22} {1,-12} {2,-10} {3,-8} {4}" -f $a.Name, $a.Status, $kind, $a.LinkSpeed, $a.Description)
            }
        }
    } catch { $body += '(adapter detail unavailable)' }
    $body += '================ ARP / NEIGHBOURS ================'
    try { $body += (@(Get-GNNeighbors) | Format-Table IPAddress,LinkLayerAddress,State,InterfaceAlias -AutoSize | Out-String) } catch { }
    $body += '================ ACTIVE TCP CONNECTIONS (count) ================'
    try {
        $conns = @(Get-GNTcpConnections)
        $body += ("Total: " + $conns.Count)
        $body += ($conns | Group-Object State | ForEach-Object { "$($_.Name): $($_.Count)" })
    } catch { }
    $body += ''
    try {
        $sessionSections = @(Get-GNDiagnosticReportSections -Session $script:GNSession)
        if ($sessionSections.Count -gt 0) {
            $body += '################ DIAGNOSIS FROM THIS SESSION ################'
            $body += ''
            $body += $sessionSections
            $body += ''
        }
    } catch {
        $body += "(the diagnosis section could not be added: $($_.Exception.Message))"
    }
    $body += '================ SESSION DIAGNOSTIC LOG ================'
    foreach ($l in (Get-GeeNetLogLines)) { $body += $l }
    $body += ''
    $body += '================ END OF REPORT ================'
    try {
        Set-Content -Path $file -Value ($body -join "`r`n") -Encoding UTF8
        Write-GNOut "  Report saved:" -Color Green
        Write-GNPara -Text $file -Color White -Indent 4
        if ($script:GNLogFile) { Write-GNPara -Text "Session log: $($script:GNLogFile)" -Color DarkGray -Indent 4 }
    } catch {
        Write-GNOut "  Could not save the report: $($_.Exception.Message)" -Color Red
    }
    if (-not $NoPause) { Pause-GeeNet }
}

function Show-GNReports {
    param([switch]$NoPause)
    Write-Header
    Write-GNOut "  SAVED REPORTS" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    Write-GNPara -Text "Reports are saved in: $($script:GeeNetReports)" -Color $script:GNCol.Text -Indent 4
    Write-GNOut ''
    $files = @()
    try {
        if (Test-Path $script:GeeNetReports) {
            $files = @(Get-ChildItem -Path $script:GeeNetReports -Filter 'GeeNet_*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        }
    } catch { }
    if ($files.Count -eq 0) {
        Write-GNOut "  No reports saved yet. Use 'Generate Network Report' or save one at the end of a guided session." -Color DarkYellow
    } else {
        $i = 0
        foreach ($f in ($files | Select-Object -First 15)) {
            $i++
            Write-GNPara -Text ("[$i] " + $f.Name + "   (" + $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm') + ", " + [Math]::Round($f.Length/1KB,1) + " KB)") -Color $script:GNCol.Text -Indent 2
        }
        Write-GNOut ''
        Write-GNOut "  [O] Open the reports folder   [Enter] Back" -Color White
        $pick = Read-GNInput -Prompt '  Select an option'
        if ($pick -match '^(o|open)$') { try { Start-Process $script:GeeNetReports } catch { } }
        return
    }
    if (-not $NoPause) { Pause-GeeNet }
}

# ------------------------------------------------------------------------------
#region 24. PROFESSIONAL MODE - DIRECT TOOLS (original GeeNet tools, improved)
# ------------------------------------------------------------------------------

function Show-NetworkInfo {
    Write-Header
    Write-GNOut "  NETWORK INFORMATION" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    $adapters = @(Get-GNAdapters)

    Write-GNOut "  ADAPTERS" -Color Cyan
    Write-GNOut ''
    if ($adapters.Count -eq 0) {
        Write-GNOut "  No network adapters reported by Windows." -Color Red
    } else {
        Write-GNOut ("  {0,-20} {1,-13} {2,-14} {3}" -f 'Name', 'Status', 'Link speed', 'Description') -Color DarkGray
        foreach ($a in $adapters) {
            $col = switch ($a.Status) { 'Up' { 'Green' } 'Disabled' { 'Red' } default { 'DarkYellow' } }
            $name = if ($a.Name.Length -gt 19) { $a.Name.Substring(0,18) + '.' } else { $a.Name }
            $desc = if ($a.Description.Length -gt 34) { $a.Description.Substring(0,33) + '.' } else { $a.Description }
            Write-GNOut ("  {0,-20} {1,-13} {2,-14} {3}" -f $name, $a.Status, $a.LinkSpeed, $desc) -Color $col
        }
    }
    Write-GNOut ''

    Write-GNOut "  IP CONFIGURATION (active interfaces)" -Color Cyan
    Write-GNOut ''
    $configs = @(Get-GNIPConfig)
    if ($configs.Count -eq 0) {
        Write-GNOut "  No IP configuration available." -Color Red
    }
    foreach ($c in $configs) {
        $status = "$($c.AdapterStatus)"
        $col = if ($c.Apipa) { 'Red' } elseif ($c.IPv4) { 'Green' } else { 'DarkYellow' }
        Write-GNOut ("  " + $c.Adapter) -Color White
        Write-GNOut ("    IPv4 address : " + $(if ($c.IPv4) { $c.IPv4 } else { '(none)' }) + $(if ($c.PrefixLength -ne $null) { "  /$($c.PrefixLength)  mask $($c.SubnetMask)" } else { '' })) -Color $col
        Write-GNOut ("    Gateway      : " + $(if ($c.Gateway) { $c.Gateway } else { '(none configured)' })) -Color $(if ($c.Gateway) { 'Gray' } else { 'DarkYellow' })
        Write-GNOut ("    DNS servers  : " + $(if (@($c.DnsServers).Count) { (@($c.DnsServers) -join ', ') } else { '(none configured)' })) -Color Gray
        Write-GNOut ("    DHCP         : " + $(if ($c.DhcpEnabled -eq $true) { 'automatic (DHCP)' } elseif ($c.DhcpEnabled -eq $false) { 'manual/static' } else { 'unknown' })) -Color Gray
        if ($c.ProfileName) { Write-GNOut ("    Network      : " + $c.ProfileName + " [" + $c.NetworkCategory + "]") -Color Gray }
        Write-GNOut ''
    }

    # Teaching notes on the address that was found
    $primary = Get-GNActiveAdapter
    if ($primary -and $primary.Config -and $primary.Config.IPv4) {
        $ip = "$($primary.Config.IPv4)"
        if ($ip -like '169.254.*') {
            Write-GNWarn "Note: $ip is a self-assigned (APIPA) address - Windows gave it to itself because no DHCP server answered."
        } elseif ($ip -match '^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[01])\.') {
            Write-GNPara -Text "Note: $ip is a private IPv4 address (RFC 1918) - the normal kind of address used inside home and office networks. It is translated to a public address by your router when you reach the internet." -Color DarkGray -Indent 4
        } elseif ($ip -match '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.') {
            Write-GNPara -Text "Note: $ip is in the carrier-grade NAT range (100.64.0.0/10), typical of mobile or shared ISP connections." -Color DarkGray -Indent 4
        } else {
            Write-GNPara -Text "Note: $ip is a public/global address - this computer is reachable directly from the internet on that address." -Color DarkGray -Indent 4
        }
        Write-GNOut ''
    }
    Pause-GeeNet
}

function Test-Internet {
    <#  Original menu item - now an interpreted, sequential check instead of a bare OK/FAILED list. #>
    Write-Header
    Write-GNOut "  INTERNET CONNECTIVITY TEST" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Pause-GNContinue '  Press Enter to run the interpreted connectivity check'
    $plan = @('Adapter','IP','DHCP','Gateway','GatewayReach','InternetIP','CaptivePortal','DNS','HTTPS')
    $inv = Invoke-GNInvestigation -Plan $plan -Focus 'Reachability' -Quiet
    Write-GNOut ''
    Write-GNOut "  INTERNET CONNECTIVITY RESULTS" -Color Cyan
    Write-GNRule '=' 2 ($script:GNW - 4) Cyan
    Write-GNOut ''
    $i = 0
    foreach ($r in $inv.Results) {
        $i++
        $statusText = switch ($r.Status) { 'Pass' { 'PASS' } 'Fail' { 'FAIL' } 'Warn' { 'WARN' } 'Skip' { 'SKIP' } default { 'INFO' } }
        Write-GNStepLine -Index $i -Total (Get-GNArray -Items $inv.Results).Count -Name $r.Name -Status $statusText -DurationMs $r.DurationMs
        if ($r.Status -eq 'Fail' -or $r.Status -eq 'Warn') {
            Write-GNPara -Text $r.Summary -Color $script:GNCol.Text -Indent 6
        }
    }
    Write-GNVerdict -Verdict $inv.Verdict
    Write-GNOut "  Tip: use 'Run Full Diagnostics' for the detailed reasoning behind each step, or Beginner mode for guided repairs." -Color DarkGray
    Pause-GeeNet
}

function Pause-GNContinue {
    param([string]$Message = '  Press Enter to continue')
    Write-GNOut ''
    [void](Read-GNInput -Prompt $Message)
    Write-GNOut ''
}

function Ping-Gateway {
    Write-Header
    Write-GNOut "  GATEWAY PING" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    $gw = Get-GNDefaultGateway
    if (-not $gw) {
        Write-GNOut "  No default gateway is configured, so there is nothing to ping." -Color Red
        Write-GNPara -Text "This normally means the computer has no valid DHCP address. Check the IP configuration (option 1) or run the guided 'IP address / DHCP' checks." -Color $script:GNCol.Text -Indent 4
        Pause-GeeNet
        return
    }
    Write-GNOut "  Pinging router $gw ..." -Color Gray
    $p = Invoke-GNPing -Target $gw -Count 4 -TimeoutMs 1500
    Write-GNOut ''
    Write-GNOut ("  Replies    : " + $p.Received + "/" + $p.Sent + "  (" + $p.LossPercent + "% loss)") -Color $(if ($p.Success) { 'Green' } else { 'Red' })
    if ($p.Success) {
        Write-GNOut ("  Round trip : min " + $p.MinMs + " ms / avg " + $p.AvgMs + " ms / max " + $p.MaxMs + " ms  (jitter " + $p.JitterMs + " ms)") -Color Gray
        Write-GNOut ''
        if ($p.AvgMs -gt 20) {
            Write-GNPara -Text "A local-network ping is normally under 5 ms on cable and under 15 ms on Wi-Fi. $($p.AvgMs) ms suggests a busy or weak link, but the router is reachable." -Color DarkYellow -Indent 4
        } else {
            Write-GNPara -Text "The router answered quickly, so the local network path is healthy." -Color Green -Indent 4
        }
    } else {
        Write-GNPara -Text "The router did not answer ping. Some routers are configured to ignore ping, so GeeNet checks the ARP table and a TCP connection before calling this a failure." -Color DarkYellow -Indent 4
        Write-GNOut ''
        $neigh = @(Get-GNNeighbors) | Where-Object { "$($_.IPAddress)" -eq "$gw" } | Select-Object -First 1
        if ($neigh -and "$($neigh.LinkLayerAddress)") {
            Write-GNOut ("  Router MAC address is present in the ARP table: " + $neigh.LinkLayerAddress) -Color Green
            Write-GNPara -Text "That means the router IS reachable at the link level; it is just ignoring ICMP ping." -Color Green -Indent 4
        } else {
            Write-GNOut "  No ARP entry for the router." -Color Red
            Write-GNPara -Text "No hardware address and no ping reply means the router is genuinely unreachable from this computer - a local network problem (cable, Wi-Fi, IP configuration or the router itself)." -Color $script:GNCol.Text -Indent 4
            Write-GNOut ''
            Write-GNOut "  Run 'Gateway reachability' from the diagnostics engine (Beginner mode, 'Router' category) for the full interpretation and repairs." -Color $script:GNCol.Action
        }
    }
    Write-GNOut ''
    Write-GNTech ("ICMP echo: $($p.Sent) sent, $($p.Received) replies, statuses $($p.Statuses -join '/')")
    Pause-GeeNet
}

function Ping-Google {
    Write-Header
    Write-GNOut "  INTERNET PING" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    $target = Read-GNInput -Prompt "  Host to ping [default: 1.1.1.1, 'd' = resolve google.com first]"
    if ($target -match '^(d|domain)$') { $target = 'google.com' }
    if ([string]::IsNullOrWhiteSpace($target)) { $target = '1.1.1.1' }
    Write-GNOut ''
    $resolved = ''
    try { $resolved = ([System.Net.Dns]::GetHostAddresses($target) | Select-Object -First 1).ToString() } catch { }
    if ($resolved -and $resolved -ne $target) { Write-GNOut "  $target resolves to $resolved" -Color DarkGray }
    Write-GNOut "  Pinging $target ..." -Color Gray
    $p = Invoke-GNPing -Target $target -Count 6 -TimeoutMs 2000
    Write-GNOut ''
    Write-GNOut ("  Replies    : " + $p.Received + "/" + $p.Sent + "  (" + $p.LossPercent + "% loss)") -Color $(if ($p.Success) { 'Green' } else { 'Red' })
    if ($p.Success) {
        Write-GNOut ("  Round trip : min " + $p.MinMs + " ms / avg " + $p.AvgMs + " ms / max " + $p.MaxMs + " ms  (jitter " + $p.JitterMs + " ms)") -Color Gray
        Write-GNOut ''
        if ($p.LossPercent -gt 0) {
            Write-GNPara -Text "Packet loss detected. Losing packets is what causes stuttering calls, lag and stalled downloads even when the connection 'works'." -Color DarkYellow -Indent 4
        } elseif ($p.AvgMs -gt 150) {
            Write-GNPara -Text "Reachable but with high delay ($($p.AvgMs) ms average). Fine for browsing, poor for calls and gaming." -Color DarkYellow -Indent 4
        } else {
            Write-GNPara -Text "Healthy round trip times to $target." -Color Green -Indent 4
        }
    } else {
        Write-GNPara -Text "No replies. Note that many networks block ping (ICMP) while web traffic still works - GeeNet's HTTPS/port checks distinguish 'ping blocked' from 'no internet'." -Color DarkYellow -Indent 4
        Write-GNTech "ICMP echo: $($p.Sent) sent, $($p.Received) replies, statuses $($p.Statuses -join '/')"
        Write-GNOut ''
        Write-GNOut "  Run 'Internet Connectivity Test' (Professional > 2) for the full interpreted result." -Color $script:GNCol.Action
    }
    Pause-GeeNet
}

function DNS-Lookup {
    Write-Header
    Write-GNOut "  DNS LOOKUP" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    $domain = Read-GNInput -Prompt "  Domain to look up [default: www.google.com]"
    if ([string]::IsNullOrWhiteSpace($domain)) { $domain = 'www.google.com' }
    Write-GNOut ''
    $local = Invoke-GNDnsQuery -Name $domain -TimeoutSec 8
    Write-GNOut "  Resolving with the DNS servers this computer uses:" -Color Gray
    if ($local.Success) {
        Write-GNOut ("    " + $local.Addresses.Count + " address(es) in " + $local.ElapsedMs + " ms") -Color $(if ($local.ElapsedMs -gt 1200) { 'DarkYellow' } else { 'Green' })
        foreach ($a in $local.Addresses) { Write-GNOut "      $a" -Color Gray }
        if ($local.ElapsedMs -gt 1200) { Write-GNPara -Text "That lookup took longer than 1.2 s - slow DNS makes every website feel slow to start loading." -Color DarkYellow -Indent 4 }
    } else {
        Write-GNOut "    FAILED: $($local.Error)" -Color Red
    }
    Write-GNOut ''
    Write-GNOut "  Comparing with a public resolver (1.1.1.1):" -Color Gray
    $pub = Invoke-GNDnsQuery -Name $domain -Server '1.1.1.1' -TimeoutSec 8
    if ($pub.Success) {
        Write-GNOut ("    " + $pub.Addresses.Count + " address(es) in " + $pub.ElapsedMs + " ms") -Color Green
        foreach ($a in $pub.Addresses) { Write-GNOut "      $a" -Color Gray }
    } else {
        Write-GNOut "    FAILED: $($pub.Error)" -Color Red
    }
    Write-GNOut ''
    if (-not $local.Success -and $pub.Success) {
        Write-GNPara -Text "Your computer's DNS servers are not resolving names that a public resolver resolves fine. That points at the DNS server being used (often the router's DNS proxy, or a leftover VPN/filtering setting) - not at the internet connection." -Color DarkYellow -Indent 4
    } elseif (-not $local.Success -and -not $pub.Success) {
        Write-GNPara -Text "Neither resolver could resolve that name. Check the spelling, and check whether the whole internet path is working (the name may simply not exist)." -Color DarkYellow -Indent 4
    } elseif ($local.Success -and $pub.Success -and ($local.Addresses -join ',') -ne ($pub.Addresses -join ',')) {
        Write-GNPara -Text "The two resolvers returned different addresses. That can be normal (load balancing, CDNs, or DNS filtering in your network)." -Color DarkGray -Indent 4
    } else {
        Write-GNPara -Text "Name resolution is working normally." -Color Green -Indent 4
    }
    Pause-GeeNet
}

function Flush-DNS {
    Write-Header
    Write-GNOut "  FLUSH DNS CACHE" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    $before = Get-GNStatusMap -Results @()
    [void](Invoke-GNRepairFlow -Id 'FlushDns' -Before $before)
    Pause-GeeNet
}

function Release-IP {
    Write-Header
    Write-GNOut "  RELEASE IP ADDRESS" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    Write-GNPara -Text "Releasing gives this computer's IP address back to the network. The computer will have no usable address (and no internet) until it renews or you do that yourself." -Color $script:GNCol.Text -Indent 4
    Write-GNPara -Text "Useful when you deliberately want to force a fresh DHCP conversation, or when troubleshooting address conflicts." -Color DarkGray -Indent 4
    Write-GNOut ''
    $active = Get-GNActiveAdapter
    if ($active -and $active.Config -and $active.Config.IPv4) {
        Write-GNOut ("  Current address on '$($active.Config.Adapter)': $($active.Config.IPv4) / $($active.Config.SubnetMask)") -Color Gray
    }
    Write-GNOut ''
    $ok = Read-GNConfirm -Prompt "  Release the IP address now?" -DefaultYes $false
    if (-not $ok) {
        Write-GNPara -Text "Nothing was changed." -Color DarkGray -Indent 4
        Pause-GeeNet
        return
    }
    $adapter = if ($active) { "$($active.Config.Adapter)" } else { '' }
    $code = if ($adapter) { 'ipconfig /release "' + $adapter + '" | Out-String' } else { 'ipconfig /release | Out-String' }
    $exec = Invoke-GNRepairCode -Code $code -NeedsAdmin $false
    Write-GNOut ''
    if ($exec.Output) {
        foreach ($line in ("$($exec.Output)" -split "`r?`n")) { if ($line.Trim()) { Write-GNPara -Text $line.Trim() -Color $script:GNCol.Tech -Indent 4 } }
    }
    Write-GNPara -Text "Released. Run 'Renew IP Address' to obtain a fresh address." -Color Green -Indent 4
    Pause-GeeNet
}

function Renew-IP {
    Write-Header
    Write-GNOut "  RENEW IP ADDRESS" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    Write-GNPara -Text "This asks the network's DHCP service for an address (and refreshes the gateway, DNS and routes that come with it)." -Color $script:GNCol.Text -Indent 4
    Write-GNOut ''
    $ok = Read-GNConfirm -Prompt "  Renew the IP address now?" -DefaultYes $true
    if (-not $ok) {
        Write-GNPara -Text "Nothing was changed." -Color DarkGray -Indent 4
        Pause-GeeNet
        return
    }
    $active = Get-GNActiveAdapter
    $adapter = if ($active) { "$($active.Config.Adapter)" } else { '' }
    $code = if ($adapter) { 'ipconfig /renew "' + $adapter + '" | Out-String' } else { 'ipconfig /renew | Out-String' }
    $exec = Invoke-GNRepairCode -Code $code -NeedsAdmin $false
    Write-GNOut ''
    if ($exec.Output) {
        foreach ($line in ("$($exec.Output)" -split "`r?`n")) { if ($line.Trim()) { Write-GNPara -Text $line.Trim() -Color $script:GNCol.Tech -Indent 4 } }
    }
    Write-GNOut ''
    $cfg = Get-GNIPConfig | Where-Object { $_.IPv4 } | Select-Object -First 1
    if ($cfg) {
        Write-GNOut ("  Address now : $($cfg.IPv4) / $($cfg.SubnetMask)") -Color Green
        Write-GNOut ("  Gateway now : " + $(if ($cfg.Gateway) { $cfg.Gateway } else { '(none)' })) -Color Gray
        Write-GNOut ("  DNS now     : " + $(if (@($cfg.DnsServers).Count) { (@($cfg.DnsServers) -join ', ') } else { '(none)' })) -Color Gray
        if ($cfg.Apipa) {
            Write-GNOut ''
            Write-GNPara -Text "The address is still a 169.254 self-assigned address, which means DHCP is still not answering. At this point the router's DHCP service (or the link to it) is the likely problem - not this computer." -Color DarkYellow -Indent 4
        }
    } else {
        Write-GNOut "  No IPv4 address was obtained. If this repeats, the DHCP service on the router is the likely cause." -Color DarkYellow
    }
    Pause-GeeNet
}

function Reset-Winsock {
    Write-Header
    Write-GNOut "  RESET WINSOCK" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    [void](Invoke-GNRepairFlow -Id 'WinsockReset')
    Pause-GeeNet
}

function Reset-TCPIP {
    Write-Header
    Write-GNOut "  RESET TCP/IP STACK" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    [void](Invoke-GNRepairFlow -Id 'TcpIpReset')
    Pause-GeeNet
}

function Trace-Route {
    Write-Header
    Write-GNOut "  TRACE ROUTE" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    $hostName = Read-GNInput -Prompt "  Target host [default: 1.1.1.1]"
    if ([string]::IsNullOrWhiteSpace($hostName)) { $hostName = '1.1.1.1' }
    Write-GNOut ''
    Write-GNOut "  [1] Numeric only (fastest - no name lookups)" -Color White
    Write-GNOut "  [2] With host names (slower, more readable)" -Color White
    Write-GNOut ''
    $mode = Read-GNInput -Prompt "  Choose [default: 1]"
    $args = @('-d')                          # -d = do not resolve addresses to host names
    if ($mode -eq '2') { $args = @() }
    $gw = Get-GNDefaultGateway
    if ($gw) {
        Write-GNPara -Text "The first hop should be your router ($gw). If the trace stops before that, the problem is inside your own network. If it stops after the router, it is upstream (ISP or beyond)." -Color $script:GNCol.Text -Indent 4
        Write-GNOut ''
    }
    Write-GNOut "  Tracing route to $hostName (this can take up to a minute) ..." -Color DarkGray
    Write-GNOut ''
    $args += @('-h','20',$hostName)
    $out = Invoke-GNNative -File 'tracert' -Arguments $args -TimeoutSec 120
    $text = "$($out.Output)"
    foreach ($line in ($text -split "`r?`n")) {
        if ($line.Trim().Length -eq 0) { continue }
        $col = 'Gray'
        if ($line -match '^\s*1\s') { $col = 'White' }
        if ($line -match '\*\s+\*\s+\*') { $col = 'DarkYellow' }
        Write-GNPara -Text $line.Trim() -Color $col -Indent 2
    }
    if ($out.TimedOut) { Write-GNWarn "The trace reached the time limit and was stopped." }
    Write-GNOut ''
    $hopCount = ([regex]::Matches($text, '(?m)^\s*\d+\s')).Count
    $starHops = ([regex]::Matches($text, '(?m)^\s*\d+\s+\*\s+\*\s+\*')).Count
    if ($hopCount -gt 0) {
        Write-GNOut ("  Hops seen: $hopCount   Silent hops (no reply): $starHops") -Color DarkGray
        if ($starHops -gt 0 -and $starHops -eq $hopCount) {
            Write-GNPara -Text "Every hop stayed silent, which usually means the network is blocking ICMP - or nothing is reachable at all. Compare with a successful internet test before drawing conclusions." -Color DarkYellow -Indent 4
        } elseif ($starHops -gt 0) {
            Write-GNPara -Text "Some hops ignored the probe. That is common and not necessarily a fault - what matters is whether the trace reaches the destination." -Color DarkGray -Indent 4
        } else {
            Write-GNPara -Text "The trace completed with replies from every hop." -Color Green -Indent 4
        }
    }
    Pause-GeeNet
}

function Show-ARP {
    Write-Header
    Write-GNOut "  ARP / NEIGHBOUR TABLE" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    $result = Test-ARP
    $neighbors = @(Get-GNNeighbors)
    if ($neighbors.Count -eq 0) {
        Write-GNOut "  No neighbour entries (the table is empty)." -Color DarkYellow
    } else {
        Write-GNOut ("  {0,-16} {1,-18} {2,-12} {3}" -f 'IP address', 'MAC address', 'State', 'Interface') -Color DarkGray
        foreach ($n in $neighbors) {
            $col = if ("$($n.State)" -match 'Incomplete|Unreachable') { 'DarkYellow' } else { 'Gray' }
            Write-GNOut ("  {0,-16} {1,-18} {2,-12} {3}" -f "$($n.IPAddress)", "$($n.LinkLayerAddress)", "$($n.State)", "$($n.InterfaceAlias)") -Color $col
        }
    }
    Write-GNOut ''
    Write-GNOut "  INTERPRETATION" -Color Cyan
    Write-GNPara -Text $result.Summary -Color $script:GNCol.Text -Indent 4
    if ($result.Status -ne 'Pass') {
        Write-GNList -Items $result.Causes -Color $script:GNCol.Text -Indent 6
    }
    Pause-GeeNet
}

function Show-Routes {
    Write-Header
    Write-GNOut "  ROUTING TABLE" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    $routes = @(Get-GNRoutes)
    Write-GNOut ("  {0,-20} {1,-16} {2,-8} {3}" -f 'Destination', 'Next hop', 'Metric', 'Interface') -Color DarkGray
    foreach ($r in ($routes | Sort-Object { "$($_.DestinationPrefix)" }, RouteMetric)) {
        $col = if ("$($r.DestinationPrefix)" -eq '0.0.0.0/0') { 'White' } else { 'Gray' }
        Write-GNOut ("  {0,-20} {1,-16} {2,-8} {3}" -f "$($r.DestinationPrefix)", "$($r.NextHop)", "$($r.RouteMetric)", "$($r.InterfaceAlias)") -Color $col
    }
    Write-GNOut ''
    $result = Test-Route
    Write-GNOut "  INTERPRETATION" -Color Cyan
    Write-GNPara -Text $result.Summary -Color $script:GNCol.Text -Indent 4
    if ($result.Status -ne 'Pass') { Write-GNList -Items $result.Causes -Color $script:GNCol.Text -Indent 6 }
    Pause-GeeNet
}

function Show-Connections {
    Write-Header
    Write-GNOut "  ACTIVE TCP CONNECTIONS" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    $conns = @(Get-GNTcpConnections)
    if ($conns.Count -eq 0) {
        Write-GNOut "  No TCP connections reported." -Color DarkYellow
    } else {
        $byState = @($conns | Group-Object State | Sort-Object Count -Descending)
        Write-GNOut "  By state:" -Color Cyan
        foreach ($g in $byState) { Write-GNOut ("    " + $g.Name.PadRight(14) + $g.Count) -Color Gray }
        Write-GNOut ''
        Write-GNOut "  Remote endpoints (top 12 by connection count):" -Color Cyan
        $byRemote = @($conns | Where-Object { "$($_.RemoteAddress)" -and "$($_.RemoteAddress)" -ne '0.0.0.0' -and "$($_.RemoteAddress)" -ne '::' } |
                     Group-Object RemoteAddress | Sort-Object Count -Descending | Select-Object -First 12)
        foreach ($g in $byRemote) { Write-GNOut ("    " + $g.Name.PadRight(24) + $g.Count + " connection(s)") -Color Gray }
        Write-GNOut ''
        $est = @($conns | Where-Object { "$($_.State)" -match 'Established' })
        Write-GNPara -Text "$($conns.Count) TCP connections in total, $($est.Count) currently established." -Color DarkGray -Indent 4
        if ($est.Count -gt 150) {
            Write-GNPara -Text "That is a high number of established connections. If you are troubleshooting slow or unstable internet, this is worth noting - a home router's connection table can fill up, which is what 'the internet dies when I download' looks like." -Color DarkYellow -Indent 4
        }
    }
    Pause-GeeNet
}

function Show-WiFi {
    Write-Header
    Write-GNOut "  WI-FI INFORMATION" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    $result = Test-WiFi
    $w = Get-GNWifiInfo
    if ($w.Present -or $w.SSID) {
        Write-GNOut ("  Adapter      : " + $w.Name) -Color Gray
        Write-GNOut ("  State        : " + $w.State) -Color Gray
        Write-GNOut ("  SSID         : " + $w.SSID) -Color White
        Write-GNOut ("  Signal       : " + $w.SignalPercent + "%") -Color $(if ($w.SignalPercent -ne $null -and $w.SignalPercent -lt 40) { 'Red' } elseif ($w.SignalPercent -ne $null -and $w.SignalPercent -lt 60) { 'DarkYellow' } else { 'Green' })
        Write-GNOut ("  Radio        : " + $w.RadioType + "  channel " + $w.Channel + "  " + $(if ("$($w.Channel)" -match '^\d+$' -and [int]"$($w.Channel)" -le 14) { '(2.4 GHz)' } elseif ("$($w.Channel)" -match '^\d+$') { '(5 GHz)' } else { '' })) -Color Gray
        Write-GNOut ("  Security     : " + $w.Authentication + " / " + $w.Cipher) -Color Gray
        Write-GNOut ("  Link rates   : rx " + $w.ReceiveRate + " / tx " + $w.TransmitRate + " Mbps") -Color Gray
    } else {
        Write-GNOut "  No Wi-Fi interface information available." -Color DarkYellow
        if ($w.Error) { Write-GNOut ("  " + $w.Error) -Color DarkGray }
    }
    Write-GNOut ''
    $scan = Test-WiFiScan
    Write-GNOut "  NEARBY NETWORKS" -Color Cyan
    if ($scan.Data.ContainsKey('Visible') -and @($scan.Data.Visible).Count -gt 0) {
        $n = 0
        foreach ($v in @($scan.Data.Visible | Select-Object -First 15)) { $n++; Write-GNOut ("    [$n] $v") -Color Gray }
    } else {
        Write-GNOut "    (none visible) $($scan.Summary)" -Color DarkYellow
    }
    Write-GNOut ''
    $profiles = @(Get-GNWifiProfiles)
    Write-GNOut "  SAVED PROFILES ($($profiles.Count))" -Color Cyan
    if ($profiles.Count -eq 0) { Write-GNOut "    (no saved Wi-Fi profiles)" -Color DarkGray }
    foreach ($p in ($profiles | Select-Object -First 12)) { Write-GNOut ("    $p") -Color Gray }
    Write-GNOut ''
    Write-GNOut "  INTERPRETATION" -Color Cyan
    Write-GNPara -Text $result.Summary -Color $script:GNCol.Text -Indent 4
    if ($result.Status -ne 'Pass') {
        Write-GNList -Items $result.Causes -Color $script:GNCol.Text -Indent 6
        Write-GNOut ''
        Write-GNOut "  Next steps:" -Color $script:GNCol.Info
        $i = 1
        foreach ($s in $result.NextSteps) { Write-GNPara -Text "$i. $s" -Color $script:GNCol.Action -Indent 6; $i++ }
    }
    Pause-GeeNet
}

function Show-ProxyState {
    Write-Header
    Write-GNOut "  PROXY / VPN INTERFERENCE CHECK" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    $r1 = Add-GNResult -Result (Test-Proxy)
    $r2 = Add-GNResult -Result (Test-VPN)
    Pause-GeeNet
}

function Show-LatencyLoss {
    Write-Header
    Write-GNOut "  LATENCY & PACKET LOSS TEST" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    Write-GNPara -Text "Sending 12 probes to your router and to the internet, measuring delay, jitter and loss." -Color $script:GNCol.Text -Indent 4
    Write-GNOut ''
    $lat = Test-Latency -Count 12 -IncludeGateway
    $loss = Test-PacketLoss -Count 12
    Add-GNResult -Result $lat | Out-Null
    Add-GNResult -Result $loss | Out-Null
    Pause-GeeNet
}

function Show-StabilityMonitor {
    Write-Header
    Write-GNOut "  STABILITY MONITOR" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    Write-GNPara -Text "This watches the connection over time and records dropouts, link changes and loss bursts. That is the only reliable way to catch intermittent faults." -Color $script:GNCol.Text -Indent 4
    Write-GNOut ''
    $secs = Read-GNInput -Prompt "  How many seconds to monitor? [default: 60]"
    $n = 60
    [void][int]::TryParse("$secs", [ref]$n)
    if ($n -lt 10 -or $n -gt 600) { $n = 60 }
    Write-GNOut ''
    Write-GNOut "  Monitoring for $n seconds (a dot per check, 'x' = a failed check) ..." -Color Cyan
    $r = Test-Stability -Seconds $n
    Write-GNOut ''
    Add-GNResult -Result $r | Out-Null
    Pause-GeeNet
}

function Show-StackCheck {
    Write-Header
    Write-GNOut "  WINDOWS NETWORK STACK & SERVICES" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Add-GNResult -Result (Test-NetworkStack) | Out-Null
    Add-GNResult -Result (Test-Services) | Out-Null
    Add-GNResult -Result (Test-Firewall) | Out-Null
    Add-GNResult -Result (Test-HostsFile) | Out-Null
    Pause-GeeNet
}

function Show-MTUTest {
    Write-Header
    Write-GNOut "  PACKET SIZE (MTU) TEST" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    Write-GNPara -Text "Finding the largest packet that can pass without fragmentation. An MTU problem makes some sites, logins and VPNs fail while others work." -Color $script:GNCol.Text -Indent 4
    Write-GNOut ''
    Add-GNResult -Result (Test-MTU) | Out-Null
    Pause-GeeNet
}

function Show-AppConnectivity {
    Write-Header
    Write-GNOut "  APPLICATION / SERVICE CONNECTIVITY TEST" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    Write-GNOut "  Choose the service to test:" -Color White
    $i = 0
    foreach ($p in $script:GNAppProfiles) {
        $i++
        Write-GNOut ("  [$i] $($p.Name)") -Color $script:GNCol.Text
    }
    Write-GNOut "  [C] Custom host/port" -Color White
    Write-GNOut ''
    $pick = Read-GNChoice -Prompt '  Select a service'
    if ($pick -match '^(c|custom)$') {
        $h = Read-GNInput -Prompt "  Host or IP address"
        $p = Read-GNInput -Prompt "  Port [default: 443]"
        $port = 443
        [void][int]::TryParse("$p", [ref]$port)
        if ($h) {
            Write-GNOut ''
            Add-GNResult -Result (Test-ApplicationConnectivity -Host $h -Port $port -Label "$h`:$port") | Out-Null
        }
    } else {
        $idx = 0
        [void][int]::TryParse("$pick", [ref]$idx)
        if ($idx -ge 1 -and $idx -le $script:GNAppProfiles.Count) {
            $profile = $script:GNAppProfiles[$idx - 1]
            Write-GNOut ''
            Add-GNResult -Result (Test-ApplicationConnectivity -ProfileKey $profile.Key) | Out-Null
        }
    }
    Pause-GeeNet
}

function Show-DiagnosticLogMenu {
    Show-GNDiagnosticLog
}

function Open-NetworkSettings {
    Write-Header
    Write-GNOut "  OPENING WINDOWS NETWORK SETTINGS" -Color Yellow
    Write-GNOut ''
    try { Start-Process 'ms-settings:network-status'; Write-GNOut "  Opened the Windows network status page." -Color Green }
    catch { Write-GNOut "  Could not open Settings automatically. Open Settings > Network & Internet manually." -Color DarkYellow }
    Pause-GeeNet
}

function Open-NetworkConnections {
    Write-Header
    Write-GNOut "  OPENING NETWORK CONNECTIONS" -Color Yellow
    Write-GNOut ''
    try { Start-Process 'ncpa.cpl'; Write-GNOut "  Opened Network Connections (adapters)." -Color Green }
    catch { Write-GNOut "  Could not open Network Connections. Run 'ncpa.cpl' from the Run dialog." -Color DarkYellow }
    Pause-GeeNet
}

function Open-DeviceManager {
    Write-Header
    Write-GNOut "  OPENING DEVICE MANAGER" -Color Yellow
    Write-GNOut ''
    try { Start-Process 'devmgmt.msc'; Write-GNOut "  Opened Device Manager. Look under 'Network adapters' for warning symbols." -Color Green }
    catch { Write-GNOut "  Could not open Device Manager. Run 'devmgmt.msc' from the Run dialog (Administrator)." -Color DarkYellow }
    Pause-GeeNet
}

function Open-Troubleshooter {
    Write-Header
    Write-GNOut "  WINDOWS NETWORK TROUBLESHOOTER" -Color Yellow
    Write-GNOut ''
    try { Start-Process 'ms-settings:troubleshoot'; Write-GNOut "  Opened the Windows troubleshooters page." -Color Green }
    catch { Write-GNOut "  Could not open the troubleshooter automatically." -Color DarkYellow }
    Write-GNOut ''
    Write-GNPara -Text "Windows' own troubleshooter is quick and safe, but its explanations are thin - GeeNet's guided mode gives the reasoning and the retest that Windows does not." -Color DarkGray -Indent 4
    Pause-GeeNet
}

function Continuous-Ping {
    <#  Kept from the original tool, rewritten so it can show running statistics. #>
    Write-Header
    Write-GNOut "  CONTINUOUS PING" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    $target = Read-GNInput -Prompt "  Host to ping [default: 1.1.1.1]"
    if ([string]::IsNullOrWhiteSpace($target)) { $target = '1.1.1.1' }
    Write-GNOut ''
    $gw = Get-GNDefaultGateway
    if ($gw -and $target -eq $gw) { Write-GNPara -Text "Pinging your router - this isolates the local network from the internet." -Color DarkGray -Indent 4 }
    Write-GNPara -Text "Press Q then Enter to stop and see the summary. Keep this window small and let it run - when the connection drops, press Q straight away and the summary shows what happened." -Color DarkGray -Indent 4
    Write-GNOut ''
    $sent = 0; $recv = 0; $times = New-Object System.Collections.Generic.List[int]; $gaps = New-Object System.Collections.Generic.List[string]
    $start = Get-Date
    $consecutive = 0
    while ($true) {
        # non-blocking keyboard check (works in the console host)
        try {
            # KeyAvailable throws when the console is not a real console (piped input,
            # some terminals, scheduled runs) - check first so no error is raised at all.
            if ((-not [Console]::IsInputRedirected) -and [Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ("$($key.Key)" -eq 'Q') { break }
            }
        } catch { break }
        $sent++
        $p = Invoke-GNPing -Target $target -Count 1 -TimeoutMs 1500
        if ($p.Success) {
            $recv++
            $times.Add([int]$p.MinMs)
            if ($consecutive -ge 2) { $gaps.Add((Get-Date).ToString('HH:mm:ss') + " recovered after $consecutive failed checks") }
            $consecutive = 0
            Write-GNOut ("  " + (Get-Date).ToString('HH:mm:ss') + "  reply in " + $p.MinMs + " ms") -Color Green
        } else {
            $consecutive++
            $gaps.Add((Get-Date).ToString('HH:mm:ss') + " no reply (status $($p.Statuses -join '/'))")
            Write-GNOut ("  " + (Get-Date).ToString('HH:mm:ss') + "  no reply - status $($p.Statuses -join '/')") -Color Red
        }
        if ($script:GNInteractive) { Start-Sleep -Seconds 1 } else { break }
        if (((Get-Date) - $start).TotalHours -gt 2) { Write-GNOut "  Stopping after 2 hours." -Color DarkYellow; break }
    }
    $dur = (Get-Date) - $start
    Write-GNOut ''
    Write-GNRule '-' 2 ($script:GNW - 4) DarkCyan
    $loss = if ($sent -gt 0) { [Math]::Round((($sent - $recv) / $sent) * 100, 1) } else { 0 }
    Write-GNOut ("  Target      : $target") -Color White
    Write-GNOut ("  Duration    : " + [Math]::Round($dur.TotalSeconds,0) + " s") -Color Gray
    Write-GNOut ("  Sent/replies: $sent / $recv   ($loss% loss)") -Color $(if ($loss -gt 0) { 'DarkYellow' } else { 'Green' })
    if ($times.Count -gt 0) {
        Write-GNOut ("  Round trip  : min " + ($times | Measure-Object -Minimum).Minimum + " ms / avg " + [Math]::Round(($times | Measure-Object -Average).Average,1) + " ms / max " + ($times | Measure-Object -Maximum).Maximum + " ms") -Color Gray
    }
    if ($gaps.Count -gt 0 -and $loss -gt 0) {
        Write-GNOut ''
        Write-GNOut "  Interruptions recorded:" -Color Cyan
        foreach ($g in ($gaps | Select-Object -Last 15)) { Write-GNPara -Text $g -Color $script:GNCol.Text -Indent 4 }
        Write-GNOut ''
        Write-GNPara -Text "Save a report before closing if you want to show these times to your ISP." -Color DarkGray -Indent 4
    }
    Pause-GeeNet
}

function Full-Diagnostics {
    <#  Original 'Full Diagnostics' - now an intelligent, sequential investigation. #>
    Write-Header
    Write-GNOut "  FULL NETWORK DIAGNOSTICS" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    Write-GNPara -Text "GeeNet will work through the layers in order - link, adapter, IP, router, internet, DNS, web - stop early when a failure already proves the cause, and interpret the combination of results." -Color $script:GNCol.Text -Indent 4
    Write-GNOut ''
    Write-GNOut "  [1] Quick (connectivity only)" -Color White
    Write-GNOut "  [2] Standard (recommended)" -Color White
    Write-GNOut "  [3] Deep (includes stability monitoring and MTU)" -Color White
    Write-GNOut ''
    $mode = Read-GNInput -Prompt '  Choose [default: 2]'
    $plan = @('Adapter','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS','HTTPS','Proxy','VPN')
    $extra = @{}
    if ($mode -eq '1') { $plan = @('Adapter','IP','Gateway','GatewayReach','InternetIP','DNS','HTTPS') }
    elseif ($mode -eq '3') {
        $plan = @('Adapter','WiFi','Ethernet','Driver','Services','NetworkStack','IP','DHCP','Gateway','Route','ARP','GatewayReach','InternetIP','CaptivePortal','DNS','Proxy','HTTPS','VPN','MTU','PacketLoss','Stability','Latency','BandwidthHogs')
        $extra['Stability'] = @{ Seconds = 45 }
    }
    if (-not $script:GNSession) { New-GeeNetSession }
    $script:GNSession.Mode = 'Professional / Full Diagnostics'
    $script:GNSession.SymptomText = 'Full diagnostics run'
    $inv = Invoke-GNInvestigation -Plan $plan -TestParams $extra -Focus 'Reachability'
    Write-GNOut ''
    Write-GNOut "  [1] Try a recommended repair" -Color White
    Write-GNOut "  [2] Save a report" -Color White
    Write-GNOut "  [3] Show the diagnostic log" -Color White
    Write-GNOut "  [T] Show the technical details behind this diagnosis" -Color White
    Write-GNOut "  [0] Back" -Color DarkGray
    Write-GNOut ''
    $pick = Read-GNChoice -Prompt '  Select an option'
    while ("$pick" -match '^(t|tech|technical)$') {
        Show-GNTechnicalDetails -Results $inv.Results
        $pick = Read-GNChoice -Prompt '  Select an option'
    }
    if ($pick -eq '1') {
        $before = Get-GNStatusMap -Results $inv.Results
        $i = 0
        $opts = @()
        foreach ($rid in @($inv.Verdict.RepairIds)) {
            $rep = Get-GNRepair -Id $rid
            if ($rep) { $i++; $opts += $rep; Write-GNOut ("  [$i] " + $rep.Title + "  (" + (Get-GNRiskBadge -Risk $rep.Risk) + ")") -Color White }
            if ($i -ge 6) { break }
        }
        if ($opts.Count -eq 0) {
            Write-GNOut ''
            Write-GNPara -Text "The diagnosis does not point at anything GeeNet can repair automatically." -Color DarkYellow -Indent 4
        } else {
            Write-GNOut ''
            $sel = Read-GNChoice -Prompt "  Which repair? [0 = none]"
            $idx = 0
            [void][int]::TryParse("$sel", [ref]$idx)
            if ($idx -ge 1 -and $idx -le $opts.Count) {
                [void](Invoke-GNRepairFlow -Id $opts[$idx-1].Id -Before $before)
            }
        }
    } elseif ($pick -eq '2') { Save-GNSessionReport }
    elseif ($pick -eq '3') { Show-GNDiagnosticLog }
    else { Pause-GeeNet }
}

# ------------------------------------------------------------------------------
#region 25. PROFESSIONAL MODE MENU
# ------------------------------------------------------------------------------

function Start-GNProfessionalMode {
    while ($true) {
        Write-Header
        Write-GNOut "  PROFESSIONAL / ADVANCED TOOLS" -Color Cyan
        Write-GNRule '=' 2 ($script:GNW - 4) DarkCyan
        Write-GNOut ''
        Write-GNAdminState
        Write-GNOut ''

        Write-GNOut "  CONNECTIVITY & DIAGNOSTICS" -Color Cyan
        Write-GNOut "  [1]  Network Information                    [2]  Test Internet Connection"
        Write-GNOut "  [3]  Ping Gateway                          [4]  Ping a Host"
        Write-GNOut "  [5]  Latency & Packet Loss Test            [6]  Stability Monitor"
        Write-GNOut "  [7]  MTU / Packet Size Test                [8]  Trace Route"
        Write-GNOut "  [9]  Application / Service Connectivity"
        Write-GNOut ''
        Write-GNOut "  DNS" -Color Cyan
        Write-GNOut "  [10] DNS Lookup                            [11] Flush DNS Cache"
        Write-GNOut ''
        Write-GNOut "  IP ADDRESSING & LOCAL NETWORK" -Color Cyan
        Write-GNOut "  [12] Release IP Address                    [13] Renew IP Address"
        Write-GNOut "  [14] ARP / Neighbour Table                 [15] Routing Table"
        Write-GNOut "  [16] Active TCP Connections"
        Write-GNOut ''
        Write-GNOut "  ADAPTER, WI-FI & WINDOWS" -Color Cyan
        Write-GNOut "  [17] Wi-Fi Information & Scan              [18] Proxy / VPN Check"
        Write-GNOut "  [19] Network Stack, Services & Firewall    [20] Hosts File, Firewall"
        Write-GNOut ''
        Write-GNOut "  TOOLS & REPAIRS" -Color Cyan
        Write-GNOut "  [21] Open Network Settings                 [22] Open Network Connections"
        Write-GNOut "  [23] Device Manager                        [24] Windows Troubleshooter"
        Write-GNOut "  [25] Continuous Ping                       [26] Reset Winsock"
        Write-GNOut "  [27] Reset TCP/IP Stack                    [28] Network Reset (last resort)"
        Write-GNOut "  [29] Repair menu (all repairs, explained)"
        Write-GNOut ''
        Write-GNOut "  INVESTIGATION & REPORTS" -Color Cyan
        Write-GNOut "  [30] Full Diagnostics (intelligent)        [31] Generate Network Report"
        Write-GNOut "  [32] Saved Reports                         [33] Diagnostic Log"
        Write-GNOut "  [34] Guided Troubleshooting (Beginner)"
        Write-GNOut ''
        Write-GNOut "  [0]  Back to the main menu" -Color DarkGray
        Write-GNOut ''
        $choice = Read-GNChoice -Prompt '  Select an option'

        # remember where we are for the continuous screens
        $script:GNLastProChoice = $choice
        switch ($choice) {
            '1'  { Show-NetworkInfo }
            '2'  { Test-Internet }
            '3'  { Ping-Gateway }
            '4'  { Ping-Google }
            '5'  { Show-LatencyLoss }
            '6'  { Show-StabilityMonitor }
            '7'  { Show-MTUTest }
            '8'  { Trace-Route }
            '9'  { Show-AppConnectivity }
            '10' { DNS-Lookup }
            '11' { Flush-DNS }
            '12' { Release-IP }
            '13' { Renew-IP }
            '14' { Show-ARP }
            '15' { Show-Routes }
            '16' { Show-Connections }
            '17' { Show-WiFi }
            '18' { Show-ProxyState }
            '19' { Show-StackCheck }
            '20' { Clear-Host; Add-GNResult -Result (Test-HostsFile) | Out-Null; Add-GNResult -Result (Test-Firewall) | Out-Null; Pause-GeeNet }
            '21' { Open-NetworkSettings }
            '22' { Open-NetworkConnections }
            '23' { Open-DeviceManager }
            '24' { Open-Troubleshooter }
            '25' { Continuous-Ping }
            '26' { Reset-Winsock }
            '27' { Reset-TCPIP }
            '28' { Show-GNRepairCatalog -FilterRisk 'High' }
            '29' { Show-GNRepairCatalog }
            '30' { Full-Diagnostics }
            '31' { Generate-Report }
            '32' { Show-GNReports }
            '33' { Show-GNDiagnosticLog }
            '34' { Start-GNGuidedMode }
            '0'  { return }
            default {
                Write-GNOut ''
                Write-GNOut "  Invalid option." -Color Red
                Start-Sleep -Milliseconds 800
            }
        }
    }
}

function Show-GNRepairCatalog {
    <#  List every repair with its risk, then let the technician choose one to run. #>
    param([string]$FilterRisk = '')
    while ($true) {
        Write-Header
        Write-GNOut "  REPAIR CATALOGUE" -Color Yellow
        Write-GNRule '=' 2 ($script:GNW - 4) Yellow
        Write-GNOut ''
        Write-GNPara -Text "Every repair below explains itself before it runs, and GeeNet re-tests afterwards. Nothing is executed without confirmation." -Color $script:GNCol.Text -Indent 4
        Write-GNOut ''
        $ids = @($script:GNRepairs.Keys)
        $shown = @()
        $i = 0
        foreach ($id in $ids) {
            $rep = Get-GNRepair -Id $id
            if ($FilterRisk -and $rep.Risk -ne $FilterRisk) { continue }
            $i++
            $shown += $rep
            $riskCol = switch ($rep.Risk) { 'Low' { 'Green' } 'Moderate' { 'DarkYellow' } default { 'Red' } }
            Write-GNOut ("  [$i] " + $rep.Title) -Color White
            Write-GNOut ("      " + (Get-GNRiskBadge -Risk $rep.Risk) + $(if ($rep.Admin) { ' - Administrator' } else { '' }) + $(if ($rep.Restart) { ' - restart required' } else { '' })) -Color $riskCol
        }
        Write-GNOut ''
        Write-GNOut "  [0] Back" -Color DarkGray
        Write-GNOut ''
        $pick = Read-GNChoice -Prompt '  Select a repair to review and run'
        if ($pick -eq '0') { return }
        $idx = 0
        [void][int]::TryParse("$pick", [ref]$idx)
        if ($idx -ge 1 -and $idx -le $shown.Count) {
            [void](Invoke-GNRepairFlow -Id $shown[$idx-1].Id)
            Pause-GeeNet
        }
    }
}

# ------------------------------------------------------------------------------
#region 26. SELF TEST (-SelfTest)
# ------------------------------------------------------------------------------
#  Runs without touching the real network: Windows commands are replaced by mocks
#  that describe a machine state, so the reasoning engine can be checked end to end
#  (healthy PC, dead adapter, APIPA address, dead router, no internet, DNS failure,
#  blocked HTTPS, one app failing, whole-network outage, packet loss, and so on).

function Test-GNSelfTestData {
    <#  Static integrity checks on the scenario/repair/question data.  #>
    $rows = New-Object System.Collections.Generic.List[object]
    $add = {
        param([string]$Name, [bool]$Ok, [string]$Detail = '')
        [void]$rows.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
    }

    $cats = @($script:GNCategories)
    $scen = @($script:GNScenarios)
    $regKeys = @($script:GNTestRegistry.Keys)
    $catIds = @($cats | ForEach-Object { "$($_.Id)" })

    & $add 'Categories defined (15)' ($cats.Count -eq 15) "count=$($cats.Count)"
    & $add 'Scenario library loaded' ($scen.Count -ge 80) "count=$($scen.Count)"
    & $add 'Test registry populated' ($regKeys.Count -ge 25) "count=$($regKeys.Count)"
    & $add 'Plan order defined (31 keys)' (@($script:GNPlanOrder).Count -eq 31) "count=$(@($script:GNPlanOrder).Count)"
    & $add 'Questions defined' (@($script:GNQuestions.Keys).Count -ge 8) "count=$(@($script:GNQuestions.Keys).Count)"

    $dup = @($scen | Group-Object { "$($_['Id'])" } | Where-Object { $_.Count -gt 1 })
    & $add 'Scenario ids unique' ($dup.Count -eq 0) (($dup | ForEach-Object { $_.Name }) -join ',')

    $emptyCats = @()
    foreach ($c in $catIds) { if (@($scen | Where-Object { "$($_['Cat'])" -eq $c }).Count -eq 0) { $emptyCats += $c } }
    & $add 'Every category has scenarios' ($emptyCats.Count -eq 0) ($emptyCats -join ',')

    $missingFn = @()
    foreach ($k in $regKeys) {
        $f = "$($script:GNTestRegistry[$k].Function)"
        if (-not (Get-Command -Name $f -ErrorAction SilentlyContinue)) { $missingFn += "$k->$f" }
    }
    & $add 'Every registered test exists as a function' ($missingFn.Count -eq 0) ($missingFn -join ',')

    # A diagnostic test must never be able to stop and ask the console for a value: if a
    # parameter is missing the test has to return an honest result instead of prompting.
    $mandatory = @()
    foreach ($k in $regKeys) {
        $f = "$($script:GNTestRegistry[$k].Function)"
        $cmd = Get-Command -Name $f -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        foreach ($p in @($cmd.Parameters.Values)) {
            $isMandatory = $false
            foreach ($a in @($p.Attributes)) {
                if ($a -is [System.Management.Automation.ParameterAttribute] -and $a.Mandatory) { $isMandatory = $true }
            }
            if ($isMandatory) { $mandatory += "${k}:${f}-$($p.Name)" }
        }
    }
    & $add 'No diagnostic test demands a value it might not have' ($mandatory.Count -eq 0) ($mandatory -join ',')

    $badPlan = @(); $offOrder = @(); $badCat = @(); $badQ = @(); $badPreset = @(); $badPv = @()
    foreach ($s in $scen) {
        $id = "$($s['Id'])"
        foreach ($p in @($s['Plan'])) {
            if ($regKeys -notcontains "$p") { $badPlan += "${id}:${p}" }
            elseif (@($script:GNPlanOrder) -notcontains "$p") { $offOrder += "${id}:${p}" }
        }
        if ($catIds -notcontains "$($s['Cat'])") { $badCat += "${id}:$($s['Cat'])" }
        $qs = if ($s.Contains('Questions')) { @($s['Questions']) } else { @() }
        foreach ($q in $qs) { if (-not $script:GNQuestions.Contains("$q")) { $badQ += "${id}:${q}" } }
        if ($s.Contains('Preset') -and $s['Preset']) {
            foreach ($pk in @($s['Preset'].Keys)) {
                # A preset seeds the diagnostic context: its key is either a question id or the
                # context key that question writes (OutageScope, ConnectionType, AppChoice, ...).
                $q = Get-GNQuestion -Id "$pk"
                if (-not $q) {
                    $q = @($script:GNQuestions.Keys | ForEach-Object { Get-GNQuestion -Id $_ } |
                           Where-Object { $_ -and "$($_.ContextKey)" -eq "$pk" } | Select-Object -First 1)
                }
                if (-not $q) { $badPreset += "${id}:${pk}"; continue }
                $optKeys = @()
                if ($q.Options) { $optKeys = @($q.Options | ForEach-Object { "$($_.Key)" }) }
                if ($optKeys.Count -gt 0 -and $optKeys -notcontains "$($s['Preset'][$pk])") { $badPv += "${id}:${pk}=$($s['Preset'][$pk])" }
            }
        }
        # a planned test that needs a target must have the question that collects it
        if (@($s['Plan']) -contains 'Website' -and $qs -notcontains 'Domain') { $badQ += "$id:Website-without-Domain" }
        if (@($s['Plan']) -contains 'AppConnect' -and $qs -notcontains 'AppWhich') { $badQ += "$id:AppConnect-without-AppWhich" }
        if (@($s['Plan']) -contains 'LocalHost' -and $qs -notcontains 'LanTarget') { $badQ += "$id:LocalHost-without-LanTarget" }
        if (@($s['Plan']) -contains 'OutageScope' -and $qs -notcontains 'Scope') { $badQ += "$id:OutageScope-without-Scope" }
    }
    & $add 'Scenario plan keys exist in the registry' ($badPlan.Count -eq 0) (($badPlan | Select-Object -First 6) -join ',')
    & $add 'Scenario plan keys are ordered' ($offOrder.Count -eq 0) (($offOrder | Select-Object -First 6) -join ',')
    & $add 'Scenario categories valid' ($badCat.Count -eq 0) (($badCat | Select-Object -First 6) -join ',')
    & $add 'Scenario questions valid and wired' ($badQ.Count -eq 0) (($badQ | Select-Object -First 6) -join ',')
    & $add 'Scenario presets valid' (($badPreset.Count -eq 0) -and ($badPv.Count -eq 0)) ((@($badPreset + $badPv) | Select-Object -First 6) -join ',')

    $badPba = @()
    foreach ($qk in @($script:GNPlanByAnswer.Keys)) {
        if (-not $script:GNQuestions.Contains("$qk")) { $badPba += "question:$qk" }
        foreach ($ak in @($script:GNPlanByAnswer[$qk].Keys)) {
            foreach ($p in @($script:GNPlanByAnswer[$qk][$ak])) { if ($regKeys -notcontains "$p") { $badPba += "$qk/$ak/$p" } }
        }
    }
    & $add 'Answer-driven plan additions are real tests' ($badPba.Count -eq 0) (($badPba | Select-Object -First 6) -join ',')

    $badRep = @()
    foreach ($rid in @($script:GNRepairs.Keys)) {
        $d = $script:GNRepairs[$rid]
        foreach ($f in @('Title', 'Risk', 'What', 'Why', 'Effect', 'Undo', 'Code')) { if (-not $d[$f]) { $badRep += "$rid.$f" } }
        if (@('Low', 'Moderate', 'High') -notcontains "$($d.Risk)") { $badRep += "$rid.risk" }
    }
    & $add 'Repair definitions complete' ($badRep.Count -eq 0) (($badRep | Select-Object -First 6) -join ',')
    & $add 'Repairs resolve by id (incl. legacy names)' (((Get-GNRepair -Id 'FlushDns') -ne $null) -and ((Get-GNRepair -Id 'RestartNetworkServices') -ne $null))

    # every repair id the verdict engine can ask for must exist
    $text = ''
    try { $text = Get-Content -Path $PSCommandPath -Raw -ErrorAction SilentlyContinue } catch { }
    if (-not $text) { try { $text = Get-Content -Path $MyInvocation.MyCommand.Path -Raw -ErrorAction SilentlyContinue } catch { } }
    if ($text) {
        $unknown = @()
        foreach ($m in [regex]::Matches($text, "RepairIds\s*=\s*@\(([^\)]+)\)")) {
            foreach ($idm in [regex]::Matches($m.Groups[1].Value, "'([A-Za-z]+)'")) {
                $cand = $idm.Groups[1].Value
                if (-not (Get-GNRepair -Id $cand) -and ($unknown -notcontains $cand)) { $unknown += $cand }
            }
        }
        & $add 'Every suggested repair exists' ($unknown.Count -eq 0) ($unknown -join ',')
    }
    return @($rows.ToArray())
}

function New-GNSelfTestState {
    <#  A description of a computer/network situation used by one self-test case. #>
    param([hashtable]$Overrides = @{})
    $m = @{
        Plan              = @('Adapter','WiFi','Ethernet','Driver','Services','NetworkStack','IP','DHCP','Gateway','Route','ARP','GatewayReach','LocalNetwork','CaptivePortal','MTU','VPN','InternetIP','DNS','Proxy','HTTPS','HostsFile','Firewall','Stability','PacketLoss','Latency','OutageScope')
        AdapterStatus     = 'Up'
        AdapterKind       = 'Ethernet'
        NoWiFi            = $true
        HasEthernet       = $false
        EthStatus         = 'Disconnected'
        WifiAdapterStatus = 'Disconnected'
        IPv4              = '192.168.1.50'
        Prefix            = 24
        Gateway           = '192.168.1.1'
        Dns               = @('192.168.1.1')
        DhcpEnabled       = $true
        GatewayPing       = $true
        InternetPing      = $true
        InternetTcp443    = $true
        DnsWorks          = $true
        DnsSlow           = $false
        HttpsWorks        = $true
        AppFailHosts      = @()
        HttpCode          = 200
        WifiSignal        = 72
        VisibleSsids      = 4
        OutageScope       = ''
        ConnectionType    = ''
        Focus             = 'Reachability'
        ServicesOk        = $true
        HostsFileOk       = $true
        Loss              = 0
        LatencyMs         = 14
        VpnPresent        = $false
        Vendor            = 'GeeNet'
        Model             = 'SelfTest'
        TestParams        = @{}
        Repairs           = @()
    }
    foreach ($k in $Overrides.Keys) { $m[$k] = $Overrides[$k] }
    return $m
}

function Define-GNSelfTestMocks {
    <#
      Dot-source this inside the scope that runs a case: it replaces the Windows
      commands with state-driven stand-ins. Nothing real is touched - no network
      calls, no repairs, no windows opened.
    #>
    function Get-NetAdapter {
        param([switch]$IncludeHidden)
        $list = @()
        if ($script:GNMock.AdapterKind -eq 'WiFi') {
            $list += [pscustomobject]@{ Name = 'Wi-Fi'; InterfaceDescription = 'Intel(R) Wi-Fi 6 AX201 160MHz'; Status = $script:GNMock.AdapterStatus; LinkSpeed = '866.7 Mbps'; MacAddress = 'AA-BB-CC-DD-EE-11'; ifIndex = 9; MediaType = '802.11'; DriverInformation = [pscustomobject]@{ DriverFileName = 'Netwtw08.sys'; DriverDate = (Get-Date).AddYears(-1) } }
            if ($script:GNMock.HasEthernet) {
                $list += [pscustomobject]@{ Name = 'Ethernet'; InterfaceDescription = 'Realtek PCIe GbE Family Controller'; Status = $script:GNMock.EthStatus; LinkSpeed = '1 Gbps'; MacAddress = '00-11-22-33-44-55'; ifIndex = 7; MediaType = '802.3'; DriverInformation = [pscustomobject]@{ DriverFileName = 'rt640x64.sys'; DriverDate = (Get-Date).AddYears(-2) } }
            }
        } else {
            if (-not $script:GNMock.NoWiFi) {
                $list += [pscustomobject]@{ Name = 'Wi-Fi'; InterfaceDescription = 'Intel(R) Wi-Fi 6 AX201 160MHz'; Status = $script:GNMock.WifiAdapterStatus; LinkSpeed = '866.7 Mbps'; MacAddress = 'AA-BB-CC-DD-EE-11'; ifIndex = 9; MediaType = '802.11'; DriverInformation = [pscustomobject]@{ DriverFileName = 'Netwtw08.sys'; DriverDate = (Get-Date).AddYears(-1) } }
            }
            $list += [pscustomobject]@{ Name = 'Ethernet'; InterfaceDescription = 'Realtek PCIe GbE Family Controller'; Status = $script:GNMock.AdapterStatus; LinkSpeed = '1 Gbps'; MacAddress = '00-11-22-33-44-55'; ifIndex = 7; MediaType = '802.3'; DriverInformation = [pscustomobject]@{ DriverFileName = 'rt640x64.sys'; DriverDate = (Get-Date).AddYears(-2) } }
        }
        if ($script:GNMock.VpnPresent) {
            $list += [pscustomobject]@{ Name = 'WireGuard Tunnel'; InterfaceDescription = 'WireGuard Virtual Adapter'; Status = 'Up'; LinkSpeed = '1 Gbps'; MacAddress = '00-00-00-00-00-01'; ifIndex = 21; MediaType = 'Tunnel'; DriverInformation = [pscustomobject]@{ DriverFileName = 'wireguard.sys'; DriverDate = (Get-Date).AddYears(-1) } }
        }
        return $list
    }
    function Get-NetIPConfiguration {
        if ($script:GNMock.AdapterStatus -eq 'Disabled') { return @() }
        $ip4 = if ($script:GNMock.IPv4) { @([pscustomobject]@{ IPAddress = $script:GNMock.IPv4; PrefixLength = $script:GNMock.Prefix }) } else { @() }
        $gw = if ($script:GNMock.Gateway) { @([pscustomobject]@{ NextHop = $script:GNMock.Gateway }) } else { @() }
        $dns = @()
        foreach ($d in @($script:GNMock.Dns)) { $dns += [pscustomobject]@{ AddressFamily = 2; ServerAddresses = @($d) } }
        $alias = if ($script:GNMock.AdapterKind -eq 'WiFi') { 'Wi-Fi' } else { 'Ethernet' }
        return @([pscustomobject]@{
                InterfaceAlias     = $alias
                InterfaceIndex     = 7
                IPv4Address        = $ip4
                IPv4DefaultGateway = $gw
                DNSServer          = $dns
                NetIPv4Interface   = [pscustomobject]@{ Dhcp = $(if ($script:GNMock.DhcpEnabled) { 'Enabled' } else { 'Disabled' }); DnsSuffix = 'lan' }
                NetProfile         = [pscustomobject]@{ Name = 'HomeNetwork'; NetworkCategory = 'Private' }
                NetAdapter         = [pscustomobject]@{ Status = $script:GNMock.AdapterStatus; MediaType = $(if ($script:GNMock.AdapterKind -eq 'WiFi') { '802.11' } else { '802.3' }) }
            })
    }
    function Get-NetIPAddress { param([string]$AddressFamily) return @([pscustomobject]@{ IPAddress = $script:GNMock.IPv4; PrefixLength = $script:GNMock.Prefix; InterfaceAlias = 'Ethernet'; InterfaceIndex = 7; AddressFamily = 'IPv4'; PrefixOrigin = 'Dhcp'; SuffixOrigin = 'Dhcp' }) }
    function Get-NetRoute {
        param([string]$DestinationPrefix, [string]$AddressFamily)
        $rows = @()
        if ($script:GNMock.Gateway) { $rows += [pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = $script:GNMock.Gateway; RouteMetric = 25; InterfaceAlias = 'Ethernet'; InterfaceIndex = 7; AddressFamily = 'IPv4' } }
        $rows += [pscustomobject]@{ DestinationPrefix = '192.168.1.0/24'; NextHop = '0.0.0.0'; RouteMetric = 281; InterfaceAlias = 'Ethernet'; InterfaceIndex = 7; AddressFamily = 'IPv4' }
        $rows += [pscustomobject]@{ DestinationPrefix = '224.0.0.0/4'; NextHop = '0.0.0.0'; RouteMetric = 281; InterfaceAlias = 'Ethernet'; InterfaceIndex = 7; AddressFamily = 'IPv4' }
        $rows += [pscustomobject]@{ DestinationPrefix = '255.255.255.255/32'; NextHop = '0.0.0.0'; RouteMetric = 281; InterfaceAlias = 'Ethernet'; InterfaceIndex = 7; AddressFamily = 'IPv4' }
        return $rows
    }
    function Get-NetNeighbor {
        param([string]$AddressFamily, [string]$State)
        return @(
            [pscustomobject]@{ IPAddress = '192.168.1.1'; LinkLayerAddress = $(if ($script:GNMock.GatewayPing) { 'AA-BB-CC-DD-EE-FF' } else { '' }); State = $(if ($script:GNMock.GatewayPing) { 'Reachable' } else { 'Incomplete' }); InterfaceAlias = 'Ethernet' }
            [pscustomobject]@{ IPAddress = '192.168.1.50'; LinkLayerAddress = '00-11-22-33-44-55'; State = 'Permanent'; InterfaceAlias = 'Ethernet' }
            [pscustomobject]@{ IPAddress = '192.168.1.255'; LinkLayerAddress = 'FF-FF-FF-FF-FF-FF'; State = 'Permanent'; InterfaceAlias = 'Ethernet' }
        )
    }
    function Get-NetTCPConnection {
        param([switch]$All, [string]$State)
        $rows = @()
        if ($script:GNMock.InternetTcp443) {
            for ($i = 1; $i -le 12; $i++) { $rows += [pscustomobject]@{ LocalAddress = '192.168.1.50'; LocalPort = 50000 + $i; RemoteAddress = '142.250.185.78'; RemotePort = 443; State = 'Established'; OwningProcess = 4321 } }
        }
        $rows += [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 135; RemoteAddress = '0.0.0.0'; RemotePort = 0; State = 'Listen'; OwningProcess = 900 }
        return $rows
    }
    function Get-NetAdapterStatistics { param([string]$Name) return [pscustomobject]@{ Name = 'Ethernet'; ReceivedPacketErrors = 0; OutboundPacketErrors = 0; ReceivedDiscardedPackets = 0; OutboundDiscardedPackets = 0; ReceivedBytes = 1234567; SentBytes = 765432 } }
    function Get-NetAdapterBinding { param([string]$ComponentID) return @([pscustomobject]@{ Name = 'Ethernet'; ComponentID = 'ms_tcpip'; Enabled = $true }) }
    function Get-NetIPInterface { param([string]$AddressFamily) return [pscustomobject]@{ InterfaceAlias = 'Ethernet'; InterfaceIndex = 7; Dhcp = 'Enabled'; ConnectionState = 'Connected'; AddressFamily = 'IPv4'; NlMtu = 1500 } }
    function Get-NetFirewallProfile { return @([pscustomobject]@{ Name = 'Domain'; Enabled = 'True' }, [pscustomobject]@{ Name = 'Private'; Enabled = 'True' }, [pscustomobject]@{ Name = 'Public'; Enabled = 'True' }) }
    function Get-NetConnectionProfile { return @([pscustomobject]@{ Name = 'HomeNetwork'; InterfaceAlias = 'Ethernet'; NetworkCategory = 'Private'; IPv4Connectivity = $(if ($script:GNMock.InternetPing) { 'Internet' } else { 'LocalNetwork' }) }) }
    function Get-DnsClientServerAddress { param([string]$AddressFamily) return @([pscustomobject]@{ InterfaceAlias = 'Ethernet'; InterfaceIndex = 7; AddressFamily = 2; ServerAddresses = @($script:GNMock.Dns) }) }
    function Get-DnsClientCache { return @() }
    function Resolve-DnsName {
        param([string]$Name, [string]$Type, [string]$Server, [switch]$DnsOnly)
        if (-not $script:GNMock.DnsWorks) { throw 'DNS name does not exist' }
        return @([pscustomobject]@{ Name = $Name; IPAddress = '142.250.185.78' })
    }
    function Get-Service {
        param([string]$Name, [string]$DisplayName, [switch]$DependentServices)
        $svc = @('Dnscache', 'Dhcp', 'WlanSvc', 'NlaSvc', 'netprofm', 'NcaSvc', 'nsi', 'DPS', 'WinHttpAutoProxySvc', 'LanmanWorkstation')
        if ($Name -and ($svc -notcontains $Name)) { return $null }
        $out = @()
        foreach ($n in $svc) {
            $status = 'Running'
            if (-not $script:GNMock.ServicesOk -and @('Dnscache', 'Dhcp', 'nsi') -contains $n) { $status = 'Stopped' }
            $out += [pscustomobject]@{ Name = $n; DisplayName = $n; Status = $status; StartType = 'Automatic'; ServiceName = $n }
        }
        return $out
    }
    function Get-Process {
        param([string]$Name, [int]$Id)
        return [pscustomobject]@{ Id = 4321; ProcessName = 'chrome'; Name = 'chrome'; Path = 'C:\Program Files\chrome\chrome.exe'; WS = 100MB }
    }
    function Get-CimInstance {
        param([string]$ClassName, [string]$Filter, [string]$Class)
        switch ("$ClassName") {
            'Win32_NetworkAdapterConfiguration' { return @([pscustomobject]@{ Description = 'Ethernet'; DHCPEnabled = $true; DHCPServer = '192.168.1.1'; MACAddress = '00:11:22:33:44:55'; DefaultIPGateway = @($script:GNMock.Gateway); DNSServerSearchOrder = @($script:GNMock.Dns) }) }
            'Win32_NetworkAdapter' { return @([pscustomobject]@{ NetConnectionID = 'Ethernet'; Name = 'Ethernet'; NetConnectionStatus = 2; Speed = 1000000000; MACAddress = '00:11:22:33:44:55'; InterfaceIndex = 7; AdapterType = 'Ethernet 802.3'; PhysicalAdapter = $true; NetEnabled = $true; PNPDeviceID = 'PCI\VEN_10EC' }) }
            'Win32_PnPEntity' { return @() }
            'Win32_OperatingSystem' { return [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; Version = '10.0.22631'; BuildNumber = '22631'; LastBootUpTime = (Get-Date).AddHours(-6) } }
            'Win32_ComputerSystem' { return [pscustomobject]@{ Manufacturer = "$($script:GNMock.Vendor)"; Model = "$($script:GNMock.Model)" } }
            'Win32_Service' { return @() }
            'Win32_PnPSignedDriver' { return @() }
            default { return $null }
        }
    }
    function Get-ItemProperty {
        param([string]$Path, [string]$Name)
        switch -Wildcard ("$Path") {
            '*RadioManagement*' { return $null }
            '*Internet Settings' { return [pscustomobject]@{ ProxyEnable = 0; ProxyServer = ''; AutoConfigURL = ''; ProxyOverride = '<local>'; DefaultConnectionSettings = (New-Object byte[] 60) } }
            '*CurrentVersion' { return [pscustomobject]@{ ProductName = 'Windows 11 Pro'; CurrentVersion = '6.3'; DisplayVersion = '23H2'; CurrentBuild = '22631'; UBR = 3155 } }
            default { return $null }
        }
    }
    function Get-GNHostsFileEntries {
        if (-not $script:GNMock.HostsFileOk) { return @('127.0.0.1 localhost', '0.0.0.0 www.google.com', '0.0.0.0 ads.example.com') }
        return @('127.0.0.1 localhost')
    }
    function Invoke-GNPing {
        param([Parameter(Mandatory)][string]$Target, [int]$Count = 2, [int]$TimeoutMs = 1200, [int]$BufferSize = 32, [switch]$DontFragment)
        $ok = $true
        if ("$Target" -eq "$($script:GNMock.Gateway)") { $ok = $script:GNMock.GatewayPing }
        elseif ("$Target" -match '^\d+\.\d+\.\d+\.\d+$') { $ok = $script:GNMock.InternetPing }
        else { $ok = ($script:GNMock.InternetPing -and $script:GNMock.DnsWorks) }
        $lat = if ($ok) { [int]$script:GNMock.LatencyMs } else { $null }
        $recv = $(if ($ok) { $Count } else { 0 })
        $loss = $(if ($ok) { 0 } else { 100 })
        if ($ok -and $script:GNMock.Loss -gt 0) {
            $loss = [int]$script:GNMock.Loss
            $recv = [int]($Count - [Math]::Ceiling($Count * $script:GNMock.Loss / 100))
        }
        return [pscustomobject]@{
            Target = $Target; Sent = $Count; Received = $recv; Lost = ($Count - $recv); LossPercent = $loss; Success = $ok
            Times = $(if ($ok) { @($lat, $lat) } else { @() }); AvgMs = $lat; MinMs = $lat; MaxMs = $lat
            JitterMs = $(if ($ok) { 2 } else { $null }); Statuses = $(if ($ok) { @('Success') } else { @('TimedOut') }); Error = ''; ResolvedTo = "$Target"
        }
    }
    function Test-GNTcpPort {
        param([Parameter(Mandatory)][string]$Target, [int]$Port = 443, [int]$TimeoutMs = 3000, [switch]$NoDns)
        $open = $script:GNMock.InternetTcp443
        if (@($script:GNMock.AppFailHosts) -contains "$Target") { $open = $false }
        elseif ("$Target" -match '^(www\.|google|microsoft|msft|teams|zoom|discord|github|outlook|login|mail|store|web)') { $open = ($script:GNMock.DnsWorks -and $script:GNMock.HttpsWorks) }
        return [pscustomobject]@{ Target = $Target; Port = $Port; Open = $open; ElapsedMs = $(if ($open) { 30 } else { $null }); Error = $(if ($open) { '' } else { 'Connection timed out' }); ResolvedIp = $(if ($open) { '142.250.185.78' } else { '' }) }
    }
    function Request-GNHttp {
        param([Parameter(Mandatory)][string]$Url, [int]$TimeoutSec = 8, [switch]$Direct, [int]$MaxBytes = 2048)
        $ok = $script:GNMock.HttpsWorks -and $script:GNMock.InternetTcp443
        return [pscustomobject]@{
            Url = $Url; Success = $ok; StatusCode = $(if ($ok) { [int]$script:GNMock.HttpCode } else { $null }); StatusText = $(if ($ok) { 'OK' } else { '' })
            Content = $(if ($ok) { 'Microsoft Connect Test' } else { '' }); ElapsedMs = $(if ($ok) { 120 } else { $null })
            Error = $(if ($ok) { '' } else { 'The operation has timed out' }); UsedProxy = 'none'; Redirected = $false
        }
    }
    function Invoke-GNDnsQuery {
        param([Parameter(Mandatory)][string]$Name, [string]$Server = '', [int]$TimeoutSec = 6)
        $ok = $script:GNMock.DnsWorks
        if ($Server -and $Server -notmatch '^(192\.168\.|10\.)') { $ok = $script:GNMock.InternetTcp443 }
        return [pscustomobject]@{
            Name = $Name; Server = $Server; Success = $ok; Addresses = $(if ($ok) { @('142.250.185.78') } else { @() })
            ElapsedMs = $(if ($script:GNMock.DnsSlow) { 2400 } else { 40 }); Error = $(if ($ok) { '' } else { 'No such host is known' }); RespondedWith = ''
        }
    }
    function Get-GNWifiProfiles { return @('HomeNetwork', 'CoffeeShop-Guest') }
    function Get-GNVpnInfo {
        if (-not $script:GNMock.VpnPresent) {
            return [pscustomobject]@{ Adapters = @(); Connections = @(); Clients = @(); ActiveRoutes = @() }
        }
        return [pscustomobject]@{
            Adapters     = @('WireGuard Tunnel [Up]')
            Connections  = @('Company VPN')
            Clients      = @('WireGuard')
            ActiveRoutes = @('0.0.0.0/0 via 10.7.0.1 metric 5 on WireGuard Tunnel')
        }
    }
    function Test-GNAirplaneMode { return [pscustomobject]@{ Detected = $false; Value = 0; AirplaneOn = $false } }
    function Get-GNCriticalServices {
        $svc = @('Dnscache', 'Dhcp', 'WlanSvc', 'NlaSvc', 'netprofm', 'NcaSvc', 'nsi', 'DPS', 'WinHttpAutoProxySvc', 'LanmanWorkstation')
        $out = @()
        foreach ($n in $svc) {
            $status = 'Running'
            if (-not $script:GNMock.ServicesOk -and @('Dnscache', 'Dhcp', 'nsi') -contains $n) { $status = 'Stopped' }
            $out += [pscustomobject]@{ Name = $n; Display = $n; Status = $status; StartType = 'Automatic' }
        }
        return $out
    }
    function Invoke-GNNative {
        param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @(), [int]$TimeoutSec = 20)
        $text = ''
        switch ("$File") {
            'netsh' {
                if (($Arguments -contains 'wlan') -and ($Arguments -contains 'interfaces')) {
                    if ($script:GNMock.AdapterKind -ne 'WiFi') { $text = 'There is no wireless interface on the system.' }
                    else {
                        $text = "There is 1 interface on the system:`r`n`r`n" +
                        '    Name                   : Wi-Fi' + "`r`n" +
                        '    Description            : Intel(R) Wi-Fi 6 AX201 160MHz' + "`r`n" +
                        '    Physical address       : aa:bb:cc:dd:ee:11' + "`r`n" +
                        '    State                  : connected' + "`r`n" +
                        '    SSID                   : HomeNetwork' + "`r`n" +
                        '    BSSID                  : aa:bb:cc:dd:ee:22' + "`r`n" +
                        '    Network type           : Infrastructure' + "`r`n" +
                        '    Radio type             : 802.11ac' + "`r`n" +
                        '    Authentication         : WPA2-Personal' + "`r`n" +
                        '    Cipher                 : CCMP' + "`r`n" +
                        '    Channel                : 36' + "`r`n" +
                        '    Receive rate (Mbps)    : 866.7' + "`r`n" +
                        '    Transmit rate (Mbps)   : 866.7' + "`r`n" +
                        "    Signal                 : $($script:GNMock.WifiSignal)%`r`n" +
                        '    Profile                : HomeNetwork'
                    }
                } elseif (($Arguments -contains 'wlan') -and ($Arguments -contains 'networks')) {
                    $sb = New-Object System.Text.StringBuilder
                    for ($i = 1; $i -le [int]$script:GNMock.VisibleSsids; $i++) {
                        [void]$sb.AppendLine("SSID $i : Network$i")
                        [void]$sb.AppendLine('    Network type            : Infrastructure')
                        [void]$sb.AppendLine('    Authentication          : WPA2-Personal')
                        [void]$sb.AppendLine('    Encryption              : CCMP')
                        [void]$sb.AppendLine("    Signal                  : $(90 - ($i * 10))%")
                        [void]$sb.AppendLine("    Channel                 : $(6 + $i)")
                    }
                    $text = $sb.ToString()
                } elseif (($Arguments -contains 'wlan') -and ($Arguments -contains 'profiles')) {
                    $text = "    All User Profile     : HomeNetwork`r`n    All User Profile     : CoffeeShop-Guest"
                } elseif ($Arguments -contains 'winsock') {
                    $sb = New-Object System.Text.StringBuilder
                    [void]$sb.AppendLine('Winsock Catalog Provider Entry')
                    [void]$sb.AppendLine('---------------------------------------------------------')
                    for ($i = 1; $i -le 6; $i++) {
                        [void]$sb.AppendLine('Entry Type            : Base Service Provider')
                        [void]$sb.AppendLine('Description           : MSAFD Tcpip [TCP/IP]')
                        [void]$sb.AppendLine("Catalog Entry ID      : 100$i")
                    }
                    $text = $sb.ToString()
                } elseif ($Arguments -contains 'winhttp') {
                    $text = 'Current WinHTTP proxy settings:' + "`r`n`r`n" + '    Direct access (no proxy server).'
                } elseif ($Arguments -contains 'advfirewall') {
                    $text = 'State                                 ON' + "`r`n" + 'Firewall Policy                       BlockInbound,AllowOutbound'
                } else { $text = 'Ok.' }
            }
            'ipconfig' {
                $text = 'Windows IP Configuration' + "`r`n`r`n" + 'Ethernet adapter Ethernet:' + "`r`n`r`n" +
                        '   Description . . . . . . . . . . . : Realtek PCIe GbE Family Controller' + "`r`n" +
                        '   Physical Address. . . . . . . . . : 00-11-22-33-44-55' + "`r`n" +
                        '   DHCP Enabled. . . . . . . . . . . : Yes' + "`r`n" +
                        "   IPv4 Address. . . . . . . . . . . : $($script:GNMock.IPv4)(Preferred)" + "`r`n" +
                        '   Subnet Mask . . . . . . . . . . . : 255.255.255.0' + "`r`n" +
                        "   Default Gateway . . . . . . . . . : $($script:GNMock.Gateway)`r`n" +
                        "   DNS Servers . . . . . . . . . . . : $(@($script:GNMock.Dns) -join "`r`n")"
            }
            'route' { $text = "          0.0.0.0          0.0.0.0      $($script:GNMock.Gateway)     25" }
            'arp' {
                $text = '  Internet Address      Physical Address      Type' + "`r`n" +
                        "  192.168.1.1           $(if ($script:GNMock.GatewayPing) { 'aa-bb-cc-dd-ee-ff' } else { 'incomplete' })     dynamic"
            }
            'netstat' { $text = '  TCP    192.168.1.50:52000     142.250.185.78:443    ESTABLISHED     4321' }
            'ping' {
                if ($script:GNMock.InternetPing) { $text = 'Reply from 1.1.1.1: bytes=32 time=14ms TTL=118' } else { $text = 'Request timed out.' }
            }
            'tracert' {
                $text = 'Tracing route to 1.1.1.1 over a maximum of 30 hops' + "`r`n`r`n" +
                        "  1     1 ms     1 ms     1 ms  $($script:GNMock.Gateway)`r`n" +
                        '  2    12 ms    11 ms    11 ms  10.10.0.1' + "`r`n" +
                        '  3    14 ms    13 ms    14 ms  1.1.1.1' + "`r`n`r`nTrace complete."
            }
            default { $text = '' }
        }
        return [pscustomobject]@{ ExitCode = 0; Output = $text; TimedOut = $false; Error = '' }
    }
    function Invoke-GNRepairCode {
        param([string]$Code, [bool]$NeedsAdmin, [switch]$AutoApprove)
        $script:GNMockRepairLog += "$Code"
        return [pscustomobject]@{ Ran = $true; Elevated = $false; Success = $true; Output = 'self-test: not executed'; ExitCode = 0; Error = '' }
    }
    function Start-Sleep { param([int]$Seconds, [int]$Milliseconds, [int]$s, [int]$ms) }
    function Start-Process { param([string]$FilePath, [string]$ArgumentList, [switch]$NoNewWindow, [switch]$PassThru, [string]$RedirectStandardOutput, [string]$RedirectStandardError, [string]$Verb) return $null }
}

function Get-GNSelfTestCases {
    <#  The situations GeeNet is expected to reason about correctly. #>
    $standard = @('Adapter','WiFi','Ethernet','Driver','Services','NetworkStack','IP','DHCP','Gateway','Route','ARP','GatewayReach','LocalNetwork','CaptivePortal','MTU','VPN','InternetIP','DNS','Proxy','HTTPS','HostsFile','Firewall','Stability','PacketLoss','Latency','OutageScope')
    return @(
        @{ Name = 'A. Healthy connection'; State = @{ Plan = $standard }
            Expect = @{ Boundary = @('Healthy'); Severity = 'Pass' } }

        @{ Name = 'B. Network adapter disconnected'; State = @{ Plan = @('Adapter','WiFi','Ethernet','IP','Gateway','GatewayReach','InternetIP','DNS','HTTPS'); AdapterStatus = 'Disconnected'; IPv4 = ''; Gateway = ''; GatewayPing = $false; InternetPing = $false; InternetTcp443 = $false }
            Expect = @{ Boundary = @('Link'); Severity = 'Fail'; ClientSide = $true; Status = @{ 'AdapterState' = 'Fail' }; RepairAny = @('EnableAdapter','RestartAdapter') } }

        @{ Name = 'C. No usable IP address (169.254 self-assigned)'; State = @{ Plan = @('Adapter','Ethernet','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS'); IPv4 = '169.254.31.7'; Gateway = ''; GatewayPing = $false; InternetPing = $false; InternetTcp443 = $false }
            Expect = @{ Boundary = @('IP'); Severity = 'Fail'; ClientSide = $true; Status = @{ 'IPConfig' = 'Fail'; 'Dhcp' = 'Fail' }; RepairAny = @('RenewDhcp','RestoreDhcp') } }

        @{ Name = 'D. No default gateway configured'; State = @{ Plan = @('Adapter','Ethernet','IP','DHCP','Gateway','Route','GatewayReach','InternetIP','DNS'); Gateway = ''; GatewayPing = $false; InternetPing = $false; InternetTcp443 = $false }
            Expect = @{ Boundary = @('Gateway'); Severity = 'Fail'; Status = @{ 'Gateway' = 'Fail' }; RepairAny = @('RenewDhcp','RestoreDhcp') } }

        @{ Name = 'E. Router (gateway) unreachable'; State = @{ Plan = @('Adapter','Ethernet','IP','DHCP','Gateway','Route','ARP','GatewayReach','LocalNetwork','InternetIP','DNS'); GatewayPing = $false; InternetPing = $false; InternetTcp443 = $false }
            Expect = @{ Boundary = @('LocalNet'); Severity = 'Fail'; ClientSide = $true; Status = @{ 'GatewayReach' = 'Fail' }; RepairAny = @('ClearArpCache','ReconnectWifi','RestartAdapter','RestoreDhcp') } }

        @{ Name = 'F. Internet unreachable although the router answers'; State = @{ Plan = @('Adapter','Ethernet','IP','DHCP','Gateway','Route','GatewayReach','InternetIP','DNS','HTTPS'); InternetPing = $false; InternetTcp443 = $false }
            Expect = @{ Boundary = @('Upstream'); Severity = 'Fail'; ClientSide = $false; AutoFixable = $false; Status = @{ 'GatewayReach' = 'Pass'; 'InternetIP' = 'Fail' }; NoteNotEmpty = $true } }

        @{ Name = 'G. DNS does not resolve names (internet by IP works)'; State = @{ Plan = @('Adapter','Ethernet','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS','HTTPS'); DnsWorks = $false }
            Expect = @{ Boundary = @('DNS'); Severity = 'Fail'; ClientSide = $true; Status = @{ 'InternetIP' = 'Pass'; 'DNS' = 'Fail' }; RepairAny = @('FlushDns','SetPublicDns','RegisterDns') } }

        @{ Name = 'H. Web (HTTPS) traffic broken, ping and DNS fine'; State = @{ Plan = @('Adapter','Ethernet','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS','Proxy','HTTPS'); HttpsWorks = $false }
            Expect = @{ Boundary = @('HTTPS'); Severity = 'Fail'; Status = @{ 'InternetIP' = 'Pass'; 'DNS' = 'Pass'; 'HTTPS' = 'Fail' } } }

        @{ Name = 'I. Only one application fails (Teams)'; State = @{ Plan = @('Adapter','Ethernet','IP','Gateway','GatewayReach','InternetIP','DNS','HTTPS','AppConnect'); AppFailHosts = @('teams.microsoft.com'); TestParams = @{ AppConnect = @{ ProfileKey = 'teams' } } }
            Expect = @{ Boundary = @('Application'); Severity = 'Fail'; ClientSide = $true; Status = @{ 'AppConnect' = 'Fail'; 'HTTPS' = 'Pass' } } }

        @{ Name = 'J. Only this computer fails (other devices are fine)'; State = @{ Plan = @('Adapter','Ethernet','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS','OutageScope'); IPv4 = '169.254.31.7'; Gateway = ''; GatewayPing = $false; InternetPing = $false; InternetTcp443 = $false; OutageScope = 'ThisPcOnly' }
            Expect = @{ Boundary = @('IP'); Severity = 'Fail'; ClientSide = $true; RepairAny = @('RenewDhcp','RestoreDhcp') } }

        @{ Name = 'K. Whole network has no internet'; State = @{ Plan = @('Adapter','Ethernet','IP','Gateway','GatewayReach','InternetIP','DNS','HTTPS','OutageScope'); InternetPing = $false; InternetTcp443 = $false; OutageScope = 'OtherDevicesToo' }
            Expect = @{ Boundary = @('Upstream'); Severity = 'Fail'; ClientSide = $false; AutoFixable = $false; NoteNotEmpty = $true } }

        @{ Name = 'L. Laptop on Wi-Fi with the cable unplugged'; State = @{ Plan = @('Adapter','WiFi','Ethernet','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS','HTTPS'); AdapterKind = 'WiFi'; HasEthernet = $true; EthStatus = 'Disconnected'; ConnectionType = 'WiFi' }
            Expect = @{ Boundary = @('Healthy','WifiQuality'); Severity = 'Pass'; NotStatus = @{ 'Wifi' = 'Fail'; 'Ethernet' = 'Fail' } } }

        @{ Name = 'M. DNS answers very slowly'; State = @{ Plan = @('Adapter','Ethernet','IP','Gateway','GatewayReach','InternetIP','DNS','HTTPS'); DnsSlow = $true }
            Expect = @{ Boundary = @('DNSSlow','DNS'); Severity = @('Warn','Fail'); Status = @{ 'DNS' = 'Warn' } } }

        @{ Name = 'N. Wi-Fi adapter present but nothing connected'; State = @{ Plan = @('Adapter','WiFi','WiFiScan','Ethernet','IP','DHCP','Gateway','GatewayReach','InternetIP'); AdapterKind = 'WiFi'; AdapterStatus = 'Disconnected'; IPv4 = ''; Gateway = ''; GatewayPing = $false; InternetPing = $false; InternetTcp443 = $false }
            Expect = @{ Boundary = @('Link','WifiLink'); Severity = 'Fail'; ClientSide = $true; RepairAny = @('EnableAdapter','ReconnectWifi','RestartAdapter','RestartWlanService') } }

        @{ Name = 'W. Weak Wi-Fi signal'; State = @{ Plan = @('Adapter','WiFi','WiFiScan','IP','GatewayReach','InternetIP','DNS','HTTPS','Latency','PacketLoss'); AdapterKind = 'WiFi'; ConnectionType = 'WiFi'; WifiSignal = 24; LatencyMs = 90 }
            Expect = @{ Boundary = @('WifiQuality','Latency','Healthy'); Severity = @('Warn','Pass'); Status = @{ 'Wifi' = 'Warn' } } }

        @{ Name = 'S. Packet loss on the way to the internet'; State = @{ Plan = @('Adapter','Ethernet','IP','GatewayReach','InternetIP','DNS','HTTPS','Latency','PacketLoss','Stability'); Loss = 22; LatencyMs = 140 }
            Expect = @{ Boundary = @('PacketLoss','Latency'); Severity = @('Fail','Warn'); Status = @{ 'PacketLoss' = 'Fail' } } }

        @{ Name = 'X. Windows network services stopped'; State = @{ Plan = @('Adapter','Services','NetworkStack','IP','GatewayReach','InternetIP','DNS','HTTPS'); ServicesOk = $false }
            Expect = @{ Boundary = @('Services'); Severity = 'Fail'; RepairAny = @('StartNetworkServices','RestartAdapter') } }

        @{ Name = 'P. Wi-Fi link is fine, no internet, other devices are fine too'; State = @{ Plan = @('Adapter','WiFi','Ethernet','IP','DHCP','Gateway','GatewayReach','InternetIP','DNS','HTTPS','OutageScope'); AdapterKind = 'WiFi'; ConnectionType = 'WiFi'; OutageScope = 'ThisPcOnly'; InternetPing = $false; InternetTcp443 = $false }
            Expect = @{ Boundary = @('Upstream','DNS','HTTPS'); Severity = 'Fail'; Status = @{ 'GatewayReach' = 'Pass' } } }

        @{ Name = 'V. VPN tunnel is up and the internet stopped working'; State = @{ Plan = @('Adapter','Ethernet','IP','GatewayReach','InternetIP','VPN','DNS','HTTPS'); VpnPresent = $true; InternetPing = $false; InternetTcp443 = $false }
            Expect = @{ Boundary = @('VPN','Upstream','DNS','HTTPS'); Severity = 'Fail'; Status = @{ 'VPN' = 'Fail' } } }

        @{ Name = 'R. Connection is slow (high latency, no packet loss)'; State = @{ Plan = @('Adapter','Ethernet','IP','GatewayReach','InternetIP','DNS','HTTPS','Latency','PacketLoss'); LatencyMs = 320 }
            Expect = @{ Boundary = @('Latency','Healthy','WifiQuality','MTU'); Severity = @('Warn','Pass') } }

        @{ Name = 'Y. Hosts file blocking a website'; State = @{ Plan = @('Adapter','Ethernet','IP','GatewayReach','InternetIP','DNS','HTTPS','HostsFile'); HostsFileOk = $false }
            Expect = @{ Boundary = @('HostsFile'); Severity = 'Warn'; Status = @{ 'HostsFile' = 'Warn' } } }
    )
}

function Invoke-GNSelfTestCase {
    <#  Runs one case with mocked Windows commands and checks the verdict. #>
    param($Case)
    . Define-GNSelfTestMocks

    $state = New-GNSelfTestState -Overrides $Case.State
    $script:GNMock = $state
    $script:GNMockRepairLog = @()
    $script:GNInteractive = $false
    New-GeeNetSession | Out-Null
    $script:GNSession.Mode = 'SelfTest'
    $script:GNSession.SymptomText = "$($Case.Name)"

    $ctx = @{}
    if ("$($state.OutageScope)") { $ctx['OutageScope'] = "$($state.OutageScope)" }
    if ("$($state.ConnectionType)") { $ctx['ConnectionType'] = "$($state.ConnectionType)" }
    $tp = @{ Stability = @{ Seconds = 6; IntervalSeconds = 3; Quiet = $true } }
    foreach ($k in @($state.TestParams.Keys)) { $tp[$k] = $state.TestParams[$k] }

    $checks = New-Object System.Collections.Generic.List[object]
    $inv = $null
    try {
        $inv = Invoke-GNInvestigation -Plan @($state.Plan) -Context $ctx -TestParams $tp -Focus "$($state.Focus)" -SymptomText "$($Case.Name)" -Quiet
    } catch {
        [void]$checks.Add([pscustomobject]@{ Name = 'Investigation completes without an exception'; Ok = $false; Detail = $_.Exception.Message })
    }
    if ($inv -and $inv.Verdict) {
        $v = $inv.Verdict
        $e = $Case.Expect

        if ($e.Boundary) {
            [void]$checks.Add([pscustomobject]@{ Name = "Failure layer identified"; Ok = ($e.Boundary -contains "$($v.Boundary)"); Detail = "boundary=$($v.Boundary) expected=$(@($e.Boundary) -join '/')" })
        }
        if ($e.Severity) {
            $want = @($e.Severity)
            [void]$checks.Add([pscustomobject]@{ Name = "Severity reported"; Ok = ($want -contains "$($v.Severity)"); Detail = "severity=$($v.Severity) expected=$($want -join '/')" })
        }
        if ($e.ContainsKey('ClientSide')) {
            [void]$checks.Add([pscustomobject]@{ Name = "Fault placed correctly (client-side: $($e.ClientSide))"; Ok = ("$($v.ClientSide)" -eq "$($e.ClientSide)"); Detail = "ClientSide=$($v.ClientSide)" })
        }
        if ($e.ContainsKey('AutoFixable')) {
            [void]$checks.Add([pscustomobject]@{ Name = "Automatic repair claim correct"; Ok = ("$($v.AutoFixable)" -eq "$($e.AutoFixable)"); Detail = "AutoFixable=$($v.AutoFixable)" })
        }
        if ($e.NoteNotEmpty) {
            [void]$checks.Add([pscustomobject]@{ Name = 'Explains the router/ISP boundary'; Ok = "$($v.BoundaryNote)".Length -gt 20; Detail = ("note length=" + "$($v.BoundaryNote)".Length) })
        }
        if ($e.Status) {
            $map = @{}
            foreach ($r in (Get-GNArray -Items $inv.Results)) { $map["$($r.Id)"] = "$($r.Status)" }
            foreach ($id in @($e.Status.Keys)) {
                $want = "$($e.Status[$id])"
                $got = if ($map.ContainsKey($id)) { $map[$id] } else { '(missing)' }
                [void]$checks.Add([pscustomobject]@{ Name = "Test '$id' reports $want"; Ok = ($got -eq $want); Detail = "got=$got" })
            }
        }
        if ($e.NotStatus) {
            $map = @{}
            foreach ($r in (Get-GNArray -Items $inv.Results)) { $map["$($r.Id)"] = "$($r.Status)" }
            foreach ($id in @($e.NotStatus.Keys)) {
                $bad = "$($e.NotStatus[$id])"
                $got = if ($map.ContainsKey($id)) { $map[$id] } else { '(missing)' }
                [void]$checks.Add([pscustomobject]@{ Name = "Test '$id' is not blamed as $bad"; Ok = ($got -ne $bad); Detail = "got=$got" })
            }
        }
        if ($e.RepairAny) {
            $offered = @($v.RepairIds)
            $hit = @($e.RepairAny | Where-Object { $offered -contains $_ })
            [void]$checks.Add([pscustomobject]@{ Name = 'A sensible repair is offered'; Ok = ($hit.Count -gt 0); Detail = "offered=$($offered -join ',')" })
        }
        [void]$checks.Add([pscustomobject]@{ Name = 'Diagnosis text is present'; Ok = ("$($v.Headline)").Length -gt 5 -and ("$($v.Diagnosis)").Length -gt 20; Detail = "$($v.Headline)" })
        [void]$checks.Add([pscustomobject]@{ Name = 'No repair was run automatically'; Ok = (@($script:GNMockRepairLog).Count -eq 0); Detail = "commands=$(@($script:GNMockRepairLog).Count)" })

        # ---- rules that must hold in every situation ----
        $crashed = @(); $thin = @()
        foreach ($r in (Get-GNArray -Items $inv.Results)) {
            if (-not $r) { continue }
            if ("$($r.Summary)" -like 'This check could not be completed*') { $crashed += "$($r.Id)" }
            if (-not $r.FixClass) { $thin += "$($r.Id)(fixClass)" }
            if ("$($r.Status)" -in @('Fail','Warn')) {
                if (-not $r.Why)     { $thin += "$($r.Id)(why)" }
                if (-not $r.Meaning) { $thin += "$($r.Id)(meaning)" }
                if (-not $r.NextSteps -or @($r.NextSteps).Count -eq 0) { $thin += "$($r.Id)(nextSteps)" }
            }
        }
        [void]$checks.Add([pscustomobject]@{ Name = 'No check hit an internal error'; Ok = ($crashed.Count -eq 0); Detail = ($crashed -join ',') })
        [void]$checks.Add([pscustomobject]@{ Name = 'Every check explains itself (why / meaning / next step / fix class)'; Ok = ($thin.Count -eq 0); Detail = ($thin -join ',') })
        if ("$($v.Boundary)" -ne 'Healthy') {
            $hasWay = (@($v.RepairIds).Count -gt 0) -or (@($v.ManualActions).Count -gt 0) -or (@($v.NextSteps).Count -gt 0)
            [void]$checks.Add([pscustomobject]@{ Name = 'The user is never left without a way forward'; Ok = $hasWay; Detail = "repairs=$(@($v.RepairIds).Count) manual=$(@($v.ManualActions).Count) steps=$(@($v.NextSteps).Count)" })
            [void]$checks.Add([pscustomobject]@{ Name = 'Evidence is listed for the report'; Ok = (@($v.Evidence).Count -gt 0); Detail = "evidence=$(@($v.Evidence).Count)" })
        }
    } elseif ($inv) {
        [void]$checks.Add([pscustomobject]@{ Name = 'A verdict was produced'; Ok = $false; Detail = 'no verdict returned' })
    }

    return [pscustomobject]@{
        Name     = "$($Case.Name)"
        Boundary = if ($inv -and $inv.Verdict) { "$($inv.Verdict.Boundary)" } else { '-' }
        Severity = if ($inv -and $inv.Verdict) { "$($inv.Verdict.Severity)" } else { '-' }
        Headline = if ($inv -and $inv.Verdict) { "$($inv.Verdict.Headline)" } else { '' }
        Repairs  = if ($inv -and $inv.Verdict) { (@($inv.Verdict.RepairIds) -join ',') } else { '' }
        Results  = if ($inv) { (Get-GNArray -Items $inv.Results) } else { @() }
        Checks   = @($checks.ToArray())
    }
}

function Invoke-GNSelfTest {
    <#  GeeNet -SelfTest: verifies the data, the sequential logic and the diagnosis engine. #>
    param([switch]$ShowResults, [switch]$Quiet)
    $started = Get-Date
    $total = 0; $failed = 0
    $lines = New-Object System.Collections.Generic.List[string]

    Write-GNOut ''
    Write-GNOut '  GeeNet self test' -Color Cyan
    Write-GNRule '=' 2 ($script:GNW - 4) DarkCyan
    Write-GNOut ''
    Write-GNPara -Text "This checks GeeNet's own data and reasoning against simulated computers. Nothing on this PC is changed, no network traffic is sent, and no repairs are run." -Color $script:GNCol.Text -Indent 4
    Write-GNOut ''

    Write-GNOut '  Data integrity' -Color Yellow
    try {
        $dataChecks = @(Test-GNSelfTestData)
        foreach ($c in $dataChecks) {
            $total++
            if ($c.Ok) { Write-GNOut ("    [ok]   " + $c.Name) -Color Green }
            else { $failed++; Write-GNOut ("    [FAIL] " + $c.Name + "  " + $c.Detail) -Color Red }
            [void]$lines.Add(("DATA  {0,-6} {1} {2}" -f $(if ($c.Ok) { 'ok' } else { 'FAIL' }), $c.Name, $c.Detail))
        }
    } catch {
        $failed++; $total++
        Write-GNOut ("    [FAIL] data checks crashed: " + $_.Exception.Message) -Color Red
    }
    Write-GNOut ''
    Write-GNOut '  Simulated situations' -Color Yellow

    foreach ($case in (Get-GNSelfTestCases)) {
        $res = Invoke-GNSelfTestCase -Case $case
        $bad = @($res.Checks | Where-Object { -not $_.Ok })
        $mark = if ($bad.Count -eq 0) { '[ok]  ' } else { '[FAIL]' }
        $col = if ($bad.Count -eq 0) { 'Green' } else { 'Red' }
        Write-GNOut ("    $mark " + $res.Name + "   -> " + $res.Boundary + "/" + $res.Severity) -Color $col
        foreach ($c in $res.Checks) {
            $total++
            if (-not $c.Ok) { $failed++; Write-GNOut ("           x " + $c.Name + "   (" + $c.Detail + ")") -Color Red }
            [void]$lines.Add(("CASE  {0,-6} {1} :: {2} {3}" -f $(if ($c.Ok) { 'ok' } else { 'FAIL' }), $res.Name, $c.Name, $c.Detail))
        }
        [void]$lines.Add(("CASE  ---- {0,-5} layer={1} severity={2} repairs={3}" -f $res.Name.Substring(0, [Math]::Min(3, $res.Name.Length)), $res.Boundary, $res.Severity, $(if ($res.Repairs) { $res.Repairs } else { '(none)' })))
        [void]$lines.Add(("           diagnosis: " + $res.Headline))
        if ($res.Results.Count -gt 0) {
            [void]$lines.Add(("           checks: " + (($res.Results | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ' ')))
        }
        if ($ShowResults -and $res.Results.Count -gt 0) {
            Write-GNOut ("           tests: " + ((Get-GNArray -Items $res.Results | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ' ')) -Color DarkGray
        }
    }

    $dur = [Math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    Write-GNOut ''
    Write-GNRule '-' 2 ($script:GNW - 4) DarkCyan
    if ($failed -eq 0) {
        Write-GNOut ("  SELF TEST PASSED - $total checks in $dur s") -Color Green
    } else {
        Write-GNOut ("  SELF TEST: $failed of $total checks FAILED ($dur s)") -Color Red
    }
    Write-GNOut ''

    # leave a copy in the reports folder so a bug report can include it
    try {
        if (-not (Test-Path $script:GeeNetReports)) { New-Item -ItemType Directory -Path $script:GeeNetReports -Force | Out-Null }
        $file = Join-Path $script:GeeNetReports ("GeeNet_SelfTest_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".txt")
        Set-Content -Path $file -Value (@("GeeNet self test - $started", "Result: $failed failed of $total checks", '') + $lines.ToArray()) -Encoding UTF8
        Write-GNOut ("  Written to: " + $file) -Color DarkGray
        Write-GNOut ''
    } catch { }
    return $failed
}

# ------------------------------------------------------------------------------
#region 27. ABOUT PAGE, MAIN MENU AND ENTRY POINT
# ------------------------------------------------------------------------------

function Show-GNAbout {
    Clear-Host
    Write-GNBanner
    Write-GNOut "  ABOUT GEENET" -Color Yellow
    Write-GNRule '=' 2 ($script:GNW - 4) Yellow
    Write-GNOut ''
    Write-GNPara -Text "GeeNet is a Windows network troubleshooting toolkit. It checks the network in the same order a good technician would - physical link, adapter, IP address, router, internet, name resolution, web - and explains what each result means instead of only saying FAILED." -Color $script:GNCol.Text -Indent 4
    Write-GNOut ''
    Write-GNOut "  TWO WAYS TO USE IT" -Color Cyan
    Write-GNPara -Text "[1] Beginner / Guided - GeeNet asks what the problem feels like, then runs the checks itself and offers the safe repairs. No commands to type, no technical questions." -Color $script:GNCol.Text -Indent 4
    Write-GNPara -Text "[2] Professional - the direct tools this toolkit has always had: ping, traceroute, DNS, ARP, routes, winsock, full diagnostics and so on." -Color $script:GNCol.Text -Indent 4
    Write-GNOut ''
    Write-GNOut "  WHAT IT WILL NEVER DO" -Color Cyan
    Write-GNList -Items @(
        'Change anything without explaining it first and asking you to confirm',
        'Reboot or shut down your computer - if a repair needs a restart, it tells you and leaves the decision to you',
        'Claim a repair worked before checking the real result and re-testing',
        'Claim certainty: results are described as "most likely" and "this suggests"',
        'Send your information anywhere - everything runs locally, and the tool works offline'
    ) -Indent 4
    Write-GNOut ''
    Write-GNOut "  REPORTS AND LOGS" -Color Cyan
    Write-GNPara -Text ("Reports are plain text files, saved in: " + $script:GeeNetReports) -Color $script:GNCol.Text -Indent 4
    Write-GNPara -Text ("This session's log: " + $(if ($script:GNLogFile) { $script:GNLogFile } else { '(not started yet)' })) -Color $script:GNCol.Text -Indent 4
    Write-GNPara -Text "They contain network configuration and test results only - no passwords, no personal files, no browsing history." -Color $script:GNCol.Dim -Indent 4
    Write-GNOut ''
    Write-GNOut "  REQUIREMENTS" -Color Cyan
    Write-GNList -Items @(
        'Windows 10 or Windows 11 (works on old and slow machines too)',
        'Windows PowerShell 5.1 (built in) or PowerShell 7+',
        'No installation, no extra downloads - it uses tools Windows already has'
    ) -Indent 4
    Write-GNOut ''
    Write-GNOut ("  Version " + $script:GeeNetVersion + "     Mode: " + $(if ($script:GNSession -and $script:GNSession.Mode) { $script:GNSession.Mode } else { 'main menu' })) -Color DarkGray
    Write-GNOut ("  Administrator: " + $(if (Test-GeeNetAdmin) { 'yes (all repairs available)' } else { 'no (admin repairs will ask for permission)' })) -Color DarkGray
    Write-GNOut ''
    Write-GNOut "  Made by $($script:GeeNetAuthor)   $($script:GeeNetPhone)" -Color Green
    Write-GNOut "  $($script:GeeNetGitHub)" -Color DarkGreen
    Write-GNOut ''
    Write-GNOut "  [1] Open the reports folder   [2] Show the log file location   [Enter] Back" -Color White
    $pick = Read-GNInput -Prompt '  Select an option'
    if ($pick -eq '1') { try { Start-Process $script:GeeNetReports } catch { } }
    elseif ($pick -eq '2') {
        Write-GNOut ''
        if ($script:GNLogFile) {
            Write-GNPara -Text ("Log file: " + $script:GNLogFile) -Color White -Indent 4
            Write-GNPara -Text "You can open it in Notepad, or attach it to a support request." -Color $script:GNCol.Dim -Indent 4
        } else {
            Write-GNPara -Text "No log file has been created yet." -Color $script:GNCol.Dim -Indent 4
        }
        Pause-GeeNet
    }
}

function Start-GeeNetMain {
    <#  The main menu. Everything else is one keystroke away. #>
    while ($true) {
        Clear-Host
        if (-not $NoBanner) { Write-GNBanner }
        if ($script:GNSession -and $script:GNSession.Mode) { Write-GNOut ("  Mode: " + $script:GNSession.Mode) -Color DarkCyan }
        Write-GNAdminState
        Write-GNOut ''

        Write-GNOut "  WHAT WOULD YOU LIKE TO DO?" -Color Cyan
        Write-GNRule '-' 2 ($script:GNW - 4) DarkCyan
        Write-GNOut ''
        Write-GNOut "  [1] Beginner / Guided Troubleshooting" -Color White
        Write-GNPara -Text "Tell GeeNet what is wrong in your own words. It works out the rest and offers safe repairs." -Color $script:GNCol.Dim -Indent 7
        Write-GNOut ''
        Write-GNOut "  [2] Professional / Advanced Tools" -Color White
        Write-GNPara -Text "All 34 direct tools: ping, traceroute, DNS, ARP, routes, sockets, winsock/TCP-IP resets, full diagnostics." -Color $script:GNCol.Dim -Indent 7
        Write-GNOut ''
        Write-GNOut "  [3] Network Information" -Color White
        Write-GNPara -Text "Adapters, IP address, gateway, DNS and what the numbers mean." -Color $script:GNCol.Dim -Indent 7
        Write-GNOut ''
        Write-GNOut "  [4] Generate Network Report" -Color White
        Write-GNPara -Text "A plain text report of this PC's network state that you can send to a technician or your ISP." -Color $script:GNCol.Dim -Indent 7
        Write-GNOut ''
        Write-GNOut "  [5] About GeeNet" -Color White
        Write-GNOut ''
        if (-not (Test-GeeNetAdmin)) {
            Write-GNOut "  [6] Restart with Administrator rights" -Color White
            Write-GNPara -Text "Some repairs (Winsock/TCP-IP reset, adapter changes) need it. GeeNet will ask anyway when it gets there." -Color $script:GNCol.Dim -Indent 7
            Write-GNOut ''
        }
        Write-GNOut "  [0] Exit" -Color DarkGray
        Write-GNOut ''
        if ($script:GNLogFile) { Write-GNOut ("  Log: " + $script:GNLogFile) -Color DarkGray }
        Write-GNOut ''

        $choice = Read-GNChoice -Prompt '  Select an option'
        switch ($choice) {
            '1' { Start-GNGuidedMode }
            '2' { Start-GNProfessionalMode }
            '3' { Show-NetworkInfo }
            '4' { Generate-Report }
            '5' { Show-GNAbout }
            '6' {
                if (Test-GeeNetAdmin) {
                    Write-GNOut ''
                    Write-GNOut "  GeeNet is already running as Administrator." -Color Green
                    Start-Sleep -Milliseconds 900
                } else {
                    Write-GNOut ''
                    Write-GNPara -Text "A second GeeNet window will open with Administrator rights. This one stays open - you can close it." -Color $script:GNCol.Text -Indent 4
                    $ok = Read-GNConfirm -Prompt '  Relaunch with Administrator rights now?' -DefaultYes $true
                    if ($ok) {
                        if (Request-GeeNetElevationRestart) {
                            Write-GNOut ''
                            Write-GNOut "  The elevated window is starting. This one can be closed." -Color Green
                            Pause-GeeNet
                        }
                    }
                }
            }
            '0' { return }
            default {
                Write-GNOut ''
                Write-GNOut "  Please choose one of the numbers shown (or 0 to exit)." -Color DarkYellow
                Start-Sleep -Milliseconds 800
            }
        }
    }
}

function Write-GeeNetGoodbye {
    Write-GNOut ''
    Write-GNRule '-' 2 ($script:GNW - 4) DarkCyan
    Write-GNOut "  Thank you for using GeeNet." -Color Green
    Write-GNOut ("  Made by " + $script:GeeNetAuthor + "   " + $script:GeeNetPhone + "   " + $script:GeeNetGitHub) -Color DarkGray
    if ($script:GNSession -and $script:GNSession.SavedReport) { Write-GNOut ("  Your last report: " + $script:GNSession.SavedReport) -Color DarkGray }
    if ($script:GNLogFile) { Write-GNOut ("  Session log: " + $script:GNLogFile) -Color DarkGray }
    Write-GNOut ''
}

# ------------------------------------------------------------------------------
#region 28. COMMAND LINE DISPATCH (start here)
# ------------------------------------------------------------------------------

if ($Version) {
    Write-Output ("GeeNet " + $script:GeeNetVersion + " - Windows Network Toolkit - Diagnose | Troubleshoot | Repair")
    Write-Output ("Made by " + $script:GeeNetAuthor + "  " + $script:GeeNetPhone + "  " + $script:GeeNetGitHub)
    return
}

if ($SelfTest) {
    $script:GNInteractive = $false
    $failed = 0
    try { $failed = [int](Invoke-GNSelfTest) } catch { Write-Output ("Self test crashed: " + $_.Exception.Message); $failed = 1 }
    exit $failed
}

if (-not $script:GNIsWindows -and $env:GEENET_ALLOW_NONWINDOWS -ne '1') {
    Write-Host ''
    Write-Host '  GeeNet is a Windows tool.' -ForegroundColor Yellow
    Write-Host '  It reads Windows network state (ipconfig, netsh, Get-NetAdapter) and repairs Windows networking.' -ForegroundColor Yellow
    Write-Host '  On this system there is nothing useful for it to check.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  The self test still works anywhere:  GeeNet.ps1 -SelfTest' -ForegroundColor Gray
    Write-Host ''
    return
}

# Non-interactive sessions (scripts, task scheduler) would block on Read-Host, so keep them quiet.
try {
    if (-not [Environment]::UserInteractive) { $script:GNInteractive = $false }
    if ($Host.Name -eq 'ServerRemoteHost' -and -not $env:GEENET_FORCE_INTERACTIVE) { $script:GNInteractive = $false }
} catch { }

if (-not $script:GNSession) { New-GeeNetSession }

$script:GNSession.Mode = if ($Beginner) { 'Beginner / Guided' } elseif ($Professional) { 'Professional / Advanced' } else { '' }

Clear-Host
Write-GNBanner
[void](Write-GeeNetLog -Message ("GeeNet $($script:GeeNetVersion) started. Admin: $(Test-GeeNetAdmin). Mode: $(if ($script:GNSession.Mode) { $script:GNSession.Mode } else { 'menu' })") -Level 'STEP')

if (Test-GeeNetAdmin) {
    Write-GNOut "  Running with Administrator rights - all repairs are available." -Color Green
    Write-GNOut ''
} elseif (-not $NoElevate) {
    Write-GNOut "  Running without Administrator rights - every diagnostic check still works." -Color DarkYellow
    Write-GNPara -Text "Repairs that change system settings will ask for approval when you choose them, or use menu option [6] to restart elevated." -Color $script:GNCol.Dim -Indent 4
    Write-GNOut ''
}

try {
    if ($Beginner) {
        Start-GNGuidedMode
        Start-GeeNetMain
    } elseif ($Professional) {
        Start-GNProfessionalMode
        Start-GeeNetMain
    } else {
        Start-GeeNetMain
    }
} finally {
    Write-GeeNetGoodbye
    [void](Write-GeeNetLog -Message 'GeeNet closed.' -Level 'INFO')
}
