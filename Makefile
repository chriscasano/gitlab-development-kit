.NOTPARALLEL:

# Generate a Makefile from Ruby and include it
include $(shell rake gdk-config.mk)

gitlab_clone_dir = gitlab
gitlab_shell_clone_dir = go-gitlab-shell/src/gitlab.com/gitlab-org/gitlab-shell
gitlab_workhorse_clone_dir = gitlab-workhorse/src/gitlab.com/gitlab-org/gitlab-workhorse
gitaly_gopath = $(abspath ./gitaly)
gitaly_clone_dir = ${gitaly_gopath}/src/gitlab.com/gitlab-org/gitaly
gitlab_pages_clone_dir = gitlab-pages/src/gitlab.com/gitlab-org/gitlab-pages
gitaly_assembly_dir = ${gitlab_development_root}/gitaly/assembly
gitlab_from_container = $(shell [ "$(shell uname)" = "Linux" ] && echo 'localhost' || echo 'docker.for.mac.localhost')
postgres_dev_db = gitlabhq_development
rails_bundle_install_cmd = bundle install --jobs 4 --without production
workhorse_version = $(shell bin/resolve-dependency-commitish "${gitlab_development_root}/gitlab/GITLAB_WORKHORSE_VERSION")
gitlab_shell_version = $(shell bin/resolve-dependency-commitish "${gitlab_development_root}/gitlab/GITLAB_SHELL_VERSION")
gitaly_version = $(shell bin/resolve-dependency-commitish "${gitlab_development_root}/gitlab/GITALY_SERVER_VERSION")
pages_version = $(shell bin/resolve-dependency-commitish "${gitlab_development_root}/gitlab/GITLAB_PAGES_VERSION")
gitlab_elasticsearch_indexer_version = $(shell bin/resolve-dependency-commitish "${gitlab_development_root}/gitlab/GITLAB_ELASTICSEARCH_INDEXER_VERSION")
tracer_build_tags = tracer_static tracer_static_jaeger

ifeq ($(shallow_clone),true)
git_depth_param = --depth=1
endif

all: preflight-checks gitlab-setup gitlab-shell-setup gitlab-workhorse-setup gitlab-pages-setup support-setup gitaly-setup prom-setup object-storage-setup gitlab-elasticsearch-indexer-setup

.PHONY: preflight-checks
preflight-checks: rake
	rake $@

.PHONY: rake
rake:
	command -v $@ > /dev/null || gem install $@

# Set up the GitLab Rails app

gitlab-setup: gitlab/.git .ruby-version gitlab-config .gitlab-bundle .gitlab-yarn .gettext

gitlab/.git:
	git clone ${git_depth_param} ${gitlab_repo} ${gitlab_clone_dir}

gitlab-config: gitlab/config/gitlab.yml gitlab/config/database.yml gitlab/config/unicorn.rb gitlab/config/resque.yml gitlab/public/uploads gitlab/config/puma.rb

auto_devops_enabled:
	echo 'false' > $@

auto_devops_gitlab_port:
	awk -v min=20000 -v max=24999 'BEGIN{srand(); print int(min+rand()*(max-min+1))}' > $@

auto_devops_registry_port: auto_devops_gitlab_port
	expr ${auto_devops_gitlab_port} + 5000 > $@

.PHONY: gitlab/config/gitlab.yml
gitlab/config/gitlab.yml:
	rake gitlab/config/gitlab.yml

gitlab/config/database.yml: database.yml.example
	bin/safe-sed "$@" \
		-e "s|/home/git|${gitlab_development_root}|g" \
		-e "s|5432|${postgresql_port}|" \
		"$<"

# Versions older than GitLab 11.5 won't have this file
gitlab/config/puma.example.development.rb:
	touch $@

gitlab/config/puma.rb: gitlab/config/puma.example.development.rb
	bin/safe-sed "$@" \
		-e "s|/home/git|${gitlab_development_root}|g" \
		"$<"

gitlab/config/unicorn.rb: gitlab/config/unicorn.rb.example.development
	bin/safe-sed "$@" \
		-e "s|/home/git|${gitlab_development_root}|g" \
		"$<"

gitlab/config/resque.yml: redis/resque.yml.example
	bin/safe-sed "$@" \
		-e "s|/home/git|${gitlab_development_root}|g" \
		"$<"

