param(
    [string]$HapiFhirUrl = "http://localhost:8080",
    [string]$ResultsFile = "results.csv",
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
    $ok = $true
    if (-not (Get-Command "docker" -ErrorAction SilentlyContinue)) {
        Write-Err "docker introuvable dans le PATH"
        $ok = $false
    } else {
        Write-Success "docker trouve"
    }
    if (-not $ok) { exit 1 }
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
    Write-Warn "Timeout atteint - HAPI ne repond pas"
    return $false
}

function Start-Level {
    param([int]$Level)
    Write-Step "Lancement Niveau $Level"
    if ($Level -eq 0) {
        docker compose up hapi-fhir-jpaserver-start hapi-fhir-postgres -d 2>&1 | Out-Null
    }
    if ($Level -eq 1) {
        docker compose --profile logs up -d 2>&1 | Out-Null
    }
    if ($Level -eq 2) {
        docker compose --profile logs --profile metrics up -d 2>&1 | Out-Null
    }
    if ($Level -eq 3) {
        docker compose --profile logs --profile metrics --profile traces up -d 2>&1 | Out-Null
    }
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
        if ($null -ne $t2) {
            $mttr = [math]::Round(($t2 - $t0).TotalSeconds, 3)
        }
    }
    $t0str = $t0.ToString("HH:mm:ss.fff")
    $t1str = $t1.ToString("HH:mm:ss.fff")
    $t2str = ""
    if ($null -ne $t2) {
        $t2str = $t2.ToString("HH:mm:ss.fff")
    }
    $line = "$level,$incident,`"$desc`",$t0str,$t1str,$t2str,$mttd,$mttr,$detected"
    $line | Add-Content $ResultsFile -Encoding UTF8
    Write-Success "CSV mis a jour : MTTD=$mttd s | MTTR=$mttr s | Detecte=$detected"
}

# -------------------------------------------------------------------
# INCIDENT 1 : Base de donnees DOWN
# -------------------------------------------------------------------
function Run-Incident1 {
    param([int]$Level)
    Write-Step "INCIDENT 1 - DB Down (Niveau $Level)"
    $desc = "DB Down"
    $t0 = Get-Date
    Write-Info "T0=$($t0.ToString('HH:mm:ss.fff')) - Arret postgres"

    docker compose stop hapi-fhir-postgres 2>&1 | Out-Null

    $t1 = $t0
    $detected = $false
    $deadline = (Get-Date).AddSeconds($MaxDetectionWait)
    $continueLoop = $true

    while ($continueLoop -and ((Get-Date) -lt $deadline)) {
        Start-Sleep 3
        $healthy = Test-HapiHealth
        if (-not $healthy) {
            $t1 = Get-Date
            $detected = $true
            $continueLoop = $false
            Write-Warn "DETECTE ! HAPI ne repond plus. T1=$($t1.ToString('HH:mm:ss.fff'))"
        }
    }

    if (-not $detected) {
        Write-Err "NON detecte apres $MaxDetectionWait s"
        $t1 = Get-Date
    }

    Write-Info "Resolution : redemarrage postgres"
    docker compose start hapi-fhir-postgres 2>&1 | Out-Null
    Wait-HapiUp | Out-Null
    $t2 = Get-Date
    Write-Info "T2=$($t2.ToString('HH:mm:ss.fff')) - HAPI repond"

    Save-Result $Level 1 $desc $t0 $t1 $t2 $detected
}

# -------------------------------------------------------------------
# INCIDENT 2 : Surcharge CPU
# -------------------------------------------------------------------
function Run-Incident2 {
    param([int]$Level)
    Write-Step "INCIDENT 2 - CPU Overload (Niveau $Level)"
    $desc = "CPU Overload"
    $t0 = Get-Date
    Write-Info "T0=$($t0.ToString('HH:mm:ss.fff')) - Flood 500 requetes"

    $urlCopy = $HapiFhirUrl
    $job = Start-Job -ScriptBlock {
        param($url)
        for ($i = 0; $i -lt 500; $i++) {
            try {
                Invoke-WebRequest -Uri "$url/fhir/Patient" -UseBasicParsing -TimeoutSec 2 | Out-Null
            } catch { }
        }
    } -ArgumentList $urlCopy

    $t1 = $t0
    $detected = $false
    $deadline = (Get-Date).AddSeconds($MaxDetectionWait)
    $continueLoop = $true

    while ($continueLoop -and ((Get-Date) -lt $deadline)) {
        Start-Sleep 3
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-WebRequest -Uri "$HapiFhirUrl/fhir/metadata" -TimeoutSec 10 -UseBasicParsing | Out-Null
        } catch { }
        $sw.Stop()
        $ms = $sw.ElapsedMilliseconds
        Write-Info "Latence mesure : $ms ms"
        if ($ms -gt 3000) {
            $t1 = Get-Date
            $detected = $true
            $continueLoop = $false
            Write-Warn "DETECTE ! Latence=$ms ms T1=$($t1.ToString('HH:mm:ss.fff'))"
        }
    }

    Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $job -ErrorAction SilentlyContinue | Out-Null

    if (-not $detected) {
        Write-Err "Degradation NON detectee"
        $t1 = Get-Date
    }

    Start-Sleep 5
    $t2 = Get-Date
    Save-Result $Level 2 $desc $t0 $t1 $t2 $detected
}

# -------------------------------------------------------------------
# INCIDENT 3 : Limite memoire 256 Mo
# -------------------------------------------------------------------
function Run-Incident3 {
    param([int]$Level)
    Write-Step "INCIDENT 3 - Memory Limit (Niveau $Level)"
    $desc = "Memory Limit"
    $t0 = Get-Date
    Write-Info "T0=$($t0.ToString('HH:mm:ss.fff')) - Redemarrage avec 256m"

    docker compose stop hapi-fhir-jpaserver-start 2>&1 | Out-Null

    docker run -d `
        --name hapi-fhir-test-mem `
        --memory="256m" `
        --network hapi-fhir-jpaserver-starter_monitoring `
        -p 8081:8080 `
        hapiproject/hapi:latest 2>&1 | Out-Null

    $t1 = $t0
    $detected = $false
    $deadline = (Get-Date).AddSeconds(90)
    $continueLoop = $true

    while ($continueLoop -and ((Get-Date) -lt $deadline)) {
        Start-Sleep 5
        $rawStats = docker stats hapi-fhir-test-mem --no-stream --format "{{.MemPerc}}" 2>&1
        $cleaned = ($rawStats -replace "%", "").Trim()
        $memPct = 0.0
        $ok = [double]::TryParse($cleaned, [ref]$memPct)
        Write-Info "Memoire : $rawStats"
        if ($ok -and $memPct -gt 85) {
            $t1 = Get-Date
            $detected = $true
            $continueLoop = $false
            Write-Warn "DETECTE ! Mem=$rawStats T1=$($t1.ToString('HH:mm:ss.fff'))"
        }
    }

    docker stop hapi-fhir-test-mem 2>&1 | Out-Null
    docker rm   hapi-fhir-test-mem 2>&1 | Out-Null
    docker compose start hapi-fhir-jpaserver-start 2>&1 | Out-Null
    Wait-HapiUp | Out-Null
    $t2 = Get-Date

    if (-not $detected) {
        Write-Err "Pression memoire NON detectee"
        $t1 = Get-Date
    }

    Save-Result $Level 3 $desc $t0 $t1 $t2 $detected
}

