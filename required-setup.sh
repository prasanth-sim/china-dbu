#!/bin/bash
set -Eeuo pipefail
trap 'echo "[ ERROR] Line $LINENO: $BASH_COMMAND (exit $?)"' ERR

# === Setup Script Context ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="[env-setup]"
# Use a separate file to hold credentials specifically for this script's use
CREDENTIALS_FILE="$SCRIPT_DIR/.git-credentials"

log() {
  echo "$LOG_PREFIX $(date +'%F %T') $*"
}

# === Install Tools ===
log "Updating package list..."
sudo apt-get update -y

log "Installing Git, curl, unzip, and essential tools..."
sudo apt-get install -y git curl unzip software-properties-common

log "Installing OpenJDK 17..."
sudo apt-get install -y openjdk-17-jdk

log "Installing Maven..."
sudo apt-get install -y maven

# Node.js (prompt version)
read -rp "Enter Node.js version to install [default: 18.20.6]: " NODE_VERSION
NODE_VERSION="${NODE_VERSION:-18.20.6}"
log "Installing Node.js $NODE_VERSION..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

log "Installing GNU Parallel..."
sudo apt-get install -y parallel

# === Git Credentials Setup ===
log "Setting up Git credentials."
# Only prompt for credentials if credentials file doesn't exist.
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
  read -p "Enter your GitHub username: " GIT_USERNAME
  read -s -p "Enter your GitHub personal access token (PAT): " GIT_TOKEN
  echo
  echo "GIT_USERNAME=$GIT_USERNAME" > "$CREDENTIALS_FILE"
  echo "GIT_TOKEN=$GIT_TOKEN" >> "$CREDENTIALS_FILE"
  chmod 600 "$CREDENTIALS_FILE"
  log "Credentials file created with credentials at $CREDENTIALS_FILE"
else
  log "Credentials file already exists. Skipping prompt."
fi

# === Version Checks ===
echo
log "Verifying tool versions..."

read -rp "Expected Java major version [default: 17]: " EXPECTED_JAVA
read -rp "Expected Maven major version [default: 3]: " EXPECTED_MAVEN
read -rp "Expected Node.js version (exact/partial) [default: $NODE_VERSION]: " EXPECTED_NODE
read -rp "Expected GNU Parallel version (partial) [default: 2020]: " EXPECTED_PARALLEL

EXPECTED_JAVA="${EXPECTED_JAVA:-17}"
EXPECTED_MAVEN="${EXPECTED_MAVEN:-3}"
EXPECTED_NODE="${EXPECTED_NODE:-$NODE_VERSION}"
EXPECTED_PARALLEL="${EXPECTED_PARALLEL:-2020}"
EXPECTED_GIT="2"

check_version() {
  TOOL="$1"
  ACTUAL="$2"
  EXPECTED="$3"
  if [[ "$ACTUAL" == *"$EXPECTED"* ]]; then
    log "$TOOL version OK: $ACTUAL"
  else
    log "$TOOL version mismatch: found '$ACTUAL', expected to include '$EXPECTED'"
    read -p "Continue setup despite $TOOL version mismatch? (y/n): " CONTINUE
    [[ "$CONTINUE" == "y" || "$CONTINUE" == "Y" ]] || exit 1
  fi
}

JAVA_VERSION=$(java -version 2>&1 | awk -F[\".] '/version/ {print $2}')
MAVEN_VERSION=$(mvn -v | awk '/Apache Maven/ {print $3}' | cut -d. -f1)
NODE_ACTUAL=$(node -v | tr -d 'v')
GIT_VERSION=$(git --version | awk '{print $3}' | cut -d. -f1)
PARALLEL_VERSION=$(parallel --version | head -n 1 | awk '{print $3}')

check_version "Java" "$JAVA_VERSION" "$EXPECTED_JAVA"
check_version "Maven" "$MAVEN_VERSION" "$EXPECTED_MAVEN"
check_version "Node.js" "$NODE_ACTUAL" "$EXPECTED_NODE"
check_version "Git" "$GIT_VERSION" "$EXPECTED_GIT"
check_version "GNU Parallel" "$PARALLEL_VERSION" "$EXPECTED_PARALLEL"

log "Environment setup completed successfully."
