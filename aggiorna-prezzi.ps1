# Legge i prezzi PUBBLICI di ETF/ETC/ETN (Borsa Italiana) e crypto (CoinGecko) per gli strumenti di watchlist.json,
# aggiorna rapporti\prezzi.json e accoda lo storico in rapporti\storico-prezzi.csv.
# - Le azioni USA (fonte "stockanalysis") restano quelle dell'ultimo file, SALVO che sia impostata la variabile d'ambiente
#   FINNHUB_KEY (chiave gratuita di finnhub.io, solo dati di mercato): allora si leggono dall'API ufficiale di Finnhub.
# - Parametri facoltativi per l'uso nel cloud:  -Watchlist <file.json>  -Uscita <cartella>  (di default: watchlist.json e rapporti\ accanto allo script)
# - Non usa credenziali, non apre l'archivio cifrato, non tocca FinanzeDati. Scrive solo nella cartella rapporti.
# - Si identifica onestamente (nessun finto browser) e aspetta tra una pagina e l'altra: se un sito rifiuta, lo segnala e basta.
# Uso:  powershell -ExecutionPolicy Bypass -File aggiorna-prezzi.ps1            (aggiorna davvero)
#       powershell -ExecutionPolicy Bypass -File aggiorna-prezzi.ps1 -SoloProva  (mostra cosa leggerebbe, non scrive nulla)
param([switch]$SoloProva, [string]$Watchlist = '', [string]$Uscita = '')

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$inv = [Globalization.CultureInfo]::InvariantCulture
$ua = 'FinanzeApp-personale/1.0 (uso privato, lettura di singole pagine pubbliche)'
$wlPath = if ($Watchlist) { $Watchlist } else { Join-Path $PSScriptRoot 'watchlist.json' }
$outDir = if ($Uscita) { $Uscita } else { Join-Path $PSScriptRoot 'rapporti' }
$pjPath = Join-Path $outDir 'prezzi.json'
$stPath = Join-Path $outDir 'storico-prezzi.csv'
$logPath = Join-Path $outDir 'aggiorna-prezzi.log'
$utf8 = New-Object Text.UTF8Encoding($false)
$now = Get-Date
$stamp = $now.ToString('yyyy-MM-ddTHH:mm:sszzz')

function ToNum([string]$s) {          # "1.234,56" -> 1234.56
  $t = ($s.Trim() -replace '\.', '') -replace ',', '.'; $d = 0.0
  if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { return $d }
  return $null
}
function ToIso([string]$d) {          # "29/10/26" -> "2026-10-29"
  $m = [regex]::Match($d, '^(\d{2})/(\d{2})/(\d{2})$')
  if (-not $m.Success) { return $null }
  return ('20{0}-{1}-{2}' -f $m.Groups[3].Value, $m.Groups[2].Value, $m.Groups[1].Value)
}
function Read-Borsa($n) {
  $url = 'https://www.borsaitaliana.it/borsa/{0}/scheda/{1}.html?lang=it' -f $n.tipo, $n.id
  $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -UserAgent $ua
  $h = [string]$r.Content
  if ($h -notmatch [regex]::Escape($n.id)) { throw "la pagina non contiene l'ISIN atteso" }
  $last = [regex]::Match($h, '-formatPrice">\s*<strong>\s*([\d\.,]+)\s*</strong>')
  $lc = [regex]::Match($h, 'Ultimo Contratto:\s*<strong>\s*(\d{2}/\d{2}/\d{2})(?:&nbsp;|\s)+(\d{2}\.\d{2}\.\d{2})')
  $ref = [regex]::Match($h, 'Prezzo di riferimento</strong>.{0,400}?([\d\.,]+)(?:&nbsp;|\s)*-(?:&nbsp;|\s)*(\d{2}/\d{2}/\d{2})', 'Singleline')
  $cands = @()
  if ($last.Success -and $lc.Success) { $cands += [pscustomobject]@{ p = ToNum $last.Groups[1].Value; d = ToIso $lc.Groups[1].Value; base = 'ultimo' } }
  if ($ref.Success) { $cands += [pscustomobject]@{ p = ToNum $ref.Groups[1].Value; d = ToIso $ref.Groups[2].Value; base = 'riferimento' } }
  $cands = @($cands | Where-Object { $_.p -gt 0 -and $_.d })
  if (-not $cands.Count) { throw 'prezzo o data non trovati nella pagina' }
  $best = $cands | Sort-Object -Property @{ Expression = 'd'; Descending = $true }, @{ Expression = 'base'; Descending = $true } | Select-Object -First 1   # data piu recente; a pari data vince "ultimo"
  $ter = [regex]::Match($h, 'Commissioni totali annue</strong>.{0,300}?([\d\.,]+)\s*%', 'Singleline')                      # costi annui (TER), benchmark e distribuzione: servono all'app per costi e tasse
  $bm = [regex]::Match($h, '<strong>Benchmark</strong>.{0,300}?-right">\s*([^<]{1,80}?)\s*</span>', 'Singleline')
  $dv = [regex]::Match($h, '<strong>Dividendi</strong>.{0,300}?-right">\s*([^<]{1,30}?)\s*</span>', 'Singleline')
  return [pscustomobject]@{ prezzo = $best.p; valuta = 'EUR'; data = $best.d; base = $best.base
    ter = $(if ($ter.Success) { ToNum $ter.Groups[1].Value } else { $null })
    bench = $(if ($bm.Success) { [Net.WebUtility]::HtmlDecode($bm.Groups[1].Value).Trim() } else { $null })
    div = $(if ($dv.Success) { [Net.WebUtility]::HtmlDecode($dv.Groups[1].Value).Trim() } else { $null }) }
}

