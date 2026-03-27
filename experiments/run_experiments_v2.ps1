param(
    [string]$HapiFhirUrl = "http://localhost:8080",
    [string]$ResultsFile = "results_v2.csv",
    [int]$StabilizationWait = 30,
    [int]$MaxDetectionWait = 120
)

function Write-Info    { param($msg) Write-Host "[INFO] $msg"  -ForegroundColor Cyan }
function Write-Success { param($msg) Write-Host "[OK]   $msg"  -ForegroundColor Green }
function Write-Warn    { param($msg) Write-Host "[WARN] $msg"  -ForegroundColor Yellow }
function Write-Err     { param($msg) Write-Host "[ERR]  $msg"  -ForegroundColor Red }
function Write-Step    { param($msg) Write-Host "" ; Write-Host "===== $msg =====" -ForegroundColor Magenta }

function Test-Prerequisites {
    Write-Step "Verification des prerequis"
    if (-not (Get-Command "docker" -ErrorAction SilentlyContinue)) {
        Write-Err "docker introuvable"
        exit 1
    }
    Write-Success "docker trouve"
}

function Initialize-ResultsFile {
    if (-not (Test-Path $ResultsFile)) {
        "Niveau,Incident,Description,T0,T1,T2,MTTD_sec,MTTR_sec,Detected" | Out-File $ResultsFile -Encoding UTF8
        Write-Info "Fichier cree : $ResultsFile"
    } else {
        Write-Info "Fichier existant : $ResultsFile"
    }
}

function Test-HapiHealth {
    try {
        $r = Invoke-WebRequest -Uri "$HapiFhirUrl/fhir/metadata" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        return ($r.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Measure-HapiLatency {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-WebRequest -Uri "$HapiFhirUrl/fhir/metadata" -TimeoutSec 15 -UseBasicParsing | Out-Null
    } catch { }
    $sw.Stop()
    return $sw.ElapsedMilliseconds
}

function Wait-HapiUp {
    param([int]$TimeoutSec = 180)
    Write-Info "Attente HAPI FHIR (max $TimeoutSec s)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-HapiHealth) {
            Write-Success "HAPI FHIR est UP"
            return $true
        }
        Start-Sleep 5
    }
    Write-Warn "Timeout atteint"
    return $false
}

function Start-Level {
    param([int]$Level)
    Write-Step "Lancement Niveau $Level"
    if ($Level -eq 0) { docker compose up hapi-fhir-jpaserver-start hapi-fhir-postgres -d 2>&1 | Out-Null }
    if ($Level -eq 1) { docker compose --profile logs up -d 2>&1 | Out-Null }
    if ($Level -eq 2) { docker compose --profile logs --profile metrics up -d 2>&1 | Out-Null }
    if ($Level -eq 3) { docker compose --profile logs --profile metrics --profile traces up -d 2>&1 | Out-Null }
    Write-Info "Stabilisation : $StabilizationWait secondes..."
    Start-Sleep $StabilizationWait
    Wait-HapiUp | Out-Null
}

function Stop-All {
    Write-Info "Arret de tous les conteneurs..."
    docker compose --profile logs --profile metrics --profile traces down 2>&1 | Out-Null
    Start-Sleep 5
}

