Secure Secrets in Dev Containers

# Introduction

Secure software delivery is a fundamental aspect of software development and operations. Establishing secure code repositories and developer containers from the start is crucial in ensuring the confidentiality, integrity, and availability of software assets for customers. This document outlines the best practices and learnings from a recent project, providing guidance on how to set up a secure and effective repository and container management process.

This document is focused on ways for developers to configure secrets in their inner loop environment. For best practices on managing secrets for deployed applications, refer to the [Microsoft Solution Playbook Secrets Store content](https://preview.ms-playbook.com/code-with-devsecops/Capabilities/02-Develop/Secrets-Store/). Another good practice to consider is enabling [Secrets Detection](https://preview.ms-playbook.com/code-with-devsecops/Capabilities/02-Develop/Secrets-Detection/) for any case a developer accidentally checks-in a secret.

# Design Goals

1.  Ease of Use for Developers: The repository should be easy to clone and use, with configuration in one place and not requiring developers to go through a lengthy readme file. The *use* of the repo will guide the user to do the right thing without having to consult a readme file.
2.  Secure by Default: The repository should be secure by default, making it as difficult as possible to accidentally check-in secrets. The repo is shared, but some secrets should be private to the individual developers.
3.  Portable: The project should work in a docker container or in codespaces.
4.  As much as possible, secrets should not be stored in clear text in the container. If possible they shouldn’t be stored on the box anywhere.

# Design

In this project, there are three different logins required from the dev container: Azure CLI, GitHub, and GitLab. Each of these logins have a unique approach for authenticating, storing secrets securely in the container environment, and using the secrets to establish a connection the next time the dev container is started. The following describes the implementation of authentication for each login, taking into consideration the previously outlined design goals.

Figure 1: scripts

To initialize the process for each of the logins, code needs to be executed when a terminal is started. This code will verify the presence of valid secrets, check if authentication has already occurred, and prompt the developer for any necessary actions. The most straightforward approach is to run the code in the **.bashrc** startup script. To ensure maintainability, a **startup.sh** script is included in the project and added to **.bashrc**, which will be executed every time a new terminal is created. The code is added to the .**bashrc** by running a script specified in the **devcontainer.json** as shows in *figure 1.*
```json
"postCreateCommand": "/bin/bash -c 'source ./.devcontainer/postCreate.sh'"
```
postCreateCommand is called by the VS Code container extension after the container is created (see https://code.visualstudio.com/docs/devcontainers/create-dev-container)

For any files created that should not be checked into the code repository, they include “local” in the file name and are listed in the [**.gitignore**](./.gitignore) file with the exclusion rule: 
```
*local*.*
```
When creating the dev container, the following code is run using the *postCreateCommand* in the **devcontainer.json** file.
```console
"postCreateCommand": "/bin/bash -c './.devcontainer/postCreate.sh'"
```
This simply tells VS Code to run the bash script call postCreate.sh

The [**postCreate.sh](.devcontainer/postCreate.sh) script looks like this:
```shell
#!/bin/bash

# Define the startup line to be added to the .bashrc
STARTUP_LINE="source $PWD/.devcontainer/startup.sh"

# Check if the startup line exists in the .bashrc file
if ! grep -q "${STARTUP_LINE}" "$HOME"/.bashrc; then
  # If it doesn't exist, append the line to the .bashrc file
  echo "${STARTUP_LINE}" >>"$HOME"/.bashrc
fi
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

# Define the secret section - if there are more secrets, add them here and follow the pattern for getting the values
# from the dev that is shown in startup.sh
SECRET_SECTION=$(
  cat <<EOF

# export is required so that when child processes are created # (say a terminal or running coraclcli) they also get 
# these vars set if you need to add another env var, follow this pattern.  Note that these settings are *ignored*
# when running in Codespaces as the values are kept in Codespaces User Secrets

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
The script above does 3 things:

1.  Defines full path to the startup.sh file, checking to see if the .bashrc already has the line, and if not, adds it to the .bashrc.
2.  Creates a string that can optionally be added to a secrets file. Note that this particular way of constructing a string in bash is nice because the written text shows up exactly this way in the file when the string is saved.
3.  If the secrets file doesn’t exist and the code, VS Code is not running in codespaces (more on this later), and the text is not already in the file – then the script will create the add the text to the file and create it if it doesn’t already exist.

    postCreate.sh can also contain specific code that needs to run when the container is created outside the scope of securing credentials.

The [**startup.sh**](./.devcontainer/startup.sh) script will contain different code for each of the methods below for authenticating and storing secrets.

## GitLab

GitLab requires the typical approach often seen with dev containers which is to include a personal access token as an environment variable and reference it when calling to the GitLab REST API, for example from a *curl* command.

There are multiple methods for injecting environmental variables into a dev container. The one used for this project is to store a **local-secrets.env** file in local storage. This file will contain secrets so it will be added to **.gitignore** so that it is not checked in to the code repository. To make it so that a developer is less likely to check in local only data, the .gitignore setting is set to

\*local\*.\*

This way a dev can dev can always create a local only file by having ‘local’ someplace in the filename.

The startup script will check for the existence of this file. If it does not exist, it will create the file with “empty” environment variables and instruct the developer to add their individual secret.

SECRETS_FILE=\$PWD/.devcontainer/local-secrets.env

echo "Secrets file is \$SECRETS_FILE"

\# if the file doesn't exist, create one

if [ ! -f "\$SECRETS_FILE" ]; then

echo "Creating a default environment file \$SECRETS_FILE. Set these variables in \$SECRETS_FILE and restart the shell."

{

echo "\# set these environment variables to make the project work"

echo "\# DO NOT CHECKIN THIS FILE"

echo ""

echo "\# the .vscode/settings.json specifies this file for \\"go.testEnvFile\\""

echo "\# and that requires a key=value format"

echo ""

echo "GITLAB_TOKEN="

echo ""

echo "\# export is required so that when child processes are created"

echo "\# (say a terminal or running coraclcli) they also get these vars set"

echo '\# if you need to add another env var, follow this pattern.'

echo ""

echo "export GITLAB_TOKEN"

echo ""

} \>\>"\$SECRETS_FILE"

fi

\# shellcheck disable=SC1090

source "\$SECRETS_FILE"

It is a good practice to echo the file location to the terminal, so the developer has an easy way to click and open the file to inspect its contents.

Secrets file is /workspaces/coralcli/.devcontainer/local-secrets.env

Note also that the **local-secrets.env** file separates the assignment of the environment variable from the task of marking it for Export. This is both a bash best practice (for example, see <https://www.shellcheck.net/wiki/SC2155>) and makes the file compatible with both the bash *source* command developer tools that will import **.env** files.

## GitHub

Wherever possible, the methods available in the CLI for the respective services should be utilized for authentication and secret storage. This approach makes it simpler for the developer and enables the service to manage the validity period of the token and its renewal process.

GitHub provides a CLI called **gh** that includes a method for authenticating to the GitHub service without creating a personal access token. The tool will launch a browser to authenticate the user and store a token in a “hidden” place. No environment variable is set by **gh** and the developer never needs to look for one to do all the normal GitHub activities.

Here’s the code in **startup.sh** for logging into GitHub.

\# see if the user is logged into GitHub and if not, log them in. it is possible that the user is only using GitLab, so only

\# prompt once and then remember the user said "no"

STARTUP_OPTIONS_FILE="\$PWD/.devcontainer/.localStartupOptions.json"

echo "Startup options set in \$STARTUP_OPTIONS_FILE"

LOGIN_TO_GITHUB=true

if [[ -f \$STARTUP_OPTIONS_FILE ]]; then

LOGIN_TO_GITHUB=\$(jq .logintoGitHub -r \<"\$STARTUP_OPTIONS_FILE")

fi

if [ "\$LOGIN_TO_GITHUB" != "false" ]; then

export GH_AUTH_STATUS

GH_AUTH_STATUS=\$(gh auth status 2\>&1 \>/dev/null)

\# this is a very specific error that gh auth status returns.

if [[ \$GH_AUTH_STATUS == "You are not logged into any GitHub hosts. Run gh auth login to authenticate." ]]; then

read -r -p "You are not logged into GitHub. Login now? [Yn]" input

if [ -z "\$input" ] \|\| [ "\$input" == "y" ] \|\| [ "\$input" == "Y" ]; then

LOGIN_TO_GITHUB=true

gh auth login

GH_AUTH_STATUS=\$(gh auth status 2\>&1 \>/dev/null)

else

\# have a local json file that we read with a setting to not login to

\# github. change this to true if you want to use gh.

echo '{"logintoGitHub": false}' \| jq \>"\$STARTUP_OPTIONS_FILE"

fi

fi

fi

\# this just echo’s a nice message to the user

\# we also \*want\* expansion/globbing here to find the check,

\# so disable SC2086 for this one line

\#shellcheck disable=SC2086

GITHUB_INFO="\$(echo \$GH_AUTH_STATUS \| awk -F'✓' '{print \$2}')"

if [[ -z \$GITHUB_INFO ]]; then

echo "You are not logged into GitHub"

else

echo "\$GITHUB_INFO"

fi

The first thing this script does is check for a **localStartupOptions.json** file. This is another file with “local” in the name and will be excluded from the code repository by **.gitignore.**

Here’s what the GitHub login code does:

1.  Check to see if the **.localStartupOptions.json** file exists and if so, gets the setting to see if the local developer has declined logging into GitHub.
2.  If the developer wants to login to GitHub, logs in using ‘gh auth login’ .
3.  Gets the status from **gh**, which looks something like this:

    ![Text Description automatically generated](media/b2216153ff41f74bf35b56306040c249.png)

    The script only outputs the “Logged in” line by passing the result through **awk**.

    GITHUB_INFO="\$(echo \$GH_AUTH_STATUS \| awk -F'✓ ' '{print \$2}')"

And echo it out. This looks something like

Logged in to github.com as joelong01 (/home/vscode/.config/gh/hosts.yml)

1.  If the developer is not logged into GitHub, they are prompted whether to login. If yes, then the normal **gh** login process is launched, and a token is stored by the CLI. No need to write down a user token in a file anywhere.

## Azure

The Azure CLI also provides a method for logging into the developer’s subscription and store a token in the container separate from the repo files. Here’s what the Azure CLI code looks like:

\# see if the user is logged into Azure and if not, log them in

USER_INFO=\$(az ad signed-in-user show 2\>/dev/null)

if [[ -z \$USER_INFO ]]; then

read -r -p "You are not logged into azure. Hit any key to login. A browser will launch."

az login --allow-no-subscriptions 2\>/dev/null 1\>/dev/null

USER_INFO=\$(az ad signed-in-user show)

fi

\# keep the user name around and echo it when the terminal starts

export AZ_USER_NAME

AZ_USER_NAME=\$(echo "\$USER_INFO" \| jq -r .displayName)

echo "Logged in to Azure as \$AZ_USER_NAME"

# Wrap-up

The full output of the script when starting a terminal looks something like this:

![Text Description automatically generated](media/9cdb639eecccc1c79d98512d8d777bbc.png)

The full script will:

1.  Automatically log the dev in when the first terminal is opened in VS Code.
2.  Never write down or show the GitHub PAT.
3.  For secrets that are not automated, provides a way to store them locally in one place and (hopefully) not check them in by accident.
4.  Works in both local Containers and CodeSpaces.
5.  “leads” the dev to figuring out where state needs to be entered to make the system work.

Check it out at <https://github.com/joelong01/coralcli>

# Pitfalls

This section includes some alternatives that were tried but did not meet the design goals:

**A simple .env file with an example in the repository and described in the README.**

This approach is often used in repositories, and it works for a small team that is aware of how the project is setup and the steps to take in creating their inner loop environment.

\#!/bin/bash

GITHUB_TOKEN=gho_70iyx\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*W3Pqh

However, it did not meet the design goals:

1.  We still have a PAT in clear text, in a file that might get checked in by mistake. This was unavoidable for the GitLab case, but there were better options for GitHub and Azure.
2.  The typical **.env** file can be executed as a shell script but the environment variables are not marked for *export*.
3.  Including the export breaks the ability to import the file into developer tools such as the Golang Debugger. (Note: the *export* command can be run in a separate shell command)
4.  It is still a “magic” setting that needs to be documented in README and discovered by the dev for it to work.

To meet the design goals, the **startup.sh** script handles the best possible case for each of the services (GitLab uses the personal access token, but GitHub uses the **gh** cli). The script also validates each login when a terminal is created and makes it clear to the developer any actions needed. The developer doesn’t need to find the instructions in README.

**Adding secrets using attributes in devcontainer.json**

There are [several ways to include secrets as environment variables](https://code.visualstudio.com/remote/advancedcontainers/environment-variables) from the container definition in **devcontainer.json** or the **Dockerfile** used to create the container. In all cases, these require the file to exist before the container is initialized. This breaks the portability design goal because Codespaces is unable to initialize this file before creating the container. The only workaround is to check the **.env** file into source control.

1.  X Include the secrets as environment variables in the **Dockerfile**
2.  X Check-in an .env with the secrets file referenced from **devcontainer.json**

Another option might be to create this file in source control with “empty” values and have the developer fill in these variables but not check-in the new file. While that may work, it requires the Developer to rebuild the container after defining the environment variables and adds extra danger that the file might get accidentally checked-in to the repository with secrets included.
