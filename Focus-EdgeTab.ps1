# Focus-EdgeTab.ps1  (v12)
# Finds an open Edge tab by name (pinned tabs included), selects it, and
# brings its window to the foreground. Uses only Windows built-ins.
#
# Stream Deck: point System > Open at a .vbs launcher.
#
# Diagnostic - list every tab in every Edge window:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Focus-EdgeTab.ps1" -ListTabs
#
# NOTE: run with powershell.exe (5.1), not pwsh.exe.
#
# ALTERNATIVES: -TabName accepts several patterns separated by ";;" and matches
# any of them, e.g. "Gmail;;Inbox;;messaged you - Chat". Use this for tabs whose
# title is rewritten by notifications. ";;" is used rather than "|" because real
# titles contain pipes ("Data | Qualtrics Experience Management").
#
# TROUBLESHOOTING: every run appends a line to %TEMP%\FocusEdgeTab.log.
# Add -Explain to pop up what was searched and every tab that was seen.
#
# MATCHING: Edge appends volatile junk to tab names ("- Pinned - Sleeping -
# Memory usage - 240 MB", unread counts), so match a short stable substring.
# Watch out for site titles that differ from the product name -
# Google Voice reports itself as "Voice", not "Google Voice".
# Tabs are returned left-to-right, so -Index 1 is the leftmost match.
#
# WHEN THE TAB ISN'T THERE (requires -Url):
#   Edge not running  -> launch it, wait for pinned tabs to restore, focus the
#                        tab if it came back, otherwise open -Url. One press.
#   Edge running      -> first press focuses Edge and arms a timer; a second
#                        press within -DoublePressMs opens -Url in a new tab.
#                        The guard exists because a stale match string would
#                        otherwise spawn a duplicate tab on every press.
#   -NoAutoOpen       -> never open anything; just fail quietly.

param(
    [string]$TabName       = "Voice -",  # substring match, case-insensitive
    [string]$EdgeProfile   = "",         # e.g. "Personal" - limits which windows are searched
    [int]   $Index         = 1,          # which match to take, 1-based, left to right
    [string]$Url           = "",         # opened when the tab can't be found
    [int]   $DoublePressMs = 1500,       # double-press window for the open-tab action
    [switch]$NoAutoOpen,
    [switch]$ListTabs,
    [switch]$Explain,
    [switch]$Quiet          # suppress the notification balloons
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

$LogFile = Join-Path $env:TEMP "FocusEdgeTab.log"

function Write-Log([string]$message) {
    try {
        $line = "{0}  [{1}]  {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $TabName, $message
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue

        # Trim occasionally so a button pressed daily for years cannot grow an
        # unbounded log file.
        if ((Get-Random -Maximum 50) -eq 0) {
            $lines = @(Get-Content $LogFile -ErrorAction SilentlyContinue)
            if ($lines.Count -gt 500) {
                Set-Content -Path $LogFile -Value ($lines[-300..-1]) -ErrorAction SilentlyContinue
            }
        }
    } catch { }
}

# A key press that does nothing is indistinguishable from a broken button, so
# every failure path says something. Balloons surface as toasts on Win10/11.
function Show-Toast([string]$title, [string]$text, [int]$ms = 2500) {
    if ($Quiet) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon            = [System.Drawing.SystemIcons]::Information
        $ni.Visible         = $true
        $ni.BalloonTipTitle = $title
        $ni.BalloonTipText  = $text
        $ni.ShowBalloonTip($ms)
        Start-Sleep -Milliseconds ([Math]::Min($ms, 2000))
        $ni.Visible = $false
        $ni.Dispose()
    } catch { }
}

function New-Cond($prop, $val) {
    New-Object System.Windows.Automation.PropertyCondition($prop, $val)
}
$tabItemCond = New-Cond $AE::ControlTypeProperty $CT::TabItem

