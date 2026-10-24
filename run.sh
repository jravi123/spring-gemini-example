#!/bin/bash
# Exit immediately if a command exits with a non-zero status
set -e

# Force temporary directory to /tmp to avoid permission denied issues in restricted environments
export TMPDIR=/tmp

# Configuration
REGION="us-central1"
REPO_NAME="travel-agent-repo"
SERVICE_NAME="travel-agent-demo"
JAR_SOURCE="target/demo-0.0.1-SNAPSHOT.jar"

# Initialize flags
RUN_TESTS=true
RUN_SCANS=true
FORCE_REBUILD=false
PROJECT_ID_OVERRIDE=""

show_help() {
    echo "================================================================="
    echo "🤖 Personal Travel Agent - Cloud Run Build & Deploy Script"
    echo "================================================================="
    echo "Usage: ./run.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --project <id>     Deploy to a specific GCP Project ID (overrides gcloud config)"
    echo "  --skip-tests       Skip running JUnit unit tests during build"
    echo "  --skip-scans       Skip running SpotBugs SAST code analysis"
    echo "  --force, --rebuild Bypass all caches and force a full re-build / re-deploy"
    echo "  -f                 Short alias for --force"
    echo "  --help, -h         Display this reference and exit"
    echo ""
    echo "⚡ Smart Caching & Optimization Behavior (Subsequent Runs):"
    echo "  • GCP APIs & IAM: Skipped if already verified on the active project."
    echo "  • Container Build: Skipped automatically if the compiled JAR has not"
    echo "    changed and the image already exists in Artifact Registry."
    echo "  • Cloud Run Deploy: Skipped if neither the image nor env vars changed."
    echo "  • Project Switching: Setup cache automatically resets if you switch"
    echo "    to a different GCP project ID."
    echo ""
    echo "Examples:"
    echo "  ./run.sh                         # Build, test, scan, and deploy to active project"
    echo "  ./run.sh --project my-gcp-proj   # Deploy to a specific GCP project"
    echo "  ./run.sh --skip-tests            # Fast build & deploy without running tests"
    echo "  ./run.sh --force                 # Force complete re-build and re-deploy from scratch"
    echo "================================================================="
}

# --- Helper Functions ---
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

# --- Argument Parsing ---
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
        --skip-tests)
            RUN_TESTS=false
            ;;
        --skip-scans)
            RUN_SCANS=false
            ;;
        --force|--rebuild|-f)
            FORCE_REBUILD=true
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
echo " - Local Build (Tests: $RUN_TESTS, SpotBugs Scan: $RUN_SCANS)"
echo " - Cloud Run Service: $SERVICE_NAME ($REGION)"
[ "$FORCE_REBUILD" = true ] && echo " - Mode: Force Rebuild (Bypassing cache)"
echo "=================================================="
echo ""

# 1. Verify gcloud credentials and explicitly prompt for target project ID
CURRENT_GCLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null)

if [ -n "$PROJECT_ID_OVERRIDE" ]; then
    PROJECT_ID="$PROJECT_ID_OVERRIDE"
else
    echo "⚠️  Safety Check: Explicit GCP Project ID confirmation is required."
    if [ -n "$CURRENT_GCLOUD_PROJECT" ]; then
        echo "   Current gcloud default project is: $CURRENT_GCLOUD_PROJECT"
    else
        echo "   Current gcloud default project is: (none set)"
    fi
    read -p "👉 Please explicitly enter the target GCP Project ID to deploy to: " PROJECT_ID
    PROJECT_ID=$(echo "$PROJECT_ID" | xargs)
fi

if [ -z "$PROJECT_ID" ]; then
    echo "❌ Error: You must explicitly enter a GCP Project ID (blank input is not allowed to prevent accidental deployment to the default project)."
    exit 1
fi

gcloud config set project "$PROJECT_ID" >/dev/null 2>&1

ACTIVE_ACCOUNT=$(gcloud config get-value account 2>/dev/null)
echo "Deploying to GCP Project: $PROJECT_ID"
echo "Deployer Account:         $ACTIVE_ACCOUNT"
echo ""

