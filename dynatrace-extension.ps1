#----------------------------------------------------------
# Install Dynatrace extensions ............----------------
#----------------------------------------------------------

[CmdletBinding()]
param(
    [Parameter(Mandatory=$True)]
	[string]$subscription,

    [Parameter(Mandatory=$True)]
	[string]$resourceGroup,

    [Parameter(Mandatory=$True)]
	[string]$appName,

	[Parameter(Mandatory=$True)]
	[string]$environmentId,

    [Parameter(Mandatory=$True)]
    [string]$apiToken,

    [string]$apiUrl = "",

    [string]$sslMode = "Default"
)

# Get SCM credentials
$data = (az webapp deployment list-publishing-profiles --name $appName --subscription $subscription --resource-group $resourceGroup | ConvertFrom-Json) | Where-Object {$_.publishMethod -eq 'MSDeploy'}
$scmUrl = "https://{0}" -f $data.publishUrl
$credentials = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $data.userName,$data.userPWD)))

# Install Site Extension via KUDU Rest API
$invoke = Invoke-RestMethod -Method 'GET' -Headers @{Authorization=("Basic {0}" -f $credentials)} -Uri ("{0}/api/extensionfeed" -f $scmUrl)
$id = ($invoke | ? {$_.id -match "Dynatrace"}).id
try {
  $install = Invoke-RestMethod -Method 'POST' -Headers @{Authorization=("Basic {0}" -f $credentials)} -Uri ("{0}/api/siteextensions/{1}" -f $scmUrli,$id)
  $installStatus = ($install.provisioningState).ToString() + "|" + ($install.installed_date_time).ToString()
  Write-Output "Installation Status : $installStatus"
}

# Kill Kudu's process, so that the Site Extension gets loaded next time it starts. This returns a 502, but can be ignored.
#Invoke-RestMethod -Headers @{Authorization=("Basic {0}" -f $credentials)} -Method 'DELETE' -Uri ("{0}/api/processes/0" -f $scmUrl)

# Now you can make make queries to the Dynatrace Site Extension API.
# If it's the first request to the SCM website, the request may fail due to request-timeout.
$retry = 0
while ($true) {
    try {
        Invoke-RestMethod -Headers @{Authorization=("Basic {0}" -f $credentials)} -Uri ("{0}/dynatrace/api/status" -f $scmUrl)
    } catch {
        if (++$retry -ge 3) {
            break
        }
    }
}

#----------------------------------------------------------
# Install the agent through extensions API ----------------
#----------------------------------------------------------
$settings = @{
    "environmentId" = $environmentId
    "apiUrl"        = $apiUrl
    "apiToken"      = $apiToken
    "sslMode"       = $sslMode
}
Invoke-RestMethod -Headers @{Authorization=("Basic {0}" -f $credentials)} -Method 'PUT' -ContentType "application/json" -Uri ("{0}/dynatrace/api/settings" -f $scmUrl) -Body ($settings | ConvertTo-Json)

# Wait until the agent is installed or the installation fails
while ($true) {
    $status = Invoke-RestMethod -Headers @{Authorization=("Basic {0}" -f $credentials)} -Uri ("{0}/dynatrace/api/status" -f $scmUrl)
    if (($status.state -eq "Installed") -or ($status.state -eq "Failed")) {
        break
    }

    Start-Sleep -Seconds 10
}

# Restart app-service so changes gets applied
