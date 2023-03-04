#!/bin/bash
# This script is run every time a terminal is started. It does the following:
# 1. Load the local environment from local.env
# 2. Login to GitHub with the proper scope
# 3. Login to Azure, optionally with a service principal
# 4. Setup the secrets

RED=$(tput setaf 1)
NORMAL=$(tput sgr0)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
LOCAL_ENV="$PWD/.devcontainer/local.env"
export LOCAL_ENV
# See https://www.shellcheck.net/wiki/SC2155 for why this is declared this way
readonly RED
readonly NORMAL
readonly GREEN
readonly YELLOW

# Functions to echo information in red/yellow/green
function echo_error() {
    printf "${RED}%s${NORMAL}\n" "${*}"
}
function echo_warning() {
    printf "${YELLOW}%s${NORMAL}\n" "${*}"
}
function echo_info() {
    printf "${GREEN}%s${NORMAL}\n" "${*}"
}

# a this is a config file in json format where we use jq to find/store settings
STARTUP_OPTIONS_FILE="$PWD/.devcontainer/localStartupOptions.json"

# this function takes a key and sets $value to be the its value. may be null
function get_setting() {
    local key
    local value
    key=$1
    value=$(jq -r ".$key" "$STARTUP_OPTIONS_FILE")
    echo "$value"
}
# save a json setting to the file localStartupOptions.json
function write_setting() {

    local key
    local value
    local tmp
    tmp=$(mktemp)
    key="$1"
    value="$2"

    if [ -f "$STARTUP_OPTIONS_FILE" ]; then
        # if the file exists, update the value for the given key while preserving existing keys/values
        jq --arg k "$key" --arg v "$value" '.[$k] |= $v' "$STARTUP_OPTIONS_FILE" >"$tmp"
    else
        # if the file doesn't exist, create a new one with the given key/value pair
        echo "{\"$key\": \"$value\"}" >"$tmp"
    fi
    mv "$tmp" "$STARTUP_OPTIONS_FILE"
}
# when using a SP login not in codespaces, we need to save appId, TenantId, and Password to use login with a Azure
# Service Principle.  This function prompts for each and then either updates or adds the keys the the local.env file.
function save_sp_secrets_locally() {
    read -r -p "What is the AppId? " AZ_SP_APP_ID
    export AZ_SP_APP_ID
    # Replace or add the AZ_SP_APP_ID variable in $LOCAL_ENV
    if grep -q "^AZ_SP_APP_ID=" "$LOCAL_ENV"; then
        sed -i "s|^AZ_SP_APP_ID=.*|AZ_SP_APP_ID=\"$AZ_SP_APP_ID\"|" "$LOCAL_ENV"
    else
        cat << EOF >> "$LOCAL_ENV"
export AZ_SP_APP_ID
AZ_SP_APP_ID=$AZ_SP_APP_ID
EOF

    fi
    read -r -p "What is the Password? " AZ_SP_PASSWORD
    export AZ_SP_PASSWORD
    # Replace or add the AZ_SP_PASSWORD variable in $LOCAL_ENV
    if grep -q "^AZ_SP_PASSWORD=" "$LOCAL_ENV"; then
        sed -i "s|^AZ_SP_PASSWORD=.*|AZ_SP_PASSWORD=\"$AZ_SP_PASSWORD\"|" "$LOCAL_ENV"
    else
       cat << EOF >> "$LOCAL_ENV"
export AZ_SP_PASSWORD
AZ_SP_PASSWORD=$AZ_SP_PASSWORD
EOF

    fi

    read -r -p "What is the TenantId? " AZ_SP_TENANT_ID
    export AZ_SP_TENANT_ID
    # Replace or add the AZ_SP_TENANT_ID variable in $LOCAL_ENV
    if grep -q "^AZ_SP_TENANT_ID=" "$LOCAL_ENV"; then
        sed -i "s|^AZ_SP_TENANT_ID=.*|AZ_SP_TENANT_ID=\"$AZ_SP_TENANT_ID\"|" "$LOCAL_ENV"
    else
        cat << EOF >> "$LOCAL_ENV"
export AZ_SP_TENANT_ID
AZ_SP_TENANT_ID=$AZ_SP_TENANT_ID
EOF

    fi

}

