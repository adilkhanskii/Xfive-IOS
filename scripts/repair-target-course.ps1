[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$TargetCourseId = '892fc2d1-f521-48a2-800f-a90eb9e1a852'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This repair is intentionally pinned to the four rows captured in the
# 2026-07-14 incident snapshot. Never broaden these predicates to course titles:
# a future legitimate course may use the same display name.
$expectedTargetCourseId = '892fc2d1-f521-48a2-800f-a90eb9e1a852'
$sourceCourseId = '4ca8d4bd-69bb-420b-81b3-bad8bd0737e1'
$duplicateCourseIds = @(
    '4ca8d4bd-69bb-420b-81b3-bad8bd0737e1',
    '8f4bf6b8-885a-4824-b91e-1d64921512fc',
    'c02ca43f-6e45-42e7-b500-85fb7e4d0230'
)
$recoveredModuleId = 'mod_1780406663282_0'
$existingModuleId = 'cat_1773850477057'

$parsedTargetId = [Guid]::Empty
if (-not [Guid]::TryParse($TargetCourseId, [ref]$parsedTargetId)) {
    throw 'TargetCourseId must be a UUID.'
}
if ($parsedTargetId -ne [Guid]$expectedTargetCourseId) {
    throw "This incident repair only supports target $expectedTargetCourseId."
}
$TargetCourseId = $expectedTargetCourseId

$repoRoot = Split-Path -Parent $PSScriptRoot
$backupDirectory = Join-Path $repoRoot 'diagnostics/course-repair'
New-Item -ItemType Directory -Force $backupDirectory | Out-Null
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')

function Invoke-LinkedSupabaseQuery {
    param([Parameter(Mandatory = $true)][string]$Sql)

    $npx = (Get-Command npx.cmd -ErrorAction Stop).Source
    # Pass SQL through a temporary file. This preserves dollar-quoted PL/pgSQL
    # blocks and avoids cmd.exe corrupting a long multiline argument.
    $sqlPath = Join-Path ([IO.Path]::GetTempPath()) ("x5-course-repair-{0}.sql" -f [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($sqlPath, $Sql, [Text.UTF8Encoding]::new($false))
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $rawCombined = & $npx --yes supabase@latest db query --linked --file $sqlPath --output json 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $sqlPath -Force -ErrorAction SilentlyContinue
    }
    $ErrorActionPreference = $previousErrorAction
    if ($exitCode -ne 0) {
        $details = ($rawCombined -replace '[\r\n]+', ' ').Trim()
        throw "Supabase query failed with exit code $exitCode. The transaction was not committed. $details"
    }

    $jsonStart = $rawCombined.IndexOf('{')
    if ($jsonStart -lt 0) {
        throw 'Supabase query succeeded but did not return JSON output.'
    }
    $raw = $rawCombined.Substring($jsonStart)
    $parsed = $raw | ConvertFrom-Json
    return @($parsed.rows)
}

function Write-Snapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object[]]$Rows
    )

    $path = Join-Path $backupDirectory "$timestamp-$Name.json"
    $payload = [ordered]@{
        captured_at = (Get-Date).ToUniversalTime().ToString('o')
        project_ref = 'afwznqjpshybmqhlewmy'
        target_course_id = $TargetCourseId
        source_course_id = $sourceCourseId
        duplicate_course_ids = $duplicateCourseIds
        rows = $Rows
    }
    $payload | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding UTF8
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    [PSCustomObject]@{ Path = $path; SHA256 = $hash }
}

function Get-CategoryById {
    param(
        [Parameter(Mandatory = $true)]$Course,
        [Parameter(Mandatory = $true)][string]$CategoryId
    )

    @($Course.categories | Where-Object { $_.id -eq $CategoryId })
}

