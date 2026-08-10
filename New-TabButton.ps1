# New-TabButton.ps1  (v17 - ignore in-page tabs, URL-driven match strings)
# GUI for building Stream Deck launchers from your currently open Edge tabs.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\New-TabButton.ps1"
#
# Keep this in the SAME FOLDER as Focus-EdgeTab.ps1. Generated .vbs files
# land in a "TabButtons" subfolder, icons in "TabButtons\Icons".

param([string]$LauncherFolder = "TabButtons")

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PsTarget  = Join-Path $ScriptDir "Focus-EdgeTab.ps1"

if (-not (Test-Path $PsTarget)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Focus-EdgeTab.ps1 not found in:`n$ScriptDir`n`nPut both scripts in the same folder.",
        "Missing script", 'OK', 'Error') | Out-Null
    exit 1
}

$LauncherDir = Join-Path $ScriptDir $LauncherFolder
$IconDir     = Join-Path $LauncherDir "Icons"
$ActionDir   = Join-Path $LauncherDir "StreamDeck"
foreach ($d in @($LauncherDir, $IconDir, $ActionDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ------------------------------------------------------------------ discovery

function New-Cond($prop, $val) {
    New-Object System.Windows.Automation.PropertyCondition($prop, $val)
}
$tabItemCond = New-Cond $AE::ControlTypeProperty $CT::TabItem

# Sites that put the CURRENT DOCUMENT, FOLDER, OR CONVERSATION in the tab
# title. Matching their full title breaks the moment you navigate or start
# something new, so default to the site name alone and let the tab's pinned
# position disambiguate.
$VolatileTitleSites = @(
    'Google Drive', 'Google Docs', 'Google Sheets', 'Google Slides',
    'Google Forms', 'Google Keep', 'OneDrive', 'Dropbox', 'SharePoint',
    'Notion', 'Trello', 'Asana',
    'Google Gemini', 'Claude', 'ChatGPT', 'Copilot', 'Perplexity',
    # Gmail's title is the current thread, and Google Chat overwrites it
    # entirely when a message arrives - see the ";;" note in the hint.
    'Gmail', 'Google Sites', 'Google Groups', 'Qualtrics'
)

# UI Automation exposes tab names but not URLs, so favicons are fetched by
# guessing a domain from the title. Anything unmatched is left blank for you
# to type in - the Domain column is editable.
$DomainMap = [ordered]@{
    'Google Drive'   = 'drive.google.com'
    'Google Docs'    = 'docs.google.com'
    'Google Sheets'  = 'sheets.google.com'
    'Google Slides'  = 'slides.google.com'
    'Google Forms'   = 'docs.google.com'
    'Google Keep'    = 'keep.google.com'
    'Google Gemini'  = 'gemini.google.com'
    'Google Photos'  = 'photos.google.com'
    'Google Maps'    = 'maps.google.com'
    'Gmail'          = 'mail.google.com'
    'Google Sites'   = 'sites.google.com'
    'Qualtrics'      = 'qualtrics.com'
    'Calendar'       = 'calendar.google.com'
    'Voice'          = 'voice.google.com'
    'Claude'         = 'claude.ai'
    'ChatGPT'        = 'chatgpt.com'
    'Perplexity'     = 'perplexity.ai'
    'Copilot'        = 'copilot.microsoft.com'
    'YouTube'        = 'youtube.com'
    'Stack Overflow' = 'stackoverflow.com'
    'GitHub'         = 'github.com'
    'Reddit'         = 'reddit.com'
    'Elgato'         = 'elgato.com'
    'CARFAX'         = 'carfax.com'
    'OneDrive'       = 'onedrive.live.com'
    'Dropbox'        = 'dropbox.com'
    'Notion'         = 'notion.so'
    'Trello'         = 'trello.com'
    'Asana'          = 'asana.com'
    'Outlook'        = 'outlook.office.com'
    'LinkedIn'       = 'linkedin.com'
    'Amazon'         = 'amazon.com'
}

# Strip the volatile decorations Edge appends to tab names.
function Get-CleanName([string]$raw) {
    $n = $raw
    $n = $n -replace '\s-\s(High\s)?[Mm]emory usage\s-\s[\d.]+\s*[KMG]B\s*$', ''
    $n = $n -replace '\s-\s(Pinned|Sleeping|Muted|Audio playing|Media playing)', ''
    return $n.Trim()
}

# Some sites rewrite their title entirely under certain conditions, so the
# durable match needs a second alternative. Keyed by host.
$HostAlternatives = @{
    'mail.google.com' = @('messaged you - Chat')   # Google Chat hijacks the Gmail title
}

# When the URL is known, it beats the title outright. A tab showing
# "Google Drive messaged you - Chat" is still the mail tab, and no title-based
# rule can know that. These are used by Capture URLs.
#
# Values may contain ";;" alternatives. Gmail needs all three forms: the
# account suffix ("... - JoshWatson.net Mail"), the plain inbox, and the Chat
# notification title.
$HostMatch = [ordered]@{
    'mail.google.com'     = 'Mail;;Inbox;;messaged you - Chat'
    'calendar.google.com' = 'Calendar'
    'drive.google.com'    = 'Google Drive'
    'docs.google.com'     = 'Google Docs'
    'sheets.google.com'   = 'Google Sheets'
    'slides.google.com'   = 'Google Slides'
    'voice.google.com'    = 'Voice -'
    'keep.google.com'     = 'Keep'
    'tasks.google.com'    = 'Tasks'
    'contacts.google.com' = 'Contacts'
    'photos.google.com'   = 'Google Photos'
    'gemini.google.com'   = 'Google Gemini'
    'claude.ai'           = 'Claude'
    'chatgpt.com'         = 'ChatGPT'
    'github.com'          = 'GitHub'
    'youtube.com'         = 'YouTube'
}

# Is this title segment something that changes on its own? Unread counts,
# dates, folder names, notification text.
function Test-VolatileSegment([string]$seg) {
    if (-not $seg) { return $true }
    $t = $seg.Trim()
    if ($t.Length -lt 3)                     { return $true }
    if ($t -match '[\(\)]')                  { return $true }   # "(8) Messages"
    if ($t -match '\d{4}')                   { return $true }   # years
    if ($t -match '^\d')                     { return $true }
    if ($t -match '(?i)\b(January|February|March|April|May|June|July|August|September|October|November|December)\b') { return $true }
    if ($t -match '(?i)(messaged you|unread|new message|week of|today|yesterday|notification)') { return $true }
    if ($t -match '(?i)^(Inbox|Sent|Drafts|Starred|Snoozed|Untitled|New Tab|Home|Dashboard)$')  { return $true }
    return $false
}

# Tab titles read "context - context - identity". The identity - the trailing
# segment - is what survives navigation. Scan right to left for the last
# segment that is not itself volatile. Splits on both " - " and " | ", since
# plenty of sites use pipes.
function Get-SuggestedMatch([string]$clean) {

    foreach ($site in $VolatileTitleSites) {
        if ($clean -like "* - $site" -or $clean -like "* | $site" -or $clean -eq $site) { return $site }
    }

    $parts = @($clean -split '\s+[-|]\s+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    if ($parts.Count -le 1) {
        $m = $clean
        $p = $m.IndexOf('(')
        if ($p -gt 0) { $m = $m.Substring(0, $p) }
        return $m.Trim()
    }

    for ($i = $parts.Count - 1; $i -ge 0; $i--) {
        if (-not (Test-VolatileSegment $parts[$i])) { return $parts[$i] }
    }
    return $parts[0]
}

# Append any known alternative for this host, so the launcher survives a
# wholesale title rewrite.
function Add-HostAlternatives([string]$match, [string]$domainOrUrl) {
    $h = Get-HostPart $domainOrUrl
    if (-not $h -or -not $HostAlternatives.ContainsKey($h)) { return $match }
    $out = $match
    foreach ($alt in $HostAlternatives[$h]) {
        if ($out -notlike "*$alt*") { $out = "$out;;$alt" }
    }
    return $out
}

# Short label for the Stream Deck key face.
function Get-KeyTitle([string]$match) {
    $t = $match.Trim()
    $t = $t -replace '\s*-\s*$', ''      # "Voice -" -> "Voice"
    $t = $t -replace '^Google\s+', ''     # "Google Drive" -> "Drive"
    if ($t.Length -gt 16) { $t = $t.Substring(0, 16).Trim() }
    return $t
}

function Get-IconDomain([string]$text) {
    foreach ($k in $DomainMap.Keys) {
        if ($text -like "*$k*") { return $DomainMap[$k] }
    }
    return ""
}

# The Domain column accepts a bare domain or a full URL. Icons need the host;
# the open-if-missing behavior needs a navigable URL.
function Get-HostPart([string]$v) {
    $v = $v.Trim()
    if (-not $v) { return "" }
    if ($v -match '^https?://') {
        try { return ([Uri]$v).Host } catch { return "" }
    }
    return ($v -split '/')[0]
}

function Get-UrlPart([string]$v) {
    $v = $v.Trim()
    if (-not $v) { return "" }
    if ($v -match '^https?://') { return $v }
    return "https://$v"
}

function Get-ProfileName([string]$windowTitle) {
    if ($windowTitle -match '-\s([^-]+?)\s-\s*Microsoft.{0,2}\s*Edge\s*$') { return $Matches[1].Trim() }
    return ""
}

function Get-EdgeWindowElements {
    $AE::RootElement.FindAll($TS::Children, (New-Cond $AE::ClassNameProperty "Chrome_WidgetWin_1")) |
        Where-Object { $_.Current.Name -like "*Microsoft*Edge" }
}

# UIA exposes only the ACTIVE tab's URL, via the omnibox. Reading a specific
# tab's URL therefore means selecting it first - see the capture button.
function Get-AddressBarUrl($win) {
    $editCond = New-Cond $AE::ControlTypeProperty $CT::Edit
    $edits    = @($win.FindAll($TS::Descendants, $editCond))

    # Prefer the class name: "Address and search bar" is LOCALIZED, so matching
    # on Name breaks on any non-English Windows. OmniboxViewViews does not.
    foreach ($e in $edits) {
        if ($e.Current.ClassName -eq 'OmniboxViewViews') {
            try {
                $v = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
                if ($v) { return $v.Trim() }
            } catch { }
        }
    }

    foreach ($e in $edits) {
        try {
            $v = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
            if ($v -and ($v -match '\.' -or $v -match '^https?://')) { return $v.Trim() }
        } catch { }
    }
    return ""
}

# Web pages can expose their own ARIA role="tab" elements - Gmail's side panel
# (Calendar, Keep, Tasks, Contacts, Get Add-ons) shows up as TabItem exactly
# like a browser tab. Real tabs carry a class name; page tabs do not.
function Get-BrowserTabs($win) {
    $all  = @($win.FindAll($TS::Descendants, $tabItemCond))
    $real = @($all | Where-Object {
        $_.Current.ClassName -eq 'EdgeTab' -or $_.Current.ClassName -eq 'Tab'
    })
    if ($real.Count) { return $real }
    return $all
}

function Get-SelectedTab($win) {
    foreach ($t in (Get-BrowserTabs $win)) {
        try {
            $sp = $t.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if ($sp.Current.IsSelected) { return $t }
        } catch { }
    }
    return $null
}

function Select-Tab($tab) {
    try {
        $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        return $true
    } catch { return $false }
}

function Get-AllTabs {
    $rows = @()
    $windows = Get-EdgeWindowElements

    foreach ($w in $windows) {
        $prof = Get-ProfileName $w.Current.Name
        foreach ($t in (Get-BrowserTabs $w)) {
            $clean = Get-CleanName $t.Current.Name
            $domain = Get-IconDomain $clean
            $match  = Add-HostAlternatives (Get-SuggestedMatch $clean) $domain
            $rows += [PSCustomObject]@{
                Clean   = $clean
                Match   = $match
                Domain  = $domain
                Title   = Get-KeyTitle $match
                Profile = $prof
            }
        }
    }
    return $rows
}

# Mirrors Test-TabName in Focus-EdgeTab.ps1 so the grid shows what the button
# will actually do at press time.
function Get-MatchCount([string]$match) {
    $pats = @($match -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $pats.Count) { return 0 }
    $n = 0
    foreach ($t in $script:AllTabs) {
        foreach ($p in $pats) {
            if ($t.Clean -like "*$p*") { $n++; break }
        }
    }
    return $n
}

function Get-SafeFileName([string]$s) {
    $out = $s
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
        $out = $out.Replace([string]$c, '')
    }
    return $out.Trim()
}

# ---------------------------------------------------------------------- form

$form               = New-Object System.Windows.Forms.Form
$form.Text          = "Stream Deck - Edge tab buttons  (v17)"
$form.StartPosition = "CenterScreen"
$form.Size          = New-Object System.Drawing.Size(1290, 700)
$form.AutoScaleMode = 'Font'

$layout             = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock        = 'Fill'
$layout.ColumnCount = 1
$layout.RowCount    = 4
$layout.Padding     = New-Object System.Windows.Forms.Padding(8)
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$form.Controls.Add($layout)

# --- row 0: filter
$filterBar              = New-Object System.Windows.Forms.FlowLayoutPanel
$filterBar.Dock         = 'Fill'
$filterBar.AutoSize     = $true
$filterBar.WrapContents = $false
$filterBar.Margin       = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)

$filterLabel          = New-Object System.Windows.Forms.Label
$filterLabel.Text     = "Search tabs:"
$filterLabel.AutoSize = $true
$filterLabel.Margin   = New-Object System.Windows.Forms.Padding(0, 7, 6, 0)
$filterBar.Controls.Add($filterLabel)

$filterBox        = New-Object System.Windows.Forms.TextBox
$filterBox.Width  = 320
$filterBox.Margin = New-Object System.Windows.Forms.Padding(0, 3, 6, 0)
$filterBar.Controls.Add($filterBox)

$btnClear          = New-Object System.Windows.Forms.Button
$btnClear.Text     = "Clear"
$btnClear.AutoSize = $true
$btnClear.Margin   = New-Object System.Windows.Forms.Padding(0, 2, 12, 0)
$filterBar.Controls.Add($btnClear)

$btnCheckShown          = New-Object System.Windows.Forms.Button
$btnCheckShown.Text     = "Check all shown"
$btnCheckShown.AutoSize = $true
$btnCheckShown.Margin   = New-Object System.Windows.Forms.Padding(0, 2, 6, 0)
$filterBar.Controls.Add($btnCheckShown)

$btnUncheckAll          = New-Object System.Windows.Forms.Button
$btnUncheckAll.Text     = "Uncheck all"
$btnUncheckAll.AutoSize = $true
$btnUncheckAll.Margin   = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$filterBar.Controls.Add($btnUncheckAll)

$layout.Controls.Add($filterBar, 0, 0)

# --- row 1: grid
$grid                       = New-Object System.Windows.Forms.DataGridView
$grid.Dock                  = 'Fill'
$grid.AllowUserToAddRows    = $false
$grid.AllowUserToDeleteRows = $false
$grid.RowHeadersVisible     = $false
$grid.SelectionMode         = 'FullRowSelect'
$grid.AutoSizeColumnsMode   = 'None'

function Add-Col($type, $name, $header, $width, $readOnly) {
    $c = New-Object $type
    $c.Name       = $name
    $c.HeaderText = $header
    $c.Width      = $width
    $c.ReadOnly   = $readOnly
    # NB: Columns.AddRange(@(...)) fails in PowerShell - Object[] will not bind
    # to DataGridViewColumn[]. Add one at a time.
    [void]$grid.Columns.Add($c)
}

Add-Col 'System.Windows.Forms.DataGridViewCheckBoxColumn' 'Use'     'Use'                      45  $false
Add-Col 'System.Windows.Forms.DataGridViewTextBoxColumn'  'Status'  'Match?'                   70  $true
Add-Col 'System.Windows.Forms.DataGridViewTextBoxColumn'  'Tab'     'Tab'                      330 $true
Add-Col 'System.Windows.Forms.DataGridViewTextBoxColumn'  'Profile' 'Profile'                  75  $true
Add-Col 'System.Windows.Forms.DataGridViewTextBoxColumn'  'Match'   'Match string (editable)'  230 $false
Add-Col 'System.Windows.Forms.DataGridViewTextBoxColumn'  'File'    'Launcher file (editable)' 215 $false
Add-Col 'System.Windows.Forms.DataGridViewTextBoxColumn'  'Domain'  'Domain or URL (editable)' 195 $false
Add-Col 'System.Windows.Forms.DataGridViewTextBoxColumn'  'Title'   'Key title (editable)'     130 $false

if ($grid.Columns.Count -ne 8) {
    [System.Windows.Forms.MessageBox]::Show(
        "Grid columns failed to build ($($grid.Columns.Count) of 8).",
        "Error", 'OK', 'Error') | Out-Null
    exit 1
}

$layout.Controls.Add($grid, 0, 1)

# --- row 2: hint
$hint          = New-Object System.Windows.Forms.Label
$hint.Dock     = 'Fill'
$hint.AutoSize = $true
$hint.Margin   = New-Object System.Windows.Forms.Padding(3, 6, 3, 6)
$hint.Text     = "Match strings are substrings, case-insensitive. Keep them SHORT and free of anything that changes - unread counts, memory figures, or the current document/folder name." + [Environment]::NewLine +
                 "Domain or URL is used for the icon AND for opening the tab if it is missing. Yellow match cells look volatile - run Capture URLs, which re-derives them from the real address."
$layout.Controls.Add($hint, 0, 2)

# --- row 3: actions
$bar              = New-Object System.Windows.Forms.FlowLayoutPanel
$bar.Dock         = 'Fill'
$bar.AutoSize     = $true
$bar.WrapContents = $false
$layout.Controls.Add($bar, 0, 3)

function New-Button($text) {
    $b              = New-Object System.Windows.Forms.Button
    $b.Text         = $text
    $b.AutoSize     = $true
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.Margin       = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $b.Padding      = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)
    $bar.Controls.Add($b)
    return $b
}

# Primary path: Refresh -> tick rows -> Build. Everything else is advanced,
# hidden by default so the main flow is unambiguous.
$btnRefresh  = New-Button "Refresh tabs"
$btnCapture  = New-Button "Capture URLs"
$btnBuild    = New-Button "Build selected buttons"
$btnAdvanced = New-Button "Advanced..."
$btnClose    = New-Button "Close"

$btnSiteOnly = New-Button "Match site only"
$btnTest     = New-Button "Test selected row"
$btnCreate   = New-Button "Create launchers only"
$btnIcons    = New-Button "Download icons only"
$btnExport   = New-Button "Export actions only"
$btnRepair   = New-Button "Repair folder paths"
$btnOpenDir  = New-Button "Open folder"

$script:AdvancedButtons = @($btnSiteOnly, $btnTest, $btnCreate, $btnIcons, $btnExport, $btnRepair, $btnOpenDir)
foreach ($b in $script:AdvancedButtons) { $b.Visible = $false }

$btnAdvanced.Add_Click({
    $show = -not $script:AdvancedButtons[0].Visible
    foreach ($b in $script:AdvancedButtons) { $b.Visible = $show }
    $btnAdvanced.Text = if ($show) { "Hide advanced" } else { "Advanced..." }
})

$status          = New-Object System.Windows.Forms.Label
$status.AutoSize = $true
$status.Margin   = New-Object System.Windows.Forms.Padding(12, 10, 0, 0)
$bar.Controls.Add($status)

# -------------------------------------------------------------- exit splash

$script:CreatedTotal = 0

function Show-ExitSplash {

    $s                 = New-Object System.Windows.Forms.Form
    $s.Text            = "One more step"
    $s.StartPosition   = 'CenterScreen'
    $s.FormBorderStyle = 'FixedDialog'
    $s.MaximizeBox     = $false
    $s.MinimizeBox     = $false
    $s.AutoScaleMode   = 'Font'
    # Size to content. A hardcoded ClientSize clips text at other display
    # scalings, since AutoSize labels never wrap.
    $s.AutoSize        = $true
    $s.AutoSizeMode    = 'GrowAndShrink'
    $s.MinimumSize     = New-Object System.Drawing.Size(560, 0)

    $t              = New-Object System.Windows.Forms.TableLayoutPanel
    $t.Dock         = 'Fill'
    $t.ColumnCount  = 1
    $t.RowCount     = 4
    $t.AutoSize     = $true
    $t.AutoSizeMode = 'GrowAndShrink'
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    for ($i = 0; $i -lt 4; $i++) {
        [void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    }
    $s.Controls.Add($t)

    $banner              = New-Object System.Windows.Forms.Panel
    $banner.Dock         = 'Fill'
    $banner.AutoSize     = $true
    $banner.AutoSizeMode = 'GrowAndShrink' 
    $banner.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#1F3A5F")
    $banner.Padding   = New-Object System.Windows.Forms.Padding(20, 16, 20, 16)
    $banner.Margin    = New-Object System.Windows.Forms.Padding(0)

    $bannerText           = New-Object System.Windows.Forms.Label
    $bannerText.Dock      = 'Top'
    $bannerText.AutoSize  = $true
    $bannerText.ForeColor = [System.Drawing.Color]::White
    $bannerText.Font      = New-Object System.Drawing.Font("Segoe UI", 17, [System.Drawing.FontStyle]::Bold)
    $bannerText.Text      = "System  >  Open  >  File"
    $banner.Controls.Add($bannerText)

    $bannerSub           = New-Object System.Windows.Forms.Label
    $bannerSub.Dock      = 'Top'
    $bannerSub.AutoSize  = $true
    $bannerSub.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#B9CBE3")
    $bannerSub.Font      = New-Object System.Drawing.Font("Segoe UI", 9.75)
    $bannerSub.Margin    = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $bannerSub.Text      = "That is the Stream Deck action these .vbs launchers need."
    $banner.Controls.Add($bannerSub)
    $bannerSub.BringToFront()

    $t.Controls.Add($banner, 0, 0)

    $steps          = New-Object System.Windows.Forms.Label
    $steps.Dock     = 'Fill'
    $steps.AutoSize = $true
    $steps.Margin   = New-Object System.Windows.Forms.Padding(20, 18, 20, 8)
    $steps.Font     = New-Object System.Drawing.Font("Segoe UI", 10)
    $steps.Text     = @"
To wire up a button:

FASTEST - import a ready-made key:
   Double-click a .streamDeckAction file in the StreamDeck subfolder,
   or drag it onto the key you want. Icon and title come with it.

BY HAND - if you would rather wire it yourself:
   1.  In Stream Deck, open the System category.
   2.  Drag the Open action onto an empty key.
   3.  Click App / File, then Browse.
   4.  Pick a .vbs launcher from the folder below.
   5.  Drag an icon from the Icons subfolder onto the key.

Do NOT use Website, Hotkey, or Multi Action - the launcher is a file,
so it has to be opened, not run as a URL or a keystroke.

Nothing to configure for double-press: the script detects it itself.
"@
    $t.Controls.Add($steps, 0, 1)

    $pathBox           = New-Object System.Windows.Forms.TextBox
    $pathBox.Dock      = 'Fill'
    $pathBox.ReadOnly  = $true
    $pathBox.Text      = $LauncherDir
    $pathBox.Font      = New-Object System.Drawing.Font("Consolas", 10)
    $pathBox.Margin    = New-Object System.Windows.Forms.Padding(20, 0, 20, 10)
    $pathBox.BackColor = [System.Drawing.Color]::White
    $t.Controls.Add($pathBox, 0, 2)

    $row              = New-Object System.Windows.Forms.FlowLayoutPanel
    $row.Dock         = 'Fill'
    $row.AutoSize     = $true
    $row.AutoSizeMode = 'GrowAndShrink'
    $row.WrapContents = $true
    $row.Margin       = New-Object System.Windows.Forms.Padding(20, 0, 20, 14)

    $count           = New-Object System.Windows.Forms.Label
    $count.AutoSize  = $true
    $count.Margin    = New-Object System.Windows.Forms.Padding(0, 10, 20, 0)
    $count.ForeColor = [System.Drawing.Color]::DimGray
    $count.Text      = if ($script:CreatedTotal -gt 0) {
                           "$($script:CreatedTotal) launcher(s) created this session."
                       } else {
                           "No launchers created this session."
                       }
    $row.Controls.Add($count)

    function New-SplashButton($text) {
        $b              = New-Object System.Windows.Forms.Button
        $b.Text         = $text
        $b.AutoSize     = $true
        $b.AutoSizeMode = 'GrowAndShrink'
        $b.Padding      = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)
        $b.Margin       = New-Object System.Windows.Forms.Padding(0, 4, 8, 0)
        $row.Controls.Add($b)
        return $b
    }

    $bOpen = New-SplashButton "Open launcher folder"
    $bCopy = New-SplashButton "Copy path"
    $bDone = New-SplashButton "Got it"

    $bOpen.Add_Click({ Start-Process explorer.exe $LauncherDir })
    $bCopy.Add_Click({ Set-Clipboard -Value $LauncherDir })
    $bDone.Add_Click({ $s.Close() })
    $s.AcceptButton = $bDone

    $t.Controls.Add($row, 0, 3)

    [void]$s.ShowDialog()
}


# --------------------------------------------------- Stream Deck action export
#
# A .streamDeckAction is a zip holding a one-key .sdProfile tree:
#
#   package.json
#   Profiles/<GUID>.sdProfile/manifest.json
#   Profiles/<GUID>.sdProfile/Profiles/<DEFAULT-PAGE>/manifest.json   (empty)
#   Profiles/<GUID>.sdProfile/Profiles/<ACTION-PAGE>/manifest.json    (the key)
#   Profiles/<GUID>.sdProfile/Profiles/<ACTION-PAGE>/Images/<rand>.png
#
# Key images are 288x288 RGBA PNG.

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-EntryName {
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 26; $i++) { [void]$sb.Append($chars[(Get-Random -Maximum $chars.Length)]) }
    return $sb.ToString() + "Z"
}

function Add-ZipText($zip, $name, $text) {
    $entry  = $zip.CreateEntry($name)
    $stream = $entry.Open()
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    $writer.Write($text)
    $writer.Flush(); $writer.Dispose(); $stream.Dispose()
}

# Explicit directory entries, to mirror what Stream Deck itself exports.
function Add-ZipDir($zip, $name) {
    [void]$zip.CreateEntry($name.TrimEnd('/') + '/')
}

function Add-ZipBytes($zip, $name, $bytes) {
    $entry  = $zip.CreateEntry($name)
    $stream = $entry.Open()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Dispose()
}

# Compose a 288x288 key face. Favicons are 128px, so they are centred at a
# modest upscale rather than stretched edge to edge.
function New-KeyImageBytes([string]$iconPath, [string]$label) {
    $bmp = New-Object System.Drawing.Bitmap(288, 288, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $drew = $false
    if ($iconPath -and (Test-Path $iconPath)) {
        try {
            # Load via memory stream so the PNG file is not left locked.
            $bytes = [System.IO.File]::ReadAllBytes($iconPath)
            $ms    = New-Object System.IO.MemoryStream(,$bytes)
            $src   = [System.Drawing.Image]::FromStream($ms)
            $size  = 176
            $g.DrawImage($src, [int](((288 - $size) / 2)), 48, $size, $size)
            $src.Dispose(); $ms.Dispose()
            $drew = $true
        } catch { }
    }

    if (-not $drew) {
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml("#1F3A5F"))
        $g.FillRectangle($brush, 0, 0, 288, 288)
        $brush.Dispose()
        $initial = if ($label) { $label.Substring(0, 1).ToUpper() } else { "?" }
        $font    = New-Object System.Drawing.Font("Segoe UI", 110, [System.Drawing.FontStyle]::Bold)
        $fmt     = New-Object System.Drawing.StringFormat
        $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
        $white   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $g.DrawString($initial, $font, $white, (New-Object System.Drawing.RectangleF(0, 0, 288, 288)), $fmt)
        $font.Dispose(); $white.Dispose()
    }

    $g.Dispose()
    $out = New-Object System.IO.MemoryStream
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return $out.ToArray()
}

function Export-StreamDeckAction([string]$vbsPath, [string]$title, [string]$iconPath, [string]$outPath) {

    $profileGuid = ([guid]::NewGuid().ToString()).ToUpper()
    $defaultPage = ([guid]::NewGuid().ToString()).ToUpper()
    $actionPage  = ([guid]::NewGuid().ToString()).ToUpper()
    $actionId    = [guid]::NewGuid().ToString()
    $deviceUuid  = [guid]::NewGuid().ToString()
    $imageName   = New-EntryName

    $root  = "Profiles/$profileGuid.sdProfile"
    $pages = "$root/Profiles"

    $package = [ordered]@{
        AppVersion      = "7.5.1.22901"
        DeviceModel     = "Fake/Storage"
        DeviceSettings  = $null
        FormatVersion   = 1
        OSType          = "Windows"
        OSVersion       = [string][System.Environment]::OSVersion.Version
        RequiredPlugins = @("com.elgato.streamdeck.system.open")
    } | ConvertTo-Json -Compress

    $profileManifest = [ordered]@{
        Device  = [ordered]@{ Model = "Fake/Storage"; UUID = $deviceUuid }
        Name    = "Default Profile"
        Pages   = [ordered]@{
            Current = "00000000-0000-0000-0000-000000000000"
            Default = $defaultPage.ToLower()
            Pages   = @($actionPage.ToLower())
        }
        Version = "3.0"
    } | ConvertTo-Json -Depth 6 -Compress

    $emptyPage = [ordered]@{
        Controllers = @(
            [ordered]@{ Actions = $null; Type = "Keypad" },
            [ordered]@{ Actions = $null; Type = "Encoder" },
            [ordered]@{ Actions = $null; Type = "Neo" }
        )
        Icon = ""
        Name = ""
    } | ConvertTo-Json -Depth 6 -Compress

    # The path setting is itself quoted, because these paths contain spaces.
    $quotedPath = '"' + $vbsPath + '"'

    $keyAction = [ordered]@{
        ActionID    = $actionId
        LinkedTitle = $true
        Name        = "Open"
        Plugin      = [ordered]@{ Name = "Open"; UUID = "com.elgato.streamdeck.system.open"; Version = "1.0" }
        Resources   = $null
        Settings    = [ordered]@{ path = $quotedPath }
        State       = 0
        States      = @([ordered]@{ Image = "Images/$imageName.png"; Title = $title })
        UUID        = "com.elgato.streamdeck.system.open"
    }

    $actionManifest = [ordered]@{
        '$uuid'     = $actionPage.ToLower()
        Controllers = @(
            [ordered]@{ Actions = [ordered]@{ '0,0' = $keyAction }; Type = "Keypad" },
            [ordered]@{ Actions = $null; Type = "Encoder" },
            [ordered]@{ Actions = $null; Type = "Neo" }
        )
        Icon = ""
        Name = ""
    } | ConvertTo-Json -Depth 12

    if (Test-Path $outPath) { Remove-Item $outPath -Force }
    $zip = [System.IO.Compression.ZipFile]::Open($outPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Add-ZipText  $zip "package.json" $package

        Add-ZipDir   $zip "Profiles"
        Add-ZipDir   $zip $root
        Add-ZipText  $zip "$root/manifest.json" $profileManifest

        Add-ZipDir   $zip $pages
        Add-ZipDir   $zip "$pages/$defaultPage"
        Add-ZipDir   $zip "$pages/$defaultPage/Images"
        Add-ZipText  $zip "$pages/$defaultPage/manifest.json" $emptyPage

        Add-ZipDir   $zip "$pages/$actionPage"
        Add-ZipDir   $zip "$pages/$actionPage/Images"
        Add-ZipBytes $zip "$pages/$actionPage/Images/$imageName.png" (New-KeyImageBytes $iconPath $title)
        Add-ZipText  $zip "$pages/$actionPage/manifest.json" $actionManifest
    } finally {
        $zip.Dispose()
    }
}

# ------------------------------------------------------------------- actions

$script:AllTabs   = @()
$script:RowState  = @{}      # keyed by tab name, survives filtering

function Save-GridState {
    foreach ($row in $grid.Rows) {
        $key = [string]$row.Cells["Tab"].Value
        if (-not $key) { continue }
        $script:RowState[$key] = @{
            Use    = ($row.Cells["Use"].Value -eq $true)
            Match  = [string]$row.Cells["Match"].Value
            File   = [string]$row.Cells["File"].Value
            Domain = [string]$row.Cells["Domain"].Value
            Title  = [string]$row.Cells["Title"].Value
        }
    }
}

function Fill-Grid {
    $filter = $filterBox.Text.Trim()
    $grid.Rows.Clear()
    $shown = 0

    foreach ($r in $script:AllTabs) {
        if ($filter -and ($r.Clean -notlike "*$filter*") -and ($r.Match -notlike "*$filter*")) { continue }

        $st = $script:RowState[$r.Clean]
        if ($st) {
            [void]$grid.Rows.Add($st.Use, "", $r.Clean, $r.Profile, $st.Match, $st.File, $st.Domain, $st.Title)
        } else {
            $file = "Focus " + (Get-SafeFileName $r.Match) + ".vbs"
            [void]$grid.Rows.Add($false, "", $r.Clean, $r.Profile, $r.Match, $file, $r.Domain, $r.Title)
        }

        $row      = $grid.Rows[$grid.Rows.Count - 1]
        $matchStr = [string]$row.Cells["Match"].Value

        # How many tabs would this match right now? Exactly one is what you
        # want; zero is a broken button; several means the index decides.
        $hits = Get-MatchCount $matchStr
        if ($hits -eq 0) {
            $row.Cells["Status"].Value = "none"
            $row.Cells["Status"].Style.BackColor = [System.Drawing.Color]::FromArgb(255, 205, 210)
            $row.Cells["Status"].ToolTipText = "Nothing open matches this. The button will only work if it has an address to open."
        } elseif ($hits -eq 1) {
            $row.Cells["Status"].Value = "ok"
            $row.Cells["Status"].Style.BackColor = [System.Drawing.Color]::FromArgb(200, 230, 201)
        } else {
            $row.Cells["Status"].Value = "$hits"
            $row.Cells["Status"].Style.BackColor = [System.Drawing.Color]::FromArgb(255, 224, 178)
            $row.Cells["Status"].ToolTipText = "$hits tabs match. The occurrence number decides which one, and that can shift."
        }

        # Flag matches that still look volatile, so a bad one is visible
        # before it becomes a button that fails intermittently.
        $firstPat = ($matchStr -split ';;')[0]
        if (Test-VolatileSegment $firstPat) {
            $row.Cells["Match"].Style.BackColor = [System.Drawing.Color]::FromArgb(255, 249, 196)
            $row.Cells["Match"].ToolTipText = "This looks like it changes on its own. Run Capture URLs, or edit it."
        }

        $shown++
    }

    $checked = @($script:RowState.Values | Where-Object { $_.Use }).Count
    $status.Text = "$shown of $($script:AllTabs.Count) tabs shown  |  $checked checked  |  -> $LauncherFolder\"
}

function Load-Tabs {
    Save-GridState
    $script:AllTabs = @(Get-AllTabs)
    Fill-Grid
}

$filterBox.Add_TextChanged({ Save-GridState; Fill-Grid })
$btnClear.Add_Click({ $filterBox.Text = "" })
$btnRefresh.Add_Click({ Load-Tabs })

$btnCheckShown.Add_Click({
    [void]$grid.EndEdit()
    foreach ($row in $grid.Rows) { $row.Cells["Use"].Value = $true }
    Save-GridState
    Fill-Grid
})

$btnUncheckAll.Add_Click({
    [void]$grid.EndEdit()
    foreach ($k in @($script:RowState.Keys)) { $script:RowState[$k].Use = $false }
    foreach ($row in $grid.Rows) { $row.Cells["Use"].Value = $false }
    Fill-Grid
})

# Rewrite Match to just the trailing site segment, e.g. "Google Gemini".
$btnSiteOnly.Add_Click({
    [void]$grid.EndEdit()
    foreach ($row in $grid.Rows) {
        if ($row.Cells["Use"].Value -eq $true) {
            $clean = [string]$row.Cells["Tab"].Value
            $parts = $clean -split '\s-\s'
            if ($parts.Count -ge 2) {
                $site = $parts[$parts.Count - 1].Trim()
                $row.Cells["Match"].Value  = $site
                $row.Cells["File"].Value   = "Focus " + (Get-SafeFileName $site) + ".vbs"
                $row.Cells["Domain"].Value = Get-IconDomain $site
                $row.Cells["Title"].Value  = Get-KeyTitle $site
            }
        }
    }
    Save-GridState
})

$btnTest.Add_Click({
    [void]$grid.EndEdit()
    if ($grid.SelectedRows.Count -eq 0) { return }
    $match = [string]$grid.SelectedRows[0].Cells["Match"].Value
    if (-not $match) { return }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PsTarget`"",'-TabName',"`"$match`""
    )
})

$btnCreate.Add_Click({
    [void]$grid.EndEdit()
    Save-GridState

    # Current tab order, so we can pin an index when a match is ambiguous.
    $allTabs = @(Get-AllTabs)
    $created = @()
    $skipped = @()

    foreach ($key in $script:RowState.Keys) {
        $st = $script:RowState[$key]
        if (-not $st.Use) { continue }

        $match = ($st.Match).Trim()
        $file  = ($st.File).Trim()
        $clean = $key
        $prof  = ($script:AllTabs | Where-Object { $_.Clean -eq $key } | Select-Object -First 1).Profile

        if (-not $match -or -not $file) { continue }
        if ($file -notlike "*.vbs") { $file += ".vbs" }

        # Which occurrence of this match is the tab the user picked?
        $hits  = @($allTabs | Where-Object { $_.Clean -like "*$match*" })
        $index = 1
        for ($i = 0; $i -lt $hits.Count; $i++) {
            if ($hits[$i].Clean -eq $clean) { $index = $i + 1; break }
        }

        $path = Join-Path $LauncherDir (Get-SafeFileName $file)
        if (Test-Path $path) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "Overwrite existing file?`n`n$path", "File exists", 'YesNo', 'Question')
            if ($ans -ne 'Yes') { $skipped += $file; continue }
        }

        # Double the quotes for VBS string literals.
        $q       = '""'
        $argLine = "-NoProfile -ExecutionPolicy Bypass -File ${q}$PsTarget${q} -TabName ${q}$match${q} -Index $index"
        if ($prof) { $argLine += " -EdgeProfile ${q}$prof${q}" }

        $url = Get-UrlPart ([string]$st.Domain)
        if ($url) { $argLine += " -Url ${q}$url${q}" }

        $body = @"
' Auto-generated by New-TabButton.ps1
' Tab   : $clean
' Match : $match  (occurrence $index)
' Opens : $url  (only if the tab is missing - double-press when Edge is open)
' Point Stream Deck's System > Open action at this file.

CreateObject("WScript.Shell").Run "powershell.exe $argLine", 0, False
"@
        Set-Content -Path $path -Value $body -Encoding ASCII
        $created += $path
        $script:CreatedTotal++
    }

    $msg = if ($created.Count) { "Created in $LauncherDir`n`n" + (($created | Split-Path -Leaf) -join "`n") } else { "Nothing created." }
    if ($skipped.Count) { $msg += "`n`nSkipped:`n" + ($skipped -join "`n") }
    [System.Windows.Forms.MessageBox]::Show($msg, "Done", 'OK', 'Information') | Out-Null
})

