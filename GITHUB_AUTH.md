# GitHub authentication for uploads

## Option 1: GitHub CLI (recommended - easiest)

```bash
# Install (if not present)
sudo pacman -S github-cli

# Login
gh auth login

# Follow the prompts:
# - Select GitHub.com
# - Select HTTPS
# - Authenticate Git with your GitHub credentials? → Yes
# - Login with a web browser → Yes
# - Copy the code and open the link in your browser
```

After login you can push as usual:
```bash
git push -u origin main
git push origin v0.1
```

## Option 2: Personal Access Token (PAT)

1. Go to: https://github.com/settings/tokens
2. "Generate new token" → "Generate new token (classic)"
3. Name: e.g. "GHULbenchmark Upload"
4. Scopes: `repo` (full access to repositories)
5. Click "Generate token"
6. **Copy the token** (it is only shown once!)

Then on the first push:
```bash
git push -u origin main
# Username: your-github-username
# Password: <paste-token-here>
```

Git can store the token (with `git config --global credential.helper store`).

## Option 3: SSH key (advanced)

If you already have an SSH key registered with GitHub:
```bash
# Switch remote to SSH
git remote set-url origin git@github.com:g-h-u-l/GHULbenchmark.git

# Then push as usual
git push -u origin main
```

## Recommendation

**GitHub CLI** is the easiest – run `gh auth login` once and you are done!


