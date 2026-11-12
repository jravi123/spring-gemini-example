#!/bin/bash
# ==============================================================================
# Personal Travel Agent - Local API Setup & Google Cloud Run Deployment Script
# ==============================================================================
# What this script does:
#   1. Prompts you to pick a Google Cloud Project from a numbered list [1-N].
#   2. Syncs that Project ID into src/main/resources/application.properties.
#   3. Verifies Cloud Billing is enabled on the project (and links an active
#      billing account automatically if needed).
#   4. Enables the required Google Cloud APIs (Vertex AI, Datastore, Cloud Run, etc.).
#      - If you pass `--apis-only`, the script stops here so you can run locally
#        with `./mvnw spring-boot:run`.
#   5. Runs JUnit unit tests, SpotBugs security scans, and packages the Spring Boot JAR.
#   6. Grants IAM roles (Vertex AI, Cloud Datastore, Cloud Logging) to the Cloud Run
#      service account.
#   7. Builds a container image via Google Cloud Build and deploys it to Cloud Run.
# ==============================================================================

# Exit immediately if any untested command exits with a non-zero status
set -e

# Force temporary directory to /tmp to avoid permission issues in restricted shells
export TMPDIR=/tmp

# ==============================================================================
# SECTION 1: Configuration & Default Flags
# ==============================================================================
REGION="us-central1"
REPO_NAME="travel-agent-repo"
SERVICE_NAME="travel-agent-demo"
JAR_SOURCE="target/demo-0.0.1-SNAPSHOT.jar"
CONFIG_FILE="$HOME/.travel_agent_demo_deploy.json"

# Google Cloud APIs required by the application and deployment pipeline
REQUIRED_APIS=(
    "run.googleapis.com"               # Google Cloud Run (serverless container hosting)
    "artifactregistry.googleapis.com"  # Artifact Registry (stores built Docker images)
    "aiplatform.googleapis.com"        # Vertex AI (Gemini model inference)
    "datastore.googleapis.com"         # Cloud Datastore (NoSQL database for User entities)
    "cloudbuild.googleapis.com"        # Cloud Build (builds the Docker container in GCP)
    "iam.googleapis.com"               # Identity and Access Management (service account roles)
    "logging.googleapis.com"           # Cloud Logging (application logs)
)

# IAM roles required by the default Compute Engine / Cloud Run service account at runtime
REQUIRED_IAM_ROLES=(
    "roles/aiplatform.user"            # Allows calling Vertex AI Gemini models
    "roles/datastore.user"             # Allows reading/writing entities in Cloud Datastore
    "roles/logging.logWriter"          # Allows writing container logs to Cloud Logging
)

# Default CLI option flags (can be overridden via command-line arguments in Section 3)
RUN_TESTS=true
RUN_SCANS=true
FORCE_REBUILD=false
ENABLE_APIS_ONLY=false
PROJECT_ID_OVERRIDE=""
BILLING_ACCOUNT_OVERRIDE=""

# Temporary paths cleaned up automatically when the script exits
ENV_YAML_FILE=""
TEMP_BUILD_DIR=""
cleanup_temp_files() {
    rm -rf "$ENV_YAML_FILE" "$TEMP_BUILD_DIR" 2>/dev/null || true
}
trap cleanup_temp_files EXIT

# ==============================================================================
# SECTION 2: CLI Help & Utility Functions
# ==============================================================================

# Prints usage instructions when `--help` / `-h` is passed
show_help() {
    echo "================================================================="
    echo "🤖 Personal Travel Agent - Cloud Run Build & Deploy Script"
    echo "================================================================="
    echo "Usage: ./run.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --project <id>          Deploy to a specific GCP Project ID (skips interactive menu)"
    echo "  --billing-account <id>  Link a specific Cloud Billing Account ID if billing is disabled"
    echo "  --apis-only             Only enable required Google Cloud APIs and update application.properties"
    echo "  --skip-tests            Skip running JUnit unit tests during the Maven build"
    echo "  --skip-scans            Skip running SpotBugs SAST code analysis"
    echo "  --force, --rebuild      Bypass all caches and force a full rebuild and redeploy"
    echo "  -f                      Short alias for --force"
    echo "  --help, -h              Display this reference and exit"
    echo ""
    echo "⚡ Smart Caching Behavior (stored in ~/.travel_agent_demo_deploy.json):"
    echo "  • GCP APIs & IAM: Skipped if already enabled for the selected project."
    echo "  • Container Build: Skipped if the compiled JAR SHA-256 hash has not"
    echo "    changed and the container image already exists in Artifact Registry."
    echo "  • Cloud Run Deploy: Skipped if neither the image nor env vars changed."
    echo "  • Project Switching: Cache automatically resets when switching projects."
    echo ""
    echo "Examples:"
    echo "  ./run.sh                         # Pick project [1-N], build, test, scan, and deploy"
    echo "  ./run.sh --apis-only             # Pick project [1-N] and enable GCP APIs for local runs"
    echo "  ./run.sh --project my-gcp-proj   # Deploy directly to 'my-gcp-proj'"
    echo "  ./run.sh --skip-tests            # Fast build & deploy without running unit tests"
    echo "  ./run.sh --force                 # Force complete rebuild and redeploy from scratch"
    echo "================================================================="
}

