# EXO-to-Splunk Log Ingestion Solution with Azure Automation

This solution can be used for automating the exporting of EXO message traces and EXO tenant level configurations to be ingested into Splunk. This is done by executing a PowerShell script that using the ExchangeOnlineManagement PowerShell module to connect to Exchange Online, perform PowerShell cmdlets to pull data, and then store that exported data to Azure Storage as a blob. From there, a third-party Splunk connector wikk ingest the data into the appropriate Splunk data index for searching and further monitoring/alerting processes.

## Pre-requisites

To deploy the solution, the following will be needed:

- Access to an Azure subscription for deploying Azure Resource Manager resources, including:
  - Azure App Service Plans
  - Azure Functions/Azure App Service
  - Azure Storage
  - Azure Virtual Networks
  - Azure Key Vault
  - Azure Private Link/Private Endpoints
  - Azure Private DNS zones (for Private Endpoints)
  - Azure Application Insights
  - Additional services may be required dependent on further extension of the baseline architecture
- Ability to create an Azure AD (AAD) application registration in the target AAD tenant hosting Exchange Online
  - This AAD application registration will require the __Exchange.ManageAsApp__  permission scope.
- Ability to grant consent for the AAD application registration for the scope specified above (typically a Global Administrator)
- Ability to assign administrative roles to the AAD application registration
- If desired, an enterprise generated certificate can be used. In this case, that certificate would be pre-requisite.

## Creating the Azure AD application registration

The first step in deploying the solution is to register the Azure AD application for accessing Exchange Online.

### Register the application

