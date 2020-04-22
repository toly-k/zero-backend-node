---
version: 2.1
orbs:
  aws-ecr: circleci/aws-ecr@6.5.0
  aws-eks: circleci/aws-eks@0.2.3
  aws-s3: circleci/aws-s3@1.0.11
  aws-cli: circleci/aws-cli@0.1.18
  queue: eddiewebb/queue@1.3.0
  slack: circleci/slack@3.4.2
  version-tag: commitdev/version-tag@0.0.3

variables:
  - &workspace /home/circleci/project
  <% if (index .Params `language`) and eq index .Params `language` "go" %>
  - &build-image cimg/go:1.13
  <% else if (index .Params `language`) and eq index .Params `language` "nodejs" %>
  - &build-image cimg/node:12.6
  <% else %>
  - &build-image cimg/base:2020.01
  <% end %>

aliases:
  # Shallow Clone - this allows us to cut the 2 minute repo clone down to about 10 seconds for repos with 50,000 commits+
  - &checkout-shallow
    name: Checkout (Shallow)
    command: |
      #!/bin/sh
      set -e

      # Workaround old docker images with incorrect $HOME
      # check https://github.com/docker/docker/issues/2968 for details
      if [ "${HOME}" = "/" ]
      then
        export HOME=$(getent passwd $(id -un) | cut -d: -f6)
      fi

      mkdir -p ~/.ssh

      echo 'github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==
      bitbucket.org ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAubiN81eDcafrgMeLzaFPsw2kNvEcqTKl/VqLat/MaB33pZy0y3rJZtnqwR2qOOvbwKZYKiEO1O6VqNEBxKvJJelCq0dTXWT5pbO2gDXC6h6QDXCaHo6pOHGPUy+YBaGQRGuSusMEASYiWunYN0vCAI8QaXnWMXNMdFP3jHAJH0eDsoiGnLPBlBp4TNm6rYI74nMzgz3B9IikW4WVK+dc8KZJZWYjAuORU3jc1c/NPskD2ASinf8v3xnfXeukU0sJ5N6m5E8VLjObPEO+mN2t/FZTMZLiFqPWc/ALSqnMnnhwrNi2rbfg/rd/IpL8Le3pSBne8+seeFVBoGqzHM9yXw==' >> ~/.ssh/known_hosts

      (umask 077; touch ~/.ssh/id_rsa)
      chmod 0600 ~/.ssh/id_rsa
      (cat \<<EOF > ~/.ssh/id_rsa
      $CHECKOUT_KEY
      EOF
      )

      # use git+ssh instead of https
      git config --global url."ssh://git@github.com".insteadOf "https://github.com" || true

      if [ -e /home/circleci/project/.git ]
      then
          cd /home/circleci/project
          git remote set-url origin "$CIRCLE_REPOSITORY_URL" || true
      else
          mkdir -p /home/circleci/project
          cd /home/circleci/project
          git clone --depth=1 "$CIRCLE_REPOSITORY_URL" .
      fi

      if [ -n "$CIRCLE_TAG" ]
      then
        git fetch --depth=10 --force origin "refs/tags/${CIRCLE_TAG}"
      elif [[ "$CIRCLE_BRANCH" =~ ^pull\/* ]]
      then
      # For PR from Fork
        git fetch --depth=10 --force origin "$CIRCLE_BRANCH/head:remotes/origin/$CIRCLE_BRANCH"
      else
        git fetch --depth=10 --force origin "$CIRCLE_BRANCH:remotes/origin/$CIRCLE_BRANCH"
      fi

      if [ -n "$CIRCLE_TAG" ]
      then
          git reset --hard "$CIRCLE_SHA1"
          git checkout -q "$CIRCLE_TAG"
      elif [ -n "$CIRCLE_BRANCH" ]
      then
          git reset --hard "$CIRCLE_SHA1"
          git checkout -q -B "$CIRCLE_BRANCH"
      fi

      git reset --hard "$CIRCLE_SHA1"
      pwd

<% if index .Params `assumeRole` %>
  - &assume-role
      name: Assume role
      command: |
        RESULT=$(aws sts assume-role --role-arn << parameters.cluster-authentication-role-arn >> --role-session-name deploy)
        aws configure set aws_access_key_id "$(echo $RESULT | jq -r .Credentials.AccessKeyId)" --profile assumed-role
        aws configure set aws_secret_access_key "$(echo $RESULT | jq -r .Credentials.SecretAccessKey)" --profile assumed-role
        aws configure set aws_session_token "$(echo $RESULT | jq -r .Credentials.SessionToken)" --profile assumed-role
<% end %>

  - &install-binaries
      name: Install Binaries
      command: |
        KUSTOMIZE_VERSION=3.5.4
        IAM_AUTH_VERSION=0.5.0
        curl -L -o ./kustomize.tar.gz "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
        sudo tar xvzf ./kustomize.tar.gz -C /usr/local/bin/
        sudo chmod +x /usr/local/bin/kustomize
        kustomize version
        curl -L -o ./aws-iam-authenticator "https://github.com/kubernetes-sigs/aws-iam-authenticator/releases/download/v${IAM_AUTH_VERSION}/aws-iam-authenticator_${IAM_AUTH_VERSION}_linux_amd64"
        sudo mv ./aws-iam-authenticator /usr/local/bin/
        sudo chmod +x /usr/local/bin/aws-iam-authenticator


jobs:
  checkout_code:
    docker:
      - image: *build-image
    steps:
      - run: *checkout-shallow
      - persist_to_workspace:
          root: /home/circleci/project
          paths:
            - .

  unit_test:
    docker:
      - image: *build-image
    working_directory: *workspace
    steps: # steps that comprise the `build` job
      - attach_workspace:
          at: *workspace

      - restore_cache: # restores saved cache if no changes are detected since last run
          keys:
            <% if (index .Params `language`) and eq index .Params `language` "go" %>
            - v1-pkg-cache-{{ checksum "go.sum" }}
            <% else if (index .Params `language`) and eq index .Params `language` "nodejs" %>
            - v1-pkg-cache-{{ checksum "package-lock.json" }}
            <% end %>
            - v1-pkg-cache-
      - run:
          name: Run unit tests
          command: |
          <% if (index .Params `language`) and eq index .Params `language` "go" %>
            go get -u github.com/jstemmer/go-junit-report
            mkdir -p test-reports
            PACKAGE_NAMES=$(go list ./... | circleci tests split --split-by=timings --timings-type=classname)
            echo "Tests: $PACKAGE_NAMES"
            go test -v $PACKAGE_NAMES | go-junit-report > test-reports/junit.xml
          <% else if (index .Params `language`) and eq index .Params `language` "nodejs" %>
            npm test
          <% else %>
            # Add your command to run unit tests here.
          <% end %>


      - save_cache: # Store cache in the /go/pkg directory
          <% if (index .Params `language`) and eq index .Params `language` "go" %>
          key: v1-pkg-cache-{{ checksum "go.sum" }}
          <% else if (index .Params `language`) and eq index .Params `language` "nodejs" %>
          key: v1-pkg-cache-{{ checksum "package-lock.json" }}
          <% end %>
          paths:
            <% if (index .Params `language`) and eq index .Params `language` "go" %>
            - "/go/pkg"
            <% else if (index .Params `language`) and eq index .Params `language` "nodejs" %>
            - "node_modules"
            <% end %>

      - store_test_results:
          path: test-reports

      - store_artifacts:
          path: test-reports

      # Requires the SLACK_WEBHOOK
      - slack/notify-on-failure

  build_and_push:
    machine:
      docker_layer_caching: <% if index .Params `circleCIPro` %>true<% else %>false<% end %> # only for performance plan circleci accounts
    steps:
      - attach_workspace:
          at: *workspace
      - run: *checkout-shallow
      - version-tag/create
      <% if index .Params `assumeRole` %>
      - aws-cli/install
      - aws-cli/setup
      - aws-ecr/ecr-login-for-secondary-account:
          account-id: AWS_ECR_REPO_ACCOUNT_ID
          region: AWS_DEFAULT_REGION
      - aws-ecr/build-image:
          repo: <% .Name %>
          tag: $VERSION_TAG,latest
      - aws-ecr/push-image:
          repo: <% .Name %>
          tag: $VERSION_TAG,latest
      <% else %>
      - aws-ecr/build-and-push-image:
          repo: <% .Name %>
          tag: $VERSION_TAG,latest
      <% end %>

  deploy:
    executor: aws-eks/python3
    parameters:
      namespace:
        type: string
        default: ''
        description: |
          The kubernetes namespace that should be used.
      repo:
        type: string
        default: ''
        description: |
          The name of the ECR repo to deploy an image from.
      config-environment:
        type: string
        default: ''
        description: |
          The environment kustomize should overlay to generate the kubernetes config. Options are the directories in kubernetes/overlays/
      tag:
        type: string
        default: $VERSION_TAG
        description: |
          The tag that should be deployed.
      region:
        type: string
        default: ''
        description: |
          The region to use for AWS operations.
      cluster-name:
        description: |
          The name of the EKS cluster.
        type: string
      cluster-authentication-role-arn:
        default: ''
        description: |
          To assume a role for cluster authentication, specify an IAM role ARN with
          this option. For example, if you created a cluster while assuming an IAM
          role, then you must also assume that role to connect to the cluster the
          first time.
        type: string
    steps:
      - run: *checkout-shallow
      - version-tag/get
      - run: *install-binaries
      - aws-cli/install
      - aws-cli/setup
      - run: *assume-role
      - aws-eks/update-kubeconfig-with-authenticator:
          cluster-name: << parameters.cluster-name >>
          cluster-authentication-role-arn: << parameters.cluster-authentication-role-arn >>
          aws-region: << parameters.region >>
          install-kubectl: true
          aws-profile: assumed-role
      - queue/until_front_of_line:
          time: '30'
      - run:
          name: Deploy
          command: |
            cd kubernetes/overlays/<< parameters.config-environment >>
            IMAGE=${AWS_ECR_ACCOUNT_URL}/<< parameters.repo >>
            kustomize edit set image fake-image=${IMAGE}:${VERSION_TAG}
            kustomize build . | kubectl apply -f - -n << parameters.namespace >>
workflows:
    version: 2
    # The main workflow. Check out the code, build it, push it, deploy to staging, test, deploy to production
    build_test_and_deploy:
      jobs:
        - checkout_code

        - unit_test:
            requires:
              - checkout_code

        - build_and_push:
            requires:
              - unit_test
            filters:
              branches:
                only:  # only branches matching the below regex filters will run
                  - /^master$/

        - deploy:
            name: deploy_staging
            repo: "<% .Name %>"
            cluster-name: "<% index .Params `stagingClusterName` %>"
            config-environment: "staging"
            <% if index .Params `assumeRole` %>cluster-authentication-role-arn: "${AWS_CLUSTER_AUTH_ROLE_ARN_STAGING}"<% end %>
            region: "${AWS_DEFAULT_REGION}"
            namespace: "${CIRCLE_BRANCH}"
            tag: "${VERSION_TAG}"
            requires:
              - build_and_push

        - wait_for_approval:
            type: approval
            requires:
              - deploy_staging

        - queue/block_workflow:
            time: '30' # hold for 30 mins then abort
            requires:
              - wait_for_approval

        - deploy:
            name: deploy_production
            repo: "<% .Name %>"
            cluster-name: "<% index .Params `productionClusterName` %>"
            config-environment: "production"
            <% if index .Params `assumeRole` %>cluster-authentication-role-arn: "${AWS_CLUSTER_AUTH_ROLE_ARN_PRODUCTION}"<% end %>
            region: "${AWS_DEFAULT_REGION}"
            namespace: "${CIRCLE_BRANCH}"
            tag: "${VERSION_TAG}"
            requires:
              - queue/block_workflow