# this gives instructions on how to create a service principal and then collects information from the user needed to
# login using a azure service principal.  the function will also store the needed information as code spaces secrets
# so that when the user runs in codespaces (or reattach's) then the azure login will work.
function azure_service_principal_login_and_secrets() {

    local script
    local repo
    script=".devcontainer/create-azure-service-principal.sh"
    repo=$(gh repo view --json nameWithOwner | jq .nameWithOwner -r)

    if [[ -n "$AZ_SP_APP_ID" && -n "$AZ_SP_PASSWORD" && -n "$AZ_SP_TENANT_ID" ]]; then
        login_info=$(az login --service-principal -u "$AZ_SP_APP_ID" -p "$AZ_SP_PASSWORD" \
            --tenant "$AZ_SP_TENANT_ID" 2>/dev/null)
        if [[ -n "$login_info" ]]; then
            echo_info "Logged in with Service Principal"
            return 0
        fi
    fi
    # if any of those value are empty, then we tell the user to rerun the script
    # in this context, we have the repo that we are running in, so we update the Repo in the script
    sed -i "s|^GITHUB_REPO=.*|GITHUB_REPO=\"$repo\"|" "$script"

    cat <<EOF
To reliably login to Azure when running in a browser, you need to login with an Azure Service Principal. This branch 
has a script (create-azure-service-principal.sh) that will create a service principal. However, you must be logged into 
Azure to run it.

To do so, follow these instructions:
    1. Go to https://ms.portal.azure.com
    2. Start cloud shell. Make sure it is a "bash" shell
    3. Copy the entire contents of create-azure-service-principal.sh (file which is in the same directory as this file)
       and paste it into the Azure Cloud Shell. This will collect and store secrets in your GitHub account that will be 
       used to login to Azure when running in CodeSpace
    4. Come back to this terminal and reconnect to codespaces when you are prompted.

If you are running in Codespaces, you will be prompted to reconnect to the Codespace and the environment variables will
automatically be set to allow onTerminalStart.sh to log into Azure using the SP. If you are not in Codespaces, these 
settings are saved in local.env.  

This script will prompt you for the values and you can copy and paste them from your Azure Cloud Shell.

EOF

    read -n 1 -s -r -p "Hit any key to continue: "
    echo ""
    # if we are not running in Codespaces, we need to store the secrets in the local.env file
    if [[ -z $CODESPACES ]]; then
        save_sp_secrets_locally
    fi

    # login with the information provided to make sure it works
    login_info=$(az login --service-principal -u "$AZ_SP_APP_ID" -p "$AZ_SP_PASSWORD" \
        --tenant "$AZ_SP_TENANT_ID" 2>/dev/null)
    # login_info is empty if the az login failed for some reason
    # recurse if the user wants to try again
    if [[ -z "$login_info" ]]; then
        echo_error "Error logging into Azure using the provided information. Would you like to try again? [Y/n]"
        read -n 1 -s -r input
        echo
        if [[ "$input" == "Y" || "$input" == "y" || "$input" == "" ]]; then
            # clear the variables so that we don't attempt a login at the start of the function
            AZ_SP_APP_ID=""
            AZ_SP_PASSWORD=""
            AZ_SP_TENANT_ID=""

            azure_service_principal_login_and_secrets
        else
            return 1 # give up?
        fi

    fi

}

