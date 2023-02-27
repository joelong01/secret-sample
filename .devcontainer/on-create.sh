#!/bin/bash

# Define the startup line
STARTUP_LINE="source $PWD/.devcontainer/.startup.sh"

# Check if the startup line exists in the .bashrc file
if ! grep -q "${STARTUP_LINE}" "$HOME"/.bashrc; then
  # If it doesn't exist, append the line to the .bashrc file
  echo "${STARTUP_LINE}" >>"$HOME"/.bashrc
fi

# Set the secrets file
SECRETS_FILE="$PWD/.devcontainer/local-secrets.env"
echo "Secrets file is $SECRETS_FILE"



# Define the secret section
SECRET_SECTION=$(cat <<EOF

# export is required so that when child processes are created
# (say a terminal or running coraclcli) they also get these vars set
# if you need to add another env var, follow this pattern.
GITLAB_TOKEN=
export GITLAB_TOKEN

EOF
)

# Check if the secrets file exists and if the user is running in codespaces
if [[ -f "${SECRETS_FILE}" ]] && [[ "$CODESPACES" != true ]]; then
  # Check if the secret section exists in the secrets file
  if ! grep -q "export GITLAB_TOKEN" "${SECRETS_FILE}"; then
    # If it doesn't exist, append the section to the secrets file
    echo "${SECRET_SECTION}" >>"$SECRETS_FILE"
  fi
fi

# add anything that needs to be run when the container is created 
