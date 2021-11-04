#!/bin/bash
###eksctl scale nodegroup --cluster=managed-smartcheck --nodes=1 --name=<nodegroupName>
printf '%s\n' "------------------------------------------"
printf '%s\n' "     Deploying / Checking Smart Check     "
printf '%s\n' "------------------------------------------"

export EXISTINGSMARTCHECKOK="false"
# If no smartcheck deployment found, deploy it 
# ----------------------------------------------
if [[ "`helm list -n ${DSSC_NAMESPACE} -o json | jq -r '.[].name'`" =~ 'deepsecurity-smartcheck' ]]; then
    # found an existing DSSC
    [ ${VERBOSE} -eq 1 ] && printf "%s\n" "Found existing SmartCheck"
    #checking if we can get a bearertoken
    export DSSC_HOST=`kubectl get services proxy -n $DSSC_NAMESPACE -o json | jq -r "${DSSC_HOST_FILTER}"`
    [[ "${PLATFORM}" == "AZURE" ]] &&  export DSSC_HOST=${DSSC_HOST//./-}.nip.io
    [[ "${PLATFORM}" == "AWS" ]]  && export DSSC_HOST=${DSSC_HOST_RAW}
    [ ${VERBOSE} -eq 1 ] && printf "%s\n" "Getting a Bearer token"
    DSSC_BEARERTOKEN=''
    DSSC_BEARERTOKEN=$(curl -s -k -X POST https://${DSSC_HOST}/api/sessions -H "Content-Type: application/json"  -H "Api-Version: 2018-05-01" -H "cache-control: no-cache" -d "{\"user\":{\"userid\":\"${DSSC_USERNAME}\",\"password\":\"${DSSC_PASSWORD}\"}}" | jq '.token' | tr -d '"')
    [ ${VERBOSE} -eq 1 ] && printf "%s\n" "Bearer Token = ${DSSC_BEARERTOKEN}"
    if [[ ! -z "${DSSC_BEARERTOKEN}" ]]; then
        # existing DSSC + can get a Bearertoken
        export EXISTINGSMARTCHECKOK="true"
        printf '%s\n' "Reusing existing Smart Check deployment"
        export DSSC_HOST=`kubectl get services proxy -n $DSSC_NAMESPACE -o json | jq -r "${DSSC_HOST_FILTER}"`
        [[ "${PLATFORM}" == "AZURE" ]] &&  export DSSC_HOST=${DSSC_HOST//./-}.nip.io
        [[ "${PLATFORM}" == "AWS" ]]  && export DSSC_HOST=${DSSC_HOST_RAW}
    else  
      #existing DSSC found, but could not get a Bearertoken -> delete existing DSSC
      printf "%s" "Uninstalling existing (and broken) smartcheck... "
      helm delete deepsecurity-smartcheck -n ${DSSC_NAMESPACE}
      printf '\n%s' "Waiting for SmartCheck pods to be deleted"
      export NROFPODS=`kubectl get pods -A | grep -c smartcheck`
      while [[ "${NROFPODS}" -gt "0" ]];do
        sleep 5
        export NROFPODS=`kubectl get pods -A | grep -c smartcheck`
        printf '%s' "."
      done
    fi
fi


if [[  "${EXISTINGSMARTCHECKOK}" == "false" ]]; then
  # (re-)install smartcheck 
  #get certificate for internal registry
  #-------------------------------------
cat << EOF > ${WORKDIR}/req.conf
# This file is (re-)generated by code.
# Any manual changes will be overwritten.
[req]
  distinguished_name=req
[san]
  subjectAltName=DNS:${DSSC_SUBJECTALTNAME}
EOF
  
  NAMESPACES=`kubectl get namespaces`
  if [[ "$NAMESPACES" =~ "${DSSC_NAMESPACE}" ]]; then
    printf '%s\n' "Reusing existing namespace \"${DSSC_NAMESPACE}\""
  else
    printf '%s' "Creating namespace smartcheck...   "
    kubectl create namespace ${DSSC_NAMESPACE}
  fi
  
  printf '%s' "Creating certificate for loadballancer...  "
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes -keyout ${WORKDIR}/k8s.key -out ${WORKDIR}/k8s.crt -subj "/CN=${DSSC_SUBJECTALTNAME}" -extensions san -config ${WORKDIR}/req.conf
  
  printf '%s' "Creating secret with keys in Kubernetes...  "
  kubectl create secret tls k8s-certificate --cert=${WORKDIR}/k8s.crt --key=${WORKDIR}/k8s.key --dry-run=client -n ${DSSC_NAMESPACE} -o yaml | kubectl apply -f -
  
  
  # Create overrides.yml
  #-------------------------
  printf '%s\n' "Creating overrides.yml file in work directory"
  cat << EOF >${WORKDIR}/overrides.yml
# This file is (re-) generated by code.
# Any manual changes will be overwritten.
#
##
## Default value: (none)
activationCode: '${DSSC_AC}'
auth:
  ## secretSeed is used as part of the password generation process for
  ## all auto-generated internal passwords, ensuring that each installation of
  ## Deep Security Smart Check has different passwords.
  ##
  ## Default value: {must be provided by the installer}
  secretSeed: 'just_anything-really_anything'
  ## userName is the name of the default administrator user that the system creates on startup.
  ## If a user with this name already exists, no action will be taken.
  ##
  ## Default value: administrator
  ## userName: administrator
  userName: '${DSSC_USERNAME}'
  ## password is the password assigned to the default administrator that the system creates on startup.
  ## If a user with the name 'auth.userName' already exists, no action will be taken.
  ##
  ## Default value: a generated password derived from the secretSeed and system details
  ## password: # autogenerated
  password: '${DSSC_TEMPPW}'
registry:
  ## Enable the built-in registry for pre-registry scanning.
  ##
  ## Default value: false
  enabled: true
    ## Authentication for the built-in registry
  auth:
    ## User name for authentication to the registry
    ##
    ## Default value: empty string
    username: '${DSSC_REGUSER}'
    ## Password for authentication to the registry
    ##
    ## Default value: empty string
    password: '${DSSC_REGPASSWORD}'
    ## The amount of space to request for the registry data volume
    ##
    ## Default value: 5Gi
  dataVolume:
    sizeLimit: 10Gi
certificate:
  secret:
    name: k8s-certificate
    certificate: tls.crt
    privateKey: tls.key
vulnerabilityScan:
  requests:
    cpu: 1000m
    memory: 3Gi
  limits:
    cpu: 1000m
    memory: 3Gi
EOF
      
  printf '%s' "Deploying SmartCheck Helm chart..."
  helm install -n ${DSSC_NAMESPACE} --values ${WORKDIR}/overrides.yml deepsecurity-smartcheck https://github.com/deep-security/smartcheck-helm/archive/master.tar.gz > /dev/null
  export DSSC_HOST=''
  export DSSC_HOST_RAW=''
  while [[ -z "$DSSC_HOST_RAW" ]];do
    export DSSC_HOST_RAW=`kubectl get svc -n ${DSSC_NAMESPACE} proxy -o json | jq -r "${DSSC_HOST_FILTER}" 2>/dev/null`
    sleep 10
    printf "%s" "."
  done
  [[ "${PLATFORM}" == "AZURE" ]] &&  export DSSC_HOST=${DSSC_HOST_RAW//./-}.nip.io
  [[ "${PLATFORM}" == "AWS" ]]  && export DSSC_HOST=${DSSC_HOST_RAW}
  [ ${VERBOSE} -eq 1 ] && printf "\n%s\n" "DSSC_HOST=${DSSC_HOST}"
  printf '\n%s' "Waiting for SmartCheck Service to come online: ."
  export DSSC_BEARERTOKEN=''
  while [[ "$DSSC_BEARERTOKEN" == '' ]];do
    sleep 5
    export DSSC_BEARERTOKEN_RAW=`curl -s -k -X POST https://${DSSC_HOST}/api/sessions -H "Content-Type: application/json"  -H "Api-Version: 2018-05-01" -H "cache-control: no-cache" -d "{\"user\":{\"userid\":\"${DSSC_USERNAME}\",\"password\":\"${DSSC_TEMPPW}\"}}" 2>/dev/null `
    export DSSC_BEARERTOKEN=`echo ${DSSC_BEARERTOKEN_RAW} | jq -r '.token'`
        printf '%s' "."
  done
 printf '\n' 
  export DSSC_USERID=`curl -s -k -X POST https://${DSSC_HOST}/api/sessions -H "Content-Type: application/json"  -H "Api-Version: 2018-05-01" -H "cache-control: no-cache" -d "{\"user\":{\"userid\":\"${DSSC_USERNAME}\",\"password\":\"${DSSC_TEMPPW}\"}}" | jq '.user.id'  2>/dev/null | tr -d '"' `
  [ ${VERBOSE} -eq 1 ] && printf "%s\n" "DSSC_BEARERTOKEN=${DSSC_BEARERTOKEN}"
  [ ${VERBOSE} -eq 1 ] && printf "%s\n" "DSSC_USERID=${DSSC_USERID}"
  
  printf '%s \n' " "
     
  # do mandatory initial password change
  #----------------------------------------
  printf '%s \n' "Doing initial (required) password change"
  DUMMY=`curl -s -k -X POST https://${DSSC_HOST}/api/users/${DSSC_USERID}/password -H "Content-Type:   application/json"  -H "Api-Version: 2018-05-01" -H "cache-control: no-cache" -H "authorization: Bearer ${DSSC_BEARERTOKEN}" -d "{  \"oldPassword\": \"${DSSC_TEMPPW}\", \"newPassword\": \"${DSSC_PASSWORD}\"  }"`
  printf '%s \n' "SmartCheck is available at: "
  printf '%s \n' "--------------------------------------------------"
  printf '%s \n' "     URL: https://${DSSC_HOST}"
  printf '%s \n' "     user: ${DSSC_USERNAME}"
  printf '%s \n' "     passw: ${DSSC_PASSWORD}"
fi 