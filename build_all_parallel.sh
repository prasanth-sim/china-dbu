#!/bin/bash
set -Eeuo pipefail

# ==============================================================================
# SCRIPT METADATA AND CONFIGURATION
# ==============================================================================
# This script orchestrates the parallel building of multiple repositories.
# It handles user input for repository selection, branches, and environments,
# and saves these choices for future runs.
#
# Dependencies:
#    - Git, Maven, Node.js, GNU Parallel (installable via required-setup.sh)
#    - Sub-scripts for building individual repos (e.g., build_spriced_ui.sh)
#
# Configuration files:
#    - $HOME/.repo_builder_config: Stores user preferences for the next run.
#
# Usage:
#    Run this script from the project root. It will prompt for all necessary inputs.
# ==============================================================================

# Determine the directory where this script is located
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REQUIRED_SETUP_SCRIPT="$SCRIPT_DIR/required-setup.sh"
readonly CONFIG_FILE="$HOME/.repo_builder_config"

# ==============================================================================
# FUNCTIONS
# ==============================================================================

# Function to save the current configuration to a file
save_config() {
    echo "Saving current configuration to $CONFIG_FILE..."
    {
        echo "BASE_INPUT=$BASE_INPUT"
        # Join array elements with a space for saving
        echo "SELECTED_REPOS=${SELECTED_REPO_NUMS[*]}"
        echo "UI_ENV=${BRANCH_CHOICES["spriced-ui-env"]}"
        # Iterate through the associative array of other repo branches
        for repo in "${!BRANCH_CHOICES[@]}"; do
            # Skip the UI environment variable
            if [[ "$repo" == "spriced-ui-env" ]]; then
                continue
            fi
            local var_name="BRANCH_${repo//-/_}"
            echo "$var_name=${BRANCH_CHOICES[$repo]}"
        done
    } > "$CONFIG_FILE"
    echo "Configuration saved."
}

# Function to load previous user inputs from the configuration file
load_config() {
    # Declare global variables to make them accessible throughout the script
    declare -g BASE_INPUT=""
    declare -g SELECTED_REPO_NUMS=()
    declare -gA BRANCH_CHOICES

    if [[ -f "$CONFIG_FILE" ]]; then
        echo "Loading previous inputs from $CONFIG_FILE..."
        while IFS='=' read -r key value; do
            case "$key" in
                BASE_INPUT) BASE_INPUT="$value" ;;
                SELECTED_REPOS) IFS=' ' read -r -a SELECTED_REPO_NUMS <<< "$value" ;;
                UI_ENV) BRANCH_CHOICES["spriced-ui-env"]="$value" ;;
                BRANCH_*)
                    local repo_key="${key#BRANCH_}"
                    local repo_name="${repo_key//_/'-'}"
                    BRANCH_CHOICES["$repo_name"]="$value"
                    ;;
            esac
        done < "$CONFIG_FILE"
    fi
}

# Clones or updates a repository and checks out the specified branch.
# Arguments:
#    $1: The repository name (e.g., "spriced-ui")
#    $2: The repository URL
#    $3: The local directory for the repository
#    $4: The branch name to check out
prepare_repo() {
    local repo_name="$1"
    local repo_url="$2"
    local repo_dir="$3"
    local branch="$4"

    echo "Checking '$repo_name' repository..."
    if [[ -d "$repo_dir/.git" ]]; then
        echo "Updating existing repo at $repo_dir"
        (
            cd "$repo_dir" || return 1
            git fetch origin --prune
            git reset --hard HEAD
            git clean -fd
        ) || { echo "Failed to update $repo_name."; return 1; }
    else
        echo "Cloning new repo from $repo_url into $repo_dir"
        [[ -d "$repo_dir" && ! -d "$repo_dir/.git" ]] && rm -rf "$repo_dir"
        git clone "$repo_url" "$repo_dir" || { echo "Failed to clone $repo_name."; return 1; }
    fi

    echo "Switching to branch '$branch' for '$repo_name'..."
    (
        cd "$repo_dir" || return 1
        git fetch origin
        if git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
            git checkout -B "$branch" "origin/$branch"
        else
            echo "Remote branch 'origin/$branch' not found. Skipping '$repo_name' build."
            return 1
        fi
    ) || { echo "Failed to checkout branch '$branch' for '$repo_name'."; return 1; }
    echo "Repo '$repo_name' prepared successfully on branch '$branch'."
    return 0
}

