gem_group :development, :test do
  gem 'dotenv-rails'
  gem 'rubocop-rails'
end

gem_group :development do
  gem 'pry-rails'
  gem 'better_errors'
  gem 'binding_of_caller'
  gem 'awesome_print'
end

gem_group :production do
  gem 'airbrake'
end

gem 'rails-i18n', '~> 6.0.0'
gem 'pg', '>= 0.18', '< 2.0'

run 'bundle install'
run 'yarn install'

RUBY_VERSION = '2.6.6'
NODE_VERSION = '12'

gsub_file 'config/database.yml', /production:.*$/m, <<~YML
production:
  <<: *default
  url: <%= ENV['DATABASE_URL'] %>
YML

initializer 'airbrake.rb', <<~RUBY
if Rails.env.production?
  Airbrake.configure do |c|
    c.project_id = ENV['AIRBRAKE_PROJECT_ID']
    c.project_key = ENV['AIRBRAKE_PROJECT_KEY']
    c.root_directory = Rails.root
    c.logger = Airbrake::Rails.logger
    c.environment = ENV.fetch('APP_ENV', Rails.env)
    c.ignore_environments = %w[test]
    c.blacklist_keys = [/password/i, /authorization/i]
  end
end
RUBY

file '.dockerignore', <<~IGNORE
tmp
node_modules
log
vendor/bundle/
.idea
app.master.json
app.json
.github/
.git/
config/master.key
IGNORE

file 'Dockerfile', <<~EOF
FROM zeitio/ruby-node-stack:ruby#{RUBY_VERSION}_node12 AS gems

ADD Gemfile* /app/
RUN bundle install --deployment --without test development

FROM zeitio/ruby-node-stack:ruby#{RUBY_VERSION}_node12 AS npms

ADD package.json yarn.lock /app/
RUN yarn --frozen-lockfile

FROM zeitio/ruby-node-stack:ruby#{RUBY_VERSION}_node12 AS web

RUN unset BUNDLE_APP_CONFIG && bundle config --local path vendor/bundle && \
    bundle config --local frozen true && \
    bundle config --local without development:test

COPY --from=gems --chown=app:www-data /app/vendor/bundle /app/vendor/bundle
COPY --from=npms --chown=app:www-data /app/node_modules /app/node_modules
COPY --chown=app:www-data . /app/

RUN RAILS_ENV=production SECRET_KEY_BASE=nothing /app/bin/entrypoint rails assets:precompile

ENTRYPOINT ["/app/bin/entrypoint"]
CMD rails server -p ${PORT:-3000} --log-to-stdout

FROM web AS release

CMD ./bin/release

FROM web AS test-backend

RUN unset BUNDLE_APP_CONFIG && \
    rm -rf /app/tmp && \
    rm -f /app/.bundle/config && \
    bundle config --local path vendor/bundle && \
    bundle install --path vendor/bundle

CMD rails db:migrate && rails test
EOF

file 'bin/entrypoint', <<~EOF
#!/usr/bin/env bash

unset BUNDLE_APP_CONFIG
export PATH="/app/bin:$PATH"

exec "$@"
EOF


file 'bin/create-app-name.js', <<~JAVASCRIPT
let [,,prefix,branch,hash] = process.argv;

const available = 30;

if (prefix.length > 20) {
    prefix = prefix.slice(0, 20);
}

hash = hash.slice(0, 5);

const availableLength = available - 2 - prefix.length - hash.length;
const shortBranch = branch.replace(/[^\w-]+/, '-').toLowerCase().slice(0, availableLength);

process.stdout.write(`${prefix}-${shortBranch}-${hash}`);
JAVASCRIPT

prod_app_name = ask('Heroku production app name?')
staging_app_name = ask("Heroku staging app name? (default #{prod_app_name}-staging)").presence || "#{prod_app_name}-staging"

file 'bin/actions-vars', <<~EOF
#!/usr/bin/env bash

TAG_PREFIX=$1
REF=$2

if [[ "$3" == "staging" ]]; then
  BRANCH_NAME=staging
  APP_NAME=#{staging_app_name}
  URL=https://$APP_NAME.herokuapp.com
elif [[ "$3" == "master" ]]; then
  BRANCH_NAME=master
  APP_NAME=#{prod_app_name}
  URL=https://$APP_NAME.herokuapp.com
