# Raccoglie dai dati ufficiali della SEC (gratuiti e pubblici) dove stanno andando i soldi dei grandi:
#  - 13F: i portafogli dei grandi fondi e istituzioni, ogni trimestre (in ritardo di circa 45 giorni)
#  - Form 4: gli acquisti e le vendite degli insider (dirigenti e grandi azionisti), entro 2 giorni lavorativi
# Scrive grandi-soldi.json nella cartella indicata. Non contiene niente di personale.
# Uso:  powershell -ExecutionPolicy Bypass -File raccogli-grandi-soldi.ps1 -Uscita ./site [-SoloFondi] [-SoloInsider] [-GiorniInsider 2]
# La SEC chiede a chi scarica di identificarsi con nome e contatto (User-Agent): senza risponde 403. Nessuna richiesta finge di essere un browser.
param([string]$Uscita = '.', [switch]$SoloFondi, [switch]$SoloInsider, [int]$GiorniInsider = 2)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ua = 'FinanzeApp/1.0 (ruspiniluca143@gmail.com)'          # formato prodotto/versione (contatto): PowerShell 7 rifiuta un User-Agent scritto a parole
$inv = [Globalization.CultureInfo]::InvariantCulture
$out = Join-Path $Uscita 'grandi-soldi.json'
$old = $null; if (Test-Path $out) { try { $old = Get-Content $out -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $old = $null } }

function Sec([string]$url) {          # una richiesta alla SEC: al massimo ~8 al secondo, con qualche nuovo tentativo
  for ($k = 1; $k -le 4; $k++) {
    try { Start-Sleep -Milliseconds 130; $r = Invoke-WebRequest $url -UserAgent $ua -UseBasicParsing -TimeoutSec 60; if ($r.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($r.Content) } else { return [string]$r.Content } }
    catch { if ($k -eq 4) { throw }; Start-Sleep -Seconds (3 * $k) }
  }
}
function IsinOf([string]$cusip) {          # ISIN americano = US + CUSIP + cifra di controllo (solo per CUSIP che iniziano con una cifra)
  if ($cusip -notmatch '^[0-9][0-9A-Z]{8}$') { return '' }
  $s = 'US' + $cusip; $d = ''; foreach ($c in $s.ToCharArray()) { if ($c -match '[A-Z]') { $d += ([int][char]$c - 55).ToString() } else { $d += $c } }
  $sum = 0; $dbl = $true; for ($i = $d.Length - 1; $i -ge 0; $i--) { $n = [int][string]$d[$i]; if ($dbl) { $n *= 2; if ($n -gt 9) { $n -= 9 } }; $sum += $n; $dbl = -not $dbl }
  return $s + ((10 - ($sum % 10)) % 10).ToString()
}

