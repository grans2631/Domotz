<#
.SYNOPSIS
    Finds failed/disabled Domotz Custom Driver associations and
    optionally attempts to re-enable them.

.DESCRIPTION
    Workflow:

      1. Connect to the Domotz Public API
      2. Retrieve all Agents / Sites
      3. Retrieve the Custom Driver catalog
      4. Retrieve all Custom Driver associations
      5. Identify associations with Status = DISABLED
      6. Resolve:
           - Site
           - Device
           - Device IP
           - Driver
           - Driver ID
           - Association ID
           - Last Inspection
           - Sample Period
           - Variable Usage
           - Driver Code Validity
      7. Export a BEFORE CSV report
      8. Optionally call the Domotz re-enable endpoint
      9. Re-query all Driver associations
     10. Compare BEFORE vs AFTER
     11. Export AFTER and Recovery CSV reports

    IMPORTANT:
        Domotz's re-enable endpoint operates on ALL disabled
        Custom Driver associations available to the current
        API user.

        It does NOT accept a list of Association IDs.

    SAFE DEFAULT:
        $AttemptReEnable = $false

    Compatible with Windows PowerShell 5.1.
#>

# ============================================================
# CONFIGURATION
# ============================================================

# Paste the Domotz API endpoint/server associated with
# your Domotz API key.
#
# Either of these formats is accepted:
#
#   https://api-xxxxxxxx.domotz.com
#
# or:
#
#   https://api-xxxxxxxx.domotz.com/public-api/v1

$DomotzServer = "https://serveraddress.domotz.com/public-api/v1/"

$DomotzApiKey = "DomotzAPIKey"

# ============================================================
# REMEDIATION SETTINGS
# ============================================================

# FALSE:
#     Report failed Drivers only.
#
# TRUE:
#     Attempt to re-enable disabled Drivers.
#
$AttemptReEnable = $false


# Recommended default = FALSE
#
# FALSE:
#     Domotz skips associations it considers unrecoverable.
#
# TRUE:
#     Domotz also attempts to re-enable associations it has
#     determined may be unrecoverable, such as associations
#     with missing credentials.
#
$IncludeUnrecoverable = $false


# Require an interactive YES before remediation.
#
# Recommended = TRUE while testing manually.
#
# Change to FALSE later if this is run unattended through:
#
#   - Task Scheduler
#   - Rewst
#   - another automation platform
#
$RequireConfirmation = $true


# Seconds to wait after the re-enable request before checking
# association status again.
#
# NOTE:
#     This verifies whether the association is ENABLED.
#
#     It does NOT necessarily prove that another complete
#     Driver execution has run successfully yet.
#
$VerificationDelaySeconds = 15


# ============================================================
# REPORTING SETTINGS
# ============================================================

$ReportFolder = ".\Domotz-Driver-Reports"

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"


# ============================================================
# POWERSHELL / TLS COMPATIBILITY
# ============================================================

# Useful for older Windows PowerShell 5.1 environments.
try {

    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.SecurityProtocolType]::Tls12

}
catch {

    # Ignore if TLS configuration cannot be changed.
}


# ============================================================
# VALIDATE CONFIGURATION
# ============================================================

if (
    [string]::IsNullOrWhiteSpace($DomotzServer) -or
    $DomotzServer -match "YOUR-DOMOTZ"
) {

    Write-Error "Configure `$DomotzServer before running this script."
    return
}


if (
    [string]::IsNullOrWhiteSpace($DomotzApiKey) -or
    $DomotzApiKey -match "YOUR-DOMOTZ"
) {

    Write-Error "Configure `$DomotzApiKey before running this script."
    return
}


# ============================================================
# BUILD BASE URL
# ============================================================

$BaseUrl = $DomotzServer.TrimEnd("/")


if ($BaseUrl -notmatch "/public-api/v1$") {

    $BaseUrl = "$BaseUrl/public-api/v1"
}


# ============================================================
# API HEADERS
# ============================================================

$Headers = @{

    "Accept"    = "application/json"
    "X-Api-Key" = $DomotzApiKey
}


# ============================================================
# CREATE REPORT DIRECTORY
# ============================================================

