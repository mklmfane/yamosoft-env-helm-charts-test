require "yaml"
vagrant_root = File.dirname(File.expand_path(__FILE__))
settings = YAML.load_file(File.join(vagrant_root, "settings.yaml"))
# Read the PAT only from the local host operating-system environment.
# Never store this secret in settings.yaml or commit it to source control.
github_pat = ENV.fetch("GITHUB_PAT", "").strip
ip_sections = settings["network"]["control_ip"].match(/^([0-9.]+\.)([^.]+)$/)
raise "Invalid network.control_ip in settings.yaml" unless ip_sections
ip_network = ip_sections.captures[0]
ip_start = Integer(ip_sections.captures[1])
num_worker_nodes = Integer(settings["nodes"]["workers"]["count"])
cluster_name = settings["cluster_name"].gsub(" ", "_")
runner_settings = settings.fetch("software").fetch("github_actions")

# Use the locally hosted VirtualBox box instead of HCP Vagrant Registry.
local_box_name = "yamosoft/ubuntu-24.04-local"
local_box_path = "/srv/vagrant-boxes/bento-ubuntu-24.04/bento-ubuntu-24.04-202510.26.0-virtualbox-amd64.box"
local_box_checksum_path = "#{local_box_path}.sha256"

unless File.file?(local_box_path)
  raise <<~ERROR
    Local VirtualBox box not found:
      #{local_box_path}
    Run the local box export script before running `vagrant up`.
  ERROR
end

unless File.file?(local_box_checksum_path)
  raise <<~ERROR
    SHA-256 file not found:
      #{local_box_checksum_path}
    Generate it with:
      cd #{File.dirname(local_box_path)}
      sha256sum #{File.basename(local_box_path)} > #{File.basename(local_box_checksum_path)}
  ERROR
end

local_box_checksum = File.read(local_box_checksum_path).split.first
unless local_box_checksum&.match?(/\A[0-9a-fA-F]{64}\z/)
  raise "Invalid SHA-256 value in #{local_box_checksum_path}"
end

