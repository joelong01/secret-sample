#shellcheck disable=SC2148
#shellcheck disable=SC2181

# we need the repo below -- this repo will be updated by the onTerminalStart.sh 
# file to contain the repo that onTerminalStart.sh is running in
GITHUB_REPO=retaildevcrews/coral-cli-go
# Instructions:  Copy and paste this function (starting with the "function create_azure_service_principal() {" line all
# the way to the end of the file) into Azure Cloud Shell (or any interactive unix terminal where you can login to azure)
# and then call the function by running "create_azure_service_principal" (no quotes).  Then enter the information from 
# the output of the function to the prompt from onTerminalStart.sh for the coralcli project
function create_azure_service_principal() {

    # make sure the user is logged into Azure
    az account show >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo "You are not logged in to Azure. Please run 'az login' to log in."
        exit 1
    fi

    echo "You must login to GitHub in order to create GitHub Codespace secrets"
    gh auth login --scopes user,repo,codespace:secrets

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
    gh secret set AZ_SP_APP_ID --user --repos "$GITHUB_REPO" --body "$app_id"
    gh secret set AZ_SP_PASSWORD --user --repos "$GITHUB_REPO" --body "$password"
    gh secret set AZ_SP_TENANT_ID --user --repos "$GITHUB_REPO" --body "$tenant_id"

   cat <<EOF
Go back to VS Code. You should have a toast popup that says "Your Codespace secrets have changed."
Click on "Reload to Apply" and you should be automatically logged into Azure. If not, go to the User Settings of your
GitHub account and manually set the AZ_SP_APP_ID, AZ_SP_PASSWORD, AZ_SP_TENANT_ID secrets.
EOF

}


clear
echo "Creating a Service Principal"
create_azure_service_principal