# Configuration file path for caching project initialization and build states
CONFIG_FILE="$HOME/.travel_agent_demo_deploy.json"
APIS_INITIALIZED="false"
IAM_INITIALIZED="false"
INFRA_INITIALIZED="false"
LAST_DEPLOYED_PROJECT_ID=""
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
    'LAST_JAR_HASH': '$LAST_JAR_HASH',
    'LAST_ENV_HASH': '$LAST_ENV_HASH'
}
data.update(updates)

with open(config_path, 'w') as f:
    json.dump(data, f, indent=4)
" 2>/dev/null || true
}

if [ -f "$CONFIG_FILE" ]; then
    eval $(python3 -c "
import json, os
try:
    with open(os.path.expanduser('$CONFIG_FILE'), 'r') as f:
        config = json.load(f)
        for k, v in config.items():
            val = str(v).replace('\"', '\\\"') if v is not None else ''
            print(f'export {k}=\"{val}\"')
except Exception:
    pass
")
fi

# Invalidate cache if targeting a different project
if [ -n "$LAST_DEPLOYED_PROJECT_ID" ] && [ "$PROJECT_ID" != "$LAST_DEPLOYED_PROJECT_ID" ]; then
    echo "ℹ️  Different GCP Project detected ($PROJECT_ID vs previous $LAST_DEPLOYED_PROJECT_ID). Resetting project setup cache."
    APIS_INITIALIZED="false"
    IAM_INITIALIZED="false"
    INFRA_INITIALIZED="false"
    LAST_JAR_HASH=""
    LAST_ENV_HASH=""
fi

# Helper function to run a command with interactive retry/skip/abort on failure
run_step() {
    local step_name="$1"
    local command="$2"

    echo "⚙️  Running: $step_name..."

    local log_file=$(mktemp)
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
            2) return 0 ;;
            *) exit 1 ;;
        esac
    else
        echo "✅ Success!"
        rm -f "$log_file"
        echo ""
    fi
}

# --- Step 1: Build, Test, and Scan Locally ---
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
    echo "Error: Compiled JAR not found at $JAR_SOURCE"
    exit 1
fi

# --- Step 2: Enable Required Google Cloud APIs & Configure IAM ---
echo "=== Step 2: Google Cloud APIs & IAM Permissions ==="
if [ "$FORCE_REBUILD" = false ] && [ "$APIS_INITIALIZED" = "true" ] && [ "$PROJECT_ID" = "$LAST_DEPLOYED_PROJECT_ID" ]; then
    echo "⚡ Google Cloud APIs already enabled for $PROJECT_ID (use --force to re-verify)."
else
    run_step "Enable Google Cloud APIs" "gcloud services enable run.googleapis.com artifactregistry.googleapis.com aiplatform.googleapis.com cloudbuild.googleapis.com iam.googleapis.com logging.googleapis.com --project $PROJECT_ID"
    APIS_INITIALIZED="true"
    save_config_state
fi

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

if [ "$FORCE_REBUILD" = false ] && [ "$IAM_INITIALIZED" = "true" ] && [ "$PROJECT_ID" = "$LAST_DEPLOYED_PROJECT_ID" ]; then
    echo "⚡ IAM permissions already configured for $DEFAULT_SA (use --force to re-verify)."
else
    run_step "Verify Vertex AI / GenAI IAM Permissions" "gcloud projects add-iam-policy-binding $PROJECT_ID --member='serviceAccount:$DEFAULT_SA' --role='roles/aiplatform.user' --quiet && gcloud projects add-iam-policy-binding $PROJECT_ID --member='serviceAccount:$DEFAULT_SA' --role='roles/logging.logWriter' --quiet"
    IAM_INITIALIZED="true"
    save_config_state
fi

# --- Step 3: Build Container & Deploy to Cloud Run ---
echo "=== Step 3: Cloud Run Deployment ==="
if [ "$FORCE_REBUILD" = false ] && [ "$INFRA_INITIALIZED" = "true" ] && [ "$PROJECT_ID" = "$LAST_DEPLOYED_PROJECT_ID" ]; then
    echo "⚡ Artifact Registry repository ($REPO_NAME) already initialized."
else
    run_step "Create Artifact Registry Repository" "gcloud artifacts repositories create $REPO_NAME --repository-format=docker --location=$REGION --project=$PROJECT_ID || true"
    INFRA_INITIALIZED="true"
    save_config_state