#  check to see if the user is logged into azure (either SP or user creds) and echo's out info
function verify_azure_login() {
    local az_info
    # Get signed-in user info
    az_info=$(az ad signed-in-user show 2>&1)

    # Check if signed in as service principal
    if [[ "$az_info" == *"/me"* ]]; then
        az_info=$(az ad sp show --id "$AZ_SP_APP_ID")
        echo_info "Logged in as Service Principle Name: $(echo "$az_info" | jq .displayName)"
        return 0
    fi
    # Extract user display name from JSON output
    azure_logged_in_user=$(echo "$az_info" | jq -r '.displayName' 2>/dev/null)
    if [[ -n $azure_logged_in_user ]]; then #already logged in
        echo_info "Logged in to Azure as $azure_logged_in_user"
        return 0
    fi

    return 1 #not logged in
}
# when logging into azure, we support logging in with a ServicePrincipal (which you must do when running the VS Code
# browser client) or with User Creds.  The user is asked their preference, which is stored in localStartupOptions
function login_to_azure() {
    # Set up variables

    local loginUsingServicePrincipal

    # they want to login to Azure, are they already there?
    if verify_azure_login; then
        return 0
    fi

    # the user isn't logged in.  check the local config to see if they want to use a service principal to login
    # value=$(jq -r '.loginUsingServicePrincipal' localStartupOptions.json)
    loginUsingServicePrincipal=$(get_setting 'loginUsingServicePrincipal')
    case $loginUsingServicePrincipal in
    null | "")
        read -r -p \
            "$GREEN""Would you like to login with a Service Principal [s], with your user creds [uU]? ""$NORMAL" \
            login_option

        if [[ "$login_option" == "u" ]]; then # since the default is S
            loginUsingServicePrincipal=false
        else
            loginUsingServicePrincipal=true
        fi
        write_setting "loginUsingServicePrincipal" "$loginUsingServicePrincipal"
        ;;
    true | false) ;;
        # nothing to do here, we got a valid setting back
    *)
        echo_error "Unexpected value for 'loginUsingServicePrincipal' in localStartupOptions.json"
        echo_error "The unexpected value is: $loginUsingServicePrincipal"
        echo_error "Deleting the setting.  Close this terminal and open a new one to retry."
        write_setting "localStartupOptions.json", ""
        return 1
        ;;
    esac

    if [[ $loginUsingServicePrincipal == true ]]; then
        azure_service_principal_login_and_secrets
    else
        read -r -p "You are not logged into Azure. Press Enter to log in. A browser will launch"
        if ! az login --allow-no-subscriptions 1>/dev/null; then
            echo_error "Error: Failed to log in to Azure. Manually log in to Azure and try again."
            return 1
        fi
    fi

    if ! verify_azure_login; then
        echo_error "Error logging in to azure.  Manually login or try again."
        echo_error "This can happen if you are trying to use user credentials while running in a VS Code Browser"
        echo_error "Login with a service principal instead."
    fi
    return 0
}

# simply loads the local secret file to source the environment variables.  this
# file is created in on-create.sh should always be here
function load_local_env() {

    # the following line disables the "follow the link linting", which we don't need here
    # shellcheck source=/dev/null
    source "$LOCAL_ENV"

    # tell the dev where the options are everytime a terminal starts so that it is obvious where to change a setting
    echo_info "Local secrets file is $LOCAL_ENV.  Set environement variables there that you want to use locally."

}

# ask the user if they want to use GitLab, and if so ask for the  Gitlab token and export it
# as GITLAB_TOKEN.  Remember their decision in the $STARTUP_OPTIONS_FILE
# side effects of this function:  USE_GITLABS and GITLAB_TOKEN are set
function get_gitlab_token() {
    if [[ -f "$STARTUP_OPTIONS_FILE" ]]; then
        USE_GITLAB=$(jq -r '.useGitlab' <"$STARTUP_OPTIONS_FILE")
    else
        USE_GITLAB=true
    fi

    # Print this message so developers can modify the setting
    if ! "$USE_GITLAB"; then
        echo_info "useGitlab set to false in $STARTUP_OPTIONS_FILE."
        return 1
    fi

    read -r -p "What is the value for GITLAB_TOKEN? " gitlab_token
    GITLAB_TOKEN="$gitlab_token"
    export USE_GITLAB
    export GITLAB_TOKEN
}