if (-not (Test-Path -Path $ReportFolder)) {

    New-Item `
        -ItemType Directory `
        -Path $ReportFolder `
        -Force |
        Out-Null
}


# ============================================================
# GENERIC GET REQUEST
# ============================================================

function Invoke-DomotzGet {

    param (

        [Parameter(Mandatory = $true)]
        [string]$Path
    )


    $Uri = "$BaseUrl$Path"


    try {

        Write-Verbose "GET $Uri"


        $Response = Invoke-RestMethod `
            -Uri $Uri `
            -Method Get `
            -Headers $Headers `
            -ErrorAction Stop


        return $Response
    }

    catch {

        Write-Warning "Domotz API GET failed:"
        Write-Warning $Uri
        Write-Warning $_.Exception.Message


        if ($_.Exception.Response) {

            try {

                $StatusCode = [int]$_.Exception.Response.StatusCode

                Write-Warning "HTTP Status: $StatusCode"

            }
            catch {

                # Ignore status extraction errors.
            }
        }


        return $null
    }
}


# ============================================================
# GENERIC POST REQUEST
#
# Used for the 204 No Content re-enable endpoint.
# ============================================================

function Invoke-DomotzPost {

    param (

        [Parameter(Mandatory = $true)]
        [string]$Path
    )


    $Uri = "$BaseUrl$Path"


    try {

        Write-Host "POST $Uri" -ForegroundColor Cyan


        $Response = Invoke-WebRequest `
            -Uri $Uri `
            -Method Post `
            -Headers $Headers `
            -UseBasicParsing `
            -ErrorAction Stop


        $StatusCode = [int]$Response.StatusCode


        return [PSCustomObject]@{

            Success    = ($StatusCode -ge 200 -and $StatusCode -lt 300)
            StatusCode = $StatusCode
            Error      = $null
        }
    }

    catch {

        $StatusCode = $null


        if ($_.Exception.Response) {

            try {

                $StatusCode = [int]$_.Exception.Response.StatusCode

            }
            catch {

                $StatusCode = $null
            }
        }


        return [PSCustomObject]@{

            Success    = $false
            StatusCode = $StatusCode
            Error      = $_.Exception.Message
        }
    }
}


# ============================================================
# SAFE PROPERTY LOOKUP
# ============================================================

function Get-FirstPropertyValue {

    param (

        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string[]]$Properties,

        $Default = $null
    )


    if ($null -eq $Object) {

        return $Default
    }


    foreach ($Property in $Properties) {

        $PropertyObject = $Object.PSObject.Properties[$Property]


        if ($null -ne $PropertyObject) {

            $Value = $PropertyObject.Value


            if ($null -ne $Value) {

                $StringValue = "$Value"


                if ($StringValue.Trim().Length -gt 0) {

                    return $Value
                }
            }
        }
    }


    return $Default
}


# ============================================================
# GET ALL DOMOTZ AGENTS
#
# Endpoint:
#
#   GET /agent
#
# Pagination:
#
#   page_size   = 100
#   page_number = 0,1,2...
# ============================================================

