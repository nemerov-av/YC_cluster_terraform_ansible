#cloud-config
package_update: true

packages:
  - unzip
  - curl
  - docker.io
  - jq

runcmd:
  # ==============================================================================
  # 1. Настройка параметров безопасности SSH
  # ==============================================================================
  - |
    SSHD_CONF="/etc/ssh/sshd_config"
    if grep -qE '^#?HostKeyAlgorithms' "$SSHD_CONF"; then
      sed -i -E 's/^#?HostKeyAlgorithms.*/HostKeyAlgorithms +ssh-rsa/' "$SSHD_CONF"
    else
      echo "HostKeyAlgorithms +ssh-rsa" >> "$SSHD_CONF"
    fi
    if grep -qE '^#?PubkeyAcceptedKeyTypes' "$SSHD_CONF"; then
      sed -i -E 's/^#?PubkeyAcceptedKeyTypes.*/PubkeyAcceptedKeyTypes +ssh-rsa/' "$SSHD_CONF"
    else
      echo "PubkeyAcceptedKeyTypes +ssh-rsa" >> "$SSHD_CONF"
    fi
    if grep -qE '^#?PasswordAuthentication' "$SSHD_CONF"; then
      sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONF"
    else
      echo "PasswordAuthentication no" >> "$SSHD_CONF"
    fi
    systemctl restart ssh || systemctl restart sshd

  # ==============================================================================
  # 2. Установка и настройка Consul
  # ==============================================================================
  - while systemctl is-active --quiet apt-daily.service apt-daily-upgrade.service; do sleep 2; done
  - while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
  - apt-get update -y
  - apt-get install -y unzip curl docker.io jq

  - curl -fsSL -o /tmp/consul.zip https://storage.yandexcloud.net/my-consul-releases-bucket-2026/consul_2.0.2_linux_amd64.zip
  - unzip /tmp/consul.zip -d /usr/local/bin/
  - chmod +x /usr/local/bin/consul
  - rm -f /tmp/consul.zip

  - groupadd --system consul || true
  - useradd --system -g consul --home /etc/consul.d --shell /bin/false consul || true
  - mkdir -p /etc/consul.d /var/lib/consul

  - |
    MY_HOSTNAME=$(hostname)
    cat <<EOF > /etc/consul.d/consul.hcl
    datacenter = "${datacenter}"
    data_dir   = "/var/lib/consul"
    log_level  = "INFO"
    bind_addr  = "{{ GetInterfaceIP \"eth0\" }}"
    client_addr = "0.0.0.0"
    retry_join = ${retry_join_ips}
    node_name = "$MY_HOSTNAME"
    server = false
    encrypt = "${encrypt_key}"
    addresses {
      http = "0.0.0.0"
      dns  = "0.0.0.0"
    }
    EOF

  - |
    cat <<'EOF' > /etc/systemd/system/consul.service
    [Unit]
    Description="HashiCorp Consul"
    Requires=network-online.target
    After=network-online.target
    [Service]
    User=consul
    Group=consul
    ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
    Restart=on-failure
    [Install]
    WantedBy=multi-user.target
    EOF

  # ==============================================================================
  # 3. Node Exporter
  # ==============================================================================
  - curl -fsSL -o /tmp/node_exporter.tar.gz https://storage.yandexcloud.net/my-consul-releases-bucket-2026/node_exporter-1.12.1.linux-amd64.tar.gz
  - tar -xvf /tmp/node_exporter.tar.gz -C /tmp/
  - mv /tmp/node_exporter-1.12.1.linux-amd64/node_exporter /usr/local/bin/
  - |
    cat <<'EOF' > /etc/systemd/system/node_exporter.service
    [Unit]
    Description=Node Exporter
    [Service]
    ExecStart=/usr/local/bin/node_exporter
    Restart=always
    [Install]
    WantedBy=multi-user.target
    EOF

  - |
    cat <<'EOF' > /etc/consul.d/service_node_exporter.json
    {"service": {"name": "node-exporter", "port": 9100, "check": {"http": "http://127.0.0.1:9100/metrics", "interval": "10s"}}}
    EOF

  # ==============================================================================
  # 4. Регистрация приложения в Consul
  # ==============================================================================
  - |
    cat <<'EOF' > /etc/consul.d/service_app.json
    {"service": {"name": "my-app", "port": 80, "check": {"http": "http://127.0.0.1:80/health", "interval": "10s"}}}
    EOF

  # ==============================================================================
  # 5. Скачивание Consul Template
  # ==============================================================================
  - curl -fsSL -o /tmp/consul-template.zip https://storage.yandexcloud.net/${bucket_name}/consul-template_${consul_template_ver}_linux_amd64.zip
  - unzip /tmp/consul-template.zip -d /usr/local/bin/
  - chmod +x /usr/local/bin/consul-template
  - rm -f /tmp/consul-template.zip
  - mkdir -p /etc/consul-template.d

  # ==============================================================================
  # 6. Настройка Consul Template для автодеплоя приложения
  # ==============================================================================
  # Шаблон, за которым следит consul-template
  - |
    cat <<'EOF' > /etc/consul-template.d/version.ctmpl
    {{ key "release_version" }}
    EOF

  # Конфигурация consul-template для запуска скрипта
  - |
    cat <<'EOF' > /etc/consul-template.d/app-deploy.hcl
    consul {
      address = "127.0.0.1:8500"
    }

    template {
      source      = "/etc/consul-template.d/version.ctmpl"
      destination = "/var/run/app_version.txt"
      command     = "/usr/local/bin/deploy_app.sh >> /var/log/app_deploy.log 2>&1"
    }
    EOF

  # Скрипт деплоя
  - |
    cat <<'EOF' > /usr/local/bin/deploy_app.sh
    #!/bin/bash
    until curl -s http://127.0.0.1:8500/v1/agent/self | grep -q "Config"; do sleep 2; done

    IAM_TOKEN=$(curl -s -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token | jq -r .access_token)
    echo "$IAM_TOKEN" | docker login --username iam --password-stdin cr.yandex

    RELEASE_VERSION=$(cat /var/run/app_version.txt)
    if [ -z "$RELEASE_VERSION" ]; then
      echo "$(date) - ERROR: Version file is empty! Aborting."
      exit 1
    fi

    echo "$(date) - Deploying version: $RELEASE_VERSION"

    # Внимание: здесь Terraform подставит URL реестра
    FULL_IMAGE_NAME="${registry_url}/service-main:$RELEASE_VERSION"

    docker pull $FULL_IMAGE_NAME
    IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' $FULL_IMAGE_NAME 2>/dev/null | cut -d'@' -f2 || echo "unknown")

    docker rm -f service-main || true

    # Обратите внимание: мы используем порт 8080, как в вашем старом конфиге[cite: 4]
    docker run -d --name service-main --restart always -p 80:8080 ${registry_url}/service-main@$IMAGE_DIGEST

    echo "$(date) - Service started successfully with version: $RELEASE_VERSION (Digest: $IMAGE_DIGEST)"
    EOF
  - chmod +x /usr/local/bin/deploy_app.sh

  # Служба systemd для Consul Template (Автодеплой)
  - |
    cat <<'EOF' > /etc/systemd/system/consul-template-app.service
    [Unit]
    Description="Consul Template for App Deployment"
    Requires=network-online.target consul.service
    After=network-online.target consul.service

    [Service]
    ExecStart=/usr/local/bin/consul-template -config=/etc/consul-template.d/app-deploy.hcl
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    EOF

  # ==============================================================================
  # 7. Финальная установка прав и запуск служб
  # ==============================================================================
  - chown -R consul:consul /etc/consul.d /var/lib/consul
  - chmod 640 /etc/consul.d/*.json /etc/consul.d/consul.hcl 2>/dev/null || true

  - systemctl daemon-reload
  - systemctl enable consul node_exporter docker consul-template-app
  - systemctl restart consul node_exporter docker consul-template-app
