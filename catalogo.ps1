# Catalogo dei prezzi: legge in blocco gli elenchi pubblici di Borsa Italiana (ETF, ETC/ETN, BTP/BOT/CCT, obbligazioni in euro, Extramot)
# e le prime 500 crypto di CoinGecko, e scrive catalogo.json: l'app lo usa per trovare da sola il prezzo di QUALSIASI strumento
# che ha un ISIN presente (cosi' un titolo nuovo si aggiorna senza che nessuno lo aggiunga a un elenco).
# Solo dati pubblici di mercato. Non legge niente di tuo.
# Uso:  pwsh ./catalogo.ps1 -Uscita ./site [-MaxPagine 400] [-SoloProva]
param([string]$Uscita = './site', [int]$MaxPagine = 400, [switch]$SoloProva)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$inv = [Globalization.CultureInfo]::InvariantCulture
$ua = 'Mozilla/5.0 (compatible; finanze-app personale)'
$tz = [TimeZoneInfo]::FindSystemTimeZoneById($(if ($IsLinux -or $IsMacOS) { 'Europe/Rome' } else { 'W. Europe Standard Time' }))
$oggi = [TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz)
function JStr([string]$s) { '"' + ((($s -replace '\\', '\\') -replace '"', '\"') -replace '[\x00-\x1f]', ' ') + '"' }
function Num([string]$s) { $t = ($s.Trim() -replace '\.', '') -replace ',', '.'; $d = 0.0; if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { $d } else { $null } }
function IsoDate($raw) {          # "10:13:49" = oggi; "29/10/26" = quella data
  if ($raw -match '^\d{2}:\d{2}:\d{2}$') { return $oggi.ToString('yyyy-MM-dd') }
  $m = [regex]::Match([string]$raw, '^(\d{2})/(\d{2})/(\d{2})$'); if ($m.Success) { return ('20{0}-{1}-{2}' -f $m.Groups[3].Value, $m.Groups[2].Value, $m.Groups[1].Value) }
  return $oggi.ToString('yyyy-MM-dd')
}
$prevD = $oggi.Date.AddDays(-1); while ($prevD.DayOfWeek -in 'Saturday', 'Sunday') { $prevD = $prevD.AddDays(-1) }; $prev = $prevD.ToString('yyyy-MM-dd')
$voci = New-Object 'Collections.Generic.Dictionary[string,object]'
function Add-Pages($baseUrl, $tipo, $maxP) {
  $tot = 0
  for ($p = 1; $p -le $maxP; $p++) {
    $u = if ($p -eq 1) { $baseUrl } else { $baseUrl + ($(if ($baseUrl.Contains('?')) { '&' } else { '?' })) + "page=$p" }
    $h = $null; for ($k = 0; $k -lt 3 -and -not $h; $k++) { try { $h = [string](Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 40 -UserAgent $ua).Content } catch { Start-Sleep -Seconds 2 } }
    if (-not $h) { Write-Host "  pagina $p non letta: ci si ferma qui"; break }
    $n = 0
    foreach ($row in ($h -split '<tr>')) {
      $m = [regex]::Match($row, '/borsa/[a-z\-/]+/scheda/([A-Z]{2}[A-Z0-9]{9}[0-9])(?:-([A-Z0-9]+))?[^"]*"[^>]*title="[^"]*?&nbsp;([^"]+)"'); if (-not $m.Success) { continue }
      $isin = $m.Groups[1].Value; $ven = $m.Groups[2].Value; $name = [Net.WebUtility]::HtmlDecode($m.Groups[3].Value).Trim() -replace ('^' + [regex]::Escape($isin) + '\s*-\s*'), ''
      $pr = $null; $dt = $null
      $mb = [regex]::Match($row, 'Ultimo:\s*([\d\.]+,\d+)'); if ($mb.Success) { $pr = Num $mb.Groups[1].Value }
      else { $me = [regex]::Match($row, '-size-xs">\s*([\d\.]+,\d+)\s*</span>'); if ($me.Success) { $pr = Num $me.Groups[1].Value } }
      $md = [regex]::Match($row, '-size-xs">\s*(\d{2}:\d{2}:\d{2}|\d{2}/\d{2}/\d{2})\s*</span>'); $dt = IsoDate $(if ($md.Success) { $md.Groups[1].Value } else { '' })
      if (-not $pr) { $txt = ($row -replace '<[^>]+>', '|' -replace '&nbsp;', ' '); $mr = [regex]::Matches($txt, '\|\s*([\d\.]+,\d+)\s*(?=\|)'); if ($mr.Count) { $pr = Num $mr[$mr.Count - 1].Groups[1].Value; $dt = $prev } }          # nessuno scambio oggi: vale il prezzo di riferimento (l'ultima chiusura)
      $estero = $ven -match '^X'          # la stessa ISIN compare anche su Amsterdam, Parigi...: in dollari o altre valute. Valgono solo le righe dei mercati italiani
      if ($pr -and $pr -gt 0 -and (-not $voci.ContainsKey($isin) -or ($voci[$isin].x -and -not $estero))) { $voci[$isin] = [pscustomobject]@{ isin = $isin; name = $name; p = $pr; d = $dt; t = $tipo; x = $estero }; $n++ }
    }
    $tot += $n; if ($n -eq 0) { break }
    Start-Sleep -Milliseconds 450
  }
  Write-Host ("  {0}: {1} strumenti" -f $tipo, $tot); return $tot
}
$etf = 'https://www.borsaitaliana.it/borsa/etf/search.html?comparto=ETF&idBenchmarkStyle=&idBenchmark=&indexBenchmark=&sectorization=&lang=it'
$etc = 'https://www.borsaitaliana.it/borsa/etf/search.html?comparto=ETC&idBenchmarkStyle=&idBenchmark=&indexBenchmark=&sectorization=&lang=it'
$n1 = Add-Pages $etf 'etf' $MaxPagine
$n2 = Add-Pages $etc 'etc' $MaxPagine
foreach ($b in 'mot/btp', 'mot/bot', 'mot/cct', 'mot/euro-obbligazioni', 'mot/obbligazioni-euro', 'extramot') { $null = Add-Pages ("https://www.borsaitaliana.it/borsa/obbligazioni/$b/lista.html?lang=it") 'obb' 40 }
foreach ($k in @($voci.Keys)) { if ($voci[$k].x) { [void]$voci.Remove($k) } }
if ($n1 -lt 500) { "Letti solo $n1 ETF (ne servono almeno 500): catalogo non aggiornato."; exit 1 }

