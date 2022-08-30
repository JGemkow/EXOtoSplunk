# Input bindings are passed in via param block.
param($Timer)

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Warning "Trigger for MessageTrackingLogExtractor is running late."
}

# Workaround for https://github.com/Azure/azure-powershell/issues/14416
Import-Module Az.Storage -Force

# Retrieve variables for Azure Function
$certificateName = $env:CertificateName
$clientIdSecretName = $env:ClientIdSecretName
$keyVaultName = $env:KeyVaultName
$tenantNameSecretName = $env:TenantNameSecretName
$executionInterval = $env:ExecutionInterval -as [int]
$exoMessageTracePageSize = $env:EXOMessageTracePageSize -as [int]
$messageTrackingExportsContainerName = $env:MessageTrackingExportsContainerName
$storageAccountConnectionString = $env:AzureWebJobsStorage # Storage Account connection string

$fileName = "EXOMessageTrace_$(get-date -f yyMMddhhmmss).json"

# Retrive information from Key Vault
try {
	# Obtain certificate from Key Vault
	Write-Verbose "Retrieving certificate and connection values for AAD application registration.."
	$cert = Get-AzKeyVaultCertificate -VaultName $keyVaultName -Name $certificateName
	$certValue = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $cert.Name -AsPlainText

	# Obtain client ID, tenant name from Key Vault
	$clientId = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $clientIdSecretName -AsPlainText
	$tenantName = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $tenantNameSecretName -AsPlainText
	
	Write-Verbose "Secrets and certificate retrieved."
} catch {
	Write-Error -Message "Failed to retrieve values from Key Vault." -Category InvalidData
	throw $_
}

# Connect to Exchange Online
try {
	Write-Output "Connecting to EXO using AAD application service principal details from Key Vault..."
	$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]([System.Convert]::FromBase64String($certValue))
	Connect-ExchangeOnline -Certificate $certificate -AppId $clientId -Organization $tenantName -CommandName "Get-MessageTrace" -ShowBanner:$false
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
Write-Output "Gathered $($pageNumber-1) pages of messages / gathered $($messages.Count) messages."

if ($messages) {
    Write-Output "Gathered messages. Preparing to send to Azure Blob."
    Write-Output "Writing traces to a blob in $($orgConfigExportsContainerName) container"

    try {
        # Create storage context
        $storageContext = New-AzStorageContext -ConnectionString $storageAccountConnectionString

        # Create file locally to upload to blob
        $tempPath = "$($env:TEMP)\$fileName"
        New-Item $tempPath | Out-Null
        Set-Content -Path $tempPath -Value (ConvertTo-Json $messages)

        # Upload to Blob Storage
        Set-AzStorageBlobContent -Container $messageTrackingExportsContainerName -File $tempPath -Blob $fileName -Context $storageContext | Out-Null

        # Remove temp file
        Remove-Item $tempPath -Force

        Write-Output "Completed adding $fileName to Azure Storage"
    } catch {
        Write-Error "Failed to write to Azure Blob." -Category NotSpecified
        throw $_
    }
} else {
    Write-Output "Nothing to write to blob."
}