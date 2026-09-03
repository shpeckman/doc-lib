#!/usr/bin/env bash
# ~/bin/crystal-fresh-install.sh

set -euo pipefail
shopt -s nullglob

REPO_SOURCES=(
  'crystal_obs|https://download.opensuse.org/repositories/devel:languages:crystal/Fedora_$releasever/|https://download.opensuse.org/repositories/devel:languages:crystal/Fedora_$releasever/repodata/repomd.xml.key'
  'crystal_84codes|https://packagecloud.io/84codes/crystal/fedora/$releasever/$basearch|https://packagecloud.io/84codes/crystal/gpgkey'
  'crystal_84codes_any|https://packagecloud.io/84codes/crystal/rpm_any/rpm_any/$basearch|https://packagecloud.io/84codes/crystal/gpgkey'
)

PURGE_PACKAGES=(crystal shards)
PURGE_CACHES=("${HOME}/.cache/crystal")

BUILD_DEPS=(
  gcc
  gmp-devel
  libevent-devel
  libxml2-devel
  libyaml-devel
  openssl-devel
  pcre2-devel
  zlib-devel
)

VALIDATIONS=(
  "compiler|crystal --version"
  "shards|shards --version"
  "libxml2 headers|pkg-config --modversion libxml-2.0"
  "xml runtime|crystal eval 'require \"xml\"; print XML.parse(\"<a>ok</a>\").first_element_child.not_nil!.content'"
  "origin repo|dnf repoquery --installed --qf '%{from_repo}' crystal"
)

SUDO=""
[[ ${EUID} -eq 0 ]] || SUDO="sudo"

FEDORA_RELEASE=""
ARCH=""
WINNER_ID=""
WINNER_VERSION=""
FAILURES=0

