# Todo List App

This is a Todo List application built with FastAPI, SQLAlchemy, and PostgreSQL. It includes infrastructure as code (IaC) using Terraform for Azure and Kubernetes manifests for deployment.

## Features

- **FastAPI** backend
- **PostgreSQL** database (Production) / **SQLite** (Local)
- **Terraform** for Azure infrastructure
- **Kubernetes** deployment via Helm and ArgoCD
- **Docker Compose** for local development

## Project Structure

- `app/`: Application source code
- `k8s/`: Kubernetes manifests and Helm charts
- `terraform/`: Terraform configuration for Azure

## Local Development

### Prerequisites

- Docker
- Docker Compose

### Running with Docker Compose

To start the application and database locally:

```bash
cd app
docker-compose up --build
```

The application will be available at `http://localhost:8000`.
API documentation is available at `http://localhost:8000/docs`.

## Infrastructure

The infrastructure is managed using Terraform on Azure.

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

## Deployment

Kubernetes deployment is managed via Helm charts located in `k8s/todo-app/`.
ArgoCD is used for GitOps deployment (`k8s/argocd-app.yaml`).
