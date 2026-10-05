[CmdletBinding()]
param([string]$ProjectRoot = '', [switch]$ReadOnlyStructureAuthorized)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$db = $null
try {
    if (-not $ReadOnlyStructureAuthorized) { throw [InvalidOperationException]::new('Explicit scoped read-only authorization is required.') }
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
    $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
    Add-Type -Path (Join-Path $ProjectRoot 'indexer/System.Data.SQLite.dll')
    Add-Type -Path (Join-Path $ProjectRoot 'indexer/TokenRader.Indexer.dll')
    $scanType = [TokenRaderIndexer].GetNestedType('SafeOversizedBodyScan', [Reflection.BindingFlags]::NonPublic)
    if ($null -eq $scanType) { throw [InvalidOperationException]::new('Production scanner unavailable.') }
    if ($null -eq ('TokenRaderBlockedInspection.Scanner' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
using System.Collections.Generic;
using System.Text;
namespace TokenRaderBlockedInspection {
 public sealed class Finding {
  public bool Found; public long Length; public bool Terminated;
  public string RootType, PayloadType, ItemType, RootFields, PayloadFields, ItemFields;
  public int UnknownRootFields, UnknownPayloadFields, UnknownItemFields;
  public bool LexicalProjectionIncomplete; public bool InBlockedGap;
  public string LatestUsageRecordFields, UsageFields, ThreadUsageFields, TurnUsageFields;
  public bool LatestUsageRecordFieldPresent;
  public int UsageFieldMask, ThreadUsageFieldMask, TurnUsageFieldMask;
  public string UnknownRootFieldsDetail, UnknownPayloadFieldsDetail, UnknownItemFieldsDetail;
  public string ParsedCommandFields, ParsedCommandTypes, ParsedCommandFieldValueTypes, CommandFirstFailure, ToolOutputFirstFailure;
  public string OutputItemTypes, OutputItemFieldValueTypes;
 }
 internal sealed class Frame { public int Scope; public bool Object, ExpectKey, ValuePending; public string Key=""; }
 internal sealed class Projection {
  static readonly HashSet<string> Fields = new HashSet<string>(new[] {
   "type","timestamp","ordinal","payload","item","id","call_id","name","status","output","arguments",
   "model","service_tier","turn_id","reasoning_effort","info","response","content","role","phase","text","end_turn","recipient",
   "cwd","command","process_id","source","exit_code","duration","stdout","stderr","aggregated_output","formatted_output","parsed_cmd",
   "thread_id","started_at_ms","completed_at_ms","developer_instructions","user_instructions","instructions","tools","sandbox_policy","approval_policy",
   "collaboration_mode","settings","model_context_window","personality","effort","summary","encrypted_content",
   "compaction_response_id","first_window_id","latest_token_usage_record","message","previous_window_id","replacement_history",
   "replacement_history_metadata","resume_metadata","retained_context","window_id","window_number",
   "response_id","root_turn_id","session_id","thread_token_usage","turn_token_usage","usage",
   "input_tokens","cached_input_tokens","output_tokens","reasoning_output_tokens","total_tokens","cache_write_input_tokens"
  },StringComparer.Ordinal);
  static readonly HashSet<string> Types = new HashSet<string>(new[] {
   "response_item","message","event_msg","item_completed","CommandExecution","compacted","turn_context","token_count",
   "session_meta","function_call","function_call_output","custom_tool_call","custom_tool_call_output","reasoning",
   "agent_message","user_message","task_started","task_complete","input_text","output_text","text","input_image",
   "shell_call","shell_call_output","mcp_call","web_search_call","image_generation_call","computer_call","code_interpreter_call"
  },StringComparer.Ordinal);
  readonly List<Frame> frames=new List<Frame>();
  readonly SortedSet<string>[] names={new SortedSet<string>(),new SortedSet<string>(),new SortedSet<string>(),new SortedSet<string>(),new SortedSet<string>(),new SortedSet<string>(),new SortedSet<string>(),new SortedSet<string>(),new SortedSet<string>(),new SortedSet<string>(),new SortedSet<string>()};
  readonly SortedDictionary<string,string>[] extra={new SortedDictionary<string,string>(),new SortedDictionary<string,string>(),new SortedDictionary<string,string>(),new SortedDictionary<string,string>(),new SortedDictionary<string,string>(),new SortedDictionary<string,string>(),new SortedDictionary<string,string>(),new SortedDictionary<string,string>(),new SortedDictionary<string,string>(),new SortedDictionary<string,string>(),new SortedDictionary<string,string>()};
  readonly int[] unknown=new int[11]; readonly string[] types={"<absent>","<absent>","<absent>"};
  readonly SortedSet<string> parsedTypes=new SortedSet<string>();
  readonly SortedSet<string> outputTypes=new SortedSet<string>();
  readonly StringBuilder token=new StringBuilder(128);
  bool quoted,escape,capture,keyString,overflow,escaped; int stringScope;
  public bool Failed;
  public void Feed(int b) {
   if(quoted) {
    if(escape) { escape=false; escaped=true; return; }
    if(b=='\\') { escape=true; escaped=true; return; }
    if(b=='"') {
     quoted=false;
     if(capture && stringScope>0) {
      string value=overflow||escaped ? "" : token.ToString(); Frame f=frames[frames.Count-1];
      if(keyString) { f.Key=Identifier(value)?value:""; if(Fields.Contains(value))names[stringScope-1].Add(value);else {unknown[stringScope-1]++;if(f.Key.Length>0&&(extra[stringScope-1].Count<64||extra[stringScope-1].ContainsKey(f.Key)))extra[stringScope-1][f.Key]="<unobserved>";} f.ExpectKey=false; }
      else if(stringScope==9)parsedTypes.Add(value=="read"||value=="list_files"||value=="search"?value:"unknown");
      else if(stringScope==11)outputTypes.Add(Types.Contains(value)?value:"<unknown-or-escaped>");
      else types[stringScope-1]=Types.Contains(value)?value:"<unknown-or-escaped>";
     } else if(keyString && frames.Count>0) { frames[frames.Count-1].Key=""; frames[frames.Count-1].ExpectKey=false; }
     token.Clear(); return;
    }
    if(capture && !overflow) { if(b<32||b>126||token.Length>=128){overflow=true;token.Clear();} else token.Append((char)b); }
    return;
   }
   if(frames.Count>0) {
    Frame pending=frames[frames.Count-1];
    if(pending.ValuePending&&b!=32&&b!=9&&b!=13&&b!=10) {
     pending.ValuePending=false;
     string kind=b=='"'?"string":b=='{'?"object":b=='['?"array":b=='n'?"null":b=='t'||b=='f'?"bool":b=='-'||b>='0'&&b<='9'?"number":"unknown";
     if(pending.Scope>0&&pending.Key.Length>0&&(extra[pending.Scope-1].ContainsKey(pending.Key)||extra[pending.Scope-1].Count<64))extra[pending.Scope-1][pending.Key]=kind;
    }
   }
   if(b=='"') {
    quoted=true;escape=overflow=escaped=false;token.Clear(); Frame f=frames.Count>0?frames[frames.Count-1]:null;
    keyString=f!=null&&f.Object&&f.ExpectKey;stringScope=f==null?0:f.Scope;
    capture=stringScope>0&&(keyString||(stringScope<=3||stringScope==9||stringScope==11)&&f.Key=="type");return;
   }
   if(b=='{'||b=='[') {
    if(frames.Count>=256){Failed=true;return;}
    Frame parent=frames.Count>0?frames[frames.Count-1]:null;
    int scope=frames.Count==0&&b=='{'?1:parent!=null&&parent.Scope==1&&parent.Key=="payload"&&b=='{'?2:parent!=null&&parent.Scope==2&&parent.Key=="item"&&b=='{'?3:parent!=null&&parent.Scope==2&&parent.Key=="latest_token_usage_record"&&b=='{'?4:parent!=null&&parent.Scope==4&&parent.Key=="usage"&&b=='{'?5:parent!=null&&parent.Scope==4&&parent.Key=="thread_token_usage"&&b=='{'?6:parent!=null&&parent.Scope==4&&parent.Key=="turn_token_usage"&&b=='{'?7:0;
    if(parent!=null&&parent.Scope==3&&parent.Key=="parsed_cmd"&&b=='[')scope=8;
    else if(parent!=null&&parent.Scope==8&&b=='{')scope=9;
    else if(parent!=null&&parent.Scope==2&&parent.Key=="output"&&b=='[')scope=10;
    else if(parent!=null&&parent.Scope==10&&b=='{')scope=11;
    frames.Add(new Frame{Scope=scope,Object=b=='{',ExpectKey=b=='{'});return;
   }
   if(b=='}'||b==']'){if(frames.Count>0)frames.RemoveAt(frames.Count-1);else Failed=true;return;}
   if(b==':'&&frames.Count>0){frames[frames.Count-1].ValuePending=true;return;}
   if(b==','&&frames.Count>0){Frame f=frames[frames.Count-1];f.Key="";f.ExpectKey=f.Object;}
  }
  public void Copy(Finding f) {
   f.RootType=types[0];f.PayloadType=types[1];f.ItemType=types[2];
   f.RootFields=string.Join(",",names[0]);f.PayloadFields=string.Join(",",names[1]);f.ItemFields=string.Join(",",names[2]);
   f.UnknownRootFields=unknown[0];f.UnknownPayloadFields=unknown[1];f.UnknownItemFields=unknown[2];
   f.LatestUsageRecordFieldPresent=names[1].Contains("latest_token_usage_record");
   f.LatestUsageRecordFields=string.Join(",",names[3]);f.UsageFields=string.Join(",",names[4]);
   f.ThreadUsageFields=string.Join(",",names[5]);f.TurnUsageFields=string.Join(",",names[6]);
   f.UsageFieldMask=UsageMask(names[4]);f.ThreadUsageFieldMask=UsageMask(names[5]);f.TurnUsageFieldMask=UsageMask(names[6]);
   f.UnknownRootFieldsDetail=Details(extra[0]);f.UnknownPayloadFieldsDetail=Details(extra[1]);f.UnknownItemFieldsDetail=Details(extra[2]);
   f.ParsedCommandFields=string.Join(",",names[8]);f.ParsedCommandTypes=string.Join(",",parsedTypes);f.ParsedCommandFieldValueTypes=Details(extra[8]);
   f.OutputItemTypes=string.Join(",",outputTypes);f.OutputItemFieldValueTypes=Details(extra[10]);
   // This is only a lexical field/type projection. Production Complete is
   // the strict validator; false here is NOT proof of valid JSON/schema.
   f.LexicalProjectionIncomplete=Failed||quoted||frames.Count!=0;
  }
  static bool Identifier(string value) {
   if(value.Length==0||value.Length>64)return false;
   for(int i=0;i<value.Length;i++){char c=value[i];if(c!='_'&&!(c>='A'&&c<='Z')&&!(c>='a'&&c<='z')&&!(i>0&&c>='0'&&c<='9'))return false;}
   return true;
  }
  static string Details(SortedDictionary<string,string> values) {List<string> result=new List<string>();foreach(KeyValuePair<string,string> entry in values)result.Add(entry.Key+":"+entry.Value);return string.Join(",",result);}
  static int UsageMask(SortedSet<string> fields) {
   string[] keys={"input_tokens","cached_input_tokens","output_tokens","reasoning_output_tokens","total_tokens","cache_write_input_tokens"};
   int mask=0;for(int i=0;i<keys.Length;i++)if(fields.Contains(keys[i]))mask|=1<<i;return mask;
  }
 }
 internal sealed class CommandTrace {
  readonly int[] s;readonly string[][] keys;readonly int frameBase; public string Failure="<none>";
  public CommandTrace(object combined,string scannerField="command",int frameBase=12) {
   this.frameBase=frameBase;
   object command=combined.GetType().GetField(scannerField,BindingFlags.Instance|BindingFlags.NonPublic).GetValue(combined);
   s=(int[])command.GetType().GetField("s",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(command);
   keys=(string[][])command.GetType().GetField("Keys",BindingFlags.Static|BindingFlags.NonPublic).GetValue(null);
  }
  public void Observe(int b) {
   if(Failure!="<none>"||s[0]==0)return;
   int depth=s[1],frame=depth>0?frameBase+(depth-1)*4:-1;
   int kind=frame>=0&&frame+3<s.Length?s[frame]:0,stage=frame>=0&&frame+3<s.Length?s[frame+1]:0,key=frame>=0&&frame+3<s.Length?s[frame+3]:-1;
   string field=kind>=0&&kind<keys.Length&&key>0&&key<=keys[kind].Length?keys[kind][key-1]:"<none>";
   string category=b==32||b==9||b==13||b==10?"whitespace":b=='-'||b>='0'&&b<='9'?"number":b=='{'||b=='}'||b=='['||b==']'||b==':'||b==','||b=='"'?"punctuation":"string";
   Failure="Depth="+depth+",FrameKind="+kind+",KeyIndex="+key+",Field="+field+",Stage="+stage+",Mode="+s[3]+",CharacterClass="+category;
  }
 }
 public static class Scanner {
  public static Finding Inspect(string path,Type scannerType,long gapStart,long gapEnd) {
   ConstructorInfo ctor=scannerType.GetConstructor(BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic,null,Type.EmptyTypes,null);
   MethodInfo feedMethod=scannerType.GetMethod("Feed",BindingFlags.Instance|BindingFlags.Public);
   PropertyInfo complete=scannerType.GetProperty("Complete",BindingFlags.Instance|BindingFlags.Public);
   if(ctor==null||feedMethod==null||complete==null)throw new InvalidOperationException();
   object state=ctor.Invoke(null); Action<int> feed=(Action<int>)Delegate.CreateDelegate(typeof(Action<int>),state,feedMethod);
   Projection projection=new Projection();CommandTrace trace=new CommandTrace(state),outputTrace=new CommandTrace(state,"toolOutput",14);long length=0,lineStart=0,position=0;bool previousCR=false;
   byte[] buffer=new byte[65536];
   using(FileStream stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
    int count;while(position<gapEnd&&(count=stream.Read(buffer,0,(int)Math.Min(buffer.Length,gapEnd-position)))>0) for(int i=0;i<count;i++) {
     int b=buffer[i];position++;if(previousCR&&b==10){previousCR=false;lineStart=position;continue;}previousCR=false;
     if(b==10||b==13) {
      Finding finding=new Finding{Length=length,Terminated=true,InBlockedGap=lineStart<gapEnd&&position>gapStart,CommandFirstFailure=trace.Failure,ToolOutputFirstFailure=outputTrace.Failure};projection.Copy(finding);
      bool accepted=(bool)complete.GetValue(state,null);
      if(finding.InBlockedGap&&(length>1048576&&!accepted || finding.RootType=="compacted"&&!accepted)) {finding.Found=true;return finding;}
      state=ctor.Invoke(null);feed=(Action<int>)Delegate.CreateDelegate(typeof(Action<int>),state,feedMethod);
      projection=new Projection();trace=new CommandTrace(state);outputTrace=new CommandTrace(state,"toolOutput",14);length=0;lineStart=position;previousCR=b==13;continue;
     }
     length++;feed(b);trace.Observe(b);outputTrace.Observe(b);projection.Feed(b);
    }
   }
   Finding tail=new Finding{Length=length,Terminated=false,InBlockedGap=lineStart<gapEnd&&position>gapStart,CommandFirstFailure=trace.Failure,ToolOutputFirstFailure=outputTrace.Failure};projection.Copy(tail);
   if(tail.InBlockedGap&&(length>1048576||tail.RootType=="compacted"))tail.Found=true;
   return tail;
  }
 }
}
'@
    }
    $dbPath = Join-Path $ProjectRoot 'data/private/index/index.db'
    $db = [System.Data.SQLite.SQLiteConnection]::new(('Data Source="{0}";Version=3;Read Only=True;FailIfMissing=True;Pooling=False;' -f $dbPath))
    $db.Open()
    $cmd = $db.CreateCommand()
    try {
        $cmd.CommandText = 'PRAGMA query_only=ON;'
        [void]$cmd.ExecuteNonQuery()
        # Only two distinct oversized representatives, smallest metadata sizes
        # first. A source-replaced sample is metadata-only and never scanned.
        $cmd.CommandText = "SELECT g.path,COALESCE(f.length,-1) AS length,MIN(g.start_offset),MAX(g.end_offset) FROM recent_history_work g LEFT JOIN file_metadata f ON f.path=g.path WHERE g.blocked_reason='oversized_line' GROUP BY g.path ORDER BY CASE WHEN f.length IS NULL THEN 1 ELSE 0 END,f.length,g.path LIMIT 2"
        $samples = New-Object 'System.Collections.Generic.List[object]'
        $reader = $cmd.ExecuteReader()
        try { while ($reader.Read()) { $samples.Add([pscustomobject]@{ Path=[string]$reader.GetValue(0); Length=[long]$reader.GetValue(1); GapStart=[long]$reader.GetValue(2); GapEnd=[long]$reader.GetValue(3) }) } }
        finally { $reader.Dispose() }
        $number = 0
        foreach ($sample in $samples) {
            $number++
            try {
                $finding = [TokenRaderBlockedInspection.Scanner]::Inspect($sample.Path,$scanType,$sample.GapStart,$sample.GapEnd)
                Write-Host ('Sample={0}; Status=oversized_line; FileLength={1}; FoundRejectedRecord={2}; RecordLength={3}; Terminated={4}; RootType={5}; PayloadType={6}; ItemType={7}; RootFields=[{8}]; PayloadFields=[{9}]; ItemFields=[{10}]; UnknownFieldCounts={11}/{12}/{13}; LexicalProjectionIncomplete={14}; InBlockedGap={15}; ProjectionIsValidation=False' -f $number,$sample.Length,$finding.Found,$finding.Length,$finding.Terminated,$finding.RootType,$finding.PayloadType,$finding.ItemType,$finding.RootFields,$finding.PayloadFields,$finding.ItemFields,$finding.UnknownRootFields,$finding.UnknownPayloadFields,$finding.UnknownItemFields,$finding.LexicalProjectionIncomplete,$finding.InBlockedGap)
                Write-Host ('Sample={0}; RootFieldValueTypes=[{1}]; PayloadFieldValueTypes=[{2}]; ItemFieldValueTypes=[{3}]; ParsedCommandFields=[{4}]; ParsedCommandTypes=[{5}]; ParsedCommandFieldValueTypes=[{6}]; CommandFirstFailure=[{7}]' -f $number,$finding.UnknownRootFieldsDetail,$finding.UnknownPayloadFieldsDetail,$finding.UnknownItemFieldsDetail,$finding.ParsedCommandFields,$finding.ParsedCommandTypes,$finding.ParsedCommandFieldValueTypes,$finding.CommandFirstFailure)
                Write-Host ('Sample={0}; ToolOutputFirstFailure=[{1}]' -f $number,$finding.ToolOutputFirstFailure)
                Write-Host ('Sample={0}; OutputItemTypes=[{1}]; OutputItemFieldValueTypes=[{2}]' -f $number,$finding.OutputItemTypes,$finding.OutputItemFieldValueTypes)
                if ($finding.RootType -eq 'compacted') {
                    Write-Host ('Sample={0}; LatestUsageRecordFieldPresent={1}; LatestUsageRecordFields=[{2}]; UsageFields=[{3}]; ThreadUsageFields=[{4}]; TurnUsageFields=[{5}]; UsageFieldPresenceMasks={6}/{7}/{8}; MaskBits=input,cached,output,reasoning,total,cache_write; PresenceIsValidation=False' -f $number,$finding.LatestUsageRecordFieldPresent,$finding.LatestUsageRecordFields,$finding.UsageFields,$finding.ThreadUsageFields,$finding.TurnUsageFields,$finding.UsageFieldMask,$finding.ThreadUsageFieldMask,$finding.TurnUsageFieldMask)
                }
            } catch { Write-Host ('Sample={0}; Status=inspection_failed; ExceptionType={1}' -f $number,$_.Exception.GetType().FullName) }
        }
        $cmd.CommandText = "SELECT g.path,COALESCE(f.length,-1) FROM (SELECT path FROM recent_history_work WHERE blocked_reason='source_replaced' UNION SELECT path FROM history_gaps WHERE blocked_reason='source_replaced') g LEFT JOIN file_metadata f ON f.path=g.path ORDER BY CASE WHEN f.length IS NULL THEN 1 ELSE 0 END,f.length,g.path LIMIT 1"
        $reader = $cmd.ExecuteReader()
        $replacedPath = $null
        try {
            if ($reader.Read()) {
                $number++
                $replacedPath = [string]$reader.GetValue(0)
                $currentLength = -1L
                try { $currentLength = ([IO.FileInfo]::new($replacedPath)).Length } catch { }
                Write-Host ('Sample={0}; Status=source_replaced; IndexedLength={1}; CurrentLength={2}; StructureScanned=False; RepairAttempted=False' -f $number,[long]$reader.GetValue(1),$currentLength)
            }
        } finally { $reader.Dispose() }
        if ($null -ne $replacedPath) {
            $createdTicks = 0L
            try { $createdTicks = [IO.File]::GetCreationTimeUtc($replacedPath).Ticks } catch { }
            $cmd.CommandText = "SELECT 'recent' AS ledger,body_scan_state FROM recent_history_work WHERE path=@path UNION ALL SELECT 'gap',body_scan_state FROM history_gaps WHERE path=@path AND blocked_reason='source_replaced' LIMIT 2"
            [void]$cmd.Parameters.AddWithValue('@path',$replacedPath)
            $reader = $cmd.ExecuteReader()
            try {
                while ($reader.Read()) {
                    $state = [string]$reader.GetValue(1)
                    $parts = $state.Split('|')
                    $knownProtocol = $parts.Length -eq 3 -and $parts[0] -in @('2','3','4','5')
                    $storedTicks = 0L
                    $storedTicksValid = $parts.Length -eq 3 -and [long]::TryParse($parts[1],[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$storedTicks) -and $storedTicks -gt 0
                    $ticksEqual = $storedTicksValid -and $createdTicks -gt 0 -and $storedTicks -eq $createdTicks
                    Write-Host ('Sample={0}; Ledger={1}; BodyStateEmpty={2}; BodyStateLength={3}; KnownProtocol={4}; StateWithinProductionLimit={5}; StoredCreationValid={6}; StoredCreationMatchesCurrent={7}; ProductionSourceMatchConditions={8}' -f $number,[string]$reader.GetValue(0),[string]::IsNullOrEmpty($state),$state.Length,$knownProtocol,($state.Length -le 600),$storedTicksValid,$ticksEqual,($knownProtocol -and $state.Length -gt 0 -and $state.Length -le 600 -and $ticksEqual))
                }
            } finally { $reader.Dispose() }
        }
    } finally { $cmd.Dispose() }
} catch { Write-Host ('Status=inspection_setup_failed; ExceptionType={0}' -f $_.Exception.GetType().FullName) }
finally { if ($null -ne $db) { try { $db.Close();$db.Dispose() } catch { } } }
