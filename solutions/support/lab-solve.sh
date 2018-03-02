
# Set Vars
GOGS_ROUTE=$(oc get route gogs -o template --template='{{.spec.host}}' -n lab-infra)
CART_REPO=http://$GOGS_ROUTE/developer/cart-service.git
PIPELINES_REPO=http://$GOGS_ROUTE/developer/pipelines.git

# Create Projects
oc new-project dev --display-name="Cart Dev"
oc new-project prod --display-name="Coolstore Prod"

# Deploy Dev
oc process -f https://raw.githubusercontent.com/openshift-evangelists/summit17-cicd-lab/master/lab-3/cart-template.yaml \
    --param=GIT_URI=$CART_REPO \
    --param=MAVEN_MIRROR_URL=http://nexus.lab-infra.svc.cluster.local:8081/content/groups/public/ \
    | oc create -f - -n dev

# Deploy Prod
HOSTNAME=$(echo "$GOGS_ROUTE" | sed "s/gogs-lab-infra.//g")
oc process -f https://raw.githubusercontent.com/openshift-evangelists/summit17-cicd-lab/master/lab-7/coolstore-bluegreen-template.yaml \
    --param=HOSTNAME_SUFFIX=prod.$HOSTNAME \
    | oc create -f - -n prod
sleep 5

# Save Resources
oc scale dc/inventory --replicas=0 -n prod
oc scale dc/inventory-postgresql --replicas=0 -n prod

# Deploy Pipeline
rm -rf /tmp/pipelines && \
    git clone http://$GOGS_ROUTE/developer/pipelines.git /tmp/pipelines && \
    pushd /tmp/pipelines && \
    curl -sL https://raw.githubusercontent.com/openshift-evangelists/summit17-cicd-lab/master/lab-8/Jenkinsfile | sed "s|git url: .*|git url: '$CART_REPO'|g" > Jenkinsfile && \
    git add Jenkinsfile && \
    git commit -m "pipeline added" && \
    git push -f http://developer:developer@$GOGS_ROUTE/developer/pipelines.git master && \
    popd && \
    rm -rf /tmp/pipelines

curl -sL https://raw.githubusercontent.com/openshift-evangelists/summit17-cicd-lab/master/lab-4/cart-pipeline-scm.yaml | sed "s|uri: .*|uri: $PIPELINES_REPO|g" | oc create -f - -n dev
    
oc policy add-role-to-user edit system:serviceaccount:dev:jenkins -n prod

echo "Done!"