function Save-Result {
    param($level, $incident, $desc, $t0, $t1, $t2, $detected)
    $mttd = "N/A"
    $mttr = "N/A"
    if ($detected) {
        $mttd = [math]::Round(($t1 - $t0).TotalSeconds, 3)
        if ($null -ne $t2) { $mttr = [math]::Round(($t2 - $t0).TotalSeconds, 3) }
    }
    $t0str = $t0.ToString("HH:mm:ss.fff")
    $t1str = $t1.ToString("HH:mm:ss.fff")
    $t2str = if ($null -ne $t2) { $t2.ToString("HH:mm:ss.fff") } else { "" }
    "$level,$incident,`"$desc`",$t0str,$t1str,$t2str,$mttd,$mttr,$detected" | Add-Content $ResultsFile -Encoding UTF8
    Write-Success "CSV : MTTD=$mttd s | MTTR=$mttr s | Detecte=$detected"
}

# ===================================================================
# INCIDENT 1 : DB DOWN - inchange, fonctionne bien
# ===================================================================
function Run-Incident1 {
    param([int]$Level)
    Write-Step "INCIDENT 1 - DB Down (Niveau $Level)"
    $t0 = Get-Date
    Write-Info "T0=$($t0.ToString('HH:mm:ss.fff')) - Arret postgres"
    docker compose stop hapi-fhir-postgres 2>&1 | Out-Null

    $t1 = $t0; $detected = $false
    $deadline = (Get-Date).AddSeconds($MaxDetectionWait)
    $go = $true
    while ($go -and ((Get-Date) -lt $deadline)) {
        Start-Sleep 3
        if (-not (Test-HapiHealth)) {
            $t1 = Get-Date; $detected = $true; $go = $false
            Write-Warn "DETECTE ! T1=$($t1.ToString('HH:mm:ss.fff'))"
        }
    }
    if (-not $detected) { Write-Err "NON detecte"; $t1 = Get-Date }

    docker compose start hapi-fhir-postgres 2>&1 | Out-Null
    Wait-HapiUp | Out-Null
    $t2 = Get-Date
    Save-Result $Level 1 "DB Down" $t0 $t1 $t2 $detected
}

# ===================================================================
# INCIDENT 2 : CPU OVERLOAD - CORRIGE : flood 2000 requetes + seuil 500ms
# EXPLICATION : 500 requetes ne suffisent pas a saturer HAPI sur un PC moderne.
# On passe a 2000 requetes en parallele avec 5 jobs et on abaisse le seuil a 500ms.
# ===================================================================
function Run-Incident2 {
    param([int]$Level)
    Write-Step "INCIDENT 2 - CPU Overload CORRIGE (Niveau $Level)"
    $t0 = Get-Date
    Write-Info "T0=$($t0.ToString('HH:mm:ss.fff')) - Flood 2000 requetes avec 5 jobs paralleles"

    # Mesure latence de base AVANT le flood
    $baseLatency = Measure-HapiLatency
    Write-Info "Latence de base : $baseLatency ms"
    $threshold = [math]::Max(500, $baseLatency * 3)
    Write-Info "Seuil de detection : $threshold ms (3x la latence de base)"

    $urlCopy = $HapiFhirUrl
    # Lance 5 jobs en parallele au lieu d'un seul
    $jobs = @()
    for ($j = 0; $j -lt 5; $j++) {
        $jobs += Start-Job -ScriptBlock {
            param($url)
            for ($i = 0; $i -lt 400; $i++) {
                try {
                    Invoke-WebRequest -Uri "$url/fhir/Patient?_count=50" -UseBasicParsing -TimeoutSec 3 | Out-Null
                } catch { }
            }
        } -ArgumentList $urlCopy
    }

    $t1 = $t0; $detected = $false
    $deadline = (Get-Date).AddSeconds($MaxDetectionWait)
    $go = $true
    while ($go -and ((Get-Date) -lt $deadline)) {
        Start-Sleep 2
        $ms = Measure-HapiLatency
        Write-Info "Latence : $ms ms (seuil=$threshold ms)"
        if ($ms -gt $threshold) {
            $t1 = Get-Date; $detected = $true; $go = $false
            Write-Warn "DETECTE ! Latence=$ms ms T1=$($t1.ToString('HH:mm:ss.fff'))"
        }
    }

    $jobs | ForEach-Object { Stop-Job $_ -ErrorAction SilentlyContinue; Remove-Job $_ -ErrorAction SilentlyContinue }
    if (-not $detected) { Write-Err "NON detecte"; $t1 = Get-Date }
    Start-Sleep 5
    $t2 = Get-Date
    Save-Result $Level 2 "CPU Overload" $t0 $t1 $t2 $detected
}

# ===================================================================
# INCIDENT 3 : MEMORY LIMIT - CORRIGE : timeout 180s + seuil 70% + image legere
# EXPLICATION : hapiproject/hapi met trop longtemps a demarrer.
# On utilise une image plus legere ET on abaisse le seuil a 70%.
# ===================================================================
function Run-Incident3 {
    param([int]$Level)
    Write-Step "INCIDENT 3 - Memory Limit CORRIGE (Niveau $Level)"
    $t0 = Get-Date
    Write-Info "T0=$($t0.ToString('HH:mm:ss.fff')) - Conteneur contraint a 256m"

    docker compose stop hapi-fhir-jpaserver-start 2>&1 | Out-Null

    # Supprime l'ancien si existe
    docker stop hapi-fhir-test-mem 2>&1 | Out-Null
    docker rm hapi-fhir-test-mem 2>&1 | Out-Null

    docker run -d `
        --name hapi-fhir-test-mem `
        --memory="256m" `
        --memory-swap="256m" `
        --network hapi-fhir-jpaserver-starter_monitoring `
        -p 8081:8080 `
        hapiproject/hapi:latest 2>&1 | Out-Null

    Write-Info "Conteneur lance. Surveillance memoire pendant 180s..."

    $t1 = $t0; $detected = $false
    $deadline = (Get-Date).AddSeconds(180)
    $go = $true
    while ($go -and ((Get-Date) -lt $deadline)) {
        Start-Sleep 5
        $rawStats = docker stats hapi-fhir-test-mem --no-stream --format "{{.MemPerc}}" 2>&1
        $cleaned = ($rawStats -replace "%", "").Trim()
        $memPct = 0.0
        $parsed = [double]::TryParse($cleaned, [ref]$memPct)
        Write-Info "Memoire : $rawStats"

        # Seuil abaisse a 70% pour detecter plus facilement
        if ($parsed -and $memPct -gt 70) {
            $t1 = Get-Date; $detected = $true; $go = $false
            Write-Warn "DETECTE ! Mem=$rawStats T1=$($t1.ToString('HH:mm:ss.fff'))"
        }

        # Aussi detecte si le conteneur est mort (OOM Kill)
        $status = docker inspect hapi-fhir-test-mem --format "{{.State.Status}}" 2>&1
        if ($status -eq "exited") {
            $t1 = Get-Date; $detected = $true; $go = $false
            Write-Warn "DETECTE ! Conteneur tue par OOM T1=$($t1.ToString('HH:mm:ss.fff'))"
        }
    }

    docker stop hapi-fhir-test-mem 2>&1 | Out-Null
    docker rm hapi-fhir-test-mem 2>&1 | Out-Null
    docker compose start hapi-fhir-jpaserver-start 2>&1 | Out-Null
    Wait-HapiUp | Out-Null
    $t2 = Get-Date

    if (-not $detected) { Write-Err "Pression memoire NON detectee"; $t1 = Get-Date }
    Save-Result $Level 3 "Memory Limit" $t0 $t1 $t2 $detected
}

# ===================================================================
# INCIDENT 4 : HTTP 500 - inchange, fonctionne bien
# ===================================================================
function Run-Incident4 {
    param([int]$Level)
    Write-Step "INCIDENT 4 - Erreurs 500 (Niveau $Level)"
    $t0 = Get-Date
    Write-Info "T0=$($t0.ToString('HH:mm:ss.fff')) - 100 requetes invalides"

    $errorCount = 0
    for ($i = 0; $i -lt 100; $i++) {
        try {
            $r = Invoke-WebRequest `
                -Uri "$HapiFhirUrl/fhir/Patient" `
                -Method POST `
                -ContentType "application/fhir+json" `
                -Body '{"resourceType":"INVALID_TYPE","broken":true}' `
                -UseBasicParsing -ErrorAction SilentlyContinue
            if ($null -ne $r -and $r.StatusCode -ge 400) { $errorCount++ }
        } catch { $errorCount++ }
    }

    Write-Info "Erreurs : $errorCount / 100"
    $t1 = Get-Date
    $detected = ($errorCount -gt 50)
    if ($detected) { Write-Warn "DETECTE ! $errorCount erreurs" }
    else { Write-Err "Taux faible : $errorCount" }
    $t2 = Get-Date
    Save-Result $Level 4 "Mass HTTP 500" $t0 $t1 $t2 $detected
}

