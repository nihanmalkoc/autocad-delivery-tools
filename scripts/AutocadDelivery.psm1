# AutocadDelivery - batch tools for AutoCAD drawing delivery sets, driven by accoreconsole.
# Windows PowerShell 5.1 compatible. See README.md for the workflow.

$script:LispDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'lisp'

#region Configuration and helpers

function Get-DeliveryConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = (Resolve-Path -LiteralPath $Path).Path
    $cfg = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $cfg.projectRoot = $cfg.projectRoot.TrimEnd('\')
    $cfg | Add-Member -NotePropertyName PlotRoot -NotePropertyValue (Join-Path $cfg.projectRoot $cfg.plotFolder) -Force
    $cfg | Add-Member -NotePropertyName BaseRoot -NotePropertyValue (Join-Path $cfg.projectRoot $cfg.baseFolder) -Force
    $cfg
}

function ConvertTo-Map($Object) {
    $h = [ordered]@{}
    if ($null -ne $Object) { foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    $h
}

function ConvertTo-LispString([string]$Text) { '"' + $Text.Replace('\', '\\').Replace('"', '\"') + '"' }

function ConvertTo-LispPath([string]$Path) { '"' + $Path.Replace('\', '/') + '"' }

function Test-PathSegment([string[]]$Segments, [string[]]$Patterns) {
    foreach ($s in $Segments) { foreach ($p in $Patterns) { if ($s -like $p) { return $true } } }
    $false
}

# Builds an accoreconsole script: common.lsp + the named LISP files inlined line by line, then the call.
# Inlining avoids (load ...), which SECURELOAD blocks for untrusted folders; one line per source line
# avoids the command line length limit.
function New-AccoreScript([string[]]$Lisp, [string]$Call) {
    $lines = foreach ($n in (@('common') + $Lisp)) {
        Get-Content -LiteralPath (Join-Path $script:LispDir "$n.lsp") |
            Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith(';') }
    }
    ((@($lines) + $Call + 'QUIT' + 'Y') -join "`r`n") + "`r`n"
}

function Read-AccoreLog([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    ([IO.File]::ReadAllText($Path)) -replace "`0", ''
}

#endregion

#region Batch runner

function Wait-AccoreSlot($Running, [int]$HangMinutes) {
    Start-Sleep -Milliseconds 300
    for ($k = $Running.Count - 1; $k -ge 0; $k--) {
        $j = $Running[$k]
        if ($j.Process.HasExited) { $Running.RemoveAt($k); continue }
        if (((Get-Date) - $j.Started).TotalMinutes -gt $HangMinutes) {
            try { $j.Process.Kill() } catch { }
            $j.Status = 'Hung'
            $Running.RemoveAt($k)
        }
    }
}

function Invoke-AccoreBatch {
    <#
    .SYNOPSIS
    Runs one accoreconsole script against many drawings in parallel.
    .DESCRIPTION
    {OUT} in the script is replaced by a per-drawing output file that the LISP writes to.
    Drawings with a .dwl lock file (open in AutoCAD) are skipped as Locked. Processes running
    longer than HangMinutes are killed and reported as Hung.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][string]$Script,
        [string]$WorkDir,
        [int]$Parallel = 0,
        [int]$HangMinutes = 0
    )
    if ($Parallel -lt 1) { $Parallel = [Math]::Max(1, [int]$Config.parallel) }
    if ($HangMinutes -lt 1) { $HangMinutes = [Math]::Max(1, [int]$Config.hangTimeoutMinutes) }
    if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP ('adt_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')) }
    [void][IO.Directory]::CreateDirectory($WorkDir)
    $exe = $Config.accoreconsole
    if (-not (Test-Path -LiteralPath $exe)) { throw "accoreconsole not found: $exe" }

    $jobs = New-Object System.Collections.Generic.List[object]
    $running = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($f in $Files) {
        $i++
        $id = '{0:D4}' -f $i
        $job = [pscustomobject]@{
            File = $f; Status = 'Pending'; Process = $null; Started = $null
            Out = (Join-Path $WorkDir "$id.txt"); Log = (Join-Path $WorkDir "$id.log")
        }
        $jobs.Add($job)
        if (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($f, '.dwl'))) { $job.Status = 'Locked'; continue }
        $scr = Join-Path $WorkDir "$id.scr"
        [IO.File]::WriteAllText($scr, $Script.Replace('{OUT}', $job.Out.Replace('\', '/')), [Text.Encoding]::Default)
        while ($running.Count -ge $Parallel) { Wait-AccoreSlot $running $HangMinutes }
        $job.Process = Start-Process -FilePath $exe -ArgumentList "/i `"$f`" /s `"$scr`" /l en-US" -NoNewWindow -PassThru -RedirectStandardOutput $job.Log
        $job.Started = Get-Date
        $job.Status = 'Running'
        $running.Add($job)
        Write-Progress -Activity 'accoreconsole' -Status "$i / $($Files.Count)" -PercentComplete (100 * $i / [Math]::Max(1, $Files.Count))
    }
    while ($running.Count -gt 0) { Wait-AccoreSlot $running $HangMinutes }
    Write-Progress -Activity 'accoreconsole' -Completed

    foreach ($job in $jobs) {
        $out = $null
        if (Test-Path -LiteralPath $job.Out) { $out = @(Get-Content -LiteralPath $job.Out -Encoding Default) }
        if ($job.Status -eq 'Running') { if ($null -ne $out) { $job.Status = 'Done' } else { $job.Status = 'NoOutput' } }
        [pscustomobject]@{ File = $job.File; Status = $job.Status; Output = $out; Log = $job.Log }
    }
}

#endregion

#region File discovery and reports

function Get-DeliveryFiles {
    <# Set drawings under the plot folder; delivery output folders (DWG, PDF) are ignored. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [string[]]$Package)
    Get-ChildItem -LiteralPath $Config.PlotRoot -Recurse -Filter *.dwg | Where-Object {
        $parts = $_.FullName.Substring($Config.PlotRoot.Length + 1) -split '\\'
        $dirs = @($parts | Select-Object -First ($parts.Count - 1))
        (-not (Test-PathSegment $dirs @($Config.outputFolders))) -and ((-not $Package) -or ($Package -contains $parts[0]))
    } | ForEach-Object FullName
}

function Get-XrefReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string[]]$Files, [string]$OutCsv)
    $res = Invoke-AccoreBatch -Config $Config -Files $Files -Script (New-AccoreScript 'xref-report' '(xref-report "{OUT}")')
    $rows = foreach ($r in $res) {
        $lines = @($r.Output | Where-Object { $_ })
        if (-not $lines.Count) {
            [pscustomobject]@{ File = $r.File; Status = $r.Status; Xref = ''; Flags = ''; Path = ''; Placement = ''; Point = ''; Scale = ''; Rotation = ''; Layer = ''; Layout = ''; Overlay = ''; Resolved = '' }
            continue
        }
        foreach ($l in $lines) {
            $a = $l -split '\|'
            $fl = [int]$a[1]
            [pscustomobject]@{
                File = $r.File; Status = $r.Status; Xref = $a[0]; Flags = $fl; Path = $a[2]; Placement = $a[3]
                Point = $a[4]; Scale = $a[5]; Rotation = $a[6]; Layer = $a[7]; Layout = $a[8]
                Overlay = [bool]($fl -band 8); Resolved = [bool]($fl -band 32)
            }
        }
    }
    if ($OutCsv) { $rows | Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Encoding UTF8 }
    $rows
}

