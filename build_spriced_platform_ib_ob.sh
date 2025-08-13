#!/bin/bash
set -Eeuo pipefail
trap 'echo "[❌ ERROR] Line $LINENO: $BASH_COMMAND (exit $?)"' ERR

# ==============================================================================
# SCRIPT METADATA AND CONFIGURATION
# ==============================================================================
# This script builds the 'spriced-platform-ib-ob' Maven project.
# It clones/updates the repository, runs a clean install, copies the resulting
# JAR file, and creates a 'latest' symlink for easy access.
#
# Arguments:
#   $1: Branch name (default: 'main')
#   $2: Base directory for repos, builds, and logs
# ==============================================================================

# === INPUT ARGUMENTS ===
readonly BRANCH="${1:-main}"
readonly BASE_DIR="${2:-$HOME/automation_workspace}"

# === REPO CONFIGURATION ===
readonly REPO="spriced-platform-ib-ob"
readonly GIT_URL="https://github.com/simaiserver/$REPO.git"
readonly ARTIFACT_NAME="workflow-orchestrator-*.jar"

# === DYNAMIC PATHS ===
readonly DATE_TAG=$(date +"%Y%m%d_%H%M%S")
readonly REPO_DIR="$BASE_DIR/repos/$REPO"
readonly BUILD_BASE="$BASE_DIR/builds/$REPO"
readonly LOG_DIR="$BASE_DIR/automationlogs"
readonly LOG_FILE="$LOG_DIR/${REPO}_${DATE_TAG}.log"
readonly BUILD_DIR="$BUILD_BASE/${BRANCH//\//_}_${DATE_TAG}"

# Create necessary directories
mkdir -p "$REPO_DIR" "$BUILD_BASE" "$LOG_DIR"

# Tee output to log file and stdout
exec > >(tee -a "$LOG_FILE") 2>&1

echo "🚀 Starting build for [$REPO] on branch [$BRANCH]"

# === Clone or Update Repository ===
if [[ -d "$REPO_DIR/.git" ]]; then
    echo "🔁 Updating existing repo at $REPO_DIR"
    (
        cd "$REPO_DIR" || exit 1
        git fetch origin
        git checkout "$BRANCH"
        git pull origin "$BRANCH"
    )
else
    echo "📥 Cloning repo to $REPO_DIR"
    git clone "$GIT_URL" "$REPO_DIR"
    (
        cd "$REPO_DIR" || exit 1
        git checkout "$BRANCH"
    )
fi

# === Build Project ===
echo "🔨 Running Maven build..."
cd "$REPO_DIR" || exit 1
mvn clean install -Dmaven.test.skip=true

# === Artifact Copy ===
mkdir -p "$BUILD_DIR"
echo "📦 Searching for and copying built JARs to [$BUILD_DIR]..."
find "$REPO_DIR" -type f -path "*/target/$ARTIFACT_NAME" -exec cp -v {} "$BUILD_DIR/" \;

# === Update 'latest' Symlink ===
echo "🔗 Updating 'latest' symlink..."
ln -sfn "$BUILD_DIR" "$BUILD_BASE/latest"

# === Done ===
echo "✅ Build complete for [$REPO] on branch [$BRANCH]"
echo "🗂️ Artifacts stored at: $BUILD_DIR"
echo "🔗 Latest symlink: $BUILD_BASE/latest"