function Get-VideoUrls {
    param([Parameter(Mandatory = $true)]$Course)

    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($category in @($Course.categories)) {
        foreach ($day in @($category.days)) {
            foreach ($lesson in @($day.lessons)) {
                if ($lesson.videoUrl -and -not [string]::IsNullOrWhiteSpace([string]$lesson.videoUrl)) {
                    $urls.Add([string]$lesson.videoUrl)
                }
            }
        }
    }
    @($urls)
}

$duplicateIdSql = @($duplicateCourseIds | ForEach-Object { "'$_'::uuid" }) -join ', '
$allCourseIdSql = "'$TargetCourseId'::uuid, $duplicateIdSql"
$selectSql = @"
select
  id::text,
  title,
  author_name,
  is_public,
  price,
  created_at,
  updated_at,
  categories
from public.courses
where id in ($allCourseIdSql)
order by created_at, id;
"@

$beforeRows = @(Invoke-LinkedSupabaseQuery -Sql $selectSql)
$expectedIds = @($TargetCourseId) + $duplicateCourseIds
$missingIds = @($expectedIds | Where-Object { $beforeRows.id -notcontains $_ })
if ($beforeRows.Count -ne 4 -or $missingIds.Count -gt 0) {
    throw "Incident row set is incomplete. Missing IDs: $($missingIds -join ', ')"
}

$target = @($beforeRows | Where-Object { $_.id -eq $TargetCourseId }) | Select-Object -First 1
$source = @($beforeRows | Where-Object { $_.id -eq $sourceCourseId }) | Select-Object -First 1
$sourceModules = @(Get-CategoryById -Course $source -CategoryId $recoveredModuleId)
$existingModules = @(Get-CategoryById -Course $target -CategoryId $existingModuleId)
$recoveredModules = @(Get-CategoryById -Course $target -CategoryId $recoveredModuleId)

if ($sourceModules.Count -ne 1) {
    throw "Exact recovery module $recoveredModuleId is missing or duplicated in source $sourceCourseId."
}
if ($existingModules.Count -ne 1) {
    throw "Exact existing module $existingModuleId is missing or duplicated in target."
}
if ($recoveredModules.Count -gt 1) {
    throw "Target contains more than one copy of recovery module $recoveredModuleId."
}
if (@($target.categories).Count -ne (1 + $recoveredModules.Count)) {
    throw 'Target contains unexpected modules; refusing a narrowly scoped incident repair.'
}

$beforeSnapshot = Write-Snapshot -Name 'before' -Rows $beforeRows
$beforeVideoUrls = @(Get-VideoUrls -Course $target)
$targetIsCanonical = (
    @($target.categories).Count -eq 2 -and
    [string]$target.categories[0].id -eq $recoveredModuleId -and
    [int]$target.categories[0].order -eq 1 -and
    [string]$target.categories[1].id -eq $existingModuleId -and
    [int]$target.categories[1].order -eq 2
)
$publicDuplicates = @($beforeRows | Where-Object {
    $duplicateCourseIds -contains [string]$_.id -and $_.is_public -eq $true
})

$plan = [ordered]@{
    mode = if ($Apply) { 'apply' } else { 'dry-run' }
    target_course_id = $TargetCourseId
    source_course_id = $sourceCourseId
    duplicate_course_ids = $duplicateCourseIds
    target_author = $target.author_name
    target_video_count = $beforeVideoUrls.Count
    module_already_present = $recoveredModules.Count -eq 1
    target_order_is_canonical = $targetIsCanonical
    public_duplicates_to_hide = $publicDuplicates.Count
    would_change = (-not $targetIsCanonical) -or $publicDuplicates.Count -gt 0
    before_snapshot = $beforeSnapshot.Path
    before_sha256 = $beforeSnapshot.SHA256
}

if (-not $Apply) {
    $planPath = Join-Path $backupDirectory "$timestamp-dry-run.json"
    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding UTF8
    Write-Output ($plan | ConvertTo-Json -Depth 20)
    Write-Output "Dry run complete. Re-run with -Apply after reviewing $planPath"
    exit 0
}

