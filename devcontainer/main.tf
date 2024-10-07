terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 1.0.0"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
    envbuilder = {
      source = "coder/envbuilder"
    }
  }
}

provider "coder" {}
provider "docker" {}
provider "envbuilder" {}
data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}
data "coder_external_auth" "github" {
    id = "primary-github"
}

data "coder_parameter" "repo" {
  description  = "Select an available repository to automatically clone and start working with a devcontainer."
  display_name = "Repository (auto)"
  mutable      = true
  name         = "repo"
  option {
    name        = "StudioCMS"
    icon        = "https://raw.githubusercontent.com/astrolicious/studiocms/refs/heads/main/www/assets/logo-light.svg"
    description = "The main StudioCMS monorepo at astrolicious/studiocms"
    value       = "https://github.com/astrolicious/studiocms"
  }
  order = 1
}

variable "cache_repo" {
  default     = ""
  description = "(Optional) Use a container registry as a cache to speed up builds."
  type        = string
}

variable "insecure_cache_repo" {
  default     = false
  description = "Enable this option if your cache registry does not serve HTTPS."
  type        = bool
}

variable "cache_repo_docker_config_path" {
  default     = ""
  description = "(Optional) Path to a docker config.json containing credentials to the provided cache repo, if required."
  sensitive   = true
  type        = string
}

locals {
  container_name             = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  devcontainer_builder_image = "ghcr.io/coder/envbuilder:latest"
  git_author_name            = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
  git_author_email           = data.coder_workspace_owner.me.email
  repo_url                   = data.coder_parameter.repo.value == "custom" ? data.coder_parameter.custom_repo_url.value : data.coder_parameter.repo.value
  # The envbuilder provider requires a key-value map of environment variables.
  envbuilder_env = {
    # ENVBUILDER_GIT_URL and ENVBUILDER_CACHE_REPO will be overridden by the provider
    # if the cache repo is enabled.
    "ENVBUILDER_GIT_URL" : local.repo_url,
    "ENVBUILDER_GIT_USERNAME" : data.coder_external_auth.github.access_token,
    "ENVBUILDER_CACHE_REPO" : var.cache_repo,
    "CODER_AGENT_TOKEN" : coder_agent.main.token,
    # Use the docker gateway if the access URL is 127.0.0.1
    "CODER_AGENT_URL" : replace(data.coder_workspace.me.access_url, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal"),
    # Use the docker gateway if the access URL is 127.0.0.1
    "ENVBUILDER_INIT_SCRIPT" : replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal"),
    "ENVBUILDER_FALLBACK_IMAGE" : "codercom/enterprise-base:ubuntu",
    "ENVBUILDER_DOCKER_CONFIG_BASE64" : try(data.local_sensitive_file.cache_repo_dockerconfigjson[0].content_base64, ""),
    "ENVBUILDER_PUSH_IMAGE" : var.cache_repo == "" ? "" : "true",
    "ENVBUILDER_INSECURE" : "${var.insecure_cache_repo}",
  }
  # Convert the above map to the format expected by the docker provider.
  docker_env = [
    for k, v in local.envbuilder_env : "${k}=${v}"
  ]
}

data "local_sensitive_file" "cache_repo_dockerconfigjson" {
  count    = var.cache_repo_docker_config_path == "" ? 0 : 1
  filename = var.cache_repo_docker_config_path
}

resource "docker_image" "devcontainer_builder_image" {
  name = local.devcontainer_builder_image
}

resource "docker_volume" "workspaces" {
  name = "coder-${data.coder_workspace.me.id}"
  # Protect the volume from being deleted due to changes in attributes.
  lifecycle {
    ignore_changes = all
  }
  # Add labels in Docker to keep track of orphan resources.
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  # This field becomes outdated if the workspace is renamed but can
  # be useful for debugging or cleaning out dangling volumes.
  labels {
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

# Check for the presence of a prebuilt image in the cache repo
# that we can use instead.
resource "envbuilder_cached_image" "cached" {
  count         = var.cache_repo == "" ? 0 : data.coder_workspace.me.start_count
  builder_image = local.devcontainer_builder_image
  git_url       = local.repo_url
  cache_repo    = var.cache_repo
  extra_env     = local.envbuilder_env
  insecure      = var.insecure_cache_repo
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = var.cache_repo == "" ? local.devcontainer_builder_image : envbuilder_cached_image.cached.0.image
  # Uses lower() to avoid Docker restriction on container names.
  name = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  # Hostname makes the shell more user friendly: coder@my-workspace:~$
  hostname = data.coder_workspace.me.name
  # Use the environment specified by the envbuilder provider, if available.
  env = var.cache_repo == "" ? local.docker_env : envbuilder_cached_image.cached.0.env
  # network_mode = "host" # Uncomment if testing with a registry running on `localhost`.
  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
  volumes {
    container_path = "/workspaces"
    volume_name    = docker_volume.workspaces.name
    read_only      = false
  }
  # Add labels in Docker to keep track of orphan resources.
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}

resource "coder_agent" "main" {
  arch           = data.coder_provisioner.me.arch
  os             = "linux"
  startup_script = <<-EOT
    set -e
    # Install code-server
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server

    CODESERVER=/tmp/code-server/bin/code-server

    # Install extensions for code-server
    $CODESERVER --install-extension astro-build.astro-vscode
    $CODESERVER --install-extension astro-build.houston
    $CODESERVER --install-extension biomejs.biome
    $CODESERVER --install-extension eamodio.gitlens

    # Start code-server
    $CODESERVER --auth none --port 13337 >/tmp/code-server.log 2>&1 &
  EOT
  dir            = "/workspaces"

  # These environment variables allow you to make Git commits right away after creating a
  # workspace. Note that they take precedence over configuration defined in ~/.gitconfig!
  # You can remove this block if you'd prefer to configure Git manually or using
  # dotfiles. (see docs/dotfiles.md)
  env = {
    GIT_AUTHOR_NAME     = local.git_author_name
    GIT_AUTHOR_EMAIL    = local.git_author_email
    GIT_COMMITTER_NAME  = local.git_author_name
    GIT_COMMITTER_EMAIL = local.git_author_email
  }

  # The following metadata blocks are optional. They are used to display
  # information about your workspace in the dashboard. You can remove them
  # if you don't want to display any information.
  # For basic resources, you can use the `coder stat` command.
  # If you need more control, you can write your own script.
  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $HOME"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    # get load avg scaled by number of cores
    script   = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval = 60
    timeout  = 1
  }

  metadata {
    display_name = "Swap Usage (Host)"
    key          = "7_swap_host"
    script       = <<EOT
      free -b | awk '/^Swap/ { printf("%.1f/%.1f", $3/1024.0/1024.0/1024.0, $2/1024.0/1024.0/1024.0) }'
    EOT
    interval     = 10
    timeout      = 1
  }
}

resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  url          = "http://localhost:13337/?folder=/workspaces"
  icon         = "/icon/code.svg"
  subdomain    = true
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 5
    threshold = 6
  }
}

resource "coder_metadata" "container_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = coder_agent.main.id
  item {
    key   = "workspace image"
    value = var.cache_repo == "" ? local.devcontainer_builder_image : envbuilder_cached_image.cached.0.image
  }
  item {
    key   = "git url"
    value = local.repo_url
  }
  item {
    key   = "cache repo"
    value = var.cache_repo == "" ? "not enabled" : var.cache_repo
  }
}
