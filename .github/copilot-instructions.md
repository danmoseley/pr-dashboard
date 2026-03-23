# Copilot Instructions for PR Dashboard

## Local Testing

Before serving pages locally for testing, ensure scan.json files reflect the most recent pipeline run. Pull just the data files from origin/main without switching branches:

```powershell
git fetch origin main
git checkout origin/main -- docs/*/scan.json
```

This updates scan.json data while preserving your local changes to HTML, JS, and CSS files. Then serve from `docs/`:

```powershell
cd docs; python -m http.server 8080
```