$crypto = New-Object Collections.Generic.List[object]
foreach ($pg in 1, 2) {
  try { $r = Invoke-RestMethod "https://api.coingecko.com/api/v3/coins/markets?vs_currency=eur&order=market_cap_desc&per_page=250&page=$pg" -UserAgent $ua -TimeoutSec 40
    foreach ($c in $r) { if ($c.current_price -gt 0) { $crypto.Add([pscustomobject]@{ id = $c.id; s = ([string]$c.symbol).ToUpper(); n = $c.name; p = [double]$c.current_price }) } } } catch { Write-Host "  CoinGecko pagina ${pg}: $($_.Exception.Message)" }
  Start-Sleep -Seconds 2
}
Write-Host "  crypto: $($crypto.Count)"
$usa = New-Object Collections.Generic.List[object]
$az = Join-Path $Uscita 'aziende.json'
if (Test-Path $az) { try { $a = Get-Content $az -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in 'giorno', 'settimana', 'mese') { foreach ($x in @($a.$k)) { if (-not ($usa | Where-Object { $_.t -eq $x.ticker })) { $usa.Add([pscustomobject]@{ t = $x.ticker; n = $x.nome; p = [double]$x.prezzo; d = $x.data }) } } } } catch { } }

$items = foreach ($v in $voci.Values) { '[' + (JStr $v.isin) + ',' + (JStr $v.name) + ',' + ([double]$v.p).ToString('R', $inv) + ',"EUR",' + (JStr $v.d) + ',' + (JStr $v.t) + ']' }
$cr = foreach ($c in $crypto) { '[' + (JStr $c.id) + ',' + (JStr $c.s) + ',' + (JStr $c.n) + ',' + ([double]$c.p).ToString('R', $inv) + ']' }
$us = foreach ($u in $usa) { '[' + (JStr $u.t) + ',' + (JStr $u.n) + ',' + ([double]$u.p).ToString('R', $inv) + ',' + (JStr $u.d) + ']' }
$json = "{`n`"app`":`"finanze-catalogo`",`"versione`":1,`"generato`":" + (JStr (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')) + ",`n`"voci`":[`n" + ($items -join ",`n") + "`n],`n`"crypto`":[`n" + ($cr -join ",`n") + "`n],`n`"usa`":[`n" + ($us -join ",`n") + "`n]}`n"
$null = $json | ConvertFrom-Json          # deve essere un JSON valido
"Catalogo: {0} strumenti di Borsa Italiana, {1} crypto, {2} azioni USA ({3:N0} KB)" -f $voci.Count, $crypto.Count, $usa.Count, ($json.Length / 1KB)
if ($SoloProva) { 'Solo prova: nessun file scritto.'; return }
New-Item -ItemType Directory -Force $Uscita | Out-Null
[IO.File]::WriteAllText((Join-Path $Uscita 'catalogo.json'), $json, (New-Object Text.UTF8Encoding($false)))