function Get-DomotzAgents {

    $Results = @()

    $PageSize = 100
    $PageNumber = 0


    do {

        Write-Host (
            "Retrieving Domotz Agents - page {0}..." -f $PageNumber
        ) -ForegroundColor DarkCyan


        $Path = (
            "/agent?page_size={0}&page_number={1}" `
                -f $PageSize, $PageNumber
        )


        $Page = Invoke-DomotzGet -Path $Path


        if ($null -eq $Page) {

            break
        }


        $Items = @($Page)


        if ($Items.Count -gt 0) {

            $Results += $Items
        }


        $PageNumber++

    }
    while ($Items.Count -eq $PageSize)


    return $Results
}


# ============================================================
# GET CUSTOM DRIVER CATALOG
#
# Endpoint:
#
#   GET /custom-driver
# ============================================================

function Get-DomotzDrivers {

    Write-Host `
        "Retrieving Domotz Custom Driver catalog..." `
        -ForegroundColor DarkCyan


    $Response = Invoke-DomotzGet -Path "/custom-driver"


    if ($null -eq $Response) {

        return @()
    }


    return @($Response)
}


# ============================================================
# BUILD DRIVER LOOKUP
#
# Driver ID -> Driver object
# ============================================================

function New-DriverLookup {

    param (

        [array]$Drivers
    )


    $Lookup = @{}


    foreach ($Driver in $Drivers) {

        if ($null -ne $Driver.id) {

            $Lookup["$($Driver.id)"] = $Driver
        }
    }


    return $Lookup
}


# ============================================================
# BUILD DEVICE LOOKUP
#
# Device ID -> Device object
# ============================================================

function New-DeviceLookup {

    param (

        [array]$Devices
    )


    $Lookup = @{}


    foreach ($Device in $Devices) {

        if ($null -ne $Device.id) {

            $Lookup["$($Device.id)"] = $Device
        }
    }


    return $Lookup
}


# ============================================================
# GET AGENT / SITE NAME
# ============================================================

function Get-AgentName {

    param (

        $Agent
    )


    $Name = Get-FirstPropertyValue `
        -Object $Agent `
        -Properties @(
            "display_name",
            "name"
        )


    if ($Name) {

        return $Name
    }


    return "Agent $($Agent.id)"
}


# ============================================================
# GET DEVICE NAME
# ============================================================

function Get-DeviceName {

    param (

        $Device
    )


    if ($null -eq $Device) {

        return "Unknown Device"
    }


    # --------------------------------------------------------
    # Prefer user-defined Domotz device name.
    # --------------------------------------------------------

    if ($Device.user_data) {

        $UserName = Get-FirstPropertyValue `
            -Object $Device.user_data `
            -Properties @(
                "name"
            )


        if ($UserName) {

            return $UserName
        }
    }


    # --------------------------------------------------------
    # Try common direct fields.
    # --------------------------------------------------------

    $Name = Get-FirstPropertyValue `
        -Object $Device `
        -Properties @(
            "display_name",
            "name",
            "hostname"
        )


    if ($Name) {

        return $Name
    }


    # --------------------------------------------------------
    # Fall back to IP.
    # --------------------------------------------------------

    $Ip = Get-DeviceIp -Device $Device


    if ($Ip) {

        return $Ip
    }


    return "Unknown Device"
}


# ============================================================
# GET DEVICE IP
# ============================================================

function Get-DeviceIp {

    param (

        $Device
    )


    if ($null -eq $Device) {

        return $null
    }


    $Ip = Get-FirstPropertyValue `
        -Object $Device `
        -Properties @(
            "ip_address",
            "ip_addresses",
            "ip"
        )


    if ($Ip -is [array]) {

        return ($Ip -join ", ")
    }


    return $Ip
}


# ============================================================
# CONVERT UTC API DATE TO LOCAL TIME
# ============================================================

function Convert-DomotzDate {

    param (

        $Value
    )


    if (
        $null -eq $Value -or
        "$Value".Trim().Length -eq 0
    ) {

        return $null
    }


    try {

        $DateValue = [DateTime]::Parse("$Value")

        return $DateValue.ToLocalTime()
    }

    catch {

        return $Value
    }
}


# ============================================================
# GET DRIVER ASSOCIATION INVENTORY
#
# For every Agent:
#
#   GET /custom-driver/agent/{agent_id}/association
#
# Also retrieves the Agent's device inventory so that
# Device IDs can be translated into useful names/IPs.
# ============================================================

function Get-DomotzDriverAssociationReport {

    param (

        [Parameter(Mandatory = $true)]
        [array]$Agents,

        [Parameter(Mandatory = $true)]
        [hashtable]$DriverLookup
    )


    $Report = @()


    foreach ($Agent in $Agents) {

        $AgentId = $Agent.id

        $SiteName = Get-AgentName -Agent $Agent


        Write-Host (
            "Checking site: {0} [{1}]" -f $SiteName, $AgentId
        ) -ForegroundColor Yellow


        # ----------------------------------------------------
        # GET DRIVER ASSOCIATIONS
        # ----------------------------------------------------

        $AssociationPath = (
            "/custom-driver/agent/{0}/association" -f $AgentId
        )


        $AssociationResponse = Invoke-DomotzGet `
            -Path $AssociationPath


        if ($null -eq $AssociationResponse) {

            Write-Warning (
                "Unable to retrieve Driver associations for {0}" `
                    -f $SiteName
            )


            continue
        }


        $Associations = @($AssociationResponse)


        if ($Associations.Count -eq 0) {

            Write-Host `
                "  No Custom Driver associations." `
                -ForegroundColor DarkGray


            continue
        }


        # ----------------------------------------------------
        # GET DEVICES ONCE PER AGENT
        # ----------------------------------------------------

        $DevicePath = (
            "/agent/{0}/device?show_hidden=true" -f $AgentId
        )


        $DeviceResponse = Invoke-DomotzGet `
            -Path $DevicePath


        $Devices = @()


        if ($null -ne $DeviceResponse) {

            $Devices = @($DeviceResponse)
        }


        $DeviceLookup = New-DeviceLookup `
            -Devices $Devices


        # ----------------------------------------------------
        # BUILD REPORT ENTRIES
        # ----------------------------------------------------

        foreach ($Association in $Associations) {

            $DriverId = $Association.custom_driver_id

            $DeviceId = $Association.device_id


            $Driver = $null

            if (
                $null -ne $DriverId -and
                $DriverLookup.ContainsKey("$DriverId")
            ) {

                $Driver = $DriverLookup["$DriverId"]
            }


            $Device = $null

            if (
                $null -ne $DeviceId -and
                $DeviceLookup.ContainsKey("$DeviceId")
            ) {

                $Device = $DeviceLookup["$DeviceId"]
            }


            # ------------------------------------------------
            # DRIVER NAME / VALIDITY
            # ------------------------------------------------

            if ($null -ne $Driver) {

                $DriverName = Get-FirstPropertyValue `
                    -Object $Driver `
                    -Properties @(
                        "name"
                    ) `
                    -Default "Driver $DriverId"


                $DriverCodeValid = Get-FirstPropertyValue `
                    -Object $Driver `
                    -Properties @(
                        "is_valid"
                    )

            }
            else {

                $DriverName = "Driver $DriverId"

                $DriverCodeValid = $null
            }


            # ------------------------------------------------
            # REPORT OBJECT
            # ------------------------------------------------

            $Record = [PSCustomObject]@{

                Site =
                    $SiteName

                AgentId =
                    $AgentId

                Device =
                    Get-DeviceName -Device $Device

                DeviceIp =
                    Get-DeviceIp -Device $Device

                DeviceId =
                    $DeviceId

                Driver =
                    $DriverName

                DriverId =
                    $DriverId

                DriverCodeValid =
                    $DriverCodeValid

                AssociationId =
                    $Association.id

                Status =
                    $Association.status

                LastInspection =
                    Convert-DomotzDate `
                        -Value $Association.last_inspection_time

                SamplePeriodSeconds =
                    $Association.sample_period

                UsedVariables =
                    $Association.used_variables
            }


            $Report += $Record
        }
    }


    return $Report
}


# ============================================================
# SCRIPT START
# ============================================================

Write-Host ""
Write-Host "============================================================" `
    -ForegroundColor Cyan

Write-Host " Domotz Failed Custom Driver Recovery" `
    -ForegroundColor Cyan

Write-Host "============================================================" `
    -ForegroundColor Cyan

Write-Host ""

Write-Host "API Base URL: $BaseUrl" -ForegroundColor DarkGray

Write-Host ""


# ============================================================
# GET AGENTS
# ============================================================

$Agents = @(Get-DomotzAgents)


if ($Agents.Count -eq 0) {

    Write-Error `
        "No Domotz Agents were returned. Check the API endpoint and API key."

    return
}


Write-Host (
    "Domotz Agents found: {0}" -f $Agents.Count
) -ForegroundColor Green


# ============================================================
# GET DRIVER CATALOG
# ============================================================

$Drivers = @(Get-DomotzDrivers)


if ($Drivers.Count -eq 0) {

    Write-Warning `
        "No Custom Drivers were returned by the API."
}


Write-Host (
    "Custom Drivers found: {0}" -f $Drivers.Count
) -ForegroundColor Green


$DriverLookup = New-DriverLookup `
    -Drivers $Drivers


# ============================================================
# COLLECT BEFORE STATE
# ============================================================

Write-Host ""
Write-Host "Collecting current Driver association state..." `
    -ForegroundColor Cyan

Write-Host ""


$BeforeAll = @(
    Get-DomotzDriverAssociationReport `
        -Agents $Agents `
        -DriverLookup $DriverLookup
)


$BeforeFailed = @(
    $BeforeAll |
        Where-Object {
            $_.Status -eq "DISABLED"
        } |
        Sort-Object Site, Device, Driver
)


# ============================================================
# EXPORT BEFORE REPORT
# ============================================================

$BeforeCsv = Join-Path `
    -Path $ReportFolder `
    -ChildPath "Domotz-FailedDrivers-Before-$Timestamp.csv"


if ($BeforeFailed.Count -gt 0) {

    $BeforeFailed |
        Export-Csv `
            -Path $BeforeCsv `
            -NoTypeInformation `
            -Encoding UTF8
}
else {

    "No disabled Custom Driver associations found." |
        Set-Content `
            -Path $BeforeCsv `
            -Encoding UTF8
}


# ============================================================
# DISPLAY FAILED ASSOCIATIONS
# ============================================================

Write-Host ""
Write-Host "============================================================" `
    -ForegroundColor Cyan

Write-Host " Disabled / Failed Custom Drivers" `
    -ForegroundColor Cyan

Write-Host "============================================================" `
    -ForegroundColor Cyan

Write-Host ""


if ($BeforeFailed.Count -eq 0) {

    Write-Host `
        "No disabled Custom Driver associations were found." `
        -ForegroundColor Green


    Write-Host ""

    Write-Host "Report: $BeforeCsv" `
        -ForegroundColor DarkGray


    return
}


$BeforeFailed |
    Format-Table `
        Site,
        Device,
        DeviceIp,
        Driver,
        LastInspection,
        DriverCodeValid `
        -AutoSize


$FailedDeviceCount = @(
    $BeforeFailed |
        Select-Object -ExpandProperty DeviceId |
        Sort-Object -Unique
).Count


$FailedSiteCount = @(
    $BeforeFailed |
        Select-Object -ExpandProperty AgentId |
        Sort-Object -Unique
).Count


$FailedDriverCount = @(
    $BeforeFailed |
        Select-Object -ExpandProperty DriverId |
        Sort-Object -Unique
).Count


Write-Host ""

Write-Host (
    "Failed Driver associations : {0}" -f $BeforeFailed.Count
) -ForegroundColor Red


Write-Host (
    "Affected devices           : {0}" -f $FailedDeviceCount
) -ForegroundColor Yellow


Write-Host (
    "Affected sites             : {0}" -f $FailedSiteCount
) -ForegroundColor Yellow


Write-Host (
    "Unique affected Drivers    : {0}" -f $FailedDriverCount
) -ForegroundColor Yellow


Write-Host ""

Write-Host "Before report: $BeforeCsv" `
    -ForegroundColor DarkGray


# ============================================================
# REPORT-ONLY MODE
# ============================================================

if (-not $AttemptReEnable) {

    Write-Host ""

    Write-Host `
        "REPORT ONLY MODE - no Driver associations were modified." `
        -ForegroundColor Yellow


    Write-Host ""

    Write-Host "To enable remediation, change:"

    Write-Host `
        '$AttemptReEnable = $true' `
        -ForegroundColor Cyan


    return
}


# ============================================================
# REMEDIATION WARNING
# ============================================================

Write-Host ""
Write-Host "============================================================" `
    -ForegroundColor Magenta

Write-Host " DRIVER REMEDIATION ENABLED" `
    -ForegroundColor Magenta

Write-Host "============================================================" `
    -ForegroundColor Magenta

Write-Host ""


Write-Warning (
    "The Domotz re-enable API operates on ALL disabled Custom Driver associations available to this API user."
)


Write-Host ""

Write-Host (
    "Associations currently identified as DISABLED: {0}" `
        -f $BeforeFailed.Count
) -ForegroundColor Yellow


Write-Host (
    "Include unrecoverable associations: {0}" `
        -f $IncludeUnrecoverable
) -ForegroundColor Yellow


# ============================================================
# OPTIONAL CONFIRMATION
# ============================================================

if ($RequireConfirmation) {

    Write-Host ""

    $Confirmation = Read-Host `
        "Type YES to attempt to re-enable the disabled Drivers"


    if ($Confirmation -ne "YES") {

        Write-Host ""

        Write-Host `
            "Remediation cancelled. No changes were made." `
            -ForegroundColor Yellow


        return
    }
}


# ============================================================
# BUILD RE-ENABLE REQUEST
# ============================================================

$IncludeValue = $IncludeUnrecoverable.ToString().ToLower()


$ReEnablePath = (
    "/custom-driver/association/re-enable?include_unrecoverable={0}" `
        -f $IncludeValue
)


# ============================================================
# ATTEMPT RE-ENABLE
# ============================================================

Write-Host ""
Write-Host "Submitting Domotz Driver re-enable request..." `
    -ForegroundColor Cyan


$ReEnableResult = Invoke-DomotzPost `
    -Path $ReEnablePath


if (-not $ReEnableResult.Success) {

    Write-Host ""

    Write-Error (
        "Domotz re-enable request failed. HTTP Status: {0}. Error: {1}" `
            -f $ReEnableResult.StatusCode,
               $ReEnableResult.Error
    )


    return
}


Write-Host ""

Write-Host (
    "Domotz accepted the re-enable request. HTTP Status: {0}" `
        -f $ReEnableResult.StatusCode
) -ForegroundColor Green


# ============================================================
# WAIT BEFORE VERIFYING
# ============================================================

Write-Host ""

Write-Host (
    "Waiting {0} seconds before checking Driver association status..." `
        -f $VerificationDelaySeconds
) -ForegroundColor Cyan


Start-Sleep `
    -Seconds $VerificationDelaySeconds


# ============================================================
# COLLECT AFTER STATE
# ============================================================

Write-Host ""

Write-Host "Re-querying Driver associations..." `
    -ForegroundColor Cyan

Write-Host ""


$AfterAll = @(
    Get-DomotzDriverAssociationReport `
        -Agents $Agents `
        -DriverLookup $DriverLookup
)


$AfterFailed = @(
    $AfterAll |
        Where-Object {
            $_.Status -eq "DISABLED"
        } |
        Sort-Object Site, Device, Driver
)


# ============================================================
# BUILD AFTER ASSOCIATION LOOKUP
# ============================================================

$AfterLookup = @{}


foreach ($Association in $AfterAll) {

    if ($null -ne $Association.AssociationId) {

        $AfterLookup["$($Association.AssociationId)"] = `
            $Association
    }
}


# ============================================================
# COMPARE BEFORE VS AFTER
# ============================================================

$RecoveryResults = @()


foreach ($Before in $BeforeFailed) {

    $AssociationKey = "$($Before.AssociationId)"

    $After = $null


    if ($AfterLookup.ContainsKey($AssociationKey)) {

        $After = $AfterLookup[$AssociationKey]
    }


    if ($null -eq $After) {

        $AfterStatus = "NOT_FOUND"
        $RecoveryState = "NOT_FOUND"
        $LastInspectionAfter = $null

    }
    elseif ($After.Status -eq "ENABLED") {

        $AfterStatus = $After.Status
        $RecoveryState = "RE-ENABLED"
        $LastInspectionAfter = $After.LastInspection

    }
    elseif ($After.Status -eq "DISABLED") {

        $AfterStatus = $After.Status
        $RecoveryState = "STILL_DISABLED"
        $LastInspectionAfter = $After.LastInspection

    }
    else {

        $AfterStatus = $After.Status
        $RecoveryState = "UNKNOWN"
        $LastInspectionAfter = $After.LastInspection
    }


    $RecoveryRecord = [PSCustomObject]@{

        Site =
            $Before.Site

        AgentId =
            $Before.AgentId

        Device =
            $Before.Device

        DeviceIp =
            $Before.DeviceIp

        DeviceId =
            $Before.DeviceId

        Driver =
            $Before.Driver

        DriverId =
            $Before.DriverId

        DriverCodeValid =
            $Before.DriverCodeValid

        AssociationId =
            $Before.AssociationId

        BeforeStatus =
            $Before.Status

        AfterStatus =
            $AfterStatus

        RecoveryState =
            $RecoveryState

        LastInspectionBefore =
            $Before.LastInspection

        LastInspectionAfter =
            $LastInspectionAfter

        SamplePeriodSeconds =
            $Before.SamplePeriodSeconds

        UsedVariables =
            $Before.UsedVariables
    }


    $RecoveryResults += $RecoveryRecord
}


# ============================================================
# EXPORT AFTER FAILED REPORT
# ============================================================

$AfterCsv = Join-Path `
    -Path $ReportFolder `
    -ChildPath "Domotz-FailedDrivers-After-$Timestamp.csv"


if ($AfterFailed.Count -gt 0) {

    $AfterFailed |
        Export-Csv `
            -Path $AfterCsv `
            -NoTypeInformation `
            -Encoding UTF8
}
else {

    "No disabled Custom Driver associations found after remediation." |
        Set-Content `
            -Path $AfterCsv `
            -Encoding UTF8
}


# ============================================================
# EXPORT RECOVERY REPORT
# ============================================================

$RecoveryCsv = Join-Path `
    -Path $ReportFolder `
    -ChildPath "Domotz-DriverRecovery-$Timestamp.csv"


$RecoveryResults |
    Export-Csv `
        -Path $RecoveryCsv `
        -NoTypeInformation `
        -Encoding UTF8


# ============================================================
# DISPLAY RECOVERY RESULTS
# ============================================================

Write-Host ""
Write-Host "============================================================" `
    -ForegroundColor Cyan

Write-Host " Driver Recovery Results" `
    -ForegroundColor Cyan

Write-Host "============================================================" `
    -ForegroundColor Cyan

Write-Host ""


$RecoveryResults |
    Sort-Object RecoveryState, Site, Device, Driver |
    Format-Table `
        Site,
        Device,
        Driver,
        BeforeStatus,
        AfterStatus,
        RecoveryState `
        -AutoSize


# ============================================================
# CALCULATE SUMMARY COUNTS
# ============================================================

$RecoveredCount = @(
    $RecoveryResults |
        Where-Object {
            $_.RecoveryState -eq "RE-ENABLED"
        }
).Count


$StillFailedCount = @(
    $RecoveryResults |
        Where-Object {
            $_.RecoveryState -eq "STILL_DISABLED"
        }
).Count


$NotFoundCount = @(
    $RecoveryResults |
        Where-Object {
            $_.RecoveryState -eq "NOT_FOUND"
        }
).Count


$UnknownCount = @(
    $RecoveryResults |
        Where-Object {
            $_.RecoveryState -eq "UNKNOWN"
        }
).Count


# ============================================================
# SUMMARY COLORS
# ============================================================

if ($StillFailedCount -gt 0) {

    $StillFailedColor = "Red"
}
else {

    $StillFailedColor = "Green"
}


if ($NotFoundCount -gt 0) {

    $NotFoundColor = "Yellow"
}
else {

    $NotFoundColor = "Green"
}


# ============================================================
# DISPLAY SUMMARY
# ============================================================

Write-Host ""

Write-Host (
    "Originally disabled : {0}" -f $BeforeFailed.Count
) -ForegroundColor Yellow


Write-Host (
    "Re-enabled          : {0}" -f $RecoveredCount
) -ForegroundColor Green


Write-Host (
    "Still disabled      : {0}" -f $StillFailedCount
) -ForegroundColor $StillFailedColor


Write-Host (
    "Not found           : {0}" -f $NotFoundCount
) -ForegroundColor $NotFoundColor


Write-Host (
    "Unknown state       : {0}" -f $UnknownCount
) -ForegroundColor Yellow


Write-Host ""

Write-Host "Before report  : $BeforeCsv"

Write-Host "After report   : $AfterCsv"

Write-Host "Recovery report: $RecoveryCsv"


Write-Host ""

Write-Host "============================================================" `
    -ForegroundColor Cyan

Write-Host " Domotz Driver Recovery Complete" `
    -ForegroundColor Cyan

Write-Host "============================================================" `
    -ForegroundColor Cyan
