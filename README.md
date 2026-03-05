# KCC Setup Cluster

This repository contains an automated setup script for **Google Cloud Config Connector (KCC)** on a GKE (Google Kubernetes Engine) cluster using **Cluster mode** and **Workload Identity**.

## Overview

Config Connector is a Kubernetes add-on that allows you to manage Google Cloud resources through Kubernetes. This project provides a robust bash script (`setup.bash`) that orchestrates the entire lifecycle of setting up a KCC-enabled environment.

## Directory Structure

```text
.
├── app/                  # Go Gin application source code
│   ├── main.go           # API endpoints (Gin + GORM)
│   ├── go.mod            # Go modules
│   └── Dockerfile        # Container definition
├── kcc/                  # Config Connector manifests (Kustomize)
│   ├── app/              # App-related manifests
│   │   ├── artifact-registry.yaml
│   │   ├── cloud-run.yaml
│   │   └── kustomization.yaml
│   ├── infra/            # Core infrastructure manifests
│   │   ├── compute-instance.yaml
│   │   ├── config-connector.yaml
│   │   ├── sql-instance.yaml
│   │   └── kustomization.yaml
│   ├── params-cm.yaml.template # Template for parameters ConfigMap
│   └── params-cm.yaml    # Generated ConfigMap (shared by kustomizations)
├── setup.bash            # Orchestrates GKE cluster and KCC setup
├── deploy-app.bash       # Orchestrates Go API deployment to Cloud Run
└── README.md             # Project documentation
```

## Prerequisites

Before running the setup script, ensure you have the following tools installed and configured:

