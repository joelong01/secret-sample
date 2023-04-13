# Secure Secrets in Dev Containers

## Introduction

Secure software delivery is a fundamental aspect of software development and operations. Establishing secure code repositories and developer containers from the start is crucial in ensuring the confidentiality, integrity, and availability of software assets for customers. This document outlines the best practices and learnings from a recent project, providing guidance on how to set up a secure and effective repository and container management process.

This document is focused on ways for developers to configure secrets in their inner loop environment. For best practices on managing secrets for deployed applications, refer to the [Microsoft Solution Playbook Secrets Store content](https://preview.ms-playbook.com/code-with-devsecops/Capabilities/02-Develop/Secrets-Store/). Another good practice to consider is enabling [Secrets Detection](https://preview.ms-playbook.com/code-with-devsecops/Capabilities/02-Develop/Secrets-Detection/) for any case a developer accidentally checks-in a secret.

The approach is to "declare" the secrets necessary to run the code in the repository be checking in a json file containing meta data about the secrets. The system is then configured such that the values for those secrets are collected and stored - either in the local container but outside of project scope, or in GitHub CodeSpaces User Secrets. By storing the secret values outside of project scope, the system protects against accidentally checking in those secret values.

*Note that we are using "secrets" here, but the system will work with any environment variable that the repo's code needs.*

GitHub Codespaces User Secrets can be optionally used to store the secrets, and when using CodeSpaces, the secrets are never stored on the client machine. The scenario for this example is a project that needs 2 secrets: a PAT for GitLab and a subscription id for Azure.  The *use* of the secrets is not part of the example.  The dev environment must support running both a docker container and GitHub CodeSpaces.
## Setup instructions
To use devsecrets, copy the **devsecrets.sh** script to the .devcontainer directory of your project.  Then from the .devcontainer directory run

```shell
    chmod +x ./devsecrets.sh
    ./devsecrets.sh setup

```
This will create a **required-secrets.json** file for you.  Enter your secret information into the json in the format defined below and then run 
```shell
    devsecrets.sh update
```
Alternatively, open another shell after you edit your json - the command ```devsecrets.sh update``` is run from the **.bashrc** or the **.zshrc**, so it will run every time a terminal starts.

If the file is checked into the repo after setup has been run, then the developer does nothing -- the creation of the container will drive the scripts to do the right thing.

## Design Goals

1. Ease of Use for Developers: The repository should be easy to clone and use, with configuration in one place and not requiring developers to go through a lengthy readme file. The *use* of the repo will guide the user to do the right thing without having to consult a readme file.
2. Declarative: a checked in file contains the information about the secrets necessary to use the repo.
3. Secure by Default: The repository should be secure by default, making it as difficult as possible to accidentally check-in secrets. The repo is shared, but some secrets should be private to the individual developers. As much as possible, secrets should not be stored in clear text in the container. Ideally they shouldn’t be stored on the box anywhere.
4. Portable: The project should work in a docker container or in Codespaces.
5. Idempotent:  if there is a problem in the collection, use, or storage of the secrets, the system will do the right thing to eventually get to the correct state.
6. Self correcting: if a developer accidentally breaks something, the system should fix it as much as possible.

## Design
The approach is to declare the secrets necessary to run the code in the repository be checking in a json file containing meta data about the secrets in a file named *.devcontainer/required-secrets.json*.

The example json is checked in to [required-secrets.json](.devcontainer/required-secrets.json), which looks like

```json
{
    "options": {
        "useGitHubUserSecrets": true
    },
    "secrets": [
        {
            "environmentVariable": "GITLAB_TOKEN",
            "description": "the PAT for Gitlab",
            "shellscript": ""
        },
        {
            "environmentVariable": "SECRET_SAMPLE_AZ_SP_APP_ID",
            "description": "the AppId for the Azure Service Principle for the Secret Sample App",
            "shellscript": "./.devcontainer/create-azure-service-principal.sh"
        },
        {
            "environmentVariable": "SECRET_SAMPLE_AZ_SP_PASSWORD",
            "description": "the password for the Azure Service Principle for the Secret Sample App",
            "shellscript": "./.devcontainer/create-azure-service-principal.sh"
        },
        {
            "environmentVariable": "SECRET_SAMPLE_TENANT_ID",
            "description": "the AppId for the Azure Service Principle for the Secret Sample App",
            "shellscript": "./.devcontainer/create-azure-service-principal.sh"
        }
    ]
}
```

**useGitHubUserSecrets**:  this can be true or false and controls whether or not the system will use GitHub CodeSpaces User Secrets to store the secrets.  Note that this can be **true** while the repo is outside of CodeSpaces, in which case the secrets will be stored in a local shell script.

**secrets**: this is an array of secrets necessary to run the code in the repo.  In this case there are four secrets, a PAT to GitLab and the secrets necessary to login to Azure using a Service Principal.  Each secret has three values:

* **environmentVariable**: this is the name of the secret and the name of the environment variable that will be set with the value of the secret
* **description**: this is used to prompt the user for a value if *shellscript* is not set and as a comment in the *$HOME/.localIndividualDevSecrets.sh* file
* **shellscript**: if this is set, the *devsecrets.sh* script will call this script to collect the value for the secret.  The scripts job is to export an environment variable named the same as the "environmentVariable" setting in the json.

For the above json, *devsecrets.sh* will generate a *$HOME/.localIndividualDevSecrets.sh" file that looks like (secrets randomized!)

```shell
#!/bin/bash
# if we are running in codespaces, we don't load the local environment
if [[ $CODESPACES == true ]]; then  
  return 0
fi
# the PAT for Gitlab
export GITLAB_TOKEN
GITLAB_TOKEN=glpat-fnpk4865j8urssQR27D6i
# the AppId for the Azure Service Principle for the Secret Sample App
export SECRET_SAMPLE_AZ_SP_APP_ID
SECRET_SAMPLE_AZ_SP_APP_ID="a9ad40f8-3eac-4d5f-b004-7af6bd454ef8"
# the password for the Azure Service Principle for the Secret Sample App
export SECRET_SAMPLE_AZ_SP_PASSWORD
SECRET_SAMPLE_AZ_SP_PASSWORD="7J_2rMvPk8aMjeAW_dNYMA1RpKQbdAzNvzNtJ-9X"
# the AppId for the Azure Service Principle for the Secret Sample App
export SECRET_SAMPLE_TENANT_ID
SECRET_SAMPLE_TENANT_ID="4330d04b-58af-4e84-9b79-35c253be5163"
```

The way this works is the VS Code created file *.devcontainer/devcontainer.json* is modified to run ```devsecrets.sh setup``` when the container is finished building (using the "postCreateCommand": "./.devcontainer/devsecrets.sh setup")  The system runs scripts (*onPostCreat.sh* and *devsecrets.sh*) that interpret this json file to collect the secrets and store them outside of the project scope by updating *.bashrc* and *.zshrc* to source a *$HOME/.localIndividualDevSecrets.sh* which is created by *devsecrets.sh* based on the contents of *required-secrets.json*.  The code in the repo accesses the secrets via environment variables.

## Commands
 **devscrets.sh** takes the following parameters:
```shell
  help        Show this help message
  update      parses required-secrets.json and updates $HOME/localIndividualDevSecrets.sh
  setup       modifies the devcontainer.json to bootstrap the system
  reset       Resets $HOME/.localIndividualDevSecrets.sh and runs update
```