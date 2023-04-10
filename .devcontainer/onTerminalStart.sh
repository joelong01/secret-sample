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
readonly REQUIRED_REPO_SECRETS="$PWD/.devcontainer/requiredRepoSecrets.json"
readonly LOCAL_SECRETS_SET_FILE="$HOME/.localIndividualDevSecrets.sh"
USE_CODESPACES_SECRETS=$(jq -r '.options.useGitHubUserSecrets' "$REQUIRED_REPO_SECRETS")

#
#   load the devscrets.json file and for each secret specified do
#   1. check if the value is known, if not prompt the user for the value
#   2. reconstruct and overwrite the $LOCAL_SECRETS_SET_FILE
#   3. source the $LOCAL_SECRETS_SET_FILE
function buildEnvFile {

    # check the last modified date of the env file file and if it is gt the last modified time of the config file
    # we have no work to do

    if [[ -f "$LOCAL_SECRETS_SET_FILE" &&
        "$(stat -c %Y "$LOCAL_SECRETS_SET_FILE")" -ge "$(stat -c %Y "$REQUIRED_REPO_SECRETS")" ]]; then
        echo_info "using existing $LOCAL_SECRETS_SET_FILE"
        echo_info "update $REQUIRED_REPO_SECRETS if you want more secrets!"
        # shellcheck disable=1090
        source "$LOCAL_SECRETS_SET_FILE"
        return 0
    fi

    local secrets
    local toWrite
    local gh_pat
    local repos
    local current_repo
    gh_pat=$(gh auth token) #needed if we set GH secrets
    current_repo=$(git config --get remote.origin.url | sed -e 's|^https://github.com/||' | sed -e 's|.git$||')

    toWrite="#!/bin/bash
# if we are running in codespaces, we don't load the local environment
if [[ \$CODESPACES == true ]]; then  
  return 0
fi
"

    readarray -t secrets <<<"$(jq -c -r '.secrets | .[]' "$REQUIRED_REPO_SECRETS")"

    for secret in "${secrets[@]}"; do
        local key
        local val
        local desc

        key=$(echo "$secret" | jq -r .environmentVariable)
        script=$(echo "$secret" | jq -r .shellscript)
        desc=$(echo "$secret" | jq -r .description)
        if [[ -f "$LOCAL_SECRETS_SET_FILE" ]]; then
            #this picks the value from the key=value .env file
            val=$(sed -n 's/^'"$key"'=\(.*\)$/\1/p' "$LOCAL_SECRETS_SET_FILE")
        fi

        if [[ -z "$val" ]]; then            #is this a new secret?
            if [[ -n "$script" ]]; then     # is there a script?
                if [[ -f "$script" ]]; then # does the script exist?
                    # shellcheck disable=1090
                    source "$script"
                    val="${!key}" # in this scheme, the scripte exports the environment variable we are looking for
                else
                    echo_error "$script is set in $REQUIRED_REPO_SECRETS but can't be found. Bad path?"
                fi
            else # no script
                echo -n "enter $desc:"
                read -r val
            fi
        fi
        # we should have gotten the value from one of 3 places
        # 1. the $LOCAL_SECRETS_SET_FILE 2. a script 3. prompting the user
        if [[ -z "$val" ]]; then
            echo_warning "the value for $key is being set to empty"
        fi

        if [[ $val != \"*\" ]]; then
            val=\""$val"\"
        fi

        toWrite+="# $desc\nexport $key\n$key=$val\n"

        # codespaces secrets
        if [[ "$USE_CODESPACES_SECRETS" == "true" ]]; then
            # get the repos that the current secret is valid for - we then add the current repo to it.  GitHub
            # will overwrite the repos with the gh secret set comand.  I couldn't find any way except calling
            # the GH REST API to get the repos for a secret
            local repos
            local url

            url="https://api.github.com/user/codespaces/secrets/$key/repositories"
            # this curl syntax will allow us to get the resonse and the response code
            response=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $gh_pat" "$url")
            response_code=${response: -3}
            response=${response:0:${#response}-3}

            # if the secret is not set, we'll get a 404 back.  then the repo is just the current repo
            if [[ $response_code == "404" ]]; then
                repos=$current_repo
            elif [[ $response_code == "200" ]]; then
                # a 2xx indicates that the user secret already exists.  get the repos that the secret is valid in.
                repos=$(echo "$response" | jq '.repositories[].full_name' | paste -sd ",")
                # Check if current_repo already exists in repos, and if not then add it
                # if you don't do this, the gh secret set api will give an error
                if [[ $repos != *"$current_repo"* ]]; then
                    repos+=",\"$current_repo\""
                fi
            else
                echo_error "unknown error calling $url"

            fi

            # set the secret -- we always do this as the value might have changed
            gh secret set "$key" --user --app codespaces --repos "$repos" --body "$val"
        fi

    done
    # overwrite the file with the new data
    echo -e "$toWrite" >"$LOCAL_SECRETS_SET_FILE"
    echo_info "created new $LOCAL_SECRETS_SET_FILE"
    if [[ $USE_CODESPACES_SECRETS != "true" ]]; then #don't source the file when using codespaces
        # shellcheck disable=1090
        source "$LOCAL_SECRETS_SET_FILE"
    fi

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

# we require GitHub login if GitHub secrets are being used. there might be other reasons outside the pervue of this
# this script to login to GitHub...
if [[ $USE_CODESPACES_SECRETS == "true" ]]; then
    login_to_github
fi
buildEnvFile
