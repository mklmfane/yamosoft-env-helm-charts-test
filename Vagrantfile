require "yaml"

vagrant_root = File.dirname(File.expand_path(__FILE__))
settings = YAML.load_file "#{vagrant_root}/settings.yaml"

IP_SECTIONS = settings["network"]["control_ip"].match(/^([0-9.]+\.)([^.]+)$/)
IP_NW = IP_SECTIONS.captures[0]
IP_START = Integer(IP_SECTIONS.captures[1])
NUM_WORKER_NODES = settings["nodes"]["workers"]["count"]
CLUSTER_NAME = settings["cluster_name"].gsub(" ", "_")

Vagrant.configure("2") do |config|
  # Pick box based on arch
  config.vm.box = `uname -m`.strip == "aarch64" ? "#{settings["software"]["box"]}-arm64" : settings["software"]["box"]
  config.vm.box_check_update = true
  config.vm.boot_timeout = 300  # Increase SSH wait timeout


  # Common provisioning
  config.vm.provision "shell",
    env: { "IP_NW" => IP_NW, 
           "IP_START" => IP_START, "NUM_WORKER_NODES" => NUM_WORKER_NODES, 
           "DNS_SERVERS" => settings["network"]["dns_servers"].join(" "),
           "GITHUB_PAT" => github_pat,
           "RUNNER_VERSION" => settings["software"]["github_actions"]["version"].to_s,
           "RUNNER_SHA256" => settings["software"]["github_actions"]["sha256"].to_s,
           "RUNNER_REPOSITORY_URL" => settings["software"]["github_actions"]["repository_url"].to_s,
           "RUNNER_NAME" => settings["software"]["github_actions"]["runner_name"].to_s,
           "RUNNER_LABELS" => settings["software"]["github_actions"]["labels"].to_s,
           "RUNNER_WORK_FOLDER" => settings["software"]["github_actions"]["work_folder"].to_s
    },
    inline: <<-SHELL
      apt-get update && apt-get upgrade -y
      echo "$IP_NW$((IP_START)) controlplane" >> /etc/hosts
      for i in $(seq 1 ${NUM_WORKER_NODES}); do
        echo "$IP_NW$((IP_START+i)) node0${i}" >> /etc/hosts
      done
    SHELL

  # ===================
  # CONTROL PLANE
  # ===================
  config.vm.define "controlplane" do |controlplane|
    controlplane.vm.hostname = "controlplane"
    controlplane.vm.network "private_network", ip: settings["network"]["control_ip"]

    controlplane.vm.provider "virtualbox" do |vb|
      vb.cpus = settings["nodes"]["control"]["cpu"]
      vb.memory = settings["nodes"]["control"]["memory"]
      vb.gui = false
      vb.name = "#{CLUSTER_NAME}_controlplane"
    end

    controlplane.vm.provision "shell",
      env: {
        "DNS_SERVERS" => settings["network"]["dns_servers"].join(" "),
        "ENVIRONMENT" => settings["environment"],
        "KUBERNETES_VERSION" => settings["software"]["kubernetes"],
        "KUBERNETES_VERSION_SHORT" => settings["software"]["kubernetes"][0..3],
        "OS" => settings["software"]["os"]
      },
      path: "scripts/common.sh"

    controlplane.vm.provision "shell",
      env: {
        "CALICO_VERSION" => settings["software"]["calico"],
        "CONTROL_IP" => settings["network"]["control_ip"],
        "POD_CIDR" => settings["network"]["pod_cidr"],
        "SERVICE_CIDR" => settings["network"]["service_cidr"]
      },
      path: "scripts/master.sh"
  end

  # ===================
  # Kuberntes WORKERS
  # ===================
  (1..NUM_WORKER_NODES).each do |i|
    config.vm.define "node0#{i}" do |node|
      node.vm.hostname = "node0#{i}"
      node.vm.network "private_network", ip: IP_NW + "#{IP_START + i}"

      node.vm.provider "virtualbox" do |vb|
        vb.cpus = settings["nodes"]["workers"]["cpu"]
        vb.memory = settings["nodes"]["workers"]["memory"]
        vb.gui = false
        vb.name = "#{CLUSTER_NAME}_node0#{i}"
      end

      node.vm.provision "shell",
        env: {
          "DNS_SERVERS" => settings["network"]["dns_servers"].join(" "),
          "ENVIRONMENT" => settings["environment"],
          "KUBERNETES_VERSION" => settings["software"]["kubernetes"],
          "KUBERNETES_VERSION_SHORT" => settings["software"]["kubernetes"][0..3],
          "OS" => settings["software"]["os"]
        },
        path: "scripts/common.sh"

      node.vm.provision "shell", path: "scripts/node.sh"

    end
  end

  # ===================
  # JENKINS
  # ===================
  config.vm.define "jenkins" do |jenkins|
    jenkins.vm.hostname = "jenkins"
    jenkins.vm.network "private_network", ip: settings["network"]["jenkins_ip"]

    # Optional port forwarding to host
    jenkins.vm.network "forwarded_port", guest: 8080, host: settings["network"]["jenkins_port"], auto_correct: true
    jenkins.vm.network "forwarded_port", guest: 22, host: settings["network"]["jenkins_ssh_port"], auto_correct: true

    jenkins.vm.provider "virtualbox" do |vb|
      vb.cpus = settings["nodes"]["jenkins"]["cpu"]
      vb.memory = settings["nodes"]["jenkins"]["memory"]
      vb.gui = false
      vb.name = "#{CLUSTER_NAME}_jenkins"
    end

    jenkins.vm.provision "shell",
      env: {
        "DNS_SERVERS" => settings["network"]["dns_servers"].join(" ")
      },
      inline: <<-SHELL
        set -eux
        apt-get update -y
        apt-get install -y qemu-guest-agent ca-certificates curl gnupg lsb-release apt-transport-https
        systemctl restart qemu-guest-agent || true

        mkdir -p /etc/systemd/resolved.conf.d/
        cat <<EOF >/etc/systemd/resolved.conf.d/dns_servers.conf
