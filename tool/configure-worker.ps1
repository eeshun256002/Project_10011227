$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$cli = Join-Path $projectRoot 'tool\backend\node_modules\.bin\supabase.cmd'
if (!(Test-Path -LiteralPath $cli)) { throw 'Run npm ci --prefix tool/backend first.' }
$urlLine = Get-Content -LiteralPath (Join-Path $projectRoot '.env') | Where-Object { $_ -match '^SUPABASE_URL=' } | Select-Object -First 1
$projectUrl = (($urlLine -split '=', 2)[1]).Trim().Trim('"').Trim("'").TrimEnd('/')
$ref = ([Uri]$projectUrl).Host.Split('.')[0]
$linkedRef = (Get-Content -LiteralPath (Join-Path $projectRoot 'supabase\.temp\project-ref') -Raw).Trim()
if ($ref -ne $linkedRef -or $projectUrl -notmatch '^https://[a-z0-9]+\.supabase\.co$') { throw 'App and linked Supabase project do not match.' }
$envFile = Join-Path $projectRoot '.env.server'
if (!(Test-Path -LiteralPath $envFile)) {
  $randomBytes = New-Object byte[] 48
  $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $generator.GetBytes($randomBytes) } finally { $generator.Dispose() }
  $workerToken = [Convert]::ToBase64String($randomBytes)
  [System.IO.File]::WriteAllText($envFile, "# Server only. Never pass this file to Flutter.`nWM_WORKER_SECRET=$workerToken`n")
} else {
  $secretLine = Get-Content -LiteralPath $envFile | Where-Object { $_ -match '^WM_WORKER_SECRET=' } | Select-Object -First 1
  if (!$secretLine) { throw 'Existing .env.server has no WM_WORKER_SECRET. Set a random value of at least 32 characters locally.' }
  $workerToken = (($secretLine -split '=', 2)[1]).Trim().Trim('"').Trim("'")
}
if ($workerToken.Length -lt 32) { throw 'Worker secret must be at least 32 characters.' }
# No credentials are passed as command-line arguments or printed.
& $cli secrets set --env-file $envFile --project-ref $ref
if ($LASTEXITCODE -ne 0) { throw 'Edge Function secret configuration failed.' }
$sql = @'
do $body$
declare existing uuid;
begin
 select id into existing from vault.secrets where name='wm_worker_secret';
 if existing is null then perform vault.create_secret('TOKEN_VALUE','wm_worker_secret');
 else perform vault.update_secret(existing,'TOKEN_VALUE'); end if;
 select id into existing from vault.secrets where name='wm_worker_url';
 if existing is null then perform vault.create_secret('URL_VALUE/functions/v1/wm-worker','wm_worker_url');
 else perform vault.update_secret(existing,'URL_VALUE/functions/v1/wm-worker'); end if;
end $body$;
select true as worker_credentials_configured;
'@
$sql = $sql.Replace('TOKEN_VALUE', $workerToken.Replace("'", "''")).Replace('URL_VALUE', $projectUrl)
$queryFile = Join-Path $projectRoot 'supabase\.temp\worker-vault.sql'
try {
  [System.IO.File]::WriteAllText($queryFile, $sql)
  & $cli db query --linked --workdir $projectRoot --file $queryFile
  if ($LASTEXITCODE -ne 0) { throw 'Vault configuration failed.' }
} finally {
  if (Test-Path -LiteralPath $queryFile) { Remove-Item -LiteralPath $queryFile }
}
Write-Output 'Worker credentials configured. Bookings and transport rates were not changed.'