function Get-LayoutReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string[]]$Files, [string]$OutCsv)
    $res = Invoke-AccoreBatch -Config $Config -Files $Files -Script (New-AccoreScript 'layout-report' '(layout-report "{OUT}")')
    $rows = foreach ($r in $res) {
        $lines = @($r.Output | Where-Object { $_ })
        if (-not $lines.Count) { [pscustomobject]@{ File = $r.File; Status = $r.Status; Layout = '' }; continue }
        foreach ($l in $lines) { [pscustomobject]@{ File = $r.File; Status = $r.Status; Layout = $l } }
    }
    if ($OutCsv) { $rows | Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Encoding UTF8 }
    $rows
}

function Get-TitleBlockReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string[]]$Files, [string]$OutCsv)
    $call = '(titleblock-report ' + (ConvertTo-LispString $Config.titleBlock.block) + ' "{OUT}")'
    $res = Invoke-AccoreBatch -Config $Config -Files $Files -Script (New-AccoreScript 'titleblock-report' $call)
    $rows = foreach ($r in $res) {
        $layout = ''
        foreach ($l in @($r.Output | Where-Object { $_ })) {
            $a = $l -split '\|', 4
            if ($a[0] -eq 'BLOCK') { $layout = $a[1] }
            elseif ($a[0] -eq 'ATT') { [pscustomobject]@{ File = $r.File; Status = $r.Status; Layout = $layout; Tag = $a[1]; Value = $a[3]; Kind = $a[2] } }
            else { [pscustomobject]@{ File = $r.File; Status = $a[0]; Layout = ''; Tag = ''; Value = ''; Kind = '' } }
        }
    }
    if ($OutCsv) { $rows | Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Encoding UTF8 }
    $rows
}

