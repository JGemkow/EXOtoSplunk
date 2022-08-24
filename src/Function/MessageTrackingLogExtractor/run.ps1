# Input bindings are passed in via param block.
param($Timer)

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Warning "Trigger for MessageTrackingLogExtractor is running late."
}

# Retrieve variables for Azure Function
$certificateName = $env:CertificateName
$clientIdSecretName = $env:ClientIdSecretName
$keyVaultName = $env:KeyVaultName
$splunkHECEndpointSecretName = $env:SplunkHECEndpointSecretName
$splunkTokenSecretName = $env:SplunkMessageTraceSplunkTokenSecretName
$tenantNameSecretName = $env:TenantNameSecretName
$executionInterval = $env:ExecutionInterval
$maxNumberSplunkSendThreads = $env:MaxNumberSplunkSendThreads
$exoMessageTracePageSize = $env:EXOMessageTracePageSize

# Retrive information from Key Vault
try {
	# Obtain certificate from Key Vault
	Write-Verbose "Retrieving certificate and connection values for AAD application registration.."
	$cert = Get-AzKeyVaultCertificate -VaultName $keyVaultName -Name $certificateName
	$certValue = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $cert.Name -AsPlainText

	# Obtain client ID, tenant name, Splunk Host Name, and Splunk Token from Key Vault
	$clientId = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $clientIdSecretName -AsPlainText
	$tenantName = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $tenantNameSecretName -AsPlainText
	$splunkHECEndpoint = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $splunkHECEndpointSecretName -AsPlainText
	$splunkToken = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $splunkTokenSecretName -AsPlainText
	
	Write-Verbose "Secrets and certificate retrieved."
} catch {
	Write-Error -Message "Failed to retrieve values from Key Vault." -Category InvalidData
	throw $_
}

# Connect to Exchange Online
try {
	Write-Output "Connecting to EXO using AAD application service principal details from Key Vault..."
	$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]([System.Convert]::FromBase64String($certValue))
	Connect-ExchangeOnline -Certificate $certificate -AppId $clientId -Organization $tenantName
	Write-Output "Connected to EXO using AAD application service principal details from Key Vault."
} catch {
	Write-Error -Message "Failed to connect to EXO." -Category ConnectionError
	throw $_
}

# Gather message tracking logs
Write-Output "Starting to gather EXO Message Traces, page-by-page"
$messages = @()
try {
	$pageNumber = 1
	$currentDateTime = Get-Date
	$endDate = Get-Date -Date $currentDateTime.Date -Hour $currentDateTime.Hour -Minute $currentDateTime.Minute -Second 0 -Millisecond 0
	$startDate = ($endDate).AddMinutes(($executionInterval * -1))
	do {
		$page = Get-MessageTrace -StartDate $startDate -EndDate $endDate -PageSize $exoMessageTracePageSize -Page $pageNumber
		$pageNumber += 1 # Increment page number
		$messages += $page
	} while ($null -ne $page)
} catch {
	Write-Error "Failed to iterate over page $pageNumber for EXO message traces." -Category NotSpecified
	throw $_
} finally {
	Disconnect-ExchangeOnline -Confirm:$false
}
Write-Output "Gathered $($pageNumber-1) pages of messages / gathered $($messages.Count) messages. Preparing to send to Splunk."

# Set up runspace pool for multi-threading
$runspacePool = [runspacefactory]::CreateRunspacePool(1, $maxNumberSplunkSendThreads)
$runspacePool.Open()
$sendJobs = @()

# Send message by Message to HEC
$sendScript = {
    param($uri, $splunkToken, $message)
    $body = @{
		event =(ConvertTo-Json $message)
	}    
	
	$header = @{"Authorization"="Splunk " + $splunkToken}
	Invoke-RestMethod -Method Post -Uri $uri -Body (ConvertTo-Json $body) -Header $header #| Out-Null # URI should be along lines of http://" + $SplunkHost + ":" + $SplunkEventCollectorPort + "/services/collector"
}

#[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true} # Functionally disable the validation of the server cert by the client if the cert in Splunk is improperly set up
for ($i=0; $i -lt $messages.Count; $i++) {
	Write-Output "Sending message #$($i+1) of $($messages.Count) to Splunk"
	$m = $messages[$i]

	$powerShell = [powershell]::Create()
	$powerShell.RunspacePool = $runspacePool
	$powerShell.AddScript($sendScript).AddArgument($splunkHECEndpoint).AddArgument($splunkToken).AddArgument($m) | Out-Null
	$sendJobs += $powerShell.BeginInvoke()
}

while ($sendJobs.IsCompleted -contains $false) {
	Start-Sleep 1
}
Write-Output "Finished sending messages to Splunk."
#[System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null