# ---- i gestori seguiti (c = codice SEC, n = nome, w = chi c'e' dietro, t = tipo) ----
$LISTA = @(
  @{ c = 1067983; n = 'Berkshire Hathaway'; w = 'Warren Buffett'; t = 'Holding' },
  @{ c = 1350694; n = 'Bridgewater Associates'; w = 'Ray Dalio'; t = 'Hedge fund' },
  @{ c = 1336528; n = 'Pershing Square'; w = 'Bill Ackman'; t = 'Hedge fund' },
  @{ c = 1029160; n = 'Soros Fund Management'; w = 'George Soros'; t = 'Family office' },
  @{ c = 1040273; n = 'Third Point'; w = 'Dan Loeb'; t = 'Hedge fund' },
  @{ c = 1656456; n = 'Appaloosa'; w = 'David Tepper'; t = 'Hedge fund' },
  @{ c = 1167483; n = 'Tiger Global'; w = 'Chase Coleman'; t = 'Hedge fund' },
  @{ c = 1536411; n = 'Duquesne Family Office'; w = 'Stanley Druckenmiller'; t = 'Family office' },
  @{ c = 1061768; n = 'Baupost Group'; w = 'Seth Klarman'; t = 'Hedge fund' },
  @{ c = 921669; n = 'Carl Icahn'; w = 'Carl Icahn'; t = 'Investitore attivista' },
  @{ c = 1791786; n = 'Elliott Management'; w = 'Paul Singer'; t = 'Investitore attivista' },
  @{ c = 1647251; n = 'TCI Fund Management'; w = 'Chris Hohn'; t = 'Investitore attivista' },
  @{ c = 1037389; n = 'Renaissance Technologies'; w = 'Fondo quantitativo (Jim Simons)'; t = 'Hedge fund' },
  @{ c = 1423053; n = 'Citadel Advisors'; w = 'Ken Griffin'; t = 'Hedge fund' },
  @{ c = 1603466; n = 'Point72'; w = 'Steve Cohen'; t = 'Hedge fund' },
  @{ c = 1179392; n = 'Two Sigma'; w = 'Fondo quantitativo'; t = 'Hedge fund' },
  @{ c = 1135730; n = 'Coatue Management'; w = 'Philippe Laffont'; t = 'Hedge fund' },
  @{ c = 1103804; n = 'Viking Global'; w = 'Andreas Halvorsen'; t = 'Hedge fund' },
  @{ c = 1061165; n = 'Lone Pine Capital'; w = 'Stephen Mandel'; t = 'Hedge fund' },
  @{ c = 1697748; n = 'ARK Invest'; w = 'Cathie Wood'; t = 'Gestore di ETF' },
  @{ c = 1549575; n = 'Dalal Street (Pabrai)'; w = 'Mohnish Pabrai'; t = 'Value investor' },
  @{ c = 1709323; n = 'Himalaya Capital'; w = 'Li Lu'; t = 'Value investor' },
  @{ c = 1112520; n = 'Akre Capital'; w = 'Chuck Akre'; t = 'Value investor' },
  @{ c = 1166559; n = 'Gates Foundation Trust'; w = 'Bill e Melinda Gates'; t = 'Fondazione' },
  @{ c = 1374170; n = 'Norges Bank'; w = 'Fondo sovrano della Norvegia'; t = 'Fondo sovrano' },
  @{ c = 93751; n = 'State Street'; w = 'Istituzione'; t = 'Istituzione' }
)

function Holdings([string]$cik, [string]$acc) {          # legge la tabella dei titoli di un 13F e somma per CUSIP (opzioni e obbligazioni escluse)
  $base = "https://www.sec.gov/Archives/edgar/data/$cik/" + ($acc -replace '-', '') + '/'
  $items = (Sec ($base + 'index.json') | ConvertFrom-Json).directory.item
  $f = $items | Where-Object { $_.name -like '*.xml' -and $_.name -ne 'primary_doc.xml' } | Sort-Object { [double]$_.size } -Descending | Select-Object -First 1
  if (-not $f) { throw 'tabella dei titoli non trovata' }
  $xml = [xml](Sec ($base + $f.name)); $map = @{}
  foreach ($n in $xml.SelectNodes('//*[local-name()="infoTable"]')) {
    $pc = $n.SelectSingleNode('*[local-name()="putCall"]'); if ($pc -and $pc.InnerText) { continue }
    $ty = $n.SelectSingleNode('*[local-name()="shrsOrPrnAmt"]/*[local-name()="sshPrnamtType"]').InnerText; if ($ty -ne 'SH') { continue }
    $cu = $n.SelectSingleNode('*[local-name()="cusip"]').InnerText.Trim().ToUpper(); $nm = $n.SelectSingleNode('*[local-name()="nameOfIssuer"]').InnerText.Trim()
    $val = [double]::Parse($n.SelectSingleNode('*[local-name()="value"]').InnerText, $inv); $sh = [double]::Parse($n.SelectSingleNode('*[local-name()="shrsOrPrnAmt"]/*[local-name()="sshPrnamt"]').InnerText, $inv)
    $ky = $cu.Substring(0, [math]::Min(6, $cu.Length))          # i primi 6 caratteri del CUSIP identificano l'emittente: le diverse classi di azioni (es. Alphabet A e C) si sommano
    if ($map.ContainsKey($ky)) { $map[$ky].v += $val; $map[$ky].s += $sh; $map[$ky].cus += $cu } else { $map[$ky] = @{ n = $nm; v = $val; s = $sh; cus = @($cu) } }
  }
  return $map
}
function IsinsOf($cus) { return @($cus | Select-Object -Unique | ForEach-Object { IsinOf $_ } | Where-Object { $_ }) }
function Cambi($now, $prev) {          # che cosa e' cambiato tra due fotografie: nuove, chiuse, aumentate, ridotte (valore del movimento = variazione delle azioni x prezzo)
  $r = @{ nuove = @(); chiuse = @(); aumentate = @(); ridotte = @() }; $cnt = @{}
  foreach ($cu in (@($now.Keys) + @($prev.Keys) | Select-Object -Unique)) {
    $a = $now[$cu]; $b = $prev[$cu]
    if ($a -and -not $b) { $r.nuove += @{ cu = $a.cus[0]; cus = $a.cus; n = $a.n; flusso = [math]::Round($a.v); pct = $null } }
    elseif ($b -and -not $a) { $r.chiuse += @{ cu = $b.cus[0]; cus = $b.cus; n = $b.n; flusso = [math]::Round(-$b.v); pct = $null } }
    elseif ($a -and $b -and $b.s -gt 0) {
      $d = $a.s - $b.s; $px = if ($a.s -gt 0) { $a.v / $a.s } else { 0 }; $p = $d / $b.s
      if ($p -ge 0.05) { $r.aumentate += @{ cu = $a.cus[0]; cus = $a.cus; n = $a.n; flusso = [math]::Round($d * $px); pct = [math]::Round($p, 3) } }
      elseif ($p -le -0.05) { $r.ridotte += @{ cu = $a.cus[0]; cus = $a.cus; n = $a.n; flusso = [math]::Round($d * $px); pct = [math]::Round($p, 3) } }
    }
  }
  foreach ($k in @($r.Keys)) { $cnt[$k] = @($r[$k]).Count }
  foreach ($k in 'nuove', 'aumentate') { $r[$k] = @($r[$k] | Sort-Object { $_.flusso } -Descending | Select-Object -First 10) }
  foreach ($k in 'chiuse', 'ridotte') { $r[$k] = @($r[$k] | Sort-Object { $_.flusso } | Select-Object -First 10) }
  foreach ($k in @($r.Keys)) { $r[$k] = @($r[$k] | ForEach-Object { $is = IsinsOf $_.cus; $_.isins = $is; $_.isin = $(if ($is.Count) { $is[0] } else { '' }); $_.Remove('cus'); $_ }) }
  $r.n = $cnt
  return $r
}

