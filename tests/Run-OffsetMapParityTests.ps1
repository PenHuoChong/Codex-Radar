[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'TokenRader.Core.psm1') -Force
& (Get-Module TokenRader.Core) {
    function ConvertTo-LegacyOffsetMap {
        param($Value)
        $map=New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        if ($null -eq $Value) { return $map }
        if ($Value -is [Collections.IDictionary]) {
            foreach ($key in @($Value.Keys)) { try { $map[(ConvertTo-TokenRaderCanonicalPath -Path ([string]$key))]=[Int64]$Value[$key] } catch { } }
        } elseif ($null -ne $Value.PSObject) {
            foreach ($property in @($Value.PSObject.Properties)) { try { $map[(ConvertTo-TokenRaderCanonicalPath -Path ([string]$property.Name))]=[Int64]$property.Value } catch { } }
        }
        return $map
    }
    $dictionary=New-Object hashtable ([StringComparer]::Ordinal)
    $dictionary['']='7'; $dictionary['relative.jsonl']='12'; $dictionary['.\relative.jsonl']='13'
    $dictionary['E:\synthetic\A.jsonl']=14L; $dictionary['e:\SYNTHETIC\a.jsonl']=15L
    $dictionary[('bad'+[char]0+'path')]=16L; $dictionary['bad-number']='no'; $dictionary['null-number']=$null
    $dictionary['object-number']=@{ synthetic=1 }; $dictionary['negative-number']=-1L
    $serialized=[pscustomobject][ordered]@{
        'relative.jsonl'='12'; '.\relative.jsonl'='13'; 'E:\synthetic\B.jsonl'=14L
        'bad-number'='no'; 'null-number'=$null; 'object-number'=@{ synthetic=1 }; 'negative-number'=-1L
    }
    foreach ($fixture in @($null,$dictionary,$serialized)) {
        $legacy=ConvertTo-LegacyOffsetMap $fixture
        $current=ConvertTo-TokenRaderOffsetMap $fixture
        if ($legacy.Count -ne $current.Count) { throw 'Offset map count parity failed' }
        foreach ($key in @($legacy.Keys)) {
            if (-not $current.ContainsKey($key) -or $legacy[$key] -ne $current[$key]) { throw 'Offset map key/value parity failed' }
        }
        if ($current.ContainsKey([IO.Path]::GetFullPath('bad-number')) -or $current.ContainsKey([IO.Path]::GetFullPath('object-number'))) { throw 'Invalid numeric values were not skipped' }
    }
    Write-Output 'OFFSET_MAP_PARITY_PASS dictionary/serialized/null, empty/invalid/relative/full paths, case aliases, numeric/null/negative/invalid values'
}
