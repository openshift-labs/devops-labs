

# Delete Lab Resources
oc delete project dev prod lab-infra 2>/dev/null
oc delete bc --all -n openshift --as=system:admin
oc delete is -l demo=coolstore-microservice -n openshift --as=system:admin
oc delete template coolstore -n openshift --as=system:admin
echo "Done!"