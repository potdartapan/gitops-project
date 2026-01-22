# Todo List Application with FastAPI, Kubernetes, and Terraform

This repository contains a full-stack Todo List application built with **FastAPI**, containerized with **Docker**, orchestrated with **Kubernetes (AKS)**, and infrastructure managed by **Terraform**.

## Project Overview

The application is a simple REST API for managing todo items. It supports creating, reading, updating, and deleting tasks. The frontend is served as static files.

### Tech Stack

*   **Application**: Python, FastAPI, SQLAlchemy
*   **Database**: PostgreSQL (Production/Docker), SQLite (Local Dev default)
*   **Containerization**: Docker, Docker Compose
*   **Orchestration**: Kubernetes (Azure Kubernetes Service - AKS)
*   **Infrastructure as Code**: Terraform (Azure)
*   **CI/CD**: ArgoCD (Manifests included)

## Directory Structure

*   `app/`: Source code for the FastAPI application, `Dockerfile`, and `docker-compose.yaml`.
*   `k8s/`: Kubernetes manifests for deploying the application and database, including ArgoCD configuration.
*   `terraform/`: Terraform configuration for provisioning Azure infrastructure (AKS, Resource Group).

## Prerequisites

Ensure you have the following tools installed:

*   [Docker](https://docs.docker.com/get-docker/) & [Docker Compose](https://docs.docker.com/compose/install/)
*   [Terraform](https://developer.hashicorp.com/terraform/downloads)
*   [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
*   [kubectl](https://kubernetes.io/docs/tasks/tools/)

## Running Locally

You can run the application locally using Docker Compose.

1.  Navigate to the `app` directory:
    ```bash
    cd app
    ```

2.  Start the application and database:
    ```bash
    docker-compose up --build
    ```

3.  Access the application:
    *   **Web Interface**: Open [http://localhost:8000](http://localhost:8000) in your browser.
    *   **API Docs (Swagger UI)**: [http://localhost:8000/docs](http://localhost:8000/docs)
    *   **ReDoc**: [http://localhost:8000/redoc](http://localhost:8000/redoc)

To stop the application, press `Ctrl+C` or run `docker-compose down`.

## Infrastructure Setup (Terraform)

This project uses Terraform to provision an Azure Kubernetes Service (AKS) cluster.

1.  Navigate to the `terraform` directory:
    ```bash
    cd terraform
    ```

2.  Login to Azure:
    ```bash
    az login
    ```

3.  Initialize Terraform:
    ```bash
    terraform init
    ```

4.  Plan the infrastructure changes:
    ```bash
    terraform plan
    ```

5.  Apply the configuration to create the resources:
    ```bash
    terraform apply
    ```
    *Type `yes` when prompted to confirm.*

6.  Configure `kubectl` to connect to the new AKS cluster (the command will be outputted by Terraform or you can construct it):
    ```bash
    az aks get-credentials --resource-group <resource_group_name> --name <cluster_name>
    ```

## Kubernetes Deployment

Once your AKS cluster is running and `kubectl` is configured, you can deploy the application.

1.  Navigate to the `k8s` directory:
    ```bash
    cd k8s
    ```

2.  Deploy the database:
    ```bash
    kubectl apply -f postgres.yaml
    ```

3.  Deploy the application:
    ```bash
    kubectl apply -f todo-app/
    ```

4.  (Optional) Deploy using ArgoCD:
    ```bash
    kubectl apply -f argocd-app.yaml
    ```

## API Endpoints

| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `GET` | `/todos` | List all todo items |
| `POST` | `/todos` | Create a new todo item |
| `PUT` | `/todos/{todo_id}` | Update a todo item (mark as complete/incomplete) |
| `DELETE` | `/todos/{todo_id}` | Delete a todo item |
