# qubes-ansible-collections

Ansible collection for configuring and managing Qubes OS qubes.

Works with [qubes-ansible](https://github.com/QubesOS/qubes-ansible)
(`qubesos.core.qubes` connection, `qubesos.security.qubes_proxy` strategy).

## Installation

### From RPM (recommended)

In dom0:

```bash
sudo qubes-dom0-update qubes-ansible-setup
```

In a Fedora template:

```bash
sudo dnf install qubes-ansible-setup
```

### From source

```bash
ansible-galaxy collection build .
ansible-galaxy collection install qubesos-setup-*.tar.gz
```

## Roles

| Role | Target | Purpose |
|---|---|---|
| `bind_dirs` | qube | Persist paths across reboots via `/rw/bind-dirs/`. |
| `split_ssh` | template + qube (vault or client) | Install the `qubes-split-ssh` package in the template (it ships the `qubes.SshAgent` RPC service, the `split-ssh` CLI, the agent/forwarder helpers and systemd unit templates, and `/etc/profile.d/qubes-ssh.sh`); per-AppVM phase writes the vault name, default agent, and an `rc.local.d` drop-in that starts the agent/forwarder units. |
| `split_gpg` | template + qube (vault or client) | Install `qubes-gpg-split` packages (its `/etc/profile.d/qubes-gpg.sh` defaults `QUBES_GPG_DOMAIN` to `@default` when unconfigured); in the vault, ensure `~/.gnupg` exists. Vault routing is done in qrexec policy via `@default target=<vault>`. |
| `qsvc_qube` | template + qube | Install packages, add qubes-service systemd condition, enable units; drop per-service `rc.local.d/30-<svc>.rc` snippet (bind-dirs delegated to `bind_dirs`). |
| `qsvc_dom0` | dom0 | Enable `qvm-service` flag for a list of qubes. |

Roles that target both `template` and `qube` auto-detect the host's
klass via `qubesos.core.qube_facts` and run the appropriate phase.
The `split_ssh` and `split_gpg` roles also branch on a `*_role:
vault|client` variable set by the playbook.

## Playbooks

Templates are discovered automatically via `qubesos.core.qube_facts`.
All list variables accept comma-separated strings from `-e`. Target
qubes (and any templates that were modified) are halted at the end of
each playbook so changes take effect on next boot.

### Split-SSH

The playbook installs the `qubes-split-ssh` package in the vault and
client templates, runs per-agent `ssh-agent` instances in the vault,
spins up a forwarder unit per `(client, agent)` pair, and writes a
per-vault allow policy that permits exactly the pairs you ask for. The
deny-by-default policy comes from the `qubes-split-ssh-dom0` package.

Two ways to invoke it, depending on the isolation you need.

#### Single shared keyring

All clients use one agent. Pick this when every client is at the same
trust level and you just want one place for the keys.

```bash
ansible-playbook qubesos.setup.split_ssh \
  -e vault=vault-ssh -e clients=work,personal
```

The agent is named `default`; keys live in `~/.ssh/identities.d/default/`
in the vault.

#### Multi-agent with per-client isolation

Each client gets the specific agents you list for it. A compromised
`work` qube cannot read keys belonging to `personal`; qrexec policy
denies the call before it reaches the vault.

```bash
ansible-playbook qubesos.setup.split_ssh \
  -e vault=vault-ssh \
  -e 'client_agents={"work": ["work"], "personal": ["personal"]}'
```

#### Private agents plus a shared one

The common case: each qube has its own private keyring, but both also
share one agent for keys that are not sensitive enough to compartment
(deploy keys for a common repo, build-host keys reused across qubes,
etc.). Give each qube its private agent and add `shared`.

```bash
ansible-playbook qubesos.setup.split_ssh \
  -e vault=vault-ssh \
  -e 'client_agents={
        "work":     ["work", "shared"],
        "personal": ["personal", "shared"]
      }'
```

`work` can reach the `work` and `shared` agents but not `personal`.
`personal` can reach `personal` and `shared` but not `work`. The vault
runs all three agents.

Route per-host in `~/.ssh/config`:

```sshconfig
Host *.work.internal
    IdentityAgent ~/.split-ssh/work.sock

Host github.com gitlab.com
    IdentityAgent ~/.split-ssh/shared.sock
```

Variables:

| Variable | Default | Purpose |
|---|---|---|
| `vault` | required | Vault qube name |
| `clients` | one of `clients` / `client_agents` | Comma-separated client qubes; all use the single `default` agent |
| `client_agents` | one of `clients` / `client_agents` | Dict `{client: [agents]}` for multi-agent with per-client mapping |
| `policy` | `allow` | `allow` or `ask` (qrexec policy action) |
| `vault_default_agent` | unset | Exports `SSH_AUTH_SOCK` in the vault user shell |
| `client_default_agent` | unset | Exports `SSH_AUTH_SOCK` in clients via `qubes-ssh.sh` (silently skipped per-client if not in that client's allowed agents). A client with exactly one agent defaults to that agent automatically. |
| `create_vault` | `false` | Create the vault qube before configuring it |
| `vault_template` | unset | Template for the vault qube (required if `create_vault=true`) |
| `vault_label` | `black` | Label for the vault qube (only with `create_vault=true`) |

#### Handling keys

Inside the vault qube, put each key set in its own directory under
`~/.ssh/identities.d/`:

```bash
mkdir -m 0700 -p ~/.ssh/identities.d/work
ssh-keygen -t ed25519 -f ~/.ssh/identities.d/work/id_work

mkdir -m 0700 -p ~/.ssh/identities.d/personal
ssh-keygen -t ed25519 -f ~/.ssh/identities.d/personal/id_perso

mkdir -m 0700 -p ~/.ssh/identities.d/shared
ssh-keygen -t ed25519 -f ~/.ssh/identities.d/shared/id_shared

split-ssh reload work
split-ssh reload personal
split-ssh reload shared
```

`split-ssh` subcommands: `list <agent>`, `add <agent>` (re-scan
`identities.d/<agent>/`), `add <agent> <args...>` (ad-hoc `ssh-add`),
`reload <agent>` (`ssh-add -D` then re-scan).

Optional per-key `ssh-add` flags (timeout, host restrictions) can be
placed next to the key, suffix `.ssh-add-option`:

```sh
# ~/.ssh/identities.d/shared/id_shared.ssh-add-option
-t 1800 -h github.com -h gitlab.com
```

Set `client_default_agent=shared` (or another name from your map) to
have `/etc/profile.d/qubes-ssh.sh` export `SSH_AUTH_SOCK` to that
agent at login, so bare `ssh foo` just works for the default keyring.
Override per-host with `IdentityAgent` as shown above. A client that
has exactly one agent defaults `SSH_AUTH_SOCK` to it automatically, so
single-agent clients need no `client_default_agent`.

### Split-GPG

```bash
ansible-playbook qubesos.setup.split_gpg \
  -e vault=vault-gpg -e clients=work,personal
```

Installs `qubes-gpg-split` in the right templates (its
`/etc/profile.d/qubes-gpg.sh` defaults `QUBES_GPG_DOMAIN` to
`@default` when no per-VM config file is present), and writes a
per-vault `qubes.Gpg` policy in dom0 using `@default target=<vault>`
so the vault routing lives in the policy, not in each client.

Route several vaults in a single run with a `vaults` map (each client must
appear under exactly one vault, since routing is `@default target=<vault>`):

```bash
ansible-playbook qubesos.setup.split_gpg \
  -e '{"vaults": {"vault-work": ["work", "build"], "vault-personal": ["personal"]}}'
```

This writes one `30-split-gpg-<vault>.policy` file per vault.

Variables:

| Variable | Default | Purpose |
|---|---|---|
| `vault` | with `clients` | Vault qube name (single-vault form) |
| `clients` | with `vault` | Comma-separated client qubes for that vault |
| `vaults` | or `vault`+`clients` | Map `{vault: [clients]}` to route several vaults in one run |
| `create_vault` | `false` | Create the vault qube(s) before configuring them |
| `vault_template` | unset | Template for created vaults (required if `create_vault=true`) |
| `vault_label` | `black` | Label for created vaults (only with `create_vault=true`) |

#### Handling keys

After the playbook runs, generate or import a GPG key inside the vault
qube:

```bash
gpg --full-generate-key
```

Clients then use `qubes-gpg-client` / `qubes-gpg-client-wrapper` as
usual; the helper routes through `qubes.Gpg` to the configured vault.

### Systemd service (template + qube + dom0)

```bash
ansible-playbook qubesos.setup.qsvc \
  -e svc=docker \
  -e qubes=builder \
  -e packages=moby-engine \
  -e units=docker.service,docker.socket \
  -e user_group=docker \
  -e users_to_group=user \
  -e bind_dirs=/var/lib/docker,/var/lib/containerd \
  -e 'rc_local_lines=mount /var/lib/docker -o dev,suid,remount 2>/dev/null || true'
```

Only `svc` and `qubes` are required. Discovers the template, installs
packages, enables units conditioned on a qubes-service flag, persists
paths, and sets the flag from dom0.

For multiple `rc_local_lines`, use JSON list syntax or a vars file
(comma splitting would break shell commands):

```bash
-e 'rc_local_lines=["mount /var/lib/docker -o dev,suid,remount 2>/dev/null || true","echo ready"]'
-e @my-vars.yml
```

### Persist paths with bind-dirs

```bash
ansible-playbook qubesos.setup.bind_dirs \
  -e qubes=work,personal \
  -e paths=/etc/letsencrypt,/var/lib/letsencrypt \
  -e tag=letsencrypt
```

`tag` is used as the bind-dirs config filename
(`qubes-bind-dirs.d/50-<tag>.conf`) to avoid collisions between
callers. The `50-` priority prefix can be overridden via
`-e bind_dirs_priority=<NN>` if you need a specific load order.

### Importing into your own playbook

```yaml
- import_playbook: qubesos.setup.split_ssh
  vars:
    vault: vault-ssh
    clients: [work, personal]
```

## Prerequisites

The split-SSH and split-GPG playbooks can create the vault qube for
you (`create_vault=true` + `vault_template=<tpl>`). Client qubes must
already exist. The playbooks configure them, they do not create them.

Manual provisioning is still required for the secrets themselves:

- **split-SSH**: generate a key per agent inside the vault qube. With
  `split_ssh_agents=[default]` the role drops `~/.ssh/identities.d/default/`;
  put a key there:

  ```bash
  ssh-keygen -t ed25519 -f ~/.ssh/identities.d/default/id_ed25519
  split-ssh reload default
  ```

- **split-GPG**: generate or import a GPG key inside the vault qube:

  ```bash
  gpg --full-generate-key
  ```

Neither secret can be provisioned by the playbook itself; they have
to be created or imported by the user.