$wl = (Get-Content $wlPath -Raw -Encoding UTF8 | ConvertFrom-Json).strumenti
$old = @{}
if (Test-Path $pjPath) { try { foreach ($e in (Get-Content $pjPath -Raw -Encoding UTF8 | ConvertFrom-Json).prezzi) { $old[$e.nome] = $e } } catch { } }

$new = @{}; $fail = New-Object Collections.Generic.List[string]; $susp = New-Object Collections.Generic.List[string]
$todo = @($wl | Where-Object { $_.fonte -eq 'borsa_italiana' })
foreach ($n in $todo) {
  try { $new[$n.nome] = Read-Borsa $n } catch { $fail.Add(('{0}: {1}' -f $n.nome, $_.Exception.Message)) }
  Start-Sleep -Milliseconds 600
}
$cg = @($wl | Where-Object { $_.fonte -eq 'coingecko' })
if ($cg.Count) {
  try {
    $ids = ($cg | ForEach-Object { $_.id }) -join ','
    $r = Invoke-RestMethod -Uri "https://api.coingecko.com/api/v3/simple/price?ids=$ids&vs_currencies=eur&include_last_updated_at=true" -UserAgent $ua -TimeoutSec 30
    foreach ($n in $cg) {
      $v = $r.PSObject.Properties[$n.id]
      if ($v -and $v.Value.eur -gt 0) {
        $d = [DateTimeOffset]::FromUnixTimeSeconds([int64]$v.Value.last_updated_at).ToLocalTime().ToString('yyyy-MM-dd')
        $new[$n.nome] = [pscustomobject]@{ prezzo = [double]$v.Value.eur; valuta = 'EUR'; data = $d; base = 'ultimo' }
      } else { $fail.Add(('{0}: non presente nella risposta di CoinGecko' -f $n.nome)) }
    }
  } catch { foreach ($n in $cg) { $fail.Add(('{0}: {1}' -f $n.nome, $_.Exception.Message)) } }
}
function Read-Finnhub($n) {           # azioni USA dall'API ufficiale di Finnhub (serve FINNHUB_KEY)
  $r = Invoke-RestMethod -Uri ('https://finnhub.io/api/v1/quote?symbol={0}&token={1}' -f [Uri]::EscapeDataString($n.id.ToUpper()), $env:FINNHUB_KEY) -UserAgent $ua -TimeoutSec 30
  if (-not ($r.c -gt 0) -or -not ($r.t -gt 0)) { throw 'quotazione assente (simbolo non coperto dal piano gratuito?)' }
  $d = [DateTimeOffset]::FromUnixTimeSeconds([int64]$r.t).ToOffset([TimeSpan]::FromHours(-5)).ToString('yyyy-MM-dd')     # data di Borsa USA (il fuso esatto non cambia il giorno)
  return [pscustomobject]@{ prezzo = [double]$r.c; valuta = 'USD'; data = $d; base = 'ultimo' }
}
$us = @($wl | Where-Object { $_.fonte -eq 'stockanalysis' }); $usOn = [bool]$env:FINNHUB_KEY -and $us.Count -gt 0
if ($usOn) {
  foreach ($n in $us) {
    try { $new[$n.nome] = Read-Finnhub $n } catch { $fail.Add(('{0}: {1}' -f $n.nome, ($_.Exception.Message -replace [regex]::Escape($env:FINNHUB_KEY), '***'))) }
    Start-Sleep -Milliseconds 400
  }
}
$expected = $todo.Count + $cg.Count + $(if ($usOn) { $us.Count } else { 0 })

