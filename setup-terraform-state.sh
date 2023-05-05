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

