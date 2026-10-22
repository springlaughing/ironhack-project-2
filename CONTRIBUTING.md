# Contributing

How work is organized in this repository.

## Workflow

1. Every change starts from an issue. Pick one, or create it first.
2. Create a branch linked to the issue:
   ```bash
   gh issue develop <number> --checkout
   ```
   Or by hand, named after the issue: `step2-k8s-data-tier`.
3. Make small commits, one logical change each (format below).
4. Test before opening a pull request:
   - the changed images build (`docker build`)
   - `kubectl apply -f k8s/` succeeds and all pods are `Running` and ready
   - one vote on the Vote page shows up on the Result page
   - the experiments related to the change pass
5. Open a pull request to `main` with `Closes #<number>` in the description.
   Merging closes the issue.

`main` must always work.

### Committing straight to `main`

Allowed only for changes that can't break anything that runs:

- `docs`: README, this guide, results, typos
- `chore`: `.gitignore`, renames of files nothing refers to

Everything else goes through an issue and a pull request: app code,
Dockerfiles, manifests, `setup-cluster.sh`, the pipeline and experiment
scripts. If you're unsure, it's not a direct commit.

## Issues and labels

There is no project board: the open issues are the plan. Every issue gets
one label for its part, so the Issues tab can be filtered by label.

| Label | For |
| --- | --- |
| `app` | Changes to Vote, Result or Worker and their Dockerfiles |
| `k8s` | Kubernetes manifests |
| `cluster` | Cluster setup: `setup-cluster.sh`, controllers, cert-manager |
| `ci` | The GitHub Actions pipeline |
| `experiment` | One experiment: what to run, what to measure, the result |
| `docs` | README, write-up, slides |
| `bug` | Something an experiment or a test proved broken (add it next to the part label) |

Create them once:

```bash
gh label create app        --color 1d76db --description "Vote, Result, Worker, Dockerfiles"
gh label create k8s        --color 326ce5 --description "Kubernetes manifests"
gh label create cluster    --color 5319e7 --description "Cluster setup and controllers"
gh label create ci         --color 0e8a16 --description "GitHub Actions pipeline"
gh label create experiment --color fbca04 --description "An experiment and its result"
gh label create docs       --color c5def5 --description "README, write-up, slides" --force
gh label create bug        --color d73a4a --description "Proven broken" --force
```

## Branch names

`<step>-<part>-<short-topic>`, for example:

| Branch | Issue |
| --- | --- |
| `step1-vote-threads` | Vote: run gunicorn with threads in the image |
| `step2-k8s-data-tier` | Kubernetes: Redis and PostgreSQL with persistent volumes |
| `step3-ci-deploy` | Pipeline: build, push and deploy on every merge |

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/): `type(scope): description`

- **description:** imperative ("add", not "added"), lower case, under 72
  characters, no period

### Type: what kind of change?

| Type | Use it when | Ask yourself | Example |
| --- | --- | --- | --- |
| `feat` | The app or the cluster can do something it couldn't before | "Is there something new a user or operator can see or use?" | `feat(k8s): run Vote and Result behind the gateway` |
| `fix` | Something worked wrong and now works right | "Was this a bug, or did an experiment prove it broken?" | `fix(k8s): add readiness probe so updates drop no votes` |
| `refactor` | The code is cleaner, but the behavior is exactly the same | "Would a user notice any difference? No → refactor" | `refactor(k8s): move shared settings into a ConfigMap` |
| `perf` | Same behavior, but faster or uses less | "Is the only goal speed or resources?" | `perf(vote): run gunicorn with 4 threads per process` |
| `docs` | Only text for humans: README, guides, comments, runbooks | "Does no code or config change?" | `docs: add rollout experiment results` |
| `test` | Load tests, experiment scripts, test data | "Does this only check things, without changing them?" | `test: add k6 script with a configurable vote rate` |
| `build` | How images are built: Dockerfiles, dependencies | "Does it change what goes into an image?" | `build(result): pin Node to version 20 in the Dockerfile` |
| `ci` | Automatic pipelines (GitHub Actions) | "Does it change something that runs on GitHub?" | `ci: build and push images on every merge` |
| `chore` | Housekeeping that changes no behavior | "Is it tidying: `.gitignore`, renames, tool settings?" | `chore: copy app code from ironhack-project-1` |

### Scope: which part of the project?

The scope is the folder or component you changed. Leave it out when the
change spans the whole project: `docs: add contributing guide`.

| Scope | Covers | Example |
| --- | --- | --- |
| `vote` | `vote/`: the Flask voting page | `feat(vote): add readiness endpoint` |
| `result` | `result/`: the Node results page | `fix(result): reconnect after a database restart` |
| `worker` | `worker/`: the .NET Worker | `fix(worker): keep the in-progress list across restarts` |
| `k8s` | `k8s/`: Kubernetes manifests | `feat(k8s): add Worker deployment with 3 replicas` |
| `cluster` | `setup-cluster.sh` and what runs once per cluster (controllers, cert-manager) | `feat(cluster): install the gateway controller` |
| `db` | Database tables and settings | `fix(db): add unique rule on voter id` |
| `redis` | Redis settings | `feat(redis): turn on the append-only file` |

### Tricky cases

| Situation | Choose | Why |
| --- | --- | --- |
| A rollout experiment showed errors; a readiness probe fixes them | `fix(k8s)` | It was proven broken; now it isn't |
| First version of the Redis and PostgreSQL manifests | `feat(k8s)` | New infrastructure is new behavior |
| Raising the Vote replicas from 2 to 4 | `feat(k8s)` | New capability: more Vote pods |
| Moving `--threads 4` from Ansible into the Vote Dockerfile | `perf(vote)` | The reason for the threads is speed (85× in Project 1) |
| The pipeline's deploy step uses the wrong namespace | `fix(ci)` | A bug in the pipeline is still a bug |
| Fixing a typo in a comment inside `k8s/` | `docs(k8s)` | Only text for humans changed |
| One commit needs two types | Split it into two commits | One commit, one reason |

When in doubt between two types, pick the one that answers "why would
someone read this commit later?". If you still can't decide, the commit
probably does two things: split it.

The body explains **why**, not what. Link the issue in the last line.

```
fix(k8s): add readiness probe so updates drop no votes

Without a probe, new Vote pods got traffic before gunicorn was
listening (rollout experiment: requests failed during every update).

Closes #12
```

### Commit template

The template is in the repository as `.gitmessage`, so every computer gets
the same version with `git pull`. Git doesn't use it automatically: turn it
on once per clone, from the project folder:

```bash
git config commit.template .gitmessage
git config core.editor nano
```

Settings made with `git config` (without `--global`) apply to this
repository only and are not committed, so repeat this on every computer.

Then commit with `git commit` (without `-m`): nano opens with the template.
Lines starting with `#` are hints and are left out of the message.

## Secrets

Never commit passwords, keys, `.env` files, kubeconfig files or Kubernetes
Secret manifests with real values. `.gitignore` blocks the usual ones. A
secret that was pushed once stays in the history: change the secret, don't
just delete the file.