# Helper function for parallel execution.
# This function is exported so 'parallel' can use it.
# Arguments:
#    $1: repo_name
#    $2: script_path
#    $3: log_file
#    $4: tracker_file
#    $5: base_dir_for_build_script
#    $6...: Additional arguments for the build script
build_and_log_repo() {
    local repo_name="$1"
    local script_path="$2"
    local log_file="$3"
    local tracker_file="$4"
    local base_dir_for_build_script="$5"
    shift 5

    local script_output
    local script_exit_code

    echo "$(date +'%Y-%m-%d %H:%M:%S') --- Build started for $repo_name ---" >> "${log_file}"

    set +e
    if script_output=$("${script_path}" "$@" "$base_dir_for_build_script" 2>&1); then
        script_exit_code=0
    else
        script_exit_code=$?
    fi
    set -e

    echo "$script_output" | while IFS= read -r line; do
        echo "$(date +'%Y-%m-%d %H:%M:%M') $line"
    done >> "${log_file}"

    local status="FAIL"
    if [[ "$script_exit_code" -eq 0 ]]; then
        status="SUCCESS"
    fi
    echo "${repo_name},${status},${log_file}" >> "${tracker_file}"

    echo "$(date +'%Y-%m-%d %H:%M:%S') --- Build finished for $repo_name with status: $status ---" >> "${log_file}"
}
export -f build_and_log_repo

# ==============================================================================
# MAIN SCRIPT EXECUTION
# ==============================================================================

# Load previous configuration at script start
load_config

# Record the script start time
readonly START_TIME=$(date +"%Y-%m-%d %H:%M:%S")

# Prompt to run required-setup.sh
if [[ -f "$REQUIRED_SETUP_SCRIPT" ]]; then
    read -rp "Do you want to run '$REQUIRED_SETUP_SCRIPT' to ensure all tools are set up? (y/N): " RUN_SETUP
    if [[ "${RUN_SETUP,,}" == "y" ]]; then
        echo "Running $REQUIRED_SETUP_SCRIPT..."
        "$REQUIRED_SETUP_SCRIPT"
        echo "required-setup.sh completed."
    else
        echo "Skipping required-setup.sh. Please ensure your environment is set up correctly."
    fi
fi

# === Prompt for Base Directory ===
readonly DEFAULT_BASE_INPUT="${BASE_INPUT:-"deployments"}"
read -rp "Enter base directory for cloning/building/logs (relative to ~) [default: $DEFAULT_BASE_INPUT]: " USER_BASE_INPUT
readonly BASE_INPUT="${USER_BASE_INPUT:-$DEFAULT_BASE_INPUT}"
readonly BASE_DIR="$HOME/$BASE_INPUT"
readonly DATE_TAG=$(date +"%Y%m%d_%H%M%S")

# === Paths Based on User Input ===
readonly CLONE_DIR="$BASE_DIR/repos"
readonly LOG_DIR="$BASE_DIR/automationlogs"
readonly TRACKER_FILE="$LOG_DIR/build-tracker-${DATE_TAG}.csv"

# Create necessary directories
mkdir -p "$CLONE_DIR" "$LOG_DIR"

# === Repo Configurations ===
declare -A REPO_URLS=(
    ["spriced-ui"]="https://github.com/simaiserver/spriced-ui.git"
    ["spriced-cdbu-2.0.301"]="https://github.com/simaiserver/spriced-cdbu-2.0.301.git"
    ["spriced-platform-data-management-layer"]="https://github.com/simaiserver/spriced-platform-data-management-layer.git"
    ["spriced-platform-ib-ob"]="https://github.com/simaiserver/spriced-platform-ib-ob.git"
    ["spriced-pipeline"]="https://github.com/simaiserver/spriced-pipeline.git"
)

