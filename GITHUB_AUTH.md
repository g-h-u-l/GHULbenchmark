# GitHub Authentifizierung für Upload

## Option 1: GitHub CLI (empfohlen - am einfachsten)

```bash
# Installieren (falls nicht vorhanden)
sudo pacman -S github-cli

# Einloggen
gh auth login

# Folgt den Anweisungen:
# - GitHub.com wählen
# - HTTPS wählen
# - Authenticate Git with your GitHub credentials? → Yes
# - Login with a web browser → Yes
# - Copy den Code und öffne den Link im Browser
```

Nach dem Login kannst du normal pushen:
```bash
git push -u origin main
git push origin v0.1
```

## Option 2: Personal Access Token (PAT)

1. Gehe zu: https://github.com/settings/tokens
2. "Generate new token" → "Generate new token (classic)"
3. Name: z.B. "GHULbenchmark Upload"
4. Scopes: `repo` (vollständiger Zugriff auf Repositories)
5. "Generate token" klicken
6. **Token kopieren** (wird nur einmal angezeigt!)

Dann beim ersten Push:
```bash
git push -u origin main
# Username: dein-github-username
# Password: <paste-token-hier>
```

Git kann das Token dann speichern (mit `git config --global credential.helper store`).

## Option 3: SSH Key (für fortgeschrittene)

Falls du bereits einen SSH-Key bei GitHub hinterlegt hast:
```bash
# Remote auf SSH umstellen
git remote set-url origin git@github.com:g-h-u-l/GHULbenchmark.git

# Dann normal pushen
git push -u origin main
```

## Empfehlung

**GitHub CLI** ist am einfachsten - einmal `gh auth login` und fertig!