gitlab/public/uploads:
	mkdir $@

.gitlab-bundle:
	cd ${gitlab_development_root}/gitlab && $(rails_bundle_install_cmd)
	touch $@

.gitlab-yarn:
	cd ${gitlab_development_root}/gitlab && yarn install --pure-lockfile
	touch $@

.gettext:
	cd ${gitlab_development_root}/gitlab && bundle exec rake gettext:compile > ${gitlab_development_root}/gettext.log 2>&1
	git -C ${gitlab_development_root}/gitlab checkout locale/*/gitlab.po
	touch $@

# Set up gitlab-shell

gitlab-shell-setup: symlink-gitlab-shell ${gitlab_shell_clone_dir}/.git gitlab-shell/config.yml .gitlab-shell-bundle gitlab-shell/.gitlab_shell_secret
	make -C gitlab-shell build

symlink-gitlab-shell:
	support/symlink gitlab-shell ${gitlab_shell_clone_dir}

${gitlab_shell_clone_dir}/.git:
	git clone --quiet --branch "${gitlab_shell_version}" ${git_depth_param} ${gitlab_shell_repo} ${gitlab_shell_clone_dir}

gitlab-shell/config.yml: gitlab-shell/config.yml.example
	bin/safe-sed "$@" \
		-e "s|/home/git|${gitlab_development_root}|g" \
		-e "s|^gitlab_url:.*|gitlab_url: http+unix://$(subst /,%2F,${gitlab_development_root}/gitlab.socket)|" \
		-e "s|/usr/bin/redis-cli|$(shell which redis-cli)|" \
		-e "s|^  socket: .*|  socket: ${gitlab_development_root}/redis/redis.socket|" \
		-e "s|^# migration|migration|" \
		"$<"

.gitlab-shell-bundle:
	cd ${gitlab_development_root}/gitlab-shell && $(rails_bundle_install_cmd)
	touch $@

gitlab-shell/.gitlab_shell_secret:
	ln -s ${gitlab_development_root}/gitlab/.gitlab_shell_secret $@

# Set up gitaly

gitaly-setup: gitaly/bin/gitaly gitaly/gitaly.config.toml gitaly/praefect.config.toml

${gitaly_clone_dir}/.git:
	git clone --quiet --branch "${gitaly_version}" ${git_depth_param} ${gitaly_repo} ${gitaly_clone_dir}

.PHONY: gitaly/gitaly.config.toml
gitaly/gitaly.config.toml:
	rake gitaly/gitaly.config.toml


.PHONY: gitaly/praefect.config.toml
gitaly/praefect.config.toml:
	rake gitaly/praefect.config.toml

prom-setup:
	if [ "$(uname -s)" = "Linux" ]; then \
		sed -i -e 's/docker\.for\.mac\.localhost/localhost/g' ${gitlab_development_root}/prometheus/prometheus.yml; \
	fi

# Set up gitlab-docs

gitlab-docs-setup: gitlab-docs/.git gitlab-docs-bundle gitlab-docs/nanoc.yaml symlink-gitlab-docs

gitlab-docs/.git:
	git clone ${git_depth_param} ${gitlab_docs_repo} gitlab-docs

gitlab-docs/.git/pull:
	cd gitlab-docs && \
		git stash && \
		git checkout master &&\
		git pull --ff-only


# We need to force delete since there's already a nanoc.yaml file
# in the docs folder which we need to overwrite.
gitlab-docs/rm-nanoc.yaml:
	rm -f gitlab-docs/nanoc.yaml

gitlab-docs/nanoc.yaml: gitlab-docs/rm-nanoc.yaml
	cp nanoc.yaml.example $@

gitlab-docs-bundle:
	cd ${gitlab_development_root}/gitlab-docs && bundle install --jobs 4

symlink-gitlab-docs:
	support/symlink ${gitlab_development_root}/gitlab-docs/content/ee ${gitlab_development_root}/gitlab/doc

gitlab-docs-update: gitlab-docs/.git/pull gitlab-docs-bundle gitlab-docs/nanoc.yaml

# Update GDK itself

self-update: unlock-dependency-installers
	@echo ""
	@echo "--------------------------"
	@echo "Running self-update on GDK"
	@echo "--------------------------"
	@echo ""
	cd ${gitlab_development_root} && \
		git stash && \
		git checkout master && \
		git fetch && \
		support/self-update-git-worktree

# Update gitlab, gitlab-shell, gitlab-workhorse, gitlab-pages and gitaly
# Pull gitlab directory first since dependencies are linked from there.
update: stop-foreman ensure-databases-running unlock-dependency-installers gitlab/.git/pull gitlab-shell-update gitlab-workhorse-update gitlab-pages-update gitaly-update gitlab-update gitlab-elasticsearch-indexer-update
	@echo
	@echo 'make update: done'

stop-foreman:
	@pkill foreman || true

ensure-databases-running: Procfile postgresql/data
	@gdk start rails-migration-dependencies

gitlab-update: ensure-databases-running postgresql gitlab/.git/pull gitlab-setup
	cd ${gitlab_development_root}/gitlab && \
		bundle exec rake db:migrate db:test:prepare

gitlab-shell-update: gitlab-shell/.git/pull gitlab-shell-setup

gitlab/.git/pull:
	cd ${gitlab_development_root}/gitlab && \
		git checkout -- Gemfile.lock db/schema.rb && \
		git stash && \
		git checkout master && \
		git pull --ff-only

gitlab-shell/.git/pull:
	support/component-git-update gitlab_shell "${gitlab_development_root}/gitlab-shell" "${gitlab_shell_version}"

gitaly-update: gitaly/.git/pull gitaly-clean gitaly/bin/gitaly

.PHONY: gitaly/.git/pull
gitaly/.git/pull: ${gitaly_clone_dir}/.git
	support/component-git-update gitaly "${gitaly_clone_dir}" "${gitaly_version}"

gitaly-clean:
	rm -rf ${gitaly_assembly_dir}
	rm -rf gitlab/tmp/tests/gitaly

.PHONY: gitaly/bin/gitaly
gitaly/bin/gitaly: ${gitaly_clone_dir}/.git
	$(MAKE) -C ${gitaly_clone_dir} assemble ASSEMBLY_ROOT=${gitaly_assembly_dir} BUNDLE_FLAGS=--no-deployment BUILD_TAGS="${tracer_build_tags}"
	mkdir -p ${gitlab_development_root}/gitaly/bin
	ln -sf ${gitaly_assembly_dir}/bin/* ${gitlab_development_root}/gitaly/bin
	rm -rf ${gitlab_development_root}/gitaly/ruby
	ln -sf ${gitaly_assembly_dir}/ruby ${gitlab_development_root}/gitaly/ruby

# Set up supporting services

support-setup: Procfile redis gitaly-setup jaeger-setup postgresql openssh-setup nginx-setup registry-setup elasticsearch-setup
	@echo ""
	@echo "*********************************************"
	@echo "************** Setup finished! **************"
	@echo "*********************************************"
	cat HELP
	@echo "*********************************************"
	@if ${auto_devops_enabled}; then \
		echo "Tunnel URLs"; \
		echo ""; \
		echo "GitLab: https://${hostname}"; \
		echo "Registry: https://${registry_host}"; \
		echo "*********************************************"; \
	fi

gdk.yml:
	touch $@

.PHONY: Procfile
Procfile:
	rake $@

redis: redis/redis.conf

redis/redis.conf: redis/redis.conf.example
	bin/safe-sed "$@" \
		-e "s|/home/git|${gitlab_development_root}|g" \
		"$<"

postgresql: postgresql/data/.rails-seed

postgresql/data:
	${postgres_bin_dir}/initdb --locale=C -E utf-8 ${postgres_data_dir}

postgresql/data/.rails-seed: postgresql/data ensure-databases-running
	gdk psql ${postgres_dev_db} -c '\q' > /dev/null 2>&1 || support/bootstrap-rails
	touch $@

postgresql/port:
	./support/postgres-port ${postgres_dir} ${postgresql_port}

postgresql-sensible-defaults:
	./support/postgresql-sensible-defaults ${postgres_dir}

postgresql-replication-primary: postgresql-replication/access postgresql-replication/role postgresql-replication/config

postgresql-replication-secondary: postgresql-replication/data postgresql-replication/access postgresql-replication/backup postgresql-replication/config

postgresql-replication-primary-create-slot: postgresql-replication/slot

postgresql-replication/data:
	${postgres_bin_dir}/initdb --locale=C -E utf-8 ${postgres_data_dir}

postgresql-replication/access:
	cat support/pg_hba.conf.add >> ${postgres_data_dir}/pg_hba.conf

postgresql-replication/role:
	${postgres_bin_dir}/psql -h ${postgres_dir} -p ${postgresql_port} -d postgres -c "CREATE ROLE ${postgres_replication_user} WITH REPLICATION LOGIN;"

postgresql-replication/backup:
	$(eval postgres_primary_dir := $(realpath postgresql-primary))
	$(eval postgres_primary_port := $(shell cat ${postgres_primary_dir}/../postgresql_port 2>/dev/null || echo '5432'))

	psql -h ${postgres_primary_dir} -p ${postgres_primary_port} -d postgres -c "select pg_start_backup('base backup for streaming rep')"
	rsync -cva --inplace --exclude="*pg_xlog*" --exclude="*.pid" ${postgres_primary_dir}/data postgresql
	psql -h ${postgres_primary_dir} -p ${postgres_primary_port} -d postgres -c "select pg_stop_backup(), current_timestamp"
	./support/recovery.conf ${postgres_primary_dir} ${postgres_primary_port} > ${postgres_data_dir}/recovery.conf
	$(MAKE) postgresql/port

postgresql-replication/slot:
	${postgres_bin_dir}/psql -h ${postgres_dir} -p ${postgresql_port} -d postgres -c "SELECT * FROM pg_create_physical_replication_slot('gitlab_gdk_replication_slot');"

postgresql-replication/list-slots:
	${postgres_bin_dir}/psql -h ${postgres_dir} -p ${postgresql_port} -d postgres -c "SELECT * FROM pg_replication_slots;"

postgresql-replication/drop-slot:
	${postgres_bin_dir}/psql -h ${postgres_dir} -p ${postgresql_port} -d postgres -c "SELECT * FROM pg_drop_replication_slot('gitlab_gdk_replication_slot');"

postgresql-replication/config:
	./support/postgres-replication ${postgres_dir}

# Setup GitLab Geo databases

.PHONY: geo-setup geo-cursor
geo-setup: Procfile geo-cursor gitlab/config/database_geo.yml postgresql/geo

geo-cursor:
	grep '^geo-cursor:' Procfile || (printf ',s/^#geo-cursor/geo-cursor/\nwq\n' | ed -s Procfile)

gitlab/config/database_geo.yml: database_geo.yml.example
	bin/safe-sed "$@" \
		-e "s|/home/git|${gitlab_development_root}|g" \
		"$<"

postgresql/geo:
	${postgres_bin_dir}/initdb --locale=C -E utf-8 postgresql-geo/data
	grep '^postgresql-geo:' Procfile || (printf ',s/^#postgresql-geo/postgresql-geo/\nwq\n' | ed -s Procfile)
	support/bootstrap-geo

postgresql/geo-fdw: postgresql/geo-fdw/development/create postgresql/geo-fdw/test/create

# Function to read values from database.yml, parameters:
#   - file: e.g. database, database_geo
#   - environment: e.g. development, test
#   - value: e.g. host, port
from_db_config = $(shell grep -A6 "$(2):" ${gitlab_development_root}/gitlab/config/$(1).yml | grep -m1 "$(3):" | cut -d ':' -f 2 | tr -d ' ')

postgresql/geo-fdw/%: dbname = $(call from_db_config,database_geo,$*,database)
postgresql/geo-fdw/%: fdw_dbname = $(call from_db_config,database,$*,database)
postgresql/geo-fdw/%: fdw_host = $(call from_db_config,database,$*,host)
postgresql/geo-fdw/%: fdw_port = $(call from_db_config,database,$*,port)
postgresql/geo-fdw/test/%: rake_namespace = test:

postgresql/geo-fdw/%/create:
	${postgres_bin_dir}/psql -h ${postgres_geo_dir} -p ${postgresql_geo_port} -d ${dbname} -c "CREATE EXTENSION IF NOT EXISTS postgres_fdw;"
	${postgres_bin_dir}/psql -h ${postgres_geo_dir} -p ${postgresql_geo_port} -d ${dbname} -c "CREATE SERVER gitlab_secondary FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host '$(fdw_host)', dbname '${fdw_dbname}', port '$(fdw_port)' );"
	${postgres_bin_dir}/psql -h ${postgres_geo_dir} -p ${postgresql_geo_port} -d ${dbname} -c "CREATE USER MAPPING FOR current_user SERVER gitlab_secondary OPTIONS (user '$(USER)');"
	${postgres_bin_dir}/psql -h ${postgres_geo_dir} -p ${postgresql_geo_port} -d ${dbname} -c "CREATE SCHEMA IF NOT EXISTS gitlab_secondary;"
	${postgres_bin_dir}/psql -h ${postgres_geo_dir} -p ${postgresql_geo_port} -d ${dbname} -c "GRANT USAGE ON FOREIGN SERVER gitlab_secondary TO current_user;"
	cd ${gitlab_development_root}/gitlab && bundle exec rake geo:db:${rake_namespace}refresh_foreign_tables

postgresql/geo-fdw/%/drop:
	${postgres_bin_dir}/psql -h ${postgres_geo_dir} -p ${postgresql_geo_port} -d ${dbname} -c "DROP SERVER gitlab_secondary CASCADE;"
	${postgres_bin_dir}/psql -h ${postgres_geo_dir} -p ${postgresql_geo_port} -d ${dbname} -c "DROP SCHEMA gitlab_secondary;"

postgresql/geo-fdw/%/rebuild:
	$(MAKE) postgresql/geo-fdw/$*/drop || true
	$(MAKE) postgresql/geo-fdw/$*/create

