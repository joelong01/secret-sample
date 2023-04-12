#!/bin/bash
#shellcheck disable=SC2148
#shellcheck disable=SC2181
#
#   guides the user to set 3 environment variables:
#
#       SECRET_SAMPLE_AZ_SP_APP_ID: the app id of a azure service principale
#       SECRET_SAMPLE_AZ_SP_PASSWORD: the SP password
#       SECRET_SAMPLE_TENANT_ID: the tenant for the SP
#
#   this can be done via copy and paste (the user specifies using an existing SP)
#   or it will guide the user to create a new Service Principal and set these keys
#   if all the keys are set, create_azure_service_principal() will not be called
function create_azure_service_principal() {

    echo -n "Would you like to create a new [Nn] Service Princpal or use an existing [e] one? "
    read -r -p "" input

    if [[ "$input" == "e" ]]; then
        echo -n "AppId: "
        read -r -p "" app_id
        echo -n "Password: "
        read -r -p "" password
        echo -n "TenantId: "
        read -r -p "" tenant_id
        SECRET_SAMPLE_AZ_SP_APP_ID="$app_id"
        SECRET_SAMPLE_AZ_SP_PASSWORD="$password"
        SECRET_SAMPLE_TENANT_ID="$tenant_id"

        export SECRET_SAMPLE_AZ_SP_APP_ID
        export SECRET_SAMPLE_AZ_SP_PASSWORD
        export SECRET_SAMPLE_TENANT_ID
        return 0
    fi
    # since the user want's a new one, make sure the user is logged into Azure
    az account show >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        az login --allow-no-subscriptions

    fi
    echo -n "Name of the service principal: "
    read -r -p "" sp_name
    echo "These are the subscriptions the logged in user has access to: "
    az account list --output table --query '[].{Name:name, SubscriptionId:id}'
    echo "You can use one of these or any other subscription you have access to."
    echo -n "Subscription Id: "
    read -r -p "" subscription_id

    # Get the tenant ID associated with the subscription
    tenant_id=$(az account show --subscription "${subscription_id}" --query "tenantId" --output tsv)
    echo "Creating service Principal.  Name=$sp_name  Subscription=$subscription_id"

    # Create a service principal and get the output as JSON - we do not redirect stderr to stdout to make parsing easier
    output=$(az ad sp create-for-rbac --name "$sp_name" --role contributor \
        --scopes "/subscriptions/$subscription_id" --query "{ appId: appId, password: password }" --output json)

    if [[ -z $output ]]; then
        echo "Error Creating Service Principal.  Message: $output"
        echo "Please fix the error and run create_azure_service_principal again."
        return 2
    fi

    # Extract the app ID and password from the JSON output -- annoyingly, the AZ ClI will add a Warning statement to the
    # beginning of the JSON and so we can't use Jq to extract the information
    app_id=$(echo "$output" | jq -r .appId)
    password=$(echo "$output" | jq -r .password)

    if [[ $output == *"WARNING"* ]]; then
        echo "$output"
        # don't return on the warning as it might just be "don't share your secrets warning" or the like
    fi

    if [[ -z $app_id || -z $password || -z $tenant_id ]]; then
        echo "There was a problem generating the service principal"
        echo "One of the critical pieces of information came back null."
        echo "Fix this issue and try again."
        # Print the app ID and password
        echo "Service Principal:"
        echo "  App ID: $app_id"
        echo "  Password: $password"
        echo "  Tenant ID: $tenant_id"
        return 1
    fi
    # we have non empty values -- store them in GH user secrets
    SECRET_SAMPLE_AZ_SP_APP_ID="$app_id"
    SECRET_SAMPLE_AZ_SP_PASSWORD="$password"
    SECRET_SAMPLE_TENANT_ID="$tenant_id"

    export SECRET_SAMPLE_AZ_SP_APP_ID
    export SECRET_SAMPLE_AZ_SP_PASSWORD
    export SECRET_SAMPLE_TENANT_ID
    return 0
}
# this script is called by onTerminalStart for each of the secrets, but we only want to generate the SP once
# so check to environment variables and if they *all* not empty, just return. the onTerminalStart.sh script
# will pick these up and set them in tha appropriate place.
if [[ -n $SECRET_SAMPLE_AZ_SP_APP_ID && -n $SECRET_SAMPLE_AZ_SP_PASSWORD && -n $SECRET_SAMPLE_TENANT_ID ]]; then
    return 0
fi

create_azure_service_principal
return $?
