#cloud-config
package_update: true

packages:
  - unzip
  - curl
  - haproxy

runcmd:
  # ==============================================================================
  # 1. Настройка параметров безопасности SSH
  # ==============================================================================
  - |
    SSHD_CONF="/etc/ssh/sshd_config"

    # HostKeyAlgorithms
    if grep -qE '^#?HostKeyAlgorithms' "$SSHD_CONF"; then
      sed -i -E 's/^#?HostKeyAlgorithms.*/HostKeyAlgorithms +ssh-rsa/' "$SSHD_CONF"
    else
      echo "HostKeyAlgorithms +ssh-rsa" >> "$SSHD_CONF"
    fi

    # PubkeyAcceptedKeyTypes
    if grep -qE '^#?PubkeyAcceptedKeyTypes' "$SSHD_CONF"; then
      sed -i -E 's/^#?PubkeyAcceptedKeyTypes.*/PubkeyAcceptedKeyTypes +ssh-rsa/' "$SSHD_CONF"
    else
      echo "PubkeyAcceptedKeyTypes +ssh-rsa" >> "$SSHD_CONF"
    fi

    # PasswordAuthentication
    if grep -qE '^#?PasswordAuthentication' "$SSHD_CONF"; then
      sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONF"
    else
      echo "PasswordAuthentication no" >> "$SSHD_CONF"
    fi

    systemctl restart ssh || systemctl restart sshd

  # ==============================================================================
  # 2. Установка утилит, HAProxy и Consul
  # ==============================================================================
  - while systemctl is-active --quiet apt-daily.service apt-daily-upgrade.service; do sleep 2; done
  - while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
  - apt-get update -y
  - apt-get install -y unzip curl haproxy

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
    bind_addr   = "{{ GetInterfaceIP \"eth0\" }}"
    client_addr = "0.0.0.0"
    retry_join = ${retry_join_ips}
    node_name  = "$MY_HOSTNAME"
    server     = false
    encrypt    = "${encrypt_key}"
    EOF

  - |
    cat <<'EOF' > /etc/systemd/system/consul.service
    [Unit]
    Description="HashiCorp Consul Agent"
    Documentation=https://www.consul.io/
    Requires=network-online.target
    After=network-online.target

    [Service]
    User=consul
    Group=consul
    ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
    ExecReload=/usr/local/bin/consul reload
    KillMode=process
    Restart=on-failure
    LimitNOFILE=65536

    [Install]
    WantedBy=multi-user.target
    EOF

  # ==============================================================================
  # 3. Скачивание Consul Template
  # ==============================================================================
  - curl -fsSL -o /tmp/consul-template.zip https://storage.yandexcloud.net/${bucket_name}/consul-template_${consul_template_ver}_linux_amd64.zip
  - unzip /tmp/consul-template.zip -d /usr/local/bin/
  - chmod +x /usr/local/bin/consul-template
  - rm -f /tmp/consul-template.zip
  - mkdir -p /etc/consul-template.d

  # ==============================================================================
  # 4. Создание шаблона HAProxy и конфигурации Consul Template
  # ==============================================================================
  - |
    cat <<'EOF' > /etc/haproxy/haproxy.cfg.ctmpl
    global
        log /dev/log local0
        log /dev/log local1 notice
        maxconn 2000

    defaults
        log     global
        mode    http
        option  httplog
        option  dontlognull
        timeout connect 5000ms
        timeout client  50000ms
        timeout server  50000ms

    frontend main_app_frontend
      bind *:80
      mode http
      default_backend main_app_backend

    backend main_app_backend
      mode http
      balance roundrobin
        # Если вы хотите проверять работоспособность приложения
      option httpchk GET /health 
      {{ range service "my-app" }}
      server {{ .Node }} {{ .Address }}:{{ .Port }} check
      {{ else }}
        # Заглушка, если ни один инстанс сервиса не найден
      server local 127.0.0.1:8080 backup
      {{ end }}



    # Consul UI (порт 8501)
    frontend consul_ui_frontend
        bind *:8501
        mode http
        default_backend consul_ui_backend

    backend consul_ui_backend
        mode http
        balance roundrobin
        option httpchk GET /v1/status/leader
        {{ range service "consul" }}
        server {{ .Node }} {{ .Address }}:8500 check
        {{ else }}
        server local 127.0.0.1:8500 backup
        {{ end }}

    # Grafana UI (порт 8080)
    frontend grafana_frontend
        bind *:8080
        mode http
        default_backend grafana_backend

    backend grafana_backend
        mode http
        balance roundrobin
        option httpchk GET /api/health
        {{ range service "grafana" }}
        server {{ .Node }} {{ .Address }}:3000 check
        {{ else }}
        server local 127.0.0.1:3000 backup
        {{ end }}
    EOF

    # Экспорт метрик HAProxy для Prometheus (порт 8404)
    frontend prometheus_metrics
        bind *:8404
        mode http
        http-request use-service prometheus-exporter if { path /metrics }
        no log

  - |
    cat <<'EOF' > /etc/consul-template.d/haproxy.hcl
    consul {
      address = "127.0.0.1:8500"
    }

    template {
      source      = "/etc/haproxy/haproxy.cfg.ctmpl"
      destination = "/etc/haproxy/haproxy.cfg"
      # Сначала проверяем конфиг, потом перезагружаем
      command     = "haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl reload haproxy"
    }
    EOF

  - |
    cat <<'EOF' > /etc/systemd/system/consul-template.service
    [Unit]
    Description="Consul Template for HAProxy"
    Requires=network-online.target consul.service
    After=network-online.target consul.service

    [Service]
    ExecStart=/usr/local/bin/consul-template -config=/etc/consul-template.d/haproxy.hcl
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    EOF

  # ==============================================================================
  # 5. Установка Node Exporter и регистрация сервиса в Consul
  # ==============================================================================
  - groupadd --system node_exporter || true
  - useradd --system -g node_exporter --no-create-home --shell /bin/false node_exporter || true

  - curl -fsSL -o /tmp/node_exporter.tar.gz https://storage.yandexcloud.net/my-consul-releases-bucket-2026/node_exporter-1.12.1.linux-amd64.tar.gz
  - tar -xvf /tmp/node_exporter.tar.gz -C /tmp/
  - cp /tmp/node_exporter-1.12.1.linux-amd64/node_exporter /usr/local/bin/
  - chmod +x /usr/local/bin/node_exporter
  - rm -rf /tmp/node_exporter*

  - |
    cat <<'EOF' > /etc/systemd/system/node_exporter.service
    [Unit]
    Description=Node Exporter
    Wants=network-online.target
    After=network-online.target

    [Service]
    User=node_exporter
    Group=node_exporter
    Type=simple
    ExecStart=/usr/local/bin/node_exporter
    Restart=always
    RestartSec=3

    [Install]
    WantedBy=multi-user.target
    EOF

  # ДОБАВЛЕНО: Регистрация Node Exporter в Consul на HAProxy-хосте
  - |
    cat <<'EOF' > /etc/consul.d/service_node_exporter.json
    {
      "service": {
        "name": "node-exporter",
        "port": 9100,
        "tags": ["monitoring", "prometheus"],
        "check": {
          "id": "node-exporter-check",
          "name": "Node Exporter Health Check",
          "http": "http://127.0.0.1:9100/metrics",
          "interval": "10s",
          "timeout": "2s"
        }
      }
    }
    EOF

  # ДОБАВЛЕНО: Регистрация метрик HAproxy в Consul на HAProxy-хосте
  - |
    cat <<'EOF' > /etc/consul.d/service_HAproxy_met.json
    {
      "service": {
        "name": "haproxy_metr",
        "port": 8404,
        "tags": ["monitoring", "prometheus"],
        "check": {
          "id": "haproxy_metr",
          "name": "haproxy_metr Health Check",
          "http": "http://127.0.0.1:8404/metrics",
          "interval": "10s",
          "timeout": "2s"
        }
      }
    }
    EOF

  # ==============================================================================
  # 6. Финальная установка прав и запуск всех служб
  # ==============================================================================
  - chown -R consul:consul /etc/consul.d /var/lib/consul
  - chmod 640 /etc/consul.d/*.json /etc/consul.d/consul.hcl 2>/dev/null || true

  - systemctl daemon-reload
  - systemctl enable consul haproxy consul-template node_exporter
  - systemctl restart consul haproxy consul-template node_exporter
