#!/usr/bin/env bash

set -euo pipefail

# Enable debug mode if DEBUG environment variable is set to true
if [[ "${DEBUG:-}" == "true" ]]; then
    set -x
fi

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"
}

# Function to set environment variables with defaults
set_variables() {
    log "Setting environment variables..."
    export PROJECT_ID="${PROJECT_ID:-javiercm-ge-tests}"
    export REGION="${REGION:-europe-west1}"
    export REPO_NAME="app-repo"
    export IMAGE_NAME="users-api"
    export IMAGE_TAG="latest"
    export FULL_IMAGE_NAME="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:${IMAGE_TAG}"
    
    # Required for ConfigMap templating
    export ZONE="${ZONE:-${REGION}-b}"
    export GSA_NAME="config-connector-gsa"
    export GSA_EMAIL="$GSA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

    # Database Password validation
    if [[ -z "${DB_PASSWORD:-}" ]]; then
        log "ERROR: DB_PASSWORD environment variable is not set."
        log "Please set it before running the script: export DB_PASSWORD='your-secure-password'"
        exit 1
    fi
}

# Function to enable required APIs for Cloud Run and Artifact Registry
enable_apis() {
    log "Enabling required APIs..."
    gcloud services enable \
        run.googleapis.com \
        artifactregistry.googleapis.com \
        --project "$PROJECT_ID"
}

# Function to generate the parameters ConfigMap
generate_params_cm() {
    log "Generating kcc/params-cm.yaml from template..."
    
    if command -v envsubst >/dev/null 2>&1; then
        envsubst < kcc/params-cm.yaml.template > kcc/params-cm.yaml
    else
        sed -e "s/\${PROJECT_ID}/$PROJECT_ID/g" \
            -e "s/\${REGION}/$REGION/g" \
            -e "s/\${ZONE}/$ZONE/g" \
            -e "s/\${GSA_EMAIL}/$GSA_EMAIL/g" \
            -e "s/\${REPO_NAME}/$REPO_NAME/g" \
            -e "s/\${FULL_IMAGE_NAME}/$FULL_IMAGE_NAME/g" \
            -e "s/\${DB_PASSWORD}/$DB_PASSWORD/g" \
            kcc/params-cm.yaml.template > kcc/params-cm.yaml
    fi
}

# Function to apply KCC app manifests using Kustomize
apply_app_kustomize() {
    generate_params_cm
    kubectl apply -k "kcc/app"
}

# Function to deploy Artifact Registry via KCC
deploy_repository_kcc() {
    log "Applying Artifact Registry manifest via Kustomize..."
    apply_app_kustomize

    log "Waiting for Artifact Registry repository '$REPO_NAME' to be ready..."
    kubectl wait --for=condition=Ready artifactregistryrepository/"$REPO_NAME" --timeout=120s
}

# Function to build and push the Docker image
build_and_push_image() {
    log "Configuring Docker to use Google Cloud CLI for authentication..."
    gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

    log "Building Docker image: $FULL_IMAGE_NAME..."
    docker build -t "$FULL_IMAGE_NAME" ./app

    log "Pushing Docker image: $FULL_IMAGE_NAME..."
    docker push "$FULL_IMAGE_NAME"
}

# Function to deploy the Cloud Run service via KCC
deploy_run_kcc() {
    log "Applying Cloud Run manifest via Kustomize..."
    apply_app_kustomize
}

# Function to wait for the Cloud Run service to be ready
wait_for_service() {
    log "Waiting for Cloud Run service 'users-api' to be ready (via KCC)..."
    kubectl wait --for=condition=Ready runservice/users-api --timeout=300s
    
    local url
    url=$(kubectl get runservice users-api -o jsonpath='{.status.url}')
    log "Cloud Run service is live at: $url"
}

# Main function to orchestrate the deployment
main() {
    set_variables
    enable_apis
    deploy_repository_kcc
    build_and_push_image
    deploy_run_kcc
    wait_for_service
    
    log "Deployment finished successfully!"
}

# Execute main function
main "$@"
