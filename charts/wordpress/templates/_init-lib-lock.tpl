{{- define "wordpress.init-lib-lock" -}}
#!/bin/bash
# WordPress Helm Chart - Database Lock Library
# Provides distributed locking for multi-pod deployments
#
# Heartbeat-based locking:
#   - Lock holder runs a background heartbeat (updates timestamp every 15s)
#   - Waiters check: was lock updated in last 60s?
#   - If no heartbeat for 60s → pod crashed → lock is stale
#   - Same hostname (pod restart): Lock immediately overridden
#   - Lock format: hostname-timestamp

BOOTSTRAP_LOCK_ACQUIRED=false
CONFIG_LOCK_ACQUIRED=false
HEARTBEAT_PID=""
readonly HEARTBEAT_INTERVAL=15  # Seconds between heartbeat updates
readonly STALE_THRESHOLD=60     # Seconds without heartbeat before lock is considered stale
readonly MAX_LOCK_WAIT=600      # Absolute max wait time in seconds (safety net)

# Start heartbeat for a lock - updates timestamp every HEARTBEAT_INTERVAL seconds
# Uses lightweight PHP directly instead of wp-cli to avoid resource contention
# Args: $1 = lock type ("bootstrap" or "config")
_start_heartbeat() {
  local lock_type="$1"
  local pod_hostname="$(hostname)"

  # Kill any existing heartbeat first
  _stop_heartbeat

  if [ "$lock_type" = "bootstrap" ]; then
    (
      while true; do
        sleep $HEARTBEAT_INTERVAL
        HEARTBEAT_TABLE="${TABLE_PREFIX}helm_locks" HEARTBEAT_HOSTNAME="${pod_hostname}" HEARTBEAT_TYPE="bootstrap" php -r '
          $m = @new mysqli(getenv("WORDPRESS_DB_HOST"), getenv("WORDPRESS_DB_USER"), getenv("WORDPRESS_DB_PASSWORD"), getenv("WORDPRESS_DB_NAME"));
          if(!$m->connect_error) {
            $t=time(); $h=getenv("HEARTBEAT_HOSTNAME"); $tbl=getenv("HEARTBEAT_TABLE");
            $m->query("UPDATE {$tbl} SET lock_value=\"" . $m->real_escape_string("{$h}-{$t}") . "\" WHERE lock_name=\"bootstrap\" AND lock_value LIKE \"" . $m->real_escape_string($h) . "-%\"");
            $m->close();
          }
        ' 2>/dev/null || true
      done
    ) &
  else
    (
      while true; do
        sleep $HEARTBEAT_INTERVAL
        HEARTBEAT_TABLE="${TABLE_PREFIX}options" HEARTBEAT_HOSTNAME="${pod_hostname}" php -r '
          $m = @new mysqli(getenv("WORDPRESS_DB_HOST"), getenv("WORDPRESS_DB_USER"), getenv("WORDPRESS_DB_PASSWORD"), getenv("WORDPRESS_DB_NAME"));
          if(!$m->connect_error) {
            $t=time(); $h=getenv("HEARTBEAT_HOSTNAME"); $tbl=getenv("HEARTBEAT_TABLE");
            $m->query("UPDATE {$tbl} SET option_value=\"" . $m->real_escape_string("{$h}-{$t}") . "\" WHERE option_name=\"_helm_config_lock\" AND option_value LIKE \"" . $m->real_escape_string($h) . "-%\"");
            $m->close();
          }
        ' 2>/dev/null || true
      done
    ) &
  fi
  HEARTBEAT_PID=$!
  [ "${DEBUG}" = "true" ] && echo "DEBUG: Heartbeat started (PID: $HEARTBEAT_PID) for $lock_type lock" >&2
}

# Stop the heartbeat background process
_stop_heartbeat() {
  if [ -n "$HEARTBEAT_PID" ]; then
    kill $HEARTBEAT_PID 2>/dev/null || true
    wait $HEARTBEAT_PID 2>/dev/null || true
    [ "${DEBUG}" = "true" ] && echo "DEBUG: Heartbeat stopped (PID: $HEARTBEAT_PID)" >&2
    HEARTBEAT_PID=""
  fi
}