fi

# Generate runtime environment configuration
ENV_YAML_FILE="/tmp/travel_agent_env.yaml"
rm -f "$ENV_YAML_FILE"
cat <<EOF > "$ENV_YAML_FILE"
GCP_PROJECT: "$PROJECT_ID"
GOOGLE_CLOUD_PROJECT: "$PROJECT_ID"
SPRING_AI_GOOGLE_GENAI_PROJECT_ID: "$PROJECT_ID"
SPRING_AI_GOOGLE_GENAI_LOCATION: "global"
SPRING_AI_GOOGLE_GENAI_MODEL: "gemini-2.5-flash"
GOOGLE_CLOUD_ENABLE_CLIENT_SIDE_METRICS: "false"
OTEL_SDK_DISABLED: "true"
OTEL_METRICS_EXPORTER: "none"
OTEL_TRACES_EXPORTER: "none"
OTEL_LOGS_EXPORTER: "none"
EOF

CURRENT_JAR_HASH=$(get_sha256 "$JAR_SOURCE")
CURRENT_ENV_HASH=$(get_sha256 "$ENV_YAML_FILE")
IMAGE_TAG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${SERVICE_NAME}:latest"

# Check if container image already exists in Artifact Registry
IMAGE_EXISTS=false
set +e
if gcloud artifacts docker images describe "$IMAGE_TAG" --project "$PROJECT_ID" --format='value(image_summary.digest)' >/dev/null 2>&1; then
    IMAGE_EXISTS=true
fi
set -e

NEED_CONTAINER_BUILD=true
if [ "$FORCE_REBUILD" = false ] && [ "$IMAGE_EXISTS" = true ] && [ -n "$CURRENT_JAR_HASH" ] && [ "$CURRENT_JAR_HASH" = "$LAST_JAR_HASH" ]; then
    NEED_CONTAINER_BUILD=false
fi

TEMP_BUILD_DIR=$(mktemp -d /tmp/.travel-build-XXXXXX)
if [ "$NEED_CONTAINER_BUILD" = true ]; then
    cp "$JAR_SOURCE" "$TEMP_BUILD_DIR/app.jar"
    cp "$ENV_YAML_FILE" "$TEMP_BUILD_DIR/env.yaml"
    cat <<EOF > "$TEMP_BUILD_DIR/Dockerfile"
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY app.jar app.jar
COPY env.yaml env.yaml
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

# Check if Cloud Run service is already active
SERVICE_ACTIVE=false
set +e
if gcloud run services describe "$SERVICE_NAME" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)' >/dev/null 2>&1; then
    SERVICE_ACTIVE=true
fi
set -e

NEED_RUN_DEPLOY=true
if [ "$FORCE_REBUILD" = false ] && [ "$NEED_CONTAINER_BUILD" = false ] && [ "$SERVICE_ACTIVE" = true ] && [ -n "$CURRENT_ENV_HASH" ] && [ "$CURRENT_ENV_HASH" = "$LAST_ENV_HASH" ]; then
    NEED_RUN_DEPLOY=false
fi

if [ "$NEED_RUN_DEPLOY" = true ]; then
    run_step "Deploy Service to Cloud Run" "gcloud run deploy $SERVICE_NAME --image $IMAGE_TAG --region $REGION --project $PROJECT_ID --allow-unauthenticated --env-vars-file $ENV_YAML_FILE --concurrency=60 --memory=1Gi --cpu=1 --min-instances=0 --max-instances=5 --timeout=300"
    LAST_ENV_HASH="$CURRENT_ENV_HASH"
    save_config_state
else
    echo "⚡ Cloud Run service ($SERVICE_NAME) is already active with up-to-date configuration. Skipping deployment."
fi

rm -rf "$TEMP_BUILD_DIR" "$ENV_YAML_FILE"

SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)' 2>/dev/null)

echo "=========================================="
echo "🎉 Deployment Process Completed! 🎉"
echo "=========================================="
echo "Project: $PROJECT_ID"
echo "Service: $SERVICE_NAME ($REGION)"
echo "URL:     $SERVICE_URL"
echo "=========================================="
