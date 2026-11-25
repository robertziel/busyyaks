// busyyaks CI: every pushed branch runs scripts/ci/test.sh — RuboCop + ShellCheck, the Ruby suite (the compose `test`
// service), the SPA's tsc + ESLint + vitest, the flake gate (the tests the change touches, repeated), the
// dependency audit (bundle-audit + npm audit), gitleaks over the full history and the host-side tests on the oldest host
// Ruby (scripts/ci/test.sh host) — and reports ONE GitHub commit status, context `jenkins/ci`, whose link is this build.
// A PR shows its head branch's status. The test stages run on the public runner's CPU quota (docker --cpus, scripts/ci/runner.env).
//
// Daily: the default branch's job (the one branch job: the filter builds only it and PRs) also builds once a
// day, so an advisory published since the last push is found by that build, not by the next feature PR. A red DAILY
// build opens (or comments on) the issue "Daily CI red on <branch>" on this repo (scripts/ci/github alert): GitHub
// notifies the repo's watchers — the maintainer — of it.
//
// Jenkins side: a multibranch job reading this file from SCM (this repository's own branches and pull requests; a
// fork's pull request is GitHub Actions', never here), an agent with a Docker CLI on a daemon it may start containers
// on — chosen by the controller's global env BUSYYAKS_CI_AGENT_LABEL (unset → the build fails: an agent, never the
// controller, runs the builds) — and the Secret Text credential `github-pat` (a token allowed to post statuses on this
// repo).
// The repo the status goes to is read from the checkout's origin remote — nothing about the deployment is written here.
//
// README badges (coverage · branches · tests): after the gates pass on the repository's DEFAULT branch (asked from
// GitHub, never a card/PR branch), scripts/ci/badges reads the Ruby + vitest summaries from this build's logs and
// PATCHes shields.io endpoint JSON into the public gist BADGE_GIST_ID (the one the README's badge URLs read) with the
// Secret Text credential BADGE_CREDENTIAL (a token that may write gists and nothing else: a fine-grained PAT with the
// account permission Gists = read/write, stored in THIS job's folder credential store — the other jobs on the
// controller cannot name it). A fork points these two at its own gist and credential. An update that fails fails the
// build, and the status then says the gates passed.
//
// Tokens never appear on a command line: this file runs no curl; scripts/ci/github and scripts/ci/badges call GitHub
// through scripts/ci/lib/github-api.sh, which feeds the Authorization header through a pipe (argv shows /dev/fd/N) —
// /proc/*/cmdline (ps) is readable by every uid. The token still sits in the step's env
// (/proc/*/environ: same uid only), which the other executor's build shares: the job, not the branch, is the boundary.
// Credential variables are only ever referenced from single-quoted shell, never Groovy-interpolated (that would write
// them into the build's flow-node XML).

