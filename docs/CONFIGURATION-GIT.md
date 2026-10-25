# Configuration through UI and Git

UI saves automatically preserve shared rules and individual/bulk exceptions in controller-owned Git history. Open **Configuration → Configuration history and Git access** to inspect the accepted revision and before/after changes. A save is durable immediately; runner adoption and fresh measurements are shown separately. Check definitions, source defaults, secrets, maintenance and incidents are outside this repository.

## Enable optional Git access

UI history needs no setup. To allow Git clients, generate a separate token on the controller host (`openssl rand -hex 32`) and put it in `controller.env` as `MONDEK_CONFIGURATION_GIT_TOKEN=…`. Recreate the controller with the normal deployment workflow. Do not put the token in Git, a URL or an agent prompt. Unset means Git endpoints return 404. Existing UI configuration migrates automatically on first use; runners need no update for this feature.

The Git URL is `https://YOUR_CONTROLLER/configuration.git`. Use your Git credential helper, username `mondek`, and the token as password. Your HTTPS gateway must permit authorized requests to that path and its Git subpaths; runner-only Cloudflare policies do not automatically authorize configuration writes. Keep existing browser protection and supply any additional gateway credentials separately. The controller token remains required even after gateway authorization.

```sh
git clone https://YOUR_CONTROLLER/configuration.git mondek-config
cd mondek-config
git pull --ff-only
# Edit the appropriate JSON resource, preserving its key, scope and schema.
git diff
git add rules/CHANGED_RULE.json
git commit -m 'Adjust the production volume limits'
git push origin main
```

Only `refs/heads/main` accepts changes. Tags, other refs, branch deletion and non-fast-forward updates reject. Local working branches are fine. A push validates the entire resulting configuration before success; invalid values, unknown files, mismatched contracts, conflicting policy or excessive atomic impact leave the accepted head unchanged. A successful push means saved configuration, not proof of runner measurements. Inspect adoption in Configuration afterward.

If a UI save happened while you edited, fetch, inspect its changes and reconcile before retrying. Do not force-push. If a connection fails after submitting a push, fetch first: the requested commit may already be accepted. Repeating an accepted push does not create another configuration generation. Validation applies to the resulting main tree; intermediate commits remain Git history, not separately activated configurations. Review that history too before transferring it, and never commit secrets even temporarily.

## Interactive access through the existing Cloudflare application

For the personal dogfood installation, `/configuration.git` uses the existing browser Access application and its tunnel audience. The runner service token is scoped to runner API paths and should not be widened for this test. Use your interactive identity first; unattended Git access can have a separately scoped service credential later. Cloudflare documents [CLI login and the application token header](https://developers.cloudflare.com/cloudflare-one/tutorials/cli/).

With `cloudflared` installed, run this in Bash or Zsh on your workstation:

```sh
cloudflared access login https://monitoring.example.test >/dev/null
export WP_CF_HEADER="cf-access-token: $(cloudflared access token --app=https://monitoring.example.test)"
wp_git() {
  git --config-env=http.https://monitoring.example.test/.extraHeader=WP_CF_HEADER \
    -c credential.username=mondek "$@"
}
wp_git ls-remote https://monitoring.example.test/configuration.git refs/heads/main
wp_git clone https://monitoring.example.test/configuration.git mondek-config
```

At Git's password prompt, supply the Mondek configuration token from `controller.env`, not a Cloudflare token. The Cloudflare header stays in the current shell environment, outside repository configuration and command-line arguments. Refresh it after your Access session expires; `unset WP_CF_HEADER` removes the shell copy when finished. A login redirect/Cloudflare denial concerns the outer gateway; a Mondek Basic-auth challenge concerns the inner configuration token. Never share either token in diagnostic output.

For an initial write test without changing monitoring settings, enter the cloned directory, create an empty commit (`git commit --allow-empty -m 'Verify dogfood Git access'`) and use `wp_git push origin main`. History should show settings unchanged. Then test a deliberate UI adjustment followed by `wp_git pull --ff-only`, before reviewing a real parameter change through Git. A competing UI save may require fetching and reconciling even the empty test commit.

## Repository format

- `mondek.json`: exactly `{"version": 1}`.
- `rules/<key>.json`: one shared rule with its stable `key`, name, source/parameter contract, selectors, priority, enabled flag, captured parameter schema and complete parameter set. `managed_project` and `managed_key` preserve optional project organization; UI edits are permitted for these rules too.
- `exceptions/<key>.json`: one installation-specific exception. Its explicit scope names assignment, runner installation, source and check. Contract, schema, monitored environment and output target identities guard against accidentally applying it elsewhere. The stable filename/key is independent of a restored assignment UUID.

Use existing exported documents as the authoring template. Preserve full schemas and complete parameter sets; these files are not the older project manifest format. Unknown fields, executable files, symlinks and other resource types are rejected. Deleting a rule or exception explicitly requests fallback to remaining rules/defaults, which must also validate. Repository omission means removal, so never push a partial tree as if it were the complete desired configuration.

Rule creation requires compatible declarations already published by a runner. Existing rules retain their schema when no checks currently match. A whole edit can affect at most 512 scheduled checks; unchanged unrelated checks do not consume that limit. The final tree supports 512 rules, 4,096 resources and 4 MiB. Git transfer budgets also bound newly introduced history. Very large retained histories may exceed transport capacity; they are preserved in PostgreSQL, with an explicit transport error rather than partial history or silent pruning.

## Restore to a new installation

Keep a normal clone independently of the controller. First start the new controller and publish the matching consumer declarations through its runners. Do not copy runner sessions, measurement state or incidents from the configuration clone. Clone the new controller into a separate directory; its initial main commit is the required baseline.

For a snapshot restore, copy the saved `rules/` and `exceptions/` documents into that new checkout. Retain its `mondek.json`; do not copy `.git` over the new checkout. Review every installation-specific exception: inspect the corresponding new scheduled check and runner, verify source/check/contract/environment/output identities, and change only its `scope.assignment_id` and `scope.runner_installation_id` to the explicitly intended instances. Keep its filename and `key`. Missing declarations and unresolved old scopes reject with guidance; they never silently broaden or disappear. Omit an old exception only after deliberately deciding to remove it.

If retaining old Git ancestry matters, use an explicit merge instead of copying a snapshot. In the **new** checkout:

```sh
git remote add saved /ABSOLUTE/PATH/TO/SAVED/CLONE
git fetch saved
git merge --allow-unrelated-histories --no-commit -s ours saved/main
# Restore only directories that exist in the saved tree:
git restore --source saved/main -- rules exceptions
# Review and explicitly map exception scopes as described above.
git diff
git add rules exceptions
git commit -m 'Restore reviewed monitoring configuration'
git push origin main
```

The merge retains old history while the new installation's main remains an ancestor. Review removals as well as additions if the new installation already has settings. No force push is needed. After acceptance, verify runner adoption and actual measurements. Restoring a snapshot/history is separate from restoring an entire installation database.

## Local verification

```sh
devenv shell -- mondek configuration-acceptance
devenv shell -- mondek configuration-acceptance --browser
```

These use isolated Docker services, installed observers and ordinary Git HTTP clients. The optional browser checkpoint pauses before cleanup. Tests cover UI-equivalent saves, stale and invalid pushes, unsupported refs, measured adoption, controller restart and fresh-installation restoration with explicit exception mapping. Native tests additionally cover killed transactions, response loss and competing writers. They do not deploy personal monitoring or verify production gateway policy.
