
# Create Project
function create_project() {
  oc new-project lab-infra --display-name="Lab Infra"
}

# waits while the condition is true until it becomes false or it times out
function wait_while_empty() {
  local _NAME=$1
  local _TIMEOUT=$(($2/5))
  local _CONDITION=$3

  echo "Waiting for $_NAME to be ready..."
  local x=1
  while [ -z "$(eval ${_CONDITION})" ]
  do
    echo "."
    sleep 5
    x=$(( $x + 1 ))
    if [ $x -gt $_TIMEOUT ]
    then
      echo "$_NAME still not ready, I GIVE UP!"
      exit 255
    fi
  done

  echo "$_NAME is ready."
}

# Deploy Nexus
function deploy_nexus() {
  oc process -f https://raw.githubusercontent.com/OpenShiftDemos/nexus/master/nexus2-persistent-template.yaml | oc create -f - -n lab-infra
  oc set resources dc/nexus --limits=cpu=1,memory=2Gi --requests=cpu=200m,memory=1Gi -n lab-infra
}

# Extract domain name for Gogs
function deploy_gogs() {
  oc create route edge dummyroute --service=dummysvc --port=80 -n lab-infra >/dev/null
  GOGS_HOSTNAME=$(oc get route dummyroute -o template --template='{{.spec.host}}' -n lab-infra | sed "s/dummyroute/gogs/g")
  oc delete route dummyroute -n lab-infra >/dev/null

  # Deploy Gogs
  oc process -f https://raw.githubusercontent.com/OpenShiftDemos/gogs-openshift-docker/master/openshift/gogs-persistent-template.yaml \
      --param=SKIP_TLS_VERIFY=true \
      --param=HOSTNAME=$GOGS_HOSTNAME \
      --param=GOGS_VERSION=0.11.4 \
      -n lab-infra \
      | oc create -f - -n lab-infra

  wait_while_empty "Gogs PostgreSQL" 600 "oc get ep gogs-postgresql -o yaml -n lab-infra | grep '\- addresses:'"
  wait_while_empty "Gogs" 600 "oc get ep gogs -o yaml -n lab-infra | grep '\- addresses:'"

  # Create Gogs user
  curl -sL -o /dev/null --post302 http://$GOGS_HOSTNAME/user/sign_up \
    --form user_name=developer \
    --form password=developer \
    --form retype=developer \
    --form email=developer@gogs.com

  # Import cart-service GitHub repo
  read -r -d '' _DATA_JSON << EOM
{
  "clone_addr": "https://github.com/siamaksade/cart-service.git",
  "uid": 1,
  "repo_name": "cart-service"
}
EOM

  curl -sL -H "Content-Type: application/json" \
      -d "$_DATA_JSON" \
      -u developer:developer \
      -X POST http://$GOGS_HOSTNAME/api/v1/repos/migrate

  # Create pipelines repository
  read -r -d '' _DATA_JSON << EOM
{
  "name": "pipelines",
  "private": false,
  "auto_init": true,
  "gitignores": "Java",
  "license": "Apache License 2.0",
  "readme": "Default"
}
EOM

  curl -sL -H "Content-Type: application/json" \
      -d "$_DATA_JSON" \
      -u developer:developer \
      -X POST http://$GOGS_HOSTNAME/api/v1/user/repos
}

# Import Image Streams
function import_imagestreams() {
  oc apply -f https://raw.githubusercontent.com/openshift/openshift-ansible/master/roles/openshift_examples/files/examples/v1.5/image-streams/image-streams-rhel7.json -n openshift --as=system:admin
  oc apply -f https://raw.githubusercontent.com/openshift/openshift-ansible/master/roles/openshift_examples/files/examples/v1.5/xpaas-streams/jboss-image-streams.json -n openshift --as=system:admin 
  oc apply -f https://raw.githubusercontent.com/openshift/openshift-ansible/master/roles/openshift_examples/files/examples/v1.5/xpaas-streams/fis-image-streams.json -n openshift --as=system:admin 
  sleep 5
}

# Create Builds
function build_images() {
  wait_while_empty "Nexus" 600 "oc get ep nexus -o yaml -n lab-infra | grep '\- addresses:'"

  oc process -f https://raw.githubusercontent.com/jbossdemocentral/coolstore-microservice/stable-ocp-3.5/openshift/templates/coolstore-builds-template.yaml \
      --param=MAVEN_MIRROR_URL=http://nexus.lab-infra.svc.cluster.local:8081/content/groups/public/ \
      -n lab-infra | oc create -f - -n openshift --as=system:admin
  sleep 10

  # Build images
  oc delete bc cart -n openshift --as=system:admin
  oc start-build web-ui -n openshift --follow --as=system:admin
  oc start-build inventory -n openshift --follow --as=system:admin
  oc start-build catalog -n openshift --follow --as=system:admin
  oc start-build coolstore-gw -n openshift --follow --as=system:admin

  sleep 5
  oc tag openshift/web-ui:latest openshift/coolstore-web-ui:prod --as=system:admin
  oc tag openshift/inventory:latest openshift/coolstore-inventory:prod --as=system:admin
  oc tag openshift/catalog:latest openshift/coolstore-catalog:prod --as=system:admin
  oc tag openshift/coolstore-gw:latest openshift/coolstore-gateway:prod --as=system:admin

  oc create -f https://raw.githubusercontent.com/openshift-evangelists/summit17-cicd-lab/master/lab-6/coolstore-template.yaml -n openshift --as=system:admin
}

function set_project_permissions() {
  oc policy remove-role-from-user admin developer -n lab-infra --as=system:admin
  oc policy add-role-to-user view developer -n lab-infra --as=system:admin
}
########################
# Prepare Labs Cluster #
########################
START=`date +%s`

create_project
deploy_nexus
deploy_gogs
sleep 5
import_imagestreams
build_images
set_project_permissions

END=`date +%s`
echo
echo "Lab cluster is ready! (completed in $(( ($END - $START)/60 )) min $(( ($END - $START)%60 )) sec)"
