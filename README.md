# DevOps Portfolio Project: GitOps with ArgoCD, AKS, and GitHub Actions

This project demonstrates a robust, production-grade **DevOps CI/CD Pipeline** leveraging **GitOps principles**. It automates the deployment of a Python FastAPI application to **Azure Kubernetes Service (AKS)**, orchestrated by **ArgoCD** and supported by infrastructure provisioned via **Terraform**.

## 🏗 Architecture & Workflow

The following diagram illustrates the complete DevOps workflow, from code commit to production deployment.

```mermaid
graph TD
    %% Define Nodes
    Dev[👤 Developer]
    Git[📂 GitHub Repository<br/>(Source Code & Config)]
    TF[🏗️ Terraform<br/>(Infrastructure as Code)]

    subgraph "CI Pipeline (GitHub Actions)"
        CI_Build[🔨 Build & Test]
        CI_Push[🐳 Push Image]
        CI_Update[📝 Update Helm Manifest]
    end

    DH[(Docker Hub<br/>Container Registry)]

    subgraph "Azure Cloud"
        AKS[☁️ Azure Kubernetes Service<br/>(AKS Cluster)]
        subgraph "GitOps Controller"
            ArgoCD[🐙 Argo CD]
        end
        App[🚀 Todo App<br/>(Running Pods)]
    end

    %% Flows
    Dev -->|1. git push| Git

    %% Infrastructure Flow
    TF -->|Provision/Manage| AKS

    %% CI Flow
    Git -->|Trigger| CI_Build
    CI_Build --> CI_Push
    CI_Push -->|Store Image| DH
    CI_Push --> CI_Update
    CI_Update -->|Commit New Image Tag| Git

    %% CD Flow
    ArgoCD -->|Monitor/Watch| Git
    ArgoCD -->|Detect Drift & Sync| AKS
    AKS -->|Pull Image| DH

    %% Styling
    style Dev fill:#f9f,stroke:#333,stroke-width:2px
    style Git fill:#24292e,stroke:#fff,color:#fff
    style TF fill:#7b42bc,stroke:#fff,color:#fff
    style ArgoCD fill:#ef7b4d,stroke:#fff,color:#fff
    style AKS fill:#0078d4,stroke:#fff,color:#fff
    style DH fill:#0db7ed,stroke:#fff,color:#fff
```

## 🔄 Workflow Breakdown

### 1. 👤 Developer
The workflow begins with the developer.
- **Action**: Writes code (Python/FastAPI) and defines infrastructure (Terraform) or Kubernetes manifests (Helm).
- **Process**: Commits changes and pushes them to the `master` branch of the **GitHub Repository**.

### 2. 🏗️ Terraform (Infrastructure as Code)
Terraform is responsible for provisioning and managing the underlying cloud infrastructure.
- **Workflow**: `.github/workflows/infra.yaml`
- **Role**: It creates the **Azure Kubernetes Service (AKS)** cluster, Virtual Networks, and other necessary Azure resources.
- **Usage**: Run manually via GitHub Actions (`workflow_dispatch`) to bootstrap or update the infrastructure.

### 3. ⚙️ CI/CD Pipeline (GitHub Actions)
The Continuous Integration pipeline ensures code quality and prepares the deployment artifact.
- **Workflow**: `.github/workflows/ci-cd.yaml`
- **Trigger**: Automatic on push to `master`.
- **Steps**:
    1.  **Build**: Creates a Docker container image from the source code.
    2.  **Push**: Uploads the Docker image to **Docker Hub** with a unique tag (Commit SHA).
    3.  **Update Manifest**: The pipeline modifies the Helm Chart values (`k8s/todo-app/values.yaml`) in the Git repository to reference the new image tag. This "config change" triggers the GitOps process.

### 4. 🐙 Argo CD (GitOps Operator)
Argo CD acts as the continuous delivery mechanism, adhering to GitOps principles.
- **Role**: Runs inside the AKS cluster and constantly monitors the `k8s/` directory in the GitHub repository.
- **Action**: When the CI pipeline commits a change to the Helm values (e.g., a new image tag), Argo CD detects a "drift" between the desired state (Git) and the live state (Cluster).
- **Sync**: It automatically synchronizes the cluster state by applying the changes, causing AKS to deploy the new application version.

### 5. ☁️ AKS Cluster (Runtime Environment)
The Azure Kubernetes Service is where the application lives.
- **Role**: Orchestrates the containerized application.
- **Action**: Upon instruction from Argo CD, Kubernetes pulls the new Docker image from **Docker Hub** and performs a rolling update of the **Todo App** pods, ensuring zero-downtime deployment.

---

## 🛠 Tech Stack

| Component | Tool | Description |
|-----------|------|-------------|
| **Cloud Provider** | Azure (AKS) | Managed Kubernetes Cluster |
| **IaC** | Terraform | Infrastructure provisioning |
| **CI System** | GitHub Actions | Automated build and manifest updates |
| **CD / GitOps** | ArgoCD | Declarative continuous delivery |
| **Containerization** | Docker | Application runtime environment |
| **Registry** | Docker Hub | Container image storage |
| **Application** | Python FastAPI | REST API Backend |
| **Templating** | Helm | Kubernetes package manager |

---

## 🚀 Getting Started

### Prerequisites
*   **Azure Subscription**
*   **GitHub Account**
*   **Docker Hub Account**
*   **Terraform** & **Azure CLI** (for local testing)

### Setup & Deployment

1.  **Configure Secrets**: Set up the following Repository Secrets in GitHub:
    *   `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`
    *   `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`

2.  **Provision Infrastructure**:
    *   Go to **GitHub Actions** tab.
    *   Select **Infrastructure Manager** workflow.
    *   Run workflow to provision AKS and bootstrap Argo CD.

3.  **Deploy Application**:
    *   Push a change to the `app/` directory.
    *   The **CI/CD** workflow will trigger, build the image, and update the manifests.
    *   **Argo CD** will automatically deploy the new version to your cluster.

## 💻 Local Development

To run the application locally for development:

```bash
cd app
docker-compose up --build
```

Access the API documentation at: `http://localhost:8000/docs`