function Get-BaseIndex {
    <# Base drawings keyed "building|level|type|location" -> full path (first hit wins). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $re = [regex]$Config.naming.baseFileRegex
    $locs = ConvertTo-Map $Config.baseLocations
    $idx = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $Config.BaseRoot -Recurse -Filter *.dwg)) {
        $parts = $f.FullName.Substring($Config.BaseRoot.Length + 1) -split '\\'
        $dirs = @($parts | Select-Object -First ($parts.Count - 1))
        if (Test-PathSegment $dirs @($Config.excludeFolders)) { continue }
        $m = $re.Match($f.Name)
        if (-not $m.Success) { continue }
        $loc = $null
        foreach ($k in $locs.Keys) { if ($dirs -contains $locs[$k]) { $loc = $k; break } }
        if (-not $loc) { continue }
        $key = '{0}|{1}|{2}|{3}' -f $m.Groups['building'].Value, $m.Groups['level'].Value, $m.Groups['type'].Value, $loc
        if (-not $idx.ContainsKey($key)) { $idx[$key] = $f.FullName }
    }
    $idx
}

#endregion

#region Delivery set rules

function New-SetPlan {
    <#
    .SYNOPSIS
    Compares every set drawing with its package rule and writes the ops that make it match.
    .DESCRIPTION
    Xrefs not in the rule (or pointing to another building/level) are detached, missing base
    drawings are attached, duplicate inserts are removed and draw order rules are queued.
    Xrefs matching naming.keepXrefRegex (the sheet border) are never touched.
    Only drawings named with the xref prefix and fully read by Get-XrefReport (Status Done) are planned.
    Draw order ops are added only to drawings that change, unless -ForceDrawOrder is given.
    Returns one summary row per drawing; the plan is applied with Invoke-SetPlan.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$XrefReport, [Parameter(Mandatory)][string]$PlanFile, [switch]$ForceDrawOrder)
    $idx = Get-BaseIndex -Config $Config
    $rules = ConvertTo-Map $Config.packages
    $alts = ConvertTo-Map $Config.typeAlternatives
    $locs = ConvertTo-Map $Config.baseLocations
    $defLoc = $Config.defaultBaseLocation
    $setRe = [regex]$Config.naming.setFileRegex
    $baseRe = [regex]$Config.naming.baseFileRegex
    $keepRe = $Config.naming.keepXrefRegex
    $plan = New-Object System.Collections.Generic.List[string]

    $summary = foreach ($g in ($XrefReport | Group-Object File)) {
        $f = $g.Name
        $pkg = ($f.Substring($Config.PlotRoot.Length + 1) -split '\\')[0]
        if (-not $rules.Contains($pkg)) { continue }
        $name = [IO.Path]::GetFileName($f)
        if ($Config.naming.xrefPrefix -and -not $name.StartsWith($Config.naming.xrefPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (@($g.Group | Where-Object { $_.Status -ne 'Done' }).Count) {
            Write-Warning "Not planned, report incomplete ($($g.Group[0].Status)): $f"
            continue
        }
        $m = $setRe.Match($name)
        if (-not $m.Success) { continue }
        $bld = $m.Groups['building'].Value
        $lvl = $m.Groups['level'].Value
        $up = '..\' * (($f.Substring($Config.projectRoot.Length + 1) -split '\\').Count - 1)

        $want = [ordered]@{}
        $missing = @()
        foreach ($tok in @($rules[$pkg].xrefs)) {
            $loc = $defLoc; $type = $tok
            if ($tok -match '^(\w+):(.+)$') { $loc = $matches[1]; $type = $matches[2] }
            $cands = @($type)
            if ($alts.Contains($type)) { $cands = @($alts[$type]) }
            $hit = $null
            foreach ($c in $cands) {
                if ($idx.ContainsKey("$bld|$lvl|$c|$loc")) { $hit = [pscustomobject]@{ Key = "$loc|$c"; Path = $idx["$bld|$lvl|$c|$loc"] }; break }
            }
            if ($hit) { $want[$tok] = $hit }
            elseif (@($rules[$pkg].optional) -notcontains $tok) { $missing += $tok }
        }
        $byKey = @{}
        foreach ($t in $want.Keys) { $byKey[$want[$t].Key] = $t }

        $det = @(); $dup = @(); $keep = @{}
        foreach ($r in ($g.Group | Where-Object { $_.Xref -and $_.Placement -eq 'INS' })) {
            if ($keepRe -and $r.Path -match $keepRe) { continue }
            $tok = $null
            $pm = $baseRe.Match([IO.Path]::GetFileName($r.Path))
            if ($pm.Success -and $pm.Groups['building'].Value -eq $bld -and $pm.Groups['level'].Value -eq $lvl) {
                $loc = $defLoc
                foreach ($k in $locs.Keys) { if ($k -ne $defLoc -and $r.Path -like ('*\' + $locs[$k] + '\*')) { $loc = $k } }
                $key = "$loc|$($pm.Groups['type'].Value)"
                if ($byKey.ContainsKey($key)) { $tok = $byKey[$key] }
            }
            if (-not $tok) { if ($det -notcontains $r.Xref) { $det += $r.Xref }; continue }
            if ($keep.ContainsKey($tok)) {
                if ($keep[$tok] -eq $r.Xref) { if ($dup -notcontains $r.Xref) { $dup += $r.Xref } }
                elseif ($det -notcontains $r.Xref) { $det += $r.Xref }
                continue
            }
            $keep[$tok] = $r.Xref
        }
        $att = @($want.Keys | Where-Object { -not $keep.ContainsKey($_) })

        foreach ($n in $det) { $plan.Add("$f|DET|$n") }
        foreach ($n in $dup) { $plan.Add("$f|DUP|$n") }
        foreach ($t in $att) { $plan.Add("$f|ATT|" + $up + $want[$t].Path.Substring($Config.projectRoot.Length + 1)) }
        if ($ForceDrawOrder -or $det.Count -or $dup.Count -or $att.Count) {
            foreach ($d in @($Config.drawOrder)) {
                $refs = @($d.above | Where-Object { $want.Contains($_) })
                if ($want.Contains($d.top) -and $refs.Count) { $plan.Add("$f|DRAW|$($d.top)|$($refs -join ',')") }
            }
        }
        [pscustomobject]@{
            File = $f; Package = $pkg; Building = $bld; Level = $lvl
            Detach = ($det -join ', '); Duplicate = ($dup -join ', '); Attach = ($att -join ', ')
            Final = (@($want.Keys) -join ', '); MissingInBase = ($missing -join ', ')
        }
    }
    [IO.File]::WriteAllLines($PlanFile, [string[]]@($plan), [Text.Encoding]::Default)
    $summary
}

function New-RepathPlan {
    <#
    .SYNOPSIS
    Plan that repoints every xref whose saved path matches Pattern (regex -replace with Replacement).
    The xref is renamed to the new file name. Apply with Invoke-SetPlan.
    .EXAMPLE
    New-RepathPlan -XrefReport $rep -Pattern '_PRE_Lay_' -Replacement '_APP_Lay_' -PlanFile plan.txt
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$XrefReport, [Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Replacement, [Parameter(Mandatory)][string]$PlanFile)
    $lines = foreach ($r in ($XrefReport | Where-Object { $_.Xref -and $_.Path -match $Pattern } | Sort-Object File, Xref -Unique)) {
        $np = $r.Path -replace $Pattern, $Replacement
        "$($r.File)|PATH|$($r.Xref)|$np|$([IO.Path]::GetFileNameWithoutExtension($np))"
    }
    [IO.File]::WriteAllLines($PlanFile, [string[]]@($lines), [Text.Encoding]::Default)
    @($lines).Count
}

function Invoke-SetPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$PlanFile)
    $files = @(Get-Content -LiteralPath $PlanFile -Encoding Default | Where-Object { $_ } | ForEach-Object { ($_ -split '\|')[0] } | Select-Object -Unique)
    if (-not $files.Count) { return }
    $call = '(set-fix ' + (ConvertTo-LispPath (Resolve-Path -LiteralPath $PlanFile).Path) + ' "{OUT}")'
    foreach ($r in (Invoke-AccoreBatch -Config $Config -Files $files -Script (New-AccoreScript 'set-fix' $call))) {
        [pscustomobject]@{ File = $r.File; Status = $r.Status; Result = (@($r.Output) -join '; ') }
    }
}

function Set-LayoutNames {
    <# Renames each drawing's single layout to its file name without the xref prefix. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string[]]$Files)
    $call = '(layout-rename ' + (ConvertTo-LispString $Config.naming.xrefPrefix) + ' "{OUT}")'
    foreach ($r in (Invoke-AccoreBatch -Config $Config -Files $Files -Script (New-AccoreScript 'layout-rename' $call))) {
        [pscustomobject]@{ File = $r.File; Status = $r.Status; Result = (@($r.Output) -join '; ') }
    }
}

function Test-DrawOrder {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string[]]$Files)
    foreach ($d in @($Config.drawOrder)) {
        $call = '(draworder-check ' + (ConvertTo-LispString $d.top) + ' ' + (ConvertTo-LispString (@($d.above) -join ',')) + ' "{OUT}")'
        foreach ($r in (Invoke-AccoreBatch -Config $Config -Files $Files -Script (New-AccoreScript 'draworder-check' $call))) {
            [pscustomobject]@{ File = $r.File; Rule = "$($d.top) above $(@($d.above) -join ',')"; Status = $r.Status; Result = (@($r.Output) -join '; ') }
        }
    }
}