.PHONY: geo-primary-migrate
geo-primary-migrate: ensure-databases-running
	cd ${gitlab_development_root}/gitlab && \
		bundle install && \
		bundle exec rake db:migrate db:test:prepare geo:db:migrate geo:db:test:prepare && \
		git checkout -- db/schema.rb ee/db/geo/schema.rb
	$(MAKE) postgresql/geo-fdw/test/rebuild

.PHONY: geo-primary-update
geo-primary-update: update geo-primary-migrate
	gdk diff-config

.PHONY: geo-secondary-migrate
geo-secondary-migrate: ensure-databases-running
	cd ${gitlab_development_root}/gitlab && \
		bundle install && \
		bundle exec rake geo:db:migrate && \
		git checkout -- ee/db/geo/schema.rb
	$(MAKE) postgresql/geo-fdw/development/rebuild

.PHONY: geo-secondary-update
geo-secondary-update:
	-$(MAKE) update
	$(MAKE) geo-secondary-migrate
	gdk diff-config

.ruby-version:
	ln -s ${gitlab_development_root}/gitlab/.ruby-version ${gitlab_development_root}/$@

localhost.crt: localhost.key

localhost.key:
	openssl req -new -subj "/CN=localhost/" -x509 -days 365 -newkey rsa:2048 -nodes -keyout "localhost.key" -out "localhost.crt"
	chmod 600 $@