Vagrant.configure("2") do |config|
  # This archive is an amd64 VirtualBox box stored on the local Ubuntu host.
  host_architecture = `uname -m`.strip
  unless ["x86_64", "amd64"].include?(host_architecture)
    raise "Local box requires amd64/x86_64; detected #{host_architecture}"
  end

  config.vm.box = local_box_name
  config.vm.box_url = "file://#{local_box_path}"
  config.vm.box_download_checksum_type = "sha256"
  config.vm.box_download_checksum = local_box_checksum
  config.vm.box_check_update = false
  config.vm.boot_timeout = 300

  # Common host entries for every VM. Do not run a full OS upgrade here;
  # package upgrades can restart services and kernels during provisioning.
  config.vm.provision "shell",
    env: {
      "IP_NW" => ip_network,
      "IP_START" => ip_start.to_s,
      "NUM_WORKER_NODES" => num_worker_nodes.to_s
    },
    inline: <<-SHELL
      set -eu
      apt-get update -y
      add_host_entry() {
        entry_ip="$1"
        entry_name="$2"
        if ! grep -qE "(^|[[:space:]])${entry_name}([[:space:]]|$)" /etc/hosts; then
          echo "${entry_ip} ${entry_name}" >> /etc/hosts
        fi
      }
      add_host_entry "${IP_NW}${IP_START}" "controlplane"
      for i in $(seq 1 "${NUM_WORKER_NODES}"); do
        add_host_entry "${IP_NW}$((IP_START + i))" "node0${i}"
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
      vb.name = "#{cluster_name}_controlplane"
    end
    controlplane.vm.provision "shell",
      env: {
        "DNS_SERVERS" => settings["network"]["dns_servers"].join(" "),
        "ENVIRONMENT" => settings.fetch("environment", "").to_s,
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
  # KUBERNETES WORKERS
  # ===================
  (1..num_worker_nodes).each do |i|
    config.vm.define "node0#{i}" do |node|
      node.vm.hostname = "node0#{i}"
      node.vm.network "private_network", ip: "#{ip_network}#{ip_start + i}"
      node.vm.provider "virtualbox" do |vb|
        vb.cpus = settings["nodes"]["workers"]["cpu"]
        vb.memory = settings["nodes"]["workers"]["memory"]
        vb.gui = false
        vb.name = "#{cluster_name}_node0#{i}"
      end
      node.vm.provision "shell",
        env: {
          "DNS_SERVERS" => settings["network"]["dns_servers"].join(" "),
          "ENVIRONMENT" => settings.fetch("environment", "").to_s,
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
    jenkins.vm.network "forwarded_port",
      guest: 8080,
      host: settings["network"]["jenkins_port"],
      id: "jenkins-http",
      auto_correct: true
    jenkins.vm.network "forwarded_port",
      guest: 22,
      host: settings["network"]["jenkins_ssh_port"],
      host_ip: "127.0.0.1",
      id: "ssh",
      auto_correct: true
    jenkins.vm.provider "virtualbox" do |vb|
      vb.cpus = settings["nodes"]["jenkins"]["cpu"]
      vb.memory = settings["nodes"]["jenkins"]["memory"]
      vb.gui = false
      vb.name = "#{cluster_name}_jenkins"
    end
    jenkins.vm.provision "shell",
      env: {
        "DNS_SERVERS" => settings["network"]["dns_servers"].join(" ")
      },
      inline: <<-SHELL
        set -eu
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y qemu-guest-agent ca-certificates curl gnupg lsb-release apt-transport-https
        systemctl restart qemu-guest-agent || true
        mkdir -p /etc/systemd/resolved.conf.d
        {
          echo "[Resolve]"
          echo "DNS=${DNS_SERVERS}"
          echo "FallbackDNS=${DNS_SERVERS}"
        } > /etc/systemd/resolved.conf.d/dns_servers.conf
        systemctl restart systemd-resolved || true
        add_host_entry() {
          entry_ip="$1"
          entry_name="$2"
          if ! grep -qE "(^|[[:space:]])${entry_name}([[:space:]]|$)" /etc/hosts; then
            echo "${entry_ip} ${entry_name}" >> /etc/hosts
          fi
        }
        add_host_entry "#{settings["network"]["control_ip"]}" "controlplane"
        for i in $(seq 1 #{num_worker_nodes}); do
          add_host_entry "#{ip_network}$((#{ip_start} + i))" "node0${i}"
        done
        add_host_entry "#{settings["network"]["jenkins_ip"]}" "jenkins"
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
    # NAT remains enabled for outbound access to GitHub. This private adapter
    # gives workflow jobs access to the Kubernetes lab.
    ghaction.vm.network "private_network",
      ip: settings["network"]["github_actions_ip"]
    # Optional application port for workflow jobs.
    ghaction.vm.network "forwarded_port",
      guest: 8080,
      host: settings["network"]["github_actions_port"],
      host_ip: "127.0.0.1",
      id: "ghaction-http",
      auto_correct: true
    # Use Vagrant's SSH forwarding rule rather than declaring a second rule.
    ghaction.vm.network "forwarded_port",
      guest: 22,
      host: settings["network"]["github_actions_ssh_port"],
      host_ip: "127.0.0.1",
      id: "ssh",
      auto_correct: true
    ghaction.vm.provider "virtualbox" do |vb|
      vb.name = "#{cluster_name}_github_actions"
      vb.gui = false
      vb.cpus = settings["nodes"]["github_actions"]["cpu"]
      vb.memory = settings["nodes"]["github_actions"]["memory"]
    end
    # Prevent workflow jobs from accessing the host project directory.
    ghaction.vm.synced_folder ".", "/vagrant", disabled: true
    ghaction.vm.provision "shell",
      env: {
        "DNS_SERVERS" => settings["network"]["dns_servers"].join(" "),
        "GITHUB_PAT" => github_pat,
        "RUNNER_VERSION" => runner_settings.fetch("version").to_s,
        "RUNNER_SHA256" => runner_settings.fetch("sha256").to_s,
        "RUNNER_REPOSITORY_URL" => runner_settings.fetch("repository_url").to_s,
        "RUNNER_NAME" => runner_settings.fetch("runner_name").to_s,
        "RUNNER_LABELS" => runner_settings.fetch("labels").to_s,
        "RUNNER_WORK_FOLDER" => runner_settings.fetch("work_folder").to_s
      },
      inline: <<-SHELL
        set -eu
        export DEBIAN_FRONTEND=noninteractive
        RUNNER_DIR="/home/vagrant/actions-runner"
        if [ "$(uname -m)" != "x86_64" ]; then
          echo "ERROR: This configuration installs the x64 GitHub Actions runner." >&2
          exit 1
        fi
        apt-get update -y
        apt-get install -y ca-certificates curl git jq tar unzip
        # Configure DNS through systemd-resolved.
        mkdir -p /etc/systemd/resolved.conf.d
        {
          echo "[Resolve]"
          echo "DNS=${DNS_SERVERS}"
          echo "FallbackDNS=${DNS_SERVERS}"
        } > /etc/systemd/resolved.conf.d/dns_servers.conf
        systemctl restart systemd-resolved
        resolvectl flush-caches || true
        add_host_entry() {
          entry_ip="$1"
          entry_name="$2"
          if ! grep -qE "(^|[[:space:]])${entry_name}([[:space:]]|$)" /etc/hosts; then
            echo "${entry_ip} ${entry_name}" >> /etc/hosts
          fi
        }
        add_host_entry "#{settings["network"]["control_ip"]}" "controlplane"
        for i in $(seq 1 #{num_worker_nodes}); do
          add_host_entry "#{ip_network}$((#{ip_start} + i))" "node0${i}"
        done
        add_host_entry "#{settings["network"]["jenkins_ip"]}" "jenkins"
        add_host_entry "#{settings["network"]["github_actions_ip"]}" "githubaction"
        install -d -m 0755 -o vagrant -g vagrant "${RUNNER_DIR}"
        # Download and verify the pinned runner release once.
        if [ ! -x "${RUNNER_DIR}/config.sh" ]; then
          runner_archive="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
          runner_archive_path="/tmp/${runner_archive}"
          runner_download_url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${runner_archive}"
          curl --fail --location --retry 5 --retry-delay 2 \
            --output "${runner_archive_path}" \
            "${runner_download_url}"
          echo "${RUNNER_SHA256}  ${runner_archive_path}" | sha256sum --check -
          tar --extract --gzip --file "${runner_archive_path}" --directory "${RUNNER_DIR}"
          rm -f "${runner_archive_path}"
          chown -R vagrant:vagrant "${RUNNER_DIR}"
          "${RUNNER_DIR}/bin/installdependencies.sh"
        fi
        # Register only when this VM has not already been configured.
        if [ ! -f "${RUNNER_DIR}/.runner" ]; then
          if [ -z "${GITHUB_PAT:-}" ]; then
            echo "ERROR: No GitHub PAT was supplied." >&2
            echo "Export GITHUB_PAT in the host shell before running Vagrant." >&2
            exit 1
          fi
          repository_path="${RUNNER_REPOSITORY_URL#https://github.com/}"
          repository_path="${repository_path%/}"
          repository_path="${repository_path%.git}"
          case "${repository_path}" in
            */*) ;;
            *)
              echo "ERROR: Invalid GitHub repository URL: ${RUNNER_REPOSITORY_URL}" >&2
              exit 1
              ;;
          esac
          echo "Generating a short-lived GitHub runner registration token..."
          runner_token="$(
            curl --silent --show-error --fail-with-body \
              --request POST \
              --header "Accept: application/vnd.github+json" \
              --header "Authorization: Bearer ${GITHUB_PAT}" \
              --header "X-GitHub-Api-Version: 2026-03-10" \
              "https://api.github.com/repos/${repository_path}/actions/runners/registration-token" |
              jq -er '.token'
          )"
          # The long-lived PAT is not needed after the short-lived token exists.
          unset GITHUB_PAT
          if [ -z "${runner_token}" ]; then
            echo "ERROR: GitHub returned an empty runner registration token." >&2
            exit 1
          fi
          (
            cd "${RUNNER_DIR}"
            runuser -u vagrant -- ./config.sh \
              --url "${RUNNER_REPOSITORY_URL}" \
              --token "${runner_token}" \
              --name "${RUNNER_NAME}" \
              --labels "${RUNNER_LABELS}" \
              --work "${RUNNER_WORK_FOLDER}" \
              --unattended \
              --replace
          )
          unset runner_token
        else
          registered_url="$(jq -r '.gitHubUrl // empty' "${RUNNER_DIR}/.runner")"
          if [ "${registered_url%/}" != "${RUNNER_REPOSITORY_URL%/}" ]; then
            echo "ERROR: Runner is registered to ${registered_url}." >&2
            echo "Expected ${RUNNER_REPOSITORY_URL}." >&2
            exit 1
          fi
          echo "Runner is already registered with ${registered_url}."
        fi
        # Keep needrestart from interrupting the runner service during jobs.
        mkdir -p /etc/needrestart/conf.d
        echo '$nrconf{override_rc}{qr(^actions\\.runner\\..+\\.service$)} = 0;' \
          > /etc/needrestart/conf.d/actions_runner_services.conf
        # Install and start the runner as a systemd service.
        if [ ! -f "${RUNNER_DIR}/.service" ]; then
          (
            cd "${RUNNER_DIR}"
            ./svc.sh install vagrant
          )
        fi
        (
          cd "${RUNNER_DIR}"
          ./svc.sh start
          ./svc.sh status
        )
      SHELL
  end
end