$btnIcons.Add_Click({
    [void]$grid.EndEdit()
    Save-GridState

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $ok = @(); $failed = @(); $noDomain = @()

    foreach ($key in $script:RowState.Keys) {
        $st = $script:RowState[$key]
        if (-not $st.Use) { continue }

        $domain = Get-HostPart ([string]$st.Domain)
        if (-not $domain) { $noDomain += $key; continue }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($st.File)
        if (-not $baseName) { $baseName = Get-SafeFileName $st.Match }
        $out = Join-Path $IconDir ((Get-SafeFileName $baseName) + ".png")

        try {
            Invoke-WebRequest -Uri "https://www.google.com/s2/favicons?domain=$domain&sz=128" `
                              -OutFile $out -UseBasicParsing -TimeoutSec 20
            $ok += (Split-Path $out -Leaf)
        } catch {
            $failed += "$key ($domain)"
        }
    }

    $msg = "Icons saved to:`n$IconDir`n`n"
    if ($ok.Count)       { $msg += "Downloaded:`n" + ($ok -join "`n") + "`n`n" }
    if ($noDomain.Count) { $msg += "No domain set (type one in the Domain column):`n" + ($noDomain -join "`n") + "`n`n" }
    if ($failed.Count)   { $msg += "Failed:`n" + ($failed -join "`n") }
    [System.Windows.Forms.MessageBox]::Show($msg, "Icons", 'OK', 'Information') | Out-Null
})


# Build one launcher and return its path (used by both Create and Export).
function Write-Launcher($key, $st, $allTabs) {
    $match = ($st.Match).Trim()
    $file  = ($st.File).Trim()
    if (-not $match -or -not $file) { return $null }
    if ($file -notlike "*.vbs") { $file += ".vbs" }

    $prof = ($script:AllTabs | Where-Object { $_.Clean -eq $key } | Select-Object -First 1).Profile

    $hits  = @($allTabs | Where-Object { $_.Clean -like "*$match*" })
    $index = 1
    for ($i = 0; $i -lt $hits.Count; $i++) {
        if ($hits[$i].Clean -eq $key) { $index = $i + 1; break }
    }

    $q       = '""'
    $argTail = "-TabName ${q}$match${q} -Index $index"
    if ($prof) { $argTail += " -EdgeProfile ${q}$prof${q}" }
    $url = Get-UrlPart ([string]$st.Domain)
    if ($url) { $argTail += " -Url ${q}$url${q}" }

    $safeKey   = $key   -replace '"', "'"
    $safeMatch = $match -replace '"', "'"

    $path = Join-Path $LauncherDir (Get-SafeFileName $file)

    # The launcher finds Focus-EdgeTab.ps1 relative to ITSELF rather than
    # storing an absolute path, so the whole folder can be moved or handed to
    # someone else without editing anything.
    $body = @"
' Auto-generated by New-TabButton.ps1
' Tab   : $safeKey
' Match : $safeMatch  (occurrence $index)
' Opens : $url  (only if the tab is missing - double-press when the browser is open)
' Point Stream Deck's System > Open action at this file.

Option Explicit
Dim fso, here, ps, cmd
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps   = here & "\Focus-EdgeTab.ps1"
If Not fso.FileExists(ps) Then ps = fso.GetParentFolderName(here) & "\Focus-EdgeTab.ps1"

If Not fso.FileExists(ps) Then
    MsgBox "Focus-EdgeTab.ps1 was not found next to this file or one folder up." & vbCrLf & vbCrLf & _
           "Keep the button files in their folder alongside the scripts.", 48, "Missing script"
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ps & """ $argTail"
CreateObject("WScript.Shell").Run cmd, 0, False
"@
    # Only prompt when an existing launcher differs - re-exporting an unchanged
    # button should be silent, but a hand-edited one must not be clobbered.
    if (Test-Path $path) {
        $existing = (Get-Content $path -Raw) -replace "`r`n", "`n"
        $proposed = $body -replace "`r`n", "`n"
        if ($existing.Trim() -ne $proposed.Trim()) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "This launcher already exists and differs from what would be generated:`n`n$path`n`nOverwrite it?`n`nNo = keep the existing file and still build the Stream Deck action from it.",
                "Launcher differs", 'YesNo', 'Question')
            if ($ans -ne 'Yes') { return $path }
        }
    }

    Set-Content -Path $path -Value $body -Encoding ASCII
    return $path
}

function Fetch-Icon($st) {
    $domain = Get-HostPart ([string]$st.Domain)
    if (-not $domain) { return $null }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($st.File)
    if (-not $baseName) { $baseName = Get-SafeFileName $st.Match }
    $out = Join-Path $IconDir ((Get-SafeFileName $baseName) + ".png")
    if (Test-Path $out) { return $out }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "https://www.google.com/s2/favicons?domain=$domain&sz=128" `
                          -OutFile $out -UseBasicParsing -TimeoutSec 20
        return $out
    } catch { return $null }
}

function Invoke-ExportActions([bool]$announce = $true) {
    [void]$grid.EndEdit()
    Save-GridState

    $allTabs = @(Get-AllTabs)
    $made    = @()
    $failed  = @()

    foreach ($key in $script:RowState.Keys) {
        $st = $script:RowState[$key]
        if (-not $st.Use) { continue }

        try {
            # Export is self-sufficient: launcher and icon are created if missing.
            $vbs = Write-Launcher $key $st $allTabs
            if (-not $vbs) { continue }

            $icon  = Fetch-Icon $st
            $title = ([string]$st.Title).Trim()
            if (-not $title) { $title = Get-KeyTitle ([string]$st.Match) }

            $outName = "Open - " + (Get-SafeFileName $title) + ".streamDeckAction"
            $outPath = Join-Path $ActionDir $outName

            Export-StreamDeckAction $vbs $title $icon $outPath
            $made += $outName
            $script:CreatedTotal++
        } catch {
            $failed += "$key - $($_.Exception.Message)"
        }
    }

    if ($announce) {
        $msg = "Stream Deck actions written to:`n$ActionDir`n`n"
        if ($made.Count)   { $msg += ($made -join "`n") + "`n`n" }
        if ($failed.Count) { $msg += "Failed:`n" + ($failed -join "`n") + "`n`n" }
        $msg += "Double-click a file (or drag it onto a key) to import it into Stream Deck."
        [System.Windows.Forms.MessageBox]::Show($msg, "Export", 'OK', 'Information') | Out-Null
    }
    return $made
}

$btnExport.Add_Click({ [void](Invoke-ExportActions $true) })


function Invoke-CaptureUrls {
    [void]$grid.EndEdit()
    Save-GridState

    $wanted = @($script:RowState.Keys | Where-Object { $script:RowState[$_].Use })
    if (-not $wanted.Count) {
        [System.Windows.Forms.MessageBox]::Show(
            "Check the rows you want URLs for first.", "Capture URLs", 'OK', 'Information') | Out-Null
        return
    }

    $ans = [System.Windows.Forms.MessageBox]::Show(
        "This briefly switches to each checked tab to read its address bar, then puts your original tabs back.`n`n$($wanted.Count) tab(s) to visit. Continue?",
        "Capture URLs", 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }

    $found   = 0
    $missed  = @()
    $windows = @(Get-EdgeWindowElements)

    # Remember what was active so the capture is non-destructive.
    $restore = @{}
    for ($i = 0; $i -lt $windows.Count; $i++) {
        $restore[$i] = Get-SelectedTab $windows[$i]
    }

    for ($i = 0; $i -lt $windows.Count; $i++) {
        $w = $windows[$i]
        foreach ($t in (Get-BrowserTabs $w)) {
            $clean = Get-CleanName $t.Current.Name
            if ($wanted -notcontains $clean) { continue }

            if (Select-Tab $t) {
                Start-Sleep -Milliseconds 350      # let the omnibox catch up
                $url = Get-AddressBarUrl $w
                if ($url) {
                    $full = Get-UrlPart $url
                    $script:RowState[$clean].Domain = $full

                    # The real host is now known, and it is more reliable than
                    # the title - especially for a tab caught mid-notification.
                    $hostName = Get-HostPart $full
                    if ($HostMatch.Contains($hostName)) {
                        $newMatch = $HostMatch[$hostName]
                    } else {
                        $newMatch = Add-HostAlternatives (Get-SuggestedMatch $clean) $full
                    }

                    $script:RowState[$clean].Match = $newMatch
                    $script:RowState[$clean].Title = Get-KeyTitle (($newMatch -split ';;')[0])
                    $script:RowState[$clean].File  = "Focus " + (Get-SafeFileName (($newMatch -split ';;')[0])) + ".vbs"
                    $found++
                } else {
                    $missed += $clean
                }
            } else {
                $missed += $clean
            }
        }
    }

    # Put the original tabs back.
    for ($i = 0; $i -lt $windows.Count; $i++) {
        if ($restore[$i]) { [void](Select-Tab $restore[$i]) }
    }

    Fill-Grid
    [void]$form.Activate()

    $msg = "Captured $found URL(s)."
    if ($missed.Count) { $msg += "`n`nNo URL read for:`n" + (($missed | Select-Object -Unique) -join "`n") }
    [System.Windows.Forms.MessageBox]::Show($msg, "Capture URLs", 'OK', 'Information') | Out-Null
}

$btnCapture.Add_Click({ Invoke-CaptureUrls })


# One-click path: optionally capture real URLs, then build launcher + icon +
# importable action for every ticked row.
$btnBuild.Add_Click({
    [void]$grid.EndEdit()
    Save-GridState

    $checked = @($script:RowState.Keys | Where-Object { $script:RowState[$_].Use })
    if (-not $checked.Count) {
        [System.Windows.Forms.MessageBox]::Show(
            "Tick the tabs you want buttons for first, in the Use column.",
            "Nothing selected", 'OK', 'Information') | Out-Null
        return
    }

    # Rows with no address cannot open anything if the tab is closed, and a
    # captured URL also sharpens the match string. Offer it once.
    $needUrl = @($checked | Where-Object { -not ([string]$script:RowState[$_].Domain).Trim() })
    if ($needUrl.Count) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "$($needUrl.Count) of $($checked.Count) selected tab(s) have no address yet.`n`nCapture them now? This briefly switches to each tab and puts your originals back.`n`nWithout an address, those buttons can focus the tab but cannot reopen it once it is closed.",
            "Capture addresses first?", 'YesNo', 'Question')
        if ($ans -eq 'Yes') { Invoke-CaptureUrls }
    }

    $made = @(Invoke-ExportActions $false)

    $msg = "Built $($made.Count) button(s)."
    $msg += "`n`nLaunchers:  $LauncherDir"
    $msg += "`nIcons:      $IconDir"
    $msg += "`nStream Deck: $ActionDir"
    $msg += "`n`nNext: double-click a file in the Stream Deck folder, or drag it onto a key."
    [System.Windows.Forms.MessageBox]::Show($msg, "Done", 'OK', 'Information') | Out-Null
})

# Launchers generated before v16 stored an absolute path to Focus-EdgeTab.ps1.
# If the folder was moved, rewrite them to the portable, self-locating form.
$btnRepair.Add_Click({
    $files = @(Get-ChildItem -Path $LauncherDir -Filter *.vbs -ErrorAction SilentlyContinue)
    if (-not $files.Count) {
        [System.Windows.Forms.MessageBox]::Show("No launcher files found in:`n$LauncherDir",
            "Repair", 'OK', 'Information') | Out-Null
        return
    }

    $fixed = @(); $ok = 0
    foreach ($f in $files) {
        $text = Get-Content $f.FullName -Raw

        # Already portable?
        if ($text -match 'fso\.FileExists\(ps\)') { $ok++; continue }

        if ($text -match '-File\s+""([^"]+\.ps1)""') {
            $embedded = $Matches[1]
            if (-not (Test-Path $embedded)) {
                # Plain string replace - the path contains backslashes, which
                # -replace would treat as regex escapes on both sides.
                $text = $text.Replace($embedded, $PsTarget)
                Set-Content -Path $f.FullName -Value $text -Encoding ASCII
                $fixed += $f.Name
            } else { $ok++ }
        }
    }

    $msg = "$ok launcher(s) already fine."
    if ($fixed.Count) { $msg += "`n`nRepaired:`n" + ($fixed -join "`n") }
    else { $msg += "`n`nNothing needed repairing." }
    $msg += "`n`nNote: Stream Deck keys store the launcher path too. If you moved this folder, re-import the actions from:`n$ActionDir"
    [System.Windows.Forms.MessageBox]::Show($msg, "Repair", 'OK', 'Information') | Out-Null
})

# Re-validate as soon as an edit lands, so the Match? column never lies.
# NB: do NOT call Fill-Grid here - clearing rows while the edit is committing
# re-enters the grid and throws. Update just the edited row.
$grid.Add_CellEndEdit({
    param($sender, $e)
    try {
        $row      = $grid.Rows[$e.RowIndex]
        $matchStr = [string]$row.Cells["Match"].Value
        $hits     = Get-MatchCount $matchStr

        if ($hits -eq 0) {
            $row.Cells["Status"].Value = "none"
            $row.Cells["Status"].Style.BackColor = [System.Drawing.Color]::FromArgb(255, 205, 210)
        } elseif ($hits -eq 1) {
            $row.Cells["Status"].Value = "ok"
            $row.Cells["Status"].Style.BackColor = [System.Drawing.Color]::FromArgb(200, 230, 201)
        } else {
            $row.Cells["Status"].Value = "$hits"
            $row.Cells["Status"].Style.BackColor = [System.Drawing.Color]::FromArgb(255, 224, 178)
        }

        $firstPat = ($matchStr -split ';;')[0]
        $row.Cells["Match"].Style.BackColor = if (Test-VolatileSegment $firstPat) {
            [System.Drawing.Color]::FromArgb(255, 249, 196)
        } else {
            [System.Drawing.Color]::White
        }

        Save-GridState
    } catch { }
})

$btnOpenDir.Add_Click({ Start-Process explorer.exe $LauncherDir })
$btnClose.Add_Click({ $form.Close() })

Load-Tabs
[void]$form.ShowDialog()
Show-ExitSplash
