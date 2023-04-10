#!/bin/bash

# Define the startup line to be added to the .bashrc
STARTUP_LINE="source $PWD/.devcontainer/onTerminalStart.sh"

# Check if the startup line exists in the .bashrc file
if ! grep -q "${STARTUP_LINE}" "$HOME"/.bashrc; then
  # If it doesn't exist, append the line to the .bashrc file
  echo "${STARTUP_LINE}" >>"$HOME"/.bashrc
fi