$fondi = @()
if (-not $SoloInsider) {
  foreach ($G in $LISTA) {
    try {
      $sub = Invoke-RestMethod ("https://data.sec.gov/submissions/CIK{0:D10}.json" -f $G.c) -UserAgent $ua -TimeoutSec 60; $r = $sub.filings.recent; $fl = @()
      for ($i = 0; $i -lt $r.form.Count; $i++) { if ($r.form[$i] -eq '13F-HR') { $fl += [pscustomobject]@{ acc = $r.accessionNumber[$i]; rep = $r.reportDate[$i]; dep = $r.filingDate[$i] } } }
      if ($fl.Count -lt 2) { '  saltato (pochi 13F): ' + $G.n; continue }
      $cur = $fl[0]; $prv = $fl[1]; $sem = if ($fl.Count -ge 3) { $fl[2] } else { $null }
      $keep = $null; if ($old) { $keep = @($old.fondi | Where-Object { $_.cik -eq $G.c -and $_.acc -eq $cur.acc })[0] }
      if ($keep) { $fondi += $keep; '  invariato: ' + $G.n; continue }
      $H1 = Holdings $G.c $cur.acc; $H0 = Holdings $G.c $prv.acc; $Hs = if ($sem) { Holdings $G.c $sem.acc } else { $null }
      $tot = ($H1.Values | ForEach-Object { $_.v } | Measure-Object -Sum).Sum; if (-not $tot) { $tot = 0 }
      $top = @($H1.GetEnumerator() | Sort-Object { $_.Value.v } -Descending | Select-Object -First 10 | ForEach-Object { [ordered]@{ cu = $_.Value.cus[0]; isin = $(@(IsinsOf $_.Value.cus)[0]); isins = @(IsinsOf $_.Value.cus); n = $_.Value.n; v = [math]::Round($_.Value.v); pct = $(if ($tot -gt 0) { [math]::Round($_.Value.v / $tot, 4) } else { 0 }) } })
      $c3 = Cambi $H1 $H0; $c6 = if ($Hs) { Cambi $H1 $Hs } else { $null }
      $fondi += [ordered]@{ cik = $G.c; acc = $cur.acc; nome = $G.n; chi = $G.w; tipo = $G.t; trimestre = $cur.rep; depositato = $cur.dep; precedente = $prv.rep; semestre = $(if ($sem) { $sem.rep } else { $null }); valore = [math]::Round($tot); posizioni = $H1.Count; top = $top; trim = $c3; sem = $c6 }
      '  ok: ' + $G.n + ' (' + $cur.rep + ', ' + $H1.Count + ' titoli)'
    } catch { '  ERRORE ' + $G.n + ': ' + $_.Exception.Message }
  }
} elseif ($old) { $fondi = @($old.fondi) }