#endregion

#region Title block and bind export

function Update-TitleBlock {
    <#
    .SYNOPSIS
    Sets the date and/or revision attributes of the title block in every drawing.
    .EXAMPLE
    Update-TitleBlock -Config $cfg -Files $sets -Date '30.07.2026' -Revision '00_0'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string[]]$Files, [string]$Date, [string]$Revision, [hashtable]$Values)
    $v = @{}
    if ($Values) { foreach ($k in $Values.Keys) { $v[$k.ToUpper()] = [string]$Values[$k] } }
    if ($Date) {
        [void][datetime]::ParseExact($Date, $Config.titleBlock.dateFormat, [Globalization.CultureInfo]::InvariantCulture)
        $v[$Config.titleBlock.dateTag.ToUpper()] = $Date
    }
    if ($Revision) { $v[$Config.titleBlock.revisionTag.ToUpper()] = $Revision }
    if (-not $v.Count) { throw 'Nothing to update: give -Date, -Revision or -Values.' }
    $pairs = ($v.Keys | ForEach-Object { '(' + (ConvertTo-LispString $_) + ' . ' + (ConvertTo-LispString $v[$_]) + ')' }) -join ' '
    $call = '(titleblock-update ' + (ConvertTo-LispString $Config.titleBlock.block) + " '(" + $pairs + ') "{OUT}")'
    foreach ($r in (Invoke-AccoreBatch -Config $Config -Files $Files -Script (New-AccoreScript 'titleblock-update' $call))) {
        [pscustomobject]@{ File = $r.File; Status = $r.Status; Result = (@($r.Output) -join '; ') }
    }
}

