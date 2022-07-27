# Retrieve variables for Azure Automation
$certificateName = Get-AutomationVariable -Name "CertificateName"
$clientIdSecretName = Get-AutomationVariable -Name "ClientIdSecretName"
$keyVaultName = Get-AutomationVariable -Name "KeyVaultName"
$splunkHECEndpointSecretName = Get-AutomationVariable -Name "SplunkHECEndpointSecretName"
$splunkTokenSecretName = Get-AutomationVariable -Name "SplunkEXOConfigTokenSecretName"
$tenantNameSecretName = Get-AutomationVariable -Name "TenantNameSecretName"


# Connect to Azure using MSI
try {
	Write-Verbose "Connecting to Azure using MSI..."
	Connect-AzAccount -Identity | Out-Null
	Write-Verbose "Connected to Azure using MSI."
} catch {
	Write-Error -Message "Failed to connect to Azure." -Category ConnectionError
	throw $_
}

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
Write-Output "Gathered organization config. Preparing to send to Splunk."

# Send config to HEC
#[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true} # Functionally disable the validation of the server cert by the client if the cert in Splunk is improperly set up
Write-Output "Sending config to Splunk"
$body = @{
	event =(ConvertTo-Json $orgConfig)
}    

$header = @{"Authorization"="Splunk " + $splunkToken}
Invoke-RestMethod -Method Post -Uri $splunkHECEndpoint -Body (ConvertTo-Json $body) -Header $header | Out-Null # URI should be along lines of http://" + $SplunkHost + ":" + $SplunkEventCollectorPort + "/services/collector"
Write-Output "Sent organization config to Splunk."
#[System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null