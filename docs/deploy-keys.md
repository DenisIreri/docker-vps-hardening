# Read-only deploy keys

The server needs to pull code. It should never be able to push it.

If the server is compromised, an attacker who finds a personal SSH key or access token
on it can rewrite your repositories. A **deploy key** is an SSH key that is attached
to one repository, and you can make it **read-only**.

## One key per repository

On the server, as the user that runs deployments:

```bash
ssh-keygen -t ed25519 -N "" -C "deploy@$(hostname) myapp" -f ~/.ssh/deploy_myapp
cat ~/.ssh/deploy_myapp.pub
```

Add the public key to the repository as a deploy key and leave **write access off**:

- GitHub: *Settings → Deploy keys → Add deploy key*
- Gitea / Forgejo: *Settings → Deploy Keys → Add Key* (leave "Enable write access" unticked)
- GitLab: *Settings → Repository → Deploy keys*

## Tell SSH which key to use

Each repository gets its own host alias in `~/.ssh/config`, so keys never get mixed up:

```sshconfig
Host git-myapp
    HostName git.example.com
    User git
    IdentityFile ~/.ssh/deploy_myapp
    IdentitiesOnly yes
```

Then clone with the alias:

```bash
git clone git-myapp:team/myapp.git /opt/app
```

## Check it is really read-only

```bash
cd /opt/app
git push --dry-run origin HEAD:refs/heads/deploy-key-test
# expected: "ERROR: ... is read-only" or "permission denied"
```

If that push succeeds, the key has write access: remove it and add it again without.

## Rotating

Deploy keys do not expire. Rotate them when someone with server access leaves, or at
least yearly: add the new key, deploy once with it, then delete the old one.