gitlab-workhorse-setup: gitlab-workhorse/bin/gitlab-workhorse gitlab-workhorse/config.toml

gitlab-workhorse/config.toml: gitlab-workhorse/config.toml.example
	bin/safe-sed "$@" \
		-e "s|/home/git|${gitlab_development_root}|g" \
		"$<"

gitlab-workhorse-update: ${gitlab_workhorse_clone_dir}/.git gitlab-workhorse/.git/pull gitlab-workhorse-clean-bin gitlab-workhorse/bin/gitlab-workhorse

gitlab-workhorse-clean-bin:
	rm -rf gitlab-workhorse/bin

.PHONY: gitlab-workhorse/bin/gitlab-workhorse
gitlab-workhorse/bin/gitlab-workhorse: ${gitlab_workhorse_clone_dir}/.git
	$(MAKE) -C ${gitlab_workhorse_clone_dir} install PREFIX=${gitlab_development_root}/gitlab-workhorse

${gitlab_workhorse_clone_dir}/.git:
	git clone --quiet --branch "${workhorse_version}" ${git_depth_param} ${gitlab_workhorse_repo} ${gitlab_workhorse_clone_dir}

gitlab-workhorse/.git/pull:
	support/component-git-update workhorse "${gitlab_workhorse_clone_dir}" "${workhorse_version}"