- **[Google Cloud SDK (gcloud)](https://cloud.google.com/sdk/docs/install)**
- **[kubectl](https://kubernetes.io/docs/tasks/tools/)** (v1.21+ for built-in Kustomize support)
- **[Kustomize](https://kustomize.io/)** (Can be used via `kubectl -k`)
- **[gsutil](https://cloud.google.com/storage/docs/gsutil_install)** (usually comes with gcloud)
- **[psql](https://www.postgresql.org/download/)** (PostgreSQL interactive terminal, required for database seeding)
- Active billing account on Google Cloud.

## Configuration

The scripts use several environment variables that you can override to customize your deployment. These variables are automatically injected into the KCC manifests via Kustomize.

| Variable | Default Value | Description |
| :--- | :--- | :--- |
| `PROJECT_ID` | `javiercm-ge-tests` | The GCP Project ID where resources will be created. |
| `REGION` | `europe-west1` | The GCP Region for the cluster and resources. |
| `ZONE` | `$REGION-d` | The GCP Zone for the GKE cluster and VM. |
| `CLUSTER_NAME` | `cc-cluster` | The name of the GKE cluster to be created. |
| `DB_PASSWORD` | *(None)* | **Mandatory**. The password for the Cloud SQL user. |
| `DEBUG` | `false` | Set to `true` to enable verbose bash logging (`set -x`). |

> [!NOTE]
> The scripts automatically generate derived values like `GSA_EMAIL`, `REPO_NAME`, and `FULL_IMAGE_NAME` (the Artifact Registry URL) to ensure consistency across the deployment.

## What the Script Does

The `setup.bash` script follows these steps:

1. **Idempotent API Activation**: Enables `compute`, `container`, `iam`, and `sqladmin` APIs.
2. **GKE Cluster Provisioning**: Creates a 3-node cluster with Workload Identity enabled.
3. **KCC Operator Installation**: Downloads and installs the latest Config Connector operator bundle.
4. **KCC CLI Tool Installation**: Installs the `config-connector` CLI to `/usr/local/bin` for resource exporting.
5. **IAM Configuration**: 
    - Creates a dedicated Google Service Account (GSA).
    - Assigns `roles/editor` to the GSA.
    - Binds the GSA to the Kubernetes Service Account (`cnrm-controller-manager`) using Workload Identity.
6. **KCC Controller Setup**: Configures the `ConfigConnector` resource in `clusterwide` mode.
7. **Verification (Demo Resources)**: Automatically provisions a Cloud SQL instance and a Compute Engine VM via KCC to verify the setup.

## Go API Demo (Cloud Run)

In addition to the core setup, this repository includes a demo of a **Go Gin** service deployed to **Cloud Run** using Config Connector.

The demo features:
- **Go Gin Gonic** framework for the REST API.
- **GORM** for PostgreSQL interaction.
- **Cloud SQL** integration via Unix Sockets.
- **Auto-migration**: On startup, it creates a `Users` table and populates it with 10 sample records.
- **Endpoints**:
    - `GET /users`: List all users.
    - `POST /users`: Create a new user.
    - `PUT /users/:id`: Update a user.
    - `DELETE /users/:id`: Delete a user.

The demo structure:
- `app/`: Go source code and `Dockerfile`.
- `kcc/`: Manifest templates for Artifact Registry and Cloud Run.
- `deploy-app.bash`: Automation script for the app lifecycle.

### Deploying the App Demo

Ensure the KCC cluster and infrastructure (SQL Instance) are already installed, then run:

```bash
./deploy-app.bash
```

The script will:
1. Enable `run.googleapis.com` and `artifactregistry.googleapis.com`.
2. Provision an **Artifact Registry** repository via KCC.
3. Build and push the Docker image to the registry.
4. Deploy the **Cloud Run** service via KCC.
5. Provide the public URL once the service is ready.

## Usage

Clone the repository and run the setup script:

```bash
# Clone the repository
git clone https://github.com/javiercanadillas/sonae-kcc.git
cd sonae-kcc

# (Optional) Set your project ID and/or region and zone
# export PROJECT_ID="your-project-id"
# export REGION="europe-west1"
# export ZONE="${REGION}-d"

# Set the Database Password (MANDATORY)
export DB_PASSWORD="your-secure-password"

# Run the installation
./setup.bash install
```

To remove all resources created by the script (including the GKE cluster and demo resources), run:

```bash
./setup.bash destroy
```

## Trying it out

Once you have completed the installation and deployment, follow these steps to verify that everything is working as expected:

### 1. Verify Infrastructure
Ensure the GKE cluster and Config Connector resources are running:
```bash
# Check KCC status
kubectl get gcp --all-namespaces

# Check SQL Instance status
kubectl get sqlinstance test-sql-cc
```

### 2. Check the Database Seeding
The setup script automatically seeds the database with characters from Edgar Allan Poe's stories. You can verify this once the app is deployed.

### 3. Test the API Endpoints
Get the Cloud Run service URL from the output of `./deploy-app.bash` and use it to test the following endpoints:

**Health Check:**
```bash
export SERVICE_URL=$(kubectl get runservice users-api -o jsonpath='{.status.url}')
curl -i $SERVICE_URL/health
```

**List Users (The Poe Collection):**
```bash
curl -s $SERVICE_URL/users | jq .
```
*You should see a list of characters like C. Auguste Dupin, Roderick Usher, and Arthur Gordon Pym.*

**Add a New User:**
```bash
curl -X POST $SERVICE_URL/users \
  -H "Content-Type: application/json" \
  -d '{"email":"the.raven@poe.com", "first_name":"The", "last_name":"Raven"}'
```

### 4. Showcase Configuration Drift Detection
One of the most powerful features of Config Connector is its ability to detect and correct "drift" (manual changes made outside of Kubernetes that conflict with your desired state).

**Step 1: Provoke manual drift via gcloud**
Add a label to the Compute Engine VM directly through the GCP console or CLI:
```bash
export ZONE=$(kubectl get configmap kcc-params -o jsonpath='{.data.zone}')
gcloud compute instances add-labels test-vm-cc --labels="manual-drift=true" --zone=$ZONE
```

**Step 2: Watch KCC reconcile the resource**
KCC will eventually detect that the state in GCP does not match the manifest in `kcc/infra/compute-instance.yaml` and will automatically remove the unauthorized label. You can monitor the progress:
```bash
kubectl describe computeinstance test-vm-cc
```

**Step 3: Verify resolution**
Verify that the label has been removed by KCC to restore the "Source of Truth":
```bash
gcloud compute instances describe test-vm-cc --zone=$ZONE --format="value(labels)"
```

### 5. Cleanup
When you are done, don't forget to run `./setup.bash destroy` to avoid unnecessary GCP costs.
# Additional information

## Exporting resources

```bash
# Export all resources
config-connector export --all

# Export specific resources
config-connector export --resource=sql.cnrm.cloud.google.com/SQLInstance --name=test-sql-cc
config-connector export --resource=compute.cnrm.cloud.google.com/ComputeInstance --name=test-vm-cc
```

## Links

- [Google Cloud Config Connector](https://cloud.google.com/config-connector)
- [Google Cloud Config Connector Documentation](https://cloud.google.com/config-connector/docs)
- [Google Cloud Config Connector CLI](https://cloud.google.com/config-connector/docs/concepts/cli)
- [Google Cloud Config Connector Workload Identity](https://cloud.google.com/config-connector/docs/concepts/workload-identity)
- [Config Connector GitHub Page](https://github.com/GoogleCloudPlatform/k8s-config-connector)

---
*Maintained by Javier Cañadillas*