# Computes the SHA-256 checksum of a file so we can detect whether the compiled
# JAR or environment variable configuration changed since the last deployment.
get_sha256() {
    local target_file="$1"
    if [ ! -f "$target_file" ]; then
        echo ""
        return
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$target_file" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$target_file" 2>/dev/null | awk '{print $1}'
    else
        python3 -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$target_file" 2>/dev/null
    fi
}

# Executes a shell command quietly, shows its log output only if an error occurs,
# and lets the user interactively Retry (1), Skip (2), or Abort (3) on failure.
LAST_STEP_SKIPPED=false
run_step() {
    local step_name="$1"
    local command="$2"
    LAST_STEP_SKIPPED=false

    echo "⚙️  Running: $step_name..."

    local log_file
    log_file=$(mktemp)
    set +e
    eval "$command" > "$log_file" 2>&1
    local exit_status=$?
    set -e

    if [ $exit_status -ne 0 ]; then
        echo "❌ Step failed! (Exit code: $exit_status)"
        echo "----------------------------------------"
        if [ -s "$log_file" ]; then cat "$log_file"; echo ""; fi
        echo "----------------------------------------"
        rm -f "$log_file"

        echo -e "\n1) Retry  2) Skip  3) Abort"
        read -p "Choice [1-3]: " fail_choice
        case $fail_choice in
            1) run_step "$step_name" "$command" ;;
            2) LAST_STEP_SKIPPED=true; return 0 ;;
            *) exit 1 ;;
        esac
    else
        echo "✅ Success!"
        rm -f "$log_file"
        echo ""
    fi
}

# ==============================================================================
# SECTION 3: Command-Line Argument Parsing
# ==============================================================================
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --project|-p)
            if [ -n "$2" ] && [[ "$2" != --* ]]; then
                PROJECT_ID_OVERRIDE="$2"
                shift
            else
                echo "Error: --project requires a non-empty project ID argument."
                exit 1
            fi
            ;;
        --billing-account|-b)
            if [ -n "$2" ] && [[ "$2" != --* ]]; then
                BILLING_ACCOUNT_OVERRIDE="${2#billingAccounts/}"
                shift
            else
                echo "Error: --billing-account requires a non-empty Billing Account ID."
                exit 1
            fi
            ;;
        --skip-tests)
            RUN_TESTS=false
            ;;
        --skip-scans)
            RUN_SCANS=false
            ;;
        --force|--rebuild|-f)
            FORCE_REBUILD=true
            ;;
        --apis-only)
            ENABLE_APIS_ONLY=true
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done

echo "=================================================="
echo "🤖 Personal Travel Agent - Cloud Run Deployer"
echo "=================================================="
echo "Execution Plan:"
if [ "$ENABLE_APIS_ONLY" = true ]; then
    echo " - Mode: Enable Required Google Cloud APIs Only (--apis-only)"
else
    echo " - Local Build (Tests: $RUN_TESTS, SpotBugs Scan: $RUN_SCANS)"
    echo " - Cloud Run Service: $SERVICE_NAME ($REGION)"
    [ "$FORCE_REBUILD" = true ] && echo " - Mode: Force Rebuild (Bypassing cache)"
fi
echo "=================================================="
echo ""

# ==============================================================================
# SECTION 4: Interactive GCP Project Selection & application.properties Sync
# ==============================================================================
# Fetches all active GCP projects accessible by your `gcloud` account and displays
# a numbered menu [1-N] (unless `--project <id>` was passed on the command line).
CURRENT_GCLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null)

