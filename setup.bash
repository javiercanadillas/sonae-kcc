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
    export ZONE="${ZONE:-${REGION}-b}"
    export CLUSTER_NAME="${CLUSTER_NAME:-cc-cluster}"
    export GSA_NAME="config-connector-gsa"
    export GSA_EMAIL="$GSA_NAME@$PROJECT_ID.iam.gserviceaccount.com"
    
    # App-specific metadata for KCC
    export REPO_NAME="app-repo"
    export IMAGE_NAME="users-api"
    export IMAGE_TAG="latest"
    export FULL_IMAGE_NAME="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:${IMAGE_TAG}"

    # Database Password validation
    if [[ -z "${DB_PASSWORD:-}" ]]; then
        log "ERROR: DB_PASSWORD environment variable is not set."
        log "Please set it before running the script: export DB_PASSWORD='your-secure-password'"
        exit 1
    fi
}

# Function to set the gcloud project
set_gcloud_project() {
    log "Configuring gcloud project to $PROJECT_ID..."
    gcloud config set project "$PROJECT_ID"
}

# Function to enable required GCP APIs idempotently
set_gcp_apis() {
    log "Enabling GCP APIs..."
    local apis=(
        "compute.googleapis.com"
        "container.googleapis.com"
        "iam.googleapis.com"
        "sqladmin.googleapis.com"
    )
    gcloud services enable "${apis[@]}"
}

# Function to create the GKE cluster if it doesn't already exist
create_gke_cluster() {
    if gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" >/dev/null 2>&1; then
        log "Cluster $CLUSTER_NAME already exists. Skipping creation."
    else
        log "Creating GKE cluster $CLUSTER_NAME..."
        gcloud container clusters create "$CLUSTER_NAME" \
            --zone "$ZONE" \
            --workload-pool="$PROJECT_ID.svc.id.goog" \
            --logging=SYSTEM,WORKLOAD \
            --monitoring=SYSTEM \
            --num-nodes=3
    fi
    
    log "Getting credentials for $CLUSTER_NAME..."
    gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE"
}

# Function to install the KCC operator
install_kcc_operator() {
    log "Installing KCC operator..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    pushd "$tmp_dir" > /dev/null
    gsutil cp "gs://configconnector-operator/latest/release-bundle.tar.gz" . || { log "Failed to download KCC bundle"; return 1; }
    tar -xzf release-bundle.tar.gz

    local operator_file="operator-system/configconnector-operator.yaml"
    if [[ -f "$operator_file" ]]; then
        kubectl apply -f "$operator_file"
    else
        log "Error: Operator file not found in bundle."
        return 1
    fi
    popd > /dev/null
}

# Function to create the GSA and set up Workload Identity
create_gsa() {
    if gcloud iam service-accounts describe "$GSA_EMAIL" >/dev/null 2>&1; then
        log "Service account $GSA_EMAIL already exists. Skipping creation."
    else
        log "Creating Google Service Account: $GSA_NAME..."
        gcloud iam service-accounts create "$GSA_NAME" --display-name="Config Connector GSA"
    fi

    log "Ensuring permissions for $GSA_NAME..."
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$GSA_EMAIL" \
        --role="roles/editor" \
        --condition=None > /dev/null

    log "Binding GSA to KSA via Workload Identity..."
    gcloud iam service-accounts add-iam-policy-binding "$GSA_EMAIL" \
        --member="serviceAccount:$PROJECT_ID.svc.id.goog[cnrm-system/cnrm-controller-manager]" \
        --role="roles/iam.workloadIdentityUser" \
        --condition=None > /dev/null
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

# Function to apply KCC manifests using Kustomize
apply_kcc_kustomize() {
    local kustomize_path="$1"
    generate_params_cm
    kubectl apply -k "$kustomize_path"
}

# Function to apply the ConfigConnector configuration
apply_kcc_config() {
    log "Waiting for KCC operator to be ready..."
    kubectl wait -n operator-system --for=condition=Available deployment/configconnector-operator-controller-manager --timeout=60s

    log "Applying ConfigConnector resource via Kustomize..."
    apply_kcc_kustomize "kcc/infra"
}

# Function to create demo resources via KCC
create_demo_resources() {
    log "Ensuring demo resources are applied (SQL and VM)..."
    apply_kcc_kustomize "kcc/infra"
}

# Function to seed the database with Edgar Allan Poe characters using SQL
seed_database_sql() {
    log "Waiting for SQL instance 'test-sql-cc' to be ready..."
    kubectl wait --for=condition=Ready sqlinstance/test-sql-cc --timeout=600s

    log "Seeding database with Edgar Allan Poe characters..."
    
    local seed_sql="
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    first_name VARCHAR(255),
    last_name VARCHAR(255)
);

INSERT INTO users (email, first_name, last_name) VALUES
('c.auguste.dupin@poe.com', 'C. Auguste', 'Dupin'),
('roderick.usher@poe.com', 'Roderick', 'Usher'),
('madeline.usher@poe.com', 'Madeline', 'Usher'),
('arthur.pym@poe.com', 'Arthur', 'Gordon Pym'),
('william.legrand@poe.com', 'William', 'Legrand'),
('ligeia@poe.com', 'Ligeia', 'Rowena'),
('prince.prospero@poe.com', 'Prince', 'Prospero'),
('berenice@poe.com', 'Berenice', 'Egaeus'),
('morella@poe.com', 'Morella', 'Unnamed'),
('jupiter.bug@poe.com', 'Jupiter', 'Gold-Bug')
ON CONFLICT (email) DO NOTHING;
"

    # Use gcloud sql connect to execute the SQL. 
    # Note: Requires local psql client installed.
    printf "%s" "$seed_sql" | gcloud sql connect test-sql-cc --user=postgres --quiet --project="$PROJECT_ID"
}