else
  APP_PREFIX=#{prod_app_name}
  BRANCH_NAME=${REF#refs/heads/}
  SUFFIX=$(echo "$BRANCH_NAME" | sha256sum)
  APP_NAME=$(node bin/create-app-name.js "$APP_PREFIX" "$BRANCH_NAME" "$SUFFIX")
  URL=https://$APP_NAME.herokuapp.com
fi

CACHE_KEY="$RUNNER_OS-docker-buildx-$BRANCH_NAME-$TAG_PREFIX-$GITHUB_SHA"
CACHE_KEY1="$RUNNER_OS-docker-buildx-$BRANCH_NAME-$TAG_PREFIX"
CACHE_KEY2="$RUNNER_OS-docker-buildx-$BRANCH_NAME"
CACHE_KEY3="$RUNNER_OS-docker-buildx"

echo ::set-output name=cache_key::"$CACHE_KEY"
echo ::set-output name=cache_key1::"$CACHE_KEY1"
echo ::set-output name=cache_key2::"$CACHE_KEY2"
echo ::set-output name=cache_key3::"$CACHE_KEY3"
echo ::set-output name=url::"$URL"
echo ::set-output name=branch_name::"$BRANCH_NAME"
echo ::set-output name=image_repo::registry.heroku.com/"$APP_NAME"
echo ::set-output name=app_name::"$APP_NAME"
echo ::set-output name=tag_prefix::"$TAG_PREFIX"
EOF

file 'bin/build-image', <<~EOF
#!/usr/bin/env bash

export DOCKER_CLI_EXPERIMENTAL=enabled
export DOCKER_BUILDKIT=1

docker build . \
  --file Dockerfile \
  "$@"
EOF

file 'bin/release', <<~EOF
#!/usr/bin/env bash

rails db:migrate
EOF

run 'chmod +x bin/entrypoint'
run 'chmod +x bin/actions-vars'
run 'chmod +x bin/build-image'
run 'chmod +x bin/release'

runner = yes?('Use github cloud agents? (no for self-hosted)') ? 'ubuntu-latest' : 'self-hosted'

file '.github/workflows/deploy-master.yml', <<~EOF
name: Deploy Master
on:
  push:
    branches:
      - master

jobs:
  build-and-deploy:
    name: Build and deploy image
    runs-on: #{runner}
    steps:
      - uses: actions/checkout@master
      - name: Initialize job variables
        id: vars
        run:
          ./bin/actions-vars deploy ${{ github.ref }} master
      - name: start deployment
        uses: bobheadxi/deployments@master
        id: deployment
        with:
          step: start
          token: ${{ secrets.GITHUB_TOKEN }}
          env: ${{ steps.vars.outputs.branch_name }}
      - name: Build the deployment docker image
        run: |
          ./bin/build-image \\
            --target web \\
            --tag "${{ steps.vars.outputs.image_repo }}/web:${{ github.sha }}"
          ./bin/build-image \\
            --target release \\
            --tag "${{ steps.vars.outputs.image_repo }}/release:${{ github.sha }}"
      - name: Push docker image
        run: |
          docker login --username=_ --password=$HEROKU_API_TOKEN registry.heroku.com
          docker push ${{ steps.vars.outputs.image_repo }}/web:${{ github.sha }}
          docker push ${{ steps.vars.outputs.image_repo }}/release:${{ github.sha }}
        env:
          HEROKU_API_TOKEN: ${{ secrets.HEROKU_API_TOKEN }}
      - name: Release image
        uses: 'zeitdev/heroku-container-deploy-action@master'
        with:
          app: ${{ steps.vars.outputs.app_name }}
          heroku_api_token: ${{ secrets.HEROKU_API_TOKEN }}
          image_tag: ${{ github.sha }}
          image_repo: ${{ steps.vars.outputs.image_repo }}
          app_json: app.master.json
      - name: update deployment status
        uses: bobheadxi/deployments@master
        with:
          step: finish
          token: ${{ secrets.GITHUB_TOKEN }}
          status: ${{ job.status }}
          deployment_id: ${{ steps.deployment.outputs.deployment_id }}
          env_url: ${{ steps.vars.outputs.url }}
EOF

file '.github/workflows/run-tests.yml', <<~EOF
name: Run Tests
on: [push]

jobs:
  test-backend:
    name: Test Backend
    runs-on: #{runner}
    services:
      postgres:
        image: postgres:12
        env:
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
          POSTGRES_DB: test
        ports:
        - 5432/tcp
        # needed because the postgres container does not provide a healthcheck
        options: --health-cmd pg_isready --health-interval 10s --health-timeout 5s --health-retries 5
    steps:
      - uses: actions/checkout@v2
      - name: Initialize job variables
        id: vars
        run:
          ./bin/actions-vars tests ${{ github.ref }}
      - name: Build the tagged base Docker image
        run: |
          ./bin/build-image \\
            --target test-backend \\
            --tag test-image
      - name: Run backend tests
        run: |
          docker run --rm --env-file=.env.test \\
            --env DISABLE_SPRING=true \\
            --env RAILS_ENV=test \\
            --env DATABASE_URL=postgres://test:test@postgres:5432/test \\
            --network ${{ job.container.network }} \\
            test-image
EOF

pipeline = ask('Heroku pipeline uuid?')

file '.github/workflows/create-review-app.yml', <<~EOF
name: Create Review App
on:
  pull_request:
    types: [opened, reopened]
    branches:
      - master

jobs:
  create-review-app:
    name: Create review app
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@master
      - name: Initialize job variables
        id: vars
        run:
          ./bin/actions-vars deploy ${{ github.head_ref }}
      - name: Create Review App
        uses: 'zeitdev/heroku-review-apps-action@master'
        with:
          app: ${{ steps.vars.outputs.app_name }}
          env_from: #{staging_app_name}
          pipeline: #{pipeline}
          heroku_api_token: ${{ secrets.HEROKU_API_TOKEN }}
      - name: start deployment
        uses: bobheadxi/deployments@master
        id: deployment
        with:
          step: start
          token: ${{ secrets.GITHUB_TOKEN }}
          env: ${{ steps.vars.outputs.branch_name }}
      - name: Build the tagged base Docker image
        run: |
          ./bin/build-image \\
            --target web \\
            --tag "${{ steps.vars.outputs.image_repo }}/web:${{ github.sha }}" \\
            --build-arg NO_OPTIMIZATION=1
          ./bin/build-image \\
            --target release \\
            --tag "${{ steps.vars.outputs.image_repo }}/release:${{ github.sha }}" \\
            --build-arg NO_OPTIMIZATION=1
      - name: Push docker image
        run: |
          docker login --username=_ --password=$HEROKU_API_TOKEN registry.heroku.com
          docker push ${{ steps.vars.outputs.image_repo }}/web:${{ github.sha }}
          docker push ${{ steps.vars.outputs.image_repo }}/release:${{ github.sha }}
        env:
          HEROKU_API_TOKEN: ${{ secrets.HEROKU_API_TOKEN }}
      - name: Release image
        uses: 'zeitdev/heroku-container-deploy-action@master'
        with:
          app: ${{ steps.vars.outputs.app_name }}
          heroku_api_token: ${{ secrets.HEROKU_API_TOKEN }}
          image_tag: ${{ github.sha }}
          image_repo: ${{ steps.vars.outputs.image_repo }}
      - name: update deployment status
        uses: bobheadxi/deployments@master
        with:
          step: finish
          token: ${{ secrets.GITHUB_TOKEN }}
          status: ${{ job.status }}
          deployment_id: ${{ steps.deployment.outputs.deployment_id }}
          env_url: ${{ steps.vars.outputs.url }}
EOF

file '.github/workflows/deploy-review-app.yml', <<~EOF
name: Deploy Review App
on:
  push:
    branches-ignore:
      - master

jobs:
  build-and-deploy:
    name: Build and deploy image
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@master
      - name: Initialize job variables
        id: vars
        run:
          ./bin/actions-vars deploy ${{ github.ref }}
      - name: Check Review App
        id: review_app
        run:
          echo ::set-output name=exists::$(if [[ $(heroku apps --all) =~ "$APP_NAME" ]]; then echo "true"; else echo "false"; fi)
        env:
          APP_NAME: ${{ steps.vars.outputs.app_name }}
          HEROKU_API_KEY: ${{ secrets.HEROKU_API_TOKEN }}
      - name: start deployment
        if: steps.review_app.outputs.exists == 'true'
        uses: bobheadxi/deployments@master
        id: deployment
        with:
          step: start
          token: ${{ secrets.GITHUB_TOKEN }}
          env: ${{ steps.vars.outputs.branch_name }}
      - name: Build the tagged base Docker image
        if: steps.review_app.outputs.exists == 'true'
        run: |
          ./bin/build-image \\
            --target web \\
            --tag "${{ steps.vars.outputs.image_repo }}/web:${{ github.sha }}" \\
            --build-arg NO_OPTIMIZATION=1
          ./bin/build-image \\
            --target release \\
            --tag "${{ steps.vars.outputs.image_repo }}/release:${{ github.sha }}" \\
            --build-arg NO_OPTIMIZATION=1
      - name: Push docker image
        if: steps.review_app.outputs.exists == 'true'
        run: |
          docker login --username=_ --password=$HEROKU_API_TOKEN registry.heroku.com
          docker push ${{ steps.vars.outputs.image_repo }}/web:${{ github.sha }}
          docker push ${{ steps.vars.outputs.image_repo }}/release:${{ github.sha }}
        env:
          HEROKU_API_TOKEN: ${{ secrets.HEROKU_API_TOKEN }}
      - name: Release image
        if: steps.review_app.outputs.exists == 'true'
        uses: 'zeitdev/heroku-container-deploy-action@master'
        with:
          app: ${{ steps.vars.outputs.app_name }}
          heroku_api_token: ${{ secrets.HEROKU_API_TOKEN }}
          image_tag: ${{ github.sha }}
          image_repo: ${{ steps.vars.outputs.image_repo }}
      - name: update deployment status
        uses: bobheadxi/deployments@master
        if: steps.review_app.outputs.exists == 'true'
        with:
          step: finish
          token: ${{ secrets.GITHUB_TOKEN }}
          status: ${{ job.status }}
          deployment_id: ${{ steps.deployment.outputs.deployment_id }}
          env_url: ${{ steps.vars.outputs.url }}

EOF

file '.github/workflows/destroy-review-app.yml', <<~EOF
name: Destroy Review App
on:
  pull_request:
    types: [closed]

jobs:
  destroy-review-app:
    runs-on: self-hosted
    name: Delete Heroku Review App
    steps:
      - uses: actions/checkout@master
      - name: Initialize job variables
        id: vars
        run:
          ./bin/actions-vars deploy ${{ github.head_ref }}
      - env:
          HEROKU_API_KEY: ${{ secrets.HEROKU_API_TOKEN }}
          APP_NAME: ${{ steps.vars.outputs.app_name }}
        run: |
          heroku apps:destroy --app=$APP_NAME --confirm=$APP_NAME
      - name: deactivate deployment
        uses: bobheadxi/deployments@master
        with:
          step: deactivate-env
          token: ${{ secrets.GITHUB_TOKEN }}
          env: ${{ steps.vars.outputs.branch_name }}
EOF

default_repo = "zeitdev/#{prod_app_name}"
repo = ask("Github repository? (format: orga/repo, default: #{default_repo})").presence || default_repo

file 'app.master.json', <<~EOF
{
  "name": "#{prod_app_name}",
  "repository": "https://github.com/#{repo}",
  "scripts": {},
  "stack": "container",
  "formation": {
    "web": {
      "quantity": 1
    }
  }
}
EOF

file 'app.json', <<~EOF
{
  "name": "#{prod_app_name}",
  "repository": "https://github.com/#{repo}",
  "scripts": {},
  "stack": "container",
  "env": {
    "RAILS_ENV": {
      "required": true
    },
    "TZ": {
      "required": true
    },
    "LOCALE": {
      "required": true
    },
    "RAILS_MASTER_KEY": {
      "required": true
    },
    "AIRBRAKE_PROJECT_KEY": {},
    "AIRBRAKE_PROJECT_ID": {},
    "APP_ENV": {
      "value": "review"
    }
  },
  "addons": [
    "heroku-postgresql:hobby-dev",
    "logdna:quaco"
  ],
  "formation": {
    "web": {
      "quantity": 1
    }
  }
}

EOF

file '.env.development', <<~EOF
TZ=Europe/Berlin
LOCALE=de
EOF


file '.env.test', <<~EOF
TZ=Europe/Berlin
LOCALE=de
EOF

environment "config.time_zone = ENV['TZ'] || 'UTC'"
environment "config.i18n.available_locales = [ENV['LOCALE'] || 'en']"
environment "config.i18n.default_locale = ENV['LOCALE'] || 'en'"

