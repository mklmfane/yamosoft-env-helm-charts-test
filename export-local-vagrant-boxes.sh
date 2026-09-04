#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./export-local-vagrant-boxes.sh [--force] [--source DIR] [--destination DIR]

Exports every box reported by `vagrant box list` into a repository-local
vagrant-boxes directory, writes SHA-256 files, and creates versioned catalogs.

Options:
  --source DIR       Copy already-exported .box files from DIR first.
                     Default: /srv/vagrant-boxes
  --destination DIR  Destination. Default: <repository>/vagrant-boxes
  --force            Repackage and replace existing archives.
  -h, --help         Show this help.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

slugify() {
  printf '%s' "$1" | sed -E 's#_#-#g; s#[^[:alnum:].-]+#-#g; s#^-+##; s#-+$##'
}

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source_dir="/srv/vagrant-boxes"
destination_dir="${repo_root}/vagrant-boxes"
force=0

while (($#)); do
  case "$1" in
    --source)
      (($# >= 2)) || die "--source requires a directory"
      source_dir="$2"
      shift 2
      ;;
    --destination)
      (($# >= 2)) || die "--destination requires a directory"
      destination_dir="$2"
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

for command_name in vagrant ruby sha256sum tar awk sed find sort mktemp df du cp mv; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: ${command_name}"
done

mkdir -p "$destination_dir" "$destination_dir/catalogs"
destination_dir="$(cd -- "$destination_dir" && pwd -P)"

info "Repository root: ${repo_root}"
info "Box destination: ${destination_dir}"

# Preserve already-repackaged artifacts without removing the originals.
if [[ -d "$source_dir" && "$(cd -- "$source_dir" && pwd -P)" != "$destination_dir" ]]; then
  info "Copying existing box archives from ${source_dir}"
  while IFS= read -r -d '' existing_box; do
    target="${destination_dir}/$(basename -- "$existing_box")"
    if [[ ! -e "$target" || $force -eq 1 ]]; then
      cp --reflink=auto --sparse=always -- "$existing_box" "$target"
    fi
  done < <(find "$source_dir" -type f -name '*.box' -print0)
fi

mapfile -t box_lines < <(vagrant box list | sed '/^[[:space:]]*$/d')
((${#box_lines[@]} > 0)) || die "no locally installed Vagrant boxes were found"

cache_kib="$(du -sk "${VAGRANT_HOME:-$HOME/.vagrant.d}/boxes" 2>/dev/null | awk '{print $1}' || true)"
available_kib="$(df -Pk "$destination_dir" | awk 'NR == 2 {print $4}')"
if [[ "$cache_kib" =~ ^[0-9]+$ && "$available_kib" =~ ^[0-9]+$ ]]; then
  # Repackaged boxes are usually compressed, but reserve the full cache size
  # plus ten percent so that failure happens before a filesystem is filled.
  required_kib=$((cache_kib + cache_kib / 10))
  if ((available_kib < required_kib)); then
    die "insufficient space: need approximately $((required_kib / 1024 / 1024)) GiB; have $((available_kib / 1024 / 1024)) GiB"
  fi
fi

manifest="$(mktemp)"
work_dir="$(mktemp -d)"
cleanup() {
  rm -f -- "$manifest"
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

for line in "${box_lines[@]}"; do
  if [[ ! "$line" =~ ^(.+)[[:space:]]+\(([^,]+),[[:space:]]*([^,\)]+)(,[[:space:]]*\(([^\)]+)\))?\)$ ]]; then
    printf 'WARNING: unable to parse and skipping: %s\n' "$line" >&2
    continue
  fi

  box_name="${BASH_REMATCH[1]}"
  box_name="$(printf '%s' "$box_name" | sed -E 's/[[:space:]]+$//')"
  provider="${BASH_REMATCH[2]}"
  version="${BASH_REMATCH[3]}"
  architecture="${BASH_REMATCH[5]:-amd64}"

  name_slug="$(slugify "$box_name")"
  filename="${name_slug}-${version}-${provider}-${architecture}.box"
  archive="${destination_dir}/${filename}"

  if [[ -s "$archive" && $force -eq 0 ]]; then
    info "Keeping existing ${filename}"
  else
    info "Repackaging ${box_name} (${provider}, ${version}, ${architecture})"
    rm -f -- "$work_dir/package.box"
    (
      cd -- "$work_dir"
      vagrant box repackage "$box_name" "$provider" "$version"
    )
    [[ -s "$work_dir/package.box" ]] || die "Vagrant did not create package.box for ${box_name}"
    mv -- "$work_dir/package.box" "$archive"
  fi

  tar -tf "$archive" >/dev/null || die "invalid box archive: ${archive}"
  checksum="$(sha256sum "$archive" | awk '{print $1}')"
  printf '%s  %s\n' "$checksum" "$filename" > "${archive}.sha256"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$box_name" "$provider" "$version" "$architecture" "$filename" "$checksum" >> "$manifest"
done

[[ -s "$manifest" ]] || die "no boxes were exported"

# Create one Vagrant catalog per logical box. Ruby is available because
# Vagrant itself uses Ruby; using it here avoids an additional jq dependency.
ruby -rjson -e '
  destination, manifest = ARGV
  rows = File.readlines(manifest, chomp: true).map { |line| line.split("\t", 6) }
  rows.group_by(&:first).each do |name, box_rows|
    versions = box_rows.group_by { |row| row[2] }.sort.to_h.map do |version, version_rows|
      {
        "version" => version,
        "providers" => version_rows.map do |_box_name, provider, _version, architecture, filename, checksum|
          {
            "name" => provider,
            "architecture" => architecture,
            "default_architecture" => true,
            "url" => "file://#{File.join(destination, filename)}",
            "checksum_type" => "sha256",
            "checksum" => checksum
          }
        end
      }
    end
    slug = name.gsub(/[^A-Za-z0-9._-]+/, "-").sub(/^-+/, "").sub(/-+$/, "")
    catalog = {
      "name" => name,
      "description" => "Locally hosted Vagrant box #{name}",
      "versions" => versions
    }
    File.write(File.join(destination, "catalogs", "#{slug}.json"), JSON.pretty_generate(catalog) + "\n")
  end
' "$destination_dir" "$manifest"

info "Verifying checksums"
(
  cd -- "$destination_dir"
  while IFS= read -r checksum_file; do
    sha256sum --check "$(basename -- "$checksum_file")"
  done < <(find "$destination_dir" -maxdepth 1 -type f -name '*.box.sha256' | sort)
)

info "Export completed"
find "$destination_dir" -maxdepth 2 -type f \
  \( -name '*.box' -o -name '*.box.sha256' -o -name '*.json' \) \
  -printf '%p\t%k KB\n' | sort