# controllo di coerenza: un salto enorme rispetto all'ultimo prezzo noto e' quasi sempre un errore di lettura, non un prezzo vero
foreach ($k in @($new.Keys)) {
  $item = $wl | Where-Object { $_.nome -eq $k } | Select-Object -First 1
  if ($old.ContainsKey($k) -and $old[$k].prezzo -gt 0) {
    $lim = if ($item.fonte -eq 'coingecko') { 0.6 } else { 0.3 }
    $chg = $new[$k].prezzo / $old[$k].prezzo - 1
    if ([math]::Abs($chg) -gt $lim) { $susp.Add(('{0}: {1:P1} rispetto all''ultimo prezzo noto, non aggiornato' -f $k, $chg)); $new.Remove($k) }
  }
}

$rows = New-Object Collections.Generic.List[object]; $fromOld = 0
foreach ($n in $wl) {
  $e = $null; $m = $null
  if ($new.ContainsKey($n.nome)) { $m = $new[$n.nome]; $e = [ordered]@{ nome = $n.nome; id = $n.id; prezzo = $m.prezzo; valuta = $m.valuta; data = $m.data } }
  elseif ($old.ContainsKey($n.nome)) { $o = $old[$n.nome]; $e = [ordered]@{ nome = $o.nome; id = $o.id; prezzo = [double]$o.prezzo; valuta = $o.valuta; data = $o.data }; $fromOld++ }
  if ($e) {
    foreach ($k in 'ter', 'bench', 'div') {       # dati dell'ETF: se questa volta non si leggono, restano quelli dell'ultimo file
      $v = $null
      if ($m -and $m.PSObject.Properties[$k] -and $null -ne $m.$k -and "$($m.$k)" -ne '') { $v = $m.$k }
      elseif ($old.ContainsKey($n.nome) -and $old[$n.nome].PSObject.Properties[$k]) { $v = $old[$n.nome].$k }
      if ($null -ne $v -and "$v" -ne '') { $e[$k] = $v }
    }
    $rows.Add($e)
  }
}

"{0}  letti ora: {1} su {2}  |  ripresi dall'ultimo file: {3}  |  non letti: {4}  |  sospetti: {5}" -f $stamp, $new.Count, $expected, $fromOld, $fail.Count, $susp.Count
foreach ($n in $wl) { if ($new.ContainsKey($n.nome)) { $x = $new[$n.nome]; '  {0,-62} {1,12} {2} {3} ({4})' -f $n.nome.Substring(0, [Math]::Min(62, $n.nome.Length)), $x.prezzo.ToString('0.######', $inv), $x.valuta, $x.data, ($x.base + $(if ($null -ne $x.ter) { ', TER ' + $x.ter } else { '' })) } }
foreach ($f in $fail) { "  NON LETTO  $f" }
foreach ($s in $susp) { "  SOSPETTO   $s" }

