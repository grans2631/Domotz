# ============================================================
# DOMOTZ DISABLED DRIVER RETRY - CONTROLLED TEST
# ============================================================

$BaseUrl = $BaseUrl.TrimEnd('/')

function Get-DisabledDomotzDrivers {

    $Disabled = @()

    $Page = 0
    $PageSize = 100

    do {

        $AgentUri = "$BaseUrl/agent?page_size=$PageSize&page_number=$Page"

        try {
            $AgentResponse = Invoke-RestMethod `
                -Method GET `
                -Uri $AgentUri `
                -Headers $Headers
        }
        catch {
            throw "Failed retrieving agents on page $Page : $($_.Exception.Message)"
        }

        $Agents = @($AgentResponse)

        foreach ($Agent in $Agents) {

            $AssociationUri = "$BaseUrl/custom-driver/agent/$($Agent.id)/association"

            try {

                $Associations = @(
                    Invoke-RestMethod `
                        -Method GET `
                        -Uri $AssociationUri `
                        -Headers $Headers
                )

            }
            catch {

                Write-Warning "Association lookup failed for $($Agent.display_name) [$($Agent.id)]"
                Write-Warning $_.Exception.Message

                # For safety, abort instead of returning an incomplete snapshot
                throw "Unable to build a complete disabled-driver snapshot."
            }

            foreach ($Association in $Associations) {

                if ($Association.status -eq "DISABLED") {

                    $Disabled += [PSCustomObject]@{
                        AgentName          = $Agent.display_name
                        AgentID            = $Agent.id
                        DeviceID           = $Association.device_id
                        DriverID           = $Association.custom_driver_id
                        AssociationID      = $Association.id
                        Status             = $Association.status
                        LastInspectionTime = $Association.last_inspection_time
                        SamplePeriod       = $Association.sample_period
                    }
                }
            }
        }

        $Page++

    } while ($Agents.Count -eq $PageSize)

    return $Disabled
}


# ============================================================
# BEFORE SNAPSHOT
# ============================================================

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " DISABLED DRIVERS - BEFORE RETRY" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

try {
    $Before = @(Get-DisabledDomotzDrivers)
}
catch {
    Write-Host ""
    Write-Host "DISCOVERY FAILED - RETRY WILL NOT RUN" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    return
}

if ($Before.Count -eq 0) {

    Write-Host ""
    Write-Host "No disabled Driver associations were found." -ForegroundColor Green
    Write-Host "Nothing will be retried." -ForegroundColor Green
    return
}

$Before |
    Sort-Object AgentName, DeviceID |
    Format-Table `
        AgentName,
        DeviceID,
        DriverID,
        AssociationID,
        Status,
        LastInspectionTime `
        -AutoSize

Write-Host ""
Write-Host "TOTAL DISABLED BEFORE RETRY: $($Before.Count)" -ForegroundColor Yellow


# Save the before snapshot
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BeforeFile = ".\Domotz-Disabled-Before-$Timestamp.csv"

$Before | Export-Csv `
    -Path $BeforeFile `
    -NoTypeInformation

Write-Host ""
Write-Host "Before snapshot saved to:" -ForegroundColor Gray
Write-Host $BeforeFile -ForegroundColor Gray


# ============================================================
# SAFETY CONFIRMATION
# ============================================================

Write-Host ""
Write-Host "WARNING:" -ForegroundColor Yellow
Write-Host "This will ask Domotz to re-enable ALL recoverable disabled Driver associations." -ForegroundColor Yellow
Write-Host ""

$Confirmation = Read-Host "Type RETRY to continue"

if ($Confirmation -cne "RETRY") {

    Write-Host ""
    Write-Host "Retry cancelled. No changes were made." -ForegroundColor Green
    return
}


# ============================================================
# RETRY
# ============================================================

$RetryUri = "$BaseUrl/custom-driver/association/re-enable?include_unrecoverable=false"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " SENDING RE-ENABLE REQUEST" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

Write-Host "URI: $RetryUri" -ForegroundColor DarkGray

try {

    $Response = Invoke-WebRequest `
        -Method POST `
        -Uri $RetryUri `
        -Headers $Headers `
        -UseBasicParsing

    Write-Host ""
    Write-Host "HTTP Status: $($Response.StatusCode)" -ForegroundColor Green

    if ($Response.StatusCode -eq 204) {
        Write-Host "Domotz accepted the re-enable request." -ForegroundColor Green
    }

}
catch {

    Write-Host ""
    Write-Host "RE-ENABLE REQUEST FAILED" -ForegroundColor Red

    if ($_.Exception.Response) {
        try {
            Write-Host "HTTP Status: $([int]$_.Exception.Response.StatusCode)" -ForegroundColor Red
        }
        catch {}
    }

    Write-Host $_.Exception.Message -ForegroundColor Red
    return
}


# ============================================================
# FIRST AFTER SNAPSHOT
# ============================================================

Write-Host ""
Write-Host "Waiting 60 seconds before first status check..." -ForegroundColor Gray

Start-Sleep -Seconds 60

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " DISABLED DRIVERS - AFTER RETRY" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

try {
    $After = @(Get-DisabledDomotzDrivers)
}
catch {
    Write-Host ""
    Write-Host "Post-retry discovery failed." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    return
}


if ($After.Count -gt 0) {

    $After |
        Sort-Object AgentName, DeviceID |
        Format-Table `
            AgentName,
            DeviceID,
            DriverID,
            AssociationID,
            Status,
            LastInspectionTime `
            -AutoSize
}
else {

    Write-Host ""
    Write-Host "No Driver associations currently report DISABLED." -ForegroundColor Green
}


# ============================================================
# COMPARE BEFORE -> AFTER
# ============================================================

$AfterLookup = @{}

foreach ($Item in $After) {
    $AfterLookup[[string]$Item.AssociationID] = $Item
}

$Results = foreach ($Item in $Before) {

    if ($AfterLookup.ContainsKey([string]$Item.AssociationID)) {

        $AfterItem = $AfterLookup[[string]$Item.AssociationID]

        [PSCustomObject]@{
            AgentName        = $Item.AgentName
            DeviceID         = $Item.DeviceID
            DriverID         = $Item.DriverID
            AssociationID    = $Item.AssociationID
            Before           = "DISABLED"
            After            = "DISABLED"
            BeforeInspection = $Item.LastInspectionTime
            AfterInspection  = $AfterItem.LastInspectionTime
            Result           = "STILL DISABLED"
        }

    }
    else {

        [PSCustomObject]@{
            AgentName        = $Item.AgentName
            DeviceID         = $Item.DeviceID
            DriverID         = $Item.DriverID
            AssociationID    = $Item.AssociationID
            Before           = "DISABLED"
            After            = "NOT DISABLED"
            BeforeInspection = $Item.LastInspectionTime
            AfterInspection  = $null
            Result           = "RE-ENABLED"
        }
    }
}


Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " RETRY RESULTS" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

$Results |
    Format-Table `
        AgentName,
        DeviceID,
        DriverID,
        Before,
        After,
        Result `
        -AutoSize


$ResultFile = ".\Domotz-Retry-Results-$Timestamp.csv"

$Results |
    Export-Csv `
        -Path $ResultFile `
        -NoTypeInformation

Write-Host ""
Write-Host "Disabled before : $($Before.Count)" -ForegroundColor Yellow
Write-Host "Disabled after  : $($After.Count)" -ForegroundColor Yellow

Write-Host ""
Write-Host "Results saved to:" -ForegroundColor Gray
Write-Host $ResultFile -ForegroundColor Gray
