#!/bin/bash

# this script is run everytime a terminal is started.  it does the following:
# 1. load the local environment from local.env
# 2. login to github with the proper scope
# 3. login to azure, optionally with a service principal
# 4. setup the secrets

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

# as this scenario is to be able to have an application that logs into GitHub, GitLab, and the AzureCLI in both
# local docker containers and in CodeSpaces.
# there are 3 scenarios for working in this repo, all with slightly different ways of dealing with secrets and azure
# 1. use a local docker container.  there secrets are stored in local-secrets.env
# 2. using the desktop version of VS Code running against a code space instance.  Here secrets are stored in GitHub
# 3. use the browser version of VS Code running against a code space instance.
#
function login_to_azure() {
    # Set up variables
    local az_info
    local azure_logged_in_user

    # Get signed-in user info
    az_info=$(az ad signed-in-user show 2>&1)
    # Extract user display name from JSON output
    azure_logged_in_user=$(echo "$az_info" | jq -r '.displayName' 2>/dev/null)

    # Check if signed in as service principal
    if [[ "$az_info" == *"/me"* ]]; then
        echo_error "Error: You are logged in with a service principal which is not supported in this application."
        echo_error "You will be logged out and then logged back in via the browser flow."
        echo_error "Note: This will not work with VS Code running as a browser. Run the desktop VS Code instead."
        az logout 2>/dev/null
        azure_logged_in_user=""
    fi

    # Prompt user to log in if not logged in
    if [[ -z "$azure_logged_in_user" ]]; then
        read -r -p "You are not logged into Azure. Press Enter to log in. A browser will launch"
        if ! az login --allow-no-subscriptions 1>/dev/null; then
            echo_error "Error: Failed to log in to Azure. Manually log in to Azure and try again."
            return 1
        fi

        # Extract user display name from JSON output
        az_info=$(az ad signed-in-user show 2>/dev/null)
        azure_logged_in_user=$(echo "$az_info" | jq -r '.displayName' 2>/dev/null)
        if [[ -z "$azure_logged_in_user" ]]; then
            echo_error "Error: Failed to extract user display name after logging in to Azure."
            return 1
        fi
    fi

    echo_info "Logged in to Azure as $azure_logged_in_user"
    export AZURE_LOGGED_IN_USER="$azure_logged_in_user"
    return 0
}

# simply loads the local secret file to source the environment variables.  this
# file is created in on-create.sh should always be here
function load_local_env() {
    # the following line disables the "follow the link linting", which we don't need here

    # shellcheck source=/dev/null
    source "/workspaces/secret-sample/.devcontainer/local.env"
    # a this is a config file in json format where we use jq to find/store settings
    STARTUP_OPTIONS_FILE="$PWD/.devcontainer/.localStartupOptions.json"

    # tell the dev where the options are everytime a terminal starts so that it is obvious where to change a setting
    echo_info "Local secrets file is $LOCAL_ENV.  Set environement variables there that you want to use locally."

}

# ask the user if they want to use GitLab, and if so ask for the  Gitlab token and export it
# as GITLAB_TOKEN.  Remember their decision in the $STARTUP_OPTIONS_FILE
# side effects of this function:  USE_GITLABS and GITLAB_TOKEN are set
function get_gitlab_token() {
    USE_GITLAB=true

    if [[ -f $STARTUP_OPTIONS_FILE ]]; then
        USE_GITLAB=$(jq .useGitlab -r <"$STARTUP_OPTIONS_FILE")
    fi

    # ech this text so that the dev working on this code knows to go to this file to change the setting
    if [[ $USE_GITLAB == false ]]; then
        echo_info "useGitlab set to false in $STARTUP_OPTIONS_FILE."
        return 1
    fi

    read -r -p "Would you like to use Gitlab? [yN]" USE_GITLAB
    if [[ $USE_GITLAB == "y" || $USE_GITLAB == "Y" ]]; then
        USE_GITLAB=true
        echo '{"useGitlab": true}' | jq >"$STARTUP_OPTIONS_FILE"
    else
        USE_GITLAB=false
        echo '{"useGitlab": false}' | jq >"$STARTUP_OPTIONS_FILE"
        return 1
    fi
    read -r -p "what is the value for GITLAB_TOKEN? " input
    export GITLAB_TOKEN=$input
    return 0
}

# secret initialization - in this scenario, the only secret that the dev has to deal with is the GITLAB_TOKEN.  if other
# secrets are needed, then this is where we would deal with them. we can either be in codespaces or running on a docker
# container on someone's desktop.  if we are in codespaces e can store per-dev secrets in GitHub and not have to worry about
# storing them locally.  Codespaces will set an environment variable CODESPACES=true if it is in codespaces.  Even if we are 
# not in Codespaces, we still set he user secret in Github so that if codespaces is used, it will be there.
# the pattern is
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

# see if the user is logged into GitHub and if not, log them in.
# it is possible that the user is only using GitLab, but the source
# is in GitHub, so they should have a GitHub account and be logged in
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
    SECRET_COUNT=$(gh api -H "Accept: application/vnd.github+json" /user/codespaces/secrets | jq -r .total_count)

    # if we don't have the scopes we need, we must update them
    if [[ -z $SECRET_COUNT ]] && [[ $USER_LOGGED_IN == true ]]; then
        echoWarning "You are not logged in with permissions to check user secrets.  Adding them by refreshing the token"
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
# call load_local_env fist because in Codespaces, the shell starts with the secrets set so this makes the
# initial conditions of the script the same if the dev is running in codespace or in a local docker container
load_local_env
login_to_github
login_to_azure
setup_secrets