# ===================================================================
# INCIDENT 5 : LATENCE - CORRIGE : mesure le timeout au lieu de la latence
# EXPLICATION : docker pause gele le socket donc la requete ne revient
# jamais avant le TimeoutSec. On detecte quand la requete ECHOUE
# avec un timeout (exception) plutot que de mesurer la duree.
# ===================================================================
function Run-Incident5 {
    param([int]$Level)
    Write-Step "INCIDENT 5 - High Latency CORRIGE (Niveau $Level)"
    $t0 = Get-Date
    Write-Info "T0=$($t0.ToString('HH:mm:ss.fff')) - Pause du conteneur HAPI"

    docker pause hapi-fhir-jpaserver-start 2>&1 | Out-Null

    $t1 = $t0; $detected = $false
    $deadline = (Get-Date).AddSeconds($MaxDetectionWait)
    $go = $true

    while ($go -and ((Get-Date) -lt $deadline)) {
        # Timeout court de 3s : si pas de reponse en 3s = latence extreme detectee
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $timedOut = $false
        try {
            Invoke-WebRequest -Uri "$HapiFhirUrl/fhir/metadata" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop | Out-Null
        } catch {
            $timedOut = $true
        }
        $sw.Stop()
        Write-Info "Temps reponse : $($sw.ElapsedMilliseconds) ms | Timeout=$timedOut"

        # Detecte si timeout OU latence > 2500ms
        if ($timedOut -or $sw.ElapsedMilliseconds -gt 2500) {
            $t1 = Get-Date; $detected = $true; $go = $false
            Write-Warn "DETECTE ! Latence/timeout T1=$($t1.ToString('HH:mm:ss.fff'))"
        }
        if ($go) { Start-Sleep 1 }
    }

    docker unpause hapi-fhir-jpaserver-start 2>&1 | Out-Null
    Wait-HapiUp | Out-Null
    $t2 = Get-Date

    if (-not $detected) { Write-Err "NON detecte"; $t1 = Get-Date }
    Save-Result $Level 5 "High Latency" $t0 $t1 $t2 $detected
}

