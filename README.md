# Secure Secrets in Dev Containers

## Introduction

Secure software delivery is a fundamental aspect of software development and operations. Establishing secure code repositories and developer containers from the start is crucial in ensuring the confidentiality, integrity, and availability of software assets for customers. This document outlines the best practices and learnings from a recent project, providing guidance on how to set up a secure and effective repository and container management process.

This document is focused on ways for developers to configure secrets in their inner loop environment. For best practices on managing secrets for deployed applications, refer to the [Microsoft Solution Playbook Secrets Store content](https://preview.ms-playbook.com/code-with-devsecops/Capabilities/02-Develop/Secrets-Store/). Another good practice to consider is enabling [Secrets Detection](https://preview.ms-playbook.com/code-with-devsecops/Capabilities/02-Develop/Secrets-Detection/) for any case a developer accidentally checks-in a secret.

The scenario for this example is a project that needs to have the developer (and the user of the app) login to Azure, GitHub, and GitLab.  Azure login is handled either via logging in with user credentials following the normal **az login** browser flow, or by logging in with an Azure Service Principle. GitHub login is done using **gh auth login** and GitLab via a PAT.  The dev environment must support 3 scenarios:

1. Running in a local docker container.  
2. Running in a GitHub Codespaces container, using the VS Code rich client
3. Running in a GitHub Codespaces container, using the VS Code web client

Both the Azure CLI and the GitHub cli have support for storing their secret used for login outside of the repo so neither of them require local secret storage. However, if the user decides to login to Azure using a Service Principle while they are not using Codespaces, then the secret information necessary to use the Service Principal is stored locally.

The scenario also requires being able login to Azure when using the Codespaces with the VS Code Web Client.  In that configuration, redirect to localhost doesn't work so you can't use the normal flows for **az login** and **az login --use-device-code** won't work because that also doesn't support running in a browser.  Therefore, the scenario requires logging in with an Azure Service Principal

However, the GitLab PAT must be stored locally. For each of the hosting options, the GitLab PAT and the Azure login works as follows:

| Host|Azure User Login|Azure Service Principal Login|
|--- |---|---|
|  Local Docker|supported|supported|
|  Codespaces, Rich Client|supported|supported|
|  Codespaces, Web Client|not supported|supported|

In all cases, if the user is running in GitHub Codespaces, the secrets are stored as User Codespaces Secrets (https://github.com/settings/codespaces).  When running outside of Codespaces, then the secrets are either stored via the CLIs (e.g. az login or gh auth login) or in a local.env file.  To protect against accidentally checking in user secrets, the pattern "\*local.\*" is added to the .gitignore file.

## Design Goals

1. Ease of Use for Developers: The repository should be easy to clone and use, with configuration in one place and not requiring developers to go through a lengthy readme file. The *use* of the repo will guide the user to do the right thing without having to consult a readme file.
2. Secure by Default: The repository should be secure by default, making it as difficult as possible to accidentally check-in secrets. The repo is shared, but some secrets should be private to the individual developers. As much as possible, secrets should not be stored in clear text in the container. Ideally they shouldn???t be stored on the box anywhere.
3. Portable: The project should work in a docker container or in Codespaces.
4. Idempotent:  if there is a problem in the collection, use, or storage of the secrets, the system will do the right thing to eventually get to the correct state.
5. Self correcting: if a developer accidentally breaks something, the system should fix it as much as possible.

## Design

In this project, there are three different logins required from the dev container: Azure CLI, GitHub, and GitLab. Each of these logins have a unique approach for authenticating, storing secrets securely in the container environment, and using the secrets to establish a connection the next time the dev container is started. The following describes the implementation of authentication for each login, taking into consideration the previously outlined design goals.

### Directory Structure
 
????????? .gitignore   
????????? .devcontainer   
    ????????? onTerminalStart.sh   
    ????????? onPostCreate.sh   
    ????????? localStartupOptions.json   
    ????????? local.env   
    ????????? devcontainer.json   
    ????????? create-azure-service-principal.sh   

File Descriptions:

1. **.gitignore**: the standard git file.  the onTerminalStart.sh script will check to see if the "\*local.\*" pattern is set in the .gitignore, and if not, will add it. 
2. **.devcontainer**:  this is a folder that defines the container that the application will run in.
3. **onTerminalStart.sh**: run every time a terminal starts.  This is the main "driver" of the system and drives the collection, storage, and use of information to enable the scenario of logging into GitHub, Azure, and storing a GitLab PAT.
4. **onPostCreate.sh**: the "handler" for the 'postCreateCommand". Its main job is to update the **.bashrc** so that **onTerminalStart.sh** is run every time a terminal is started.  It is also a convenient place to "bootstrap" the system by creating files and adding information to them.  For example, this sample will create the **local.env** file and then add environment variables for the Gitlab PAT (GITLAB_TOKEN) and the location of the **local.env** file
5. **localStartupOptions.json**: a file *is not checked in* and contains config used by the local-secrets scripts such as remembering options the user has selected.  It is created by **onTerminalStart.sh**.
6. **local.env**:  a file that *is not checked in* that contains environment variables (including secrets) that the developer needs to build and run the application.  this file is created by the **onPostCreate.sh** script.
8. **devcontainer.json**:  this contains the meta data that VS Code uses to create the container.  In particular, there is one line that must be added to make the system work:
    ```"postCreateCommand": "/bin/bash -i -c 'source ./.devcontainer/onPostCreate.sh```
9. **create-azure-service-principal.sh**: this is a self contained script that will guide the user to enter the data necessary to create an Azure Service Principal.  The generated Service Principal information (name, secret, and tenantId) will be stored as User Secrets in Codespaces.
  
## Implementation

To initialize the process for each of the logins, code needs to be executed when a terminal is started. This code will verify the presence of valid secrets, check if authentication has already occurred, and prompt the developer for any necessary actions. The most straightforward approach is to run the code in the **.bashrc** startup script. To ensure maintainability, a **onTerminalStart.sh** script is included in the project and added to **.bashrc**, which will be executed every time a new terminal is created. The code is added to the .**bashrc** by running a script specified in the **devcontainer.json**.

```json
"postCreateCommand": "/bin/bash -c 'source ./.devcontainer/onPostCreate.sh'"
```

*postCreateCommand* is called by the VS Code container extension after the container is created (see <https://code.visualstudio.com/docs/devcontainers/create-dev-container>)

For any files created that should not be checked into the code repository, they include ???local??? in the file name and are listed in the [**.gitignore**](./.gitignore) file with the exclusion rule:

```sh
*local*.*
```
If the .gitignore file does not exist, or if the line is missing, *onTerminalStart.sh* will add the line to the file.

When creating the dev container, the following code is run using the *postCreateCommand* in the **devcontainer.json** file.

```console
"postCreateCommand": "/bin/bash -c './.devcontainer/onPostCreate.sh'"
```

This simply tells VS Code to run the bash script call **onPostCreate.sh**

The [onPostCreate.sh](.devcontainer/onPostCreate.sh) script looks like this, divided up as section for easier explanation:

> This section checks to see if the line already exists in the *.bashrc* file and if so, replaces it with the proper line. If it is not there it adds it.  
```sh
#!/bin/bash

# Define the startup line to be added to the .bashrc
STARTUP_LINE="source $PWD/.devcontainer/onTerminalStart.sh"

# Check if the startup line exists in the .bashrc file
if ! grep -q "${STARTUP_LINE}" "$HOME"/.bashrc; then
  # If it doesn't exist, append the line to the .bashrc file
  echo "${STARTUP_LINE}" >>"$HOME"/.bashrc
fi
```


>The following section of the file creates the *local.env* file if it doesn't exist and then looks for the line ```LOCAL_ENV=``` and adds it if it isn't there or replaces it if it is.  The sed command of "replace the whole line if it starts with these characters" is a generally useful pattern to follow.

```sh
LOCAL_ENV="$PWD/.devcontainer/local.env"
# create the secrets file if necessary
if [[ ! -f $LOCAL_ENV ]]; then
  touch "$LOCAL_ENV"
fi
# if the variable is not set in local.env, set it, otherwise replace it with the current value
if ! grep -q "LOCAL_ENV=" "$LOCAL_ENV"; then
  cat <<EOF >>"$LOCAL_ENV"
#!/bin/bash
LOCAL_ENV=$LOCAL_ENV
export LOCAL_ENV
EOF
else
  # replace it -- the scenario here is that someone copied the files and so the root directory is wrong
  sed -i "s|^LOCAL_ENV=.*|LOCAL_ENV=\"$LOCAL_ENV\"|" "$LOCAL_ENV"
fi
```
> This section checks to see if the app is running in Codespaces and if not, adds the GITLAB_TOKEN key to the .env file.  Note that it isn't set yet - that will happen in *onTerminalStart.sh*. If there are other secrets to add to the project, add them to the SECRET_SECTION following the pattern above.

```sh
# Define the secret section - if there are more secrets, add them here and follow the pattern for 
# getting the values from the dev that is shown in onTerminalStart.sh
SECRET_SECTION=$(
  cat <<EOF

# Export is required so that child processes (such as a terminal or coraclcli) also have access to 
# these environment variables. Use "export" to set them. To add another variable, follow the same 
# pattern. These settings are ignored in Codespaces as values are kept in User Secrets.



GITLAB_TOKEN=
export GITLAB_TOKEN

EOF
)

# Check if the user is running in codespaces - this means that if you only ever run
# in codespaces this section won't be in the file, but the file will exist
if [[ "$CODESPACES" != true ]]; then
  # Check if the secret section exists in the secrets file
  if ! grep -q "export GITLAB_TOKEN" "${LOCAL_ENV}"; then
    # If it doesn't exist, append the section to the secrets file
    echo "${SECRET_SECTION}" >>"$LOCAL_ENV"
  fi
fi

# add anything that needs to be run when the container is created

```
## onTerminalStart.sh

This script is run every time a terminal is started.  it does the following:
1. load the local environment from local.env
2. login to GitHub with the proper scope
3. login to azure, optionally with a service principal
4. sets up the secrets

Next, we will go through the onTerminalStart.sh script and explain what each part of it does.  the format is in
> *function ()*:
> Description

```sh
    # shell code
```

>This script starts off defining some functions for echoing text to the console in various colors.  These are used to make the interactions easier to understand.

```sh
#!/bin/bash

RED=$(tput setaf 1)
NORMAL=$(tput sgr0)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)

# see https://www.shellcheck.net/wiki/SC2155 for why this is declared this way
readonly RED
readonly NORMAL
readonly GREEN
readonly YELLOW

# functions to echo information in red/yellow/green
function echo_error() {
    printf "${RED}%s${NORMAL}\n" "${*}"
}
function echo_warning() {
    printf "${YELLOW}%s${NORMAL}\n" "${*}"
}
function echo_info() {
    printf "${GREEN}%s${NORMAL}\n" "${*}"
}
```
> these are functions that read or write meta data to the *localStartupOptions.json* file

```sh

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
```
>When using a SP login not in codespaces, we need to save appId, TenantId, and Password to use login with a Azure Service Principle.  This function prompts for each and then either updates or adds the keys the the local.env file.  Not storing these keys locally is big value prop for using Codespaces!
```sh

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
```
> *function azure_service_principal_login_and_secrets()*  

This gives instructions on how to create a service principal and then collects information from the user needed to
login using a Azure Service Principal.  The *create-azure-service-principal.sh* code will also store the needed information as Codespaces secrets so that when the user runs in codespaces (or reattach's) then the azure login will work. If the user picks logging into Azure with a Service Principal and they are not running in Codespaces, then the *save_sp_secrets_locally* function is called and the SP information is stored in the *local.env* file

```sh

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
```
> *function verify_azure_login*
> Checks to see if the user is logged into azure (either SP or user creds) and echo's out info about creds used.
```sh

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
```
>*function login_to_azure()*  
As this scenario is to be able to have an application that logs into GitHub, GitLab, and the AzureCLI in both local docker containers and in CodeSpaces. there are 2 scenarios for working in this repo, all with slightly different ways of dealing with secrets and azure
>
> 1. use a local docker container.  all secrets are stored in local-secrets.env
> 2. use Codespaces and then all secrets are stored as Codespaces User Secrets
>
> One of the problems using the AZ CLI in Codespaces is that the call to login via "az login" simply hangs during the redirect to localhost.  If the login is via "az login --user-device-code" it will appear to work, but the user is not actually logged in. The strategy here is to check to see if the environment variables for the Service Principal are set, and if so, ask the user if they want to use them to login to Azure.  If not, issue an "az login" command.  One of the downsides of using a Service Principal is that the permissions of a SP are often less than the permissions that are granted to a SP by default -- and granting more permissions often requires an AAD admin to approve.  This is can be very hard, depending on the policies of the company.  Sometimes, this might force a scenario where a Service Principal cannot be supported.  Since the secrets in Codespaces are key/value pairs the names of the secrets (e.g. AZ_SP_APP_ID) are used across all repos.  If the dev scenarios require a separate secret for a particular project, the script should be updated to look for additional or different secret names.
>
```sh
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
```

> *load_local_env()*  
This function loads the local secrets and lets the user know where those secrets are stored.  Echoing the location is a key part of the scenario as it "guides" the developer to the right spot if they need to update or add additional environment variables.  The shellcheck comment below is a way of turning off a shell linter warning that it can't follow the link to check the referenced file.  As we check it separately, it isn't needed here.  the LOCAL_ENV environment variable is set in the local.env file by the *onPostCreate.sh*
> Note that the $LOCAL_ENV is declared at the top of this script as a hardcoded path.

```sh
function load_local_env() {
     # the following line disables the "follow the link linting", which we don't need here
    # shellcheck source=/dev/null
    source "$LOCAL_ENV"

    # tell the dev where the options are everytime a terminal starts so that it is obvious where to change a setting
    echo_info "Local secrets file is $LOCAL_ENV.  Set environement variables there that you want to use locally."

}
```

> *function get_gitlab_token()*  
Ask the user if they want to use GitLab, and if so ask for the Gitlab token and export it as GITLAB_TOKEN.  Remember their decision in the $STARTUP_OPTIONS_FILE.  This function will set the USE_GITLABS and GITLAB_TOKEN environment variables.

```sh
function get_gitlab_token() {
    if [[ -f "$STARTUP_OPTIONS_FILE" ]]; then
        USE_GITLAB=$(jq -r '.useGitlab' < "$STARTUP_OPTIONS_FILE")
    else
        USE_GITLAB=true
    fi

    # Print this message so developers can modify the setting
    if ! "$USE_GITLAB"; then
        echo_info "useGitlab set to false in $STARTUP_OPTIONS_FILE."
        return 1
    fi

    read -r -p "Would you like to use Gitlab? [y/N] " use_gitlab
    # this regular expression checks for upper or lower case Y
    if [[ "$use_gitlab" =~ ^[Yy]$ ]]; then
        USE_GITLAB=true
        echo '{"useGitlab": true}' | jq > "$STARTUP_OPTIONS_FILE"
    else
        USE_GITLAB=false
        echo '{"useGitlab": false}' | jq > "$STARTUP_OPTIONS_FILE"
        return 1
    fi

    read -r -p "What is the value for GITLAB_TOKEN? " gitlab_token
    GITLAB_TOKEN="$gitlab_token"
    export USE_GITLAB
    export GITLAB_TOKEN
}
```

> *function setup_secrets()*
> Loads the local secrets and lets the user know where those secrets are stored. In this scenario, the only secret that the dev has to deal with is the GITLAB_TOKEN. If other secrets are needed, then this is where they would deal with them.  We can either be in codespaces or running on a docker container on someone's desktop.  If we are in codespaces we can store per-dev secrets in GitHub and not have to worry about storing them locally.  Codespaces will set an environment variable CODESPACES=true if it is in codespaces.  Even if we are not in Codespaces, we still set he user secret in GitHub so that if codespaces is used, it will be there. the pattern is
>
> 1. if the secret is set, return
> 2. get the value and then set it as a user secret for the current repo
> 3. if it is not running in codespaces, get the value and put it in the $LOCAL_SECRETS file

```sh
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

    # if you are not in Codespaces, update the GITLAB_TOEKN= line in the secrets file to set the
    # GitLab PAT
    if [[ -z $CODESPACES ]]; then
        sed -i "s/GITLAB_TOKEN=/GITLAB_TOKEN=$GITLAB_TOKEN/" "$LOCAL_ENV"
    fi
    return 0
}
```

> *function login_to_github()*  
Checks to see if the user is logged into GitHub and if not logs them in.
In order to use GitHub's Codespaces secrets (```gh secret set```), the token needs to have```codespace:secrets``` scope set.  To test permissions, get the count of secrets and if this fails, re-auth the token with the proper permissions.  Here we login with the permissions to use the user, repo, and codespaces secrets.

```sh
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
    SECRET_COUNT=$(gh api -H "Accept: application/vnd.github+json" 
                    /user/codespaces/secrets | jq -r .total_count)

    # if we don't have the scopes we need, we must update them
    if [[ -z $SECRET_COUNT ]] && [[ $USER_LOGGED_IN == true ]]; then
        echo_warning "You are not logged in with permissions to check user secrets."
        echo_warning "Adding them by refreshing the token"
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

    # this just echos a nice message to the user...GitLabs should have a --json option 
    # for this!we also *want* expansion/globbing here to find the check, so disable 
    # C2086 for this one line
    #shellcheck disable=SC2086
    GITHUB_INFO="$(echo $GH_AUTH_STATUS | awk -F'??? ' '{print $2}')"
    if [[ -z ${GITHUB_INFO} ]]; then
        echo_warning "You are not logged into GitHub"
    else
        echo_info "$GITHUB_INFO"
    fi
}
```
>function *fix_git_ignore*   
Makes sure the gitignore has the line to ignore *local*.* files.  It will create the .gitignore file it if doesn't exist, and will add the line if it isn't there.
```sh

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
```

>This part of the script just calls the functions in the proper order.  Call load_local_env fist because in Codespaces, the shell starts with the secrets set so this makes the initial conditions of the script the same if the dev is running in Codespaces or in a local docker container

```sh
fix_git_ignore
load_local_env
login_to_github
login_to_azure
setup_secrets
```

## Creating an Azure Service Principal

The code in [create-azure-service-principal.sh](.devcontainer/create-azure-service-principal.sh) is designed to make it as easy as possible to create a service principal.  After collecting some information from the user, it will create the SP and then gather information about the SP to store as Codespaces User Secrets.  This code will be explained section by section below.  It designed such that the user can login to the azure cloud shell on portal.azure.com and then copy/paste (as plain text!) into the shell.  This seemed easier than finding a way to upload the file and call it as a shell script.  When comparing the readme.md to the actual file, some of the comments have been turned into markdown sections to make it easier to read/understand.

>These two commands are explained at <https://www.shellcheck.net/wiki/SC2148> and <https://www.shellcheck.net/wiki/SC2181> The first says we should have a #!/bin/bash at the start -- but this file is designed to be copied and pasted into the Azure Cloud Shell, so it is really just a function and not a "script".  The second is to allow this code ```if [[ $? -ne 0 ]]``` to be written without a linter error, which is required so that the output can be redirected and captured along with checking the return value of the function.

```sh
#shellcheck disable=SC2148
#shellcheck disable=SC2181
```

>Codespaces secrets need to be scoped to one or more repos.  Therefore, this file needs to know the repo that the user is working in.  The *onTerminalStart.sh* script in the *azure_login()* function will check to see if the developer wants to create an Azure SP and echo out instructions to run this function.  When it does that it will update the above line to point to the current repo.

```sh
GITHUB_REPO=retaildevcrews/secret-sample-go
```

>This is the one and only function in this file and it can be called multiple times after the code is entered into the Azure Cloud Shell (or any other terminal where the user can login to azure using their personal identity).  Start by checking to make sure that the user is logged into Azure.

```sh
function create_azure_service_principal() {

    # make sure the user is logged into Azure
    az account show >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo "You are not logged in to Azure. Please run 'az login' to log in."
        exit 1
    fi
```

>Since we are storing user secrets in GitHub, we must log into GitHub with the proper scope.

```sh
    echo "You must login to GitHub in order to create GitHub Codespace secrets"
    gh auth login --scopes user,repo,codespace:secrets

```
> secrets in Github Codespaces secrets are bound to repositories, so ask the user if the above repository is the one they intend to use

```sh
 echo -n "The repo the secret will be available in is $GITHUB_REPO.  Is this correct? [yYn]: "
    read -r -n 1 answer
    echo ""
    if [[ ! $answer =~ ^[yY]?$ ]]; then
       echo -n "Repo name in the form of owner/repo: " 
       read -r GITHUB_REPO
    fi
```

>Prompt the user for the name for the service principal, the subscription and the tenant id.  To make it easier for the user, print out a table of all subscriptions they have access to, along with the associated names and ids.

```sh
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
```

>Create the service principle and get the output we care about in json format

```sh
    # Create a service principal and get the output as JSON - we do not redirect stderr
    # to stdout to make parsing easier
    output=$(az ad sp create-for-rbac --name "$sp_name" --role contributor \
        --scopes "/subscriptions/$subscription_id" \
        --query "{ appId: appId, password: password }" --output json)
```

>If the output is empty, the user will see an error that has been sent to stderr and the output variable will be the empty string.  Check for this and return if there is an error.

```sh
    if [[ -z $output ]]; then
        echo "Error Creating Service Principal.  Message: $output"
        echo "Please fix the error and run create_azure_service_principal again."
        return 2
    fi

```

>use JQ to extract the appId and the password.  If either the appId or the password or the tenant Id that we got earlier is empty then warn the user and exit the function.  Note that there are often warnings coming back from ```az ad asp create-for-rbac```, but they are usually in the form "you are seeing private information, be careful"

```sh
    app_id=$(echo "$output" | jq -r .appId)
    password=$(echo "$output" | jq -r .password)
    if [[ -z $app_id || -z $password || -z $tenant_id ]]; then
        echo "There was a problem generating the service principal "
        echo "and one of the critical pieces of information came back null."
        echo "Fix this issue and try again."
        # Print the app ID and password
        echo "Service Principal:"
        echo "  App ID: $app_id"
        echo "  Password: $password"
        echo "  Tenant ID: $tenant_id"
        return 1
    fi
```
> Show the information about the Service Principal in case the user is logging in to Azure with a SP outside of Codespaces.

```sh
echo "Service Principal:"
    echo "  App ID:    $app_id"
    echo "  Password:  $password"
    echo "  Tenant ID: $tenant_id"
```
>If we get here, we have the information we need, store the secrets as user secrets for the repository that is set at the top of the file.

```sh
    # we have non empty values -- store them in GH user secrets
    gh secret set AZ_SP_APP_ID --user --repos "$GITHUB_REPO" --body "$app_id"
    gh secret set AZ_SP_PASSWORD --user --repos "$GITHUB_REPO" --body "$password"
    gh secret set AZ_SP_TENANT_ID --user --repos "$GITHUB_REPO" --body "$tenant_id"

```

>Finally, echo instructions to the user on what to do next

```sh
   cat <<EOF
Go back to VS Code. You should have a toast popup that says "Your Codespace secrets 
have changed." Click on "Reload to Apply" and you should be automatically logged into 
Azure. If not, go to the User Settings of yourGitHub account and manually set the 
AZ_SP_APP_ID, AZ_SP_PASSWORD, AZ_SP_TENANT_ID secrets.
EOF
}
```

>This is part of the file that is copied/pasted into the Azure Cloud Shell.  There will be a lot of text after the copy, so first the screen is cleared, and then the user is told that the function is being called, and then we just call the function.

```sh
clear
echo "Creating a Service Principal"
create_azure_service_principal

```

When the user goes back to VS Code and reloads the Codespace instance, VS Code and the Codespace extension will automatically set environment variables for the secrets.  the *onTerminalStart.sh* script will use these environment variables to login to azure automatically.  If the user is not running in Codespaces, the *onTerminalStart.sh* script will ask for each piece of information about the SP and store it in the *local.env* file.

## Wrap-up

The full output of the script when starting a terminal looks something like this:

The full script will:

1. Automatically log the dev in when the first terminal is opened in VS Code.
2. Never write down or show the GitHub PAT.
3. For secrets that are not automated, provides a way to store them locally in one place and (hopefully) not check them in by accident.
4. Works in both local Containers and CodeSpaces.
5. ???leads??? the dev to figuring out where state needs to be entered to make the system work.

Check it out at <https://github.com/joelong01/secret-sample>

## Pitfalls

This section includes some alternatives that were tried but did not meet the design goals:

**A simple .env file with an example in the repository and described in the README.**

This approach is often used in repositories, and it works for a small team that is aware of how the project is setup and the steps to take in creating their inner loop environment.

```sh
#!/bin/bash

GITHUB_TOKEN=gho_70iyx\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*Paha
```

However, it did not meet the design goals:

1. We still have a PAT in clear text, in a file that might get checked in by mistake. This was unavoidable for the GitLab case, but there were better options for GitHub and Azure.
2. The typical **.env** file can be executed as a shell script but the environment variables are not marked for *export*.
3. Including the export breaks the ability to import the file into developer tools such as the Golang Debugger. (Note: the *export* command can be run in a separate shell command)
4. It is still a ???magic??? setting that needs to be documented in README and discovered by the dev for it to work.

To meet the design goals, the **onTerminalStart.sh** script handles the best possible case for each of the services (GitLab uses the personal access token, but GitHub uses the **gh** cli). The script also validates each login when a terminal is created and makes it clear to the developer any actions needed. The developer doesn???t need to find the instructions in README.

## Adding secrets using attributes in devcontainer.json

There are [several ways to include secrets as environment variables](https://code.visualstudio.com/remote/advancedcontainers/environment-variables) from the container definition in **devcontainer.json** or the **Dockerfile** used to create the container. In all cases, these require the file to exist before the container is initialized. This breaks the portability design goal because Codespaces is unable to initialize this file before creating the container. The only workaround is to check the **.env** file into source control.

1. X Include the secrets as environment variables in the **Dockerfile**
2. X Check-in an .env with the secrets file referenced from **devcontainer.json**

Another option might be to create this file in source control with ???empty??? values and have the developer fill in these variables but not check-in the new file. While that may work, it requires the Developer to rebuild the container after defining the environment variables and adds extra danger that the file might get accidentally checked-in to the repository with secrets included.
