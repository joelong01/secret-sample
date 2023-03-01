#!/bin/bash

# Define the startup line to be added to the .bashrc
STARTUP_LINE="source $PWD/.devcontainer/onTerminalStart.sh"

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
# from the dev that is shown in onTerminalStart.sh
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
