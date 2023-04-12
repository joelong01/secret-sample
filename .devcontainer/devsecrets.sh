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
readonly REQUIRED_REPO_SECRETS="$PWD/.devcontainer/required-secrets.json"
readonly LOCAL_SECRETS_SET_FILE="$HOME/.localIndividualDevSecrets.sh"
USE_CODESPACES_SECRETS=$(jq -r '.options.useGitHubUserSecrets' "$REQUIRED_REPO_SECRETS" 2>/dev/null)

# collect_secrets function
#
#   $1 contains a JSON array
#   1.	iterate through the array
#   2.	check a file called $ LOCAL_SECRETS_SET_FILE to see if there is text in the form “KEY=VALUE”
#       where KEY is the environment variable name (use sed for this)
#           a.	if the value is set in the file, set an environment variable with this key and value
#           b.	continue to the next array element
#   3.	if the shellscript is not empty, it should "source" the script
#   4.	if it is empty, it should prompt the user for the value using the description
#   5.	it should set the environment variable to the value entered
#   6.	if the script is called, the script will set the environment variable
#
function collect_secrets() {
    # Parse the JSON input
    local json_array # renamed $1: a json array of secrets (environmentVariable, description, and shellscript)
    local length     # the length of the json array
    json_array=$1
    length=$(echo "$json_array" | jq '. | length')

    # Iterate through the array
    for ((i = 0; i < length; i++)); do
        # Extract JSON properties
        local environmentVariable # the name of the environment variable
        local description
        local shellscript # a shellscript that will provide information to the user to collect the needed value
        environmentVariable=$(echo "$json_array" | jq -r ".[$i].environmentVariable")
        description=$(echo "$json_array" | jq -r ".[$i].description")
        shellscript=$(echo "$json_array" | jq -r ".[$i].shellscript")

        # check to make sure that if shellscript is set that the file exists
        if [[ -n "$shellscript" && ! -f "$shellscript" ]]; then
            echo_error "ERROR: $shellscript specified in $REQUIRED_REPO_SECRETS does not exist."
            echo_error "$environmentVariable will not be set."
            echo_error "Note:  \$PWD=$PWD"
            continue
        fi
        # Check if the environment variable is set in the local secrets file
        local secret_entry
        secret_entry=$(grep "^$environmentVariable=" "$LOCAL_SECRETS_SET_FILE" | 
                        sed 's/^.*=\(.*\)$/\1/; s/\\\([^"]\|$\)/\1/g; s/^"\(.*\)"$/\1/' 2>/dev/null)

        if [[ -n "$secret_entry" ]]; then
            # Get the value from the secret_entry
            local value
            value=$(echo "$secret_entry" | cut -d'=' -f2)

            # Set the environment variable with the key and value from the file
            export "$environmentVariable=$value"
        else
            if [[ -n "$shellscript" ]]; then
                # If shellscript is not empty, source it
                #shellcheck disable=SC1090
                source "$shellscript"
            else
                # If shellscript is empty, prompt the user for the value using the description
                echo -n "Enter $description: "
                read -r value

                # Set the environment variable to the value entered
                export "$environmentVariable=$value"
            fi
        fi
    done
}

# build_save_secrets_script function
# this builds the script that is called by update_secrets.sh that sets the secrets
# $1 contains a JSON array

function build_save_secrets_script() {
    local toWrite
    toWrite="#!/bin/bash
# if we are running in codespaces, we don't load the local environment
if [[ \$CODESPACES == true ]]; then  
  return 0
fi
"
    local environmentVariable
    local description
    local val        # the value of the environment variable
    local json_array # renamed $1: a json array of secrets (environmentVariable, description, and shellscript)
    local length     # the length of the json array
    json_array=$1
    length=$(echo "$json_array" | jq '. | length')
    # Iterate through the array
    for ((i = 0; i < length; i++)); do
        environmentVariable=$(echo "$json_array" | jq -r ".[$i].environmentVariable")
        val="${!environmentVariable}"
        description=$(echo "$json_array" | jq -r ".[$i].description")
        toWrite+="# $description\nexport $environmentVariable\n$environmentVariable=\"$val\"\n"
    done
    echo -e "$toWrite" >"$LOCAL_SECRETS_SET_FILE"
    # we don't have to worry about sourcing this when in CodeSpaces as the script will exit if
    # CODESPACES == true.  the shellcheck disable is there to tell the linter to not worry about
    # linting the script that we are sourcing
    # shellcheck disable=1090
    source "$LOCAL_SECRETS_SET_FILE"
}