# Every row lock, mutation, and invariant check is inside this transaction. Any
# missing source/duplicate or failed assertion raises before COMMIT, so PostgreSQL
# rolls the whole repair back. Conditional UPDATE predicates also make retries a
# true no-op: an already repaired row keeps its original updated_at value.
$mutationSql = @"
begin;

do `$repair`$
declare
  v_target_id constant uuid := '$TargetCourseId'::uuid;
  v_source_id constant uuid := '$sourceCourseId'::uuid;
  v_duplicate_ids constant uuid[] := array[$duplicateIdSql];
  v_recovered_module_id constant text := '$recoveredModuleId';
  v_existing_module_id constant text := '$existingModuleId';
  v_before jsonb;
  v_after jsonb;
  v_source_categories jsonb;
  v_source_module jsonb;
  v_recovered_module jsonb;
  v_existing_module jsonb;
  v_desired jsonb;
  v_author_before text;
  v_author_after text;
  v_count integer;
begin
  select categories, author_name
  into v_before, v_author_before
  from public.courses
  where id = v_target_id
  for update;

  if not found then
    raise exception 'target_course_missing:%', v_target_id;
  end if;

  select categories
  into v_source_categories
  from public.courses
  where id = v_source_id
  for update;
  if not found then
    raise exception 'recovery_source_missing:%', v_source_id;
  end if;

  select count(*), (jsonb_agg(category) -> 0)
  into v_count, v_source_module
  from jsonb_array_elements(coalesce(v_source_categories, '[]'::jsonb)) as category
  where category ->> 'id' = v_recovered_module_id;
  if v_count <> 1 or v_source_module is null then
    raise exception 'exact_recovery_module_missing:%:%', v_source_id, v_recovered_module_id;
  end if;

  perform 1
  from public.courses
  where id = any(v_duplicate_ids)
  for update;
  get diagnostics v_count = row_count;
  if v_count <> cardinality(v_duplicate_ids) then
    raise exception 'incident_duplicate_set_incomplete:expected=%,actual=%', cardinality(v_duplicate_ids), v_count;
  end if;

  select count(*)
  into v_count
  from jsonb_array_elements(coalesce(v_before, '[]'::jsonb)) as category
  where category ->> 'id' = v_recovered_module_id;
  if v_count > 1 then
    raise exception 'recovered_module_duplicated_in_target:%', v_count;
  end if;

  select category
  into v_existing_module
  from jsonb_array_elements(coalesce(v_before, '[]'::jsonb)) as category
  where category ->> 'id' = v_existing_module_id;
  if not found then
    raise exception 'existing_module_missing:%', v_existing_module_id;
  end if;

  select category
  into v_recovered_module
  from jsonb_array_elements(coalesce(v_before, '[]'::jsonb)) as category
  where category ->> 'id' = v_recovered_module_id;
  v_recovered_module := coalesce(v_recovered_module, v_source_module);

  if jsonb_array_length(coalesce(v_before, '[]'::jsonb)) <> (case
      when exists (
        select 1
        from jsonb_array_elements(coalesce(v_before, '[]'::jsonb)) as category
        where category ->> 'id' = v_recovered_module_id
      ) then 2
      else 1
    end) then
    raise exception 'unexpected_target_modules';
  end if;

  v_desired := jsonb_build_array(
    jsonb_set(v_recovered_module, '{order}', '1'::jsonb, true),
    jsonb_set(v_existing_module, '{order}', '2'::jsonb, true)
  );

  update public.courses
  set categories = v_desired,
      updated_at = now()
  where id = v_target_id
    and categories is distinct from v_desired;

  update public.courses
  set is_public = false,
      updated_at = now()
  where id = any(v_duplicate_ids)
    and is_public is distinct from false;

  select categories, author_name
  into v_after, v_author_after
  from public.courses
  where id = v_target_id;

  if jsonb_array_length(v_after) <> 2
     or v_after -> 0 ->> 'id' <> v_recovered_module_id
     or v_after -> 0 ->> 'order' <> '1'
     or v_after -> 1 ->> 'id' <> v_existing_module_id
     or v_after -> 1 ->> 'order' <> '2' then
    raise exception 'target_module_order_validation_failed';
  end if;

  if (v_after -> 0) - 'order' is distinct from v_recovered_module - 'order' then
    raise exception 'recovered_module_content_changed';
  end if;
  if (v_after -> 1) - 'order' is distinct from v_existing_module - 'order' then
    raise exception 'existing_module_content_changed';
  end if;
  if v_author_after is distinct from v_author_before then
    raise exception 'author_changed';
  end if;

  select count(*)
  into v_count
  from public.courses
  where id = any(v_duplicate_ids)
    and is_public is false;
  if v_count <> cardinality(v_duplicate_ids) then
    raise exception 'duplicate_visibility_validation_failed:expected=%,actual=%', cardinality(v_duplicate_ids), v_count;
  end if;
