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

# The settings ERPNext cannot run without - port 10000, utf8mb4/unicode_ci, and
# skip-innodb-read-only-compressed. /etc/mysql/my.cnf !includedirs conf.d *last*, so this file
# outranks Debian's own defaults, and a command-line flag still outranks this file. It is in the
# image rather than in render.yaml's dockerCommand because a service hand-created in the
# dashboard inherits no dockerCommand at all (X9, measured on the first Render deploy).
COPY docker/render.cnf /etc/mysql/conf.d/render.cnf

# The datadir. Render mounts a disk here; everything outside it is gone on every deploy.
ENV MARIADB_DATA_DIR=/var/lib/mysql

ENTRYPOINT ["/opt/render/entrypoint.sh"]
CMD ["mariadbd", "--console"]