function Export-BoundSets {
    <#
    .SYNOPSIS
    Binds every set drawing and saves it as <set folder>\<bindOutputFolder>\<yyyyMMdd>\<name without prefix>.
    .DESCRIPTION
    The date (in titleBlock.dateFormat) gives the folder name. Set drawings are not modified.
    Existing outputs are never overwritten. A drawing is only saved when every xref could be bound;
    otherwise the failing xrefs are reported. Drawings without the title block are skipped unless
    -AllowNoTitleBlock is given. -OutputRoot writes the same folder tree somewhere else (for tests).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][string]$Date,
        [string]$OutputRoot,
        [switch]$AllowNoTitleBlock
    )
    $d = [datetime]::ParseExact($Date, $Config.titleBlock.dateFormat, [Globalization.CultureInfo]::InvariantCulture)
    $folder = $d.ToString('yyyyMMdd')
    $prefix = [string]$Config.naming.xrefPrefix
    $created = @()
    $plan = foreach ($f in $Files) {
        $name = [IO.Path]::GetFileName($f)
        if ($prefix -and -not $name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $setDir = Split-Path $f
        if ($OutputRoot) { $setDir = Join-Path $OutputRoot $setDir.Substring($Config.projectRoot.Length + 1) }
        $dir = Join-Path (Join-Path $setDir $Config.bindOutputFolder) $folder
        if (-not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir); $created += $dir }
        "$f|" + (Join-Path $dir $name.Substring($prefix.Length)).Replace('\', '/')
    }
    $planFile = Join-Path $env:TEMP ('adt_bind_' + $folder + '_' + (Get-Date -Format 'HHmmss') + '.txt')
    [IO.File]::WriteAllLines($planFile, [string[]]@($plan), [Text.Encoding]::Default)
    $blk = ''
    if (-not $AllowNoTitleBlock) { $blk = [string]$Config.titleBlock.block }
    $call = '(bind-export ' + (ConvertTo-LispPath $planFile) + ' ' + (ConvertTo-LispString $blk) + ' "{OUT}")'
    $files2 = @($plan | ForEach-Object { ($_ -split '\|')[0] })
    $res = foreach ($r in (Invoke-AccoreBatch -Config $Config -Files $files2 -Script (New-AccoreScript 'bind-export' $call))) {
        $out = @($r.Output)
        [pscustomobject]@{
            File = $r.File; Status = $r.Status; Saved = [bool]($out -contains 'SAVED|OK')
            Target = (($plan | Where-Object { ($_ -split '\|')[0] -eq $r.File } | Select-Object -First 1) -split '\|')[1]
            Problems = (@($out | Where-Object { $_ -match '^(UNRESOLVED|BINDFAILED|NOTSAVED|NOTITLEBLOCK|EXISTS|NOPLAN)' }) -join '; ')
        }
    }
    foreach ($c in $created) {
        if (-not (Get-ChildItem -LiteralPath $c -Force | Select-Object -First 1)) { [IO.Directory]::Delete($c) }
    }
    $res
}

#endregion

#region Excel reports (needs Microsoft Excel)

function New-XlBook {
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false; $xl.ScreenUpdating = $false
    $wb = $xl.Workbooks.Add()
    while ($wb.Worksheets.Count -gt 1) { $wb.Worksheets.Item($wb.Worksheets.Count).Delete() }
    @($xl, $wb)
}

function Add-XlSheet($Wb, [string]$Name, [bool]$First) {
    if ($First) { $ws = $Wb.Worksheets.Item(1) } else { $ws = $Wb.Worksheets.Add([Type]::Missing, $Wb.Worksheets.Item($Wb.Worksheets.Count)) }
    $ws.Name = $Name
    $ws.Cells.Font.Name = 'Arial'; $ws.Cells.Font.Size = 10; $ws.Cells.VerticalAlignment = -4160
    $ws
}

