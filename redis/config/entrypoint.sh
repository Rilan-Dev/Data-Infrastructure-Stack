#!/bin/sh
set -e

# Redis Entrypoint with Dynamic ACL Generation
# Generates users.acl with proper password hashes from environment variables
# Writes to /tmp/users.acl (tmpfs, always writable)

# Function to generate Redis ACL password hash
# Redis 7 uses SHA-256: HEX(SHA256(password))
gen_hash() {
    printf "%s" "$1" | sha256sum | awk '{print $1}'
}

ACL_FILE="/tmp/users.acl"

# Generate ACL file with actual password hashes
if [ -n "$REDIS_ADMIN_PASSWORD" ]; then
    ADMIN_HASH=$(gen_hash "$REDIS_ADMIN_PASSWORD")
    cat > "$ACL_FILE" <<EOF
user admin on #$ADMIN_HASH ~* +@all
user default off
EOF
fi

# Add project users if passwords are set (lowercase project names)
for proj in a b c d e; do
    pw_var="REDIS_PROJECT_$(echo $proj | tr '[:lower:]' '[:upper:]')_PASSWORD"
    eval pw=\$$pw_var
    if [ -n "$pw" ]; then
        hash=$(gen_hash "$pw")
        cat >> "$ACL_FILE" <<EOF
user project_${proj} on #$hash ~project-${proj}:* +@read +@write +@list +@set +@sortedset +@hash +@stream +@pubsub +@keyspace +@string +@connection -@dangerous -@admin
EOF
    fi
done

# Add OmniRoute user if password set (scoped to the omniroute: key namespace)
if [ -n "$REDIS_OMNIROUTE_PASSWORD" ]; then
    omni_hash=$(gen_hash "$REDIS_OMNIROUTE_PASSWORD")
    cat >> "$ACL_FILE" <<EOF
user omniroute on #$omni_hash ~omniroute:* +@read +@write +@list +@set +@sortedset +@hash +@stream +@pubsub +@keyspace +@string +@connection +@scripting -@dangerous -@admin
EOF
fi

# Add readonly user if password set
if [ -n "$REDIS_READONLY_PASSWORD" ]; then
    ro_hash=$(gen_hash "$REDIS_READONLY_PASSWORD")
    cat >> "$ACL_FILE" <<EOF
user readonly on #$ro_hash ~* +@read -@dangerous -@admin -@connection -@write
EOF
fi

# Original entrypoint logic without chown
if [ "$1" = "redis-server" ]; then
    shift
    exec redis-server "$@"
fi

exec "$@"