end;
`$repair`$;

commit;

select id::text, title, author_name, is_public, price, created_at, updated_at, categories
from public.courses
where id in ($allCourseIdSql)
order by created_at, id;
"@

$afterRows = @(Invoke-LinkedSupabaseQuery -Sql $mutationSql)
$afterSnapshot = Write-Snapshot -Name 'after' -Rows $afterRows
$afterTarget = @($afterRows | Where-Object { $_.id -eq $TargetCourseId }) | Select-Object -First 1
if (-not $afterTarget) {
    throw 'Post-repair target verification failed: target row missing.'
}

$afterRecoveredModules = @(Get-CategoryById -Course $afterTarget -CategoryId $recoveredModuleId)
$afterExistingModules = @(Get-CategoryById -Course $afterTarget -CategoryId $existingModuleId)
if (@($afterTarget.categories).Count -ne 2 -or
    $afterRecoveredModules.Count -ne 1 -or
    $afterExistingModules.Count -ne 1 -or
    [string]$afterTarget.categories[0].id -ne $recoveredModuleId -or
    [int]$afterTarget.categories[0].order -ne 1 -or
    [string]$afterTarget.categories[1].id -ne $existingModuleId -or
    [int]$afterTarget.categories[1].order -ne 2) {
    throw 'Post-repair target verification failed: expected exact modules with deterministic orders 1 and 2.'
}
if ([string]$afterTarget.author_name -ne [string]$target.author_name) {
    throw 'Post-repair target verification failed: author changed.'
}

$afterVideoUrls = @(Get-VideoUrls -Course $afterTarget)
foreach ($url in $beforeVideoUrls) {
    if ($afterVideoUrls -notcontains $url) {
        throw 'Post-repair target verification failed: an existing video URL was lost.'
    }
}

$afterDuplicates = @($afterRows | Where-Object { $duplicateCourseIds -contains [string]$_.id })
$stillPublic = @($afterDuplicates | Where-Object { $_.is_public -ne $false })
if ($afterDuplicates.Count -ne 3 -or $stillPublic.Count -gt 0) {
    throw 'Post-repair verification failed: the exact incident duplicate set is missing or still public.'
}

$result = [ordered]@{
    status = if ($plan.would_change) { 'repaired' } else { 'already_repaired' }
    target_course_id = $TargetCourseId
    categories = @($afterTarget.categories).Count
    module_orders = @($afterTarget.categories.order)
    preserved_video_urls = $beforeVideoUrls.Count
    hidden_duplicates = $afterDuplicates.Count
    before_snapshot = $beforeSnapshot.Path
    before_sha256 = $beforeSnapshot.SHA256
    after_snapshot = $afterSnapshot.Path
    after_sha256 = $afterSnapshot.SHA256
}
Write-Output ($result | ConvertTo-Json -Depth 20)