# function save_in_codespaces()
# $1 contains a JSON array of secrets
# go through that array and save the secret in Codespaces User Secrets
# makes sure that if the secret already exists *add* the current repo to the repo list instead of just updating it
# which in current GitHub, resets the secret to be valid in only the specified repos
# assumes that every secret has an environment variable set with the correct value
function save_in_codespaces() {

    local repos               # the repos the secret is available in
    local url                 # the url to get the secret's repos
    local environmentVariable # the name of the secret
    local val                 # the secrets value
    local gh_pat              # the GitHub PAT - needed to call the REST api
    local current_repo        # the repo of the current project
    local json_array          # renamed $1: a json array of secrets (environmentVariable, description, and shellscript)
    local length              # the length of the json array

    json_array=$1
    length=$(echo "$json_array" | jq '. | length')
    current_repo=$(git config --get remote.origin.url | sed -e 's|^https://github.com/||' | sed -e 's|.git$||')

    gh_pat=$(gh auth token)
    length=$(echo "$json_array" | jq '. | length')
    for ((i = 0; i < length; i++)); do
        environmentVariable=$(echo "$json_array" | jq -r ".[$i].environmentVariable")
        val="${!environmentVariable}" # we assume that this has been set before this function is called
        url="https://api.github.com/user/codespaces/secrets/$environmentVariable/repositories"
        # this curl syntax will allow us to get the resonse and the response code
        response=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $gh_pat" "$url")
        response_code=${response: -3}
        response=${response:0:${#response}-3}

        # if the secret is not set, we'll get a 404 back.  then the repo is just the current repo
        case $response_code in
        "404")
            repos="$current_repo"
            ;;
        "200")
            # a 2xx indicates that the user secret already exists.  get the repos that the secret is valid in.
            repos=$(echo "$response" | jq '.repositories[].full_name' | paste -sd ",")
            # Check if current_repo already exists in repos, and if not then add it
            # if you don't do this, the gh secret set api will give an error
            if [[ $repos != *"$current_repo"* ]]; then
                repos+=",\"$current_repo\""
            fi
            ;;
        *)
            echo_error "unknown error calling $url"
            echo_error "Secret=$environmentVariable value=$val in repos=$repos"
            ;;
        esac

        # set the secret -- we always do this as the value might have changed...we can't check the value
        # using the current GH api.
        gh secret set "$environmentVariable" --user --app codespaces --repos "$repos" --body "$val"
    done
}

#
#   load the devscrets.json file and for each secret specified do
#   1. check if the value is known, if not prompt the user for the value
#   2. reconstruct and overwrite the $LOCAL_SECRETS_SET_FILE
#   3. source the $LOCAL_SECRETS_SET_FILE
function update_secrets {

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

    # we require GitHub login if GitHub secrets are being used. there might be other reasons outside the pervue of this
    # this script to login to GitHub..
    if [[ $USE_CODESPACES_SECRETS == "true" ]]; then
        login_to_github
    fi

    # load the secrets file to get the array of secrets
    local json_secrets_array # a json array of secrets loaded from the $REQUIRED_REPO_SECRETS file

    json_secrets_array=$(jq '.secrets' "$REQUIRED_REPO_SECRETS")

    # iterate through the JSON and get values for each secret
    # when this returns each secret will have an environment variable set
    collect_secrets "$json_secrets_array"

    # build, save, and source the local secrets script
    build_save_secrets_script "$json_secrets_array"

    # if the user wants to use codespaces secrets, iterate through the json array
    # and store the secret in CodeSpaces user secrets, adding the current repo
    if [[ "$USE_CODESPACES_SECRETS" == "true" ]]; then
        save_in_codespaces "$json_secrets_array"
    fi

}

# see if the user is logged into GitHub with the scopes necessary to use Codespaces secrets.
#  not, log them in.
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

function initial_setup() {
    # Define the startup line to be added to the .bashrc
    STARTUP_LINE="source $PWD/.devcontainer/devsecrets.sh update"

    # Check if the startup line exists in the .bashrc file
    if ! grep -q "${STARTUP_LINE}" "$HOME"/.bashrc; then
        # If it doesn't exist, append the line to the .bashrc file
        echo "${STARTUP_LINE}" >>"$HOME"/.bashrc
    fi
    # Check if the startup line exists in the .zshrc file
    if ! grep -q "${STARTUP_LINE}" "$HOME"/.zshrc; then
        # If it doesn't exist, append the line to the .bashrc file
        echo "${STARTUP_LINE}" >>"$HOME"/.zshrc
    fi

    # if there isn't a json file, create a default one
    if [[ ! -f $REQUIRED_REPO_SECRETS ]]; then
        echo '{
    "options": {
        "useGitHubUserSecrets": false
    },
    "secrets": []
}' >"$REQUIRED_REPO_SECRETS"
    fi
}

function show_help() {
    echo "Usage: devsecrets.sh [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  help        Show this help message"
    echo "  update      parses requiredRepoSecrets.json and updates $LOCAL_SECRETS_SET_FILE"
    echo "  setup       modifies the devcontainer.json to bootstrap the system"
    echo "  reset       Resets $LOCAL_SECRETS_SET_FILE and runs update"
    echo ""
}
# this is where code execution starts
case "$1" in
help)
    show_help
    ;;
update)
    update_secrets
    ;;
setup)
    initial_setup
    ;;
reset)
    rm "$LOCAL_SECRETS_SET_FILE" 2>/dev/null
    update_secrets
    # code for resetting the terminal goes here
    ;;
*)
    echo "Invalid option: $1"
    show_help
    ;;
esac
