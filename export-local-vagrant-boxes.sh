#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./export-local-vagrant-boxes.sh [--force] [--destination DIR]

Exports every box reported by `vagrant box list` into a local box repository,
writes SHA-256 files, and creates versioned catalogs.

Options:
  --destination DIR  Destination. Default: /srv/vagrant-boxes
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

destination_dir="/srv/vagrant-boxes"
force=0

while (($#)); do
  case "$1" in
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

info "Local box repository: ${destination_dir}"

# Adopt the libvirt archive created by the documented manual procedure. A
# generic package.box has no identity, so only this known path can be mapped
# safely without rebuilding it.
legacy_libvirt="${destination_dir}/jtarpley-ubuntu2404/package.box"
legacy_libvirt_target="${destination_dir}/jtarpley-ubuntu2404/jtarpley-ubuntu2404-base-2025.11.12-libvirt-amd64.box"
if [[ -s "$legacy_libvirt" ]]; then
  if [[ ! -e "$legacy_libvirt_target" ]]; then
    info "Renaming existing jtarpley libvirt package.box"
    mv -- "$legacy_libvirt" "$legacy_libvirt_target"
  elif [[ "$(sha256sum "$legacy_libvirt" | awk '{print $1}')" == "$(sha256sum "$legacy_libvirt_target" | awk '{print $1}')" ]]; then
    info "Removing duplicate jtarpley package.box"
    rm -f -- "$legacy_libvirt"
  else
    legacy_conflict="${legacy_libvirt}.conflict.$(date +%s)"
    printf 'WARNING: preserving different package.box as %s\n' "$legacy_conflict" >&2
    mv -- "$legacy_libvirt" "$legacy_conflict"
  fi
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
  archive_dir="${destination_dir}/${name_slug}"
  mkdir -p "$archive_dir"
  filename="${name_slug}-${version}-${provider}-${architecture}.box"
  archive="${archive_dir}/${filename}"

  # Recover archives created by the earlier flat-layout version of this
  # script. Valid files are moved into the per-box directory. Truncated files
  # are retained with an .invalid suffix so they cannot be mistaken for boxes.
  flat_archive="${destination_dir}/${filename}"
  if [[ -s "$flat_archive" && ! -e "$archive" ]]; then
    if tar -tf "$flat_archive" >/dev/null 2>&1; then
      info "Adopting valid flat-layout archive ${filename}"
      mv -- "$flat_archive" "$archive"
      [[ -f "${flat_archive}.sha256" ]] && rm -f -- "${flat_archive}.sha256"
    else
      invalid_archive="${flat_archive}.invalid"
      [[ -e "$invalid_archive" ]] && invalid_archive="${flat_archive}.invalid.$(date +%s)"
      printf 'WARNING: quarantining truncated archive as %s\n' "$invalid_archive" >&2
      mv -- "$flat_archive" "$invalid_archive"
      [[ -f "${flat_archive}.sha256" ]] && mv -- "${flat_archive}.sha256" "${invalid_archive}.sha256"
    fi
  fi

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
  relative_archive="${name_slug}/${filename}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$box_name" "$provider" "$version" "$architecture" "$relative_archive" "$checksum" >> "$manifest"
done

[[ -s "$manifest" ]] || die "no boxes were exported"

# Remove legacy or manually created duplicate archives only when their content
# exactly matches a canonical archive recorded in this run. Canonical archives
# are never removed, even if two legitimate provider/version entries happen to
# have identical content.
declare -A canonical_paths=()
declare -A canonical_checksums=()
while IFS=$'\t' read -r _box_name _provider _version _architecture relative_archive checksum; do
  canonical_paths["${destination_dir}/${relative_archive}"]=1
  canonical_checksums["$checksum"]="${destination_dir}/${relative_archive}"
done < "$manifest"

info "Checking for duplicate box archives"
while IFS= read -r -d '' candidate; do
  [[ -n "${canonical_paths[$candidate]:-}" ]] && continue
  candidate_checksum="$(sha256sum "$candidate" | awk '{print $1}')"
  canonical_match="${canonical_checksums[$candidate_checksum]:-}"
  if [[ -n "$canonical_match" ]]; then
    info "Removing duplicate ${candidate}; canonical copy is ${canonical_match}"
    rm -f -- "$candidate" "${candidate}.sha256"
  fi
done < <(find "$destination_dir" -type f -name '*.box' -print0)

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
while IFS= read -r checksum_file; do
  (
    cd -- "$(dirname -- "$checksum_file")"
    sha256sum --check "$(basename -- "$checksum_file")"
  )
done < <(find "$destination_dir" -mindepth 2 -maxdepth 2 -type f -name '*.box.sha256' | sort)

info "Export completed"
find "$destination_dir" -maxdepth 3 -type f \
  \( -name '*.box' -o -name '*.box.sha256' -o -name '*.json' \) \
  -printf '%p\t%k KB\n' | sort
