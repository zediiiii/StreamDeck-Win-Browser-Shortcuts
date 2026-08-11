# Diagnose-Tabs.ps1 - diagnostic only, safe to delete afterward.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Diagnose-Tabs.ps1"
#
# Reports, per Edge window: whether the tab strip was located, what it is,
# what is inside it, and what every TabItem in the window looks like.

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

function New-Cond($prop, $val) {
    New-Object System.Windows.Automation.PropertyCondition($prop, $val)
}
$tabItemCond = New-Cond $AE::ControlTypeProperty $CT::TabItem

function Find-TabStrip($win) {
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $queue  = New-Object System.Collections.Queue
    $queue.Enqueue(@{ El = $win; Depth = 0 })

    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if ($item.Depth -gt 8) { continue }
        try { $child = $walker.GetFirstChild($item.El) } catch { $child = $null }
        while ($child -ne $null) {
            $cn = ""
            try { $cn = $child.Current.ClassName } catch { }
            if ($cn -like '*TabStrip*') {
                return @{ El = $child; Depth = $item.Depth + 1 }
            }
            if ($cn -ne 'Chrome_RenderWidgetHostHWND') {
                $queue.Enqueue(@{ El = $child; Depth = $item.Depth + 1 })
            }
            try { $child = $walker.GetNextSibling($child) } catch { $child = $null }
        }
    }
    return $null
}

$windows = @($AE::RootElement.FindAll($TS::Children, (New-Cond $AE::ClassNameProperty "Chrome_WidgetWin_1")))

"Top-level Chrome_WidgetWin_1 windows: $($windows.Count)"
""

$n = 0
foreach ($w in $windows) {
    $n++
    $name = ""
    try { $name = $w.Current.Name } catch { }
    $isEdge = $name -like "*Microsoft*Edge"

    "==================== window $n"
    "  Name      : $name"
    "  Edge?     : $isEdge"
    if (-not $name) { "  (no title - skipping)"; ""; continue }

    $found = Find-TabStrip $w
    if ($found) {
        "  Strip     : FOUND at depth $($found.Depth)"
        "     class  : $($found.El.Current.ClassName)"
        "     name   : $($found.El.Current.Name)"
        "     type   : $($found.El.Current.ControlType.ProgrammaticName)"

        $stripTabs = @($found.El.FindAll($TS::Descendants, $tabItemCond))
        "     TabItems under strip: $($stripTabs.Count)"
        foreach ($t in $stripTabs) {
            "        [$($t.Current.ClassName)]  $($t.Current.Name)"
        }
    } else {
        "  Strip     : NOT FOUND"
    }

    $allTabs = @($w.FindAll($TS::Descendants, $tabItemCond))
    "  All TabItems anywhere in window: $($allTabs.Count)"
    $i = 0
    foreach ($t in $allTabs) {
        $i++
        if ($i -gt 40) { "        ... truncated"; break }
        "        [$($t.Current.ClassName)]  $($t.Current.Name)"
    }
    ""
}

Read-Host "Press Enter to close"