declare -A DEFAULT_BRANCHES=(
    ["spriced-ui"]="main"
    ["spriced-cdbu-2.0.301"]="main"
    ["spriced-platform-data-management-layer"]="main"
    ["spriced-platform-ib-ob"]="develop"
    ["spriced-pipeline"]="china_dbu_ui"
)

REPOS=(
    "spriced-cdbu-2.0.301"
    "spriced-ui"
    "spriced-platform-data-management-layer"
    "spriced-platform-ib-ob"
)

BUILD_SCRIPTS=(
    "$SCRIPT_DIR/build_spriced_cdbu_2.0.301.sh"
    "$SCRIPT_DIR/build_spriced_ui.sh"
    "$SCRIPT_DIR/build_spriced_platform_data_management_layer.sh"
    "$SCRIPT_DIR/build_spriced_platform_ib_ob.sh"
)

# === Display Repo Selection Menu ===
echo -e "\nAvailable Repositories:"
for i in "${!REPOS[@]}"; do
    printf "  %d) %s\n" "$((i+1))" "${REPOS[$i]}"
done
echo "  0) ALL"

DEFAULT_SELECTED_PROMPT="${SELECTED_REPO_NUMS[*]:-0}"
read -rp $'\nEnter repo numbers to build (space-separated or 0 for all) [default: '"$DEFAULT_SELECTED_PROMPT"']: ' -a USER_SELECTED_INPUT

if [[ -n "${USER_SELECTED_INPUT[*]}" ]]; then
    SELECTED_REPO_NUMS=("${USER_SELECTED_INPUT[@]}")
fi

