# Le grandi aziende USA che scendono di piu'. A ogni giro legge il prezzo delle circa 100 piu' grandi (S&P 100, in aziende-lista.json)
# dall'API ufficiale di Finnhub (chiave gratuita in FINNHUB_KEY), tiene lo storico delle chiusure e scrive aziende.json con le 10 peggiori
# dell'ultima seduta, degli ultimi 7 giorni e degli ultimi 30, ognuna con le ultime notizie (titolo, fonte, link).
# Solo dati pubblici di mercato: niente dati personali. Non e' un consiglio: chi scende tanto puo' continuare a scendere.
# Uso:  pwsh ./aziende.ps1 -Uscita ./site   [-Lista ./aziende-lista.json] [-Base https://finnhub.io/api/v1] [-SoloProva]
param([string]$Uscita = './site', [string]$Lista = './aziende-lista.json', [string]$Base = 'https://finnhub.io/api/v1', [switch]$SoloProva, [int]$Pausa = 1100)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$key = $env:FINNHUB_KEY
if (-not $key) { "Nessuna FINNHUB_KEY: niente classifica delle aziende (resta il file di prima)."; return }
$inv = [Globalization.CultureInfo]::InvariantCulture
$tz = [TimeZoneInfo]::FindSystemTimeZoneById($(if ($IsLinux -or $IsMacOS) { 'America/New_York' } else { 'Eastern Standard Time' }))
function TradeDate($t) { if (-not $t) { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd') }; [TimeZoneInfo]::ConvertTimeFromUtc([DateTimeOffset]::FromUnixTimeSeconds([long]$t).UtcDateTime, $tz).ToString('yyyy-MM-dd') }
function JStr([string]$s) { '"' + (((($s -replace '\\', '\\') -replace '"', '\"') -replace "`r?`n", ' ') -replace '[\x00-\x1f]', ' ') + '"' }
function ToJson($o) {
  if ($null -eq $o) { return 'null' }
  if ($o -is [string]) { return (JStr $o) }
  if ($o -is [double] -or $o -is [int] -or $o -is [long] -or $o -is [decimal]) { return ([double]$o).ToString('R', $inv) }
  if ($o -is [bool]) { return $(if ($o) { 'true' } else { 'false' }) }
  if ($o -is [System.Collections.IDictionary]) { return '{' + (($o.Keys | ForEach-Object { (JStr ([string]$_)) + ':' + (ToJson $o[$_]) }) -join ',') + '}' }
  if ($o -is [System.Collections.IEnumerable]) { return '[' + ((@($o) | ForEach-Object { ToJson $_ }) -join ',') + ']' }
  return (JStr ([string]$o))
}
function Get-Api($path) {          # con pausa tra le chiamate: il piano gratuito permette 60 chiamate al minuto
  for ($k = 0; $k -lt 3; $k++) {
    Start-Sleep -Milliseconds $Pausa
    try { return Invoke-RestMethod -Uri ($Base + $path + '&token=' + $key) -TimeoutSec 30 }
    catch { $m = $_.Exception.Message -replace [regex]::Escape($key), '***'; if ($m -match '429') { Start-Sleep -Seconds 20 } elseif ($k -eq 2) { throw $m } }
  }
}

$L = (Get-Content $Lista -Raw -Encoding UTF8 | ConvertFrom-Json).aziende
$stFile = Join-Path $Uscita 'aziende-storico.csv'; $hist = @{}
if (Test-Path $stFile) { foreach ($riga in (Get-Content $stFile -Encoding UTF8 | Select-Object -Skip 1)) { $p = $riga.Split(';'); if ($p.Count -ge 3) { if (-not $hist[$p[1]]) { $hist[$p[1]] = @{} }; $hist[$p[1]][$p[0]] = [double]::Parse($p[2], $inv) } } }

$q = New-Object Collections.Generic.List[object]; $fail = New-Object Collections.Generic.List[string]
foreach ($a in $L) {
  try {
    $r = Get-Api ('/quote?symbol=' + [Uri]::EscapeDataString($a.ticker))
    if (-not ([double]$r.c -gt 0) -or -not ([double]$r.pc -gt 0)) { $fail.Add($a.ticker); continue }
    $d = TradeDate $r.t
    if (-not $hist[$a.ticker]) { $hist[$a.ticker] = @{} }; $hist[$a.ticker][$d] = [double]$r.c
    $q.Add([pscustomobject]@{ ticker = $a.ticker; nome = $a.nome; settore = $a.settore; prezzo = [double]$r.c; giorno = [double]$r.c / [double]$r.pc - 1; data = $d })
  } catch { $fail.Add($a.ticker) }
}
if ($q.Count -lt 20) { "Lette solo $($q.Count) aziende su $($L.Count): file non aggiornato."; exit 1 }

function Since($tk, $days) {          # variazione dall'ultima chiusura salvata che sia almeno "days" giorni prima
  $h = $hist[$tk]; if (-not $h) { return $null }
  $ds = @($h.Keys | Sort-Object); $last = $ds[-1]; $lim = ([datetime]::ParseExact($last, 'yyyy-MM-dd', $inv)).AddDays(-$days).ToString('yyyy-MM-dd')
  $ref = @($ds | Where-Object { $_ -le $lim }); if (-not $ref.Count) { return $null }
  $h[$last] / $h[$ref[-1]] - 1
}
foreach ($x in $q) { $x | Add-Member settimana (Since $x.ticker 7); $x | Add-Member mese (Since $x.ticker 30) }
function Worst($field) { @($q | Where-Object { $null -ne $_.$field -and $_.$field -lt 0 } | Sort-Object $field | Select-Object -First 10) }
$G = Worst 'giorno'; $W = Worst 'settimana'; $M = Worst 'mese'

# notizie: per ogni azienda in classifica, le piu' recenti del periodo piu' lungo in cui compare
$per = @{}; foreach ($x in $G) { $per[$x.ticker] = 4 }; foreach ($x in $W) { $per[$x.ticker] = [Math]::Max(9, [int]$per[$x.ticker]) }; foreach ($x in $M) { $per[$x.ticker] = 31 }
$oggi = (Get-Date).ToUniversalTime(); $news = [ordered]@{}
foreach ($tk in $per.Keys) {
  try {
    $n = Get-Api ('/company-news?symbol=' + [Uri]::EscapeDataString($tk) + '&from=' + $oggi.AddDays(-$per[$tk]).ToString('yyyy-MM-dd') + '&to=' + $oggi.ToString('yyyy-MM-dd'))
    $news[$tk] = @(@($n) | Where-Object { $_.headline -and $_.url } | Sort-Object datetime -Descending | Select-Object -First 3 | ForEach-Object {
      [ordered]@{ titolo = [string]$_.headline; fonte = [string]$_.source; link = [string]$_.url; data = [DateTimeOffset]::FromUnixTimeSeconds([long]$_.datetime).UtcDateTime.ToString('yyyy-MM-ddTHH:mmZ'); sintesi = $(if ($_.summary) { ([string]$_.summary).Substring(0, [Math]::Min(240, ([string]$_.summary).Length)) } else { '' }) } })
  } catch { $news[$tk] = @() }
}
$row = { param($x) [ordered]@{ ticker = $x.ticker; nome = $x.nome; settore = $x.settore; prezzo = [Math]::Round($x.prezzo, 2); giorno_pct = [Math]::Round($x.giorno * 100, 2); settimana_pct = $(if ($null -ne $x.settimana) { [Math]::Round($x.settimana * 100, 2) } else { $null }); mese_pct = $(if ($null -ne $x.mese) { [Math]::Round($x.mese * 100, 2) } else { $null }); data = $x.data } }
$giorni = @($hist.Values | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
$out = [ordered]@{
  app = 'finanze-aziende'; versione = 1; generato = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); universo = 'S&P 100 (circa le 100 piu grandi aziende USA)'
  lette = $q.Count; non_lette = $fail.Count; giorni_di_storico = $giorni; seduta = (@($q | ForEach-Object { $_.data } | Sort-Object))[-1]
  giorno = @($G | ForEach-Object { & $row $_ }); settimana = @($W | ForEach-Object { & $row $_ }); mese = @($M | ForEach-Object { & $row $_ }); notizie = $news
  nota = 'Prezzi e notizie da Finnhub. Le liste a 7 e 30 giorni si riempiono man mano che si accumula lo storico. Non sono consigli: un titolo che scende molto puo continuare a scendere.'
}
$json = ToJson $out
$null = $json | ConvertFrom-Json          # controllo: deve essere JSON valido
"{0}: lette {1} su {2} (non lette {3}) | peggiori oggi: {4}" -f $out.generato, $q.Count, $L.Count, $fail.Count, (($G | Select-Object -First 3 | ForEach-Object { $_.ticker + ' ' + [Math]::Round($_.giorno * 100, 1) + '%' }) -join ', ')
if ($SoloProva) { 'Solo prova: nessun file scritto.'; return }
New-Item -ItemType Directory -Force $Uscita | Out-Null
[IO.File]::WriteAllText((Join-Path $Uscita 'aziende.json'), $json, (New-Object Text.UTF8Encoding($false)))
$lines = New-Object Collections.Generic.List[string]; $lines.Add('data;ticker;chiusura')
foreach ($tk in ($hist.Keys | Sort-Object)) { foreach ($d in (@($hist[$tk].Keys | Sort-Object) | Select-Object -Last 60)) { $lines.Add($d + ';' + $tk + ';' + $hist[$tk][$d].ToString('R', $inv)) } }
[IO.File]::WriteAllLines($stFile, $lines, (New-Object Text.UTF8Encoding($false)))
