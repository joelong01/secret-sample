#!/bin/bash

#   this is the script this is specified in ../devscrets.json as the script that will help the user
#   figure out the value for the AZURE_SUB_ID environment variable.
#
#   in this example, it does a simple az call to get the list of subscriptions and prompts the user
#   to copy/paste on of the subscription ids, and then it echos its value as the last line
#
#   in this example, the caller is a shell script that invokes via "source", so we simply set the 
#   environment variable

# Login to Azure using the Azure CLI
if ! az account show &>/dev/null; then
    # User is not logged in, so login to Azure using the Azure CLI
    echo "Logging into azure.  A browswer will launch."
    az login --allow-no-subscriptions &>/dev/null
fi

# Get the list of Azure subscriptions and their tenant IDs
subscriptions=$(az account list --query '[].{Name:name, SubscriptionId:id, TenantId:tenantId}' --output table)

# Print the list of subscriptions and their tenant IDs
echo "Here are your Azure subscriptions and their tenant IDs:"
echo "$subscriptions"
echo ""
echo -n "Please enter the Subscription ID you want to use: "
# Prompt the user to enter a subscription ID
read -r AZURE_SUB_ID

# Return the subscription ID that the user picked - put a blank line so that the cli picks only the subscription
export AZURE_SUB_ID