if [[ "${SELECTED_REPO_NUMS[0]}" == "0" || "${SELECTED_REPO_NUMS[0],,}" == "all" ]]; then
    SELECTED_REPO_NUMS=($(seq 1 ${#REPOS[@]}))
fi

# === Phase 1: Git Operations and User Input Collection ===
declare -a COMMANDS=()
declare -A SELECTED_REPOS_MAP
UI_BUILD_ENV_CHOSEN="${BRANCH_CHOICES["spriced-ui-env"]:-}"

for repo_index_str in "${SELECTED_REPO_NUMS[@]}"; do
    if ! [[ "$repo_index_str" =~ ^[0-9]+$ ]] || (( repo_index_str < 1 || repo_index_str > ${#REPOS[@]} )); then
        echo "Invalid selection: $repo_index_str. Skipping..."
        continue
    fi
    repo_index=$((repo_index_str - 1))
    REPO_NAME="${REPOS[$repo_index]}"
    SELECTED_REPOS_MAP["$REPO_NAME"]=1

    # Get default branch from saved config or default map
    DEFAULT_BRANCH="${BRANCH_CHOICES[$REPO_NAME]:-${DEFAULT_BRANCHES[$REPO_NAME]}}"

    REPO_DIR="$CLONE_DIR/$REPO_NAME"

    # Handle spriced-ui with its special environment prompt
    if [[ "$REPO_NAME" == "spriced-ui" ]]; then
        readonly PIPELINE_DIR="$CLONE_DIR/spriced-pipeline"
        readonly PIPELINE_URL="${REPO_URLS["spriced-pipeline"]}"

        PIPELINE_BRANCH_COLLECTED="${DEFAULT_BRANCHES["spriced-pipeline"]}"
        BRANCH_CHOICES["spriced-pipeline"]="$PIPELINE_BRANCH_COLLECTED"

        if ! prepare_repo "spriced-pipeline" "$PIPELINE_URL" "$PIPELINE_DIR" "$PIPELINE_BRANCH_COLLECTED"; then
            echo "Failed to prepare spriced-pipeline. Skipping spriced-ui build."
            unset SELECTED_REPOS_MAP["$REPO_NAME"]; continue
        fi

        declare -a AVAILABLE_ENVS=()
        readonly PIPELINE_FRONTEND_DIR="$PIPELINE_DIR/framework/frontend"
        if [ ! -d "$PIPELINE_FRONTEND_DIR" ]; then
            echo "Directory not found: $PIPELINE_FRONTEND_DIR. Cannot determine environments."
            unset SELECTED_REPOS_MAP["$REPO_NAME"]; continue
        fi

        while IFS= read -r -d '' dir; do
            env_name=$(basename "$dir" | sed 's/china-//')
            AVAILABLE_ENVS+=("$env_name")
        done < <(find "$PIPELINE_FRONTEND_DIR" -maxdepth 1 -type d -name "china-*" -print0)

        echo -e "\nChoose environment for spriced-ui:"
        for env_idx in "${!AVAILABLE_ENVS[@]}"; do
            printf "  %d) %s\n" "$((env_idx+1))" "${AVAILABLE_ENVS[$env_idx]}"
        done
        echo "  $((${#AVAILABLE_ENVS[@]} + 1))) Create New..."

        DEFAULT_ENV_CHOICE=1
        if [[ -n "$UI_BUILD_ENV_CHOSEN" ]]; then
            for env_idx in "${!AVAILABLE_ENVS[@]}"; do
                if [[ "${AVAILABLE_ENVS[$env_idx]}" == "$UI_BUILD_ENV_CHOSEN" ]]; then
                    DEFAULT_ENV_CHOICE=$((env_idx+1))
                    break
                fi
            done
        fi

        while true; do
            read -rp "Enter environment number [default: $DEFAULT_ENV_CHOICE]: " ENV_NUM_INPUT
            ENV_NUM_CHOICE="${ENV_NUM_INPUT:-$DEFAULT_ENV_CHOICE}"

            # --- NEW LOGIC: Create New Environment ---
            if [[ "$ENV_NUM_CHOICE" =~ ^[0-9]+$ ]] && (( ENV_NUM_CHOICE == ${#AVAILABLE_ENVS[@]} + 1 )); then
                read -rp "Enter new environment name (e.g., prasanth): " NEW_ENV_NAME
                UI_BUILD_ENV_CHOSEN="$NEW_ENV_NAME"
                if [ -z "$UI_BUILD_ENV_CHOSEN" ]; then
                    echo "Environment name cannot be empty. Please try again."
                    continue
                fi

                # Hardcode SOURCE_ENV to "dev" as requested
                SOURCE_ENV="dev"

                readonly SOURCE_DIR="$PIPELINE_FRONTEND_DIR/china-$SOURCE_ENV"
                readonly NEW_ENV_DIR="$PIPELINE_FRONTEND_DIR/china-$UI_BUILD_ENV_CHOSEN"

                if [ -d "$NEW_ENV_DIR" ]; then
                    echo "Environment '$UI_BUILD_ENV_CHOSEN' already exists. Please choose a different name."
                    continue
                fi
                if [[ ! -d "$SOURCE_DIR" ]]; then
                    echo "Error: Source environment directory '$SOURCE_DIR' is missing. Cannot create new environment."
                    unset SELECTED_REPOS_MAP["$REPO_NAME"]; continue 2
                fi

                echo "Creating new environment directory: $NEW_ENV_DIR"
                cp -r "$SOURCE_DIR" "$NEW_ENV_DIR"
                echo "Initial .env files and manifest copied from '$SOURCE_ENV'."

                echo "Updating URLs in new environment files..."
                # The corrected sed command. It now ignores NX_KEY_CLOAK_URL lines.
                find "$NEW_ENV_DIR" -type f -name ".env" -exec sed -i -E "/NX_KEY_CLOAK_URL/!s/(https?:\/\/(cdbu-|reports\.cdbu-))?(dev|qa|uat|test|prasanth)(\.alpha)?\.simadvisory\.com/\1${NEW_ENV_NAME}\4.simadvisory.com/g" {} \;

                echo "  - Updated all .env files in '$NEW_ENV_DIR'."
                break

            elif [[ "$ENV_NUM_CHOICE" =~ ^[0-9]+$ ]] && (( ENV_NUM_CHOICE >= 1 && ENV_NUM_CHOICE <= ${#AVAILABLE_ENVS[@]} )); then
                UI_BUILD_ENV_CHOSEN="${AVAILABLE_ENVS[$((ENV_NUM_CHOICE-1))]}"
                break
            else
                echo "Invalid input. Please enter a valid number."
            fi
        done
        BRANCH_CHOICES["spriced-ui-env"]="$UI_BUILD_ENV_CHOSEN"
    fi

    # Prompt for branch name
    read -rp "Enter branch name for $REPO_NAME [default: $DEFAULT_BRANCH]: " USER_BRANCH_INPUT
    BRANCH_INPUT_COLLECTED="${USER_BRANCH_INPUT:-$DEFAULT_BRANCH}"
    BRANCH_CHOICES["$REPO_NAME"]="$BRANCH_INPUT_COLLECTED"

    # Prepare the repo and handle failures
    if ! prepare_repo "$REPO_NAME" "${REPO_URLS[$REPO_NAME]}" "$REPO_DIR" "$BRANCH_INPUT_COLLECTED"; then
        unset SELECTED_REPOS_MAP["$REPO_NAME"]
        continue
    fi

    # Add command for parallel execution
    LOG_FILE="$LOG_DIR/build-${REPO_NAME}-${DATE_TAG}.log"
    BUILD_SCRIPT_PATH="${BUILD_SCRIPTS[$repo_index]}"
    if [[ "$REPO_NAME" == "spriced-ui" ]]; then
        COMMANDS+=("build_and_log_repo \"$REPO_NAME\" \"$BUILD_SCRIPT_PATH\" \"$LOG_FILE\" \"$TRACKER_FILE\" \"$BASE_DIR\" \"$UI_BUILD_ENV_CHOSEN\" \"$BRANCH_INPUT_COLLECTED\"")
    else
        COMMANDS+=("build_and_log_repo \"$REPO_NAME\" \"$BUILD_SCRIPT_PATH\" \"$LOG_FILE\" \"$TRACKER_FILE\" \"$BASE_DIR\" \"$BRANCH_INPUT_COLLECTED\"")
    fi
done

# Save the configuration now that all inputs are collected
save_config

# --- Phase 2: Parallel Execution ---

CPU_CORES=$(nproc)
# Calculate max jobs = 80% of available cores (rounded up)
MAX_JOBS=$(( (CPU_CORES * 80 + 99) / 100 ))

echo -e "\n🚀 Running ${#COMMANDS[@]} builds in parallel, limited to ~80% of CPU capacity..."

if [ ${#COMMANDS[@]} -eq 0 ]; then
    echo "No parallel commands to execute. Exiting."
    exit 0
fi

set +e # Temporarily disable 'exit on error' for the parallel command
printf "%s\n" "${COMMANDS[@]}" | parallel -j "$MAX_JOBS" --load 80% --no-notice --bar
PARALLEL_EXIT_CODE=$?
set -e # Re-enable 'exit on error'
readonly END_TIME=$(date +"%Y-%m-%d %H:%M:%S")

# === Phase 3: Summary Output ===
echo -e "\nBuild Summary:\n"
readonly SUMMARY_CSV_FILE="$LOG_DIR/build-summary-${DATE_TAG}.csv"

if [[ -f "$TRACKER_FILE" ]]; then
    {
        echo "Script Start Time,$START_TIME"
        echo "Script End Time,$END_TIME"
        echo "---"
        echo "Status,Repository,Log File"
    } > "$SUMMARY_CSV_FILE"

    while IFS=',' read -r REPO STATUS LOGFILE; do
        if [[ "$STATUS" == "SUCCESS" ]]; then
            echo "[DONE] $REPO - see log: $LOGFILE"
        else
            echo "[FAIL] $REPO - see log: $LOGFILE"
        fi
        echo "$STATUS,$REPO,$LOGFILE" >> "$SUMMARY_CSV_FILE"
    done < "$TRACKER_FILE"
else
    echo "Build tracker not found: $TRACKER_FILE"
    echo "Script execution was likely interrupted. No summary was generated."
fi

echo "Detailed build summary also available at: $SUMMARY_CSV_FILE"
echo -e "\nScript execution complete."
exit "$PARALLEL_EXIT_CODE"
