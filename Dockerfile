# Proof repo: MariaDB for ERPNext as a Render private service, with the datadir on a
# persistent disk and an entrypoint that reconciles secrets on every boot (X11).
#
# ERPNext v16 has no PostgreSQL support and Render has no managed MariaDB, so the database
# stays a container. Pinned to the LTS the app image is built against.
FROM mariadb:10.6

# mariadb's own entrypoint is a set of shell functions plus a `_is_sourced` guard, so sourcing
# it gives us docker_process_sql / docker_gosu without re-implementing the install path.
COPY docker/entrypoint.sh /opt/render/entrypoint.sh
RUN chmod 0755 /opt/render/entrypoint.sh

# The settings ERPNext cannot run without - the port and the utf8mb4 character set and collation -
# plus skip-innodb-read-only-compressed, which is a measured no-op today and kept for parity with
# frappe_docker. /etc/mysql/my.cnf !includedirs conf.d *last*, so this file outranks Debian's own
# defaults, and a command-line flag still outranks this file. It is in the image rather than in
# render.yaml's dockerCommand because a service hand-created in the dashboard inherits no
# dockerCommand at all (X9, measured on the first Render deploy).
COPY docker/render.cnf /etc/mysql/conf.d/render.cnf

# The datadir. Render mounts a disk here; everything outside it is gone on every deploy.
ENV MARIADB_DATA_DIR=/var/lib/mysql

# Not secrets, not per-plan: the schema name and the account Frappe logs in as are constants of
# this stack, and render.yaml sets the same two values. They are baked here for the same reason as
# render.cnf - the image reads them *only* while the datadir is empty, so a hand-created service
# that omits them gets one unrepeatable boot that initializes a database with no user and no
# schema and still reports "live" (X9, measured). What must still come from the dashboard is
# MARIADB_PASSWORD and MARIADB_ROOT_PASSWORD; docker/entrypoint.sh refuses to boot without them.
ENV MARIADB_DATABASE=erpnext \
    MARIADB_USER=erpnext

ENTRYPOINT ["/opt/render/entrypoint.sh"]
CMD ["mariadbd", "--console"]
