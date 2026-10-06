terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
    local = {
      source = "hashicorp/local"
    }
  }
  required_version = ">= 0.13"
}

variable "yc_folder_id" {
  type        = string
  description = "Yandex Cloud Folder ID"
}

variable "yc_cloud_id" {
  type        = string
  description = "Yandex Cloud ID"
}

provider "yandex" {
  cloud_id                 = var.yc_cloud_id
  folder_id                = var.yc_folder_id
  zone                     = "ru-central1-a"
  service_account_key_file = "${path.module}/authorized_key.json"
}

# ==============================================================================
# Yandex Container Registry
# ==============================================================================

resource "yandex_container_registry" "app_registry" {
  name      = "my-app-registry"
  folder_id = var.yc_folder_id
}

# ==============================================================================
# Service Account for GitLab CI (Pusher)
# ==============================================================================

resource "yandex_iam_service_account" "sa_gitlab_ci" {
  name        = "sa-gitlab-ci"
  description = "Service account for pushing images from GitLab CI"
}

# Используем yandex_container_registry_iam_binding вместо _iam_member
resource "yandex_container_registry_iam_binding" "sa_gitlab_ci_pusher" {
  registry_id = yandex_container_registry.app_registry.id
  role        = "container-registry.images.pusher"

  members = [
    "serviceAccount:${yandex_iam_service_account.sa_gitlab_ci.id}",
  ]
}

# Создаем ключ авторизации для GitLab CI
resource "yandex_iam_service_account_key" "sa_gitlab_ci_key" {
  service_account_id = yandex_iam_service_account.sa_gitlab_ci.id
  description        = "Key for GitLab CI to auth in Yandex Container Registry"
}

# ==============================================================================
# Service Account for Workers (Puller)
# ==============================================================================

resource "yandex_iam_service_account" "sa_worker" {
  name        = "sa-worker-puller"
  description = "Service account for Worker nodes to pull images"
}

# Используем yandex_container_registry_iam_binding для прав на скачивание
resource "yandex_container_registry_iam_binding" "sa_worker_puller" {
  registry_id = yandex_container_registry.app_registry.id
  role        = "container-registry.images.puller"

  members = [
    "serviceAccount:${yandex_iam_service_account.sa_worker.id}",
  ]
}

# ==============================================================================
# Формирование JSON-ключа авторизации через jsonencode
# ==============================================================================

locals {
  gitlab_ci_key_json = jsonencode({
    id                 = yandex_iam_service_account_key.sa_gitlab_ci_key.id
    service_account_id = yandex_iam_service_account.sa_gitlab_ci.id
    created_at         = yandex_iam_service_account_key.sa_gitlab_ci_key.created_at
    key_algorithm      = yandex_iam_service_account_key.sa_gitlab_ci_key.key_algorithm
    public_key         = yandex_iam_service_account_key.sa_gitlab_ci_key.public_key
    private_key        = yandex_iam_service_account_key.sa_gitlab_ci_key.private_key
  })
}

# ==============================================================================
# Сохранение ключа GitLab CI в локальный файл
# ==============================================================================

resource "local_file" "gitlab_ci_key_file" {
  content  = local.gitlab_ci_key_json
  filename = "${path.module}/gitlab_ci_key.json"
}

# ==============================================================================
# Outputs
# ==============================================================================

output "registry_id" {
  value = yandex_container_registry.app_registry.id
}

output "registry_url" {
  value = "cr.yandex/${yandex_container_registry.app_registry.id}"
}

output "gitlab_ci_key_json" {
  value     = local.gitlab_ci_key_json
  sensitive = true
}