# Function to install the Config Connector CLI tool (config-connector)
install_config_connector_cli() {
    if command -v config-connector &> /dev/null; then
        log "Config Connector CLI already installed. Skipping."
        return 0
    fi

    log "Installing Config Connector CLI..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    pushd "$tmp_dir" > /dev/null
    log "Downloading KCC CLI bundle..."
    gsutil cp "gs://cnrm/latest/cli.tar.gz" . || { log "Failed to download KCC CLI bundle"; return 1; }
    tar -xzf cli.tar.gz

    local os_type
    os_type=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch
    arch=$(uname -m)

    # Map architecture names for the bundle structure
    case "$arch" in
        x86_64) arch="amd64" ;;
        arm64) arch="arm64" ;;
    esac

    local binary_path="${os_type}/${arch}/config-connector"
    
    # Fallback for Mac ARM if arm64 folder doesn't exist (assuming amd64 + Rosetta)
    if [[ "$os_type" == "darwin" && "$arch" == "arm64" && ! -f "$binary_path" ]]; then
       log "ARM64 binary not found, falling back to AMD64 (requires Rosetta 2 on macOS)..."
       binary_path="darwin/amd64/config-connector"
    fi

    if [[ -f "$binary_path" ]]; then
        log "Installing config-connector binary to /usr/local/bin..."
        # Note: This may prompt for sudo password
        if sudo cp "$binary_path" /usr/local/bin/config-connector; then
            sudo chmod +x /usr/local/bin/config-connector
            log "Config Connector CLI installed successfully."
        else
            log "Failed to install binary to /usr/local/bin. Please install it manually from $tmp_dir/$binary_path"
            return 1
        fi
    else
        log "Error: Config Connector CLI binary not found for ${os_type}/${arch} in downloaded bundle."
        return 1
    fi
    popd > /dev/null
}

# Function to delete resources created by the script
destroy_resources() {
    log "Starting cleanup..."
    
    # Try to delete demo resources if kubectl is configured
    if kubectl cluster-info >/dev/null 2>&1; then
        log "Deleting demo resources via KCC..."
        kubectl delete SQLInstance test-sql-cc --ignore-not-found=true
        kubectl delete ComputeInstance test-vm-cc --ignore-not-found=true
    else
        log "Kubectl not configured or cluster unreachable. Skipping demo resource deletion."
    fi

    if gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" >/dev/null 2>&1; then
        log "Deleting GKE cluster $CLUSTER_NAME..."
        gcloud container clusters delete "$CLUSTER_NAME" --zone "$ZONE" --quiet
    else
        log "Cluster $CLUSTER_NAME does not exist. Skipping cluster deletion."
    fi

    if gcloud iam service-accounts describe "$GSA_EMAIL" >/dev/null 2>&1; then
        log "Deleting GSA $GSA_NAME..."
        gcloud iam service-accounts delete "$GSA_EMAIL" --quiet
    else
        log "GSA $GSA_NAME does not exist."
    fi

    log "Cleanup complete."
}

# Function to run the full installation
install() {
    set_variables
    set_gcloud_project
    set_gcp_apis
    create_gke_cluster
    install_kcc_operator
    install_config_connector_cli
    create_gsa
    apply_kcc_config
    create_demo_resources
    seed_database_sql
}

# Function to display usage information
usage() {
    echo "Usage: $0 {install|destroy}"
    exit 1
}

# Main function to orchestrate the setup
main() {
    if [[ $# -lt 1 ]]; then
        usage
    fi

    local action="$1"
    set_variables

    case "$action" in
        install)
            install
            log "Setup complete! Resources are being provisioned by Config Connector."
            ;;
        destroy)
            destroy_resources
            ;;
        *)
            usage
            ;;
    esac
}

# Execute main function
main "$@"