gitlab-pages-setup: gitlab-pages/bin/gitlab-pages

gitlab-pages-update: ${gitlab_pages_clone_dir}/.git gitlab-pages/.git/pull gitlab-pages-clean-bin gitlab-pages/bin/gitlab-pages

gitlab-pages-clean-bin:
	rm -rf gitlab-pages/bin

.PHONY: gitlab-pages/bin/gitlab-pages
gitlab-pages/bin/gitlab-pages: ${gitlab_pages_clone_dir}/.git
	mkdir -p gitlab-pages/bin
	$(MAKE) -C ${gitlab_pages_clone_dir}
	install -m755 ${gitlab_pages_clone_dir}/gitlab-pages gitlab-pages/bin

${gitlab_pages_clone_dir}/.git:
	git clone --quiet --branch "${pages_version}" ${git_depth_param} ${gitlab_pages_repo} ${gitlab_pages_clone_dir}

gitlab-pages/.git/pull:
	support/component-git-update gitlab_pages "${gitlab_pages_clone_dir}" "${pages_version}"

influxdb-setup: influxdb/influxdb.conf influxdb/bin/influxd influxdb/meta/meta.db

influxdb/bin/influxd:
	cd influxdb && ${MAKE}

influxdb/meta/meta.db: Procfile
	grep '^influxdb:' Procfile || (printf ',s/^#influxdb/influxdb/\nwq\n' | ed -s Procfile)
	support/bootstrap-influxdb 8086

