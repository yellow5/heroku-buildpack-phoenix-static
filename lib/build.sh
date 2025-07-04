cleanup_cache() {
  if [ $clean_cache = true ]; then
    info "clean_cache option set to true."
    info "Cleaning out cache contents"
    rm -rf $cache_dir/npm-version
    rm -rf $cache_dir/node-version
    rm -rf $cache_dir/phoenix-static
    rm -rf $cache_dir/yarn-cache
    rm -rf $cache_dir/node_modules
    cleanup_old_node
  fi
}

load_previous_npm_node_versions() {
  if [ -f $cache_dir/npm-version ]; then
    old_npm=$(<$cache_dir/npm-version)
  fi
  if [ -f $cache_dir/npm-version ]; then
    old_node=$(<$cache_dir/node-version)
  fi
}

resolve_node() {
  echo "Resolving node version $node_version..."

  local base_url="https://nodejs.org/dist"
  local lookup_url=""

  case "$node_version" in
    ""|latest) lookup_url="${base_url}/latest/" ;;
    v*)        lookup_url="${base_url}/${node_version}/" ;;
    *)         lookup_url="${base_url}/v${node_version}/" ;;
  esac

  # ── 1. Pull the *href* value that contains the Linux-x64 tarball ──
  local node_path
  node_path=$(
    curl -sSfL --retry 5 --retry-max-time 15 "$lookup_url" \
      | grep -Eo -m1 '/dist[^"]*node-v[0-9]+\.[0-9]+\.[0-9]+-linux-x64\.tar\.gz'
  )

  if [ "$?" -eq 0 ] && [ -n "$node_path" ]; then
    # ── 2. Extract bare filename from the path ──
    local node_file=${node_path##*/}

    # ── 3. Derive the version number & final download URL ──
    local number=${node_file#node-v}; number=${number%-linux-x64.tar.gz}
    url="${base_url}/v${number}/${node_file}"
  else
    fail_bin_install node "$node_version"
  fi
}

download_node() {
  local platform=linux-x64

  if [ ! -f ${cached_node} ]; then
    echo "Resolving node version $node_version..."
    resolve_node

    echo "Downloading and installing node $number..."
    local code=$(curl "$url" -L --silent --fail --retry 5 --retry-max-time 15 -o ${cached_node} --write-out "%{http_code}")
    if [ "$code" != "200" ]; then
      echo "Unable to download node: $code" && false
    fi
  else
    info "Using cached node ${node_version}..."
  fi
}

cleanup_old_node() {
  local old_node_dir=$cache_dir/node-$old_node-linux-x64.tar.gz

  # Note that $old_node will have a format of "v5.5.0" while $node_version
  # has the format "5.6.0"

  if [ $clean_cache = true ] || [ $old_node != v$node_version ] && [ -f $old_node_dir ]; then
    info "Cleaning up old Node $old_node"
    rm $old_node_dir

    local bower_components_dir=$cache_dir/bower_components

    if [ -d $bower_components_dir ]; then
      rm -rf $bower_components_dir
    fi
  fi
}

install_node() {
  info "Installing Node $node_version..."
  tar xzf ${cached_node} -C /tmp
  local node_dir=$heroku_dir/node

  if [ -d $node_dir ]; then
    echo " !     Error while installing Node $node_version."
    echo "       Please remove any prior buildpack that installs Node."
    exit 1
  else
    mkdir -p $node_dir
    # Move node (and npm) into .heroku/node and make them executable
    mv /tmp/node-v$node_version-linux-x64/* $node_dir
    chmod +x $node_dir/bin/*
    PATH=$node_dir/bin:$PATH
  fi
}

install_npm() {
  # Optionally bootstrap a different npm version
  if [ ! $npm_version ] || [[ `npm --version` == "$npm_version" ]]; then
    info "Using default npm version `npm --version`"
  else
    info "Downloading and installing npm $npm_version (replacing version `npm --version`)..."
    cd $build_dir
    npm install --unsafe-perm --quiet -g npm@$npm_version 2>&1 >/dev/null | indent
  fi
}

install_yarn() {
  local dir="$1"

  if [ ! $yarn_version ]; then
    echo "Downloading and installing yarn lastest..."
    local download_url="https://yarnpkg.com/latest.tar.gz"
  else
    echo "Downloading and installing yarn $yarn_version..."
    local download_url="https://yarnpkg.com/downloads/$yarn_version/yarn-v$yarn_version.tar.gz"
  fi

  local code=$(curl "$download_url" -L --silent --fail --retry 5 --retry-max-time 15 -o /tmp/yarn.tar.gz --write-out "%{http_code}")
  if [ "$code" != "200" ]; then
    echo "Unable to download yarn: $code" && false
  fi
  rm -rf $dir
  mkdir -p "$dir"
  # https://github.com/yarnpkg/yarn/issues/770
  if tar --version | grep -q 'gnu'; then
    tar xzf /tmp/yarn.tar.gz -C "$dir" --strip 1 --warning=no-unknown-keyword
  else
    tar xzf /tmp/yarn.tar.gz -C "$dir" --strip 1
  fi
  chmod +x $dir/bin/*
  PATH=$dir/bin:$PATH
  echo "Installed yarn $(yarn --version)"
}

install_and_cache_deps() {
  cd $assets_dir

  if [ -d $cache_dir/node_modules ]; then
    info "Loading node modules from cache"
    mkdir node_modules
    cp -R $cache_dir/node_modules/* node_modules/
  fi

  info "Installing node modules"
  if [ -f "$assets_dir/yarn.lock" ]; then
    install_yarn_deps
  else
    install_npm_deps
  fi

  if [ -d node_modules ]; then
    info "Caching node modules"
    cp -R node_modules $cache_dir
  fi

  PATH=$assets_dir/node_modules/.bin:$PATH

  install_bower_deps
}

install_npm_deps() {
  npm prune | indent
  npm install --quiet --unsafe-perm --userconfig $build_dir/npmrc 2>&1 | indent
  npm rebuild 2>&1 | indent
  npm --unsafe-perm prune 2>&1 | indent
}

install_yarn_deps() {
  yarn install --check-files --cache-folder $cache_dir/yarn-cache --pure-lockfile 2>&1
}

install_bower_deps() {
  cd $assets_dir
  local bower_json=bower.json

  if [ -f $bower_json ]; then
    info "Installing and caching bower components"

    if [ -d $cache_dir/bower_components ]; then
      mkdir -p bower_components
      cp -r $cache_dir/bower_components/* bower_components/
    fi
    bower install
    cp -r bower_components $cache_dir
  fi
}

compile() {
  cd $phoenix_dir
  PATH=$build_dir/.platform_tools/erlang/bin:$PATH
  PATH=$build_dir/.platform_tools/elixir/bin:$PATH

  run_compile
}

run_compile() {
  local custom_compile="${build_dir}/${compile}"

  cd $phoenix_dir

  has_clean=$(mix help "${phoenix_ex}.digest.clean" 1>/dev/null 2>&1; echo $?)

  if [ $has_clean = 0 ]; then
    mkdir -p $cache_dir/phoenix-static
    info "Restoring cached assets"
    mkdir -p priv
    rsync -a -v --ignore-existing $cache_dir/phoenix-static/ priv/static
  fi

  cd $assets_dir

  if [ -f $custom_compile ]; then
    info "Running custom compile"
    source $custom_compile 2>&1 | indent
  else
    info "Running default compile"
    source ${build_pack_dir}/${compile} 2>&1 | indent
  fi

  cd $phoenix_dir

  if [ $has_clean = 0 ]; then
    info "Caching assets"
    rsync -a --delete -v priv/static/ $cache_dir/phoenix-static
  fi
}

cache_versions() {
  info "Caching versions for future builds"
  echo `node --version` > $cache_dir/node-version
  echo `npm --version` > $cache_dir/npm-version
}

finalize_node() {
  if [ $remove_node = true ]; then
    remove_node
  else
    write_profile
  fi
}

write_profile() {
  info "Creating runtime environment"
  mkdir -p $build_dir/.profile.d
  local export_line="export PATH=\"\$HOME/.heroku/node/bin:\$HOME/.heroku/yarn/bin:\$HOME/bin:\$HOME/$phoenix_relative_path/node_modules/.bin:\$PATH\""
  echo $export_line >> $build_dir/.profile.d/phoenix_static_buildpack_paths.sh
}

remove_node() {
  info "Removing node and node_modules"
  rm -rf $assets_dir/node_modules
  rm -rf $heroku_dir/node
}