if ($SoloProva) { 'Solo prova: nessun file scritto.'; return }
if (-not (Test-Path $outDir)) { throw "cartella non trovata: $outDir" }
if ($new.Count -eq 0) { Add-Content -Path $logPath -Value ("{0}  NESSUN PREZZO LETTO: file lasciato com'era" -f $stamp) -Encoding UTF8; Write-Error 'Nessun prezzo letto: prezzi.json non modificato.'; exit 1 }

function JStr([string]$s) { '"' + ((($s -replace '\\', '\\') -replace '"', '\"') -replace '[\x00-\x1f]', ' ') + '"' }   # niente ConvertTo-Json: in PowerShell 5.1 e' fragile
$items = foreach ($r in $rows) {
  $s = '{{"nome":{0},"id":{1},"prezzo":{2},"valuta":{3},"data":{4}' -f (JStr $r.nome), (JStr $r.id), ([double]$r.prezzo).ToString('R', $inv), (JStr $r.valuta), (JStr $r.data)
  if ($null -ne $r['ter']) { $s += ',"ter":' + ([double]$r['ter']).ToString('R', $inv) }
  if ($r['bench']) { $s += ',"bench":' + (JStr ([string]$r['bench'])) }
  if ($r['div']) { $s += ',"div":' + (JStr ([string]$r['div'])) }
  '    ' + $s + '}'
}
# cambi ufficiali della BCE (euro per 1 unita' di valuta): servono all'app per i titoli quotati in dollari
$cambi = [ordered]@{}
try { $x = [xml](Invoke-WebRequest 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml' -UseBasicParsing -TimeoutSec 30).Content; foreach ($cb in @($x.Envelope.Cube.Cube.Cube)) { if (@('USD', 'GBP', 'CHF', 'JPY', 'CAD', 'AUD') -contains $cb.currency) { $rt = [double]::Parse($cb.rate, $inv); if ($rt -gt 0) { $cambi[[string]$cb.currency] = [Math]::Round(1 / $rt, 6) } } } } catch { }
$cj = if ($cambi.Count) { "  `"cambi`": {" + (($cambi.Keys | ForEach-Object { (JStr $_) + ': ' + ([double]$cambi[$_]).ToString('R', $inv) }) -join ', ') + "},`n" } else { '' }
$json = "{`n  `"app`": `"finanze-prezzi`",`n  `"versione`": 1,`n  `"generato`": $(JStr $stamp),`n" + $cj + "  `"prezzi`": [`n" + ($items -join ",`n") + "`n  ]`n}`n"
[IO.File]::WriteAllText($pjPath, $json, $utf8)

$lines = New-Object Collections.Generic.List[string]
if (-not (Test-Path $stPath)) { $lines.Add('timestamp;nome;id;prezzo;valuta;data;fonte') }
foreach ($n in $wl) { if ($new.ContainsKey($n.nome)) { $x = $new[$n.nome]; $lines.Add(('{0};{1};{2};{3};{4};{5};{6}' -f $stamp, ($n.nome -replace ';', ','), $n.id, $x.prezzo.ToString('R', $inv), $x.valuta, $x.data, $n.fonte)) } }
[IO.File]::AppendAllText($stPath, (($lines -join "`r`n") + "`r`n"), $utf8)

$msg = '{0}  letti {1}, ripresi {2}, non letti {3}, sospetti {4}' -f $stamp, $new.Count, $fromOld, $fail.Count, $susp.Count
$log = @($msg) + @($fail | ForEach-Object { '    NON LETTO ' + $_ }) + @($susp | ForEach-Object { '    SOSPETTO ' + $_ })
[IO.File]::AppendAllText($logPath, (($log -join "`r`n") + "`r`n"), $utf8)
Write-Host "Scritto $pjPath e accodato lo storico."
if ($fail.Count -gt $expected / 2) { exit 1 }