# -TabName may hold several alternatives separated by ";;"
$Patterns = @($TabName -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# NB: Edge puts a zero-width character inside "Microsoft Edge" in the window
# name, hence the wildcard rather than a literal match.
function Get-AllEdgeWindows {
    $AE::RootElement.FindAll($TS::Children, (New-Cond $AE::ClassNameProperty "Chrome_WidgetWin_1")) |
        Where-Object { $_.Current.Name -like "*Microsoft*Edge" }
}

function Get-EdgeWindows {
    $all = @(Get-AllEdgeWindows)
    if ($EdgeProfile) {
        $filtered = @($all | Where-Object { $_.Current.Name -like "*$EdgeProfile*" })
        if ($filtered.Count) { return $filtered }   # fall through to all if no match
    }
    return $all
}

# Tabs live several levels down (EdgeTabStripRegionView > EdgeTabStrip >
# EdgeTabContainerImpl > TabItem), so search the window's descendants.
#
# IMPORTANT: web pages can contain their own ARIA role="tab" elements, which
# surface as TabItem too - Gmail's side panel (Calendar, Keep, Tasks, Contacts,
# Get Add-ons) is the common offender. Real browser tabs carry a class name;
# page tabs do not. Filter on that, and fall back to everything only if the
# class name is unrecognised (a future Edge build, or another Chromium browser).
function Get-Tabs($win) {
    $all  = @($win.FindAll($TS::Descendants, $tabItemCond))
    $real = @($all | Where-Object {
        $_.Current.ClassName -eq 'EdgeTab' -or $_.Current.ClassName -eq 'Tab'
    })
    if ($real.Count) { return $real }
    return $all
}

function Try-Focus($element) {
    try { $element.SetFocus(); return $true } catch { return $false }
}

function Test-TabName([string]$name) {
    foreach ($p in $Patterns) {
        if ($name -like "*$p*") { return $true }
    }
    return $false
}

# Collect every match, then pick. If the wanted occurrence no longer exists -
# a tab was closed since the launcher was generated - fall back to the first
# match rather than failing outright. NB: $matches is an automatic variable in
# PowerShell, hence $hits.
function Find-Tab {
    $hits = @()
    foreach ($w in (Get-EdgeWindows)) {
        foreach ($t in (Get-Tabs $w)) {
            if (Test-TabName $t.Current.Name) {
                $hits += @{ Window = $w; Tab = $t }
            }
        }
    }

    if ($hits.Count -eq 0) { return $null }
    if ($hits.Count -ge $Index) { return $hits[$Index - 1] }

    Write-Log "Wanted occurrence $Index but only $($hits.Count) matched; using the first."
    return $hits[0]
}

function Show-Explain([string]$verdict) {
    Add-Type -AssemblyName System.Windows.Forms
    $lines = @()
    $lines += "Searched for: " + ($Patterns -join "   OR   ")
    $lines += "Occurrence:   $Index"
    if ($EdgeProfile) { $lines += "Profile filter: $EdgeProfile" }
    $lines += "Result: $verdict"
    $lines += ""
    foreach ($w in (Get-EdgeWindows)) {
        $lines += "--- " + $w.Current.Name
        foreach ($t in (Get-Tabs $w)) {
            $mark = if (Test-TabName $t.Current.Name) { " <== MATCH" } else { "" }
            $lines += "    " + $t.Current.Name + $mark
        }
    }
    $lines += ""
    $lines += "Log: $LogFile"
    [System.Windows.Forms.MessageBox]::Show(($lines -join [Environment]::NewLine),
        "Focus-EdgeTab", 'OK', 'Information') | Out-Null
}

function Focus-Hit($hit) {
    # Un-minimize first.
    try {
        $wp = $hit.Window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        if ($wp.Current.WindowVisualState -eq 'Minimized') {
            $wp.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
            Start-Sleep -Milliseconds 120
        }
    } catch { }

    # Select the tab - this alone usually raises the window too.
    $selected = $false
    foreach ($pat in @([System.Windows.Automation.SelectionItemPattern]::Pattern,
                       [System.Windows.Automation.InvokePattern]::Pattern)) {
        if ($selected) { break }
        try {
            $p = $hit.Tab.GetCurrentPattern($pat)
            if ($p -is [System.Windows.Automation.SelectionItemPattern]) { $p.Select() } else { $p.Invoke() }
            $selected = $true
        } catch { }
    }
    if (-not $selected) { [void](Try-Focus $hit.Tab) }

    Start-Sleep -Milliseconds 80

    # SetFocus throws "Target element cannot receive focus" when Windows
    # refuses at that instant - swallow it and fall back to AppActivate.
    if (-not (Try-Focus $hit.Window)) {
        Start-Sleep -Milliseconds 120
        if (-not (Try-Focus $hit.Window)) {
            try {
                Add-Type -AssemblyName Microsoft.VisualBasic
                [Microsoft.VisualBasic.Interaction]::AppActivate($hit.Window.Current.ProcessId)
            } catch { }
        }
    }
}

# ------------------------------------------------------------------ launching

function Get-EdgePath {
    foreach ($p in @("$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
                     "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                     "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe")) {
        if (Test-Path $p) { return $p }
    }
    return "msedge.exe"   # fall back to App Paths resolution
}

# The window title shows the profile's DISPLAY name ("Personal"), but the
# command line wants its DIRECTORY name ("Default", "Profile 1"). Local State
# holds the mapping.
function Get-EdgeProfileDir([string]$displayName) {
    if (-not $displayName) { return "" }
    $localState = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data\Local State"
    if (-not (Test-Path $localState)) { return "" }
    try {
        $json  = Get-Content $localState -Raw | ConvertFrom-Json
        $cache = $json.profile.info_cache
        foreach ($prop in $cache.PSObject.Properties) {
            if ($prop.Value.name -eq $displayName) { return $prop.Name }
        }
    } catch { }
    return ""
}

function Start-Edge([string]$urlOrEmpty) {
    $exe     = Get-EdgePath
    $argList = @()
    $dir     = Get-EdgeProfileDir $EdgeProfile
    if ($dir) { $argList += "--profile-directory=$dir" }
    if ($urlOrEmpty) { $argList += $urlOrEmpty }

    if ($argList.Count) { Start-Process $exe -ArgumentList $argList }
    else                { Start-Process $exe }
}

# ------------------------------------------------------------------ main flow

if ($ListTabs) {
    foreach ($w in (Get-EdgeWindows)) {
        "--- $($w.Current.Name)"
        $tabs = Get-Tabs $w
        if ($tabs.Count -eq 0) { "    (no TabItems exposed)" }
        foreach ($t in $tabs) { "    [$($t.Current.Name)]" }
    }
    Read-Host "`nPress Enter to close"
    exit 0
}

# Double-press state lives in TEMP, keyed by match string so each button
# arms independently.
$stampFile = Join-Path $env:TEMP ("FocusEdgeTab_" + ($TabName -replace '[^A-Za-z0-9]', '_') + ".stamp")

$anyEdge = @(Get-AllEdgeWindows).Count -gt 0

# --- Edge is closed: launch it, let pinned tabs restore, then look again.
if (-not $anyEdge) {
    if ($NoAutoOpen) { Write-Error "Edge is not running."; exit 1 }

    Start-Edge ""    # bare launch, so restored pins are not duplicated

    for ($i = 0; $i -lt 24; $i++) {          # up to ~12s
        Start-Sleep -Milliseconds 500
        $hit = Find-Tab
        if ($hit) {
            Focus-Hit $hit
            Remove-Item $stampFile -ErrorAction SilentlyContinue
            Write-Log "Edge was closed; tab restored and focused."
            exit 0
        }
    }

    # Pinned tabs did not bring it back - open it outright.
    if ($Url) { Write-Log "Edge was closed; tab did not restore; opened $Url"; Start-Edge $Url; exit 0 }
    Write-Log "Edge was closed; tab did not restore; no -Url set."
    Show-Toast "Tab not found" "Edge started, but nothing matching `"$($Patterns[0])`" came back and this button has no address to open."
    Write-Error "Edge started but no tab matching '$TabName', and no -Url given."
    exit 1
}

# --- Edge is running: the normal path.
$hit = Find-Tab
if ($hit) {
    Focus-Hit $hit
    Remove-Item $stampFile -ErrorAction SilentlyContinue
    Write-Log "Focused."
    if ($Explain) { Show-Explain "FOUND and focused" }
    exit 0
}

# Nothing matched. Count what we did see, so the log is actionable.
$tabTotal = 0
foreach ($w in (Get-EdgeWindows)) { $tabTotal += (Get-Tabs $w).Count }
Write-Log "NO MATCH. Searched $tabTotal tabs for: $($Patterns -join ' OR ')"
if ($Explain) { Show-Explain "NOT FOUND" }

# --- Tab missing. Require a second press before opening anything.
if ($NoAutoOpen -or -not $Url) {
    Show-Toast "Tab not found" "Nothing matching `"$($Patterns[0])`" is open, and this button has no address to open."
    Write-Error "No tab #$Index matching '$TabName' found."
    exit 1
}

$armed = $false
if (Test-Path $stampFile) {
    $age = ((Get-Date) - (Get-Item $stampFile).LastWriteTime).TotalMilliseconds
    if ($age -le $DoublePressMs) { $armed = $true }
}

if ($armed) {
    Remove-Item $stampFile -ErrorAction SilentlyContinue
    Write-Log "Second press within ${DoublePressMs}ms; opening $Url"
    Start-Edge $Url
    exit 0
}

# First press: arm the timer and surface the browser so the press is not silent.
Set-Content -Path $stampFile -Value (Get-Date).Ticks -Encoding ASCII
Write-Log "First press armed; press again within ${DoublePressMs}ms to open $Url"
$first = @(Get-EdgeWindows)[0]
if ($first) { [void](Try-Focus $first) }
Show-Toast "Tab is not open" "Press the button again to open it." 2000
exit 2