# -------------------------------------------------------------------
# INCIDENT 4 : Erreurs HTTP 500
# -------------------------------------------------------------------
function Run-Incident4 {
    param([int]$Level)
    Write-Step "INCIDENT 4 - Erreurs 500 (Niveau $Level)"
    $desc = "Mass HTTP 500"
    $t0 = Get-Date
    Write-Info "T0=$($t0.ToString('HH:mm:ss.fff')) - Envoi 100 requetes invalides"

    $errorCount = 0
    for ($i = 0; $i -lt 100; $i++) {
        try {
            $r = Invoke-WebRequest `
                -Uri "$HapiFhirUrl/fhir/Patient" `
                -Method POST `
                -ContentType "application/fhir+json" `
                -Body '{"resourceType":"INVALID_TYPE","broken":true}' `
                -UseBasicParsing `
                -ErrorAction SilentlyContinue
            if ($null -ne $r -and $r.StatusCode -ge 400) {
                $errorCount++
            }
        } catch {
            $errorCount++
        }
    }

    Write-Info "Erreurs : $errorCount / 100"
    $t1 = Get-Date
    $detected = ($errorCount -gt 50)

    if ($detected) {
        Write-Warn "DETECTE ! $errorCount erreurs T1=$($t1.ToString('HH:mm:ss.fff'))"
    } else {
        Write-Err "Taux faible : $errorCount%"
    }

    $t2 = Get-Date
    Save-Result $Level 4 $desc $t0 $t1 $t2 $detected
}