# Attempt to claim bootstrap lock using dedicated helm_locks table
# This is used BEFORE WordPress installation when wp_options doesn't exist yet
#
# Returns:
#   0 - Lock successfully claimed (heartbeat started)
#   1 - Lock held by another pod (after retries)
#
# Heartbeat: Lock holder updates timestamp every 15s.
# Waiters check: no heartbeat for 60s → lock is stale → override.
claim_bootstrap_lock() {
  local retry_interval=10
  local retry_count=0
  local max_retries=$((MAX_LOCK_WAIT / retry_interval))
  local pod_hostname="$(hostname)"
  local current_time=$(date +%s)

  echo "Attempting to claim bootstrap lock (for WordPress installation)..."
  [ "${DEBUG}" = "true" ] && echo "DEBUG: Pod hostname: $pod_hostname" >&2

  while [ $retry_count -lt $max_retries ]; do
    current_time=$(date +%s)

    # Use raw PHP to create the table and attempt to claim the lock atomically
    # This bypasses WP-CLI completely, preventing the 'wp-config.php not found' error
    LOCK_TBL="${TABLE_PREFIX}helm_locks" \
    POD_HOST="${pod_hostname}" \
    CUR_TIME="${current_time}" \
    STALE="${STALE_THRESHOLD}" \
    php -r '
      $m = @new mysqli(getenv("WORDPRESS_DB_HOST"), getenv("WORDPRESS_DB_USER"), getenv("WORDPRESS_DB_PASSWORD"), getenv("WORDPRESS_DB_NAME"));
      if(!$m->connect_error) {
        $tbl = getenv("LOCK_TBL");
        $host = $m->real_escape_string(getenv("POD_HOST"));
        $time = (int)getenv("CUR_TIME");
        $stale = (int)getenv("STALE");

        // 1. Ensure helm_locks table exists
        $m->query("CREATE TABLE IF NOT EXISTS {$tbl} (
          lock_name VARCHAR(64) PRIMARY KEY,
          lock_value VARCHAR(255) NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )");

        // 2. Atomic lock claim: override if same hostname OR lock is stale
        $val = "{$host}-{$time}";
        $m->query("INSERT INTO {$tbl} (lock_name, lock_value) VALUES (\"bootstrap\", \"{$val}\")
          ON DUPLICATE KEY UPDATE
            lock_value = IF(
              lock_value LIKE \"{$host}-%\" OR CAST(SUBSTRING_INDEX(lock_value, \"-\", -1) AS UNSIGNED) < {$time} - {$stale},
              \"{$val}\",
              lock_value
            )");
        $m->close();
      }
    ' 2>/dev/null || true

    sleep 0.1

    # Read back the lock owner using raw PHP
    local lock_owner=$(
      LOCK_TBL="${TABLE_PREFIX}helm_locks" \
      php -r '
        $m = @new mysqli(getenv("WORDPRESS_DB_HOST"), getenv("WORDPRESS_DB_USER"), getenv("WORDPRESS_DB_PASSWORD"), getenv("WORDPRESS_DB_NAME"));
        if(!$m->connect_error) {
          $tbl = getenv("LOCK_TBL");
          $res = $m->query("SELECT lock_value FROM {$tbl} WHERE lock_name=\"bootstrap\"");
          if($res && $row = $res->fetch_assoc()) {
            echo $row["lock_value"];
          }
          $m->close();
        }
      ' 2>/dev/null || echo ""
    )

    if [[ "$lock_owner" == "$pod_hostname-$current_time" ]]; then
      echo "Bootstrap lock acquired successfully!"
      BOOTSTRAP_LOCK_ACQUIRED=true
      _start_heartbeat "bootstrap"
      return 0
    fi

    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $max_retries ]; then
      local wait_time=$((retry_count * retry_interval))
      echo "Another pod is installing WordPress, waiting... (${wait_time}s)"
      sleep $retry_interval
    fi
  done

  echo "ERROR: Timeout waiting for bootstrap lock after ${MAX_LOCK_WAIT}s"
  return 1
}

