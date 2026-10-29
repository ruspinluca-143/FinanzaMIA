# Raccoglie, da fonti PUBBLICHE, titoli di notizie e dati di mercato e li scrive in mercati.json (letto dall'app, scheda "Mercati").
# - Si identifica onestamente (nessun finto browser). Se una fonte rifiuta o non risponde, la segna "non disponibile" e va avanti: non si aggira nulla.
# - Dalle testate prende SOLO titolo, indirizzo e data (RSS pubblici): il testo degli articoli resta sul loro sito.
# - Non usa credenziali, non apre archivi, non conosce i tuoi dati. In piu', con la variabile FINNHUB_KEY legge i settori USA (ETF SPDR).
# Uso:  powershell -ExecutionPolicy Bypass -File raccogli-mercati.ps1 [-Uscita cartella] [-SoloProva]
param([switch]$SoloProva, [string]$Uscita = '')

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$inv = [Globalization.CultureInfo]::InvariantCulture
$ua = 'FinanzeApp-personale/1.0 (uso privato, lettura di singole pagine pubbliche)'
$outDir = if ($Uscita) { $Uscita } else { Join-Path $PSScriptRoot 'rapporti' }
$utf8 = New-Object Text.UTF8Encoding($false)
$stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')

function JStr([string]$s) { '"' + ((($s -replace '\\', '\\') -replace '"', '\"') -replace '[\x00-\x1f]', ' ') + '"' }
function ToJson($o) {          # niente ConvertTo-Json: in PowerShell 5.1 e' fragile
  if ($null -eq $o) { return 'null' }
  if ($o -is [string]) { return (JStr $o) }
  if ($o -is [bool]) { if ($o) { return 'true' } else { return 'false' } }
  if ($o -is [int] -or $o -is [long] -or $o -is [double] -or $o -is [decimal] -or $o -is [single]) { $d = [double]$o; if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return 'null' }; return $d.ToString('R', $inv) }
  if ($o -is [System.Collections.IDictionary]) { return '{' + (($o.Keys | ForEach-Object { (JStr ([string]$_)) + ':' + (ToJson $o[$_]) }) -join ',') + '}' }
  if ($o -is [System.Collections.IEnumerable]) { return '[' + (($o | ForEach-Object { ToJson $_ }) -join ',') + ']' }
  return (JStr ([string]$o))
}
function Get-Text($url) { [string](Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -UserAgent $ua).Content }
function Clean($s, $max) { $t = [Net.WebUtility]::HtmlDecode(([string]$s -replace '<!\[CDATA\[', '' -replace '\]\]>', '' -replace '<[^>]+>', ' ')); $t = ($t -replace '\s+', ' ').Trim(); if ($t.Length -gt $max) { $t = $t.Substring(0, $max - 3) + '...' }; $t }
function Num($v) { $d = 0.0; if ([double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { $d } else { $null } }

# ---------- notizie (RSS/Atom pubblici: solo titolo, link, data) ----------
$feeds = @(
  @('Mercati e imprese', 'CNBC - Mercati', 'https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=10000664'),
  @('Mercati e imprese', 'CNBC - Prime notizie', 'https://www.cnbc.com/id/100003114/device/rss/rss.html'),
  @('Mercati e imprese', 'Wall Street Journal - Mercati', 'https://feeds.a.dj.com/rss/RSSMarketsMain.xml'),
  @('Mercati e imprese', 'MarketWatch', 'https://feeds.content.dowjones.io/public/rss/mw_topstories'),
  @('Mercati e imprese', 'Financial Times', 'https://www.ft.com/rss/home'),
  @('Mercati e imprese', 'New York Times - Economia', 'https://rss.nytimes.com/services/xml/rss/nyt/Business.xml'),
  @('Mercati e imprese', 'New York Times - Macroeconomia', 'https://rss.nytimes.com/services/xml/rss/nyt/Economy.xml'),
  @('Mercati e imprese', 'Investing.com', 'https://www.investing.com/rss/news.rss'),
  @('Mercati e imprese', 'Seeking Alpha', 'https://seekingalpha.com/market_currents.xml'),
  @('Mercati e imprese', 'The Economist - Finanza', 'https://www.economist.com/finance-and-economics/rss.xml'),
  @('Mercati e imprese', 'BBC - Economia', 'https://feeds.bbci.co.uk/news/business/rss.xml'),
  @('Mercati e imprese', 'The Guardian - Economia', 'https://www.theguardian.com/uk/business/rss'),
  @('Mercati e imprese', 'eToro - News e analisi', 'https://www.etoro.com/news-and-analysis/feed/'),
  @('Italia', 'Il Sole 24 Ore - Finanza', 'https://www.ilsole24ore.com/rss/finanza.xml'),
  @('Italia', 'ANSA - Economia', 'https://www.ansa.it/sito/notizie/economia/economia_rss.xml'),
  @('Banche centrali', 'Federal Reserve', 'https://www.federalreserve.gov/feeds/press_all.xml'),
  @('Banche centrali', 'BCE', 'https://www.ecb.europa.eu/rss/press.html'),
  @('Crypto', 'CoinDesk', 'https://www.coindesk.com/arc/outboundfeeds/rss')
)
function Read-Feed($url) {
  $x = (Get-Text $url).Trim()
  $blocks = [regex]::Matches($x, '<item[\s>].*?</item>|<entry[\s>].*?</entry>', 'Singleline')
  $out = New-Object Collections.Generic.List[object]
  foreach ($b in $blocks) {
    $s = $b.Value
    $t = [regex]::Match($s, '<title[^>]*>(.*?)</title>', 'Singleline').Groups[1].Value
    $l = [regex]::Match($s, '<link[^>]*href="([^"]+)"').Groups[1].Value
    if (-not $l) { $l = [regex]::Match($s, '<link[^>]*>\s*(?:<!\[CDATA\[)?\s*(https?://[^<\s\]]+)').Groups[1].Value }
    $d = [regex]::Match($s, '<(?:pubDate|published|updated|dc:date)[^>]*>([^<]+)<').Groups[1].Value
    $iso = ''; $dt = [DateTimeOffset]::MinValue; if ($d -and [DateTimeOffset]::TryParse($d.Trim(), $inv, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dt)) { $iso = $dt.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $title = Clean $t 180
    if ($title.Length -ge 12 -and $l -match '^https?://') { $out.Add([ordered]@{ titolo = $title; link = ([Net.WebUtility]::HtmlDecode($l)).Trim(); data = $iso }) }
    if ($out.Count -ge 40) { break }
  }
  if (-not $out.Count) { throw 'nessuna notizia riconosciuta nel file' }
  $limit = (Get-Date).ToUniversalTime().AddDays(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')          # niente notizie vecchie: un feed fermo da mesi si segnala, non si mostra
  $fresh = @($out | Where-Object { -not $_['data'] -or $_['data'] -ge $limit })
  if (-not $fresh.Count) { $newest = ($out | ForEach-Object { $_['data'] } | Sort-Object -Descending | Select-Object -First 1); throw ('feed non aggiornato (ultima notizia: ' + $newest + ')') }
  return @($fresh | Sort-Object -Property @{ Expression = { $_['data'] }; Descending = $true } | Select-Object -First 8)
}
$fonti = New-Object Collections.Generic.List[object]
foreach ($f in $feeds) {
  try { $fonti.Add([ordered]@{ nome = $f[1]; gruppo = $f[0]; ok = $true; voci = @(Read-Feed $f[2]) }) }       # @(): con una sola notizia deve restare un elenco, non diventare un oggetto
  catch { $msg = ($_.Exception.Message -replace '\s+', ' '); if ($msg.Length -gt 90) { $msg = $msg.Substring(0, 90) }; $fonti.Add([ordered]@{ nome = $f[1]; gruppo = $f[0]; ok = $false; errore = $msg; voci = @() }) }
  Start-Sleep -Milliseconds 300
}

# ---------- indicatori ----------
$ind = [ordered]@{}; $indErr = New-Object Collections.Generic.List[string]

try {   # curva dei tassi del Tesoro USA
  $rows = New-Object Collections.Generic.List[object]
  foreach ($off in -1, 0) {
    $m = (Get-Date).AddMonths($off).ToString('yyyyMM')
    $x = Get-Text "https://home.treasury.gov/resource-center/data-chart-center/interest-rates/pages/xml?data=daily_treasury_yield_curve&field_tdr_date_value_month=$m"
    foreach ($e in [regex]::Matches($x, '<entry>.*?</entry>', 'Singleline')) {
      $b = $e.Value; $d = [regex]::Match($b, '<d:NEW_DATE[^>]*>([^<]+)<').Groups[1].Value
      if ($d) { $rows.Add([pscustomobject]@{ d = $d.Substring(0, 10); y2 = Num ([regex]::Match($b, '<d:BC_2YEAR[^>]*>([\d\.]+)<').Groups[1].Value); y10 = Num ([regex]::Match($b, '<d:BC_10YEAR[^>]*>([\d\.]+)<').Groups[1].Value); y30 = Num ([regex]::Match($b, '<d:BC_30YEAR[^>]*>([\d\.]+)<').Groups[1].Value) }) }
    }
  }
  $s = @($rows | Sort-Object d); $a = $s[-1]; $p = if ($s.Count -ge 2) { $s[-2] } else { $null }
  if (-not $a -or $null -eq $a.y10) { throw 'valori non trovati' }
  $ind['tassi_usa'] = [ordered]@{ data = $a.d; y2 = $a.y2; y10 = $a.y10; y30 = $a.y30; spread_2_10 = [math]::Round($a.y10 - $a.y2, 3); y10_prec = $(if ($p) { $p.y10 } else { $null }); y2_prec = $(if ($p) { $p.y2 } else { $null }) }
} catch { $indErr.Add('Curva dei tassi USA: ' + $_.Exception.Message) }

try {   # mercato crypto globale
  $g = (Get-Text 'https://api.coingecko.com/api/v3/global' | ConvertFrom-Json).data
  $ind['crypto'] = [ordered]@{ capitalizzazione_mld_usd = [math]::Round($g.total_market_cap.usd / 1e9, 0); var_24h_pct = [math]::Round($g.market_cap_change_percentage_24h_usd, 2); dominanza_btc_pct = [math]::Round($g.market_cap_percentage.btc, 1) }
} catch { $indErr.Add('Mercato crypto: ' + $_.Exception.Message) }

try {   # paura e avidita delle crypto (API ufficiale di alternative.me)
  $fg = (Get-Text 'https://api.alternative.me/fng/?limit=2' | ConvertFrom-Json).data
  $ind['paura_avidita_crypto'] = [ordered]@{ valore = [int]$fg[0].value; classe = [string]$fg[0].value_classification; ieri = $(if ($fg.Count -ge 2) { [int]$fg[1].value } else { $null }) }
} catch { $indErr.Add('Paura e avidit' + [char]0x00E0 + ' crypto: ' + $_.Exception.Message) }

try {   # liquidita in stablecoin (carburante del mercato crypto)
  $sc = @(Get-Text 'https://stablecoins.llama.fi/stablecoincharts/all' | ConvertFrom-Json | ForEach-Object { $_ })       # ConvertFrom-Json di PowerShell 5.1 restituisce l'elenco come un solo oggetto: lo si "srotola"
  $n = $sc.Count; $last = [double]$sc[$n - 1].totalCirculatingUSD.peggedUSD; $w = [double]$sc[$n - 8].totalCirculatingUSD.peggedUSD; $mth = [double]$sc[$n - 31].totalCirculatingUSD.peggedUSD
  $ind['stablecoin'] = [ordered]@{ totale_mld_usd = [math]::Round($last / 1e9, 1); var_7g_pct = [math]::Round(($last / $w - 1) * 100, 2); var_30g_pct = [math]::Round(($last / $mth - 1) * 100, 2) }
} catch { $indErr.Add('Stablecoin: ' + $_.Exception.Message) }

try {   # posizioni dei grandi operatori sui futures (CFTC, settimanale, con qualche giorno di ritardo)
  $cot = New-Object Collections.Generic.List[object]; $asof = ''
  $lines = (Get-Text 'https://www.cftc.gov/dea/newcot/deafut.txt') -split "`r?`n" | Where-Object { $_ }
  $want = @(@('S&P 500', '^E-MINI S&P 500 - '), @('Nasdaq 100', '^(NASDAQ MINI|NASDAQ-100 Consolidated)'), @('Titoli di Stato USA 10 anni', '^UST 10Y NOTE'), @('Titoli di Stato USA 2 anni', '^UST 2Y NOTE'), @('Euro / Dollaro', '^EURO FX - '), @('Dollaro USA (indice)', '^USD INDEX'), @('Oro', '^GOLD - '), @('Argento', '^SILVER - '), @('Rame', '^COPPER'), @('Petrolio WTI', '^(WTI-PHYSICAL|CRUDE OIL, LIGHT SWEET-WTI)'), @('Bitcoin', '^BITCOIN - '), @(('VIX (volatilit' + [char]0x00E0 + ')'), '^VIX FUTURES'))
  foreach ($w in $want) {
    $l = $lines | Where-Object { $_ -match ('^"' + $w[1].TrimStart('^')) } | Select-Object -First 1
    if (-not $l) { continue }
    $mm = [regex]::Match($l, '^"([^"]+)",(.*)$'); $f = @($mm.Groups[1].Value) + ($mm.Groups[2].Value -split ',')      # il nome puo' contenere virgole: va separato prima
    $oi = Num $f[7]; $nl = Num $f[8]; $ns = Num $f[9]
    if ($oi -gt 0) { $cot.Add([ordered]@{ nome = $w[0]; lunghi = $nl; corti = $ns; netto = $nl - $ns; netto_su_oi_pct = [math]::Round(($nl - $ns) / $oi * 100, 1) }); $asof = $f[2].Trim() }
  }
  if (-not $cot.Count) { throw 'nessun contratto riconosciuto' }
  $ind['posizioni_grandi_futures'] = [ordered]@{ data = $asof; voci = $cot }
} catch { $indErr.Add('Posizioni sui futures (CFTC): ' + $_.Exception.Message) }

if ($env:FINNHUB_KEY) {   # settori USA (ETF SPDR), solo con la chiave gratuita di Finnhub
  try {
    $sect = New-Object Collections.Generic.List[object]
    foreach ($p in @(@('XLK', 'Tecnologia'), @('XLF', 'Finanza'), @('XLE', 'Energia'), @('XLV', 'Salute'), @('XLY', 'Consumi ciclici'), @('XLP', 'Consumi di base'), @('XLI', 'Industriali'), @('XLU', ('Servizi di pubblica utilit' + [char]0x00E0)), @('XLB', 'Materiali'), @('XLRE', 'Immobiliare'), @('XLC', 'Comunicazioni'))) {
      $q = Invoke-RestMethod -Uri ('https://finnhub.io/api/v1/quote?symbol={0}&token={1}' -f $p[0], $env:FINNHUB_KEY) -UserAgent $ua -TimeoutSec 30
      if ($q.c -gt 0) { $sect.Add([ordered]@{ nome = $p[1]; simbolo = $p[0]; var_giorno_pct = [math]::Round([double]$q.dp, 2) }) }
      Start-Sleep -Milliseconds 400
    }
    if ($sect.Count) { $ind['settori_usa'] = @($sect | Sort-Object { -$_.var_giorno_pct }) }
  } catch { $indErr.Add('Settori USA: ' + ($_.Exception.Message -replace [regex]::Escape($env:FINNHUB_KEY), '***')) }
}

$okF = @($fonti | Where-Object { $_.ok }).Count
"{0}  fonti di notizie: {1} su {2}  |  indicatori: {3}  |  errori indicatori: {4}" -f $stamp, $okF, $fonti.Count, (($ind.Keys) -join ', '), $indErr.Count
foreach ($f in $fonti) { if (-not $f.ok) { "  NON DISPONIBILE  $($f.nome): $($f.errore)" } }
foreach ($e in $indErr) { "  INDICATORE NON LETTO  $e" }
if ($SoloProva) { 'Solo prova: nessun file scritto.'; return }
if (-not (Test-Path $outDir)) { throw "cartella non trovata: $outDir" }
if ($okF -eq 0 -and $ind.Count -eq 0) { Write-Error 'Nessuna fonte letta: mercati.json non modificato.'; exit 1 }
$doc = New-Object Collections.Specialized.OrderedDictionary       # costruito voce per voce: [ordered]@{ ... = @(lista) } in PowerShell 5.1 puo' dare "Argument types do not match"
$doc['app'] = 'finanze-mercati'; $doc['versione'] = 1; $doc['generato'] = $stamp; $doc['indicatori'] = $ind
$doc['indicatori_non_letti'] = $indErr.ToArray(); $doc['fonti'] = $fonti.ToArray()
[IO.File]::WriteAllText((Join-Path $outDir 'mercati.json'), ((ToJson $doc) + "`n"), $utf8)
Write-Host "Scritto $(Join-Path $outDir 'mercati.json')."