if [ -n "$PROJECT_ID_OVERRIDE" ]; then
    PROJECT_ID="$PROJECT_ID_OVERRIDE"
else
    echo "🔍 Fetching available Google Cloud projects..."
    PROJECT_IDS=()
    PROJECT_NAMES=()
    while IFS=$'\t' read -r pid pname; do
        if [ -n "$pid" ]; then
            PROJECT_IDS+=("$pid")
            PROJECT_NAMES+=("$pname")
        fi
    done < <(gcloud projects list --filter="lifecycleState:ACTIVE" --format="value(projectId,name)" --sort-by=projectId 2>/dev/null)

    PROJECT_COUNT=${#PROJECT_IDS[@]}
    if [ "$PROJECT_COUNT" -eq 0 ]; then
        echo "⚠️  No projects returned by 'gcloud projects list'."
        read -p "👉 Please enter the target GCP Project ID manually: " PROJECT_ID
        PROJECT_ID=$(echo "$PROJECT_ID" | xargs)
    else
        echo ""
        echo "Available GCP Projects:"
        echo "--------------------------------------------------"
        for (( i=0; i<PROJECT_COUNT; i++ )); do
            idx=$((i + 1))
            marker=""
            if [ "${PROJECT_IDS[$i]}" = "$CURRENT_GCLOUD_PROJECT" ]; then
                marker=" [current]"
            fi
            printf "  %2d) %-32s (%s)%s\n" "$idx" "${PROJECT_IDS[$i]}" "${PROJECT_NAMES[$i]}" "$marker"
        done
        echo "--------------------------------------------------"
        read -p "👉 Select a project by number [1-$PROJECT_COUNT]: " PROJECT_CHOICE
        PROJECT_CHOICE=$(echo "$PROJECT_CHOICE" | xargs)

        if ! [[ "$PROJECT_CHOICE" =~ ^[0-9]+$ ]] || [ "$PROJECT_CHOICE" -lt 1 ] || [ "$PROJECT_CHOICE" -gt "$PROJECT_COUNT" ]; then
            echo "❌ Error: Invalid selection '$PROJECT_CHOICE'. Please enter a number between 1 and $PROJECT_COUNT."
            exit 1
        fi
        PROJECT_ID="${PROJECT_IDS[$((PROJECT_CHOICE - 1))]}"
    fi
fi

if [ -z "$PROJECT_ID" ]; then
    echo "❌ Error: No GCP Project ID selected."
    exit 1
fi

# Export the selected project ID across standard Google Cloud and Spring Boot
# environment variables so all child commands use the chosen project.
export PROJECT_ID
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
export GOOGLE_CLOUD_PROJECT="$PROJECT_ID"
export GCP_PROJECT="$PROJECT_ID"
export GCLOUD_PROJECT="$PROJECT_ID"
export DEVSHELL_PROJECT_ID="$PROJECT_ID"
export SPRING_CLOUD_GCP_PROJECT_ID="$PROJECT_ID"
export SPRING_CLOUD_GCP_DATASTORE_PROJECT_ID="$PROJECT_ID"
export SPRING_AI_GOOGLE_GENAI_PROJECT_ID="$PROJECT_ID"

gcloud config set project "$PROJECT_ID" >/dev/null 2>&1

# Update the fallback project ID inside src/main/resources/application.properties
# so running `./mvnw spring-boot:run` locally or packaging the JAR uses $PROJECT_ID.
APP_PROPS="src/main/resources/application.properties"
if [ -f "$APP_PROPS" ]; then
    python3 - "$APP_PROPS" "$PROJECT_ID" <<'PYEOF'
import re, sys

path, proj = sys.argv[1], sys.argv[2]
with open(path, 'r') as f:
    content = f.read()

genai_line = f"spring.ai.google.genai.project-id=${{SPRING_AI_GOOGLE_GENAI_PROJECT_ID:${{GOOGLE_CLOUD_PROJECT:${{GCP_PROJECT:${{DEVSHELL_PROJECT_ID:{proj}}}}}}}}}"
gcp_line = f"spring.cloud.gcp.project-id=${{GOOGLE_CLOUD_PROJECT:${{GCP_PROJECT:${{DEVSHELL_PROJECT_ID:${{SPRING_AI_GOOGLE_GENAI_PROJECT_ID:{proj}}}}}}}}}"
ds_line = f"spring.cloud.gcp.datastore.project-id=${{GOOGLE_CLOUD_PROJECT:${{GCP_PROJECT:${{DEVSHELL_PROJECT_ID:${{SPRING_AI_GOOGLE_GENAI_PROJECT_ID:{proj}}}}}}}}}"

content = re.sub(r'^spring\.ai\.google\.genai\.project-id=.*$', lambda _: genai_line, content, flags=re.MULTILINE)
content = re.sub(r'^spring\.cloud\.gcp\.project-id=.*$', lambda _: gcp_line, content, flags=re.MULTILINE)
content = re.sub(r'^spring\.cloud\.gcp\.datastore\.project-id=.*$', lambda _: ds_line, content, flags=re.MULTILINE)

with open(path, 'w') as f:
    f.write(content)
PYEOF
fi

ACTIVE_ACCOUNT=$(gcloud config get-value account 2>/dev/null)
echo "Target GCP Project: $PROJECT_ID"
echo "Active Account:     $ACTIVE_ACCOUNT"
echo ""

# ==============================================================================
# SECTION 5: Smart Deployment Cache (~/.travel_agent_demo_deploy.json)
# ==============================================================================
# Remembers whether APIs, IAM roles, and Artifact Registry have already been
# initialized for $PROJECT_ID, as well as the last deployed JAR & env hashes.
APIS_INITIALIZED="false"
IAM_INITIALIZED="false"
INFRA_INITIALIZED="false"
LAST_DEPLOYED_PROJECT_ID=""
LAST_ENABLED_APIS=""
LAST_IAM_ROLES=""
LAST_JAR_HASH=""
LAST_ENV_HASH=""

save_config_state() {
    python3 -c "
import json, os

config_path = os.path.expanduser('$CONFIG_FILE')
data = {}
if os.path.exists(config_path):
    try:
        with open(config_path, 'r') as f:
            data = json.load(f)
    except Exception:
        data = {}

updates = {
    'LAST_DEPLOYED_PROJECT_ID': '$PROJECT_ID',
    'APIS_INITIALIZED': '$APIS_INITIALIZED',
    'IAM_INITIALIZED': '$IAM_INITIALIZED',
    'INFRA_INITIALIZED': '$INFRA_INITIALIZED',
    'LAST_ENABLED_APIS': '$LAST_ENABLED_APIS',
    'LAST_IAM_ROLES': '$LAST_IAM_ROLES',
    'LAST_JAR_HASH': '$LAST_JAR_HASH',
    'LAST_ENV_HASH': '$LAST_ENV_HASH'
}
data.update(updates)

with open(config_path, 'w') as f:
    json.dump(data, f, indent=4)
" 2>/dev/null || true
}

# Load cached state from disk if it exists
if [ -f "$CONFIG_FILE" ]; then
    eval "$(python3 -c "
import json, os
try:
    with open(os.path.expanduser('$CONFIG_FILE'), 'r') as f:
        config = json.load(f)
        for k, v in config.items():
            val = str(v).replace('\"', '\\\"') if v is not None else ''
            print(f'export {k}=\"{val}\"')
except Exception:
    pass
")"
fi

# Reset cached flags if the user selected a different GCP project than last time
if [ -n "$LAST_DEPLOYED_PROJECT_ID" ] && [ "$PROJECT_ID" != "$LAST_DEPLOYED_PROJECT_ID" ]; then
    echo "ℹ️  Switched GCP Project ($PROJECT_ID vs previous $LAST_DEPLOYED_PROJECT_ID). Resetting setup cache."
    APIS_INITIALIZED="false"
    IAM_INITIALIZED="false"
    INFRA_INITIALIZED="false"
    LAST_ENABLED_APIS=""
    LAST_IAM_ROLES=""
    LAST_JAR_HASH=""
    LAST_ENV_HASH=""
fi

# ==============================================================================
# SECTION 6: Cloud Billing Verification & Google Cloud API Enablement
# ==============================================================================
# Ensures an active Cloud Billing account is linked to $PROJECT_ID before
# enabling billing-gated services (Cloud Run, Artifact Registry, Cloud Build).
BILLING_CHECKED=false
ensure_billing_enabled() {
    if [ "$BILLING_CHECKED" = true ]; then
        return 0
    fi
    BILLING_CHECKED=true

    local billing_cmd="gcloud billing"
    if ! gcloud billing --help >/dev/null 2>&1; then
        billing_cmd="gcloud beta billing"
    fi

    local billing_json=""
    local describe_ok=false
    if billing_json=$($billing_cmd projects describe "$PROJECT_ID" --format="json" 2>/dev/null); then
        describe_ok=true
    fi

    if [ "$describe_ok" = true ]; then
        local is_enabled
        is_enabled=$(BILLING_JSON="$billing_json" python3 -c '
import json, os
try:
    data = json.loads(os.environ.get("BILLING_JSON", "{}") or "{}")
    print("true" if data.get("billingEnabled") is True else "false")
except Exception:
    print("unknown")
')
        if [ "$is_enabled" = "true" ]; then
            echo "⚡ Cloud Billing is active for $PROJECT_ID."
            return 0
        fi
    else
        # If billing info cannot be read (e.g., restricted role on an already-billed shared project),
        # proceed unless an explicit --billing-account override was passed.
        if [ -z "$BILLING_ACCOUNT_OVERRIDE" ]; then
            return 0
        fi
    fi

    echo "⚠️  Cloud Billing is not enabled for project '$PROJECT_ID'."
    local selected_account="$BILLING_ACCOUNT_OVERRIDE"
    local selected_name=""

    if [ -z "$selected_account" ]; then
        echo "🔍 Checking available active Cloud Billing accounts..."
        local accounts_json="[]"
        accounts_json=$($billing_cmd accounts list --filter="open=true" --format="json" 2>/dev/null || echo "[]")

        local account_ids=()
        local account_names=()
        while IFS=$'\t' read -r aid aname; do
            if [ -n "$aid" ]; then
                account_ids+=("$aid")
                account_names+=("$aname")
            fi
        done < <(ACCOUNTS_JSON="$accounts_json" python3 -c '
import json, os
try:
    items = json.loads(os.environ.get("ACCOUNTS_JSON", "[]") or "[]")
    for item in items:
        if item.get("open") is False:
            continue
        raw_name = str(item.get("name", "")).strip()
        aid = raw_name.split("/")[-1] if raw_name else ""
        dname = str(item.get("displayName", "Billing Account")).replace("\t", " ").strip()
        if aid:
            print(f"{aid}\t{dname}")
except Exception:
    pass
')

        local account_count=${#account_ids[@]}
        if [ "$account_count" -eq 1 ]; then
            selected_account="${account_ids[0]}"
            selected_name="${account_names[0]}"
            echo "💳 Found active billing account: $selected_name ($selected_account)"
        elif [ "$account_count" -gt 1 ]; then
            echo ""
            echo "Available Active Cloud Billing Accounts:"
            echo "--------------------------------------------------"
            for (( i=0; i<account_count; i++ )); do
                idx=$((i + 1))
                printf "  %2d) %-24s (%s)\n" "$idx" "${account_ids[$i]}" "${account_names[$i]}"
            done
            echo "--------------------------------------------------"
            read -p "👉 Select a billing account to link to '$PROJECT_ID' [1-$account_count]: " billing_choice
            billing_choice=$(echo "$billing_choice" | xargs)
            if ! [[ "$billing_choice" =~ ^[0-9]+$ ]] || [ "$billing_choice" -lt 1 ] || [ "$billing_choice" -gt "$account_count" ]; then
                echo "❌ Error: Invalid selection '$billing_choice'. Please enter a number between 1 and $account_count."
                exit 1
            fi
            selected_account="${account_ids[$((billing_choice - 1))]}"
            selected_name="${account_names[$((billing_choice - 1))]}"
        else
            echo "⚠️  No active Cloud Billing accounts were found automatically."
            echo "   You can create or view your billing account at:"
            echo "     https://console.cloud.google.com/billing"
            echo "   Or link one directly in the Console for '$PROJECT_ID' at:"
            echo "     https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
            echo ""
            read -p "👉 Enter a Billing Account ID (e.g. 012345-6789AB-CDEF01), or press Enter if you just linked it in the browser: " manual_account
            selected_account=$(echo "$manual_account" | xargs)
            selected_account="${selected_account#billingAccounts/}"
        fi
    fi

    if [ -n "$selected_account" ]; then
        local label="$selected_account"
        if [ -n "$selected_name" ]; then
            label="$selected_name ($selected_account)"
        fi
        run_step "Link Cloud Billing Account ($label) to $PROJECT_ID" "$billing_cmd projects link '$PROJECT_ID' --billing-account='$selected_account' --quiet"
        if [ "$LAST_STEP_SKIPPED" = false ]; then
            # Brief pause so Service Usage recognizes the newly linked billing account
            sleep 2
        fi
    else
        local recheck_json=""
        recheck_json=$($billing_cmd projects describe "$PROJECT_ID" --format="json" 2>/dev/null || echo "{}")
        local now_enabled
        now_enabled=$(BILLING_JSON="$recheck_json" python3 -c '
import json, os
try:
    data = json.loads(os.environ.get("BILLING_JSON", "{}") or "{}")
    print("true" if data.get("billingEnabled") is True else "false")
except Exception:
    print("false")
')
        if [ "$now_enabled" != "true" ]; then
            echo "❌ Error: Cloud Billing is still not enabled for '$PROJECT_ID'. Billing is required to activate Cloud Run, Artifact Registry, and Cloud Build APIs."
            exit 1
        fi
        echo "✅ Confirmed Cloud Billing is now active for $PROJECT_ID!"
        echo ""
    fi
}

# Verify billing upfront when setting up a new/switched project so any prompt happens immediately
if [ "$APIS_INITIALIZED" != "true" ] || [ "$FORCE_REBUILD" = true ] || [ -n "$BILLING_ACCOUNT_OVERRIDE" ]; then
    ensure_billing_enabled
fi

# Verifies every service in REQUIRED_APIS (including datastore.googleapis.com)
# against the live project and enables any missing APIs automatically, even if
# an older cache entry exists in ~/.travel_agent_demo_deploy.json.
enable_required_apis() {
    local required_apis_str="${REQUIRED_APIS[*]}"

    if [ "$FORCE_REBUILD" = true ]; then
        ensure_billing_enabled
        run_step "Enable Google Cloud APIs" "gcloud services enable ${REQUIRED_APIS[*]} --project=$PROJECT_ID --quiet"
        if [ "$LAST_STEP_SKIPPED" = false ]; then
            APIS_INITIALIZED="true"
            LAST_ENABLED_APIS="$required_apis_str"
            save_config_state
        fi
        return
    fi

    local enabled_apis
    if ! enabled_apis=$(gcloud services list --enabled --project="$PROJECT_ID" --format="value(config.name)" --quiet 2>/dev/null); then
        # Fallback if listing enabled services fails: attempt to enable all required APIs directly
        ensure_billing_enabled
        run_step "Enable Google Cloud APIs" "gcloud services enable ${REQUIRED_APIS[*]} --project=$PROJECT_ID --quiet"
        if [ "$LAST_STEP_SKIPPED" = false ]; then
            APIS_INITIALIZED="true"
            LAST_ENABLED_APIS="$required_apis_str"
            save_config_state
        fi
        return
    fi

    local missing_apis=()
    for api in "${REQUIRED_APIS[@]}"; do
        if ! printf '%s\n' "$enabled_apis" | grep -Fxq "$api"; then
            missing_apis+=("$api")
        fi
    done

    if [ "${#missing_apis[@]}" -eq 0 ]; then
        echo "⚡ All required Google Cloud APIs (including datastore.googleapis.com) are enabled for $PROJECT_ID."
        if [ "$APIS_INITIALIZED" != "true" ] || [ "$LAST_ENABLED_APIS" != "$required_apis_str" ]; then
            APIS_INITIALIZED="true"
            LAST_ENABLED_APIS="$required_apis_str"
            save_config_state
        fi
    else
        echo "ℹ️  Missing required API(s) on $PROJECT_ID: ${missing_apis[*]}"
        ensure_billing_enabled
        run_step "Enable Missing Google Cloud APIs (${missing_apis[*]})" "gcloud services enable ${missing_apis[*]} --project=$PROJECT_ID --quiet"
        if [ "$LAST_STEP_SKIPPED" = false ]; then
            APIS_INITIALIZED="true"
            LAST_ENABLED_APIS="$required_apis_str"
            save_config_state
        fi
    fi
}

# If the user ran `./run.sh --apis-only` (for local development), enable APIs and exit now
if [ "$ENABLE_APIS_ONLY" = true ]; then
    echo "=== Enabling Required Google Cloud APIs for $PROJECT_ID ==="
    enable_required_apis
    echo "=========================================="
    echo "🎉 Google Cloud APIs Ready for $PROJECT_ID! 🎉"
    echo "=========================================="
    exit 0
fi

# ==============================================================================
# SECTION 7: Step 1 — Local Java Build, JUnit Tests & SpotBugs Security Scan
# ==============================================================================
echo "=== Step 1: Building Java Application ==="
MVN_CMD="./mvnw"
if [ ! -x "$MVN_CMD" ]; then
    MVN_CMD="mvn"
fi

if [ "$RUN_TESTS" = true ]; then
    run_step "Run JUnit Tests" "$MVN_CMD clean test"
else
    echo "⚠️  Skipping unit tests (--skip-tests active)"
    echo ""
fi

if [ "$RUN_SCANS" = true ]; then
    run_step "Run SpotBugs SAST Code Analysis" "$MVN_CMD compile spotbugs:check"
else
    echo "⚠️  Skipping SpotBugs security scan (--skip-scans active)"
    echo ""
fi

run_step "Package Application JAR" "$MVN_CMD package -DskipTests"

if [ ! -f "$JAR_SOURCE" ]; then
    echo "❌ Error: Compiled JAR not found at $JAR_SOURCE"
    exit 1
fi

# ==============================================================================
# SECTION 8: Step 2 — Google Cloud APIs & Service Account IAM Permissions
# ==============================================================================
echo "=== Step 2: Google Cloud APIs & IAM Permissions ==="
enable_required_apis

# Look up the default Compute Engine service account used by Cloud Run
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

CURRENT_IAM_ROLES="${REQUIRED_IAM_ROLES[*]}"
if [ "$FORCE_REBUILD" = false ] && [ "$IAM_INITIALIZED" = "true" ] && [ "$PROJECT_ID" = "$LAST_DEPLOYED_PROJECT_ID" ] && [ "$LAST_IAM_ROLES" = "$CURRENT_IAM_ROLES" ]; then
    echo "⚡ IAM permissions already configured for $DEFAULT_SA (use --force to re-verify)."
else
    # Build the IAM binding command for all roles in REQUIRED_IAM_ROLES
    IAM_CMD=""
    for role in "${REQUIRED_IAM_ROLES[@]}"; do
        if [ -n "$IAM_CMD" ]; then
            IAM_CMD="$IAM_CMD && "
        fi
        IAM_CMD="${IAM_CMD}gcloud projects add-iam-policy-binding $PROJECT_ID --member='serviceAccount:$DEFAULT_SA' --role='$role' --quiet"
    done
    run_step "Grant Vertex AI, Datastore & Logging IAM Roles" "$IAM_CMD"
    if [ "$LAST_STEP_SKIPPED" = false ]; then
        IAM_INITIALIZED="true"
        LAST_IAM_ROLES="$CURRENT_IAM_ROLES"
        save_config_state
    fi
fi

# ==============================================================================
# SECTION 9: Step 3A — Container Image Build (Artifact Registry & Cloud Build)
# ==============================================================================
echo "=== Step 3: Cloud Run Deployment ==="

# 1. Ensure the Docker repository exists in Artifact Registry
if [ "$FORCE_REBUILD" = false ] && [ "$INFRA_INITIALIZED" = "true" ] && [ "$PROJECT_ID" = "$LAST_DEPLOYED_PROJECT_ID" ]; then
    echo "⚡ Artifact Registry repository ($REPO_NAME) already initialized."
else
    run_step "Create Artifact Registry Repository" "gcloud artifacts repositories create $REPO_NAME --repository-format=docker --location=$REGION --project=$PROJECT_ID || true"
    INFRA_INITIALIZED="true"
    save_config_state
fi

# 2. Generate runtime environment variables file for the Cloud Run service
ENV_YAML_FILE="/tmp/travel_agent_env.yaml"
cat <<EOF > "$ENV_YAML_FILE"
GCP_PROJECT: "$PROJECT_ID"
GOOGLE_CLOUD_PROJECT: "$PROJECT_ID"
SPRING_CLOUD_GCP_PROJECT_ID: "$PROJECT_ID"
SPRING_CLOUD_GCP_DATASTORE_PROJECT_ID: "$PROJECT_ID"
SPRING_AI_GOOGLE_GENAI_PROJECT_ID: "$PROJECT_ID"
SPRING_AI_GOOGLE_GENAI_LOCATION: "global"
SPRING_AI_GOOGLE_GENAI_MODEL: "gemini-3.8-flash"
GOOGLE_CLOUD_ENABLE_CLIENT_SIDE_METRICS: "false"
OTEL_SDK_DISABLED: "true"
OTEL_METRICS_EXPORTER: "none"
OTEL_TRACES_EXPORTER: "none"
OTEL_LOGS_EXPORTER: "none"
EOF

CURRENT_JAR_HASH=$(get_sha256 "$JAR_SOURCE")
CURRENT_ENV_HASH=$(get_sha256 "$ENV_YAML_FILE")
IMAGE_TAG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${SERVICE_NAME}:latest"

# 3. Check if the container image already exists in Artifact Registry and whether
#    the local JAR changed since the last build.
IMAGE_EXISTS=false
if gcloud artifacts docker images describe "$IMAGE_TAG" --project "$PROJECT_ID" --format='value(image_summary.digest)' >/dev/null 2>&1; then
    IMAGE_EXISTS=true
fi

NEED_CONTAINER_BUILD=true
if [ "$FORCE_REBUILD" = false ] && [ "$IMAGE_EXISTS" = true ] && [ -n "$CURRENT_JAR_HASH" ] && [ "$CURRENT_JAR_HASH" = "$LAST_JAR_HASH" ]; then
    NEED_CONTAINER_BUILD=false
fi

if [ "$NEED_CONTAINER_BUILD" = true ]; then
    TEMP_BUILD_DIR=$(mktemp -d /tmp/.travel-build-XXXXXX)
    cp "$JAR_SOURCE" "$TEMP_BUILD_DIR/app.jar"
    cat <<EOF > "$TEMP_BUILD_DIR/Dockerfile"
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY app.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "--enable-native-access=ALL-UNNAMED", "-XX:+UseContainerSupport", "-XX:MaxRAMPercentage=75.0", "-jar", "app.jar"]
EOF
    run_step "Ensure Cloud Build Staging Bucket" "gcloud storage buckets create gs://${PROJECT_ID}_cloudbuild --location=$REGION --project=$PROJECT_ID || true"
    run_step "Build Container Image via Cloud Build" "(cd $TEMP_BUILD_DIR && gcloud builds submit . --tag $IMAGE_TAG --project $PROJECT_ID)"
    LAST_JAR_HASH="$CURRENT_JAR_HASH"
    save_config_state
else
    echo "⚡ Application JAR and container image are unchanged."
    echo "   ⏩ Skipping Cloud Build container build (use --force to rebuild)."
fi

# ==============================================================================
# SECTION 10: Step 3B — Cloud Run Service Deployment & URL Output
# ==============================================================================
# Check if the Cloud Run service is already active and whether the image or
# environment variables changed since the last deployment.
SERVICE_ACTIVE=false
if gcloud run services describe "$SERVICE_NAME" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)' >/dev/null 2>&1; then
    SERVICE_ACTIVE=true
fi

NEED_RUN_DEPLOY=true
if [ "$FORCE_REBUILD" = false ] && [ "$NEED_CONTAINER_BUILD" = false ] && [ "$SERVICE_ACTIVE" = true ] && [ -n "$CURRENT_ENV_HASH" ] && [ "$CURRENT_ENV_HASH" = "$LAST_ENV_HASH" ]; then
    NEED_RUN_DEPLOY=false
fi

if [ "$NEED_RUN_DEPLOY" = true ]; then
    DEPLOY_CMD="gcloud run deploy $SERVICE_NAME \
        --image $IMAGE_TAG \
        --region $REGION \
        --project $PROJECT_ID \
        --allow-unauthenticated \
        --env-vars-file $ENV_YAML_FILE \
        --concurrency=60 \
        --memory=1Gi \
        --cpu=1 \
        --min-instances=0 \
        --max-instances=5 \
        --timeout=300"
    run_step "Deploy Service to Cloud Run" "$DEPLOY_CMD"
    LAST_ENV_HASH="$CURRENT_ENV_HASH"
    save_config_state
else
    echo "⚡ Cloud Run service ($SERVICE_NAME) is already active with up-to-date configuration. Skipping deployment."
fi

SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)' 2>/dev/null)

echo "=========================================="
echo "🎉 Deployment Process Completed! 🎉"
echo "=========================================="
echo "Project: $PROJECT_ID"
echo "Service: $SERVICE_NAME ($REGION)"
echo "URL:     $SERVICE_URL"
echo "=========================================="