# Release bootstrap lock and stop heartbeat
release_bootstrap_lock() {
  if [ "$BOOTSTRAP_LOCK_ACQUIRED" = "true" ]; then
    _stop_heartbeat
    [ "${DEBUG}" = "true" ] && echo "DEBUG: Releasing bootstrap lock" >&2
    local pod_hostname="$(hostname)"
    # Direct PHP for fast release (no WordPress bootstrap overhead)
    php -r "\$m = @new mysqli('${WORDPRESS_DB_HOST}', '${WORDPRESS_DB_USER}', '${WORDPRESS_DB_PASSWORD}', '${WORDPRESS_DB_NAME}'); if(!\$m->connect_error) { \$m->query(\"DELETE FROM ${TABLE_PREFIX}helm_locks WHERE lock_name='bootstrap' AND lock_value LIKE '${pod_hostname}-%'\"); \$m->close(); }" 2>/dev/null || true
    BOOTSTRAP_LOCK_ACQUIRED=false
    echo "Bootstrap lock released!"
  fi
}

# Attempt to claim configuration lock using wp_options table
# This is used AFTER WordPress installation for plugin/theme/config management
#
# Returns:
#   0 - Lock successfully claimed (heartbeat started)
#   1 - Lock held by another pod (after retries)
#
# Heartbeat: Lock holder updates timestamp every 15s.
# Waiters check: no heartbeat for 60s → lock is stale → override.
claim_config_lock() {
  local retry_interval=10
  local retry_count=0
  local max_retries=$((MAX_LOCK_WAIT / retry_interval))
  local pod_hostname="$(hostname)"
  local current_time=$(date +%s)

  [ "${DEBUG}" = "true" ] && echo "DEBUG: Attempting config lock, hostname: $pod_hostname" >&2

  while [ $retry_count -lt $max_retries ]; do
    current_time=$(date +%s)

    # Atomic lock claim: override if same hostname OR no heartbeat for STALE_THRESHOLD seconds
    wp db query "
      INSERT INTO ${TABLE_PREFIX}options (option_name, option_value, autoload)
      VALUES ('_helm_config_lock', '$pod_hostname-$current_time', 'no')
      ON DUPLICATE KEY UPDATE
        option_value = IF(
          option_value LIKE '$pod_hostname-%'
          OR CAST(SUBSTRING_INDEX(option_value, '-', -1) AS UNSIGNED) < $current_time - $STALE_THRESHOLD,
          '$pod_hostname-$current_time',
          option_value
        );
    " >/dev/null 2>&1

    sleep 0.1

    # Check if we got the lock
    local lock_owner=$(wp db query "SELECT option_value FROM ${TABLE_PREFIX}options WHERE option_name='_helm_config_lock';" --skip-column-names 2>/dev/null || echo "")

    if [[ "$lock_owner" == "$pod_hostname-$current_time" ]]; then
      CONFIG_LOCK_ACQUIRED=true
      _start_heartbeat "config"
      [ "${DEBUG}" = "true" ] && echo "DEBUG: Pod $pod_hostname claimed config lock" >&2
      return 0
    fi

    # Lock held by another pod with fresh heartbeat
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $max_retries ]; then
      local wait_time=$((retry_count * retry_interval))
      echo "Another pod is running init process, waiting... (${wait_time}s)"
      sleep $retry_interval
    fi
  done

  [ "${DEBUG}" = "true" ] && echo "DEBUG: Timeout waiting for config lock after ${MAX_LOCK_WAIT}s" >&2
  return 1
}

# Release the configuration lock and stop heartbeat
release_config_lock() {
  if [ "$CONFIG_LOCK_ACQUIRED" = "true" ]; then
    _stop_heartbeat
    [ "${DEBUG}" = "true" ] && echo "DEBUG: Releasing config lock" >&2
    local pod_hostname="$(hostname)"
    # Direct PHP for fast release (no WordPress bootstrap overhead)
    php -r "\$m = @new mysqli('${WORDPRESS_DB_HOST}', '${WORDPRESS_DB_USER}', '${WORDPRESS_DB_PASSWORD}', '${WORDPRESS_DB_NAME}'); if(!\$m->connect_error) { \$m->query(\"DELETE FROM ${TABLE_PREFIX}options WHERE option_name='_helm_config_lock' AND option_value LIKE '${pod_hostname}-%'\"); \$m->close(); }" 2>/dev/null || true
    CONFIG_LOCK_ACQUIRED=false
    echo "Config lock released!"
  fi
}
{{- end -}}