[Resolve]
DNS=${DNS_SERVERS}
EOF
        systemctl restart systemd-resolved || true

        echo "#{settings["network"]["control_ip"]} controlplane" >> /etc/hosts
        for i in $(seq 1 #{NUM_WORKER_NODES}); do
          echo "#{IP_NW}$((#{IP_START}+i)) node0${i}" >> /etc/hosts
        done
        echo "#{settings["network"]["jenkins_ip"]} jenkins" >> /etc/hosts
      SHELL

    jenkins.vm.provision "shell",
      env: {
        "JENKINS_HTTP_PORT" => settings["software"]["jenkins"]["port"].to_s
      },
      path: "scripts/jenkins.sh"
  end

  # ===================
  # GITHUB ACTIONS RUNNER
  # ===================
  config.vm.define "ghaction" do |ghaction|
    ghaction.vm.hostname = "gha-runner"

    # Private network access to the Kubernetes lab.
    ghaction.vm.network "private_network",
      ip: settings["network"]["github_actions_ip"]

    # Optional application port for workflow jobs.
    ghaction.vm.network "forwarded_port",
      guest: 8080,
      host: settings["network"]["github_actions_port"],
      host_ip: "127.0.0.1",
      auto_correct: true

    # Optional SSH forwarding.
    ghaction.vm.network "forwarded_port",
      guest: 22,
      host: settings["network"]["github_actions_ssh_port"],
      host_ip: "127.0.0.1",
      auto_correct: true

    ghaction.vm.provider "virtualbox" do |vb|
      vb.name = "#{CLUSTER_NAME}_github_actions"
      vb.gui = false
      vb.cpus = settings["nodes"]["github_actions"]["cpu"]
      vb.memory = settings["nodes"]["github_actions"]["memory"]
    end

    # Prevent workflow jobs from accessing the host project directory.
    ghaction.vm.synced_folder ".", "/vagrant", disabled: true

    ghaction.vm.provision "shell",
      env: {
        "DNS_SERVERS" => settings["network"]["dns_servers"].join(" ")
      },
      inline: <<-SHELL
        set -eu

        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y

        apt-get install -y \
          ca-certificates \
          curl \
          git \
          jq \
          tar \
          unzip

        # Configure DNS.
        mkdir -p /etc/systemd/resolved.conf.d

        cat > /etc/systemd/resolved.conf.d/dns_servers.conf <<EOF
[Resolve]
DNS=${DNS_SERVERS}
EOF

        systemctl restart systemd-resolved
        resolvectl flush-caches

        # Add an entry only when the hostname is not already present.
        add_host_entry() {
          host_ip="$1"
          host_name="$2"

          if ! grep -qE "(^|[[:space:]])${host_name}([[:space:]]|$)" /etc/hosts; then
            echo "${host_ip} ${host_name}" >> /etc/hosts
          fi
        }

        # Control plane.
        add_host_entry \
          "#{settings["network"]["control_ip"]}" \
          "controlplane"

        # Kubernetes workers.
        for i in $(seq 1 #{NUM_WORKER_NODES}); do
          worker_ip="#{IP_NW}$((#{IP_START} + i))"
          worker_name="node0${i}"
          add_host_entry "${worker_ip}" "${worker_name}"
        done

        # Jenkins.
        add_host_entry \
          "#{settings["network"]["jenkins_ip"]}" \
          "jenkins"

        # GitHub Actions runner.
        add_host_entry \
          "#{settings["network"]["github_actions_ip"]}" \
          "gha-runner"

        # Create the runner installation directory.
        install -d \
          -m 0755 \
          -o vagrant \
          -g vagrant \
          /home/vagrant/actions-runner


        # Register only when the runner is not already configured.
        if [ ! -f "${RUNNER_DIR}/.runner" ]; then
          if [ -z "${GITHUB_PAT:-}" ]; then
            echo "ERROR: No GitHub PAT was supplied." >&2
            echo "Expected PAT file or GITHUB_PAT environment variable." >&2
            exit 1
          fi

        # Convert the repository URL into owner/repository.
        REPOSITORY_PATH="${RUNNER_REPOSITORY_URL#https://github.com/}"
        REPOSITORY_PATH="${REPOSITORY_PATH%.git}"

        echo "Generating a short-lived registration token..."

        RUNNER_TOKEN="$(
          curl \
            --silent \
            --show-error \
            --fail-with-body \
            --request POST \
            --header "Accept: application/vnd.github+json" \
            --header "Authorization: Bearer ${GITHUB_PAT}" \
            --header "X-GitHub-Api-Version: 2026-03-10" \
            "https://api.github.com/repos/${REPOSITORY_PATH}/actions/runners/registration-token" |
          jq -er '.token'
        )"

        # The long-lived PAT is no longer required.
        unset GITHUB_PAT

        if [ -z "${RUNNER_TOKEN}" ]; then
          echo "ERROR: GitHub returned an empty registration token." >&2
          exit 1
        fi

        echo "Registering ${RUNNER_NAME} with ${RUNNER_REPOSITORY_URL}..."

        (
          cd "${RUNNER_DIR}"

          runuser -u vagrant -- ./config.sh \
            --url "${RUNNER_REPOSITORY_URL}" \
            --token "${RUNNER_TOKEN}" \
            --name "${RUNNER_NAME}" \
            --labels "${RUNNER_LABELS}" \
            --work "${RUNNER_WORK_FOLDER}" \
            --unattended
          )

        unset RUNNER_TOKEN
        else
          REGISTERED_URL="$(
            jq -r '.gitHubUrl // empty' "${RUNNER_DIR}/.runner"
          )"

          if [ -n "${REGISTERED_URL}" ] &&
          [ "${REGISTERED_URL}" != "${RUNNER_REPOSITORY_URL}" ]; then
            echo "ERROR: Runner is registered to ${REGISTERED_URL}" >&2
            echo "Expected: ${RUNNER_REPOSITORY_URL}" >&2
            exit 1
          fi

          echo "Runner is already registered with ${REGISTERED_URL}."
        fi
      SHELL
  end
end