influxdb/influxdb.conf: influxdb/influxdb.conf.example
	bin/safe-sed "$@" \
		-e "s|/home/git|${gitlab_development_root}|g" \
		"$<"

grafana-setup: grafana/grafana.ini grafana/bin/grafana-server grafana/gdk-pg-created grafana/gdk-data-source-created

grafana/bin/grafana-server:
	cd grafana && ${MAKE}

grafana/grafana.ini: grafana/grafana.ini.example
	bin/safe-sed "$@" \
		-e "s|/home/git|${gitlab_development_root}|g" \
		-e "s/GDK_USERNAME/${username}/g" \
		"$<"

grafana/gdk-pg-created:
	PATH=${postgres_bin_dir}:${PATH} support/create-grafana-db
	touch $@

grafana/gdk-data-source-created:
	grep '^grafana:' Procfile || (printf ',s/^#grafana/grafana/\nwq\n' | ed -s Procfile)
	support/bootstrap-grafana
	touch $@

performance-metrics-setup: Procfile influxdb-setup grafana-setup

openssh-setup: openssh/sshd_config openssh/ssh_host_rsa_key

openssh/sshd_config: openssh/sshd_config.example
	bin/safe-sed "$@" \
		-e "s|/home/git|${gitlab_development_root}|g" \
		-e "s/GDK_USERNAME/${username}/g" \
		"$<"

openssh/ssh_host_rsa_key:
	ssh-keygen -f $@ -N '' -t rsa

nginx-setup: nginx/conf/nginx.conf nginx/logs nginx/tmp

.PHONY: nginx/conf/nginx.conf
nginx/conf/nginx.conf:
	rake $@

nginx/logs:
	mkdir -p $@

nginx/tmp:
	mkdir -p $@

registry-setup: registry/storage registry/config.yml localhost.crt

registry/storage:
	mkdir -p $@

registry/config.yml: auto_devops_enabled
	cp registry/config.yml.example $@
	if ${auto_devops_enabled}; then \
		protocol='https' gitlab_host=${hostname} gitlab_port=${port} registry_port=${registry_port} \
		support/edit-registry-config.yml $@; \
	else \
		gitlab_host=${gitlab_from_container} gitlab_port=${port} registry_port=${registry_port} \
		support/edit-registry-config.yml $@; \
	fi

elasticsearch-setup: elasticsearch/bin/elasticsearch

elasticsearch/bin/elasticsearch: elasticsearch-${elasticsearch_version}.tar.gz
	rm -rf elasticsearch
	tar zxf elasticsearch-${elasticsearch_version}.tar.gz
	mv elasticsearch-${elasticsearch_version} elasticsearch
	touch $@

elasticsearch-${elasticsearch_version}.tar.gz:
	curl -L -o $@.tmp https://artifacts.elastic.co/downloads/elasticsearch/$@
	echo "${elasticsearch_tar_gz_sha1}  $@.tmp" | shasum -a1 -c -
	mv $@.tmp $@

gitlab-elasticsearch-indexer-setup: gitlab-elasticsearch-indexer/bin/gitlab-elasticsearch-indexer