function Write-XlTable($Ws, [int]$Row, [int]$Col, $Rows) {
    $n = $Rows.Count
    $m = ($Rows | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
    $arr = New-Object 'object[,]' $n, $m
    for ($i = 0; $i -lt $n; $i++) { for ($j = 0; $j -lt $Rows[$i].Count; $j++) { if ($null -ne $Rows[$i][$j]) { $arr[$i, $j] = [string]$Rows[$i][$j] } } }
    $rg = $Ws.Range($Ws.Cells.Item($Row, $Col), $Ws.Cells.Item($Row + $n - 1, $Col + $m - 1))
    $rg.NumberFormat = '@'
    $rg.Value2 = $arr
    $rg.Borders.LineStyle = 1; $rg.Borders.Color = 0xBFBFBF; $rg.WrapText = $true
    $h = $Ws.Range($Ws.Cells.Item($Row, $Col), $Ws.Cells.Item($Row, $Col + $m - 1))
    $h.Font.Bold = $true; $h.Font.Color = 0xFFFFFF; $h.Interior.Color = 0x5A3A1F; $h.VerticalAlignment = -4108
    , $rg
}

function Set-XlTitle($Ws, [string]$Title, [string]$Sub) {
    $Ws.Cells.Item(1, 1).Value2 = $Title; $Ws.Cells.Item(1, 1).Font.Size = 14; $Ws.Cells.Item(1, 1).Font.Bold = $true
    if ($Sub) { $Ws.Cells.Item(2, 1).Value2 = $Sub; $Ws.Cells.Item(2, 1).Font.Italic = $true; $Ws.Cells.Item(2, 1).Font.Color = 0x595959 }
}

function Save-XlBook($Xl, $Wb, [string]$Path) {
    foreach ($s in $Wb.Worksheets) { [void]$s.Activate(); $Xl.ActiveWindow.DisplayGridlines = $false }
    [void]$Wb.Worksheets.Item(1).Activate()
    $Xl.Calculate()
    $Wb.SaveAs($Path, 51)
    $Wb.Close($false); $Xl.Quit()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Wb); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Xl)
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}