# -------------------------------------------------------------------
# INCIDENT 5 : Latence (pause conteneur)
# -------------------------------------------------------------------
function Run-Incident5 {
    param([int]$Level)
    Write-Step "INCIDENT 5 - High Latency (Niveau $Level)"
    $desc = "High Latency"
    $t0 = Get-Date
    Write-Info "T0=$($t0.ToString('HH:mm:ss.fff')) - Pause du conteneur HAPI"

    docker pause hapi-fhir-jpaserver-start 2>&1 | Out-Null

    $t1 = $t0
    $detected = $false
    $deadline = (Get-Date).AddSeconds($MaxDetectionWait)
    $continueLoop = $true

    while ($continueLoop -and ((Get-Date) -lt $deadline)) {
        Start-Sleep 3
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-WebRequest -Uri "$HapiFhirUrl/fhir/metadata" -TimeoutSec 8 -UseBasicParsing | Out-Null
        } catch { }
        $sw.Stop()
        Write-Info "Latence : $($sw.ElapsedMilliseconds) ms"
        if ($sw.ElapsedMilliseconds -gt 5000) {
            $t1 = Get-Date
            $detected = $true
            $continueLoop = $false
            Write-Warn "DETECTE ! Latence extreme T1=$($t1.ToString('HH:mm:ss.fff'))"
        }
    }

    docker unpause hapi-fhir-jpaserver-start 2>&1 | Out-Null
    Wait-HapiUp | Out-Null
    $t2 = Get-Date

    if (-not $detected) {
        Write-Err "Latence NON detectee"
        $t1 = Get-Date
    }

    Save-Result $Level 5 $desc $t0 $t1 $t2 $detected
}

# -------------------------------------------------------------------
# INCIDENT 6 : Disque plein
# -------------------------------------------------------------------
function Run-Incident6 {
    param([int]$Level)
    Write-Step "INCIDENT 6 - Disk Full (Niveau $Level)"
    $desc = "Disk Full"
    $t0 = Get-Date
    Write-Info "T0=$($t0.ToString('HH:mm:ss.fff')) - Remplissage volume postgres"

    docker exec hapi-fhir-postgres bash -c "dd if=/dev/zero of=/var/lib/postgresql/data/fillfile bs=1M count=500 2>&1" | Out-Null
    Write-Info "Fichier 500Mo cree"

    $t1 = $t0
    $detected = $false
    $continueLoop = $true
    $attempt = 0

    while ($continueLoop -and $attempt -lt 10) {
        $attempt++
        Start-Sleep 3
        try {
            $r = Invoke-WebRequest `
                -Uri "$HapiFhirUrl/fhir/Patient" `
                -Method POST `
                -ContentType "application/fhir+json" `
                -Body '{"resourceType":"Patient","name":[{"family":"DiskTest"}]}' `
                -UseBasicParsing `
                -ErrorAction Stop
            Write-Info "Ecriture OK (statut $($r.StatusCode)) - tentative $attempt"
        } catch {
            $t1 = Get-Date
            $detected = $true
            $continueLoop = $false
            Write-Warn "DETECTE ! Erreur ecriture T1=$($t1.ToString('HH:mm:ss.fff'))"
        }
    }

    docker exec hapi-fhir-postgres bash -c "rm -f /var/lib/postgresql/data/fillfile" 2>&1 | Out-Null
    Write-Info "Volume nettoye"
    $t2 = Get-Date

    if (-not $detected) {
        Write-Err "Incident disque NON detecte"
        $t1 = Get-Date
    }

    Save-Result $Level 6 $desc $t0 $t1 $t2 $detected
}

# ===================================================================
# BOUCLE PRINCIPALE
# ===================================================================
Test-Prerequisites
Initialize-ResultsFile

Write-Step "DEBUT DES EXPERIENCES : 4 niveaux x 6 incidents = 24 tests"

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

Write-Step "TOUTES LES EXPERIENCES SONT TERMINEES"
Write-Success "Resultats dans : $ResultsFile"
Write-Info "Prochaine etape : python analyze_results.py $ResultsFile"