log()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
good() { printf '    \033[1;32mok\033[0m   %s\n' "$*" >&2; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*" >&2; }
bad()  { printf '    \033[1;31mfail\033[0m %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
die()  { printf '\n\033[1;31mabort:\033[0m %s\n' "$*" >&2; exit 1; }

expand_vars() {
  local value="$1"
  value="${value//\$releasever/${FEDORA_RELEASE}}"
  value="${value//\$basearch/${ARCH}}"
  printf '%s' "${value}"
}

key_path() { printf '/etc/pki/rpm-gpg/RPM-GPG-KEY-%s' "$1"; }
repo_path() { printf '/etc/yum.repos.d/%s.repo' "$1"; }

require_fedora() {
  [[ -r /etc/os-release ]] || die "no /etc/os-release"
  . /etc/os-release
  [[ ${ID} == "fedora" ]] || die "expected Fedora, found ${ID}"
  FEDORA_RELEASE="$(rpm -E %fedora)"
  ARCH="$(rpm -E %_arch)"
  info "Fedora ${FEDORA_RELEASE} ${ARCH}"
}

inspect() {
  log "Inspecting current state"

  local installed
  installed="$(rpm -qa 'crystal*' 'shards*' | sort || true)"
  if [[ -n ${installed} ]]; then
    info "installed packages:"
    printf '      %s\n' ${installed} >&2
  else
    info "no crystal or shards packages installed"
  fi

  local repos=(/etc/yum.repos.d/*crystal*.repo)
  if ((${#repos[@]})); then
    info "crystal-related repo files:"
    printf '      %s\n' "${repos[@]}" >&2
  else
    info "no crystal-related repo files"
  fi

  local owners
  owners="$(rpm -qf /usr/bin/shards 2>/dev/null || true)"
  [[ -n ${owners} ]] && info "/usr/bin/shards owned by: ${owners}"

  info "libxml2: $(rpm -q --qf '%{VERSION}-%{RELEASE}\n' libxml2 2>/dev/null || echo 'not installed')"
}

cleanup() {
  log "Removing existing installation"

  local pkg present=() versioned
  for pkg in "${PURGE_PACKAGES[@]}"; do
    rpm -q "${pkg}" &>/dev/null && present+=("${pkg}")
  done

  versioned="$(rpm -qa --qf '%{NAME}\n' 'crystal[0-9]*' | sort -u || true)"
  [[ -n ${versioned} ]] && present+=(${versioned})

  if ((${#present[@]})); then
    info "removing: ${present[*]}"
    ${SUDO} dnf remove -y "${present[@]}"
  else
    info "nothing to remove"
  fi

  local repos=(/etc/yum.repos.d/*crystal*.repo)
  if ((${#repos[@]})); then
    info "deleting repo files: ${repos[*]}"
    ${SUDO} rm -f "${repos[@]}"
  fi

  local cache
  for cache in "${PURGE_CACHES[@]}"; do
    [[ -d ${cache} ]] && info "clearing ${cache}" && rm -rf "${cache}"
  done

  ${SUDO} dnf clean metadata >/dev/null 2>&1 || true
  good "clean slate"
}

write_repo() {
  local id="$1" base="$2" key="$3" repo_gpgcheck="$4" enabled="$5" staged
  staged="$(mktemp)"
  {
    printf '[%s]\n' "${id}"
    printf 'name=%s\n' "${id}"
    printf 'baseurl=%s\n' "${base}"
    printf 'gpgkey=file://%s\n' "${key}"
    printf 'repo_gpgcheck=%s\n' "${repo_gpgcheck}"
    printf 'gpgcheck=0\n'
    printf 'enabled=%s\n' "${enabled}"
    printf 'metadata_expire=6h\n'
  } >"${staged}"

  if grep -nvE '^(\[[A-Za-z0-9_.:-]+\]|[a-z_]+=[^[:space:]].*)$' "${staged}" >&2; then
    rm -f "${staged}"
    die "generated repo file for ${id} is malformed"
  fi

  ${SUDO} install -m 0644 "${staged}" "$(repo_path "${id}")"
  rm -f "${staged}"
}

fetch_key() {
  local id="$1" url="$2" target
  target="$(key_path "${id}")"
  if curl -fsSL --max-time 20 "$(expand_vars "${url}")" | ${SUDO} tee "${target}" >/dev/null; then
    ${SUDO} chmod 0644 "${target}"
    ${SUDO} rpm --import "${target}" 2>/dev/null || true
    return 0
  fi
  ${SUDO} rm -f "${target}"
  return 1
}

query_repo() {
  local id="$1"
  ${SUDO} dnf makecache -y --refresh --repo="${id}" >/dev/null 2>&1 || true
  dnf repoquery --repo="${id}" --qf '%{version}\n' crystal 2>/dev/null | sort -V | tail -n1
}

probe_repos() {
  log "Probing candidate repositories"

  local entry id base key version
  for entry in "${REPO_SOURCES[@]}"; do
    IFS='|' read -r id base key <<<"${entry}"

    if ! fetch_key "${id}" "${key}"; then
      warn "${id}: gpg key unreachable, skipped"
      continue
    fi

    write_repo "${id}" "${base}" "$(key_path "${id}")" 1 1
    version="$(query_repo "${id}")"

    if [[ -z ${version} ]]; then
      write_repo "${id}" "${base}" "$(key_path "${id}")" 0 1
      version="$(query_repo "${id}")"
      [[ -n ${version} ]] && warn "${id}: metadata unverified"
    fi

    if [[ -z ${version} ]]; then
      warn "${id}: no crystal package, disabling"
      write_repo "${id}" "${base}" "$(key_path "${id}")" 0 0
      continue
    fi

    info "${id}: crystal ${version}"

    if [[ -z ${WINNER_VERSION} ]] ||
      [[ "$(printf '%s\n%s\n' "${WINNER_VERSION}" "${version}" | sort -V | tail -n1)" == "${version}" ]]; then
      WINNER_VERSION="${version}"
      WINNER_ID="${id}"
    fi
  done

  [[ -n ${WINNER_ID} ]] || die "no repository offers a crystal package"
  good "selected ${WINNER_ID} at crystal ${WINNER_VERSION}"
}

disable_losers() {
  local entry id base key
  for entry in "${REPO_SOURCES[@]}"; do
    IFS='|' read -r id base key <<<"${entry}"
    [[ ${id} == "${WINNER_ID}" ]] && continue
    [[ -f "$(repo_path "${id}")" ]] || continue
    write_repo "${id}" "${base}" "$(key_path "${id}")" 0 0
    info "disabled ${id}"
  done
}

preinstall() {
  log "Installing build dependencies"
  info "${BUILD_DEPS[*]}"
  ${SUDO} dnf install -y "${BUILD_DEPS[@]}"
  good "build dependencies present"
}

install_crystal() {
  log "Installing Crystal ${WINNER_VERSION} from ${WINNER_ID}"
  ${SUDO} dnf install -y --best --setopt=install_weak_deps=False \
    --repo="${WINNER_ID}" --repo=fedora --repo=updates crystal
  good "installed"
}

validate() {
  log "Validating"

  hash -r

  local entry label command output
  for entry in "${VALIDATIONS[@]}"; do
    label="${entry%%|*}"
    command="${entry#*|}"
    if output="$(eval "${command}" 2>&1)"; then
      good "$(printf '%-15s %s' "${label}" "${output%%$'\n'*}")"
    else
      bad "$(printf '%-15s %s' "${label}" "${output%%$'\n'*}")"
    fi
  done

  local shards_owners
  shards_owners="$(rpm -qf /usr/bin/shards 2>/dev/null | wc -l)"
  if ((shards_owners > 1)); then
    bad "multiple packages own /usr/bin/shards"
  else
    good "single owner for /usr/bin/shards"
  fi
}

main() {
  require_fedora
  inspect
  cleanup
  probe_repos
  disable_losers
  preinstall
  install_crystal
  validate

  if ((FAILURES == 0)); then
    log "Done: $(crystal --version | head -n1)"
  else
    die "${FAILURES} validation step(s) failed"
  fi
}

main "$@"