pipeline {
  // `env` here is the controller's global env (Jenkinsfile code cannot set it before this point). A label that is unset,
  // or that the controller's job restrictions do not let this job run on, never builds: it fails or waits in the queue.
  agent { label requiredAgentLabel() }

  // Builds of one branch run side by side (card #573: a push to `local` no longer queues behind the build before it,
  // each lands on any free trusted agent). What two overlapping builds share is made safe where
  // it is shared: each posts the status of its OWN commit; the README badges are published only by the build of the
  // branch's current head (an older build that finishes last never writes over a newer one's numbers).
  options {
    timestamps()
    timeout(time: 60, unit: 'MINUTES')   // the gates + the install machines (card #573)
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  // No `triggers { githubPush() }`: the multibranch job's branch source already builds on the repo webhook's push
  // event, and a githubPush() trigger on the branch job built the same push a second time.
  // The daily build: branch jobs only (no CHANGE_ID) — the job's filter leaves the default branch as the one branch job.
  // A PR job gets cron('') = a TimerTrigger with an empty spec, which never fires.
  triggers { cron(env.CHANGE_ID ? '' : 'H 5 * * *') }

  environment {
    BADGE_GIST_ID = 'f4d62c00382e99d2952e6185510eeb75'
    BADGE_CREDENTIAL = 'badge-gist-token'
  }

  stages {
    stage('Checkout') {
      steps {
        script {
          // A fork's pull request is GitHub Actions' (disposable runners), never this Jenkins: its code would run on
          // this host. Jenkins builds the default branch and pull requests from this repository's own branches. Were
          // fork PR discovery ever switched on, an untrusted fork PR runs the default branch's copy of this file, so
          // this refusal holds there.
          if (env.CHANGE_FORK) {
            error("pull request ${env.CHANGE_ID} from fork ${env.CHANGE_FORK} refused: forks are built by GitHub Actions only")
          }
        }
        checkout scm
        script {
          env.GIT_SHA = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
          env.GH_REPO = sh(returnStdout: true, script: '''
            url=$(git config --get remote.origin.url)
            repo=$(printf '%s' "$url" | sed -nE 's#^(https://|git@|ssh://git@)github\\.com[:/]([^/]+/[^/]+)$#\\2#p' | sed 's#\\.git$##')
            [ -n "$repo" ] || { echo "origin $url is not a GitHub repo — nowhere to post the status" >&2; exit 1; }
            printf '%s' "$repo"
          ''').trim()
          env.DEFAULT_BRANCH = defaultBranch()
          // the flake gate's base (scripts/ci/test.sh flake): a PR's target branch, fetched (a PR build checks out the
          // PR head only); a branch build's previous commit
          if (env.CHANGE_ID) {
            withCredentials([string(credentialsId: 'github-pat', variable: 'GH_TOKEN')]) {
              sh 'scripts/ci/github fetch-base "$CHANGE_TARGET"'
            }
            env.CI_BASE_REF = "refs/remotes/origin/${env.CHANGE_TARGET}"
          } else {
            env.CI_BASE_REF = 'HEAD~1'
          }
          echo "Building ${env.GH_REPO}@${env.GIT_SHA} (${env.BRANCH_NAME}; default branch ${env.DEFAULT_BRANCH})"
          sh 'rm -rf "$WORKSPACE_TMP/ci-logs" "$WORKSPACE_TMP/badges"'
        }
        notifyGitHub('pending', 'Lint + Ruby suite (SQLite + PostgreSQL) + frontend + flake + audit + secrets + host Ruby + distros, then install running')
      }
    }

    stage('Gates') {
      parallel {
        stage('Lint')       { steps { gate('lint') } }
        stage('Ruby suite') { steps { gate('ruby') } }
        stage('Ruby suite (PostgreSQL)') { steps { gate('ruby-pg') } }
        stage('Frontend')   { steps { gate('frontend') } }
        stage('Flake')      { steps { gate('flake') } }
        // the libgit2 audit reads GitHub authenticated: github-pat as CI_GITHUB_READ_TOKEN, by name
        stage('Audit')      { steps { withCredentials([string(credentialsId: 'github-pat', variable: 'CI_GITHUB_READ_TOKEN')]) { gate('audit') } } }
        stage('Secrets')    { steps { gate('secrets') } }
        stage('Host Ruby')  { steps { gate('host') } }
        stage('Distros')    { steps { gate('distros') } }
      }
      post { success { script { env.GATES_PASSED = 'true' } } }
    }

    // Install FOR REAL (card #573): each its own disposable machine (scripts/ci/machine-run: systemd, a user
    // manager and a Docker daemon of its own, in a privileged container of this agent's ROOTLESS daemon). The README
    // Quickstart → the stack → the systemd --user installers → doctor → the desktop entry. After the gates, so a red
    // gate costs no machine; two machines at a time per build (each peaks ~4 GB of memory and ~2.6 GB of disk); across builds the agent's
    // executors bound them: at most 2 × its executors machines run on one agent at once. Screenshots
    // and a failure's logs are archived with the build (ci-artifacts/).
    // no credential is bound here: a machine runs the change's own code as its root
    stage('Machine image') { steps { gate('machine-image') } }
    stage('Install') {
      environment { CI_ARTIFACTS = "${env.WORKSPACE}/ci-artifacts" }
      parallel {
        stage('Install (SQLite)')     { steps { gate('install') } }
        stage('Install (PostgreSQL)') { steps { gate('install-pg') } }
      }
      post { success { script { env.MACHINES_PASSED = 'true' } } }
    }

    stage('Badges') {
      when { expression { env.BRANCH_NAME == env.DEFAULT_BRANCH && !env.CHANGE_ID } }
      steps {
        script {
          // read once, a few seconds before the publish: a newer head's build is ≥ 20 min behind this point, so it
          // publishes after this one whenever the head moves in between
          String head = branchHead(env.BRANCH_NAME)
          env.BADGES_FROM_HEAD = (head == env.GIT_SHA) ? 'true' : 'false'
          if (env.BADGES_FROM_HEAD != 'true') { echo "Badges NOT published by this build: ${env.BRANCH_NAME} is at ${head} now, this build is ${env.GIT_SHA}: the head's build publishes them" }
        }
        withCredentials([string(credentialsId: env.BADGE_CREDENTIAL, variable: 'GIST_TOKEN')]) {
          sh '''#!/usr/bin/env bash
            set -euo pipefail
            [ "$BADGES_FROM_HEAD" = true ] || exit 0
            scripts/ci/badges render "$WORKSPACE_TMP/badges" "$WORKSPACE_TMP/ci-logs/ruby.log" "$WORKSPACE_TMP/ci-logs/frontend.log"
            scripts/ci/badges publish "$BADGE_GIST_ID" "$WORKSPACE_TMP/badges"
          '''
        }
      }
    }
  }

  post {
    always   { archiveArtifacts artifacts: 'ci-artifacts/**', allowEmptyArchive: true }
    success  { notifyGitHub('success', 'Gates (lint · ruby · ruby-pg · frontend · flake · audit · secrets · host · distros) + install passed') }
    failure  {
      notifyGitHub('failure', env.MACHINES_PASSED ? 'Gates + install passed; README badge update failed — see the build log' : env.GATES_PASSED ? 'Gates passed; machine image / install failed — see the build log' : 'CI failed — see the build log')
      script { if (dailyBuild()) { alertGitHub("Daily CI red on ${env.BRANCH_NAME}", 'The daily build of this branch failed; the build log says which stage and why.') } }
    }
    unstable { notifyGitHub('failure', 'CI unstable') }
    aborted  { notifyGitHub('error', 'Build aborted') }
    cleanup  { cleanWs() }
  }
}

// The agent label the controller sets for this job (global env BUSYYAKS_CI_AGENT_LABEL). No default: an unset label
// would let `agent any` land the build on the controller itself.
String requiredAgentLabel() {
  String label = env.BUSYYAKS_CI_AGENT_LABEL
  if (!label?.trim()) {
    error('BUSYYAKS_CI_AGENT_LABEL is not set on this Jenkins (Manage Jenkins → System → Global properties) — the label of the agents that run this job')
  }
  return label.trim()
}

// One gate, its output also kept in $WORKSPACE_TMP/ci-logs/<suite>.log (outside the checkout) for the badges.
void gate(String suite) {
  sh """#!/usr/bin/env bash
    set -euo pipefail
    export CI_GITHUB_CACHE_DIR="\$HOME/.cache/busyyaks-ci/github-etags"   # the agent user's, kept across builds
    mkdir -p "\$WORKSPACE_TMP/ci-logs"
    scripts/ci/test.sh ${suite} 2>&1 | tee "\$WORKSPACE_TMP/ci-logs/${suite}.log"
  """
}


// A build the cron trigger started (the daily build), not a push or a PR
boolean dailyBuild() {
  return !currentBuild.getBuildCauses('hudson.triggers.TimerTrigger$TimerTriggerCause').isEmpty()
}

// scripts/ci/github alert: the open issue with this title gets a comment, or a new issue is opened. Title and text reach
// the script as env, so nothing Groovy-interpolates into the shell.
void alertGitHub(String title, String text) {
  withCredentials([string(credentialsId: 'github-pat', variable: 'GH_TOKEN')]) {
    withEnv(["ALERT_TITLE=${title}", "ALERT_TEXT=${text}"]) {
      sh 'scripts/ci/github alert "$ALERT_TITLE" "$ALERT_TEXT"'
    }
  }
}

// The sha a branch points at now (scripts/ci/github branch-head). Unreadable fails the build.
String branchHead(String branch) {
  withCredentials([string(credentialsId: 'github-pat', variable: 'GH_TOKEN')]) {
    withEnv(["HEAD_BRANCH=${branch}"]) {
      return sh(returnStdout: true, script: 'scripts/ci/github branch-head "$HEAD_BRANCH"').trim()
    }
  }
}

// GitHub's default branch for this repo (scripts/ci/github default-branch). Unreadable fails the build.
String defaultBranch() {
  withCredentials([string(credentialsId: 'github-pat', variable: 'GH_TOKEN')]) {
    return sh(returnStdout: true, script: 'scripts/ci/github default-branch').trim()
  }
}

// The jenkins/ci commit status (scripts/ci/github status). A status that cannot be posted FAILS the build: a green
// build GitHub never heard about would look exactly like a PR with no CI. State and text reach the script as env, so
// nothing Groovy-interpolates into the shell.
void notifyGitHub(String state, String description) {
  if (!env.GIT_SHA || !env.GH_REPO) { error("no commit/repo known yet — cannot post GitHub status ${state}") }
  withCredentials([string(credentialsId: 'github-pat', variable: 'GH_TOKEN')]) {
    withEnv(["GH_STATE=${state}", "GH_DESCRIPTION=${description}"]) {
      sh 'scripts/ci/github status "$GH_STATE" "$GH_DESCRIPTION"'
    }
  }
}