function New-RulesWorkbook {
    <# Writes the delivery rules from the config as a workbook to share with the team. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Path)
    $dot = [string][char]0x25CF
    $xl, $wb = New-XlBook

    $ws = Add-XlSheet $wb 'Set contents' $true
    Set-XlTitle $ws 'Base drawings referenced by each delivery set' "$dot = referenced. A base drawing that does not exist for a building/level is skipped."
    $cols = @($Config.reportColumns)
    $rows = @(, (@('Package', 'Own drawing') + $cols + @('Notes')))
    $rules = ConvertTo-Map $Config.packages
    foreach ($p in $rules.Keys) {
        $r = $rules[$p]
        $row = @($p, [string]$r.own)
        foreach ($c in $cols) {
            $mark = ''
            foreach ($tok in @($r.xrefs)) {
                if ($tok -eq $c) { $mark = $dot; if (@($r.optional) -contains $tok) { $mark = "$dot (if any)" } }
            }
            $row += $mark
        }
        $rows += , ($row + @([string]$r.notes))
    }
    [void](Write-XlTable $ws 4 1 $rows)
    $ws.Columns.Item(1).ColumnWidth = 12; $ws.Columns.Item(2).ColumnWidth = 14
    for ($j = 3; $j -le $cols.Count + 2; $j++) { $ws.Columns.Item($j).ColumnWidth = 7; $ws.Columns.Item($j).HorizontalAlignment = -4108 }
    $ws.Columns.Item($cols.Count + 3).ColumnWidth = 70

    $ws = Add-XlSheet $wb 'Conventions' $false
    Set-XlTitle $ws 'Folder, naming and xref conventions' ''
    $rows = @(, @('Topic', 'Rule'))
    $rows += , @('Plot folder', "$($Config.plotFolder)\<package>\<building>\  (grouped buildings: <package>\<group>\<building>\)")
    $rows += , @('Delivery outputs', "$(@($Config.outputFolders) -join ' and ') folders next to each set; bound drawings go to $($Config.bindOutputFolder)\<yyyyMMdd>\")
    $rows += , @('Base drawings', "$($Config.baseFolder)\<building>\<location>\<level folder>\  locations: " + ((ConvertTo-Map $Config.baseLocations).Values -join ', '))
    foreach ($e in (ConvertTo-Map $Config.naming.examples).GetEnumerator()) { $rows += , @($e.Key, $e.Value) }
    $rows += , @('Layout name', 'Set file name without the xref prefix and extension; one layout per set drawing.')
    $rows += , @('Xref type', 'Placement: model space, 0,0,0, scale 1, rotation 0, layer 0, relative path. New xrefs are attached as overlay.')
    foreach ($d in @($Config.drawOrder)) { $rows += , @('Draw order', "$($d.top) above $(@($d.above) -join ' and ')") }
    foreach ($e in (ConvertTo-Map $Config.typeAlternatives).GetEnumerator()) { $rows += , @("Preferred $($e.Key)", "First existing of: $(@($e.Value) -join ', ')") }
    $rows += , @('Title block', "Block $($Config.titleBlock.block): $($Config.titleBlock.dateTag) ($($Config.titleBlock.dateFormat)) and $($Config.titleBlock.revisionTag) are set before binding.")
    [void](Write-XlTable $ws 4 1 $rows)
    $ws.Columns.Item(1).ColumnWidth = 24; $ws.Columns.Item(2).ColumnWidth = 110

    $ws = Add-XlSheet $wb 'Levels' $false
    Set-XlTitle $ws 'Level codes' 'Level code in file names and the base drawing folder it lives in'
    $rows = @(, @('Code in file name', 'Base folder'))
    foreach ($e in (ConvertTo-Map $Config.levelFolders).GetEnumerator()) { $rows += , @($e.Key, $e.Value) }
    [void](Write-XlTable $ws 4 1 $rows)
    $ws.Columns.Item(1).ColumnWidth = 20; $ws.Columns.Item(2).ColumnWidth = 16

    Save-XlBook $xl $wb $Path
}

function New-StatusWorkbook {
    <# Building x package overview, drawing list and base drawing inventory from the reports. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$XrefReport, [Parameter(Mandatory)]$LayoutReport, [Parameter(Mandatory)][string]$Path)
    $dot = [string][char]0x25CF
    $setRe = [regex]$Config.naming.setFileRegex
    $baseRe = [regex]$Config.naming.baseFileRegex
    $keepRe = $Config.naming.keepXrefRegex
    $lvlOrder = @{}; $i = 0
    foreach ($k in (ConvertTo-Map $Config.levelFolders).Keys) { $lvlOrder[$k] = $i++ }
    $packages = @(Get-ChildItem -LiteralPath $Config.PlotRoot -Directory | ForEach-Object Name | Sort-Object)
    $xr = $XrefReport | Group-Object File -AsHashTable -AsString
    $lay = $LayoutReport | Group-Object File -AsHashTable -AsString

    $files = foreach ($f in ($XrefReport | ForEach-Object File | Select-Object -Unique)) {
        $m = $setRe.Match([IO.Path]::GetFileName($f))
        $types = @(); $sheet = ''
        foreach ($r in @($xr[$f])) {
            if (-not $r.Xref) { continue }
            if ($keepRe -and $r.Path -match $keepRe) { $sheet = [IO.Path]::GetFileNameWithoutExtension($r.Path); continue }
            $pm = $baseRe.Match([IO.Path]::GetFileName($r.Path))
            if ($pm.Success) { $types += $pm.Groups['type'].Value } else { $types += [IO.Path]::GetFileName($r.Path) }
        }
        [pscustomobject]@{
            Package = ($f.Substring($Config.PlotRoot.Length + 1) -split '\\')[0]
            Building = $(if ($m.Success) { $m.Groups['building'].Value } else { '' })
            Level = $(if ($m.Success) { $m.Groups['level'].Value } else { '' })
            Name = [IO.Path]::GetFileName($f)
            Layout = ((@($lay[$f]) | Where-Object { $_.Layout } | ForEach-Object Layout) -join ', ')
            Sheet = $sheet; Xrefs = (($types | Sort-Object -Unique) -join ', ')
        }
    }
    $files = @($files | Sort-Object Package, Building, @{ e = { $lvlOrder[$_.Level] } }, Name)
    $blds = @($files | Where-Object { $_.Building } | ForEach-Object Building | Sort-Object -Unique)

    $xl, $wb = New-XlBook
    $ws = Add-XlSheet $wb 'Building x Package' $true
    Set-XlTitle $ws 'Delivery sets per building and package' 'Each cell lists the levels that have a set drawing. Counts are formulas.'
    $rows = @(, (@('Building') + $packages + @('Packages with sets')))
    foreach ($b in $blds) {
        $row = @($b)
        foreach ($p in $packages) {
            $row += ((@($files | Where-Object { $_.Package -eq $p -and $_.Building -eq $b } | ForEach-Object Level) | Sort-Object { $lvlOrder[$_] } -Unique) -join ', ')
        }
        $rows += , $row
    }
    [void](Write-XlTable $ws 4 1 $rows)
    $nc = $packages.Count + 1; $last = 4 + $blds.Count
    $ws.Range($ws.Cells.Item(4, 2), $ws.Cells.Item(4, $nc)).Orientation = 90
    $ws.Rows.Item(4).RowHeight = 70
    for ($r = 5; $r -le $last; $r++) {
        $c = $ws.Cells.Item($r, $nc + 1); $c.NumberFormat = 'General'
        $c.Formula = '=COUNTIF(' + $ws.Cells.Item($r, 2).Address($false, $false) + ':' + $ws.Cells.Item($r, $nc).Address($false, $false) + ',"?*")'
    }
    $ws.Cells.Item($last + 1, 1).Value2 = 'Buildings with sets'
    for ($j = 2; $j -le $nc; $j++) {
        $c = $ws.Cells.Item($last + 1, $j); $c.NumberFormat = 'General'
        $c.Formula = '=COUNTIF(' + $ws.Cells.Item(5, $j).Address($false, $false) + ':' + $ws.Cells.Item($last, $j).Address($false, $false) + ',"?*")'
    }
    $ws.Range($ws.Cells.Item($last + 1, 1), $ws.Cells.Item($last + 1, $nc)).Font.Bold = $true
    $ws.Columns.Item(1).ColumnWidth = 18
    for ($j = 2; $j -le $nc; $j++) { $ws.Columns.Item($j).ColumnWidth = 8; $ws.Columns.Item($j).HorizontalAlignment = -4108 }
    $ws.Columns.Item($nc + 1).ColumnWidth = 14; $ws.Columns.Item($nc + 1).HorizontalAlignment = -4108

    $ws = Add-XlSheet $wb 'Drawing list' $false
    Set-XlTitle $ws 'Set drawings' '"Layout = file name" is a formula: the layout must equal the file name without prefix and extension.'
    $rows = @(, @('Package', 'Building', 'Level', 'File name', 'Layout', 'Layout = file name', 'Sheet xref', 'Base drawings'))
    foreach ($f in $files) { $rows += , @($f.Package, $f.Building, $f.Level, $f.Name, $f.Layout, '', $f.Sheet, $f.Xrefs) }
    [void](Write-XlTable $ws 4 1 $rows)
    $lastL = 4 + $files.Count
    $fc = $ws.Range("F5:F$lastL"); $fc.NumberFormat = 'General'
    $pre = [string]$Config.naming.xrefPrefix
    $fc.Formula = '=IF(E5="","-",IF(E5=SUBSTITUTE(SUBSTITUTE(D5,".dwg",""),"' + $pre + '","",1),"Yes","No"))'
    [void]$ws.Range("A4:H$lastL").AutoFilter()
    $ws.Range("A5:H$lastL").WrapText = $false
    $w = @(11, 9, 7, 50, 46, 12, 22, 50); for ($j = 0; $j -lt $w.Count; $j++) { $ws.Columns.Item($j + 1).ColumnWidth = $w[$j] }

    $ws = Add-XlSheet $wb 'Base drawings' $false
    Set-XlTitle $ws 'Base drawing inventory (building x level)' "$dot = exists. Location-prefixed columns (e.g. ID:FFE) come from that base location."
    $idx = Get-BaseIndex -Config $Config
    $alts = ConvertTo-Map $Config.typeAlternatives
    $cols = @($Config.reportColumns)
    if ($Config.extraInventoryColumns) { $cols += @($Config.extraInventoryColumns) }
    $keys = @($idx.Keys | ForEach-Object { $k = $_ -split '\|'; "$($k[0])|$($k[1])" } | Sort-Object -Unique | Sort-Object { ($_ -split '\|')[0] }, { $lvlOrder[($_ -split '\|')[1]] })
    $rows = @(, (@('Building', 'Level') + $cols))
    foreach ($bl in $keys) {
        $b, $l = $bl -split '\|'
        $row = @($b, $l)
        foreach ($c in $cols) {
            $loc = $Config.defaultBaseLocation; $type = $c
            if ($c -match '^(\w+):(.+)$') { $loc = $matches[1]; $type = $matches[2] }
            $cands = @($type); if ($alts.Contains($type)) { $cands = @($alts[$type]) }
            $hit = @($cands | Where-Object { $idx.ContainsKey("$b|$l|$_|$loc") } | Select-Object -First 1)
            if ($hit.Count) { $row += $(if ($hit[0] -ne $type) { "$dot $($hit[0])" } else { $dot }) } else { $row += '' }
        }
        $rows += , $row
    }
    [void](Write-XlTable $ws 4 1 $rows)
    $ws.Columns.Item(1).ColumnWidth = 10; $ws.Columns.Item(2).ColumnWidth = 8
    for ($j = 3; $j -le $cols.Count + 2; $j++) { $ws.Columns.Item($j).ColumnWidth = 9; $ws.Columns.Item($j).HorizontalAlignment = -4108 }

    Save-XlBook $xl $wb $Path
}

#endregion

Export-ModuleMember -Function Get-DeliveryConfig, Invoke-AccoreBatch, Read-AccoreLog, Get-DeliveryFiles, Get-XrefReport,
    Get-LayoutReport, Get-TitleBlockReport, Get-BaseIndex, New-SetPlan, New-RepathPlan, Invoke-SetPlan, Set-LayoutNames,
    Test-DrawOrder, Update-TitleBlock, Export-BoundSets, New-RulesWorkbook, New-StatusWorkbook