To begin, create an Azure AD application registration using the instructions [here](https://docs.microsoft.com/en-us/azure/active-directory/develop/howto-create-service-principal-portal#register-an-application-with-azure-ad-and-create-a-service-principal). For brevity, the steps are copied below:

1. Sign in to your Azure Account through the Azure portal.
2. Select _Azure Active Directory_.
3. Select _App registrations_.
4. Select _New registration_.
5. Name the application.
6. Select a supported account type - __single tenant__.
7. Leave redirect URI as-is.
8. After setting the values, select Register.

After creating the registration, [obtain](https://docs.microsoft.com/en-us/azure/active-directory/develop/howto-create-service-principal-portal#get-tenant-and-app-id-values-for-signing-in) the tenant ID, app name, and client ID. Keep these available for the next steps.

### Add the permission scope

Using the instructions referenced [here](https://docs.microsoft.com/en-us/azure/active-directory/develop/quickstart-configure-app-access-web-apis#add-permissions-to-access-your-web-api), the next step will be to add the __Exchange.ManageAsApp__ API permission to the application.

1. From the AAD application registration created above, navigate to _API Permissions_.
2. Select _Add a permission_.
3. Under _APIS my organization uses_, search for __Office 365 Exchange Online__.
4. Select _Application permissions_.
5. Under _Exchange_, select the __Exchange.ManageAsApp__.
6. Click __Add permissions__.

Now, a global administrator will need to consent to these permissions. This can be done now, or at the time of administrative role assignment as this will also require a global administrator. This is done by clicking __Grant consent for ORGANIZATION_NAME__.

__NOTE__:  The permission scope above is only used by this app. It allows the app to manage the organization's Exchange environment without any user interaction. This includes mailboxes, groups, and other configuration objects. To enable management actions, an admin _must assign the appropriate roles directly to the app_.

### Assign the appropriate role to the app

In order to pull data about all permissions for Exchange mailboxes, tenant level configuration, etc, the app will require an administrative role. This role can be one of the following:

- Exchange Online Administrator (access to EXO, but technically has read/write access)
- Global Reader (beneficial, as cannot change data, but will have access to more than EXO)
- Global Administrator (has required permissions to access data, but __is not recommended__)

You can assign the chosen role from the Azure Portal using these [instructions](https://docs.microsoft.com/en-us/azure/active-directory/fundamentals/active-directory-users-assign-role-azure-portal). The app can be found by display name or by client/app ID.

## Creating the Azure resources

Once the baseline Azure AD application has been created, you can begin deploying the Azure resources to run the automation with the registration.

### Create a resource group

If you do not already have a resource group, create a [resource group](https://docs.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-portal#create-resource-groups) in your target subscription.

### Deploy the Azure resources into your resource group

The resource configuration is defined as an ARM template. It will deploy:

- An Azure App service plan (minimum S1 SKU is required for VNet integration)
- An Azure Function app
- An Azure Key Vault
- An Azure Storage Account
  - Including containers for blobs
- An Azure Virtual Network
- Various Private Link/Private Endpoint resources to lock down communication between resources
  - Azure Private DNS zones to support Private Endpoints
- Secrets within the Azure Key Vault (used for configuration)
- Azure Application Insights
- Related configuration (runtime settings, app setting configuration, network integration, etc.) within the Azure Function app.

You can deploy this template using PowerShell, or by [using the Azure Portal](https://docs.microsoft.com/en-us/azure/azure-resource-manager/templates/quickstart-create-templates-use-the-portal). The template data is stored in __deploy/template-base.json__ within this repository/package.

## Certificate management

You will need to add a certificate for authentication within the solution.

- The __private key__ contained certificate will go in Azure Key Vault. This will be accessed by the Azure Automation solution.
- The __public key__-only certificate will be added to AAD application registration.

Please keep in mind that the certificates will expire based on the expiration set at the time of generation. __This could impact operations of the solution. Regular rotation of the certificate will be necessary.__

### Add the certificate for authentication to Key Vault

The option to use a prior generated self-signed certificate or a enterprise-issued certificate exists. The other option is to generate a certificate using Azure Key Vault. Depending on how you choose to bring your own certificate or generate a new one, use the link to the appropriate instructions below:

- [Create a self-signed certificate](https://docs.microsoft.com/en-us/azure/active-directory/develop/howto-create-self-signed-certificate). _Note:_ You will need to import the certificate after generating.
- [Import an existing certificate to Key Vault](https://docs.microsoft.com/en-us/azure/key-vault/certificates/tutorial-import-certificate?tabs=azure-portal)
- [Generate a certificate in Key Vault](https://docs.microsoft.com/en-us/azure/key-vault/certificates/quick-create-portal#add-a-certificate-to-key-vault). _Note:_ Be sure to download the certificate in __CER__ format afterward. This will be used for the AAD App registration

### Add the certificate to the Azure AD application registration

In order to authenticate against the Azure AD application registration, the public-key certificate will need to be uploaded. The instructions to do so are [here](https://docs.microsoft.com/en-us/azure/active-directory/develop/howto-create-service-principal-portal#option-1-upload-a-certificate).

To do so in the Azure Portal:

1. Select Azure Active Directory.
2. From App registrations in Azure AD, select your application.
3. Select Certificates & secrets.
4. Select Certificates > Upload certificate and select the certificate (an existing certificate or the self-signed certificate you exported).

## Deploying the Function code

The Azure Function resources will be created as empty. The function code will need to be added to the resource. The function code is stored under the __src/Function__ folder. There are various ways to deploy the application depending on your workstation configuration, network configuration, and outbound firewall configuration.

1. ZIP the _contents_ of the __src/Function__ directory. Do not ZIP the Function folder itself.
2. Deploy the ZIP package using the Kudu UI or another programmatic method described [here](https://docs.microsoft.com/en-us/azure/app-service/deploy-zip?tabs=kudu-ui#deploy-a-zip-package). __Be sure that the [inbound traffic restrictions for your Function app](https://docs.microsoft.com/en-us/azure/azure-functions/functions-networking-options?tabs=azure-cli#inbound-access-restrictions) will allow the upload traffic for the deployment.__

## Test and validate

The functions are now deployed and configured. Monitor the execution of the functions on the schedules and ensure data is flowing to Azure Storage for consumption by Splunk. 

__Note:__ By default, a lifecycle policy is put in place on the Storage Account to delete the JSON exports after 7 days. This is to help manage sprawl of exports and minimize costs. Additionally, Application Insights log data is only retained by default for 90 days. These are configurable in the ARM template variables or in the respective resources in the Azure Portal.
