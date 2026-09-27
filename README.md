# autocad-delivery-tools

Batch tools for keeping AutoCAD drawing delivery sets consistent: which base drawings each sheet
references, how files, layouts and xrefs are named, title block date and revision, and bound
(xref-free) copies for delivery. Everything runs headless through AutoCAD's `accoreconsole.exe`,
driven from PowerShell. Hundreds of drawings take minutes instead of a day of clicking.

Rules live in one JSON config, so an office can agree on its conventions once and every project
applies them the same way.

## What it does

| Step | Function | Changes drawings? |
|---|---|---|
| List xrefs (name, path, overlay/attach, loaded, placement) | `Get-XrefReport` | no |
| List layouts / title block attributes | `Get-LayoutReport`, `Get-TitleBlockReport` | no |
| Compare each set with its package rule and plan fixes | `New-SetPlan` | no (writes a plan file) |
| Plan to repoint xrefs by path pattern (e.g. old sheet border → new) | `New-RepathPlan` | no (writes a plan file) |
| Apply a plan: detach, attach, repath, remove duplicates, draw order | `Invoke-SetPlan` | yes |
| Rename the layout to the file name | `Set-LayoutNames` | yes |
| Check draw order (e.g. DR above PLN and FAC) | `Test-DrawOrder` | no |
| Set title block date / revision | `Update-TitleBlock` | yes |
| Bind every xref and save a delivery copy in `DWG\<yyyyMMdd>\` | `Export-BoundSets` | no (writes new files only) |
| Share the rules / project status as Excel | `New-RulesWorkbook`, `New-StatusWorkbook` | no |

## Requirements

- Windows, PowerShell 5.1 (built in)
- AutoCAD 2024 or later (for `accoreconsole.exe`; tested with AutoCAD 2024)
- Microsoft Excel, only for the two workbook functions

## Folder conventions

The tools assume a layout like this (all names are configurable):

```
<projectRoot>\
  00_BC\                                 base drawings
    <building>\03_PLN\<level folder>\     XR_PRJ_<building>_<type>_<level>.dwg   (PLN, RM, DR, FAC, ...)
    <building>\20_ID-FFE\                 XR_PRJ_<building>_FFE_<level>.dwg      (interior FFE)
    <group>\03_PLN\<building>\<level>\    grouped buildings (e.g. two gatehouses of one type)
  03_PLOT_APP\                           delivery sets
    <package>\<building>\                 XR_..._<building>_<package>_<level>_00_0.dwg  (one sheet each)
      DWG\<yyyyMMdd>\                      bound delivery copies
      PDF\
  07_LAY\                                sheet border xrefs
```

A set drawing references base drawings as xrefs (overlay, 0,0,0, scale 1, relative path) and the
sheet border in paper space. The config says which base drawings each package references, e.g.
a plan set gets PLN, ST, FAC, RM, DIM, DR, FFE, WET and EXT; a ceiling plan only PLN, ST, FAC, RM, RCP.

## Setup

1. Download or clone this repository.
2. Copy `config.example.json` to `config.local.json` (ignored by git) and edit it:
   - `accoreconsole`, `projectRoot`, folder names
   - `naming`: regexes for set and base drawing names, xref prefix, sheet border pattern
   - `titleBlock`: block name and attribute tags
   - `packages`: the base drawings each package references (`"ID:FFE"` = type FFE from the `ID` base location)
   - `typeAlternatives`: preferred file for a type, e.g. `FFE_2` before `FFE`
   - `drawOrder`: e.g. `DR` above `PLN` and `FAC`
3. In PowerShell:

```powershell
Import-Module .\scripts\AutocadDelivery.psm1
$cfg  = Get-DeliveryConfig .\config.local.json
$sets = Get-DeliveryFiles -Config $cfg          # all set drawings (DWG/PDF output folders skipped)
```

## Typical runs

Check and fix the sets against the rules:

```powershell
$rep  = Get-XrefReport -Config $cfg -Files $sets -OutCsv .\out\xrefs.csv
$plan = New-SetPlan   -Config $cfg -XrefReport $rep -PlanFile .\out\plan.txt
$plan | Where-Object { $_.Detach -or $_.Attach } | Format-Table Package, Building, Level, Detach, Attach
Invoke-SetPlan -Config $cfg -PlanFile .\out\plan.txt      # after reviewing plan.txt
```

Repoint the sheet border from one version to another and rename the xref:

```powershell
New-RepathPlan -XrefReport $rep -Pattern '_PRE_Lay_' -Replacement '_APP_Lay_' -PlanFile .\out\border.txt
Invoke-SetPlan -Config $cfg -PlanFile .\out\border.txt
```

### Delivery (e.g. urgent re-issue)

```powershell
Update-TitleBlock -Config $cfg -Files $sets -Date '30.07.2026' -Revision '00_0'
$res = Export-BoundSets -Config $cfg -Files $sets -Date '30.07.2026'
$res | Where-Object { -not $_.Saved } | Format-Table File, Problems
```

`Export-BoundSets` opens each set, binds all xrefs and saves `<set folder>\DWG\20260730\<name without XR_>.dwg`.
The set drawing itself stays unbound. File name and sheet name in the title block are fields and
update on their own.

Timing measured on a real project (about 330 sets, 4 parallel processes, network share):
title block about 7.5 min, bind and save about 10 min, checking the failures about 10 min.

### Reports for the team

```powershell
New-RulesWorkbook  -Config $cfg -Path .\out\delivery-rules.xlsx
$lay = Get-LayoutReport -Config $cfg -Files $sets
New-StatusWorkbook -Config $cfg -XrefReport $rep -LayoutReport $lay -Path .\out\delivery-status.xlsx
```

## Safety

- Make a copy of the plot folder before the first `Invoke-SetPlan`, `Set-LayoutNames` or `Update-TitleBlock` run.
- Drawings open in AutoCAD (a `.dwl` lock file exists) are skipped and reported as `Locked`.
- A drawing whose report is incomplete is never planned, so a failed read cannot turn into "attach everything".
- `Export-BoundSets` never overwrites an existing output and only saves when every xref was bound.
- The tools never change xref types (attach/overlay) of existing references.

## Known issues

- **SECURELOAD**: AutoCAD blocks `(load ...)` from untrusted folders and cannot ask in console mode.
  The LISP files are therefore inlined into each generated `.scr` file (one source line per script
  line; long single-line scripts get cut). No security setting is changed.
- **Hanging drawings**: some drawings never finish loading in `accoreconsole`. They are killed after
  `hangTimeoutMinutes` and reported as `Hung`. Rerun them alone.
- **Parallel reads**: with several processes reading the same xref over the network, a reference can
  appear unloaded in one run. Re-check suspicious results with `-Parallel 1`.
- **Bind failures** come from the base drawings, not from the tools: proxy objects, a drawing that
  references itself, damaged files ("drawing may need recovery"), or nested *attached* xrefs.
  Fix the base drawing (`AUDIT`, `RECOVER`, remove proxies / self references) and export again.
- **Nested attachments**: an xref attached (not overlaid) inside a base drawing shows up in every set
  that uses that base drawing, even when the set rule excludes it.
- `layoutlist` and ActiveX (`vla-*`) are not available in `accoreconsole`; the LISP avoids them.

## Layout

```
scripts\AutocadDelivery.psm1   PowerShell module (all functions)
lisp\*.lsp                     AutoCAD side, one file per operation, common.lsp shared
config.example.json            documented example rules
```

## License

MIT