# ---- dove vanno i soldi, tutti i gestori insieme: titoli piu' comprati e venduti (movimenti netti stimati) ----
$NOAGG = @(1423053, 1037389, 1179392, 1374170, 93751)          # fondi quantitativi, market maker e indicizzati: i loro movimenti sono meccanici, non scelte: non entrano nel conto di chi compra e vende
function Aggrega($per) {
  $m = @{}
  foreach ($f in $fondi) { if (-not $f.$per -or $NOAGG -contains [int64]$f.cik) { continue }; foreach ($k in 'nuove', 'aumentate', 'ridotte', 'chiuse') { foreach ($x in @($f.$per.$k)) {
    $id = $x.cu.Substring(0, [math]::Min(6, $x.cu.Length)); if (-not $m.ContainsKey($id)) { $m[$id] = @{ isin = $x.isin; isins = @(); cu = $x.cu; n = $x.n; netto = 0.0; compra = @(); vende = @() } }; foreach ($z in @($x.isins)) { if ($z) { $m[$id].isins += $z } }
    $m[$id].netto += [double]$x.flusso; if ([double]$x.flusso -ge 0) { $m[$id].compra += $f.nome } else { $m[$id].vende += $f.nome } } } }
  $l = @($m.Values | ForEach-Object { [ordered]@{ isin = $_.isin; isins = @($_.isins | Select-Object -Unique); cu = $_.cu; n = $_.n; netto = [math]::Round($_.netto); compra = @($_.compra | Select-Object -Unique); vende = @($_.vende | Select-Object -Unique) } })
  return [ordered]@{ comprati = @($l | Sort-Object { $_.netto } -Descending | Select-Object -First 15); venduti = @($l | Sort-Object { $_.netto } | Select-Object -First 15) }
}
$aggr = [ordered]@{ trim = (Aggrega 'trim'); sem = (Aggrega 'sem') }

