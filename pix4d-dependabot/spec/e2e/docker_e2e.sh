#!/bin/sh

# Before running the script, setup your secret in pass. They can be found in the Vault
# Github/pix4d-dependabot    --> ./tools/vault_helper.py read-secret /concourse/developers/janus_developers_rw_token
# Artifactory/concourse_pass --> ./tools/vault_helper.py read-secret /concourse/shared/concourse_artifactory_password
# docker/pix4d-pass --> ./tools/vault_helper.py read-secret /concourse/shared/docker_cloud_pix4d_password

TAG=$1

docker run --name PM_DOCKER -d \
    -e GITHUB_ACCESS_TOKEN=$(pass Github/pix4d-dependabot) \
    -e DOCKER_REGISTRY="docker.ci.pix4d.com" \
    -e DOCKER_USER="pix4d" \
    -e DOCKER_PASS=$(pass docker/pix4d-pass) \
    -e REPOSITORY_DATA="[{'branch':'staging','dependency_dir':'ci/pipelines/','module':'concourse','repo':'Pix4D/github-automation-playground'},{'branch':'staging','dependency_dir':'dockerfiles/','module':'docker','repo':'Pix4D/github-automation-playground'}]" \
    -it docker.ci.pix4d.com/pix4d-dependabot:$TAG /bin/bash

docker exec -it PM_DOCKER sh -c "cd pix4d-dependabot && bundle exec ruby pix4d-dependabot.rb"
docker stop PM_DOCKER
docker rm PM_DOCKER

docker run --name PM_PIP -d \
    -e GITHUB_ACCESS_TOKEN=$(pass Github/pix4d-dependabot) \
    -e ARTIFACTORY_USERNAME="concourse" \
    -e ARTIFACTORY_PASSWORD=$(pass Artifactory/concourse_pass) \
    -e EXTRA_INDEX_URL="https://artifactory.ci.pix4d.com/artifactory/api/pypi/pix4d-pypi-local/simple/" \
    -e REPOSITORY_DATA="[{'module':'pip', 'repo':'Pix4D/github-automation-playground','branch':'staging','dependency_dir':'/python/pip_example/'}]" \
    -it docker.ci.pix4d.com/pix4d-dependabot:$TAG /bin/bash

docker exec -it PM_PIP sh -c "cd pix4d-dependabot && bundle exec ruby pix4d-dependabot.rb"
docker stop PM_PIP
docker rm PM_PIP