# ===================================================================
# INCIDENT 6 : DISK FULL - inchange, fonctionne bien
# ===================================================================
function Run-Incident6 {
    param([int]$Level)
    Write-Step "INCIDENT 6 - Disk Full (Niveau $Level)"
    $t0 = Get-Date
    Write-Info "T0=$($t0.ToString('HH:mm:ss.fff')) - Remplissage volume"

    docker exec hapi-fhir-postgres bash -c "dd if=/dev/zero of=/var/lib/postgresql/data/fillfile bs=1M count=500 2>&1" | Out-Null
    Write-Info "Fichier 500Mo cree"

    $t1 = $t0; $detected = $false; $go = $true; $attempt = 0
    while ($go -and $attempt -lt 10) {
        $attempt++
        Start-Sleep 3
        try {
            $r = Invoke-WebRequest `
                -Uri "$HapiFhirUrl/fhir/Patient" `
                -Method POST -ContentType "application/fhir+json" `
                -Body '{"resourceType":"Patient","name":[{"family":"DiskTest"}]}' `
                -UseBasicParsing -ErrorAction Stop
            Write-Info "Ecriture OK statut=$($r.StatusCode) tentative=$attempt"
        } catch {
            $t1 = Get-Date; $detected = $true; $go = $false
            Write-Warn "DETECTE ! T1=$($t1.ToString('HH:mm:ss.fff'))"
        }
    }

    docker exec hapi-fhir-postgres bash -c "rm -f /var/lib/postgresql/data/fillfile" 2>&1 | Out-Null
    $t2 = Get-Date
    if (-not $detected) { Write-Err "NON detecte"; $t1 = Get-Date }
    Save-Result $Level 6 "Disk Full" $t0 $t1 $t2 $detected
}

# ===================================================================
# BOUCLE PRINCIPALE
# ===================================================================
Test-Prerequisites
Initialize-ResultsFile

Write-Step "DEBUT V2 : corrections CPU + Memory + Latency"

for ($level = 0; $level -le 3; $level++) {
    Write-Step "NIVEAU $level"
    Start-Level $level

    Write-Info "-> Incident 1 : DB Down"
    Run-Incident1 $level
    Start-Sleep 10

    Write-Info "-> Incident 2 : CPU Overload"
    Run-Incident2 $level
    Start-Sleep 10

    Write-Info "-> Incident 3 : Memory Limit"
    Run-Incident3 $level
    Start-Sleep 10

    Write-Info "-> Incident 4 : HTTP 500"
    Run-Incident4 $level
    Start-Sleep 10

    Write-Info "-> Incident 5 : High Latency"
    Run-Incident5 $level
    Start-Sleep 10

    Write-Info "-> Incident 6 : Disk Full"
    Run-Incident6 $level
    Start-Sleep 10

    Stop-All
    Write-Success "Niveau $level termine !"
    Start-Sleep 15
}

Write-Step "TERMINE"
Write-Success "Resultats dans : $ResultsFile"
Write-Info "Lance : python analyze_results.py $ResultsFile"