# ---- insider: Form 4 giorno per giorno, solo acquisti (P) e vendite (S) sul mercato sopra 100.000 USD ----
$ins = [ordered]@{ giorniFatti = @(); operazioni = @() }
if ($old -and $old.insider) { $ins.giorniFatti = @($old.insider.giorniFatti); $ins.operazioni = @($old.insider.operazioni) }
if (-not $SoloFondi) {
  $dt = (Get-Date).ToUniversalTime().Date.AddDays(-1); $todo = @(); $guard = 0
  while ($todo.Count -lt $GiorniInsider -and $guard -lt 12) { if ($dt.DayOfWeek -ne 'Saturday' -and $dt.DayOfWeek -ne 'Sunday') { $ds = $dt.ToString('yyyyMMdd'); if ($ins.giorniFatti -notcontains $ds) { $todo += $ds } }; $dt = $dt.AddDays(-1); $guard++ }
  foreach ($ds in $todo) {
    try {
      $q = [int][math]::Ceiling([int]$ds.Substring(4, 2) / 3.0); $idx = Sec ('https://www.sec.gov/Archives/edgar/daily-index/' + $ds.Substring(0, 4) + "/QTR$q/form.$ds.idx")
      $righe = [regex]::Matches($idx, '(?m)^4 {2,}.*?edgar/data/(\d+)/(\d{10}-\d{2}-\d{6})\.txt'); $visti = @{}; $n = 0; $nn = 0
      foreach ($m in $righe) {
        $acc = $m.Groups[2].Value; if ($visti.ContainsKey($acc)) { continue }; $visti[$acc] = 1; $n++
        try {
          $t = Sec ('https://www.sec.gov/Archives/edgar/data/' + $m.Groups[1].Value + '/' + $acc + '.txt')
          $mm = [regex]::Match($t, '<ownershipDocument>[\s\S]*?</ownershipDocument>'); if (-not $mm.Success) { continue }
          $d = [xml]$mm.Value; $iss = $d.ownershipDocument.issuer; $ro = @($d.ownershipDocument.reportingOwner)[0]; $rel = $ro.reportingOwnerRelationship
          $ruolo = if ($rel.officerTitle) { [string]$rel.officerTitle } elseif ($rel.isDirector -in '1', 'true') { 'Amministratore' } elseif ($rel.isTenPercentOwner -in '1', 'true') { 'Azionista oltre 10%' } elseif ($rel.isOfficer -in '1', 'true') { 'Dirigente' } else { 'Altro' }
          $agg = @{}
          foreach ($tx in @($d.ownershipDocument.nonDerivativeTable.nonDerivativeTransaction)) {
            if (-not $tx) { continue }; $code = [string]$tx.transactionCoding.transactionCode; if ($code -ne 'P' -and $code -ne 'S') { continue }
            $sh = [double]::Parse([string]$tx.transactionAmounts.transactionShares.value, $inv); $px = 0.0; if ($tx.transactionAmounts.transactionPricePerShare.value) { $px = [double]::Parse([string]$tx.transactionAmounts.transactionPricePerShare.value, $inv) }
            $k = $code + '|' + [string]$tx.transactionDate.value; if (-not $agg.ContainsKey($k)) { $agg[$k] = @{ code = $code; data = [string]$tx.transactionDate.value; sh = 0.0; val = 0.0 } }; $agg[$k].sh += $sh; $agg[$k].val += $sh * $px
          }
          foreach ($a in $agg.Values) { if ($a.val -lt 100000) { continue }
            $ins.operazioni += [ordered]@{ data = $a.data.Substring(0, 10); deposito = $ds.Substring(0, 4) + '-' + $ds.Substring(4, 2) + '-' + $ds.Substring(6, 2); societa = [string]$iss.issuerName; ticker = [string]$iss.issuerTradingSymbol; insider = [string]$ro.reportingOwnerId.rptOwnerName; ruolo = $ruolo; tipo = $a.code; azioni = [math]::Round($a.sh); prezzo = [math]::Round($a.val / [math]::Max($a.sh, 1), 2); valore = [math]::Round($a.val); acc = $acc; cik = [string]$iss.issuerCik }; $nn++ }
        } catch { }
      }
      $ins.giorniFatti = @($ins.giorniFatti) + $ds; "  insider ${ds}: $n depositi letti, $nn operazioni sopra 100.000 USD"
    } catch { "  insider ${ds}: non disponibile (" + $_.Exception.Message + ')' }
  }
  $lim = (Get-Date).ToUniversalTime().Date.AddDays(-45).ToString('yyyy-MM-dd')          # si tengono 45 giorni
  $ins.operazioni = @($ins.operazioni | Where-Object { $_.deposito -ge $lim } | Sort-Object { $_.valore } -Descending)
  $ins.giorniFatti = @($ins.giorniFatti | Sort-Object -Descending | Select-Object -First 60)
  if ($ins.operazioni.Count -gt 1500) { $ins.operazioni = @($ins.operazioni | Select-Object -First 1500) }
}
$res = [ordered]@{ generato = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); fonte = 'SEC EDGAR (13F e Form 4)'; fondi = $fondi; escludiAgg = $NOAGG; aggregato = $aggr; insider = $ins }
if (-not (Test-Path $Uscita)) { New-Item -ItemType Directory $Uscita -Force | Out-Null }
if (@($fondi).Count -eq 0 -and -not $SoloInsider) { if ($old -and @($old.fondi).Count) { 'Nessun portafoglio letto ora: tengo i dati di prima.'; return }; throw 'Nessun portafoglio letto: non scrivo un file vuoto.' }
[IO.File]::WriteAllText($out, ($res | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false)))
'Scritto ' + $out + ' (' + [math]::Round((Get-Item $out).Length / 1KB) + ' KB): ' + @($fondi).Count + ' gestori, ' + @($ins.operazioni).Count + ' operazioni insider'
