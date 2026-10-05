[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
if([string]::IsNullOrWhiteSpace($IndexerDll)){$IndexerDll=Join-Path $project 'indexer\TokenRader.Indexer.dll'}
Add-Type -Path (Join-Path $project 'indexer\System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
$module=Import-Module (Join-Path $project 'TokenRader.Core.psm1') -Force -PassThru
$temp=Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-RecentContext-'+[guid]::NewGuid().ToString('N'))
$previous=$env:TOKEN_RADER_INDEX_DB
$utf8=[Text.UTF8Encoding]::new($false)
$now=[DateTimeOffset]::UtcNow
function Assert([bool]$condition,[string]$why){if(-not$condition){throw ('RECENT CONTEXT HANDOFF FAILED: '+$why)}}
function Sql([string]$sql){$cmd=$script:db.CreateCommand();try{$cmd.CommandText=$sql;[void]$cmd.ExecuteNonQuery()}finally{$cmd.Dispose()}}
function Scalar([string]$sql){$cmd=$script:db.CreateCommand();try{$cmd.CommandText=$sql;$cmd.ExecuteScalar()}finally{$cmd.Dispose()}}
function Line($record){($record|ConvertTo-Json -Depth 10 -Compress)+"`n"}
function Context([string]$model,[string]$tier,[string]$turn){Line @{timestamp=$now.AddMinutes(-10).ToString('o');type='turn_context';payload=@{model=$model;service_tier=$tier;turn_id=$turn;reasoning_effort='high'}}}
function Token([DateTimeOffset]$at,[int]$total,[bool]$last=$true,[bool]$hasTotal=$true){
 $info=@{}
 if($hasTotal){$info.total_token_usage=@{input_tokens=$total;cached_input_tokens=0;output_tokens=0}}
 if($last){$info.last_token_usage=@{input_tokens=100;cached_input_tokens=0;output_tokens=0}}
 Line @{timestamp=$at.ToString('o');type='event_msg';payload=@{type='token_count';info=$info}}
}
function MakeUnknown {Sql "UPDATE file_metadata SET turn_context_model='',turn_context_model_source='fast_sample_unknown',turn_context_model_timestamp='',turn_context_model_timestamp_ticks=0,turn_context_service_tier='',turn_context_service_tier_source='fast_sample_unknown'"}
function CommitProof {
 $status=[TokenRaderIndexer]::GetRecentHistoryBackfillStatus($script:db)
 $method=[TokenRaderIndexer].GetMethod('CommitRecentCoverageIfCompleted',[Reflection.BindingFlags]'NonPublic,Static')
 [void]$method.Invoke($null,@($script:db.PSObject.BaseObject,$status.PSObject.BaseObject,[Threading.CancellationToken]::None))
}
try {
 $sessions=Join-Path $temp 'sessions';[void][IO.Directory]::CreateDirectory($sessions)
 $env:TOKEN_RADER_INDEX_DB=Join-Path $temp 'data\private\synthetic-index.db'
 $path=Join-Path $sessions 'context-synthetic.jsonl'
 $meta=Line @{timestamp=$now.AddMinutes(-12).ToString('o');type='session_meta';payload=@{id='context-synthetic'}}
 $padding=Line @{timestamp=$now.AddMinutes(-9).ToString('o');type='response_item';payload=@{type='message';role='assistant';content=@(@{type='output_text';text=('x'*100000)})}}
 # A newer context hidden in the unsampled middle, followed by no token rows.
 $body=$meta+(Context 'gpt-5.4' 'default' 'old-turn')+(Token $now.AddMinutes(-11) 100)+$padding+$padding+(Context 'gpt-5.5' 'priority' 'new-turn')+$padding+$padding+$padding
 [IO.File]::WriteAllText($path,$body,$utf8)
 Initialize-TokenRaderIndexFromNow -SessionsRoot $sessions|Out-Null
 $script:db=(Get-TokenRaderIndex).Connection
 Assert ((Scalar 'SELECT turn_context_model_source FROM file_metadata')-eq'fast_sample_unknown') 'bounded startup does not guess across the middle'
 $prepared=Complete-TokenRaderRecentHistory -SessionsRoot $sessions -ProgressState ([hashtable]::Synchronized(@{}))
 Assert ($prepared.Completed-and-not$prepared.HistoryReused) 'first bounded scan completes'
 Assert ((Scalar 'SELECT turn_context_model FROM file_metadata')-eq'gpt-5.5') 'verified final model handed off'
 Assert ((Scalar 'SELECT turn_context_service_tier FROM file_metadata')-eq'priority') 'verified final tier handed off'
 Assert ((Scalar 'SELECT turn_context_model_timestamp_ticks FROM file_metadata')-gt0) 'valid context timestamp stored'
 $frozen=[long]$prepared.EndOffsets[$path]
 MakeUnknown
 $reused=Complete-TokenRaderRecentHistory -SessionsRoot $sessions -ProgressState ([hashtable]::Synchronized(@{}))
 Assert ($reused.HistoryReused-and$reused.ProcessedBytes-eq0) 'completed history repaired without rescan'
 Assert ((Scalar 'SELECT turn_context_model FROM file_metadata')-eq'gpt-5.5') 'reused completed proof repairs old unknown catalog'
 # Unit guard mutations affect only the synthetic database. Restore each field.
 foreach($guard in @('blocked','discard','body','timestamp','parentGuess','replacement','laterCursor','laterLiveContext','changedStamp','parser')) {
  MakeUnknown
  Sql 'UPDATE file_metadata SET fast_baseline_input=999'
  switch($guard){
   blocked {Sql "UPDATE recent_history_work SET blocked_reason='malformed_usage_record'"}
   discard {Sql 'UPDATE recent_history_work SET discard_line=1'}
   body {Sql "UPDATE recent_history_work SET body_scan_state='synthetic-unfinished'"}
   timestamp {Sql "UPDATE recent_history_work SET model_timestamp='invalid'"}
   parentGuess {Sql "UPDATE recent_history_work SET model_source='inherited_index'"}
   replacement {Sql "UPDATE history_gaps SET blocked_reason='source_replaced'"}
   laterCursor {Sql 'UPDATE file_metadata SET parsed_offset=parsed_offset+1'}
   laterLiveContext {Sql "UPDATE file_metadata SET turn_context_model='gpt-6-sol',turn_context_model_source='turn_context',turn_context_service_tier='default',turn_context_service_tier_source='turn_context'"}
   changedStamp {Sql 'UPDATE recent_history_attempt_stamps SET last_write_ticks=last_write_ticks+1'}
   parser {Sql 'UPDATE recent_history_attempt_stamps SET parser_version=0'}
  }
  CommitProof
  $expected=if($guard-eq'laterLiveContext'){'gpt-6-sol'}else{''}
  Assert ((Scalar 'SELECT turn_context_model FROM file_metadata')-eq$expected) ('refuse unsafe handoff: '+$guard)
  if($guard-ne'laterLiveContext'){Assert ((Scalar 'SELECT fast_baseline_input FROM file_metadata')-eq999) ('unsafe proof preserves cumulative baseline: '+$guard)}
  Sql "UPDATE recent_history_work SET blocked_reason='',discard_line=0,body_scan_state='',model_source='turn_context',model_timestamp='$($now.AddMinutes(-10).ToString('o'))'; UPDATE history_gaps SET blocked_reason=''; UPDATE file_metadata SET parsed_offset=$frozen; UPDATE recent_history_attempt_stamps SET last_write_ticks=(SELECT last_write_ticks FROM file_metadata),parser_version=$([TokenRaderIndexer]::RecentHistoryParserVersion)"
 }
 MakeUnknown
 Sql 'UPDATE file_metadata SET fast_baseline_input=999'
 $cancel=[Threading.CancellationTokenSource]::new();$cancel.Cancel()
 $status=[TokenRaderIndexer]::GetRecentHistoryBackfillStatus($db)
 $method=[TokenRaderIndexer].GetMethod('CommitRecentCoverageIfCompleted',[Reflection.BindingFlags]'NonPublic,Static')
 try{[void]$method.Invoke($null,@($db.PSObject.BaseObject,$status.PSObject.BaseObject,$cancel.Token));throw 'Expected cancellation'}catch{Assert ($_.Exception.ToString().Contains('OperationCanceledException')) 'cancellation is propagated'}finally{$cancel.Dispose()}
 Assert ((Scalar 'SELECT turn_context_model FROM file_metadata')-eq'') 'cancelled repair rolls back'
 Assert ((Scalar 'SELECT fast_baseline_input FROM file_metadata')-eq999) 'cancelled cumulative handoff preserves prior baseline'
 Sql "CREATE TRIGGER synthetic_baseline_failure BEFORE UPDATE OF fast_baseline_offset ON file_metadata BEGIN SELECT RAISE(ABORT,'synthetic baseline failure'); END"
 try{CommitProof;throw 'Expected baseline SQLite failure'}catch{Assert ($_.Exception.ToString().Contains('SQLiteException')) 'baseline database failure propagated'}
 Assert ((Scalar 'SELECT turn_context_model FROM file_metadata')-eq'') 'baseline failure rolls back earlier model handoff'
 Assert ((Scalar 'SELECT fast_baseline_input FROM file_metadata')-eq999) 'failed baseline handoff rolls back'
 Sql 'DROP TRIGGER synthetic_baseline_failure'
 CommitProof
 Assert ((Scalar 'SELECT fast_baseline_input FROM file_metadata')-eq100) 'verified cumulative total handed off with context'
 Sql 'UPDATE file_metadata SET fast_baseline_input=NULL'
 CommitProof
 Assert ((Scalar 'SELECT fast_baseline_input FROM file_metadata')-eq100) 'known model still accepts verified cumulative baseline'
 Sql "UPDATE file_metadata SET fast_baseline_offset=$($frozen+1),fast_baseline_input=999"
 CommitProof
 Assert ((Scalar 'SELECT fast_baseline_input FROM file_metadata')-eq999) 'later frozen cumulative baseline is not overwritten'
 Sql "UPDATE file_metadata SET fast_baseline_offset=$frozen"
 CommitProof
 $prices=Get-TokenRaderPrices -PricingPath (Join-Path $project 'pricing.json')
 $baseline=CaptureMeasurementBaseline -SessionsRoot $sessions -PreparedHistory $reused -PricingDocument $prices
 Start-Sleep -Milliseconds 20
 [IO.File]::AppendAllText($path,(Token ([DateTimeOffset]::UtcNow) 200),$utf8)
 $ending=CaptureMeasurementEnd -Baseline $baseline
 $result=Get-TokenRaderIndexedIntervalResult -Baseline $baseline -PricingDocument $prices -EndOffsets $ending.EndOffsets -EndRevision $ending.EndRevision -EndedAt $ending.EndedAt -ScanRateLimits $false
 Assert ($result.CountedEvents-eq1-and$result.Usage.Input-eq100-and$result.TotalCost-gt0-and$result.PricingComplete) 'production Start append CaptureEnd IndexedResult prices exactly one call'
 Assert ((Scalar 'SELECT model FROM token_records ORDER BY source_offset_end DESC LIMIT 1')-eq'gpt-5.5') 'live append uses final verified model'
 Assert ((Scalar 'SELECT service_tier FROM token_records ORDER BY source_offset_end DESC LIMIT 1')-eq'priority') 'live append uses final verified tier'
 # An old-version successful measurement may already have indexed an unknown
 # suffix beyond the previous recent freeze. The next Start resumes only it.
 foreach($repairCase in @('exact','usageMismatch','identityMismatch','knownModel','explicitDefault','databaseFailure','truncatedSource')) {
  Close-TokenRaderIndex
  $sessions=Join-Path $temp ($repairCase+'\sessions');[void][IO.Directory]::CreateDirectory($sessions)
  $env:TOKEN_RADER_INDEX_DB=Join-Path $temp ($repairCase+'\data\private\synthetic-index.db')
  $path=Join-Path $sessions 'context-synthetic.jsonl'
  [IO.File]::WriteAllText($path,$body.Replace('new-turn','old-turn'),$utf8)
  Initialize-TokenRaderIndexFromNow -SessionsRoot $sessions|Out-Null
  $first=Complete-TokenRaderRecentHistory -SessionsRoot $sessions -ProgressState ([hashtable]::Synchronized(@{}))
  $db=(Get-TokenRaderIndex).Connection
  $baseline=CaptureMeasurementBaseline -SessionsRoot $sessions -PreparedHistory $first -PricingDocument $prices
  MakeUnknown
  Start-Sleep -Milliseconds 20
  [IO.File]::AppendAllText($path,(Token ([DateTimeOffset]::UtcNow) 200),$utf8)
  $ending=CaptureMeasurementEnd -Baseline $baseline
  Assert ((Scalar 'SELECT parsed_offset FROM file_metadata')-gt[long]$first.EndOffsets[$path]) 'old bug state has live cursor beyond recent freeze'
  Assert ((Scalar 'SELECT model FROM token_records ORDER BY source_offset_end DESC LIMIT 1')-eq'') 'synthetic old bug stores unknown new row'
  switch($repairCase){
   usageMismatch {Sql 'UPDATE token_records SET call_input=call_input+1 WHERE source_offset_end=(SELECT MAX(source_offset_end) FROM token_records)'}
   identityMismatch {Sql "UPDATE token_records SET request_id='different-request' WHERE source_offset_end=(SELECT MAX(source_offset_end) FROM token_records)"}
   knownModel {Sql "UPDATE token_records SET model='gpt-5.4',model_source='turn_context' WHERE source_offset_end=(SELECT MAX(source_offset_end) FROM token_records)"}
   explicitDefault {Sql "UPDATE token_records SET service_tier='default',service_tier_source='response',turn_context_service_tier='default' WHERE source_offset_end=(SELECT MAX(source_offset_end) FROM token_records)"}
  }
  $beforeRevision=[TokenRaderIndexer]::GetIndexRevision($db)
  if($repairCase-eq'truncatedSource'){
   [IO.File]::WriteAllText($path,$meta,$utf8)
   $refused=[TokenRaderIndexer]::PrepareRecentHistory($db,$sessions,[DateTimeOffset]::UtcNow.AddHours(-24),[DateTimeOffset]::UtcNow,@{},[Threading.CancellationToken]::None)
   Assert (-not$refused.Completed-and$refused.BlockedFiles-gt0) 'truncated source cannot extend old context proof'
   Assert ((Scalar 'SELECT turn_context_model FROM file_metadata')-eq'') 'replaced source retains unknown old catalog rather than sampling replacement'
   Assert ((Scalar "SELECT COUNT(*) FROM history_gaps WHERE blocked_reason='source_replaced'")-gt0) 'replacement block retained'
   continue
  }
  $next=[TokenRaderIndexer]::PrepareRecentHistory($db,$sessions,[DateTimeOffset]::UtcNow.AddHours(-24),[DateTimeOffset]::UtcNow,@{},[Threading.CancellationToken]::None)
  $resumeCursor=Scalar 'SELECT cursor_offset FROM recent_history_work'
  Assert ($resumeCursor-eq[long]$first.EndOffsets[$path]) 'new preparation resumes old completed prefix'
  if($repairCase-eq'databaseFailure'){
   Sql "CREATE TRIGGER synthetic_repair_failure BEFORE UPDATE OF model ON token_records BEGIN SELECT RAISE(ABORT,'synthetic repair failure'); END"
   $revision=[TokenRaderIndexer]::GetIndexRevision($db)
   try{[void][TokenRaderIndexer]::BackfillRecentHistoryBatch($db,65536,5000,@{},[Threading.CancellationToken]::None);throw 'Expected SQLite failure'}catch{Assert ($_.Exception.ToString().Contains('SQLiteException')) 'repair database failure propagated'}
   Assert ((Scalar 'SELECT model FROM token_records ORDER BY source_offset_end DESC LIMIT 1')-eq'') 'failed model repair rolls back'
   Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq$resumeCursor) 'failed repair does not advance cursor'
   Assert ([TokenRaderIndexer]::GetIndexRevision($db)-eq$revision) 'failed repair does not advance revision'
   Sql 'DROP TRIGGER synthetic_repair_failure'
  }
  $bytes=0L;$repairs=0L
  do{$next=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,65536,5000,@{},[Threading.CancellationToken]::None);$bytes+=$next.ProcessedBytes;$repairs+=$next.RepairedModelRecords}while(-not$next.Completed-and$next.EligibleFiles-gt0)
  Assert ($next.Completed-and$bytes-gt0-and$bytes-lt10000) 'next Start scans only newly frozen suffix, not large known prefix'
  Assert ((Scalar 'SELECT turn_context_model FROM file_metadata')-eq'gpt-5.5') 'new freeze restores future model safely'
  Assert ([TokenRaderIndexer]::GetIndexRevision($db)-gt$beforeRevision) 'repair invalidates prior aggregate revision'
  $expected=if($repairCase-in@('exact','databaseFailure','explicitDefault')){'gpt-5.5'}elseif($repairCase-eq'knownModel'){'gpt-5.4'}else{''}
  Assert ((Scalar 'SELECT model FROM token_records ORDER BY source_offset_end DESC LIMIT 1')-eq$expected) ('bounded duplicate row repair: '+$repairCase)
  Assert ($repairs-eq$(if($repairCase-in@('exact','databaseFailure','explicitDefault')){1}else{0})) ('committed repair diagnostic count: '+$repairCase)
  Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq2) 'continuation neither adds nor double bills source-offset rows'
  if($repairCase-in@('exact','explicitDefault')){
   $expectedTier=if($repairCase-eq'exact'){'priority'}else{'default'}
   Assert ((Scalar 'SELECT service_tier FROM token_records ORDER BY source_offset_end DESC LIMIT 1')-eq$expectedTier) ('repair only unknown tier, preserve explicit tier: '+$repairCase)
   $repairedResult=Get-TokenRaderIndexedIntervalResult -Baseline $baseline -PricingDocument $prices -EndOffsets $ending.EndOffsets -EndRevision ([TokenRaderIndexer]::GetIndexRevision($db)) -EndedAt $ending.EndedAt -ScanRateLimits $false
   $expectedCost=if($repairCase-eq'exact'){0.00125}else{0.0005}
   Assert ([Math]::Abs($repairedResult.TotalCost-$expectedCost)-lt0.000000001) ('repaired dollars use verified tier: '+$repairCase)
  }
 }
 foreach($numericCase in @('hiddenTotal','lastOnlyBreak')) {
  Close-TokenRaderIndex
  $sessions=Join-Path $temp ($numericCase+'\sessions');[void][IO.Directory]::CreateDirectory($sessions)
  $env:TOKEN_RADER_INDEX_DB=Join-Path $temp ($numericCase+'\data\private\synthetic-index.db')
  $path=Join-Path $sessions 'context-synthetic.jsonl'
  $numeric=$meta+(Context 'gpt-5.4' 'default' 'same-turn')+(Token $now.AddMinutes(-11) 100)+$padding+$padding+(Token $now.AddMinutes(-10) 300 $false)+$padding+$padding+$padding
  if($numericCase-eq'lastOnlyBreak'){$numeric=$numeric+(Token $now.AddMinutes(-9) 0 $true $false)+$padding+$padding}
  [IO.File]::WriteAllText($path,$numeric,$utf8)
  Initialize-TokenRaderIndexFromNow -SessionsRoot $sessions|Out-Null
  $db=(Get-TokenRaderIndex).Connection
  Assert ([Convert]::IsDBNull((Scalar 'SELECT fast_baseline_input FROM file_metadata'))) 'hidden middle total is not in bounded startup sample'
  if($numericCase-eq'lastOnlyBreak'){Sql 'UPDATE file_metadata SET fast_baseline_input=999,fast_baseline_cached=0,fast_baseline_output=0,fast_baseline_reasoning=0'}
  $prepared=Complete-TokenRaderRecentHistory -SessionsRoot $sessions -ProgressState ([hashtable]::Synchronized(@{}))
  if($numericCase-eq'lastOnlyBreak'){Assert ([Convert]::IsDBNull((Scalar 'SELECT fast_baseline_input FROM file_metadata'))) 'verified last-only explicitly clears stale cumulative baseline'}
  $baseline=CaptureMeasurementBaseline -SessionsRoot $sessions -PreparedHistory $prepared -PricingDocument $prices
  Start-Sleep -Milliseconds 20
  [IO.File]::AppendAllText($path,(Token ([DateTimeOffset]::UtcNow) 400 $false),$utf8)
  $ending=CaptureMeasurementEnd -Baseline $baseline
  $numericResult=Get-TokenRaderIndexedIntervalResult -Baseline $baseline -PricingDocument $prices -EndOffsets $ending.EndOffsets -EndRevision $ending.EndRevision -EndedAt $ending.EndedAt -ScanRateLimits $false
  if($numericCase-eq'hiddenTotal'){
   Assert ($numericResult.CountedEvents-eq1-and$numericResult.Usage.Input-eq100-and$numericResult.TotalCost-gt0) 'hidden verified total supports new total-only live cost'
  } else {
   Assert ($numericResult.CountedEvents-eq0-and$numericResult.Usage.Input-eq0) 'last-only history breaks cumulative baseline without charging prior work'
   Start-Sleep -Milliseconds 20
   [IO.File]::AppendAllText($path,(Token ([DateTimeOffset]::UtcNow) 450 $false),$utf8)
   $ending=CaptureMeasurementEnd -Baseline $baseline
   $numericResult=Get-TokenRaderIndexedIntervalResult -Baseline $baseline -PricingDocument $prices -EndOffsets $ending.EndOffsets -EndRevision $ending.EndRevision -EndedAt $ending.EndedAt -ScanRateLimits $false
   Assert ($numericResult.CountedEvents-eq1-and$numericResult.Usage.Input-eq50-and$numericResult.TotalCost-gt0) 'next trusted total establishes a new stream after last-only break'
  }
 }
 Write-Output ('RECENT_CONTEXT_HANDOFF_TESTS_PASSED: tokens={0}, cost={1}' -f $result.Usage.Input,$result.TotalCost)
} finally {
 Close-TokenRaderIndex
 if($null-eq$previous){Remove-Item Env:TOKEN_RADER_INDEX_DB -ErrorAction SilentlyContinue}else{$env:TOKEN_RADER_INDEX_DB=$previous}
 $resolved=[IO.Path]::GetFullPath($temp);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\TokenRader-RecentContext-'
 if(-not$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic cleanup target'}
 if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