# secret initialization - in this scenario, the only secret that the dev has to deal with is the GITLAB_TOKEN.  if
# other secrets are needed, then this is where we would deal with them. we can either be in codespaces or running on a
# docker container on someone's desktop.  if we are in codespaces e can store per-dev secrets in GitHub and not have to
# worry aboutstoring them locally.  Codespaces will set an environment variable CODESPACES=true if it is in codespaces.
# Even if we are not in Codespaces, we still set he user secret in Github so that if codespaces is used, it will be
# there. The pattern is
# 1. if the secret is set, return
# 2. get the value and then set it as a user secret for the current repo
# 3. if it is not running in codespaces, get the value and put it in the $LOCAL_SECRETS file
function setup_secrets() {

    # if the GITLAB_TOKEN variable is set, then we don't need to do anything
    if [[ -n "${GITLAB_TOKEN}" ]]; then
        echo_info "GITLAB_TOKEN is set"
        return 0
    fi

    get_gitlab_token #this has the side effect of setting GITLAB_TOKEN and USE_GITLAB

    if [[ $USE_GITLAB == false ]]; then
        return 0
    fi

    # we always store the secret as a user secret in GitLab -
    # if there are more secrets, follow this pattern to store them in github codespaces secrets
    repo=$(gh repo view --json nameWithOwner | jq .nameWithOwner -r)
    gh secret set GITLAB_TOKEN --user --repos "$repo" --body "$GITLAB_TOKEN"

    # if you are not in Codespaces, update the GITLAB_TOEKN= line in the secrets file to set the GitLab PAT
    if [[ -z $CODESPACES ]]; then
        sed -i "s/GITLAB_TOKEN=/GITLAB_TOKEN=$GITLAB_TOKEN/" "$LOCAL_ENV"
    fi
    return 0
}

# see if the user is logged into GitHub and if not, log them in. this scenario has us logging into both
# GitHub and Gitlab.  If either one is optional, this is where you'd check the localStartupOptions.json
# and ask the user if they wanted to login to GitHub.
function login_to_github() {

    export GH_AUTH_STATUS
    GH_AUTH_STATUS=$(gh auth status 2>&1 >/dev/null)

    # there are three interesting cases coming back in GH_AUTH_STATUS
    # 1. logged in with the correct scopes
    # 2. logged in, but with the wrong scopes
    # 3. not logged in.
    # here we deal with all 3 of those possibilities
    if [[ "$GH_AUTH_STATUS" == *"not logged into"* ]]; then
        USER_LOGGED_IN=false
    else
        USER_LOGGED_IN=true
    fi

    # find the number of secrets to test if we have the write scopes for our github login
    # if they are not logged in, this fails and SECRET_COUNT is empty
    SECRET_COUNT=$(gh api -H "Accept: application/vnd.github+json" /user/codespaces/secrets | jq -r .total_count)

    # without secrets, the SECRET_COUNT is 0 if they are logged in with the right permissions. so if it is empty...
    if [[ -z $SECRET_COUNT ]] && [[ $USER_LOGGED_IN == true ]]; then
        echo_warning "Refreshing GitHub Token to request codespace:secrets scope"
        gh auth refresh --scopes user,repo,codespace:secrets
    fi

    # ""You are not logged into any GitHub hosts. Run gh auth login to authenticate.""
    # is the message returned for gh auth status when the user isn't signed in
    # it is possible that github could change this in the future, which would break
    # this script, so "not logged into" seems like a safer thing to check.
    if [[ $USER_LOGGED_IN == false ]]; then
        gh auth login --scopes user,repo,codespace:secrets
        GH_AUTH_STATUS=$(gh auth status 2>&1 >/dev/null)
    fi

    # this just echos a nice message to the user...GitLabs should have a --json option for this!
    # we also *want* expansion/globbing here to find the check, so disable SC2086 for this one line
    #shellcheck disable=SC2086
    GITHUB_INFO="$(echo $GH_AUTH_STATUS | awk -F'✓ ' '{print $2}')"
    if [[ -z ${GITHUB_INFO} ]]; then
        echo_warning "You are not logged into GitHub"
    else
        echo_info "$GITHUB_INFO"
    fi
}
# make sure the gitignore has the line to ignore *local*.* files
function fix_git_ignore() {
    # Check if .gitignore file exists in current directory
    if [[ ! -f .gitignore ]]; then
        touch .gitignore
    fi

    # Check if "*local*.*" pattern is already in .gitignore file
    if ! grep -qF "*local*.*" .gitignore; then
        cat <<EOF >>.gitignore
# anything containing the word local. used to keep local.env and other local
# files from being checked in, as they often contain secrets
*local*.*
EOF
    fi
}

fix_git_ignore
# call load_local_env fist because in Codespaces, the shell starts with the secrets set so this makes the
# initial conditions of the script the same if the dev is running in codespace or in a local docker container
load_local_env
login_to_github
login_to_azure
setup_secrets
