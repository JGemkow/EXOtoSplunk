# Input bindings are passed in via param block.
param($Timer)

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Warning "Trigger for OrganizationConfigExtractor is running late."
}

# Workaround for https://github.com/Azure/azure-powershell/issues/14416
Import-Module Az.Storage -Force

# Retrieve variables for Azure Function
$certificateName = $env:CertificateName
$clientIdSecretName = $env:ClientIdSecretName
$keyVaultName = $env:KeyVaultName
$tenantNameSecretName = $env:TenantNameSecretName
$orgConfigExportsContainerName = $env:OrgConfigExportsContainerName
$storageAccountConnectionString = $env:AzureWebJobsStorage # Storage Account connection string

$fileName = "EXOOrgConfig_$(get-date -f yyMMddhhmmss).json"

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
	Connect-ExchangeOnline -Certificate $certificate -AppId $clientId -Organization $tenantName -CommandName "Get-OrganizationConfig" -ShowBanner:$false
	Write-Output "Connected to EXO using AAD application service principal details from Key Vault."
} catch {
	Write-Error -Message "Failed to connect to EXO." -Category ConnectionError
	throw $_
}

# Gather prg config logs
Write-Output "Starting to gather EXO config"
$orgConfig = $null
try {
	$orgConfig = Get-OrganizationConfig
} catch {
	Write-Error "Failed to gather organization config." -Category NotSpecified
	throw $_
} finally {
	Disconnect-ExchangeOnline -Confirm:$false
}

Write-Output "Gathered organization config. Preparing to send to Azure Blob."
Write-Output "Writing configuration to a blob in $($orgConfigExportsContainerName) container"

try {
    # Create storage context
	$storageContext = New-AzStorageContext -ConnectionString $storageAccountConnectionString

    # Create file locally to upload to blob
    $tempPath = "$($env:TEMP)\$fileName"
    New-Item $tempPath | Out-Null
    Set-Content -Path $tempPath -Value (ConvertTo-Json $orgConfig)

    # Upload to Blob Storage
    Set-AzStorageBlobContent -Container $orgConfigExportsContainerName -File $tempPath -Blob $fileName -Context $storageContext | Out-Null

    # Remove temp file
    Remove-Item $tempPath -Force

    Write-Output "Completed adding $fileName to Azure Storage"
} catch {
	Write-Error "Failed to write to Azure Blob." -Category NotSpecified
	throw $_
}