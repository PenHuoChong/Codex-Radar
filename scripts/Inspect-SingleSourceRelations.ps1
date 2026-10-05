[CmdletBinding()]
param([string]$ProjectRoot='', [switch]$ReadOnlyRelationsAuthorized, [switch]$ReadTargetHeaderAuthorized)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$db=$null; $begun=$false
function RelationRows([string]$sql,[hashtable]$parameters=@{}) {
    $cmd=$script:db.CreateCommand()
    try {
        $cmd.CommandText=$sql
        foreach($key in $parameters.Keys){[void]$cmd.Parameters.AddWithValue([string]$key,$parameters[$key])}
        $rows=[Collections.Generic.List[object]]::new()
        $reader=$cmd.ExecuteReader()
        try {
            while($reader.Read()){
                $row=@{}
                for($i=0;$i-lt$reader.FieldCount;$i++){$row[$reader.GetName($i)]=$reader.GetValue($i)}
                $rows.Add([pscustomobject]$row)
            }
        }finally{$reader.Dispose()}
        return $rows.ToArray()
    }finally{$cmd.Dispose()}
}
function RelationCount([string]$sql,[hashtable]$parameters=@{}) {
    $cmd=$script:db.CreateCommand()
    try {
        $cmd.CommandText=$sql
        foreach($key in $parameters.Keys){[void]$cmd.Parameters.AddWithValue([string]$key,$parameters[$key])}
        return [long]$cmd.ExecuteScalar()
    }finally{$cmd.Dispose()}
}
function RelationCommand([string]$sql) {
    $cmd=$script:db.CreateCommand()
    try{$cmd.CommandText=$sql;[void]$cmd.ExecuteNonQuery()}finally{$cmd.Dispose()}
}
function RelationText($value){if($null-eq$value-or$value-is[DBNull]){return ''};return [string]$value}
try {
    if(-not$ReadOnlyRelationsAuthorized){throw [InvalidOperationException]::new('Scoped authorization required.')}
    if([string]::IsNullOrWhiteSpace($ProjectRoot)){$ProjectRoot=Split-Path -Parent $PSScriptRoot}
    $ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot)
    # Deliberately ignore environment overrides: only this authorized project index.
    $dbPath=[IO.Path]::GetFullPath((Join-Path $ProjectRoot 'data\private\index\index.db'))
    if(-not[IO.File]::Exists($dbPath)){throw [InvalidOperationException]::new('Authorized index unavailable.')}
    if(([IO.File]::GetAttributes($dbPath)-band[IO.FileAttributes]::ReparsePoint)-ne0){throw [InvalidOperationException]::new('Linked index refused.')}
    for($directory=[IO.DirectoryInfo]::new([IO.Path]::GetDirectoryName($dbPath));$null-ne$directory;$directory=$directory.Parent){
        if(($directory.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw [InvalidOperationException]::new('Linked parent refused.')}
    }
    Add-Type -Path (Join-Path $ProjectRoot 'indexer\System.Data.SQLite.dll')
    $builder=[System.Data.SQLite.SQLiteConnectionStringBuilder]::new()
    $builder['Data Source']=[string]$dbPath; $builder['Read Only']=$true; $builder['FailIfMissing']=$true; $builder['Pooling']=$false
    $db=[System.Data.SQLite.SQLiteConnection]::new($builder.ConnectionString);$db.Open()
    RelationCommand 'PRAGMA query_only=ON; PRAGMA busy_timeout=5000; BEGIN'
    $begun=$true
    if((RelationCount 'PRAGMA query_only')-ne1){throw [InvalidOperationException]::new('Read-only guard unavailable.')}
    $blocked=@(RelationRows "SELECT DISTINCT path FROM history_gaps WHERE blocked_reason='source_replaced' LIMIT 2")
    if($blocked.Count-ne1){
        [pscustomobject]@{Status='target_not_unique';BlockedTargetCount=$blocked.Count;ReadOnly=$true}|ConvertTo-Json -Compress
    }else{
        $targetPath=RelationText $blocked[0].path
        $target=@(RelationRows 'SELECT path,session_id,parent_thread_id,forked_from_id,root_session_id,length,parsed_offset,last_write_ticks,content_retained FROM file_metadata WHERE path COLLATE BINARY=@path LIMIT 2' @{'@path'=$targetPath})
        if($target.Count-ne1){throw [InvalidOperationException]::new('Target metadata unavailable.')}
        $fresh=$null;$freshFacts=$null;$headerRoot='';$headerRootThread='';$headerId='';$headerAliasAgree=$true
        if($ReadTargetHeaderAuthorized){
            if(([IO.File]::GetAttributes($targetPath)-band[IO.FileAttributes]::ReparsePoint)-ne0){throw [InvalidOperationException]::new('Linked target refused.')}
            Add-Type -Path (Join-Path $ProjectRoot 'indexer\TokenRader.Indexer.dll')
            $readHeader=[TokenRaderIndexer].GetMethod('ReadRepairHeader',[Reflection.BindingFlags]'NonPublic,Static')
            $validatorType=[TokenRaderIndexer].GetNestedType('RepairJsonValidator',[Reflection.BindingFlags]::NonPublic)
            if($null-eq$readHeader-or$null-eq$validatorType){throw [InvalidOperationException]::new('Header validator unavailable.')}
            $source=[IO.FileStream]::new($targetPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete))
            try{
                $headerBytes=[byte[]]$readHeader.Invoke($null,[object[]]@($source,[long]$source.Length,[Threading.CancellationToken]::None))
                $headerText=[Text.UTF8Encoding]::new($false,$true).GetString($headerBytes).TrimStart([char]0xFEFF)
                $validator=$validatorType.GetConstructor([type[]]@([string])).Invoke([object[]]@($headerText))
                $selected=$validatorType.GetMethod('Validate').Invoke($validator,$null)
                if(-not$selected.ContainsKey('type')-or$selected['type']-ne'session_meta'){throw [InvalidOperationException]::new('Session header unavailable.')}
                $fresh=@{}
                foreach($key in @('id','parent_thread_id','parent_session_id','forked_from_id','root_session_id','root_thread_id')){
                    $fresh[$key]=if($selected.ContainsKey('payload.'+$key)){[string]$selected['payload.'+$key]}else{''}
                }
                $selected.Clear();$headerText=$null;$validator=$null;[Array]::Clear($headerBytes,0,$headerBytes.Length)
            }finally{$source.Dispose()}
            $headerId=[string]$fresh.id;$headerRoot=[string]$fresh.root_session_id;$headerRootThread=[string]$fresh.root_thread_id
            $headerAliasAgree=[string]::IsNullOrEmpty($fresh.parent_thread_id)-or[string]::IsNullOrEmpty($fresh.parent_session_id)-or$fresh.parent_thread_id.Equals($fresh.parent_session_id,[StringComparison]::OrdinalIgnoreCase)
            $freshFacts=[pscustomobject]@{IdMatchesOldCatalog=$headerId.Equals((RelationText $target[0].session_id),[StringComparison]::OrdinalIgnoreCase);ParentThreadPresent=(-not[string]::IsNullOrEmpty($fresh.parent_thread_id));ParentSessionPresent=(-not[string]::IsNullOrEmpty($fresh.parent_session_id));ParentAliasesAgree=$headerAliasAgree;ForkPresent=(-not[string]::IsNullOrEmpty($fresh.forked_from_id));RootSessionPresent=(-not[string]::IsNullOrEmpty($headerRoot));RootThreadPresent=(-not[string]::IsNullOrEmpty($headerRootThread));RootAliasesAgree=([string]::IsNullOrEmpty($headerRoot)-or[string]::IsNullOrEmpty($headerRootThread)-or$headerRoot.Equals($headerRootThread,[StringComparison]::OrdinalIgnoreCase));ExplicitRootMatchesOldCatalog=([string]::IsNullOrEmpty($headerRoot)-or$headerRoot.Equals((RelationText $target[0].root_session_id),[StringComparison]::OrdinalIgnoreCase))}
        }
        $nodes=[Collections.Generic.List[object]]::new();$facts=[Collections.Generic.List[object]]::new();$parentCandidates=[Collections.Generic.List[object]]::new();$candidateAgreement=$null;$candidateTotal=0L
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $current=$target[0];$complete=$false;$unique=$true;$cycle=$false;$conflict=$false;$missing=$false;$limit=$false
        if($null-ne$fresh){
            $firstParent=if(-not[string]::IsNullOrEmpty($fresh.parent_thread_id)){$fresh.parent_thread_id}else{$fresh.parent_session_id}
            $current=[pscustomobject]@{path=$targetPath;session_id=$headerId;parent_thread_id=$firstParent;forked_from_id=$fresh.forked_from_id;root_session_id=$headerRoot;length=$target[0].length;parsed_offset=$target[0].parsed_offset;last_write_ticks=$target[0].last_write_ticks;content_retained=$target[0].content_retained}
        }
        for($level=0;$level-lt32;$level++){
            $id=RelationText $current.session_id;$path=RelationText $current.path;$parent=RelationText $current.parent_thread_id
            $fork=RelationText $current.forked_from_id;$root=RelationText $current.root_session_id
            if([string]::IsNullOrWhiteSpace($id)){$missing=$true;break}
            if(-not$seen.Add($id)){$cycle=$true;break}
            $catalogCount=RelationCount 'SELECT COUNT(*) FROM file_metadata WHERE session_id COLLATE NOCASE=@id' @{'@id'=$id}
            $samePathExtra=0L;$legacy=0L
            foreach($table in @('token_records','tool_records','recent_lineage_evidence')){
                $samePathExtra+=RelationCount ("SELECT COUNT(*) FROM "+$table+" WHERE session_id COLLATE NOCASE=@id AND COALESCE(source_path,'') COLLATE BINARY<>@path AND COALESCE(source_path,'')<>''") @{'@id'=$id;'@path'=$path}
                $legacy+=RelationCount ("SELECT COUNT(*) FROM "+$table+" WHERE session_id COLLATE NOCASE=@id AND COALESCE(source_path,'')=''") @{'@id'=$id}
            }
            $history=RelationCount "SELECT COUNT(*) FROM history_gaps WHERE path COLLATE BINARY=@path AND (cursor_offset<end_offset OR blocked_reason<>'')" @{'@path'=$path}
            $historyReplaced=RelationCount "SELECT COUNT(*) FROM history_gaps WHERE path COLLATE BINARY=@path AND blocked_reason='source_replaced'" @{'@path'=$path}
            $recent=RelationCount "SELECT COUNT(*) FROM recent_history_work WHERE path COLLATE BINARY=@path AND (cursor_offset<end_offset OR blocked_reason<>'')" @{'@path'=$path}
            $recentReplaced=RelationCount "SELECT COUNT(*) FROM recent_history_work WHERE path COLLATE BINARY=@path AND blocked_reason='source_replaced'" @{'@path'=$path}
            $tokenRootMismatch=RelationCount "SELECT COUNT(*) FROM token_records WHERE source_path COLLATE BINARY=@path AND COALESCE(root_session_id,'') COLLATE NOCASE<>@root" @{'@path'=$path;'@root'=$root}
            $toolRootMismatch=RelationCount "SELECT COUNT(*) FROM tool_records WHERE source_path COLLATE BINARY=@path AND COALESCE(root_session_id,'') COLLATE NOCASE<>@root" @{'@path'=$path;'@root'=$root}
            $proofRootMismatch=RelationCount "SELECT COUNT(*) FROM recent_lineage_evidence WHERE source_path COLLATE BINARY=@path AND lower(substr(event_key,1,instr(event_key,'|')-1))<>lower(@root)" @{'@path'=$path;'@root'=$root}
            $parentForkAgree=[string]::IsNullOrEmpty($parent)-or[string]::IsNullOrEmpty($fork)-or$parent.Equals($fork,[StringComparison]::OrdinalIgnoreCase)
            $nodes.Add($current)
            $facts.Add([pscustomobject]@{Layer=$level;CatalogMatches=$catalogCount;Unique=($catalogCount-eq1);HasParent=(-not[string]::IsNullOrEmpty($parent));HasFork=(-not[string]::IsNullOrEmpty($fork));ParentForkAgree=$parentForkAgree;RootPresent=(-not[string]::IsNullOrEmpty($root));OffsetWithinLength=([long]$current.parsed_offset-ge0-and[long]$current.parsed_offset-le[long]$current.length);ContentRetained=([long]$current.content_retained-eq1);HistoryPendingOrBlocked=$history;HistorySourceReplaced=$historyReplaced;RecentPendingOrBlocked=$recent;RecentSourceReplaced=$recentReplaced;OtherPathSameSessionRows=$samePathExtra;BlankSourceLegacyRows=$legacy;TokenRootMismatch=$tokenRootMismatch;ToolRootMismatch=$toolRootMismatch;ProofRootMismatch=$proofRootMismatch})
            if($catalogCount-ne1){$unique=$false;break}
            if($level-eq0-and-not$headerAliasAgree){$conflict=$true;break}
            if(-not$parentForkAgree){$conflict=$true;break}
            $next=if(-not[string]::IsNullOrEmpty($parent)){$parent}else{$fork}
            if([string]::IsNullOrEmpty($next)){$complete=$true;break}
            $remainingCandidates=32-$nodes.Count
            if($remainingCandidates-le0){$limit=$true;break}
            $nextCount=RelationCount 'SELECT COUNT(*) FROM file_metadata WHERE session_id COLLATE NOCASE=@id' @{'@id'=$next}
            $matches=@(RelationRows ('SELECT path,session_id,parent_thread_id,forked_from_id,root_session_id,length,parsed_offset,last_write_ticks,content_retained FROM file_metadata WHERE session_id COLLATE NOCASE=@id LIMIT '+[Math]::Min(2,$remainingCandidates)) @{'@id'=$next})
            if($matches.Count-eq0){$missing=$true;break}
            if($nextCount-ne1){
                $unique=$false
                $candidateTotal=$nextCount
                $candidateAgreement=$true;$firstCandidate=$matches[0];$variant=0
                foreach($candidate in $matches){
                    $candidatePath=RelationText $candidate.path;$candidateRoot=RelationText $candidate.root_session_id;$candidateId=RelationText $candidate.session_id
                    foreach($field in @('parent_thread_id','forked_from_id','root_session_id')){if(-not(RelationText $candidate.$field).Equals((RelationText $firstCandidate.$field),[StringComparison]::OrdinalIgnoreCase)){$candidateAgreement=$false}}
                    $parentValue=RelationText $candidate.parent_thread_id;$forkValue=RelationText $candidate.forked_from_id
                    $parentCandidates.Add([pscustomobject]@{Layer=($level+1);Variant=$variant;ParentPresent=(-not[string]::IsNullOrEmpty($parentValue));ForkPresent=(-not[string]::IsNullOrEmpty($forkValue));ParentPointsToSelf=$parentValue.Equals($candidateId,[StringComparison]::OrdinalIgnoreCase);ForkPointsToSelf=$forkValue.Equals($candidateId,[StringComparison]::OrdinalIgnoreCase);ParentForkAgree=([string]::IsNullOrEmpty($parentValue)-or[string]::IsNullOrEmpty($forkValue)-or$parentValue.Equals($forkValue,[StringComparison]::OrdinalIgnoreCase));RootPresent=(-not[string]::IsNullOrEmpty($candidateRoot));SelfRoot=$candidateId.Equals($candidateRoot,[StringComparison]::OrdinalIgnoreCase);OffsetWithinLength=([long]$candidate.parsed_offset-ge0-and[long]$candidate.parsed_offset-le[long]$candidate.length);ContentRetained=([long]$candidate.content_retained-eq1);HistorySourceReplaced=(RelationCount "SELECT COUNT(*) FROM history_gaps WHERE path COLLATE BINARY=@path AND blocked_reason='source_replaced'" @{'@path'=$candidatePath});HistoryPendingOrBlocked=(RelationCount "SELECT COUNT(*) FROM history_gaps WHERE path COLLATE BINARY=@path AND (cursor_offset<end_offset OR blocked_reason<>'')" @{'@path'=$candidatePath});RecentPendingOrBlocked=(RelationCount "SELECT COUNT(*) FROM recent_history_work WHERE path COLLATE BINARY=@path AND (cursor_offset<end_offset OR blocked_reason<>'')" @{'@path'=$candidatePath});TargetTokenRootMatches=(RelationCount 'SELECT COUNT(*) FROM token_records WHERE source_path COLLATE BINARY=@path AND root_session_id COLLATE NOCASE=@root' @{'@path'=$targetPath;'@root'=$candidateRoot});TargetToolRootMatches=(RelationCount 'SELECT COUNT(*) FROM tool_records WHERE source_path COLLATE BINARY=@path AND root_session_id COLLATE NOCASE=@root' @{'@path'=$targetPath;'@root'=$candidateRoot})})
                    $variant++
                }
                break
            }
            $current=$matches[0]
            if($level-eq31){$limit=$true}
        }
        $rootAgreement=$false;$canonical=''
        if($complete-and$nodes.Count-gt0){
            $canonical=RelationText $nodes[$nodes.Count-1].session_id;$rootAgreement=$true
            foreach($node in $nodes){$declared=RelationText $node.root_session_id;if([string]::IsNullOrEmpty($declared)-or-not$declared.Equals($canonical,[StringComparison]::OrdinalIgnoreCase)){$rootAgreement=$false}}
        }
        $rootReferences=[Collections.Generic.List[object]]::new();$rootGroups=[Collections.Generic.List[object]]::new();$sessionFacts=[Collections.Generic.List[object]]::new()
        if($null-ne$fresh){
            $remaining=32-$nodes.Count-$parentCandidates.Count
            foreach($entry in @(@{Role='root_session';Id=$headerRoot},@{Role='root_thread';Id=$headerRootThread})){
                if([string]::IsNullOrEmpty($entry.Id)){continue}
                if(-not$seen.Contains($entry.Id)){
                    if($remaining-le0){$limit=$true;$rootReferences.Add([pscustomobject]@{Role=$entry.Role;DepthLimitReached=$true});continue}
                    $remaining--;[void]$seen.Add($entry.Id)
                }
                $rootMatches=@(RelationRows 'SELECT path,session_id,parent_thread_id,forked_from_id,root_session_id FROM file_metadata WHERE session_id COLLATE NOCASE=@id LIMIT 2' @{'@id'=$entry.Id})
                $rootNode=$null
                if($rootMatches.Count-eq1){
                    $node=$rootMatches[0];$p=RelationText $node.path;$sid=RelationText $node.session_id;$declared=RelationText $node.root_session_id
                    $rootNode=[pscustomobject]@{ParentPresent=(-not[string]::IsNullOrEmpty((RelationText $node.parent_thread_id)));ForkPresent=(-not[string]::IsNullOrEmpty((RelationText $node.forked_from_id)));SelfRoot=$sid.Equals($declared,[StringComparison]::OrdinalIgnoreCase);SourceReplaced=(RelationCount "SELECT COUNT(*) FROM history_gaps WHERE path COLLATE BINARY=@path AND blocked_reason='source_replaced'" @{'@path'=$p});RecentBlocked=(RelationCount "SELECT COUNT(*) FROM recent_history_work WHERE path COLLATE BINARY=@path AND blocked_reason<>''" @{'@path'=$p})}
                }
                $rootReferences.Add([pscustomobject]@{Role=$entry.Role;CatalogMatches=$rootMatches.Count;Unique=($rootMatches.Count-eq1);MatchesResolvedChain=($complete-and$entry.Id.Equals($canonical,[StringComparison]::OrdinalIgnoreCase));Node=$rootNode})
            }
            foreach($table in @('token_records','tool_records')){
                $oldId=RelationText $target[0].session_id
                $sessionFacts.Add([pscustomobject]@{Table=$table;Rows=(RelationCount ("SELECT COUNT(*) FROM "+$table+" WHERE source_path COLLATE BINARY=@path") @{'@path'=$targetPath});MismatchOldCatalog=(RelationCount ("SELECT COUNT(*) FROM "+$table+" WHERE source_path COLLATE BINARY=@path AND session_id COLLATE NOCASE<>@id") @{'@path'=$targetPath;'@id'=$oldId});MismatchFreshHeader=(RelationCount ("SELECT COUNT(*) FROM "+$table+" WHERE source_path COLLATE BINARY=@path AND session_id COLLATE NOCASE<>@id") @{'@path'=$targetPath;'@id'=$headerId})})
                $groups=@(RelationRows ("SELECT root_session_id,COUNT(*) AS row_count FROM "+$table+" WHERE source_path COLLATE BINARY=@path GROUP BY root_session_id LIMIT 33") @{'@path'=$targetPath})
                $ordinal=0
                foreach($group in @($groups|Select-Object -First 32)){
                    $value=RelationText $group.root_session_id
                    $rootGroups.Add([pscustomobject]@{Table=$table;Group=$ordinal;Rows=[long]$group.row_count;RootPresent=(-not[string]::IsNullOrEmpty($value));MatchesOldCatalog=$value.Equals((RelationText $target[0].root_session_id),[StringComparison]::OrdinalIgnoreCase);MatchesFreshParent=((-not[string]::IsNullOrEmpty($fresh.parent_thread_id)-and$value.Equals($fresh.parent_thread_id,[StringComparison]::OrdinalIgnoreCase))-or(-not[string]::IsNullOrEmpty($fresh.parent_session_id)-and$value.Equals($fresh.parent_session_id,[StringComparison]::OrdinalIgnoreCase)));MatchesFreshExplicitRoot=(-not[string]::IsNullOrEmpty($headerRoot)-and$value.Equals($headerRoot,[StringComparison]::OrdinalIgnoreCase));MatchesFreshRootThread=(-not[string]::IsNullOrEmpty($headerRootThread)-and$value.Equals($headerRootThread,[StringComparison]::OrdinalIgnoreCase));MatchesResolvedChain=($complete-and$value.Equals($canonical,[StringComparison]::OrdinalIgnoreCase));Truncated=($groups.Count-gt32)})
                    $ordinal++
                }
            }
        }
        [pscustomobject]@{Status='relation_metadata_read';ReadOnly=$true;FreshHeader=$freshFacts;Layers=$facts.ToArray();LayerCount=$facts.Count;ChainComplete=$complete;ChainUnique=$unique;Cycle=$cycle;ParentForkConflict=$conflict;MissingAncestorOrIdentity=$missing;DepthLimitReached=$limit;StoredRootsAgreeWithResolvedChain=$rootAgreement;ParentCandidateCount=$candidateTotal;ParentCandidateRelationshipsAgree=$candidateAgreement;ParentCandidates=$parentCandidates.ToArray();ExplicitRootReferences=$rootReferences.ToArray();TargetRootGroups=$rootGroups.ToArray();TargetSessionCounts=$sessionFacts.ToArray();FreshHeaderNotRead=($null-eq$fresh);SourceAuthenticityNotProven=$true}|ConvertTo-Json -Depth 7 -Compress
    }
}catch{
    [pscustomobject]@{Status='read_only_relation_inspection_failed';ErrorType=$_.Exception.GetType().Name;ReadOnly=$true}|ConvertTo-Json -Compress
}finally{
    if($null-ne$db){if($begun){try{RelationCommand 'ROLLBACK'}catch{}};$db.Dispose()}
}