gitlab-elasticsearch-indexer-update: gitlab-elasticsearch-indexer/.git/pull gitlab-elasticsearch-indexer-clean-bin gitlab-elasticsearch-indexer/bin/gitlab-elasticsearch-indexer

gitlab-elasticsearch-indexer-clean-bin:
	rm -rf gitlab-elasticsearch-indexer/bin

gitlab-elasticsearch-indexer/.git:
	git clone --quiet --branch "${gitlab_elasticsearch_indexer_version}" ${git_depth_param} ${gitlab_elasticsearch_indexer_repo} gitlab-elasticsearch-indexer

.PHONY: gitlab-elasticsearch-indexer/bin/gitlab-elasticsearch-indexer
gitlab-elasticsearch-indexer/bin/gitlab-elasticsearch-indexer: gitlab-elasticsearch-indexer/.git
	$(MAKE) -C gitlab-elasticsearch-indexer build

.PHONY: gitlab-elasticsearch-indexer/.git/pull
gitlab-elasticsearch-indexer/.git/pull: gitlab-elasticsearch-indexer/.git
	support/component-git-update gitlab_elasticsearch_indexer gitlab-elasticsearch-indexer "${gitlab_elasticsearch_indexer_version}"

object-storage-setup: minio/data/lfs-objects minio/data/artifacts minio/data/uploads minio/data/packages

minio/data/%:
	mkdir -p $@

ifeq ($(jaeger_server_enabled),true)
.PHONY: jaeger-setup
jaeger-setup: jaeger/jaeger-${jaeger_version}/jaeger-all-in-one
else
.PHONY: jaeger-setup
jaeger-setup:
	@echo Skipping jaeger-setup as Jaeger has been disabled.
endif

jaeger-artifacts/jaeger-${jaeger_version}.tar.gz:
	mkdir -p $(@D)
	./bin/download-jaeger "${jaeger_version}" "$@"
	# To save disk space, delete old versions of the download,
	# but to save bandwidth keep the current version....
	find jaeger-artifacts ! -path "$@" -type f -exec rm -f {} + -print

jaeger/jaeger-${jaeger_version}/jaeger-all-in-one: jaeger-artifacts/jaeger-${jaeger_version}.tar.gz
	mkdir -p "jaeger/jaeger-${jaeger_version}"
	tar -xf "$<" -C "jaeger/jaeger-${jaeger_version}" --strip-components 1

clean-config:
	rm -rf \
	gitlab/config/gitlab.yml \
	gitlab/config/database.yml \
	gitlab/config/unicorn.rb \
	gitlab/config/puma.rb \
	gitlab/config/resque.yml \
	gitlab-shell/config.yml \
	gitlab-shell/.gitlab_shell_secret \
	redis/redis.conf \
	.ruby-version \
	Procfile \
	gitlab-workhorse/config.toml \
	gitaly/gitaly.config.toml \
	nginx/conf/nginx.conf \
	registry/config.yml \
	jaeger

touch-examples:
	touch \
	Procfile.erb \
	database.yml.example \
	database_geo.yml.example \
	gitlab-shell/config.yml.example \
	gitlab-workhorse/config.toml.example \
	gitlab/config/puma.example.development.rb \
	gitlab/config/unicorn.rb.example.development \
	grafana/grafana.ini.example \
	influxdb/influxdb.conf.example \
	openssh/sshd_config.example \
	redis/redis.conf.example \
	redis/resque.yml.example \
	registry/config.yml.example \
	support/templates/*.erb

unlock-dependency-installers:
	rm -f \
	.gitlab-bundle \
	.gitlab-shell-bundle \
	.gitlab-yarn \
	.gettext \

.PHONY:
static-analysis: static-analysis-editorconfig

.PHONY: static-analysis-editorconfig
static-analysis-editorconfig: install-eclint
	eclint check $$(git ls-files) || (echo "editorconfig check failed. Please run \`make correct\`" && exit 1)

.PHONY: correct
correct: correct-editorconfig

.PHONY: correct-editorconfig
correct-editorconfig: install-eclint
	eclint fix $$(git ls-files)

.PHONY: install-eclint
install-eclint:
	# Some distros come with `npm`, some with `yarn`
	# So, we attempt to install eclint with either package manager
	(command -v eclint > /dev/null) || \
	((command -v npm > /dev/null) && npm install -g eclint) || \
	((command -v yarn > /dev/null) && yarn global add eclint)
