# Example of PrivateLink AppService

## Fork This GitHub Project

Start by forking this Github repository to the Git repo product of your choice
(ie. GitHub or Azure DevOps)(https://github.com/brentmcconnell/privatelinkapp).

## Setup Terraform State File in Azure

Ensure you have an Azure subscription with privileges to create service
principals, resource groups and storage accounts.  This tutorial assumes you are 
using "bash" on a Linux terminal.

Run the following script to setup a Resource Group and Storage Acct for
Terraform state.  This script will also create a service principal with Owner on
the subscription that will be used by Azure DevOps as a service connection to
Azure for running pipelines.

```
#!/bin/bash

read -p 'Enter a Resource Group name: ' resource_group 
RESOURCE_GROUP_NAME=$resource_group

if [ -z $RESOURCE_GROUP_NAME ]; then
  echo "Resource Group Required"
  exit 1
fi

# Create resource group
az group create --name $RESOURCE_GROUP_NAME --location eastus --output none

# Create storage account
SA=$(az storage account list --query "[?starts_with(name,'tfstate') && resourceGroup=='$RESOURCE_GROUP_NAME'].name" --output tsv)

# Check and see if a SA already exists
if [ -z $SA ]; then
  STORAGE_ACCOUNT_NAME=tfstate${RANDOM}sa
  az storage account create --resource-group $RESOURCE_GROUP_NAME --name $STORAGE_ACCOUNT_NAME --sku Standard_LRS --encryption-services blob --output none
else
  STORAGE_ACCOUNT_NAME=$SA
fi

CONTAINER_NAME=tfstate

# Create blob container
az storage container create --name $CONTAINER_NAME --account-name $STORAGE_ACCOUNT_NAME --output none

# Grab the storage account key and print it to stdout.  Not recommended in most cases.
ACCOUNT_KEY=$(az storage account keys list --resource-group $RESOURCE_GROUP_NAME --account-name $STORAGE_ACCOUNT_NAME --query '[0].value' -o tsv)

# Create Service Principal with Owner on the Subscription
SUB_ID=$(az account show --query id -o tsv)
az ad sp create-for-rbac --name privatelink-sp --role Owner --scopes /subscriptions/$SUB_ID

echo "TENANT_ID          = $(az account show --query tenantId -o tsv)"
echo "SUBSCRIPTION_ID    = $SUB_ID"
echo "STORAGE_ACCT_NAME  = $STORAGE_ACCOUNT_NAME"
echo "CONTAINER_NAME     = $CONTAINER_NAME"
echo "ACCOUNT_KEY        = $ACCOUNT_KEY"

```
Modify the iac/main.tf file and change the "backend" section at the top of the file
to reflect the values created by the script above.  In particular you'll need to
change __storage_account_name__ and __resource_group_name__ to what was created
during the script execution above.

Commit your changes to the repository.

## Setting Up Azure DevOps Project

Sign into Azure DevOps and create a new project for this example application.

If you haven't already go to the Azure DevOps Marketplace and install the
Terraform extension for ADO.  This is a free extension for Azure DevOps that
gives your pipelines additional Terraform functionality.

Next, navigate to "Project settings" in the new project and select "Service
Connections".

Select "Create service connection" -> "Azure Resource Manager".  Select the
"Service principal (manual) option and enter the following information from the
script output from above (script output is in bold):

* Tenant Id = __TENANT_ID__
* Subscription Id = __SUBSCRIPTION_ID__
* Service Principal Id = __appId__
* Service Principal Key = __password__
* Subscription Name = <any string>
* Service connection name = __azure__ (can be anything but "__azure__" is used
  in this repo throughout)

After saving you should now see a new service connection in your project.  Note
the name you gave the service connection if other than __azure__ as that will be needed later.


## Setup ADO Pipelines

Select Pipelines from the left navigation menu and then select "Create
Pipeline".  Choose the __privatelink-springapp__ repository from your repository list where you forked
it. 

At the __Configuration Your Pipeline__ page, select __Existing Azure Pipeline
YAML file__ and then select __/iac_pipeline.yml__ for the Path.

Once the pipline has been loaded into the editor use the __Variables__ option in
the top right corner of the editor to add four variables for the pipeline:
* resource_group = name of resource group created during initial script
  execution
* prefix = prefix is the __unique__ set of characters to be used by Terraform to
  create resources in Azure.  Terraform will fail if this is not unique.
* storage_acct = __STORAGE_ACCT_NAME__ from initial script execution.
* sp_id = __appId__ from initial script execution (select __secret__ when creating)
* sp_key = __password__ from initial script execution (select __secret__ when
  creating)

Once these Variables have been added you can save and execute the pipeline.
This will take about 20 minutes to execute and will create resources in Azure.

After the Terraform script has completed the following primary resources can be found in
the Resource Group specified.  There are other supporting objects as well but
these are the primary objects:
* Redis Cache
* MySQL Database
* AppService Plan
* AppService WebApp
* AppService WebApp Slot
* Azure Container Registry
* PrivateLink for AppService
* Windows 11 VM

At this point you should be able to view the default web address of the Spring
Application by running the following command to see the web address.  Remember
to change the resource_group name below before executing.
```
az webapp list -g <resource-group> --query "[0].defaultHostName" -o tsv 2>/dev/null
```
If you visit that hostname from a web browser outside of Azure you should see a
"403 Forbidden" message indicating that the web application is not accessible
from outside.  However, if you RDP into the Win 11 VM that was provisioned in
the VNet and use a web browser to view the same hostname you will see the web
application for the Spring App, a ToDo list application, appear.
