[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Explorer { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw "EXPLORER TEST FAILED: $Message" } }

$projectRoot = Join-Path ([IO.Path]::GetTempPath()) ('token-rader-explorer-' + [Guid]::NewGuid().ToString('N'))
$dbPath = Join-Path $projectRoot 'data\private\index\index.db'
New-Item -ItemType Directory -Path (Split-Path -Parent $dbPath) -Force | Out-Null
$pricing = [ordered]@{
    unitTokens = 1000000
    verifiedAt = 'synthetic'
    models = @([ordered]@{ id='gpt-5.5'; aliases=@(); input=1.0; cachedInput=0.5; output=2.0 })
}
[IO.File]::WriteAllText((Join-Path $projectRoot 'pricing.json'), ($pricing | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

Add-Type -Path (Join-Path $PSScriptRoot '..\indexer\System.Data.SQLite.dll')
if ($null -eq ('TokenRaderIndexer' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot '..\indexer\TokenRader.Indexer.dll') }
Import-Module (Join-Path $PSScriptRoot '..\TokenRader.Explorer.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\TokenRader.Core.psm1') -Force
$conn = New-Object System.Data.SQLite.SQLiteConnection ('Data Source=' + $dbPath + ';Version=3;')
$conn.Open(); [TokenRaderIndexer]::CreateSchema($conn)
$pRoot = Join-Path $projectRoot 'sessions'; New-Item -ItemType Directory -Path $pRoot -Force | Out-Null
$projectA = Join-Path $projectRoot 'Project A'; $projectB = Join-Path $projectRoot 'Project B'
$parent = Join-Path $pRoot 'rollout-11111111-1111-1111-1111-111111111111.jsonl'
$child = Join-Path $pRoot 'rollout-22222222-2222-2222-2222-222222222222.jsonl'
$other = Join-Path $pRoot 'rollout-33333333-3333-3333-3333-333333333333.jsonl'
$now = [DateTime]::UtcNow.Ticks
[TokenRaderIndexer]::UpdateFileMetadata($conn,$parent,1000,$now,1000,'11111111-1111-1111-1111-111111111111',$projectA,'','',$null)
[TokenRaderIndexer]::UpdateFileMetadata($conn,$child,1000,$now+1,1000,'22222222-2222-2222-2222-222222222222',$projectA,'11111111-1111-1111-1111-111111111111','',$null)
[TokenRaderIndexer]::UpdateFileMetadata($conn,$other,1000,$now+2,1000,'33333333-3333-3333-3333-333333333333',$projectB,'','',$null)
$insert = $conn.CreateCommand(); $insert.CommandText = 'INSERT INTO token_records (session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning,call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,source_offset_end,root_session_id,turn_id,request_id,response_id,identity_source,service_tier,service_tier_source) VALUES (@s,@t,@m,@ti,@tc,@to,0,@ci,@cc,@co,0,@f,@p,@o,@r,'''','''','''','''','''','''')'
foreach($n in @('s','t','m','ti','tc','to','ci','cc','co','f','p','o','r')){[void]$insert.Parameters.Add('@'+$n,[System.Data.DbType]::Object)}
function Add-SyntheticRecord { param($Session,$Timestamp,$InputTokens,$Path,$Offset,$Root)
    $vals=@{s=$Session;t=$Timestamp;m='gpt-5.5';ti=$InputTokens;tc=0;to=10;ci=$InputTokens;cc=0;co=10;f=([Guid]::NewGuid().ToString());p=$Path;o=$Offset;r=$Root}
    foreach($k in $vals.Keys){$insert.Parameters['@'+$k].Value=$vals[$k]}; [void]$insert.ExecuteNonQuery()
}
Add-SyntheticRecord '11111111-1111-1111-1111-111111111111' '2026-01-01T00:00:00.0000000Z' 100 $parent 100 '11111111-1111-1111-1111-111111111111'
Add-SyntheticRecord '22222222-2222-2222-2222-222222222222' '2026-01-01T00:01:00.0000000Z' 200 $child 100 '11111111-1111-1111-1111-111111111111'
Add-SyntheticRecord '33333333-3333-3333-3333-333333333333' '2026-01-01T00:02:00.0000000Z' 900 $other 100 '33333333-3333-3333-3333-333333333333'
Add-SyntheticRecord '22222222-2222-2222-2222-222222222222' '2026-01-01T00:00:10.0000000Z' 100 $child 110 '11111111-1111-1111-1111-111111111111'
$insert.Dispose(); $conn.Close(); $conn.Dispose()

$catalog = Get-TokenRaderExplorerCatalog -ProjectRoot $projectRoot
$a = @($catalog.Projects | Where-Object Path -eq $projectA)[0]
Assert-Explorer ($null -ne $a) 'catalog project A exists'
Assert-Explorer ($a.Sessions.Count -eq 2) 'catalog includes parent and child sessions'
$start = [DateTimeOffset]::Parse('2025-12-31T00:00:00Z'); $end = [DateTimeOffset]::Parse('2026-01-02T00:00:00Z')
$projectResult = Get-TokenRaderExplorerResult -ProjectRoot $projectRoot -ProjectPath $projectA -StartAt $start -EndAt $end
Assert-Explorer ([Int64]$projectResult.Usage.Input -eq 300) 'project result includes descendants only'
$childResult = Get-TokenRaderExplorerResult -ProjectRoot $projectRoot -SessionId '22222222-2222-2222-2222-222222222222' -StartAt $start -EndAt $end
Assert-Explorer ([Int64]$childResult.Usage.Input -eq 200) 'session result does not include parent'
Assert-Explorer ([Math]::Abs($childResult.TotalCost-0.00022) -lt 0.000000001) 'child dollar cost includes copied parent event'
$allTime=Get-TokenRaderExplorerResult -ProjectRoot $projectRoot -ProjectPath $projectA -StartAt $null -EndAt $end
Assert-Explorer ($allTime.Usage.Input -eq 300) 'all-time results diverge or double count parent copies'
$bounded=Get-TokenRaderExplorerResult -ProjectRoot $projectRoot -ProjectPath $projectA -StartAt ([DateTimeOffset]::Parse('2026-01-01T00:00:20Z')) -EndAt $end
Assert-Explorer ($bounded.Usage.Input -eq 200) 'time filter included earlier calls'
$otherResult = Get-TokenRaderExplorerResult -ProjectRoot $projectRoot -ProjectPath $projectB -StartAt $start -EndAt $end
Assert-Explorer ([Int64]$otherResult.Usage.Input -eq 900) 'other project is isolated'
Assert-Explorer (-not [bool]$projectResult.Coverage.IsComplete) 'main index result is conservative about coverage'
$allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$target=[IO.Path]::GetFullPath($projectRoot)
if (-not $target.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe synthetic cleanup target' }
Remove-Item -LiteralPath $target -Recurse -Force
Write-Output 'EXPLORER_TESTS_PASSED'
