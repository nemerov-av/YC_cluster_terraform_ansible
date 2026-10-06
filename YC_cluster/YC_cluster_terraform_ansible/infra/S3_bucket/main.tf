terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
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

variable "service_account_id" {
  type        = string
  description = "Service Account ID"
  default     = "" # Опционально, если не используется в S3_bucket
}

provider "yandex" {
  cloud_id  = var.yc_cloud_id
  folder_id = var.yc_folder_id
  zone      = "ru-central1-a"
  service_account_key_file = "${path.module}/authorized_key.json"
}

# ==============================================================================
# Service Account & S3 Bucket
# ==============================================================================

resource "yandex_iam_service_account" "sa-s3" {
  name        = "sa-s3-storage"
  description = "Service account for managing S3 bucket"
}

resource "yandex_resourcemanager_folder_iam_member" "sa-s3-editor" {
  folder_id = var.yc_folder_id
  role      = "storage.admin"
  member    = "serviceAccount:${yandex_iam_service_account.sa-s3.id}"
}

resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  service_account_id = yandex_iam_service_account.sa-s3.id
  description        = "Static access key for S3"
}

resource "yandex_storage_bucket" "consul_bucket" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  
  bucket = "my-consul-releases-bucket-2026"

  anonymous_access_flags {
    read = true
    list = false
  }

  depends_on = [
    yandex_resourcemanager_folder_iam_member.sa-s3-editor
  ]
}

# ==============================================================================
# S3 Objects Upload
# ==============================================================================

resource "yandex_storage_object" "consul_zip" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key

  bucket = yandex_storage_bucket.consul_bucket.id
  key    = "consul_2.0.2_linux_amd64.zip"
  source = "${path.module}/consul_2.0.2_linux_amd64.zip"

  acl = "public-read"
}

resource "yandex_storage_object" "template_zip" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key

  bucket = yandex_storage_bucket.consul_bucket.id
  key    = "consul-template_0.42.1_linux_amd64.zip"
  source = "${path.module}/consul-template_0.42.1_linux_amd64.zip"

  acl = "public-read"
}

resource "yandex_storage_object" "node_exporter_tar" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key

  bucket = yandex_storage_bucket.consul_bucket.id
  key    = "node_exporter-1.12.1.linux-amd64.tar.gz"
  source = "${path.module}/node_exporter-1.12.1.linux-amd64.tar.gz"

  acl = "public-read"
}

resource "yandex_storage_object" "prometheus_tar" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key

  bucket = yandex_storage_bucket.consul_bucket.id
  key    = "prometheus-3.13.2.linux-amd64.tar.gz"
  source = "${path.module}/prometheus-3.13.2.linux-amd64.tar.gz"

  acl = "public-read"
}

# ==============================================================================
# Outputs
# ==============================================================================

output "bucket_name" {
  value = yandex_storage_bucket.consul_bucket.bucket
}

output "consul_s3_url" {
  value = "https://storage.yandexcloud.net/${yandex_storage_bucket.consul_bucket.bucket}/consul_2.0.2_linux_amd64.zip"
}

output "template_s3_url" {
  value = "https://storage.yandexcloud.net/${yandex_storage_bucket.consul_bucket.bucket}/consul-template_0.42.1_linux_amd64.zip"
}

output "node_exporter_s3_url" {
  value = "https://storage.yandexcloud.net/${yandex_storage_bucket.consul_bucket.bucket}/node_exporter-1.12.1.linux-amd64.tar.gz"
}

output "prometheus_s3_url" {
  value = "https://storage.yandexcloud.net/${yandex_storage_bucket.consul_bucket.bucket}/prometheus-3.13.2.linux-amd64.tar.gz"
}